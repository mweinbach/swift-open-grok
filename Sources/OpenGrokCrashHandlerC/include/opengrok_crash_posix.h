// Async-signal-safe crash capture (sigaction + alternate stack + GCRX blob).

#ifndef OPENGROK_CRASH_POSIX_H
#define OPENGROK_CRASH_POSIX_H

#ifdef __cplusplus
extern "C" {
#endif

/// Install SIGSEGV/SIGBUS handlers that write a GCRX blob to `crash_file_path`
/// (opened owner-only by this function) and re-raise with default disposition.
/// Returns 1 on success, 0 on failure.
int opengrok_crash_install(const char *crash_file_path, const char *app_version);

/// Install using a caller-owned, already-open file descriptor (secure openat
/// path). The descriptor is adopted (closed by the signal path / reinstall).
/// Returns 1 on success, 0 on failure.
int opengrok_crash_install_fd(int crash_fd, const char *app_version);

/// Minimal install: termios restore only (no crash blob).
void opengrok_crash_install_terminal_restore_only(void);

/// Upgrade handlers to also write terminal escape restore sequences.
void opengrok_crash_enable_terminal_escape_restore(void);

/// Downgrade handlers to termios-only restoration (blob still written if installed).
void opengrok_crash_disable_terminal_escape_restore(void);

/// True if a full crash blob install is currently active.
int opengrok_crash_is_installed(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENGROK_CRASH_POSIX_H */
