#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <pwd.h>
#include <grp.h>
#include <errno.h>

#define REPO_DIR "/opt/gateway"
#define TAILSCALE_UNITS "tailscaled.service"
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

static int run_cmd(char *const argv[]) {
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

    if (argc != 2) {
        fprintf(stderr, "ERROR: usage: ota-update-wrapper <service1,service2,...>\n");
        return 1;
    }

    // Parse and validate service list
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

    // Become root for filesystem ops
    setgroups(0, NULL);
    gid_t root_gid = 0;
    uid_t root_uid = 0;
    setgid(root_gid);
    setuid(root_uid);

    // Determine repo owner
    struct stat st;
    if (stat(REPO_DIR, &st) != 0) {
        fprintf(stderr, "ERROR: cannot stat %s: %s\n", REPO_DIR, strerror(errno));
        return 1;
    }
    uid_t repo_owner = st.st_uid;

    // chdir to repo
    if (chdir(REPO_DIR) != 0) {
        fprintf(stderr, "ERROR: cannot chdir to %s: %s\n", REPO_DIR, strerror(errno));
        return 1;
    }

    // Capture pre-pull HEAD
    FILE *fp;
    char pre_head[128] = "";
    fp = popen("git rev-parse HEAD 2>/dev/null", "r");
    if (fp) {
        if (fgets(pre_head, sizeof(pre_head), fp)) {
            char *nl = strchr(pre_head, '\n');
            if (nl) *nl = '\0';
        }
        pclose(fp);
    }

    // git pull as repo owner
    setuid(repo_owner);
    setgid(0);

    setvbuf(stdout, NULL, _IOLBF, 0);

    int pull_rc = system("git pull 2>&1");
    pull_rc = WEXITSTATUS(pull_rc);

    // Become root again
    setuid(root_uid);
    setgid(root_gid);

    if (pull_rc != 0) {
        fprintf(stderr, "ERROR: git pull failed (exit %d)\n", pull_rc);
        return 1;
    }

    // Capture post-pull HEAD
    char post_head[128] = "";
    fp = popen("git rev-parse HEAD 2>/dev/null", "r");
    if (fp) {
        if (fgets(post_head, sizeof(post_head), fp)) {
            char *nl = strchr(post_head, '\n');
            if (*nl) *nl = '\0';
        }
        pclose(fp);
    }

    // Write diff to stdout
    if (pre_head[0] && post_head[0] && strcmp(pre_head, post_head) != 0) {
        char diff_cmd[512];
        snprintf(diff_cmd, sizeof(diff_cmd),
                 "git diff --name-only %s %s 2>/dev/null", pre_head, post_head);
        fp = popen(diff_cmd, "r");
        if (fp) {
            char line[4096];
            while (fgets(line, sizeof(line), fp)) {
                fputs(line, stdout);
            }
            pclose(fp);
        }
    } else {
        printf("(no changes)\n");
    }

    // Restart services as root
    for (int i = 0; i < svc_count; i++) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "systemctl restart %s 2>&1", svc_list[i]);
        int rc = system(cmd);
        rc = WEXITSTATUS(rc);
        printf("restarted %s (exit %d)\n", svc_list[i], rc);
    }

    // Read new version
    char version[256] = "unknown";
    fp = fopen("/etc/gateway-version", "r");
    if (fp) {
        if (fgets(version, sizeof(version), fp)) {
            char *nl = strchr(version, '\n');
            if (nl) *nl = '\0';
        }
        fclose(fp);
    }
    printf("VERSION:%s\n", version);

    return 0;
}
