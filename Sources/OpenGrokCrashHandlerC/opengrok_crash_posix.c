// Async-signal-safe crash capture. Mirrors xai-crash-handler handler.rs.
// Only async-signal-safe libc calls in signal context.

// glibc hides the `REG_RIP`/`REG_RBP` gregs indices behind __USE_GNU, which is
// only set when _GNU_SOURCE is defined *before* the first system header. Without
// it the x86_64 Linux PC/FP extraction below fails to compile — and it fails
// only on x86_64 Linux, so an arm64 Linux build stays green and hides it.
// Cost: this must stay above every #include in this file. Moving it below one
// silently reverts to the broken state on exactly one platform.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

/* POSIX-only (<sys/mman.h>, sigaction, termios). The Swift caller's every use
   of these symbols is already `#if os(macOS) || os(Linux)` with a Windows arm
   that reports the handler as uninstalled, so on Windows this file compiles to
   a placeholder rather than failing the build. The header stays unguarded: it
   declares only int/char* signatures, and declarations nothing calls are
   harmless. */
#if defined(_WIN32)

int opengrok_crash_unavailable_on_windows(void);
int opengrok_crash_unavailable_on_windows(void) { return 0; }

#else

#include "opengrok_crash_posix.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* GCRX layout constants (must match CrashBlobFormat in Swift). */
#define OG_MAGIC0 0x47
#define OG_MAGIC1 0x43
#define OG_MAGIC2 0x52
#define OG_MAGIC3 0x58
#define OG_VERSION 1
#define OG_MAX_FRAMES 64
#define OG_VERSION_LEN 32
#define OG_HEADER_SIZE (4 + 1 + 1 + 4 + 8 + 4 + 8 + 2 + OG_VERSION_LEN)
#define OG_MAX_FILE_SIZE (OG_HEADER_SIZE + OG_MAX_FRAMES * 8)

#define OG_ALT_STACK_SIZE (16 * 1024)

static volatile sig_atomic_t g_crash_fd = -1;
static volatile sig_atomic_t g_has_termios = 0;
static volatile sig_atomic_t g_terminal_escape_restore = 0;
static volatile sig_atomic_t g_installed = 0;
static volatile sig_atomic_t g_alt_stack_installed = 0;

static struct termios g_original_termios;
static unsigned char g_app_version[OG_VERSION_LEN];
static unsigned char g_crash_buf[OG_MAX_FILE_SIZE];
static unsigned char g_restore_seq[] =
    "\033[?2026l\033[?25h\033[?1000l\033[?1002l\033[?1003l\033[?1015l\033[?1006l"
    "\033[?2004l\033[?1004l\033[<u\033[?1049l";

/* ---- little-endian writers (signal-safe) ---- */

static size_t write_u16_le(unsigned char *buf, size_t off, uint16_t v) {
    buf[off] = (unsigned char)(v & 0xff);
    buf[off + 1] = (unsigned char)((v >> 8) & 0xff);
    return off + 2;
}

static size_t write_u32_le(unsigned char *buf, size_t off, uint32_t v) {
    for (int i = 0; i < 4; i++) {
        buf[off + (size_t)i] = (unsigned char)((v >> (8 * i)) & 0xff);
    }
    return off + 4;
}

static size_t write_i32_le(unsigned char *buf, size_t off, int32_t v) {
    return write_u32_le(buf, off, (uint32_t)v);
}

static size_t write_u64_le(unsigned char *buf, size_t off, uint64_t v) {
    for (int i = 0; i < 8; i++) {
        buf[off + (size_t)i] = (unsigned char)((v >> (8 * i)) & 0xff);
    }
    return off + 8;
}

/* `fault_addr` carries siginfo_t's si_addr but cannot be named that: glibc
   defines si_addr as an object-like macro expanding to a _sifields member
   access, so any identifier with that spelling is rewritten mid-declaration. */
static size_t write_header(
    unsigned char *buf,
    uint8_t sig,
    int32_t si_code,
    uint64_t fault_addr,
    uint32_t pid,
    uint64_t timestamp,
    uint16_t n_frames
) {
    size_t off = 0;
    buf[off++] = OG_MAGIC0;
    buf[off++] = OG_MAGIC1;
    buf[off++] = OG_MAGIC2;
    buf[off++] = OG_MAGIC3;
    buf[off++] = OG_VERSION;
    buf[off++] = sig;
    off = write_i32_le(buf, off, si_code);
    off = write_u64_le(buf, off, fault_addr);
    off = write_u32_le(buf, off, pid);
    off = write_u64_le(buf, off, timestamp);
    off = write_u16_le(buf, off, n_frames);
    for (int i = 0; i < OG_VERSION_LEN; i++) {
        buf[off++] = g_app_version[i];
    }
    return off;
}

