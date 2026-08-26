#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include "opengrok_cpu_profile_posix.h"

#include <stdio.h>
#include <string.h>

static _Thread_local int og_profile_error = OG_CPU_PROFILE_OK;
static _Thread_local char og_profile_error_text[192];

static int og_profile_fail(int code, const char *message) {
    og_profile_error = code;
    (void)snprintf(
        og_profile_error_text,
        sizeof(og_profile_error_text),
        "%s",
        message != NULL ? message : "CPU profiling failed"
    );
    return code;
}

static int og_profile_succeed(void) {
    og_profile_error = OG_CPU_PROFILE_OK;
    og_profile_error_text[0] = '\0';
    return OG_CPU_PROFILE_OK;
}

int og_cpu_profile_last_error_code(void) {
    return og_profile_error;
}

const char *og_cpu_profile_last_error_message(void) {
    return og_profile_error_text;
}

#if (defined(__APPLE__) || defined(__linux__)) \
    && (defined(__x86_64__) || defined(__aarch64__) || defined(__arm64__))

#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#if defined(__linux__)
#include <ucontext.h>
#endif
#include <unistd.h>

#define OG_PROFILE_MAX_SAMPLES 8192U
#define OG_PROFILE_MAX_FRAMES 32U
#define OG_PROFILE_MAX_FILENAME 255U
#define OG_PROFILE_MAX_SYMBOL 96U
#define OG_PROFILE_MAX_LINE 4096U
#define OG_PROFILE_MAX_ARTIFACT (4U * 1024U * 1024U)
#define OG_PROFILE_PATH_RETRIES 32U
#define OG_PROFILE_MAX_FRAME_GAP (1024U * 1024U)

typedef struct {
    uint32_t depth;
    uintptr_t frames[OG_PROFILE_MAX_FRAMES];
} OGCPUProfileSample;

typedef struct {
    const char *text;
    size_t length;
} OGCPUProfileLine;

typedef struct {
    OGCPUProfileSample *samples;
    int home_fd;
    int profiles_fd;
    int artifact_fd;
    int validation_read_fd;
    int validation_write_fd;
    struct sigaction previous_action;
    struct itimerval previous_timer;
    char filename[OG_PROFILE_MAX_FILENAME + 1U];
} OGCPUProfileState;

static pthread_mutex_t og_profile_lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_flag og_profile_signal_owner = ATOMIC_FLAG_INIT;
static _Atomic uint32_t og_profile_samples_used = 0;
static _Atomic int og_profile_accepting = 0;
static _Atomic int og_profile_running = 0;

static OGCPUProfileState og_profile_state = {
    .samples = NULL,
    .home_fd = -1,
    .profiles_fd = -1,
    .artifact_fd = -1,
    .validation_read_fd = -1,
    .validation_write_fd = -1,
    .filename = {0},
};

/*
 * Upstream: xai-grok-shell-base/src/cpu_profile.rs:559-685. The exact Rust
 * build uses pprof's DWARF unwinder from its SIGPROF handler. Calling an
 * unwinder, allocator, symbol resolver, or Swift runtime in a signal handler
 * cannot meet this port's signal-safety boundary. We instead use pprof's
 * optional validated-frame-pointer strategy (pprof 0.15 addr_validate.rs:
 * 66-105, backtrace/frame_pointer.rs:96-127). Optimized code which omits frame
 * pointers can therefore yield shorter *real* stacks; frames are never invented.
 */
