// Portable PTY open + fork/exec child setup (setsid, TIOCSCTTY, chdir).
// Called from OpenGrokPTY because Swift cannot use fork() on Apple platforms.

#ifndef OPENGROK_PTY_SPAWN_H
#define OPENGROK_PTY_SPAWN_H

/* POSIX-only. `pid_t` and <sys/ioctl.h> do not exist in the Windows SDK, so on
 * Windows this target must present an empty module rather than fail to compile
 * — the Swift caller's PTY path is already `#if os(macOS) || os(Linux)` and its
 * `#elseif os(Windows)` arm never reaches these symbols. Cost: the module still
 * imports on Windows and silently exports nothing, so a future Windows PTY
 * implementation must add its own declarations here rather than assume these
 * exist. Without this guard the whole Windows build dies in this header. */
#if !defined(_WIN32)

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Open a PTY pair and optionally set initial winsize. Returns 0 on success
/// (writes master/slave fds), or a positive errno on failure.
int opengrok_open_pty(
    int *master_fd,
    int *slave_fd,
    unsigned short rows,
    unsigned short cols
);

/// Fork + child setup + execve.
///
/// In the child:
///   - if new_session: setsid(); if set_ctty: ioctl(stdin_fd, TIOCSCTTY, 0)
///   - else if new_pgroup: setpgid(0, 0)
///   - if cwd != NULL: chdir(cwd)
///   - dup2 stdin/stdout/stderr, close extras in close_fds
///   - execve(path, argv, envp)
///
/// Returns 0 and sets *out_pid on success, or a positive errno on failure.
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
);

#ifdef __cplusplus
}
#endif

#endif /* !_WIN32 */

#endif /* OPENGROK_PTY_SPAWN_H */
