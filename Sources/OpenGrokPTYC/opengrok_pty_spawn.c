// Portable PTY open + fork/exec with session / controlling-terminal / CWD setup.

/* glibc hides posix_openpt/grantpt/unlockpt/ptsname behind __USE_XOPEN2K,
   which SwiftPM's default C dialect does not request; without this they
   compile as implicit int-returning functions and ptsname's char* result is
   truncated to an int. Must precede every other include. Apple's headers
   declare them unconditionally. */
#if !defined(__APPLE__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include "opengrok_pty_spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

/* TIOCSCTTY / TIOCSWINSZ: present via sys/ioctl.h on Linux; on Apple may need ttycom. */
#if defined(__APPLE__)
#include <sys/ttycom.h>
#endif

int opengrok_open_pty(
    int *master_fd,
    int *slave_fd,
    unsigned short rows,
    unsigned short cols
) {
    if (master_fd == NULL || slave_fd == NULL) {
        return EINVAL;
    }

    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) {
        return errno ? errno : EIO;
    }
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        int err = errno ? errno : EIO;
        close(master);
        return err;
    }

    char *name = ptsname(master);
    if (name == NULL) {
        int err = errno ? errno : EIO;
        close(master);
        return err;
    }

    int slave = open(name, O_RDWR | O_NOCTTY);
    if (slave < 0) {
        int err = errno ? errno : EIO;
        close(master);
        return err;
    }

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;
#ifdef TIOCSWINSZ
    (void)ioctl(master, TIOCSWINSZ, &ws);
#else
    (void)rows;
    (void)cols;
#endif

    *master_fd = master;
    *slave_fd = slave;
    return 0;
}

int opengrok_spawn_with_fds(
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *cwd,
    int stdin_fd,
    int stdout_fd,
    int stderr_fd,
    const int *close_fds,
    size_t close_fds_count,
    int new_session,
    int set_ctty,
    int new_pgroup,
    pid_t *out_pid
) {
    if (path == NULL || argv == NULL || envp == NULL || out_pid == NULL) {
        return EINVAL;
    }

    int ready_pipe[2];
    if (pipe(ready_pipe) != 0) {
        return errno ? errno : EIO;
    }

    pid_t pid = fork();
    if (pid < 0) {
        int err = errno ? errno : EAGAIN;
        close(ready_pipe[0]);
        close(ready_pipe[1]);
        return err;
    }

    if (pid == 0) {
        /* ---- child ---- */
        close(ready_pipe[0]);
        int setup_error = 0;
        if (new_session) {
            if (setsid() < 0) {
                setup_error = errno ? errno : EPERM;
            }
            if (setup_error == 0 && set_ctty && stdin_fd >= 0) {
#ifdef TIOCSCTTY
                if (ioctl(stdin_fd, TIOCSCTTY, 0) != 0) {
                    setup_error = errno ? errno : EIO;
                }
#endif
            }
        } else if (new_pgroup) {
            if (setpgid(0, 0) != 0) {
                setup_error = errno ? errno : EPERM;
            }
        }

        sigset_t empty_mask;
        if (sigemptyset(&empty_mask) != 0
            || sigprocmask(SIG_SETMASK, &empty_mask, NULL) != 0) {
            setup_error = errno ? errno : EIO;
        }

        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGTSTP, SIG_DFL);
        signal(SIGTTIN, SIG_DFL);
        signal(SIGTTOU, SIG_DFL);

        ssize_t written;
        do {
            written = write(ready_pipe[1], &setup_error, sizeof(setup_error));
        } while (written < 0 && errno == EINTR);
        close(ready_pipe[1]);
        if (written != (ssize_t)sizeof(setup_error) || setup_error != 0) {
            _exit(127);
        }

        if (cwd != NULL && cwd[0] != '\0') {
            if (chdir(cwd) != 0) {
                _exit(127);
            }
        }

        if (stdin_fd >= 0) {
            if (dup2(stdin_fd, STDIN_FILENO) < 0) {
                _exit(127);
            }
        }
        if (stdout_fd >= 0) {
            if (dup2(stdout_fd, STDOUT_FILENO) < 0) {
                _exit(127);
            }
        }
        if (stderr_fd >= 0) {
            if (dup2(stderr_fd, STDERR_FILENO) < 0) {
                _exit(127);
            }
        }

        if (stdin_fd > STDERR_FILENO) {
            close(stdin_fd);
        }
        if (stdout_fd > STDERR_FILENO && stdout_fd != stdin_fd) {
            close(stdout_fd);
        }
        if (stderr_fd > STDERR_FILENO && stderr_fd != stdin_fd && stderr_fd != stdout_fd) {
            close(stderr_fd);
        }

        if (close_fds != NULL) {
            for (size_t i = 0; i < close_fds_count; i++) {
                int fd = close_fds[i];
                if (fd > STDERR_FILENO) {
                    close(fd);
                }
            }
        }

        execve(path, argv, envp);
        _exit(127);
    }

    close(ready_pipe[1]);
    int setup_error = EIO;
    ssize_t received;
    do {
        received = read(ready_pipe[0], &setup_error, sizeof(setup_error));
    } while (received < 0 && errno == EINTR);
    close(ready_pipe[0]);
    if (received != (ssize_t)sizeof(setup_error) || setup_error != 0) {
        if (setup_error == 0) {
            setup_error = EIO;
        }
        (void)kill(pid, SIGKILL);
        (void)waitpid(pid, NULL, 0);
        return setup_error;
    }

    *out_pid = pid;
    return 0;
}
