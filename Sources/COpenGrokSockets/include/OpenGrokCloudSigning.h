#ifndef OPENGROK_CLOUD_SIGNING_H
#define OPENGROK_CLOUD_SIGNING_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int og_cloud_sign_rsa_sha256(
    const void *pkcs8_der,
    size_t key_length,
    const void *message,
    size_t message_length,
    unsigned char *signature,
    size_t *signature_length
);

const char *og_cloud_sign_last_error_message(void);

#ifdef __cplusplus
}
#endif

#endif