static void og_profile_extract_registers(
    void *context,
    uintptr_t *program_counter,
    uintptr_t *frame_pointer
) {
    *program_counter = 0;
    *frame_pointer = 0;
    if (context == NULL) {
        return;
    }

#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__))
    typedef struct {
        uint64_t registers[29];
        uint64_t fp;
        uint64_t lr;
        uint64_t sp;
        uint64_t pc;
        uint32_t cpsr;
        uint32_t padding;
    } OGArm64ThreadState;
    typedef struct {
        uint8_t exception_state[16];
        OGArm64ThreadState thread_state;
    } OGDarwinMachineContext;
    typedef struct {
        int32_t on_stack;
        uint32_t signal_mask;
        stack_t stack;
        void *link;
        size_t machine_context_size;
        OGDarwinMachineContext *machine_context;
    } OGDarwinUserContext;

    OGDarwinUserContext *user_context = (OGDarwinUserContext *)context;
    if (user_context->machine_context != NULL) {
        *program_counter = (uintptr_t)user_context->machine_context->thread_state.pc;
        *frame_pointer = (uintptr_t)user_context->machine_context->thread_state.fp;
    }
#elif defined(__APPLE__) && defined(__x86_64__)
    typedef struct {
        uint64_t rax, rbx, rcx, rdx, rdi, rsi, rbp, rsp;
        uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
        uint64_t rip, rflags, cs, fs, gs;
    } OGX86ThreadState;
    typedef struct {
        uint8_t exception_state[16];
        OGX86ThreadState thread_state;
    } OGDarwinMachineContext;
    typedef struct {
        int32_t on_stack;
        uint32_t signal_mask;
        stack_t stack;
        void *link;
        size_t machine_context_size;
        OGDarwinMachineContext *machine_context;
    } OGDarwinUserContext;

    OGDarwinUserContext *user_context = (OGDarwinUserContext *)context;
    if (user_context->machine_context != NULL) {
        *program_counter = (uintptr_t)user_context->machine_context->thread_state.rip;
        *frame_pointer = (uintptr_t)user_context->machine_context->thread_state.rbp;
    }
#elif defined(__linux__) && defined(__x86_64__)
    ucontext_t *user_context = (ucontext_t *)context;
    *program_counter = (uintptr_t)user_context->uc_mcontext.gregs[REG_RIP];
    *frame_pointer = (uintptr_t)user_context->uc_mcontext.gregs[REG_RBP];
#elif defined(__linux__) && (defined(__aarch64__) || defined(__arm64__))
    ucontext_t *user_context = (ucontext_t *)context;
    *program_counter = (uintptr_t)user_context->uc_mcontext.pc;
    *frame_pointer = (uintptr_t)user_context->uc_mcontext.regs[29];
#endif
}

/*
 * A kernel copy is both the validation and the read. Unlike validate-then-
 * dereference, there is no second unsafe access after the check: an unmapped
 * frame returns EFAULT from write(2), and its two words are recovered only
 * from our already-open, nonblocking validation pipe.
 */
static int og_profile_copy_frame(uintptr_t address, uintptr_t pair[2]) {
    if (address < 4096U || (address % sizeof(uintptr_t)) != 0U) {
        return 0;
    }

    ssize_t written = write(
        og_profile_state.validation_write_fd,
        (const void *)address,
        sizeof(uintptr_t) * 2U
    );
    if (written != (ssize_t)(sizeof(uintptr_t) * 2U)) {
        return 0;
    }

    ssize_t received = read(
        og_profile_state.validation_read_fd,
        pair,
        sizeof(uintptr_t) * 2U
    );
    return received == (ssize_t)(sizeof(uintptr_t) * 2U);
}

static void og_profile_signal_handler(int signal_number, siginfo_t *information, void *context) {
    (void)signal_number;
    (void)information;
    int original_errno = errno;

    if (!atomic_load_explicit(&og_profile_accepting, memory_order_acquire)) {
        errno = original_errno;
        return;
    }
    if (atomic_flag_test_and_set_explicit(&og_profile_signal_owner, memory_order_acquire)) {
        errno = original_errno;
        return;
    }

    if (atomic_load_explicit(&og_profile_accepting, memory_order_relaxed)) {
        uint32_t index = atomic_load_explicit(&og_profile_samples_used, memory_order_relaxed);
        if (index < OG_PROFILE_MAX_SAMPLES && og_profile_state.samples != NULL) {
            uintptr_t program_counter = 0;
            uintptr_t frame_pointer = 0;
            og_profile_extract_registers(context, &program_counter, &frame_pointer);

            if (program_counter >= 4096U) {
                OGCPUProfileSample *sample = &og_profile_state.samples[index];
                sample->depth = 1;
                sample->frames[0] = program_counter;

                while (sample->depth < OG_PROFILE_MAX_FRAMES) {
                    uintptr_t pair[2] = {0, 0};
                    if (!og_profile_copy_frame(frame_pointer, pair)) {
                        break;
                    }
                    uintptr_t next_frame = pair[0];
                    uintptr_t return_address = pair[1];
                    if (return_address < 4096U) {
                        break;
                    }
                    sample->frames[sample->depth++] = return_address;
                    if (next_frame <= frame_pointer
                        || next_frame - frame_pointer > OG_PROFILE_MAX_FRAME_GAP) {
                        break;
                    }
                    frame_pointer = next_frame;
                }

                atomic_store_explicit(&og_profile_samples_used, index + 1U, memory_order_release);
            }
        }
    }

    atomic_flag_clear_explicit(&og_profile_signal_owner, memory_order_release);
    errno = original_errno;
}

static int og_profile_private_directory(int descriptor) {
    struct stat metadata;
    if (descriptor < 0 || fstat(descriptor, &metadata) != 0) {
        return 0;
    }
    return S_ISDIR(metadata.st_mode)
        && metadata.st_uid == geteuid()
        && (metadata.st_mode & (S_IRWXG | S_IRWXO)) == 0;
}

