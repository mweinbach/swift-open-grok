#include "OpenGrokHTTPS.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Thread_local int og_https_error_code;
static _Thread_local int og_https_error_kind;
static _Thread_local char og_https_error_message[256];

static void og_https_set_error(int code, int kind, const char *message) {
    og_https_error_code = code;
    og_https_error_kind = kind;
    snprintf(
        og_https_error_message,
        sizeof(og_https_error_message),
        "%s",
        message ? message : "verified HTTPS request failed"
    );
}

int og_https_last_error_code(void) {
    return og_https_error_code;
}

int og_https_last_error_kind(void) {
    return og_https_error_kind;
}

const char *og_https_last_error_message(void) {
    return og_https_error_message;
}

#if defined(__linux__)

#include <ctype.h>
#include <curl/curl.h>
#include <math.h>
#include <openssl/err.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <stdatomic.h>
#include <strings.h>

extern int og_tls_initialize_shared_curl(void);

enum {
    OG_HTTPS_MAX_RESPONSE_HEADER_BYTES = 64 * 1024,
    OG_HTTPS_MAX_REQUEST_HEADER_BYTES = 64 * 1024,
    OG_HTTPS_MAX_HEADER_COUNT = 256,
    OG_HTTPS_MAX_HEADER_NAME_BYTES = 256,
    OG_HTTPS_MAX_URL_BYTES = 32 * 1024,
    OG_HTTPS_MAX_PROXY_HOST_BYTES = 512,
    OG_HTTPS_MAX_ROOT_BYTES = 1024 * 1024,
    OG_HTTPS_MAX_ROOT_COUNT = 256,
    OG_HTTPS_MAX_TRUST_BUNDLE_BYTES = 20 * 1024 * 1024,
};

typedef struct {
    CURL *easy;
    struct curl_slist *request_headers;
    unsigned char *request_body;
    size_t request_body_length;
    unsigned char *response_headers;
    size_t response_header_length;
    size_t request_header_length;
    size_t request_header_count;
    size_t validated_root_bytes;
    size_t validated_root_count;
    long current_status;
    int current_status_is_interim;
    int metadata_delivered;
    int protocol_failure;
    int callback_failure;
    int trust_bundle_installed;
    int url_installed;
    int is_secure_url;
    int performed;
    _Atomic int cancelled;
    void *callback_context;
    OGHTTPSMetadataCallback metadata_callback;
    OGHTTPSBodyCallback body_callback;
} OGHTTPSConnection;

static int og_https_curl_failure_kind(CURLcode result, int cancelled) {
    if (cancelled && result == CURLE_ABORTED_BY_CALLBACK) {
        return OG_HTTPS_FAILURE_CANCELLED;
    }

    switch (result) {
        case CURLE_COULDNT_RESOLVE_PROXY:
        case CURLE_COULDNT_RESOLVE_HOST:
        case CURLE_COULDNT_CONNECT:
            return OG_HTTPS_FAILURE_UNREACHABLE;

        case CURLE_URL_MALFORMAT:
        case CURLE_UNSUPPORTED_PROTOCOL:
        case CURLE_SSL_CONNECT_ERROR:
        case CURLE_PEER_FAILED_VERIFICATION:
        case CURLE_SSL_CERTPROBLEM:
        case CURLE_SSL_CACERT_BADFILE:
        case CURLE_SSL_ISSUER_ERROR:
        case CURLE_BAD_FUNCTION_ARGUMENT:
            return OG_HTTPS_FAILURE_PERMANENT;

        default:
            return OG_HTTPS_FAILURE_INTERRUPTED;
    }
}

static int og_https_set_curl_error(CURLcode result, int cancelled) {
    int kind = og_https_curl_failure_kind(result, cancelled);
    og_https_set_error(
        (int)result,
        kind,
        kind == OG_HTTPS_FAILURE_CANCELLED
            ? "verified HTTPS request was cancelled"
            : curl_easy_strerror(result)
    );
    return -1;
}

static int og_https_set_option(CURLcode result) {
    return result == CURLE_OK ? 0 : og_https_set_curl_error(result, 0);
}

static void og_https_zero_memory(void *bytes, size_t length) {
    volatile unsigned char *cursor = bytes;
    while (length-- > 0) {
        *cursor++ = 0;
    }
}

