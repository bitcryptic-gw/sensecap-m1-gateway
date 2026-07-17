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
    /* ── Step 1: delete any existing profile with this SSID name ─────────── */
    {
        pid_t pid = fork();
        if (pid == -1) {
            fprintf(stderr, "ERROR: fork failed\n");
            return 1;
        }
        if (pid == 0) {
            setgroups(0, NULL);
            setgid(0);
            setuid(0);
            char *del_argv[] = {
                "/usr/bin/nmcli",
                "connection", "delete",
                (char *)ssid,
                NULL
            };
            execv("/usr/bin/nmcli", del_argv);
            _exit(1);
        }
        int status;
        waitpid(pid, &status, 0);
        /* Ignore exit code — expected to fail if no prior profile exists */
    }

    /* ── Step 2: create the connection profile ──────────────────────────── */
    {
        pid_t pid = fork();
        if (pid == -1) {
            fprintf(stderr, "ERROR: fork failed\n");
            return 1;
        }
        if (pid == 0) {
            setgroups(0, NULL);
            setgid(0);
            setuid(0);

            int has_password = password && password[0] != '\0';

            if (has_password) {
                char *add_argv[] = {
                    "/usr/bin/nmcli",
                    "connection", "add",
                    "type", "wifi",
                    "con-name", (char *)ssid,
                    "ssid", (char *)ssid,
                    "wifi-sec.key-mgmt", "wpa-psk",
                    "wifi-sec.psk", (char *)password,
                    NULL
                };
                execv("/usr/bin/nmcli", add_argv);
            } else {
                char *add_argv[] = {
                    "/usr/bin/nmcli",
                    "connection", "add",
                    "type", "wifi",
                    "con-name", (char *)ssid,
                    "ssid", (char *)ssid,
                    "wifi-sec.key-mgmt", "none",
                    NULL
                };
                execv("/usr/bin/nmcli", add_argv);
            }
            fprintf(stderr, "ERROR: failed to execute /usr/bin/nmcli\n");
            _exit(1);
        }

        int status;
        waitpid(pid, &status, 0);

        if (!(WIFEXITED(status) && WEXITSTATUS(status) == 0)) {
            printf("CONNECT:FAILED:profile creation failed (nmcli exit %d)\n",
                   WIFEXITED(status) ? WEXITSTATUS(status) : -1);
            return 1;
        }
    }

    /* ── Step 3: bring the profile up ──────────────────────────────────── */
    {
        pid_t pid = fork();
        if (pid == -1) {
            fprintf(stderr, "ERROR: fork failed\n");
            return 1;
        }
        if (pid == 0) {
            setgroups(0, NULL);
            setgid(0);
            setuid(0);

            char *up_argv[] = {
                "/usr/bin/nmcli",
                "--wait", "30",
                "connection", "up",
                (char *)ssid,
                NULL
            };
            execv("/usr/bin/nmcli", up_argv);
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
	    "--wait", "30",
            "connection", "up",
            (char *)name,
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

static int do_forget(const char *name) {
    pid_t pid = fork();
    if (pid == -1) {
        fprintf(stderr, "ERROR: fork failed\n");
        return 1;
    }

    if (pid == 0) {
        setgroups(0, NULL);
        setgid(0);
        setuid(0);

        char *del_argv[] = {
            "/usr/bin/nmcli",
            "connection", "delete",
            (char *)name,
            NULL
        };
        execv("/usr/bin/nmcli", del_argv);
        fprintf(stderr, "ERROR: failed to execute /usr/bin/nmcli\n");
        _exit(1);
    }

    int status;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        printf("FORGET:OK\n");
        return 0;
    }

    printf("FORGET:FAILED:nmcli exited with code %d\n",
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

    if (strcmp(action, "forget") == 0) {
        if (argc != 3) {
            fprintf(stderr, "ERROR: usage: wifi-connect-wrapper forget <name>\n");
            return 1;
        }
        return do_forget(argv[2]);
    }

    fprintf(stderr, "ERROR: invalid action '%s' — use connect, connect-saved, or forget\n", action);
    return 1;
}
