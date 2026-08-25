#include "OpenGrokSockets.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Thread_local int og_tls_error_code;
static _Thread_local char og_tls_error_message[256];

static void og_tls_set_error(int code, const char *message) {
    og_tls_error_code = code;
    snprintf(
        og_tls_error_message,
        sizeof(og_tls_error_message),
        "%s",
        message ? message : "secure socket operation failed"
    );
}

int og_tls_last_error_code(void) {
    return og_tls_error_code;
}

const char *og_tls_last_error_message(void) {
    return og_tls_error_message;
}

#if defined(__linux__)

#include <curl/curl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/socket.h>

typedef struct {
    CURL *easy;
    curl_socket_t socket;
    pthread_mutex_t operation_lock;
    _Atomic int closed;
} OGTLSConnection;

static pthread_once_t og_tls_curl_once = PTHREAD_ONCE_INIT;
static CURLcode og_tls_curl_initialization = CURLE_FAILED_INIT;

static void og_tls_initialize_curl(void) {
    og_tls_curl_initialization = curl_global_init(CURL_GLOBAL_DEFAULT);
}

static void og_tls_set_curl_error(CURLcode code) {
    og_tls_set_error((int)code, curl_easy_strerror(code));
}

static int og_tls_set_option(CURLcode code) {
    if (code == CURLE_OK) return 0;
    og_tls_set_curl_error(code);
    return -1;
}

int og_tls_connect(
    const char *url,
    double timeout_seconds,
    const void *trusted_pem_bundle,
    size_t trusted_pem_bundle_length,
    OGTLSHandle *handle
) {
    if (!url || !handle || !(timeout_seconds > 0.0)
        || timeout_seconds > (double)(LONG_MAX / 1000)
        || (trusted_pem_bundle_length > 0 && !trusted_pem_bundle)) {
        og_tls_set_error(EINVAL, "invalid secure socket connection parameters");
        return -1;
    }
    *handle = OG_TLS_INVALID;

    if (pthread_once(&og_tls_curl_once, og_tls_initialize_curl) != 0) {
        og_tls_set_error(EINVAL, "could not initialize the secure socket transport");
        return -1;
    }
    if (og_tls_curl_initialization != CURLE_OK) {
        og_tls_set_curl_error(og_tls_curl_initialization);
        return -1;
    }

    OGTLSConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) {
        og_tls_set_error(ENOMEM, "could not allocate the secure socket transport");
        return -1;
    }
    connection->socket = CURL_SOCKET_BAD;
    atomic_init(&connection->closed, 0);
    if (pthread_mutex_init(&connection->operation_lock, NULL) != 0) {
        og_tls_set_error(EINVAL, "could not initialize the secure socket transport");
        free(connection);
        return -1;
    }

    connection->easy = curl_easy_init();
    if (!connection->easy) {
        og_tls_set_error(ENOMEM, "could not create the secure socket transport");
        pthread_mutex_destroy(&connection->operation_lock);
        free(connection);
        return -1;
    }

    long timeout_ms = (long)(timeout_seconds * 1000.0 + 0.999);
    if (timeout_ms < 1) timeout_ms = 1;

    if (og_tls_set_option(curl_easy_setopt(connection->easy, CURLOPT_URL, url)) != 0
        || og_tls_set_option(curl_easy_setopt(connection->easy, CURLOPT_CONNECT_ONLY, 1L)) != 0
        || og_tls_set_option(curl_easy_setopt(connection->easy, CURLOPT_SSL_VERIFYPEER, 1L)) != 0
        || og_tls_set_option(curl_easy_setopt(connection->easy, CURLOPT_SSL_VERIFYHOST, 2L)) != 0
        || og_tls_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_SSLVERSION,
            (long)CURL_SSLVERSION_TLSv1_2
        )) != 0
        || og_tls_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_HTTP_VERSION,
            (long)CURL_HTTP_VERSION_1_1
        )) != 0
        || og_tls_set_option(curl_easy_setopt(connection->easy, CURLOPT_FOLLOWLOCATION, 0L)) != 0
        || og_tls_set_option(curl_easy_setopt(connection->easy, CURLOPT_NOSIGNAL, 1L)) != 0
        || og_tls_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_CONNECTTIMEOUT_MS,
            timeout_ms
        )) != 0
        || og_tls_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_TIMEOUT_MS,
            timeout_ms
        )) != 0) {
        goto failure;
    }

    if (trusted_pem_bundle_length > 0) {
#if LIBCURL_VERSION_NUM >= 0x074D00
        struct curl_blob bundle = {
            .data = (void *)trusted_pem_bundle,
            .len = trusted_pem_bundle_length,
            .flags = CURL_BLOB_COPY,
        };
        if (og_tls_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_CAINFO_BLOB,
            &bundle
        )) != 0) {
            goto failure;
        }
#else
        og_tls_set_error(
            EOPNOTSUPP,
            "configured additional TLS trust roots are unavailable in this libcurl version"
        );
        goto failure;
#endif
    }

    CURLcode result = curl_easy_perform(connection->easy);
    if (result != CURLE_OK) {
        og_tls_set_curl_error(result);
        goto failure;
    }

    result = curl_easy_getinfo(connection->easy, CURLINFO_ACTIVESOCKET, &connection->socket);
    if (result != CURLE_OK) {
        og_tls_set_curl_error(result);
        goto failure;
    }
    if (connection->socket == CURL_SOCKET_BAD) {
        og_tls_set_error(ENOTCONN, "secure connection produced no active socket");
        goto failure;
    }

    *handle = (OGTLSHandle)(intptr_t)connection;
    return 0;