static void og_https_release_headers(struct curl_slist *headers) {
    for (struct curl_slist *entry = headers; entry; entry = entry->next) {
        if (entry->data) {
            og_https_zero_memory(entry->data, strlen(entry->data));
        }
    }
    curl_slist_free_all(headers);
}

static OGHTTPSConnection *og_https_connection(OGHTTPSHandle handle) {
    if (handle == OG_HTTPS_INVALID) {
        og_https_set_error(
            EINVAL,
            OG_HTTPS_FAILURE_PERMANENT,
            "invalid verified HTTPS request handle"
        );
        return NULL;
    }
    return (OGHTTPSConnection *)(intptr_t)handle;
}

static int og_https_cancelled(const OGHTTPSConnection *connection) {
    return atomic_load_explicit(&connection->cancelled, memory_order_acquire) != 0;
}

static int og_https_progress_callback(
    void *context,
    curl_off_t download_total,
    curl_off_t downloaded,
    curl_off_t upload_total,
    curl_off_t uploaded
) {
    (void)download_total;
    (void)downloaded;
    (void)upload_total;
    (void)uploaded;
    return og_https_cancelled((const OGHTTPSConnection *)context);
}

static int og_https_header_is_blank(const char *bytes, size_t length) {
    return (length == 1 && bytes[0] == '\n')
        || (length == 2 && bytes[0] == '\r' && bytes[1] == '\n');
}

static int og_https_parse_status_line(const char *bytes, size_t length, long *status) {
    if (length < 12 || memcmp(bytes, "HTTP/", 5) != 0) {
        return 0;
    }

    const char *end = bytes + length;
    const char *cursor = memchr(bytes, ' ', length);
    if (!cursor) {
        return -1;
    }
    while (cursor < end && *cursor == ' ') {
        cursor++;
    }
    if ((size_t)(end - cursor) < 3
        || !isdigit((unsigned char)cursor[0])
        || !isdigit((unsigned char)cursor[1])
        || !isdigit((unsigned char)cursor[2])) {
        return -1;
    }

    long parsed = (long)(cursor[0] - '0') * 100
        + (long)(cursor[1] - '0') * 10
        + (long)(cursor[2] - '0');
    if (parsed < 100 || parsed > 599) {
        return -1;
    }
    *status = parsed;
    return 1;
}

static int og_https_append_response_header(
    OGHTTPSConnection *connection,
    const char *bytes,
    size_t length
) {
    if (length > OG_HTTPS_MAX_RESPONSE_HEADER_BYTES - connection->response_header_length) {
        connection->protocol_failure = 1;
        og_https_set_error(
            EOVERFLOW,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS response headers exceeded the 64 KiB limit"
        );
        return -1;
    }
    memcpy(
        connection->response_headers + connection->response_header_length,
        bytes,
        length
    );
    connection->response_header_length += length;
    return 0;
}

static size_t og_https_header_callback(
    char *bytes,
    size_t size,
    size_t count,
    void *context
) {
    OGHTTPSConnection *connection = context;
    if (size != 0 && count > SIZE_MAX / size) {
        connection->protocol_failure = 1;
        og_https_set_error(
            EOVERFLOW,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS response header size overflowed"
        );
        return 0;
    }

    size_t length = size * count;
    if (length == 0 || og_https_cancelled(connection)) {
        return 0;
    }

    long status = 0;
    int parsed_status = og_https_parse_status_line(bytes, length, &status);
    if (parsed_status < 0) {
        connection->protocol_failure = 1;
        og_https_set_error(
            EPROTO,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS response has a malformed status line"
        );
        return 0;
    }
    if (parsed_status > 0) {
        if (connection->metadata_delivered) {
            connection->protocol_failure = 1;
            og_https_set_error(
                EPROTO,
                OG_HTTPS_FAILURE_PERMANENT,
                "verified HTTPS response unexpectedly changed authorities"
            );
            return 0;
        }
        connection->response_header_length = 0;
        connection->current_status = status;
        connection->current_status_is_interim = status < 200;
        if (!connection->current_status_is_interim
            && og_https_append_response_header(connection, bytes, length) != 0) {
            return 0;
        }
        return length;
    }

    if (connection->metadata_delivered) {
        return length;
    }
    if (connection->current_status == 0) {
        connection->protocol_failure = 1;
        og_https_set_error(
            EPROTO,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS response headers arrived before its status"
        );
        return 0;
    }

    if (!og_https_header_is_blank(bytes, length)) {
        if (!connection->current_status_is_interim
            && og_https_append_response_header(connection, bytes, length) != 0) {
            return 0;
        }
        return length;
    }

    if (connection->current_status_is_interim) {
        connection->current_status = 0;
        connection->current_status_is_interim = 0;
        connection->response_header_length = 0;
        return length;
    }

    char *effective_url = NULL;
    CURLcode information = curl_easy_getinfo(
        connection->easy,
        CURLINFO_EFFECTIVE_URL,
        &effective_url
    );
    if (information != CURLE_OK || !effective_url) {
        connection->protocol_failure = 1;
        og_https_set_error(
            EPROTO,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS response has no effective request authority"
        );
        return 0;
    }

    if (!connection->metadata_callback
        || connection->metadata_callback(
            connection->callback_context,
            connection->current_status,
            effective_url,
            connection->response_headers,
            connection->response_header_length
        ) != 0) {
        connection->callback_failure = 1;
        return 0;
    }
    connection->metadata_delivered = 1;
    return length;
}

