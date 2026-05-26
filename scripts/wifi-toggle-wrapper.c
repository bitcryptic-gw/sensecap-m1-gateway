/*
 * wifi-toggle-wrapper — setuid root wrapper to toggle WiFi radio via nmcli.
 *
 * Install (after git pull on Pi):
 *
 *   sudo gcc -O2 -Wall -o /usr/local/bin/wifi-toggle-wrapper \
 *       /opt/gateway/scripts/wifi-toggle-wrapper.c
 *   sudo chown root:root /usr/local/bin/wifi-toggle-wrapper
 *   sudo chmod u+s /usr/local/bin/wifi-toggle-wrapper
 *   sudo systemctl restart gateway-ui.service
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
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
        fprintf(stderr, "ERROR: usage: wifi-toggle-wrapper <on|off>\n");
        return 1;
    }

    const char *action = argv[1];

    if (strcmp(action, "on") != 0 && strcmp(action, "off") != 0) {
        fprintf(stderr, "ERROR: invalid action '%s' — use on or off\n", action);
        return 1;
    }

    pid_t pid = fork();
    if (pid == -1) {
        fprintf(stderr, "ERROR: fork failed\n");
        return 1;
    }

    if (pid == 0) {
        setgroups(0, NULL);
        setgid(0);
        setuid(0);

        char *new_argv[] = {"/usr/bin/nmcli", "radio", "wifi", (char *)action, NULL};
        execv("/usr/bin/nmcli", new_argv);
        fprintf(stderr, "ERROR: failed to execute /usr/bin/nmcli\n");
        _exit(1);
    }

    int status;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        printf("WIFI:%s\n", action);
        return 0;
    }

    fprintf(stderr, "ERROR: nmcli radio wifi %s failed\n", action);
    return 1;
}
