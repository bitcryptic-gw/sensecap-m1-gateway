/*
 * wifi-connect-wrapper — setuid root wrapper for nmcli wifi connect/connection up.
 *
 * Install (after git pull on Pi):
 *
 *   sudo gcc -O2 -Wall -o /usr/local/bin/wifi-connect-wrapper \
 *       /opt/gateway/scripts/wifi-connect-wrapper.c
 *   sudo chown root:root /usr/local/bin/wifi-connect-wrapper
 *   sudo chmod u+s /usr/local/bin/wifi-connect-wrapper
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

static int do_connect(const char *ssid, const char *password) {
    pid_t pid = fork();
    if (pid == -1) {
        fprintf(stderr, "ERROR: fork failed\n");
        return 1;
    }

    if (pid == 0) {
        setgroups(0, NULL);
        setgid(0);
        setuid(0);

        char *new_argv[] = {
            "/usr/bin/nmcli",
            "device", "wifi", "connect",
            (char *)ssid,
            "password", (char *)password,
            "--wait", "30",
            NULL
        };
        execv("/usr/bin/nmcli", new_argv);
        fprintf(stderr, "ERROR: failed to execute /usr/bin/nmcli\n");
        _exit(1);
    }

    int status;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        printf("CONNECT:OK\n");
        return 0;
    }

    printf("CONNECT:FAILED:nmcli exited with code %d\n",
           WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    return 1;
}

static int do_connect_saved(const char *name) {
    pid_t pid = fork();
    if (pid == -1) {
        fprintf(stderr, "ERROR: fork failed\n");
        return 1;
    }

    if (pid == 0) {
        setgroups(0, NULL);
        setgid(0);
        setuid(0);

        char *new_argv[] = {
            "/usr/bin/nmcli",
            "connection", "up",
            (char *)name,
            "--wait", "30",
            NULL
        };
        execv("/usr/bin/nmcli", new_argv);
        fprintf(stderr, "ERROR: failed to execute /usr/bin/nmcli\n");
        _exit(1);
    }

    int status;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        printf("CONNECT:OK\n");
        return 0;
    }

    printf("CONNECT:FAILED:nmcli exited with code %d\n",
           WIFEXITED(status) ? WEXITSTATUS(status) : -1);
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
        fprintf(stderr, "ERROR: usage: wifi-connect-wrapper <connect|connect-saved> [ssid] [password|name]\n");
        return 1;
    }

    const char *action = argv[1];

    if (strcmp(action, "connect") == 0) {
        if (argc != 4) {
            fprintf(stderr, "ERROR: usage: wifi-connect-wrapper connect <ssid> <password>\n");
            return 1;
        }
        return do_connect(argv[2], argv[3]);
    }

    if (strcmp(action, "connect-saved") == 0) {
        if (argc != 3) {
            fprintf(stderr, "ERROR: usage: wifi-connect-wrapper connect-saved <name>\n");
            return 1;
        }
        return do_connect_saved(argv[2]);
    }

    fprintf(stderr, "ERROR: invalid action '%s' — use connect or connect-saved\n", action);
    return 1;
}