static int og_profile_open_home(const char *path, char canonical[OG_CPU_PROFILE_MAX_PATH]) {
    if (path == NULL || path[0] != '/') {
        return -1;
    }
    size_t length = strnlen(path, OG_CPU_PROFILE_MAX_PATH);
    if (length < 2U || length >= OG_CPU_PROFILE_MAX_PATH || path[length - 1U] == '/') {
        return -1;
    }

    const char *original_path = path;
    char ancestor_path[OG_CPU_PROFILE_MAX_PATH];
    size_t lexical_cursor = 1U;
    while (lexical_cursor < length) {
        size_t lexical_end = lexical_cursor;
        while (lexical_end < length && path[lexical_end] != '/') {
            if (path[lexical_end] == '\\') {
                return -1;
            }
            lexical_end++;
        }
        size_t component_length = lexical_end - lexical_cursor;
        if (component_length == 0U
            || (component_length == 1U && path[lexical_cursor] == '.')
            || (component_length == 2U
                && path[lexical_cursor] == '.'
                && path[lexical_cursor + 1U] == '.')) {
            return -1;
        }
        if (lexical_end < length) {
            memcpy(ancestor_path, path, lexical_end);
            ancestor_path[lexical_end] = '\0';
            struct stat ancestor;
            if (lstat(ancestor_path, &ancestor) != 0
                || (S_ISLNK(ancestor.st_mode) && ancestor.st_uid != 0)) {
                return -1;
            }
        }
        lexical_cursor = lexical_end + 1U;
    }

    /* Darwin exposes legitimate homes below root-owned /tmp -> /private/tmp.
       User-owned ancestor aliases and aliases for the state root stay refused. */
    struct stat original_root;
    if (lstat(path, &original_root) != 0 || !S_ISDIR(original_root.st_mode)
        || S_ISLNK(original_root.st_mode) || realpath(path, canonical) == NULL) {
        return -1;
    }
    path = canonical;
    length = strnlen(path, OG_CPU_PROFILE_MAX_PATH);
    if (length < 2U || length >= OG_CPU_PROFILE_MAX_PATH) {
        return -1;
    }

    int directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) {
        return -1;
    }

    size_t cursor = 1U;
    while (cursor < length) {
        if (path[cursor] == '/') {
            close(directory);
            return -1;
        }
        size_t end = cursor;
        while (end < length && path[end] != '/') {
            if (path[end] == '\\') {
                close(directory);
                return -1;
            }
            end++;
        }

        size_t component_length = end - cursor;
        if (component_length == 0U || component_length > OG_PROFILE_MAX_FILENAME) {
            close(directory);
            return -1;
        }
        char component[OG_PROFILE_MAX_FILENAME + 1U];
        memcpy(component, path + cursor, component_length);
        component[component_length] = '\0';
        if (strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
            close(directory);
            return -1;
        }

        int next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int saved_errno = errno;
        close(directory);
        if (next < 0) {
            errno = saved_errno;
            return -1;
        }
        directory = next;
        cursor = end + 1U;
    }

    struct stat opened_root;
    struct stat unchanged_original;
    struct stat unchanged_root;
    if (!og_profile_private_directory(directory)
        || fstat(directory, &opened_root) != 0
        || lstat(original_path, &unchanged_original) != 0
        || lstat(path, &unchanged_root) != 0
        || original_root.st_dev != opened_root.st_dev
        || original_root.st_ino != opened_root.st_ino
        || opened_root.st_dev != unchanged_original.st_dev
        || opened_root.st_ino != unchanged_original.st_ino
        || opened_root.st_dev != unchanged_root.st_dev
        || opened_root.st_ino != unchanged_root.st_ino) {
        close(directory);
        errno = EACCES;
        return -1;
    }
    return directory;
}

static int og_profile_open_profiles(int home_descriptor) {
    if (mkdirat(home_descriptor, "profiles", 0700) != 0 && errno != EEXIST) {
        return -1;
    }
    int profiles = openat(
        home_descriptor,
        "profiles",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    );
    if (profiles < 0) {
        return -1;
    }
    if (!og_profile_private_directory(profiles)) {
        close(profiles);
        errno = EACCES;
        return -1;
    }
    return profiles;
}

static int og_profile_safe_basename(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return 0;
    }
    size_t length = strnlen(name, OG_PROFILE_MAX_FILENAME + 1U);
    if (length == 0U || length > OG_PROFILE_MAX_FILENAME
        || strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        return 0;
    }
    for (size_t index = 0; index < length; index++) {
        unsigned char value = (unsigned char)name[index];
        if (!(isalnum(value) || value == '_' || value == '-' || value == '.')) {
            return 0;
        }
    }
    return 1;
}

