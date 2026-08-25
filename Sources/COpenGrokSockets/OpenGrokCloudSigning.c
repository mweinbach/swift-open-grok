#include "OpenGrokCloudSigning.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    OG_CLOUD_SIGN_MAX_KEY_BYTES = 64 * 1024,
    OG_CLOUD_SIGN_MAX_MESSAGE_BYTES = 1024 * 1024,
    OG_CLOUD_SIGN_MIN_RSA_BITS = 2048,
    OG_CLOUD_SIGN_MAX_RSA_BITS = 8192,
};

static _Thread_local char og_cloud_sign_error_message[192];

static int og_cloud_sign_error(const char *message) {
    snprintf(
        og_cloud_sign_error_message,
        sizeof(og_cloud_sign_error_message),
        "%s",
        message == NULL ? "cloud signing failed" : message
    );
    return -1;
}

const char *og_cloud_sign_last_error_message(void) {
    return og_cloud_sign_error_message;
}

static int og_cloud_sign_validate(
    const void *pkcs8_der,
    size_t key_length,
    const void *message,
    size_t message_length,
    size_t *signature_length
) {
    og_cloud_sign_error_message[0] = '\0';

    if (pkcs8_der == NULL || key_length == 0
        || key_length > OG_CLOUD_SIGN_MAX_KEY_BYTES) {
        return og_cloud_sign_error("invalid PKCS#8 signing key");
    }
    if (message == NULL || message_length == 0
        || message_length > OG_CLOUD_SIGN_MAX_MESSAGE_BYTES) {
        return og_cloud_sign_error("invalid cloud signing payload");
    }
    if (signature_length == NULL) {
        return og_cloud_sign_error("missing cloud signing output length");
    }
    return 0;
}

#if defined(__linux__)

typedef struct evp_pkey_st EVP_PKEY;
typedef struct evp_pkey_ctx_st EVP_PKEY_CTX;
typedef struct evp_md_ctx_st EVP_MD_CTX;
typedef struct evp_md_st EVP_MD;
typedef struct engine_st ENGINE;

extern EVP_PKEY *d2i_AutoPrivateKey(
    EVP_PKEY **key,
    const unsigned char **input,
    long length
);
extern int EVP_PKEY_get_base_id(const EVP_PKEY *key);
extern int EVP_PKEY_get_bits(const EVP_PKEY *key);
extern void EVP_PKEY_free(EVP_PKEY *key);
extern EVP_MD_CTX *EVP_MD_CTX_new(void);
extern void EVP_MD_CTX_free(EVP_MD_CTX *context);
extern const EVP_MD *EVP_sha256(void);
extern int EVP_DigestSignInit(
    EVP_MD_CTX *context,
    EVP_PKEY_CTX **key_context,
    const EVP_MD *digest,
    ENGINE *engine,
    EVP_PKEY *key
);
extern int EVP_PKEY_CTX_set_rsa_padding(EVP_PKEY_CTX *context, int padding);
extern int EVP_DigestSignUpdate(
    EVP_MD_CTX *context,
    const void *message,
    size_t length
);
extern int EVP_DigestSignFinal(
    EVP_MD_CTX *context,
    unsigned char *signature,
    size_t *length
);
extern void OPENSSL_cleanse(void *pointer, size_t length);

enum {
    OG_OPENSSL_RSA_KEY_TYPE = 6,
    OG_OPENSSL_RSA_PKCS1_PADDING = 1,
};