static size_t og_https_body_callback(
    char *bytes,
    size_t size,
    size_t count,
    void *context
) {
    OGHTTPSConnection *connection = context;
    if (size != 0 && count > SIZE_MAX / size) {
        connection->protocol_failure = 1;
        og_https_set_error(
            EOVERFLOW,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS response body chunk size overflowed"
        );
        return 0;
    }

    size_t length = size * count;
    if (length == 0) {
        return 0;
    }
    if (og_https_cancelled(connection)) {
        return 0;
    }
    if (!connection->metadata_delivered) {
        connection->protocol_failure = 1;
        og_https_set_error(
            EPROTO,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS response body arrived before its metadata"
        );
        return 0;
    }
    if (!connection->body_callback
        || connection->body_callback(
            connection->callback_context,
            (const unsigned char *)bytes,
            length
        ) != 0) {
        connection->callback_failure = 1;
        return 0;
    }
    return length;
}

OGHTTPSHandle og_https_create(void) {
    int curl_initialization = og_tls_initialize_shared_curl();
    if (curl_initialization < 0) {
        og_https_set_error(
            EINVAL,
            OG_HTTPS_FAILURE_PERMANENT,
            "could not initialize the verified HTTPS transport"
        );
        return OG_HTTPS_INVALID;
    }
    if (curl_initialization != CURLE_OK) {
        og_https_set_curl_error((CURLcode)curl_initialization, 0);
        return OG_HTTPS_INVALID;
    }

    OGHTTPSConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) {
        og_https_set_error(
            ENOMEM,
            OG_HTTPS_FAILURE_INTERRUPTED,
            "could not allocate the verified HTTPS request"
        );
        return OG_HTTPS_INVALID;
    }
    atomic_init(&connection->cancelled, 0);

    connection->response_headers = malloc(OG_HTTPS_MAX_RESPONSE_HEADER_BYTES);
    connection->easy = curl_easy_init();
    if (!connection->response_headers || !connection->easy) {
        og_https_set_error(
            ENOMEM,
            OG_HTTPS_FAILURE_INTERRUPTED,
            "could not allocate the verified HTTPS transport"
        );
        goto failure;
    }

    if (og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_SSL_VERIFYPEER, 1L)) != 0
        || og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_SSL_VERIFYHOST, 2L)) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_SSLVERSION,
            (long)CURL_SSLVERSION_TLSv1_2
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_HTTP_VERSION,
            (long)CURL_HTTP_VERSION_2TLS
        )) != 0
        || og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_FOLLOWLOCATION, 0L)) != 0
        || og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_MAXREDIRS, 0L)) != 0
        || og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_FAILONERROR, 0L)) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_PROTOCOLS,
            (long)CURLPROTO_HTTPS
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_REDIR_PROTOCOLS,
            (long)CURLPROTO_HTTPS
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_NETRC,
            (long)CURL_NETRC_IGNORED
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_HTTPAUTH,
            (long)CURLAUTH_NONE
        )) != 0
        || og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_UNRESTRICTED_AUTH, 0L)) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_DISALLOW_USERNAME_IN_URL,
            1L
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_HEADEROPT,
            (long)CURLHEADER_SEPARATE
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_SUPPRESS_CONNECT_HEADERS,
            1L
        )) != 0
        || og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_NOSIGNAL, 1L)) != 0
        || og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_NOPROGRESS, 0L)) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_XFERINFOFUNCTION,
            og_https_progress_callback
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_XFERINFODATA,
            connection
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_HEADERFUNCTION,
            og_https_header_callback
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_HEADERDATA,
            connection
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_WRITEFUNCTION,
            og_https_body_callback
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_WRITEDATA,
            connection
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_CONNECTTIMEOUT_MS,
            30000L
        )) != 0
        || og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_TIMEOUT_MS, 0L)) != 0) {
        goto failure;
    }

    return (OGHTTPSHandle)(intptr_t)connection;