static int og_profile_timestamp(char *output, size_t capacity) {
    struct timespec instant;
    if (clock_gettime(CLOCK_REALTIME, &instant) != 0) {
        return -1;
    }
    struct tm calendar;
    if (gmtime_r(&instant.tv_sec, &calendar) == NULL) {
        return -1;
    }
    char seconds[32];
    if (strftime(seconds, sizeof(seconds), "%Y%m%dT%H%M%S", &calendar) == 0U) {
        return -1;
    }
    int count = snprintf(
        output,
        capacity,
        "%s.%06ldZ",
        seconds,
        (long)(instant.tv_nsec / 1000L)
    );
    return count < 0 || (size_t)count >= capacity ? -1 : 0;
}

static int og_profile_build_name(
    const char *requested,
    const char *timestamp,
    unsigned int attempt,
    char *filename,
    size_t capacity,
    int *is_explicit
) {
    const char *base = requested == NULL ? "leader" : requested;
    if (!og_profile_safe_basename(base)) {
        return -1;
    }

    const char *extension = strrchr(base, '.');
    if (requested != NULL && extension != NULL
        && (strcasecmp(extension, ".folded") == 0 || strcasecmp(extension, ".txt") == 0)) {
        *is_explicit = 1;
        int count = snprintf(filename, capacity, "%s", base);
        return count < 0 || (size_t)count >= capacity ? -1 : 0;
    }
    if (requested != NULL && extension != NULL && strcasecmp(extension, ".svg") == 0) {
        *is_explicit = 1;
        size_t prefix_length = (size_t)(extension - base);
        int count = snprintf(filename, capacity, "%.*s.folded", (int)prefix_length, base);
        return count < 0 || (size_t)count >= capacity ? -1 : 0;
    }

    *is_explicit = 0;
    int count;
    if (attempt == 0U) {
        count = snprintf(filename, capacity, "%s-%ld-%s.folded", base, (long)getpid(), timestamp);
    } else {
        count = snprintf(
            filename,
            capacity,
            "%s-%ld-%s-%02u.folded",
            base,
            (long)getpid(),
            timestamp,
            attempt
        );
    }
    return count < 0 || (size_t)count >= capacity ? -1 : 0;
}

static int og_profile_create_pipe(int descriptors[2]) {
#if defined(__linux__)
    if (pipe2(descriptors, O_CLOEXEC | O_NONBLOCK) != 0) {
        return -1;
    }
#else
    if (pipe(descriptors) != 0) {
        return -1;
    }
    for (int index = 0; index < 2; index++) {
        int status = fcntl(descriptors[index], F_GETFL, 0);
        int descriptor_flags = fcntl(descriptors[index], F_GETFD, 0);
        if (status < 0 || descriptor_flags < 0
            || fcntl(descriptors[index], F_SETFL, status | O_NONBLOCK) != 0
            || fcntl(descriptors[index], F_SETFD, descriptor_flags | FD_CLOEXEC) != 0) {
            close(descriptors[0]);
            close(descriptors[1]);
            descriptors[0] = -1;
            descriptors[1] = -1;
            return -1;
        }
    }
#endif
    return 0;
}

static int og_profile_previous_signal_is_safe(const struct sigaction *action) {
    return action->sa_handler == SIG_DFL || action->sa_handler == SIG_IGN;
}

static int og_profile_timer_is_active(const struct itimerval *timer) {
    return timer->it_interval.tv_sec != 0 || timer->it_interval.tv_usec != 0
        || timer->it_value.tv_sec != 0 || timer->it_value.tv_usec != 0;
}

static void og_profile_release_resources(int remove_artifact) {
    if (remove_artifact && og_profile_state.profiles_fd >= 0 && og_profile_state.filename[0] != '\0') {
        (void)unlinkat(og_profile_state.profiles_fd, og_profile_state.filename, 0);
    }
    if (og_profile_state.artifact_fd >= 0) {
        close(og_profile_state.artifact_fd);
    }
    if (og_profile_state.validation_read_fd >= 0) {
        close(og_profile_state.validation_read_fd);
    }
    if (og_profile_state.validation_write_fd >= 0) {
        close(og_profile_state.validation_write_fd);
    }
    if (og_profile_state.profiles_fd >= 0) {
        close(og_profile_state.profiles_fd);
    }
    if (og_profile_state.home_fd >= 0) {
        close(og_profile_state.home_fd);
    }
    free(og_profile_state.samples);
    og_profile_state.samples = NULL;
    og_profile_state.home_fd = -1;
    og_profile_state.profiles_fd = -1;
    og_profile_state.artifact_fd = -1;
    og_profile_state.validation_read_fd = -1;
    og_profile_state.validation_write_fd = -1;
    og_profile_state.filename[0] = '\0';
    atomic_store_explicit(&og_profile_samples_used, 0, memory_order_release);
}

