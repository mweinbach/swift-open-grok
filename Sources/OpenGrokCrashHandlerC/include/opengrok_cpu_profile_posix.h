#ifndef OPENGROK_CPU_PROFILE_POSIX_H
#define OPENGROK_CPU_PROFILE_POSIX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OG_CPU_PROFILE_MAX_PATH 4096

enum OGCPUProfileErrorCode {
    OG_CPU_PROFILE_OK = 0,
    OG_CPU_PROFILE_UNSUPPORTED = 1,
    OG_CPU_PROFILE_INVALID_FREQUENCY = 2,
    OG_CPU_PROFILE_ALREADY_ACTIVE = 3,
    OG_CPU_PROFILE_NOT_ACTIVE = 4,
    OG_CPU_PROFILE_INVALID_OUTPUT = 5,
    OG_CPU_PROFILE_OUTPUT_COLLISION = 6,
    OG_CPU_PROFILE_UNSAFE_OUTPUT = 7,
    OG_CPU_PROFILE_SIGNAL_BUSY = 8,
    OG_CPU_PROFILE_SYSTEM_ERROR = 9,
    OG_CPU_PROFILE_NO_SAMPLES = 10,
};

int og_cpu_profile_supported(void);
int og_cpu_profile_active(void);

int og_cpu_profile_start(
    const char *home_directory,
    const char *requested_output,
    int frequency_hz,
    char *output_path,
    size_t output_path_capacity
);

int og_cpu_profile_stop(uint64_t *sample_count);

int og_cpu_profile_last_error_code(void);
const char *og_cpu_profile_last_error_message(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENGROK_CPU_PROFILE_POSIX_H */