failure:
    if (connection->easy) {
        curl_easy_cleanup(connection->easy);
    }
    free(connection->response_headers);
    free(connection);
    return OG_HTTPS_INVALID;
}

int og_https_set_url(OGHTTPSHandle handle, const char *url) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection || !url) {
        if (connection) {
            og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS request URL");
        }
        return -1;
    }

    size_t length = strnlen(url, OG_HTTPS_MAX_URL_BYTES + 1);
    if (length == 0 || length > OG_HTTPS_MAX_URL_BYTES) {
        og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS request URL");
        return -1;
    }
    for (size_t index = 0; index < length; index++) {
        unsigned char character = (unsigned char)url[index];
        if (character <= 0x20 || character == 0x7F) {
            og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS request URL");
            return -1;
        }
    }

    CURLU *parts = curl_url();
    if (!parts) {
        og_https_set_error(
            ENOMEM,
            OG_HTTPS_FAILURE_INTERRUPTED,
            "could not inspect the HTTPS request authority"
        );
        return -1;
    }

    char *scheme = NULL;
    char *host = NULL;
    char *username = NULL;
    char *password = NULL;
    CURLUcode parsed = curl_url_set(parts, CURLUPART_URL, url, 0);
    CURLUcode scheme_result = parsed == CURLUE_OK
        ? curl_url_get(parts, CURLUPART_SCHEME, &scheme, 0)
        : parsed;
    CURLUcode host_result = parsed == CURLUE_OK
        ? curl_url_get(parts, CURLUPART_HOST, &host, 0)
        : parsed;
    CURLUcode user_result = parsed == CURLUE_OK
        ? curl_url_get(parts, CURLUPART_USER, &username, 0)
        : parsed;
    CURLUcode password_result = parsed == CURLUE_OK
        ? curl_url_get(parts, CURLUPART_PASSWORD, &password, 0)
        : parsed;

    int valid = parsed == CURLUE_OK
        && scheme_result == CURLUE_OK
        && host_result == CURLUE_OK
        && host
        && host[0] != '\0'
        && user_result == CURLUE_NO_USER
        && password_result == CURLUE_NO_PASSWORD
        && strcasecmp(scheme, "https") == 0;
    int secure = valid && strcasecmp(scheme, "https") == 0;

    curl_free(scheme);
    curl_free(host);
    curl_free(username);
    curl_free(password);
    curl_url_cleanup(parts);

    if (!valid) {
        og_https_set_error(
            EINVAL,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS requests require an HTTPS authority without embedded credentials"
        );
        return -1;
    }
    if (og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_URL, url)) != 0) {
        return -1;
    }

    connection->url_installed = 1;
    connection->is_secure_url = secure;
    return 0;
}

int og_https_set_method(OGHTTPSHandle handle, const char *method) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection || !method) {
        if (connection) {
            og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS request method");
        }
        return -1;
    }

    const char *allowed[] = { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };
    int valid = 0;
    for (size_t index = 0; index < sizeof(allowed) / sizeof(allowed[0]); index++) {
        if (strcmp(method, allowed[index]) == 0) {
            valid = 1;
            break;
        }
    }
    if (!valid) {
        og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS request method");
        return -1;
    }

    if (og_https_set_option(curl_easy_setopt(
        connection->easy,
        CURLOPT_NOBODY,
        strcmp(method, "HEAD") == 0 ? 1L : 0L
    )) != 0) {
        return -1;
    }
    return og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_CUSTOMREQUEST, method));
}