int og_cpu_profile_supported(void) {
    return atomic_is_lock_free(&og_profile_samples_used)
        && atomic_is_lock_free(&og_profile_accepting)
        && atomic_is_lock_free(&og_profile_running);
}

int og_cpu_profile_active(void) {
    return atomic_load_explicit(&og_profile_running, memory_order_acquire);
}

int og_cpu_profile_start(
    const char *home_directory,
    const char *requested_output,
    int frequency_hz,
    char *output_path,
    size_t output_path_capacity
) {
    if (output_path != NULL && output_path_capacity > 0U) {
        output_path[0] = '\0';
    }
    if (!og_cpu_profile_supported()) {
        return og_profile_fail(OG_CPU_PROFILE_UNSUPPORTED, "runtime CPU profiling is unavailable");
    }
    if (frequency_hz < 1 || frequency_hz > 4000) {
        return og_profile_fail(OG_CPU_PROFILE_INVALID_FREQUENCY, "CPU profile frequency must be between 1 and 4000 Hz");
    }
    if (output_path == NULL || output_path_capacity == 0U) {
        return og_profile_fail(OG_CPU_PROFILE_INVALID_OUTPUT, "CPU profile output buffer is invalid");
    }
    if (requested_output != NULL && !og_profile_safe_basename(requested_output)) {
        return og_profile_fail(OG_CPU_PROFILE_INVALID_OUTPUT, "CPU profile output must be one safe relative filename");
    }

    pthread_mutex_lock(&og_profile_lifecycle_lock);
    if (atomic_load_explicit(&og_profile_running, memory_order_acquire)) {
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_ALREADY_ACTIVE, "a CPU profile is already active");
    }

    struct sigaction previous_action;
    struct itimerval previous_timer;
    if (sigaction(SIGPROF, NULL, &previous_action) != 0 || getitimer(ITIMER_PROF, &previous_timer) != 0) {
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not inspect the process CPU profiling signal");
    }
    if (!og_profile_previous_signal_is_safe(&previous_action) || og_profile_timer_is_active(&previous_timer)) {
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SIGNAL_BUSY, "the process CPU profiling signal or timer is already owned");
    }

    char canonical_home[OG_CPU_PROFILE_MAX_PATH];
    int home = og_profile_open_home(home_directory, canonical_home);
    if (home < 0) {
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_UNSAFE_OUTPUT, "CPU profile home must be a private owner-only directory without symlinks");
    }
    int profiles = og_profile_open_profiles(home);
    if (profiles < 0) {
        close(home);
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_UNSAFE_OUTPUT, "CPU profile directory must be private, owner-only, and not a symlink");
    }

    char timestamp[48];
    if (og_profile_timestamp(timestamp, sizeof(timestamp)) != 0) {
        close(profiles);
        close(home);
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not create a CPU profile timestamp");
    }

    char filename[OG_PROFILE_MAX_FILENAME + 1U];
    int artifact = -1;
    int explicit_output = 0;
    for (unsigned int attempt = 0; attempt < OG_PROFILE_PATH_RETRIES; attempt++) {
        if (og_profile_build_name(
                requested_output,
                timestamp,
                attempt,
                filename,
                sizeof(filename),
                &explicit_output
            ) != 0) {
            close(profiles);
            close(home);
            pthread_mutex_unlock(&og_profile_lifecycle_lock);
            return og_profile_fail(OG_CPU_PROFILE_INVALID_OUTPUT, "CPU profile output filename is too long");
        }

        int path_length = snprintf(output_path, output_path_capacity, "%s/profiles/%s", canonical_home, filename);
        if (path_length < 0 || (size_t)path_length >= output_path_capacity
            || (size_t)path_length >= OG_CPU_PROFILE_MAX_PATH) {
            output_path[0] = '\0';
            close(profiles);
            close(home);
            pthread_mutex_unlock(&og_profile_lifecycle_lock);
            return og_profile_fail(OG_CPU_PROFILE_INVALID_OUTPUT, "CPU profile output path exceeds its bounded capacity");
        }

        artifact = openat(
            profiles,
            filename,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0600
        );
        if (artifact >= 0) {
            break;
        }
        if (errno != EEXIST || explicit_output) {
            int collision = errno == EEXIST;
            output_path[0] = '\0';
            close(profiles);
            close(home);
            pthread_mutex_unlock(&og_profile_lifecycle_lock);
            return og_profile_fail(
                collision ? OG_CPU_PROFILE_OUTPUT_COLLISION : OG_CPU_PROFILE_UNSAFE_OUTPUT,
                collision ? "CPU profile output already exists" : "could not securely reserve CPU profile output"
            );
        }
    }
    if (artifact < 0) {
        output_path[0] = '\0';
        close(profiles);
        close(home);
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_OUTPUT_COLLISION, "could not reserve a unique CPU profile output");
    }

    og_profile_state.home_fd = home;
    og_profile_state.profiles_fd = profiles;
    og_profile_state.artifact_fd = artifact;
    memcpy(og_profile_state.filename, filename, strlen(filename) + 1U);

    struct stat artifact_metadata;
    if (fchmod(artifact, 0600) != 0 || fstat(artifact, &artifact_metadata) != 0
        || !S_ISREG(artifact_metadata.st_mode)
        || artifact_metadata.st_uid != geteuid()
        || artifact_metadata.st_nlink != 1
        || (artifact_metadata.st_mode & 0777) != 0600) {
        og_profile_release_resources(1);
        output_path[0] = '\0';
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_UNSAFE_OUTPUT, "CPU profile artifact could not be made owner-private");
    }

    og_profile_state.samples = calloc(OG_PROFILE_MAX_SAMPLES, sizeof(OGCPUProfileSample));
    if (og_profile_state.samples == NULL) {
        og_profile_release_resources(1);
        output_path[0] = '\0';
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not allocate bounded CPU profile sample storage");
    }

    int validation_pipe[2] = {-1, -1};
    if (og_profile_create_pipe(validation_pipe) != 0) {
        og_profile_release_resources(1);
        output_path[0] = '\0';
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not create the signal-safe CPU profile validation pipe");
    }
    og_profile_state.validation_read_fd = validation_pipe[0];
    og_profile_state.validation_write_fd = validation_pipe[1];
    og_profile_state.previous_action = previous_action;
    og_profile_state.previous_timer = previous_timer;
    atomic_store_explicit(&og_profile_samples_used, 0, memory_order_release);
    atomic_flag_clear_explicit(&og_profile_signal_owner, memory_order_release);

    struct sigaction handler;
    memset(&handler, 0, sizeof(handler));
    handler.sa_sigaction = og_profile_signal_handler;
    handler.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&handler.sa_mask);
    if (sigaction(SIGPROF, &handler, NULL) != 0) {
        og_profile_release_resources(1);
        output_path[0] = '\0';
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not install the CPU profiling signal handler");
    }

    atomic_store_explicit(&og_profile_accepting, 1, memory_order_release);
    struct itimerval interval;
    memset(&interval, 0, sizeof(interval));
    long microseconds = 1000000L / frequency_hz;
    interval.it_interval.tv_sec = microseconds / 1000000L;
    interval.it_interval.tv_usec = microseconds % 1000000L;
    interval.it_value = interval.it_interval;
    if (setitimer(ITIMER_PROF, &interval, NULL) != 0) {
        atomic_store_explicit(&og_profile_accepting, 0, memory_order_release);
        (void)sigaction(SIGPROF, &previous_action, NULL);
        og_profile_release_resources(1);
        output_path[0] = '\0';
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not start the process CPU profiling timer");
    }

    atomic_store_explicit(&og_profile_running, 1, memory_order_release);
    pthread_mutex_unlock(&og_profile_lifecycle_lock);
    return og_profile_succeed();
}

