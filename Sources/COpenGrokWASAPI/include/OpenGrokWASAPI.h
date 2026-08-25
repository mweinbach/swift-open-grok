#ifndef OPENGROK_WASAPI_H
#define OPENGROK_WASAPI_H

#include <stddef.h>
#include <stdint.h>

typedef void (*OGWASAPIAudioCallback)(
    const uint8_t *bytes,
    size_t length,
    int is_silence,
    void *context
);

typedef void (*OGWASAPIErrorCallback)(
    int32_t status,
    const char *detail,
    void *context
);

typedef void (*OGWASAPIContextRelease)(void *context);

int og_wasapi_is_available(void);

int og_wasapi_probe(
    int include_format,
    char *device_name,
    size_t device_name_capacity,
    char *device_detail,
    size_t device_detail_capacity,
    int32_t *status
);

/* Ownership of context transfers to this call even when startup fails. */
int og_wasapi_start(
    uint32_t sample_rate,
    OGWASAPIAudioCallback audio_callback,
    OGWASAPIErrorCallback error_callback,
    OGWASAPIContextRelease release_context,
    void *context,
    int64_t *session,
    int32_t *status
);

int og_wasapi_stop(int64_t session, uint32_t timeout_milliseconds, int32_t *status);
void og_wasapi_destroy(int64_t session);

int32_t og_wasapi_last_error_code(void);
const char *og_wasapi_last_error_message(void);

#endif
