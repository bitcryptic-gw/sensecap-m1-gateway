#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <pwd.h>
#include <grp.h>
#include <errno.h>

#define REPO_DIR "/opt/gateway"
#define ALLOWED_UNITS \
    "pktfwd.service,gateway-rs.service,gateway-ui.service," \
    "readsb.service,wingbits.service,tailscaled.service"

static int is_allowed(const char *name) {
    const char *p = ALLOWED_UNITS;
    while (*p) {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (strncmp(p, name, len) == 0 && name[len] == '\0')
            return 1;
        p = end ? end + 1 : end;
    }
    return 0;
}

/* Run argv via execvp, inheriting stdin/stdout/stderr. Return exit code. */
static int run(char *const argv[]) {
    pid_t pid = fork();
    if (pid == -1) return -1;
    if (pid == 0) {
        execvp(argv[0], argv);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

/* Run argv via execvp, capture stdout into buf (up to bufsz-1 bytes, NUL-terminated).
   Stderr passes through to parent. Return exit code. */
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
        execvp(argv[0], argv);
        _exit(127);
    }
    close(pipefd[1]);
    ssize_t n = read(pipefd[0], buf, bufsz - 1);
    if (n > 0) buf[n] = '\0';
    else buf[0] = '\0';
    close(pipefd[0]);
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
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
        fprintf(stderr, "ERROR: usage: ota-update-wrapper --changes | <service1,service2,...>\n");
        return 1;
    }

    /* Become root for filesystem ops */
    setgroups(0, NULL);
    setgid(0);
    setuid(0);

    /* Determine repo owner from /opt/gateway directory stat */
    struct stat st;
    if (stat(REPO_DIR, &st) != 0) {
        fprintf(stderr, "ERROR: cannot stat %s: %s\n", REPO_DIR, strerror(errno));
        return 1;
    }
    uid_t repo_owner = st.st_uid;

    /* chdir to repo */
    if (chdir(REPO_DIR) != 0) {
        fprintf(stderr, "ERROR: cannot chdir to %s: %s\n", REPO_DIR, strerror(errno));
        return 1;
    }

    /* ── --changes mode ─────────────────────────────────────────────────────── */
    if (strcmp(argv[1], "--changes") == 0) {
        /* git operations as repo owner */
        setuid(repo_owner);
        setgid(0);

        int fetch_rc = run((char *[]){"/usr/bin/git", "fetch", "origin", NULL});
        if (fetch_rc != 0) {
            fprintf(stderr, "ERROR: git fetch origin failed (exit %d)\n", fetch_rc);
            return 1;
        }

        char diff_buf[65536];
        int diff_rc = run_capture(
            (char *[]){"/usr/bin/git", "diff", "--name-only", "HEAD..origin/main", NULL},
            diff_buf, sizeof(diff_buf));
        if (diff_rc != 0) {
            fprintf(stderr, "ERROR: git diff failed (exit %d)\n", diff_rc);
            return 1;
        }
        printf("%s", diff_buf);
        if (diff_buf[0] && diff_buf[strlen(diff_buf) - 1] != '\n')
            putchar('\n');
        return 0;
    }

    /* ── Update mode (default) ──────────────────────────────────────────────── */

    /* Parse and validate service list */
    char svc_buf[1024];
    strncpy(svc_buf, argv[1], sizeof(svc_buf) - 1);
    svc_buf[sizeof(svc_buf) - 1] = '\0';
    char *svc_list[32];
    int svc_count = 0;
    char *token = strtok(svc_buf, ",");
    while (token && svc_count < 32) {
        while (*token == ' ') token++;
        char *end = token + strlen(token);
        while (end > token && end[-1] == ' ') end--;
        *end = '\0';
        if (*token == '\0') { token = strtok(NULL, ","); continue; }
        if (!is_allowed(token)) {
            fprintf(stderr, "ERROR: not allowed: %s\n", token);
            return 1;
        }
        svc_list[svc_count++] = token;
        token = strtok(NULL, ",");
    }

    if (svc_count == 0) {
        fprintf(stderr, "ERROR: at least one service required\n");
        return 1;
    }

    /* Line-buffer stdout for SSE streaming */
    setvbuf(stdout, NULL, _IOLBF, 0);

    /* Capture pre-pull HEAD */
    char pre_head[128] = "";
    run_capture((char *[]){"/usr/bin/git", "rev-parse", "HEAD", NULL},
                pre_head, sizeof(pre_head));
    if (pre_head[0]) {
        char *nl = strchr(pre_head, '\n');
        if (nl) *nl = '\0';
    }

    /* git pull as repo owner */
    setuid(repo_owner);
    setgid(0);

    int pull_rc = run((char *[]){"/usr/bin/git", "pull", NULL});

    /* Become root again */
    setuid(0);
    setgid(0);

    if (pull_rc != 0) {
        fprintf(stderr, "ERROR: git pull failed (exit %d)\n", pull_rc);
        return 1;
    }

    /* Capture post-pull HEAD */
    char post_head[128] = "";
    run_capture((char *[]){"/usr/bin/git", "rev-parse", "HEAD", NULL},
                post_head, sizeof(post_head));
    if (post_head[0]) {
        char *nl = strchr(post_head, '\n');
        if (nl) *nl = '\0';
    }

    /* Update /etc/gateway-version with new git describe output */
    char version[256] = "unknown";
    setuid(repo_owner);
    setgid(0);
    char describe_buf[256] = "";
    int describe_rc = run_capture(
        (char *[]){"/usr/bin/git", "-C", REPO_DIR, "describe", "--tags", "--always", NULL},
        describe_buf, sizeof(describe_buf));
    setuid(0);
    setgid(0);

    if (describe_rc == 0 && describe_buf[0]) {
        char *nl = strchr(describe_buf, '\n');
        if (nl) *nl = '\0';
        strncpy(version, describe_buf, sizeof(version) - 1);
        version[sizeof(version) - 1] = '\0';
        FILE *vf = fopen("/etc/gateway-version", "w");
        if (vf) {
            fprintf(vf, "%s\n", version);
            fclose(vf);
        }
    } else {
        fprintf(stderr, "WARNING: git describe failed (exit %d) — /etc/gateway-version not updated\n", describe_rc);
    }

    /* ── Recompile all setuid wrappers ──────────────────────────────────────── */
    {
        struct { const char *name, *src, *bin; } const w_list[] = {
            {"ota-update-wrapper",
             REPO_DIR "/scripts/ota-update-wrapper.c",
             "/usr/local/bin/ota-update-wrapper"},
            {"system-power-wrapper",
             REPO_DIR "/scripts/system-power-wrapper.c",
             "/usr/local/bin/system-power-wrapper"},
            {"tailscale-wrapper",
             REPO_DIR "/scripts/tailscale-wrapper.c",
             "/usr/local/bin/tailscale-wrapper"},
            {"wingbits-setup-wrapper",
             REPO_DIR "/scripts/wingbits-setup-wrapper.c",
             "/usr/local/bin/wingbits-setup-wrapper"},
            {"wifi-toggle-wrapper",
             REPO_DIR "/scripts/wifi-toggle-wrapper.c",
             "/usr/local/bin/wifi-toggle-wrapper"},
            {NULL, NULL, NULL},
        };
        for (int i = 0; w_list[i].name; i++) {
            /* Skip if source file does not exist (wingbits may not be installed) */
            struct stat ws;
            if (stat(w_list[i].src, &ws) != 0) {
                /* wingbits-setup-wrapper is optional — skip silently */
                if (strcmp(w_list[i].name, "wingbits-setup-wrapper") == 0)
                    continue;
                fprintf(stderr, "ERROR: source not found: %s\n", w_list[i].src);
                printf("WRAPPER: %s FAILED\n", w_list[i].name);
                continue;
            }
            int rc = run((char *[]){"/usr/bin/gcc", "-O2",
                           (char *)w_list[i].src, "-o", (char *)w_list[i].bin, NULL});
            if (rc != 0) {
                fprintf(stderr, "ERROR: gcc failed for %s (exit %d)\n", w_list[i].name, rc);
                printf("WRAPPER: %s FAILED\n", w_list[i].name);
                continue;
            }
            run((char *[]){"/usr/bin/chown", "root:root", (char *)w_list[i].bin, NULL});
            run((char *[]){"/bin/chmod", "4755", (char *)w_list[i].bin, NULL});
            printf("WRAPPER: %s OK\n", w_list[i].name);
        }
    }

    /* Write diff to stdout */
    if (pre_head[0] && post_head[0] && strcmp(pre_head, post_head) != 0) {
        char *diff_argv[] = {
            "/usr/bin/git", "diff", "--name-only", pre_head, post_head, NULL
        };
        char diff_buf[8192];
        int diff_rc = run_capture(diff_argv, diff_buf, sizeof(diff_buf));
        if (diff_rc == 0 && diff_buf[0]) {
            fputs(diff_buf, stdout);
            if (diff_buf[strlen(diff_buf) - 1] != '\n')
                putchar('\n');
        }
    } else {
        printf("(no changes)\n");
    }

    /* Restart services as root */
    for (int i = 0; i < svc_count; i++) {
        int rc = run((char *[]){"/usr/bin/systemctl", "restart", svc_list[i], NULL});
        printf("restarted %s (exit %d)\n", svc_list[i], rc);
    }

    printf("VERSION:%s\n", version);

    return 0;
}
