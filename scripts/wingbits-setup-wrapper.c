#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>

#define SETUP_SCRIPT   "/opt/gateway/scripts/wingbits-setup.sh"

static const char SHELL_META[] = {';', '&', '|', '`', '$', '(', ')', '<', '>', '\n', '\r', 0};

static int has_shell_meta(const char *s) {
    for (const char *p = s; *p; p++) {
        if (strchr(SHELL_META, *p)) return 1;
    }
    return 0;
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

    const char *loc = NULL;
    const char *id  = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--loc") == 0 && i + 1 < argc) {
            loc = argv[++i];
        } else if (strcmp(argv[i], "--id") == 0 && i + 1 < argc) {
            id = argv[++i];
        } else {
            fprintf(stderr, "ERROR: usage: wingbits-setup-wrapper --loc \"<loc>\" --id \"<id>\"\n");
            return 1;
        }
    }

    if (!loc || !id) {
        fprintf(stderr, "ERROR: both --loc and --id are required\n");
        return 1;
    }

    if (has_shell_meta(loc) || has_shell_meta(id)) {
        fprintf(stderr, "ERROR: location or station ID contains invalid characters\n");
        return 1;
    }

    if (!strchr(loc, ',')) {
        fprintf(stderr, "ERROR: location must contain latitude and longitude separated by a comma\n");
        return 1;
    }

    for (const char *p = id; *p; p++) {
        if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9'))) {
            fprintf(stderr, "ERROR: station ID must be alphanumeric\n");
            return 1;
        }
    }

    setuid(0);
    setgid(0);

    execl(SETUP_SCRIPT, SETUP_SCRIPT, "--loc", loc, "--id", id, (char *)NULL);

    fprintf(stderr, "ERROR: failed to execute %s\n", SETUP_SCRIPT);
    return 1;
}