int og_cloud_sign_rsa_sha256(
    const void *pkcs8_der,
    size_t key_length,
    const void *message,
    size_t message_length,
    unsigned char *signature,
    size_t *signature_length
) {
    if (og_cloud_sign_validate(
        pkcs8_der,
        key_length,
        message,
        message_length,
        signature_length
    ) != 0) return -1;

    const unsigned char *bytes = pkcs8_der;
    const unsigned char *cursor = bytes;
    EVP_PKEY *key = d2i_AutoPrivateKey(NULL, &cursor, (long)key_length);
    if (key == NULL || cursor != bytes + key_length) {
        if (key != NULL) EVP_PKEY_free(key);
        return og_cloud_sign_error("could not decode the PKCS#8 signing key");
    }

    int key_bits = EVP_PKEY_get_bits(key);
    if (EVP_PKEY_get_base_id(key) != OG_OPENSSL_RSA_KEY_TYPE
        || key_bits < OG_CLOUD_SIGN_MIN_RSA_BITS
        || key_bits > OG_CLOUD_SIGN_MAX_RSA_BITS) {
        EVP_PKEY_free(key);
        return og_cloud_sign_error("cloud signing requires a 2048-8192 bit RSA key");
    }

    EVP_MD_CTX *context = EVP_MD_CTX_new();
    if (context == NULL) {
        EVP_PKEY_free(key);
        return og_cloud_sign_error("could not allocate the cloud signing context");
    }

    int result = -1;
    EVP_PKEY_CTX *key_context = NULL;
    if (EVP_DigestSignInit(context, &key_context, EVP_sha256(), NULL, key) != 1
        || key_context == NULL
        || EVP_PKEY_CTX_set_rsa_padding(
            key_context,
            OG_OPENSSL_RSA_PKCS1_PADDING
        ) != 1
        || EVP_DigestSignUpdate(context, message, message_length) != 1) {
        og_cloud_sign_error("could not initialize RSA-SHA256 cloud signing");
        goto cleanup;
    }

    size_t required = 0;
    if (EVP_DigestSignFinal(context, NULL, &required) != 1
        || required == 0
        || required > OG_CLOUD_SIGN_MAX_RSA_BITS / CHAR_BIT) {
        og_cloud_sign_error("could not determine the RSA signature length");
        goto cleanup;
    }

    if (signature == NULL) {
        *signature_length = required;
        result = 0;
        goto cleanup;
    }
    if (*signature_length < required) {
        *signature_length = required;
        og_cloud_sign_error("cloud signing output buffer is too small");
        goto cleanup;
    }

    size_t written = required;
    if (EVP_DigestSignFinal(context, signature, &written) != 1
        || written != required) {
        OPENSSL_cleanse(signature, required);
        og_cloud_sign_error("RSA-SHA256 cloud signing failed");
        goto cleanup;
    }

    *signature_length = written;
    result = 0;

cleanup:
    EVP_MD_CTX_free(context);
    EVP_PKEY_free(key);
    return result;
}

#elif defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <ncrypt.h>

static int og_cloud_sign_windows_error(
    const char *operation,
    SECURITY_STATUS status
) {
    snprintf(
        og_cloud_sign_error_message,
        sizeof(og_cloud_sign_error_message),
        "%s (Windows error 0x%08lx)",
        operation,
        (unsigned long)(uint32_t)status
    );
    return -1;
}