static int og_profile_compare_samples(const void *left_value, const void *right_value) {
    const OGCPUProfileSample *left = (const OGCPUProfileSample *)left_value;
    const OGCPUProfileSample *right = (const OGCPUProfileSample *)right_value;
    uint32_t shared = left->depth < right->depth ? left->depth : right->depth;
    for (uint32_t index = 0; index < shared; index++) {
        if (left->frames[index] < right->frames[index]) {
            return -1;
        }
        if (left->frames[index] > right->frames[index]) {
            return 1;
        }
    }
    return left->depth < right->depth ? -1 : (left->depth > right->depth ? 1 : 0);
}

static int og_profile_compare_lines(const void *left_value, const void *right_value) {
    const OGCPUProfileLine *left = (const OGCPUProfileLine *)left_value;
    const OGCPUProfileLine *right = (const OGCPUProfileLine *)right_value;
    return strcmp(left->text, right->text);
}

static void og_profile_symbol(uintptr_t address, char *destination, size_t capacity) {
    Dl_info info;
    if (dladdr((const void *)address, &info) != 0
        && info.dli_sname != NULL
        && info.dli_sname[0] != '\0') {
        size_t cursor = 0;
        while (cursor + 1U < capacity
            && cursor < OG_PROFILE_MAX_SYMBOL
            && info.dli_sname[cursor] != '\0') {
            unsigned char value = (unsigned char)info.dli_sname[cursor];
            destination[cursor] = (value <= 32U || value == 127U || value == ';')
                ? '_'
                : (char)value;
            cursor++;
        }
        destination[cursor] = '\0';
        return;
    }
    (void)snprintf(destination, capacity, "0x%" PRIxPTR, address);
}

