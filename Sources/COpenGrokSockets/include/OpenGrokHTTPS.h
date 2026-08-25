#ifndef OPENGROK_HTTPS_H
#define OPENGROK_HTTPS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef intptr_t OGHTTPSHandle;

#define OG_HTTPS_INVALID ((OGHTTPSHandle)0)

enum {
    OG_HTTPS_FAILURE_UNREACHABLE = 1,
    OG_HTTPS_FAILURE_INTERRUPTED = 2,
    OG_HTTPS_FAILURE_PERMANENT = 3,
    OG_HTTPS_FAILURE_CANCELLED = 4,
};

typedef int (*OGHTTPSMetadataCallback)(
    void *context,
    long status_code,
    const char *effective_url,
    const unsigned char *headers,
    size_t header_length
);

typedef int (*OGHTTPSBodyCallback)(
    void *context,
    const unsigned char *bytes,
    size_t length
);

OGHTTPSHandle og_https_create(void);
int og_https_set_url(OGHTTPSHandle handle, const char *url);
int og_https_set_method(OGHTTPSHandle handle, const char *method);
int og_https_set_body(OGHTTPSHandle handle, const void *body, size_t length);
int og_https_add_header(OGHTTPSHandle handle, const char *name, const char *value);
int og_https_set_user_agent(OGHTTPSHandle handle, const char *user_agent);
int og_https_set_timeouts(
    OGHTTPSHandle handle,
    double connect_seconds,
    double request_seconds
);
int og_https_set_minimum_tls(OGHTTPSHandle handle, int version);
int og_https_set_proxy(
    OGHTTPSHandle handle,
    const char *host,
    uint16_t port,
    const char *username,
    const char *password
);
int og_https_add_root_der(OGHTTPSHandle handle, const void *certificate, size_t length);
int og_https_set_trust_bundle(OGHTTPSHandle handle, const void *bundle, size_t length);
int og_https_perform(
    OGHTTPSHandle handle,
    void *context,
    OGHTTPSMetadataCallback metadata_callback,
    OGHTTPSBodyCallback body_callback
);
void og_https_cancel(OGHTTPSHandle handle);
void og_https_destroy(OGHTTPSHandle handle);
int og_https_last_error_code(void);
int og_https_last_error_kind(void);
const char *og_https_last_error_message(void);

#ifdef __cplusplus
}
#endif

#endif
