#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <pwd.h>
#include <grp.h>

#define TAILSCALE_BIN "/usr/bin/tailscale"
#define KEY_DIR       "/etc/gateway"
#define KEY_FILE      "/etc/gateway/tailscale.key"
#define KEY_TMP       "/etc/gateway/.tailscale.key.tmp"
#define OPERATOR_USER "gateway-ui"

/* ── Validation helpers ──────────────────────────────────────────────────── */

static int has_shell_meta(const char *s) {
    for (; *s; s++) {
        if (strchr(";&|`$()<>\n\r", *s))
            return 1;
    }
    return 0;
}

static int is_valid_cidr_list(const char *s) {
    if (*s == '\0')
        return 1;

    char buf[1024];
    strncpy(buf, s, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    char *token = strtok(buf, ",");
    while (token) {
        while (*token == ' ')
            token++;
        char *end = token + strlen(token);
        while (end > token && end[-1] == ' ')
            end--;
        *end = '\0';

        if (*token == '\0') {
            token = strtok(NULL, ",");
            continue;
        }

        int a, b, c, d, mask;
        char rest[2] = {};
        if (sscanf(token, "%d.%d.%d.%d/%d%1s", &a, &b, &c, &d, &mask, rest) != 5)
            return 0;
        if (a < 0 || a > 255 || b < 0 || b > 255 || c < 0 || c > 255 || d < 0 || d > 255)
            return 0;
        if (mask < 0 || mask > 32)
            return 0;

        token = strtok(NULL, ",");
    }
    return 1;
}

/* Route lists read back from tailscaled prefs may include IPv6 CIDRs, which
   is_valid_cidr_list (IPv4-only, guards UI input) rejects. Prefs come from
   root-owned tailscaled, so a conservative charset check is sufficient here:
   hex digits, dots, colons, slashes and commas only. */
static int is_safe_prefs_route_list(const char *s) {
    for (; *s; s++) {
        if (!strchr("0123456789abcdefABCDEF:./,", *s))
            return 0;
    }
    return 1;
}

static int is_safe_hostname(const char *s) {
    size_t n = strlen(s);
    if (n == 0 || n > 63)
        return 0;
    for (; *s; s++) {
        if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') ||
              (*s >= '0' && *s <= '9') || *s == '-' || *s == '.' || *s == '_'))
            return 0;
    }
    return 1;
}

/* ── Subprocess helpers (pattern shared with ota-update-wrapper.c) ───────── */