static int og_profile_output_still_safe(void) {
    if (!og_profile_private_directory(og_profile_state.home_fd)
        || !og_profile_private_directory(og_profile_state.profiles_fd)) {
        return 0;
    }

    struct stat pinned_directory;
    struct stat current_directory;
    if (fstat(og_profile_state.profiles_fd, &pinned_directory) != 0
        || fstatat(og_profile_state.home_fd, "profiles", &current_directory, AT_SYMLINK_NOFOLLOW) != 0
        || !S_ISDIR(current_directory.st_mode)
        || pinned_directory.st_dev != current_directory.st_dev
        || pinned_directory.st_ino != current_directory.st_ino) {
        return 0;
    }

    struct stat pinned_artifact;
    struct stat current_artifact;
    return fstat(og_profile_state.artifact_fd, &pinned_artifact) == 0
        && fstatat(
            og_profile_state.profiles_fd,
            og_profile_state.filename,
            &current_artifact,
            AT_SYMLINK_NOFOLLOW
        ) == 0
        && S_ISREG(current_artifact.st_mode)
        && pinned_artifact.st_nlink == 1
        && current_artifact.st_nlink == 1
        && pinned_artifact.st_dev == current_artifact.st_dev
        && pinned_artifact.st_ino == current_artifact.st_ino
        && pinned_artifact.st_uid == geteuid()
        && (pinned_artifact.st_mode & 0777) == 0600;
}

static int og_profile_write_all(int descriptor, const char *bytes, size_t count) {
    size_t offset = 0;
    unsigned int interrupted = 0;
    while (offset < count) {
        ssize_t written = write(descriptor, bytes + offset, count - offset);
        if (written < 0) {
            if (errno == EINTR && interrupted++ < 8U) {
                continue;
            }
            return -1;
        }
        if (written == 0) {
            return -1;
        }
        offset += (size_t)written;
    }
    return 0;
}

static int og_profile_render_artifact(uint32_t count) {
    qsort(og_profile_state.samples, count, sizeof(OGCPUProfileSample), og_profile_compare_samples);

    char *storage = malloc(OG_PROFILE_MAX_ARTIFACT);
    OGCPUProfileLine *lines = calloc(count, sizeof(OGCPUProfileLine));
    if (storage == NULL || lines == NULL) {
        free(storage);
        free(lines);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not allocate bounded CPU profile artifact storage");
    }

    size_t storage_used = 0;
    size_t line_count = 0;
    uint32_t cursor = 0;
    while (cursor < count) {
        uint32_t end = cursor + 1U;
        while (end < count
            && og_profile_compare_samples(&og_profile_state.samples[cursor], &og_profile_state.samples[end]) == 0) {
            end++;
        }

        char line[OG_PROFILE_MAX_LINE];
        int used = snprintf(line, sizeof(line), "process-%ld", (long)getpid());
        if (used < 0 || (size_t)used >= sizeof(line)) {
            free(storage);
            free(lines);
            return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not encode a CPU profile stack");
        }

        const OGCPUProfileSample *sample = &og_profile_state.samples[cursor];
        for (uint32_t index = sample->depth; index > 0U; index--) {
            char symbol[224];
            og_profile_symbol(sample->frames[index - 1U], symbol, sizeof(symbol));
            int added = snprintf(line + used, sizeof(line) - (size_t)used, ";%s", symbol);
            if (added < 0 || (size_t)added >= sizeof(line) - (size_t)used) {
                free(storage);
                free(lines);
                return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "CPU profile stack exceeds its bounded capacity");
            }
            used += added;
        }

        int added = snprintf(line + used, sizeof(line) - (size_t)used, " %" PRIu32 "\n", end - cursor);
        if (added < 0 || (size_t)added >= sizeof(line) - (size_t)used) {
            free(storage);
            free(lines);
            return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not encode a CPU profile sample count");
        }
        used += added;
        size_t required = (size_t)used + 1U;
        if (storage_used > OG_PROFILE_MAX_ARTIFACT - required) {
            free(storage);
            free(lines);
            return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "CPU profile artifact exceeds its bounded capacity");
        }
        memcpy(storage + storage_used, line, required);
        lines[line_count].text = storage + storage_used;
        lines[line_count].length = (size_t)used;
        line_count++;
        storage_used += required;
        cursor = end;
    }

    qsort(lines, line_count, sizeof(OGCPUProfileLine), og_profile_compare_lines);
    int success = 1;
    for (size_t index = 0; index < line_count; index++) {
        if (og_profile_write_all(og_profile_state.artifact_fd, lines[index].text, lines[index].length) != 0) {
            success = 0;
            break;
        }
    }
    if (success && fsync(og_profile_state.artifact_fd) != 0) {
        success = 0;
    }
    if (success && fsync(og_profile_state.profiles_fd) != 0) {
        success = 0;
    }

    free(storage);
    free(lines);
    return success
        ? OG_CPU_PROFILE_OK
        : og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not persist the owner-private CPU profile artifact");
}

