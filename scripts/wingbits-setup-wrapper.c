#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>

#define ALLOWED_PREFIX "https://gitlab.com/wingbits/config/-/raw/"
#define SETUP_SCRIPT   "/opt/gateway/scripts/wingbits-setup.sh"

static const char SHELL_META[] = {';', '&', '|', '`', '$', '(', ')', '<', '>', '\n', '\r', 0};

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
        fprintf(stderr, "ERROR: usage: wingbits-setup-wrapper <install-url>\n");
        return 1;
    }

    const char *url = argv[1];
    size_t prefix_len = strlen(ALLOWED_PREFIX);

    if (strncmp(url, ALLOWED_PREFIX, prefix_len) != 0) {
        fprintf(stderr, "ERROR: URL must start with: %s\n", ALLOWED_PREFIX);
        return 1;
    }

    for (const char *p = url; *p; p++) {
        if (strchr(SHELL_META, *p)) {
            fprintf(stderr, "ERROR: URL contains invalid characters\n");
            return 1;
        }
    }

    setuid(0);
    setgid(0);

    execl(SETUP_SCRIPT, SETUP_SCRIPT, url, (char *)NULL);

    fprintf(stderr, "ERROR: failed to execute %s\n", SETUP_SCRIPT);
    return 1;
}