/* Run argv, inheriting stdin/stdout/stderr. Return exit code, -1 on error. */
static int run(char *const argv[]) {
    pid_t pid = fork();
    if (pid == -1) return -1;
    if (pid == 0) {
        execv(argv[0], argv);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

/* Run argv, capture stdout into buf (NUL-terminated). Stderr passes through.
   If the child produces more than bufsz-1 bytes, the excess is read and
   discarded (never stop reading — a full pipe would block the child and
   hang waitpid). Callers must treat a completely-full buffer as truncated.
   Return exit code, -1 on error. */
static int run_capture(char *const argv[], char *buf, size_t bufsz) {
    int pipefd[2];
    if (pipe(pipefd) == -1) return -1;
    pid_t pid = fork();
    if (pid == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        execv(argv[0], argv);
        _exit(127);
    }
    close(pipefd[1]);
    size_t off = 0;
    for (;;) {
        if (off < bufsz - 1) {
            ssize_t n = read(pipefd[0], buf + off, bufsz - 1 - off);
            if (n <= 0) break;
            off += (size_t)n;
        } else {
            char drain[256];
            ssize_t n = read(pipefd[0], drain, sizeof(drain));
            if (n <= 0) break;
        }
    }
    buf[off < bufsz - 1 ? off : bufsz - 1] = '\0';
    close(pipefd[0]);
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

/* ── Minimal extraction from `tailscale debug prefs` JSON output ─────────── */
/* The output is machine-generated (json.MarshalIndent) with exact quoted
   keys, so targeted string scanning is sufficient and avoids a JSON
   dependency in a setuid binary. On any ambiguity we fail the parse and the
   caller falls back to conservative flags (which may make `tailscale up`
   error visibly — never wipe prefs silently). */

static const char *find_json_key(const char *buf, const char *key) {
    char pat[64];
    if (snprintf(pat, sizeof(pat), "\"%s\":", key) >= (int)sizeof(pat))
        return NULL;
    const char *p = strstr(buf, pat);
    if (!p)
        return NULL;
    p += strlen(pat);
    while (*p == ' ' || *p == '\t')
        p++;
    return p;
}

/* Returns 1/0 via *out; return value is parse success. */
static int extract_json_bool(const char *buf, const char *key, int *out) {
    const char *p = find_json_key(buf, key);
    if (!p)
        return 0;
    if (strncmp(p, "true", 4) == 0) { *out = 1; return 1; }
    if (strncmp(p, "false", 5) == 0) { *out = 0; return 1; }
    return 0;
}

static int extract_json_string(const char *buf, const char *key,
                               char *out, size_t outsz) {
    const char *p = find_json_key(buf, key);
    if (!p || *p != '"')
        return 0;
    p++;
    size_t i = 0;
    while (*p && *p != '"') {
        if (*p == '\\')
            return 0; /* escaped content unexpected for our fields — bail */
        if (i >= outsz - 1)
            return 0;
        out[i++] = *p++;
    }
    if (*p != '"')
        return 0;
    out[i] = '\0';
    return 1;
}

/* AdvertiseRoutes is either null or an array of quoted CIDR strings.
   Writes a comma-separated list into out (empty string when null/empty). */
static int extract_json_routes(const char *buf, char *out, size_t outsz) {
    out[0] = '\0';
    const char *p = find_json_key(buf, "AdvertiseRoutes");
    if (!p)
        return 0;
    if (strncmp(p, "null", 4) == 0)
        return 1;
    if (*p != '[')
        return 0;
    p++;
    size_t off = 0;
    for (;;) {
        while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == ','))
            p++;
        if (*p == ']')
            return 1;
        if (*p != '"')
            return 0;
        p++;
        if (off > 0) {
            if (off >= outsz - 1)
                return 0;
            out[off++] = ',';
        }
        while (*p && *p != '"') {
            if (*p == '\\' || off >= outsz - 1)
                return 0;
            out[off++] = *p++;
        }
        if (*p != '"')
            return 0;
        p++;
        out[off] = '\0';
    }
}

/* ── Auth key persistence ────────────────────────────────────────────────── */

/* Write the key to KEY_TMP (0600 root:root). The caller renames it to
   KEY_FILE only after `tailscale up` succeeds, so a previously-working
   saved key is never clobbered by a bad one. */
static int write_key_tmp(const char *key) {
    if (mkdir(KEY_DIR, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "ERROR: cannot create %s: %s\n", KEY_DIR, strerror(errno));
        return -1;
    }
    int fd = open(KEY_TMP, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        fprintf(stderr, "ERROR: cannot write %s: %s\n", KEY_TMP, strerror(errno));
        return -1;
    }
    if (fchown(fd, 0, 0) != 0 || fchmod(fd, 0600) != 0) {
        fprintf(stderr, "ERROR: cannot set ownership on %s: %s\n", KEY_TMP, strerror(errno));
        close(fd);
        unlink(KEY_TMP);
        return -1;
    }
    size_t len = strlen(key);
    if (write(fd, key, len) != (ssize_t)len) {
        fprintf(stderr, "ERROR: short write to %s\n", KEY_TMP);
        close(fd);
        unlink(KEY_TMP);
        return -1;
    }
    if (fsync(fd) != 0) {
        fprintf(stderr, "ERROR: fsync %s failed: %s\n", KEY_TMP, strerror(errno));
        close(fd);
        unlink(KEY_TMP);
        return -1;
    }
    close(fd);
    return 0;
}

/* ── auth subcommand ─────────────────────────────────────────────────────── */
/* Never uses --reset: `tailscale up` requires every non-default pref to be
   re-specified, and --reset "solves" that by silently wiping them (this is
   what disabled Tailscale SSH and cleared --operator on re-auth in the
   field). Instead we read the current prefs and re-specify them explicitly.
   If the prefs read fails we proceed with conservative flags: tailscale
   will then error visibly rather than wipe anything. */
static int do_auth(const char *key) {
    if (strncmp(key, "tskey-", 6) != 0) {
        fprintf(stderr, "ERROR: auth key must start with tskey-\n");
        return 1;
    }
    if (strlen(key) > 256) {
        fprintf(stderr, "ERROR: auth key too long\n");
        return 1;
    }
    if (has_shell_meta(key)) {
        fprintf(stderr, "ERROR: auth key contains invalid characters\n");
        return 1;
    }

    if (write_key_tmp(key) != 0)
        return 1;

    /* Read current prefs so they can be preserved explicitly. A buffer
       filled to capacity means truncated output — treat as unreadable
       rather than risk parsing a cut-off document. */
    static char prefs[16384];
    int prefs_ok = 0;
    {
        char *prefs_argv[] = {TAILSCALE_BIN, "debug", "prefs", NULL};
        if (run_capture(prefs_argv, prefs, sizeof(prefs)) == 0 && prefs[0] &&
            strlen(prefs) < sizeof(prefs) - 1)
            prefs_ok = 1;
    }

    int run_ssh = 0;
    int have_ssh = 0;
    static char routes[2048];
    int have_routes = 0;
    static char hostname_pref[128];
    int have_hostname = 0;

    if (prefs_ok) {
        have_ssh = extract_json_bool(prefs, "RunSSH", &run_ssh);
        if (extract_json_routes(prefs, routes, sizeof(routes)) &&
            routes[0] != '\0' && is_safe_prefs_route_list(routes))
            have_routes = 1;
        if (extract_json_string(prefs, "Hostname", hostname_pref, sizeof(hostname_pref)) &&
            hostname_pref[0] != '\0' && is_safe_hostname(hostname_pref))
            have_hostname = 1;
    }

    char authkey_arg[]  = "--auth-key=file:" KEY_TMP;
    char operator_arg[] = "--operator=" OPERATOR_USER;
    char timeout_arg[]  = "--timeout=25s";
    char ssh_arg[16];
    snprintf(ssh_arg, sizeof(ssh_arg), "--ssh=%s", run_ssh ? "true" : "false");
    char routes_arg[2064];
    snprintf(routes_arg, sizeof(routes_arg), "--advertise-routes=%s", routes);
    char hostname_arg[160];
    snprintf(hostname_arg, sizeof(hostname_arg), "--hostname=%s", hostname_pref);

    char *up_argv[10];
    int n = 0;
    up_argv[n++] = TAILSCALE_BIN;
    up_argv[n++] = "up";
    up_argv[n++] = authkey_arg;
    up_argv[n++] = operator_arg;
    up_argv[n++] = timeout_arg;
    if (have_ssh)
        up_argv[n++] = ssh_arg;
    if (have_routes)
        up_argv[n++] = routes_arg;
    if (have_hostname)
        up_argv[n++] = hostname_arg;
    up_argv[n] = NULL;

    int rc = run(up_argv);

    if (rc == 0) {
        if (rename(KEY_TMP, KEY_FILE) != 0) {
            fprintf(stderr, "WARNING: connected, but could not persist auth key to %s: %s\n",
                    KEY_FILE, strerror(errno));
            unlink(KEY_TMP);
        }
    } else {
        unlink(KEY_TMP);
        if (rc == 127)
            fprintf(stderr, "ERROR: failed to execute %s\n", TAILSCALE_BIN);
    }
    return rc == 0 ? 0 : (rc > 0 ? rc : 1);
}

/* ── main ────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    struct passwd *pw = getpwnam("gateway-ui");
    if (!pw) {
        fprintf(stderr, "ERROR: gateway-ui user not found on system\n");
        return 1;
    }
    if (getuid() != pw->pw_uid) {
        fprintf(stderr, "ERROR: only gateway-ui user may invoke this wrapper\n");
        return 1;
    }

    if (argc < 2) {
        fprintf(stderr, "ERROR: usage: tailscale-wrapper <auth|set-routes|set-ssh> [args]\n");
        return 1;
    }

    const char *subcmd = argv[1];

    if (strcmp(subcmd, "auth") == 0) {
        if (argc != 3) {
            fprintf(stderr, "ERROR: usage: tailscale-wrapper auth <authkey>\n");
            return 1;
        }

        setgroups(0, NULL);
        setgid(0);
        setuid(0);

        return do_auth(argv[2]);
    }

    if (strcmp(subcmd, "set-routes") == 0) {
        if (argc != 3) {
            fprintf(stderr, "ERROR: usage: tailscale-wrapper set-routes <cidrs> (empty string disables)\n");
            return 1;
        }
        const char *cidrs = argv[2];
        if (!is_valid_cidr_list(cidrs)) {
            fprintf(stderr, "ERROR: invalid CIDR in list\n");
            return 1;
        }
        if (has_shell_meta(cidrs)) {
            fprintf(stderr, "ERROR: CIDR list contains invalid characters\n");
            return 1;
        }

        char routes_arg[4096];
        snprintf(routes_arg, sizeof(routes_arg), "--advertise-routes=%s", cidrs);
        char *new_argv[] = {TAILSCALE_BIN, "set", routes_arg, NULL};

        setgroups(0, NULL);
        setgid(0);
        setuid(0);

        execv(TAILSCALE_BIN, new_argv);
        fprintf(stderr, "ERROR: failed to execute %s\n", TAILSCALE_BIN);
        return 1;
    }

    if (strcmp(subcmd, "set-ssh") == 0) {
        if (argc != 3) {
            fprintf(stderr, "ERROR: usage: tailscale-wrapper set-ssh <on|off>\n");
            return 1;
        }
        const char *val = argv[2];
        if (strcmp(val, "on") != 0 && strcmp(val, "off") != 0) {
            fprintf(stderr, "ERROR: set-ssh requires 'on' or 'off'\n");
            return 1;
        }

        const char *ssh_val = (strcmp(val, "on") == 0) ? "true" : "false";
        char ssh_arg[32];
        snprintf(ssh_arg, sizeof(ssh_arg), "--ssh=%s", ssh_val);
        char *new_argv[] = {TAILSCALE_BIN, "set", ssh_arg, NULL};

        setgroups(0, NULL);
        setgid(0);
        setuid(0);

        execv(TAILSCALE_BIN, new_argv);
        fprintf(stderr, "ERROR: failed to execute %s\n", TAILSCALE_BIN);
        return 1;
    }

    fprintf(stderr, "ERROR: unknown subcommand '%s' — use auth, set-routes, or set-ssh\n", subcmd);
    return 1;
}