int og_cloud_sign_rsa_sha256(
    const void *pkcs8_der,
    size_t key_length,
    const void *message,
    size_t message_length,
    unsigned char *signature,
    size_t *signature_length
) {
    if (og_cloud_sign_validate(
        pkcs8_der,
        key_length,
        message,
        message_length,
        signature_length
    ) != 0) return -1;

    NCRYPT_PROV_HANDLE provider = 0;
    NCRYPT_KEY_HANDLE key = 0;
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    unsigned char digest[32] = {0};
    SECURITY_STATUS status;
    int result = -1;

    status = NCryptOpenStorageProvider(&provider, MS_KEY_STORAGE_PROVIDER, 0);
    if (status != ERROR_SUCCESS) {
        og_cloud_sign_windows_error("could not open the Windows key provider", status);
        goto cleanup;
    }

    status = NCryptImportKey(
        provider,
        0,
        NCRYPT_PKCS8_PRIVATE_KEY_BLOB,
        NULL,
        &key,
        (PBYTE)pkcs8_der,
        (DWORD)key_length,
        0
    );
    if (status != ERROR_SUCCESS) {
        og_cloud_sign_windows_error("could not import the PKCS#8 signing key", status);
        goto cleanup;
    }

    wchar_t key_algorithm[16] = {0};
    DWORD property_length = 0;
    status = NCryptGetProperty(
        key,
        NCRYPT_ALGORITHM_PROPERTY,
        (PBYTE)key_algorithm,
        (DWORD)sizeof(key_algorithm),
        &property_length,
        0
    );
    if (status != ERROR_SUCCESS || property_length < sizeof(wchar_t)
        || property_length > sizeof(key_algorithm)
        || key_algorithm[property_length / sizeof(wchar_t) - 1] != L'\0'
        || wcscmp(key_algorithm, BCRYPT_RSA_ALGORITHM) != 0) {
        og_cloud_sign_error("cloud signing requires an RSA private key");
        goto cleanup;
    }

    DWORD key_bits = 0;
    property_length = 0;
    status = NCryptGetProperty(
        key,
        NCRYPT_LENGTH_PROPERTY,
        (PBYTE)&key_bits,
        (DWORD)sizeof(key_bits),
        &property_length,
        0
    );
    if (status != ERROR_SUCCESS || property_length != sizeof(key_bits)
        || key_bits < OG_CLOUD_SIGN_MIN_RSA_BITS
        || key_bits > OG_CLOUD_SIGN_MAX_RSA_BITS) {
        og_cloud_sign_error("cloud signing requires a 2048-8192 bit RSA key");
        goto cleanup;
    }

    status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0);
    if (status != ERROR_SUCCESS) {
        og_cloud_sign_windows_error("could not open the SHA-256 provider", status);
        goto cleanup;
    }
    status = BCryptCreateHash(algorithm, &hash, NULL, 0, NULL, 0, 0);
    if (status != ERROR_SUCCESS) {
        og_cloud_sign_windows_error("could not initialize SHA-256 cloud signing", status);
        goto cleanup;
    }
    status = BCryptHashData(hash, (PUCHAR)message, (ULONG)message_length, 0);
    if (status != ERROR_SUCCESS) {
        og_cloud_sign_windows_error("could not hash the cloud signing payload", status);
        goto cleanup;
    }
    status = BCryptFinishHash(hash, digest, (ULONG)sizeof(digest), 0);
    if (status != ERROR_SUCCESS) {
        og_cloud_sign_windows_error("could not finalize the cloud signing digest", status);
        goto cleanup;
    }

    BCRYPT_PKCS1_PADDING_INFO padding = {.pszAlgId = BCRYPT_SHA256_ALGORITHM};
    DWORD required = 0;
    status = NCryptSignHash(
        key,
        &padding,
        digest,
        (DWORD)sizeof(digest),
        NULL,
        0,
        &required,
        BCRYPT_PAD_PKCS1
    );
    if (status != ERROR_SUCCESS || required == 0
        || required > OG_CLOUD_SIGN_MAX_RSA_BITS / CHAR_BIT) {
        og_cloud_sign_windows_error("could not determine the RSA signature length", status);
        goto cleanup;
    }

    if (signature == NULL) {
        *signature_length = required;
        result = 0;
        goto cleanup;
    }
    if (*signature_length < required) {
        *signature_length = required;
        og_cloud_sign_error("cloud signing output buffer is too small");
        goto cleanup;
    }

    DWORD written = 0;
    status = NCryptSignHash(
        key,
        &padding,
        digest,
        (DWORD)sizeof(digest),
        signature,
        required,
        &written,
        BCRYPT_PAD_PKCS1
    );
    if (status != ERROR_SUCCESS || written != required) {
        SecureZeroMemory(signature, required);
        og_cloud_sign_windows_error("RSA-SHA256 cloud signing failed", status);
        goto cleanup;
    }

    *signature_length = written;
    result = 0;

cleanup:
    SecureZeroMemory(digest, sizeof(digest));
    if (hash != NULL) BCryptDestroyHash(hash);
    if (algorithm != NULL) BCryptCloseAlgorithmProvider(algorithm, 0);
    if (key != 0) NCryptFreeObject(key);
    if (provider != 0) NCryptFreeObject(provider);
    return result;
}

#else

int og_cloud_sign_rsa_sha256(
    const void *pkcs8_der,
    size_t key_length,
    const void *message,
    size_t message_length,
    unsigned char *signature,
    size_t *signature_length
) {
    (void)signature;
    if (og_cloud_sign_validate(
        pkcs8_der,
        key_length,
        message,
        message_length,
        signature_length
    ) != 0) return -1;
    return og_cloud_sign_error("native cloud signing is unavailable on this platform");
}

#endif
