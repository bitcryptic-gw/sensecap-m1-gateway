#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>
#include <grp.h>

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
        fprintf(stderr, "ERROR: usage: system-power-wrapper <reboot|poweroff>\n");
        return 1;
    }

    const char *action = argv[1];

    if (strcmp(action, "reboot") != 0 && strcmp(action, "poweroff") != 0) {
        fprintf(stderr, "ERROR: invalid action '%s' — use reboot or poweroff\n", action);
        return 1;
    }

    setgroups(0, NULL);
    setgid(0);
    setuid(0);

    char *new_argv[] = {"/usr/bin/systemctl", (char *)action, NULL};
    execv("/usr/bin/systemctl", new_argv);
    fprintf(stderr, "ERROR: failed to execute /usr/bin/systemctl\n");
    return 1;
}