int og_https_set_body(OGHTTPSHandle handle, const void *body, size_t length) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection || (length > 0 && !body) || length > (size_t)INT64_MAX) {
        if (connection) {
            og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS request body");
        }
        return -1;
    }

    unsigned char *copy = malloc(length == 0 ? 1 : length);
    if (!copy) {
        og_https_set_error(
            ENOMEM,
            OG_HTTPS_FAILURE_INTERRUPTED,
            "could not retain the HTTPS request body"
        );
        return -1;
    }
    if (length > 0) {
        memcpy(copy, body, length);
    } else {
        copy[0] = 0;
    }

    if (og_https_set_option(curl_easy_setopt(
        connection->easy,
        CURLOPT_POSTFIELDSIZE_LARGE,
        (curl_off_t)length
    )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_POSTFIELDS,
            copy
        )) != 0) {
        og_https_zero_memory(copy, length);
        free(copy);
        return -1;
    }

    if (connection->request_body) {
        og_https_zero_memory(connection->request_body, connection->request_body_length);
        free(connection->request_body);
    }
    connection->request_body = copy;
    connection->request_body_length = length;
    return 0;
}

static int og_https_valid_header_name(const char *name, size_t length) {
    for (size_t index = 0; index < length; index++) {
        unsigned char character = (unsigned char)name[index];
        if (isalnum(character)) {
            continue;
        }
        if (!strchr("!#$%&'*+-.^_`|~", character)) {
            return 0;
        }
    }
    return length > 0;
}

static int og_https_valid_header_value(const char *value, size_t length) {
    for (size_t index = 0; index < length; index++) {
        unsigned char character = (unsigned char)value[index];
        if ((character < 0x20 && character != '\t') || character == 0x7F) {
            return 0;
        }
    }
    return 1;
}

int og_https_add_header(OGHTTPSHandle handle, const char *name, const char *value) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection || !name || !value) {
        if (connection) {
            og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS request header");
        }
        return -1;
    }

    size_t name_length = strnlen(name, OG_HTTPS_MAX_HEADER_NAME_BYTES + 1);
    size_t value_length = strnlen(value, OG_HTTPS_MAX_REQUEST_HEADER_BYTES + 1);
    if (name_length == 0
        || name_length > OG_HTTPS_MAX_HEADER_NAME_BYTES
        || value_length > OG_HTTPS_MAX_REQUEST_HEADER_BYTES
        || !og_https_valid_header_name(name, name_length)
        || !og_https_valid_header_value(value, value_length)
        || connection->request_header_count >= OG_HTTPS_MAX_HEADER_COUNT
        || name_length > OG_HTTPS_MAX_REQUEST_HEADER_BYTES - connection->request_header_length
        || value_length > OG_HTTPS_MAX_REQUEST_HEADER_BYTES
            - connection->request_header_length
            - name_length
        || 2 > OG_HTTPS_MAX_REQUEST_HEADER_BYTES
            - connection->request_header_length
            - name_length
            - value_length) {
        og_https_set_error(
            EINVAL,
            OG_HTTPS_FAILURE_PERMANENT,
            "invalid or oversized HTTPS request header"
        );
        return -1;
    }

    size_t line_length = name_length + 2 + value_length;
    char *line = malloc(line_length + 1);
    if (!line) {
        og_https_set_error(
            ENOMEM,
            OG_HTTPS_FAILURE_INTERRUPTED,
            "could not retain the HTTPS request headers"
        );
        return -1;
    }
    memcpy(line, name, name_length);
    line[name_length] = ':';
    line[name_length + 1] = ' ';
    memcpy(line + name_length + 2, value, value_length);
    line[line_length] = '\0';

    struct curl_slist *updated = curl_slist_append(connection->request_headers, line);
    og_https_zero_memory(line, line_length);
    free(line);
    if (!updated) {
        og_https_set_error(
            ENOMEM,
            OG_HTTPS_FAILURE_INTERRUPTED,
            "could not retain the HTTPS request headers"
        );
        return -1;
    }

    connection->request_headers = updated;
    if (og_https_set_option(curl_easy_setopt(
        connection->easy,
        CURLOPT_HTTPHEADER,
        connection->request_headers
    )) != 0) {
        return -1;
    }
    connection->request_header_length += line_length;
    connection->request_header_count += 1;
    return 0;
}

