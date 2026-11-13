#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#include <libproc.h>
#else
#include <pty.h>
#include <stdio.h>
#endif

static void sp_child_reset_signals(void) {
    // Ignored signals stay ignored across exec(); a GUI process commonly ignores
    // SIGPIPE, which would silently break pipelines in the shell. Reset everything.
    for (int sig = 1; sig < NSIG; sig++) {
        if (sig == SIGKILL || sig == SIGSTOP) continue;
        signal(sig, SIG_DFL);
    }
    sigset_t set;
    sigemptyset(&set);
    sigprocmask(SIG_SETMASK, &set, NULL);
}

static void sp_child_close_fds(void) {
    long max = sysconf(_SC_OPEN_MAX);
    if (max < 0 || max > 4096) max = 4096;
    for (int fd = 3; fd < max; fd++) close(fd);
}

int sp_pty_spawn(const char *path,
                 char *const argv[],
                 char *const envp[],
                 const char *cwd,
                 unsigned short rows,
                 unsigned short cols,
                 pid_t *out_pid) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_row = rows ? rows : 24;
    ws.ws_col = cols ? cols : 80;

    struct termios tio;
    memset(&tio, 0, sizeof tio);
    // Sensible cooked-mode defaults; the shell's line editor will adjust these.
    tio.c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT;
#ifdef IUTF8
    tio.c_iflag |= IUTF8;
#endif
    tio.c_oflag = OPOST | ONLCR;
    tio.c_cflag = CREAD | CS8 | HUPCL;
    tio.c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;
    tio.c_cc[VEOF] = 4;      // ^D
    tio.c_cc[VEOL] = 255;
    tio.c_cc[VERASE] = 0x7f; // DEL
    tio.c_cc[VWERASE] = 23;  // ^W
    tio.c_cc[VKILL] = 21;    // ^U
    tio.c_cc[VREPRINT] = 18; // ^R
    tio.c_cc[VINTR] = 3;     // ^C
    tio.c_cc[VQUIT] = 0x1c;  // FS, i.e. Ctrl+Backslash
    tio.c_cc[VSUSP] = 26;    // ^Z
    tio.c_cc[VSTART] = 17;   // ^Q
    tio.c_cc[VSTOP] = 19;    // ^S
    tio.c_cc[VLNEXT] = 22;   // ^V
    tio.c_cc[VDISCARD] = 15; // ^O
    tio.c_cc[VMIN] = 1;
    tio.c_cc[VTIME] = 0;
    cfsetispeed(&tio, B38400);
    cfsetospeed(&tio, B38400);

    int master = -1;
    pid_t pid = forkpty(&master, NULL, &tio, &ws);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // Child: only async-signal-safe calls from here on.
        sp_child_reset_signals();
        sp_child_close_fds();
        if (cwd && cwd[0]) {
            if (chdir(cwd) != 0) {
                // Fall back silently; the shell will start in the inherited cwd.
            }
        }
        execve(path, argv, envp);
        // exec failed — report through the terminal itself and bail out.
        const char msg[] = "\r\nSidePanel: unable to start shell\r\n";
        write(STDERR_FILENO, msg, sizeof msg - 1);
        _exit(127);
    }

    int flags = fcntl(master, F_GETFL);
    if (flags >= 0) fcntl(master, F_SETFL, flags | O_NONBLOCK);
    fcntl(master, F_SETFD, FD_CLOEXEC);

    if (out_pid) *out_pid = pid;
    return master;
}

int sp_pty_resize(int master_fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_row = rows;
    ws.ws_col = cols;
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}

pid_t sp_pty_reap(pid_t pid, int *status) {
    int st = 0;
    pid_t r;
    do {
        r = waitpid(pid, &st, WNOHANG);
    } while (r < 0 && errno == EINTR);
    if (r > 0 && status) *status = st;
    return r;
}

int sp_pty_wait(pid_t pid) {
    int st = 0;
    pid_t r;
    do {
        r = waitpid(pid, &st, 0);
    } while (r < 0 && errno == EINTR);
    return r < 0 ? -1 : st;
}

int sp_pty_exit_code(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

int sp_pty_foreground_name(int master_fd, char *buf, int buflen) {
    if (!buf || buflen <= 1) return -1;
    pid_t pgrp = tcgetpgrp(master_fd);
    if (pgrp <= 0) return -1;
#if defined(__APPLE__)
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pgrp, path, sizeof path) <= 0) return -1;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    strncpy(buf, base, (size_t)buflen - 1);
    buf[buflen - 1] = 0;
    return 0;
#else
    char procpath[64];
    snprintf(procpath, sizeof procpath, "/proc/%d/comm", (int)pgrp);
    int fd = open(procpath, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, (size_t)buflen - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    char *nl = strchr(buf, '\n');
    if (nl) *nl = 0;
    return 0;
#endif
}

int sp_process_cwd(pid_t pid, char *buf, int buflen) {
    if (!buf || buflen <= 1 || pid <= 0) return -1;
#if defined(__APPLE__)
    struct proc_vnodepathinfo vpi;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof vpi);
    if (n != (int)sizeof vpi) return -1;
    strncpy(buf, vpi.pvi_cdir.vip_path, (size_t)buflen - 1);
    buf[buflen - 1] = 0;
    return buf[0] ? 0 : -1;
#else
    char procpath[64];
    snprintf(procpath, sizeof procpath, "/proc/%d/cwd", (int)pid);
    ssize_t n = readlink(procpath, buf, (size_t)buflen - 1);
    if (n <= 0) return -1;
    buf[n] = 0;
    return 0;
#endif
}
