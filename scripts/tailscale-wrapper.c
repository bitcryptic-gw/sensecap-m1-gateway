#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>
#include <grp.h>

#define TAILSCALE_BIN "/usr/bin/tailscale"

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
        const char *key = argv[2];
        if (strncmp(key, "tskey-", 6) != 0) {
            fprintf(stderr, "ERROR: auth key must start with tskey-\n");
            return 1;
        }
        if (has_shell_meta(key)) {
            fprintf(stderr, "ERROR: auth key contains invalid characters\n");
            return 1;
        }

        char authkey_arg[2048];
        snprintf(authkey_arg, sizeof(authkey_arg), "--authkey=%s", key);
        char *new_argv[] = {TAILSCALE_BIN, "up", authkey_arg, "--reset", NULL};

        setgroups(0, NULL);
        setuid(0);
        setgid(0);

        execv(TAILSCALE_BIN, new_argv);
        fprintf(stderr, "ERROR: failed to execute %s\n", TAILSCALE_BIN);
        return 1;
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
        setuid(0);
        setgid(0);

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
        setuid(0);
        setgid(0);

        execv(TAILSCALE_BIN, new_argv);
        fprintf(stderr, "ERROR: failed to execute %s\n", TAILSCALE_BIN);
        return 1;
    }

    fprintf(stderr, "ERROR: unknown subcommand '%s' — use auth, set-routes, or set-ssh\n", subcmd);
    return 1;
}