int og_https_set_user_agent(OGHTTPSHandle handle, const char *user_agent) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection || !user_agent) {
        if (connection) {
            og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS user agent");
        }
        return -1;
    }

    size_t length = strnlen(user_agent, OG_HTTPS_MAX_REQUEST_HEADER_BYTES + 1);
    if (length == 0
        || length > OG_HTTPS_MAX_REQUEST_HEADER_BYTES
        || !og_https_valid_header_value(user_agent, length)) {
        og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS user agent");
        return -1;
    }
    return og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_USERAGENT, user_agent));
}

static int og_https_timeout_milliseconds(double seconds, int allow_zero, long *milliseconds) {
    if (!isfinite(seconds)
        || seconds < 0.0
        || (!allow_zero && seconds == 0.0)
        || seconds > (double)(LONG_MAX / 1000)) {
        og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS request timeout");
        return -1;
    }
    if (seconds == 0.0) {
        *milliseconds = 0;
        return 0;
    }

    double rounded = seconds * 1000.0;
    long result = (long)rounded;
    if ((double)result < rounded) {
        result += 1;
    }
    *milliseconds = result < 1 ? 1 : result;
    return 0;
}

int og_https_set_timeouts(
    OGHTTPSHandle handle,
    double connect_seconds,
    double request_seconds
) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection) {
        return -1;
    }

    long connect_ms = 0;
    long request_ms = 0;
    if (og_https_timeout_milliseconds(connect_seconds, 0, &connect_ms) != 0
        || og_https_timeout_milliseconds(request_seconds, 1, &request_ms) != 0) {
        return -1;
    }

    if (og_https_set_option(curl_easy_setopt(
        connection->easy,
        CURLOPT_CONNECTTIMEOUT_MS,
        connect_ms
    )) != 0) {
        return -1;
    }
    return og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_TIMEOUT_MS, request_ms));
}

int og_https_set_minimum_tls(OGHTTPSHandle handle, int version) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection) {
        return -1;
    }

    long curl_version;
    if (version == 12) {
        curl_version = (long)CURL_SSLVERSION_TLSv1_2;
    } else if (version == 13) {
        curl_version = (long)CURL_SSLVERSION_TLSv1_3;
    } else {
        og_https_set_error(
            EINVAL,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS requires TLS 1.2 or TLS 1.3"
        );
        return -1;
    }
    return og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_SSLVERSION, curl_version));
}

static int og_https_valid_proxy_host(const char *host, size_t length) {
    if (length == 0 || length > OG_HTTPS_MAX_PROXY_HOST_BYTES) {
        return 0;
    }
    for (size_t index = 0; index < length; index++) {
        unsigned char character = (unsigned char)host[index];
        if (character <= 0x20
            || character == 0x7F
            || strchr("/\\?#@%", character)) {
            return 0;
        }
    }
    return 1;
}

int og_https_set_proxy(
    OGHTTPSHandle handle,
    const char *host,
    uint16_t port,
    const char *username,
    const char *password
) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection || !host || port == 0) {
        if (connection) {
            og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS proxy authority");
        }
        return -1;
    }

    size_t host_length = strnlen(host, OG_HTTPS_MAX_PROXY_HOST_BYTES + 1);
    if (!og_https_valid_proxy_host(host, host_length)) {
        og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS proxy authority");
        return -1;
    }
    if ((username && !og_https_valid_header_value(username, strlen(username)))
        || (password && !og_https_valid_header_value(password, strlen(password)))) {
        og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS proxy credentials");
        return -1;
    }

    char proxy[OG_HTTPS_MAX_PROXY_HOST_BYTES + 32];
    int wrap_ipv6 = strchr(host, ':') != NULL && host[0] != '[';
    int written = snprintf(
        proxy,
        sizeof(proxy),
        wrap_ipv6 ? "http://[%s]:%u" : "http://%s:%u",
        host,
        (unsigned int)port
    );
    if (written < 0 || (size_t)written >= sizeof(proxy)) {
        og_https_set_error(EINVAL, OG_HTTPS_FAILURE_PERMANENT, "invalid HTTPS proxy authority");
        return -1;
    }

    if (og_https_set_option(curl_easy_setopt(connection->easy, CURLOPT_PROXY, proxy)) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_PROXYTYPE,
            (long)CURLPROXY_HTTP
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_HTTPPROXYTUNNEL,
            connection->is_secure_url ? 1L : 0L
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_PROXYUSERNAME,
            username
        )) != 0
        || og_https_set_option(curl_easy_setopt(
            connection->easy,
            CURLOPT_PROXYPASSWORD,
            password
        )) != 0) {
        return -1;
    }
    return 0;
}