/* ---- PC / FP extraction ---- */

static void extract_pc_fp(void *ctx, uintptr_t *out_pc, uintptr_t *out_fp) {
    *out_pc = 0;
    *out_fp = 0;
    if (ctx == NULL) {
        return;
    }

#if defined(__APPLE__) && defined(__aarch64__)
    typedef struct {
        uint64_t regs[29];
        uint64_t fp;
        uint64_t lr;
        uint64_t sp;
        uint64_t pc;
        uint32_t cpsr;
        uint32_t pad;
    } Arm64ThreadState;
    typedef struct {
        uint8_t es[16];
        Arm64ThreadState ss;
    } MachMcontext;
    typedef struct {
        int32_t onstack;
        uint32_t sigmask;
        stack_t stack;
        void *link;
        size_t mcsize;
        MachMcontext *mctx;
    } DarwinUcontext;
    DarwinUcontext *uc = (DarwinUcontext *)ctx;
    if (uc->mctx != NULL) {
        *out_pc = (uintptr_t)uc->mctx->ss.pc;
        *out_fp = (uintptr_t)uc->mctx->ss.fp;
    }
#elif defined(__APPLE__) && defined(__x86_64__)
    typedef struct {
        uint64_t rax, rbx, rcx, rdx, rdi, rsi, rbp, rsp;
        uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
        uint64_t rip, rflags, cs, fs, gs;
    } X86ThreadState;
    typedef struct {
        uint8_t es[16];
        X86ThreadState ss;
    } MachMcontext;
    typedef struct {
        int32_t onstack;
        uint32_t sigmask;
        stack_t stack;
        void *link;
        size_t mcsize;
        MachMcontext *mctx;
    } DarwinUcontext;
    DarwinUcontext *uc = (DarwinUcontext *)ctx;
    if (uc->mctx != NULL) {
        *out_pc = (uintptr_t)uc->mctx->ss.rip;
        *out_fp = (uintptr_t)uc->mctx->ss.rbp;
    }
#elif defined(__linux__) && defined(__x86_64__)
    ucontext_t *uc = (ucontext_t *)ctx;
    *out_pc = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
    *out_fp = (uintptr_t)uc->uc_mcontext.gregs[REG_RBP];
#elif defined(__linux__) && defined(__aarch64__)
    ucontext_t *uc = (ucontext_t *)ctx;
    *out_pc = (uintptr_t)uc->uc_mcontext.pc;
    *out_fp = (uintptr_t)uc->uc_mcontext.regs[29];
#else
    (void)ctx;
#endif
}

static size_t walk_frame_pointers(uintptr_t initial_fp, uintptr_t *out, size_t max) {
    uintptr_t fp = initial_fp;
    size_t count = 0;
    while (count < max) {
        if (fp == 0 || fp < 4096 || (fp % sizeof(uintptr_t)) != 0) {
            break;
        }
        uintptr_t prev_fp = *(uintptr_t *)fp;
        uintptr_t ret_addr = *(uintptr_t *)(fp + sizeof(uintptr_t));
        if (ret_addr == 0 || ret_addr < 4096) {
            break;
        }
        out[count++] = ret_addr;
        if (prev_fp <= fp) {
            break;
        }
        fp = prev_fp;
    }
    return count;
}

static void restore_termios_and_reraise(int sig) {
    if (g_has_termios) {
        (void)tcsetattr(STDIN_FILENO, TCSANOW, &g_original_termios);
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, NULL);
    raise(sig);
}

static void restore_terminal_escape(void) {
    if (g_terminal_escape_restore) {
        (void)write(STDERR_FILENO, g_restore_seq, sizeof(g_restore_seq) - 1);
    }
}