failure:
    curl_easy_cleanup(connection->easy);
    pthread_mutex_destroy(&connection->operation_lock);
    free(connection);
    return -1;
}

static int og_tls_wait_ready(OGTLSConnection *connection, short events) {
    struct pollfd descriptor = {
        .fd = connection->socket,
        .events = events,
        .revents = 0,
    };

    for (;;) {
        if (atomic_load(&connection->closed)) return 1;
        descriptor.revents = 0;
        int ready = poll(&descriptor, 1, 250);
        if (ready > 0) return 0;
        if (ready == 0 || errno == EINTR) continue;
        og_tls_set_error(errno, "could not wait for the secure socket");
        return -1;
    }
}

int64_t og_tls_read(OGTLSHandle handle, void *buffer, size_t capacity) {
    if (handle == OG_TLS_INVALID || !buffer || capacity == 0) return 0;
    OGTLSConnection *connection = (OGTLSConnection *)(intptr_t)handle;

    for (;;) {
        if (atomic_load(&connection->closed)) return 0;
        pthread_mutex_lock(&connection->operation_lock);
        if (atomic_load(&connection->closed)) {
            pthread_mutex_unlock(&connection->operation_lock);
            return 0;
        }
        size_t received = 0;
        CURLcode result = curl_easy_recv(connection->easy, buffer, capacity, &received);
        pthread_mutex_unlock(&connection->operation_lock);

        if (result == CURLE_OK) return (int64_t)received;
        if (result == CURLE_AGAIN) {
            int waited = og_tls_wait_ready(connection, POLLIN);
            if (waited > 0) return 0;
            if (waited < 0) return -1;
            continue;
        }
        if (atomic_load(&connection->closed)) return 0;
        og_tls_set_curl_error(result);
        return -1;
    }
}

int64_t og_tls_write_all(OGTLSHandle handle, const void *buffer, size_t length) {
    if (handle == OG_TLS_INVALID || (!buffer && length > 0)) {
        og_tls_set_error(EINVAL, "invalid secure socket write");
        return -1;
    }
    OGTLSConnection *connection = (OGTLSConnection *)(intptr_t)handle;
    size_t written = 0;

    while (written < length) {
        if (atomic_load(&connection->closed)) {
            og_tls_set_error(EPIPE, "secure socket is closed");
            return -1;
        }
        pthread_mutex_lock(&connection->operation_lock);
        if (atomic_load(&connection->closed)) {
            pthread_mutex_unlock(&connection->operation_lock);
            og_tls_set_error(EPIPE, "secure socket is closed");
            return -1;
        }
        size_t sent = 0;
        CURLcode result = curl_easy_send(
            connection->easy,
            (const unsigned char *)buffer + written,
            length - written,
            &sent
        );
        pthread_mutex_unlock(&connection->operation_lock);

        if (result == CURLE_OK && sent > 0) {
            written += sent;
            continue;
        }
        if (result == CURLE_AGAIN) {
            int waited = og_tls_wait_ready(connection, POLLOUT);
            if (waited > 0) {
                og_tls_set_error(EPIPE, "secure socket is closed");
                return -1;
            }
            if (waited < 0) return -1;
            continue;
        }
        if (result == CURLE_OK) {
            og_tls_set_error(EPIPE, "secure socket closed while writing");
        } else {
            og_tls_set_curl_error(result);
        }
        return -1;
    }

    return (int64_t)written;
}

void og_tls_interrupt(OGTLSHandle handle) {
    if (handle == OG_TLS_INVALID) return;
    OGTLSConnection *connection = (OGTLSConnection *)(intptr_t)handle;
    if (atomic_exchange(&connection->closed, 1)) return;
    if (connection->socket != CURL_SOCKET_BAD) {
        shutdown(connection->socket, SHUT_RDWR);
    }
}

void og_tls_destroy(OGTLSHandle handle) {
    if (handle == OG_TLS_INVALID) return;
    OGTLSConnection *connection = (OGTLSConnection *)(intptr_t)handle;
    og_tls_interrupt(handle);
    curl_easy_cleanup(connection->easy);
    pthread_mutex_destroy(&connection->operation_lock);
    free(connection);
}

#else

int og_tls_connect(
    const char *url,
    double timeout_seconds,
    const void *trusted_pem_bundle,
    size_t trusted_pem_bundle_length,
    OGTLSHandle *handle
) {
    (void)url;
    (void)timeout_seconds;
    (void)trusted_pem_bundle;
    (void)trusted_pem_bundle_length;
    if (handle) *handle = OG_TLS_INVALID;
    og_tls_set_error(EINVAL, "verified portable TLS is unavailable on this platform");
    return -1;
}

int64_t og_tls_read(OGTLSHandle handle, void *buffer, size_t capacity) {
    (void)handle;
    (void)buffer;
    (void)capacity;
    return -1;
}

int64_t og_tls_write_all(OGTLSHandle handle, const void *buffer, size_t length) {
    (void)handle;
    (void)buffer;
    (void)length;
    return -1;
}

void og_tls_interrupt(OGTLSHandle handle) {
    (void)handle;
}

void og_tls_destroy(OGTLSHandle handle) {
    (void)handle;
}

#endif