int og_https_add_root_der(OGHTTPSHandle handle, const void *certificate, size_t length) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection || !certificate || length == 0) {
        if (connection) {
            og_https_set_error(
                EINVAL,
                OG_HTTPS_FAILURE_PERMANENT,
                "configured additional TLS trust root is not a valid X.509 certificate"
            );
        }
        return -1;
    }
    if (length > OG_HTTPS_MAX_ROOT_BYTES
        || connection->validated_root_count >= OG_HTTPS_MAX_ROOT_COUNT
        || length > OG_HTTPS_MAX_ROOT_BYTES - connection->validated_root_bytes
        || length > (size_t)LONG_MAX) {
        og_https_set_error(
            EOVERFLOW,
            OG_HTTPS_FAILURE_PERMANENT,
            "configured additional TLS trust roots exceed the bounded certificate limit"
        );
        return -1;
    }

    const unsigned char *begin = certificate;
    const unsigned char *cursor = begin;
    ERR_clear_error();
    X509 *parsed = d2i_X509(NULL, &cursor, (long)length);
    int valid = parsed != NULL
        && cursor == begin + length
        && X509_check_ca(parsed) > 0;
    X509_free(parsed);
    ERR_clear_error();

    if (!valid) {
        og_https_set_error(
            EINVAL,
            OG_HTTPS_FAILURE_PERMANENT,
            "configured additional TLS trust root is not a valid X.509 certificate"
        );
        return -1;
    }

    connection->validated_root_count += 1;
    connection->validated_root_bytes += length;
    return 0;
}

int og_https_set_trust_bundle(OGHTTPSHandle handle, const void *bundle, size_t length) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection || !bundle || length == 0 || length > OG_HTTPS_MAX_TRUST_BUNDLE_BYTES) {
        if (connection) {
            og_https_set_error(
                EINVAL,
                OG_HTTPS_FAILURE_PERMANENT,
                "configured additional TLS trust roots require a bounded in-memory CA bundle"
            );
        }
        return -1;
    }

#if LIBCURL_VERSION_NUM >= 0x074D00
    struct curl_blob trusted_bundle = {
        .data = (void *)bundle,
        .len = length,
        .flags = CURL_BLOB_COPY,
    };
    if (og_https_set_option(curl_easy_setopt(
        connection->easy,
        CURLOPT_CAINFO_BLOB,
        &trusted_bundle
    )) != 0) {
        return -1;
    }
    connection->trust_bundle_installed = 1;
    return 0;
#else
    (void)bundle;
    (void)length;
    og_https_set_error(
        EOPNOTSUPP,
        OG_HTTPS_FAILURE_PERMANENT,
        "configured additional TLS trust roots are unavailable in this libcurl version"
    );
    return -1;
#endif
}

int og_https_perform(
    OGHTTPSHandle handle,
    void *context,
    OGHTTPSMetadataCallback metadata_callback,
    OGHTTPSBodyCallback body_callback
) {
    OGHTTPSConnection *connection = og_https_connection(handle);
    if (!connection) {
        return -1;
    }
    if (!connection->url_installed
        || !connection->is_secure_url
        || !metadata_callback
        || !body_callback
        || connection->performed
        || connection->validated_root_count == 0
        || !connection->trust_bundle_installed) {
        og_https_set_error(
            EINVAL,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS request was not configured safely"
        );
        return -1;
    }
    if (og_https_cancelled(connection)) {
        og_https_set_error(
            ECANCELED,
            OG_HTTPS_FAILURE_CANCELLED,
            "verified HTTPS request was cancelled"
        );
        return -1;
    }

    connection->performed = 1;
    connection->callback_context = context;
    connection->metadata_callback = metadata_callback;
    connection->body_callback = body_callback;

    CURLcode result = curl_easy_perform(connection->easy);
    if (result != CURLE_OK) {
        if (og_https_cancelled(connection)) {
            og_https_set_error(
                (int)result,
                OG_HTTPS_FAILURE_CANCELLED,
                "verified HTTPS request was cancelled"
            );
            return -1;
        }
        if (connection->protocol_failure) {
            return -1;
        }
        if (connection->callback_failure) {
            og_https_set_error(
                (int)result,
                OG_HTTPS_FAILURE_INTERRUPTED,
                "verified HTTPS response callback refused the transfer"
            );
            return -1;
        }
        return og_https_set_curl_error(result, 0);
    }

    if (!connection->metadata_delivered) {
        og_https_set_error(
            EPROTO,
            OG_HTTPS_FAILURE_PERMANENT,
            "verified HTTPS request completed without response metadata"
        );
        return -1;
    }
    return 0;
}

