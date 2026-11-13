#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Spawns `path` attached to a freshly allocated pseudo-terminal.
///
/// The child becomes a session leader whose controlling terminal is the PTY
/// slave, with signal dispositions reset to their defaults and every file
/// descriptor above stderr closed before exec.
///
/// @return the PTY master file descriptor (non-blocking, close-on-exec), or -1
///         with errno set on failure. The child's pid is written to `out_pid`.
int sp_pty_spawn(const char *path,
                 char *const argv[],
                 char *const envp[],
                 const char *cwd,
                 unsigned short rows,
                 unsigned short cols,
                 pid_t *out_pid);

/// Informs the kernel (and therefore the foreground process group, via SIGWINCH)
/// of a new window size. Returns 0 on success, -1 on failure.
int sp_pty_resize(int master_fd, unsigned short rows, unsigned short cols);

/// Non-blocking reap. Returns the child's pid once it has exited and stores the
/// raw wait status in `status`; returns 0 while it is still running; -1 on error.
pid_t sp_pty_reap(pid_t pid, int *status);

/// Blocking reap (retries on EINTR). Returns the raw wait status, or -1 on error.
int sp_pty_wait(pid_t pid);

/// Exit code (0-255) if the status describes a normal exit, otherwise 128+signal.
int sp_pty_exit_code(int status);

/// Name of the foreground process attached to the terminal (e.g. "vim"), written
/// into `buf`. Returns 0 on success, -1 if it cannot be determined.
int sp_pty_foreground_name(int master_fd, char *buf, int buflen);

/// Current working directory of process `pid`, written into `buf`.
/// Returns 0 on success, -1 if it cannot be determined.
int sp_process_cwd(pid_t pid, char *buf, int buflen);

#ifdef __cplusplus
}
#endif

#endif