int og_cpu_profile_stop(uint64_t *sample_count) {
    if (sample_count != NULL) {
        *sample_count = 0;
    }

    pthread_mutex_lock(&og_profile_lifecycle_lock);
    if (!atomic_load_explicit(&og_profile_running, memory_order_acquire)) {
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_NOT_ACTIVE, "no CPU profile is active");
    }

    atomic_store_explicit(&og_profile_accepting, 0, memory_order_release);
    struct itimerval disabled;
    memset(&disabled, 0, sizeof(disabled));
    if (setitimer(ITIMER_PROF, &disabled, NULL) != 0) {
        atomic_store_explicit(&og_profile_accepting, 1, memory_order_release);
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not stop the process CPU profiling timer");
    }

    struct sigaction ignored;
    memset(&ignored, 0, sizeof(ignored));
    ignored.sa_handler = SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    if (sigaction(SIGPROF, &ignored, NULL) != 0) {
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not drain pending CPU profiling signals");
    }

    int acquired_signal_owner = 0;
    for (unsigned int attempt = 0; attempt < 1000U; attempt++) {
        if (!atomic_flag_test_and_set_explicit(&og_profile_signal_owner, memory_order_acquire)) {
            acquired_signal_owner = 1;
            break;
        }
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000L};
        (void)nanosleep(&delay, NULL);
    }
    if (!acquired_signal_owner) {
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "an in-flight CPU profile sample did not stop in time");
    }

    if (sigaction(SIGPROF, &og_profile_state.previous_action, NULL) != 0
        || setitimer(ITIMER_PROF, &og_profile_state.previous_timer, NULL) != 0) {
        atomic_flag_clear_explicit(&og_profile_signal_owner, memory_order_release);
        pthread_mutex_unlock(&og_profile_lifecycle_lock);
        return og_profile_fail(OG_CPU_PROFILE_SYSTEM_ERROR, "could not restore the previous CPU profiling signal state");
    }

    uint32_t count = atomic_load_explicit(&og_profile_samples_used, memory_order_acquire);
    if (sample_count != NULL) {
        *sample_count = count;
    }

    int result;
    int remove_artifact = 0;
    if (!og_profile_output_still_safe()) {
        result = og_profile_fail(OG_CPU_PROFILE_UNSAFE_OUTPUT, "the CPU profile output authority changed while profiling");
        /* A replaced final name does not belong to us and must not be removed. */
    } else if (count == 0U) {
        remove_artifact = 1;
        result = og_profile_fail(OG_CPU_PROFILE_NO_SAMPLES, "CPU profiling stopped before a real execution sample was collected");
    } else {
        result = og_profile_render_artifact(count);
        remove_artifact = result != OG_CPU_PROFILE_OK;
    }

    og_profile_release_resources(remove_artifact);
    atomic_store_explicit(&og_profile_running, 0, memory_order_release);
    atomic_flag_clear_explicit(&og_profile_signal_owner, memory_order_release);
    pthread_mutex_unlock(&og_profile_lifecycle_lock);
    return result == OG_CPU_PROFILE_OK ? og_profile_succeed() : result;
}

#else

int og_cpu_profile_supported(void) {
    return 0;
}

int og_cpu_profile_active(void) {
    return 0;
}

int og_cpu_profile_start(
    const char *home_directory,
    const char *requested_output,
    int frequency_hz,
    char *output_path,
    size_t output_path_capacity
) {
    (void)home_directory;
    (void)requested_output;
    (void)frequency_hz;
    if (output_path != NULL && output_path_capacity > 0U) {
        output_path[0] = '\0';
    }
    return og_profile_fail(
        OG_CPU_PROFILE_UNSUPPORTED,
        "runtime CPU profiling is not supported on this platform"
    );
}

int og_cpu_profile_stop(uint64_t *sample_count) {
    if (sample_count != NULL) {
        *sample_count = 0;
    }
    return og_profile_fail(
        OG_CPU_PROFILE_UNSUPPORTED,
        "runtime CPU profiling is not supported on this platform"
    );
}

#endif