void og_https_cancel(OGHTTPSHandle handle) {
    if (handle == OG_HTTPS_INVALID) {
        return;
    }
    OGHTTPSConnection *connection = (OGHTTPSConnection *)(intptr_t)handle;
    atomic_store_explicit(&connection->cancelled, 1, memory_order_release);
}

void og_https_destroy(OGHTTPSHandle handle) {
    if (handle == OG_HTTPS_INVALID) {
        return;
    }
    OGHTTPSConnection *connection = (OGHTTPSConnection *)(intptr_t)handle;
    og_https_cancel(handle);

    if (connection->easy) {
        curl_easy_cleanup(connection->easy);
    }
    if (connection->request_headers) {
        og_https_release_headers(connection->request_headers);
    }
    if (connection->request_body) {
        og_https_zero_memory(connection->request_body, connection->request_body_length);
        free(connection->request_body);
    }
    free(connection->response_headers);
    og_https_zero_memory(connection, sizeof(*connection));
    free(connection);
}

#else

static int og_https_unavailable(void) {
    og_https_set_error(
        EINVAL,
        OG_HTTPS_FAILURE_PERMANENT,
        "verified Linux enterprise HTTPS is unavailable on this platform"
    );
    return -1;
}

OGHTTPSHandle og_https_create(void) {
    og_https_unavailable();
    return OG_HTTPS_INVALID;
}

int og_https_set_url(OGHTTPSHandle handle, const char *url) {
    (void)handle;
    (void)url;
    return og_https_unavailable();
}

int og_https_set_method(OGHTTPSHandle handle, const char *method) {
    (void)handle;
    (void)method;
    return og_https_unavailable();
}

int og_https_set_body(OGHTTPSHandle handle, const void *body, size_t length) {
    (void)handle;
    (void)body;
    (void)length;
    return og_https_unavailable();
}

int og_https_add_header(OGHTTPSHandle handle, const char *name, const char *value) {
    (void)handle;
    (void)name;
    (void)value;
    return og_https_unavailable();
}

int og_https_set_user_agent(OGHTTPSHandle handle, const char *user_agent) {
    (void)handle;
    (void)user_agent;
    return og_https_unavailable();
}

int og_https_set_timeouts(
    OGHTTPSHandle handle,
    double connect_seconds,
    double request_seconds
) {
    (void)handle;
    (void)connect_seconds;
    (void)request_seconds;
    return og_https_unavailable();
}

int og_https_set_minimum_tls(OGHTTPSHandle handle, int version) {
    (void)handle;
    (void)version;
    return og_https_unavailable();
}

int og_https_set_proxy(
    OGHTTPSHandle handle,
    const char *host,
    uint16_t port,
    const char *username,
    const char *password
) {
    (void)handle;
    (void)host;
    (void)port;
    (void)username;
    (void)password;
    return og_https_unavailable();
}

int og_https_add_root_der(OGHTTPSHandle handle, const void *certificate, size_t length) {
    (void)handle;
    (void)certificate;
    (void)length;
    return og_https_unavailable();
}

int og_https_set_trust_bundle(OGHTTPSHandle handle, const void *bundle, size_t length) {
    (void)handle;
    (void)bundle;
    (void)length;
    return og_https_unavailable();
}

int og_https_perform(
    OGHTTPSHandle handle,
    void *context,
    OGHTTPSMetadataCallback metadata_callback,
    OGHTTPSBodyCallback body_callback
) {
    (void)handle;
    (void)context;
    (void)metadata_callback;
    (void)body_callback;
    return og_https_unavailable();
}

void og_https_cancel(OGHTTPSHandle handle) {
    (void)handle;
}

void og_https_destroy(OGHTTPSHandle handle) {
    (void)handle;
}

#endif