static void write_crash_blob(int sig, siginfo_t *info, void *ctx) {
    int fd = (int)g_crash_fd;
    if (fd < 0) {
        return;
    }

    int32_t si_code = 0;
    uint64_t fault_addr = 0;
    if (info != NULL) {
        si_code = info->si_code;
#if defined(__APPLE__) || defined(__linux__)
        fault_addr = (uint64_t)(uintptr_t)info->si_addr;
#endif
    }

    uint32_t pid = (uint32_t)getpid();
    uint64_t timestamp = (uint64_t)time(NULL);

    uintptr_t frames[OG_MAX_FRAMES];
    memset(frames, 0, sizeof(frames));
    uint16_t n_frames = 0;

    uintptr_t crash_pc = 0;
    uintptr_t crash_fp = 0;
    extract_pc_fp(ctx, &crash_pc, &crash_fp);
    if (crash_pc != 0) {
        frames[0] = crash_pc;
        n_frames = 1;
    }

    size_t offset = write_header(
        g_crash_buf,
        (uint8_t)sig,
        si_code,
        fault_addr,
        pid,
        timestamp,
        n_frames
    );
    for (uint16_t i = 0; i < n_frames; i++) {
        offset = write_u64_le(g_crash_buf, offset, (uint64_t)frames[i]);
    }
    (void)write(fd, g_crash_buf, offset);

    /* Best-effort frame walk; SA_RESETHAND protects against recursive faults. */
    if (crash_fp != 0 && crash_pc != 0 && n_frames < OG_MAX_FRAMES) {
        size_t walked = walk_frame_pointers(
            crash_fp,
            &frames[1],
            (size_t)(OG_MAX_FRAMES - 1)
        );
        if (walked > 0) {
            n_frames = (uint16_t)(1 + walked);
            offset = write_header(
                g_crash_buf,
                (uint8_t)sig,
                si_code,
                fault_addr,
                pid,
                timestamp,
                n_frames
            );
            for (uint16_t i = 0; i < n_frames; i++) {
                offset = write_u64_le(g_crash_buf, offset, (uint64_t)frames[i]);
            }
            (void)lseek(fd, 0, SEEK_SET);
            (void)write(fd, g_crash_buf, offset);
        }
    }

    g_crash_fd = -1;
    close(fd);
}

static void crash_handler(int sig, siginfo_t *info, void *ctx) {
    /* Bound handler runtime so a wedged write cannot hang forever. */
    alarm(3);
    write_crash_blob(sig, info, ctx);
    restore_terminal_escape();
    restore_termios_and_reraise(sig);
}

static void terminal_restore_handler(int sig, siginfo_t *info, void *ctx) {
    (void)info;
    (void)ctx;
    restore_terminal_escape();
    restore_termios_and_reraise(sig);
}

static void save_termios(void) {
    if (tcgetattr(STDIN_FILENO, &g_original_termios) == 0) {
        g_has_termios = 1;
    }
}

static void setup_alt_stack(void) {
    if (g_alt_stack_installed) {
        return;
    }
    void *stack_mem = mmap(
        NULL,
        OG_ALT_STACK_SIZE,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON,
        -1,
        0
    );
    if (stack_mem == MAP_FAILED) {
        return;
    }
    stack_t ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp = stack_mem;
    ss.ss_size = OG_ALT_STACK_SIZE;
    ss.ss_flags = 0;
    if (sigaltstack(&ss, NULL) == 0) {
        g_alt_stack_installed = 1;
    }
}

static void register_crash_signals(void (*handler)(int, siginfo_t *, void *)) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}

int opengrok_crash_install_fd(int crash_fd, const char *app_version) {
    if (crash_fd < 0) {
        return 0;
    }
    if (fchmod(crash_fd, 0600) != 0) {
        close(crash_fd);
        return 0;
    }

    if (g_crash_fd >= 0) {
        close((int)g_crash_fd);
    }
    g_crash_fd = crash_fd;

    memset(g_app_version, 0, sizeof(g_app_version));
    if (app_version != NULL) {
        size_t n = strlen(app_version);
        if (n > OG_VERSION_LEN) {
            n = OG_VERSION_LEN;
        }
        memcpy(g_app_version, app_version, n);
    }

    save_termios();
    setup_alt_stack();
    register_crash_signals(crash_handler);
    g_installed = 1;
    return 1;
}

int opengrok_crash_install(const char *crash_file_path, const char *app_version) {
    if (crash_file_path == NULL) {
        return 0;
    }

    int fd = open(crash_file_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        return 0;
    }
    return opengrok_crash_install_fd(fd, app_version);
}

void opengrok_crash_install_terminal_restore_only(void) {
    save_termios();
    setup_alt_stack();
    register_crash_signals(terminal_restore_handler);
}

void opengrok_crash_enable_terminal_escape_restore(void) {
    g_terminal_escape_restore = 1;
    if (g_installed) {
        register_crash_signals(crash_handler);
    } else {
        register_crash_signals(terminal_restore_handler);
    }
}

void opengrok_crash_disable_terminal_escape_restore(void) {
    g_terminal_escape_restore = 0;
    if (g_installed) {
        register_crash_signals(crash_handler);
    } else {
        register_crash_signals(terminal_restore_handler);
    }
}

int opengrok_crash_is_installed(void) {
    return g_installed ? 1 : 0;
}

#endif /* !_WIN32 */
