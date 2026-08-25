#include "OpenGrokWindowsWebSocket.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

enum {
    OG_WINDOWS_WEBSOCKET_KEEPALIVE_MS = 15000,
    OG_WINDOWS_WEBSOCKET_CLOSE_TIMEOUT_MS = 2000,
};

typedef struct {
    HINTERNET session;
    HINTERNET connection;
    HINTERNET websocket;
    CRITICAL_SECTION send_lock;
    CRITICAL_SECTION receive_lock;
    volatile LONG closed;
    DWORD keepalive_milliseconds;
} OGWindowsWebSocket;

typedef struct {
    HANDLE stop;
    DWORD timeout_milliseconds;
    PVOID volatile request;
    volatile LONG expired;
} OGWindowsWebSocketDeadline;

static _Thread_local DWORD og_windows_websocket_error_code;
static _Thread_local char og_windows_websocket_error_message[256];

static void og_windows_websocket_set_error(DWORD code, const char *operation) {
    og_windows_websocket_error_code = code == ERROR_SUCCESS ? ERROR_GEN_FAILURE : code;
    snprintf(
        og_windows_websocket_error_message,
        sizeof(og_windows_websocket_error_message),
        "%s (Windows error %lu)",
        operation,
        (unsigned long)og_windows_websocket_error_code
    );
}

static wchar_t *og_windows_websocket_widen(const char *value) {
    if (value == NULL) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return NULL;
    }

    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (length <= 0) return NULL;

    wchar_t *result = calloc((size_t)length, sizeof(wchar_t));
    if (result == NULL) {
        SetLastError(ERROR_OUTOFMEMORY);
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result, length) <= 0) {
        free(result);
        return NULL;
    }
    return result;
}

static DWORD WINAPI og_windows_websocket_watch_deadline(void *context) {
    OGWindowsWebSocketDeadline *deadline = context;
    DWORD result = WaitForSingleObject(deadline->stop, deadline->timeout_milliseconds);
    if (result == WAIT_TIMEOUT) {
        InterlockedExchange(&deadline->expired, 1);
        HINTERNET request = InterlockedExchangePointer(&deadline->request, NULL);
        if (request != NULL) WinHttpCloseHandle(request);
    }
    return 0;
}

static void og_windows_websocket_stop_deadline(
    OGWindowsWebSocketDeadline *deadline,
    HANDLE worker
) {
    if (worker != NULL) {
        SetEvent(deadline->stop);
        WaitForSingleObject(worker, INFINITE);
        CloseHandle(worker);
    }
    HINTERNET request = InterlockedExchangePointer(&deadline->request, NULL);
    if (request != NULL) WinHttpCloseHandle(request);
    if (deadline->stop != NULL) CloseHandle(deadline->stop);
}

static OGWindowsWebSocket *og_windows_websocket_value(int64_t handle) {
    if (handle == 0 || handle == -1) {
        og_windows_websocket_set_error(ERROR_INVALID_HANDLE, "invalid WebSocket handle");
        return NULL;
    }
    return (OGWindowsWebSocket *)(intptr_t)handle;
}

int og_windows_websocket_is_available(void) { return 1; }

int og_windows_websocket_keepalive_interval_milliseconds(void) {
    return OG_WINDOWS_WEBSOCKET_KEEPALIVE_MS;
}

int og_windows_websocket_connect(
    const char *host,
    uint16_t port,
    const char *target,
    const char *headers,
    int use_tls,
    double timeout_seconds,
    int64_t *websocket,
    int *http_status
) {
    if (
        host == NULL || target == NULL || headers == NULL || websocket == NULL
        || http_status == NULL || port == 0 || !(timeout_seconds > 0)
    ) {
        og_windows_websocket_set_error(ERROR_INVALID_PARAMETER, "invalid WebSocket connection options");
        return -1;
    }

    *websocket = -1;
    *http_status = 0;
    og_windows_websocket_error_code = ERROR_SUCCESS;
    og_windows_websocket_error_message[0] = '\0';

    double exact_timeout = timeout_seconds * 1000.0;
    DWORD timeout_ms = exact_timeout >= (double)INT_MAX
        ? (DWORD)INT_MAX
        : (DWORD)(exact_timeout < 1.0 ? 1.0 : exact_timeout);

    wchar_t *wide_host = NULL;
    wchar_t *wide_target = NULL;
    wchar_t *wide_headers = NULL;
    HINTERNET session = NULL;
    HINTERNET connection = NULL;
    HINTERNET upgraded = NULL;
    HANDLE watchdog = NULL;
    OGWindowsWebSocketDeadline deadline = {0};
    int success = -1;

    wide_host = og_windows_websocket_widen(host);
    wide_target = og_windows_websocket_widen(target);
    wide_headers = og_windows_websocket_widen(headers);
    if (wide_host == NULL || wide_target == NULL || wide_headers == NULL) {
        og_windows_websocket_set_error(GetLastError(), "invalid UTF-8 WebSocket endpoint or headers");
        goto cleanup;
    }

    session = WinHttpOpen(
        L"open-grok",
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0
    );
    if (session == NULL) {
        og_windows_websocket_set_error(GetLastError(), "WinHttpOpen failed");
        goto cleanup;
    }

    if (!WinHttpSetTimeouts(
        session,
        (int)timeout_ms,
        (int)timeout_ms,
        (int)timeout_ms,
        (int)timeout_ms
    )) {
        og_windows_websocket_set_error(GetLastError(), "could not apply WebSocket connection timeouts");
        goto cleanup;
    }

    if (use_tls) {
        DWORD protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;
#ifdef WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3
        protocols |= WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3;
#endif
        if (!WinHttpSetOption(
            session,
            WINHTTP_OPTION_SECURE_PROTOCOLS,
            &protocols,
            sizeof(protocols)
        )) {
            og_windows_websocket_set_error(GetLastError(), "could not require TLS 1.2 or newer");
            goto cleanup;
        }
    }

    connection = WinHttpConnect(session, wide_host, (INTERNET_PORT)port, 0);
    if (connection == NULL) {
        og_windows_websocket_set_error(GetLastError(), "WinHttpConnect failed");
        goto cleanup;
    }

    HINTERNET request = WinHttpOpenRequest(
        connection,
        L"GET",
        wide_target,
        L"HTTP/1.1",
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        use_tls ? WINHTTP_FLAG_SECURE : 0
    );
    if (request == NULL) {
        og_windows_websocket_set_error(GetLastError(), "could not open WebSocket upgrade request");
        goto cleanup;
    }
    deadline.request = request;

    DWORD disabled = WINHTTP_DISABLE_COOKIES
        | WINHTTP_DISABLE_AUTHENTICATION
        | WINHTTP_DISABLE_REDIRECTS;
    if (!WinHttpSetOption(
        request,
        WINHTTP_OPTION_DISABLE_FEATURE,
        &disabled,
        sizeof(disabled)
    )) {
        og_windows_websocket_set_error(GetLastError(), "could not disable implicit WebSocket credentials and redirects");
        goto cleanup;
    }

    if (!WinHttpSetOption(request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0)) {
        og_windows_websocket_set_error(GetLastError(), "could not request an HTTP WebSocket upgrade");
        goto cleanup;
    }

    if (wide_headers[0] != L'\0' && !WinHttpAddRequestHeaders(
        request,
        wide_headers,
        (DWORD)-1,
        WINHTTP_ADDREQ_FLAG_ADD
    )) {
        og_windows_websocket_set_error(GetLastError(), "could not apply WebSocket request headers");
        goto cleanup;
    }

    deadline.stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    deadline.timeout_milliseconds = timeout_ms;
    if (deadline.stop == NULL) {
        og_windows_websocket_set_error(GetLastError(), "could not create WebSocket connection deadline");
        goto cleanup;
    }
    watchdog = CreateThread(NULL, 0, og_windows_websocket_watch_deadline, &deadline, 0, NULL);
    if (watchdog == NULL) {
        og_windows_websocket_set_error(GetLastError(), "could not enforce WebSocket connection deadline");
        goto cleanup;
    }

    if (!WinHttpSendRequest(
        request,
        WINHTTP_NO_ADDITIONAL_HEADERS,
        0,
        WINHTTP_NO_REQUEST_DATA,
        0,
        0,
        0
    )) {
        DWORD code = InterlockedCompareExchange(&deadline.expired, 0, 0)
            ? ERROR_TIMEOUT
            : GetLastError();
        og_windows_websocket_set_error(code, "WebSocket request could not be sent");
        goto cleanup;
    }

    if (!WinHttpReceiveResponse(request, NULL)) {
        DWORD code = InterlockedCompareExchange(&deadline.expired, 0, 0)
            ? ERROR_TIMEOUT
            : GetLastError();
        og_windows_websocket_set_error(code, "WebSocket server did not complete its HTTP response");
        goto cleanup;
    }

    DWORD status = 0;
    DWORD status_length = sizeof(status);
    if (!WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX,
        &status,
        &status_length,
        WINHTTP_NO_HEADER_INDEX
    )) {
        og_windows_websocket_set_error(GetLastError(), "WebSocket response omitted its HTTP status");
        goto cleanup;
    }
    *http_status = (int)status;
    if (status != 101) {
        og_windows_websocket_set_error(ERROR_INVALID_DATA, "WebSocket upgrade was rejected");
        goto cleanup;
    }

    upgraded = WinHttpWebSocketCompleteUpgrade(request, 0);
    if (upgraded == NULL) {
        DWORD code = InterlockedCompareExchange(&deadline.expired, 0, 0)
            ? ERROR_TIMEOUT
            : GetLastError();
        og_windows_websocket_set_error(code, "WebSocket upgrade could not be completed");
        goto cleanup;
    }
    if (InterlockedCompareExchange(&deadline.expired, 0, 0)) {
        og_windows_websocket_set_error(ERROR_TIMEOUT, "WebSocket connection deadline expired");
        goto cleanup;
    }

    /* These options accept only the handle returned by CompleteUpgrade, not
       its session or request. A server can therefore observe the 101 before
       local policy is armed; never publish the socket if either option fails. */
    DWORD keepalive_ms = OG_WINDOWS_WEBSOCKET_KEEPALIVE_MS;
    if (!WinHttpSetOption(
        upgraded,
        WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL,
        &keepalive_ms,
        sizeof(keepalive_ms)
    )) {
        og_windows_websocket_set_error(GetLastError(), "could not enable the 15-second WebSocket keepalive");
        goto cleanup;
    }
    DWORD observed_keepalive = 0;
    DWORD observed_keepalive_size = sizeof(observed_keepalive);
    if (!WinHttpQueryOption(
        upgraded,
        WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL,
        &observed_keepalive,
        &observed_keepalive_size
    ) || observed_keepalive_size != sizeof(observed_keepalive)
      || observed_keepalive != keepalive_ms) {
        DWORD error = GetLastError();
        og_windows_websocket_set_error(
            error == ERROR_SUCCESS ? ERROR_INVALID_DATA : error,
            "could not verify the 15-second WebSocket keepalive"
        );
        goto cleanup;
    }

    DWORD close_timeout_ms = OG_WINDOWS_WEBSOCKET_CLOSE_TIMEOUT_MS;
    if (!WinHttpSetOption(
        upgraded,
        WINHTTP_OPTION_WEB_SOCKET_CLOSE_TIMEOUT,
        &close_timeout_ms,
        sizeof(close_timeout_ms)
    )) {
        og_windows_websocket_set_error(GetLastError(), "could not bound the WebSocket close handshake");
        goto cleanup;
    }
    DWORD observed_close_timeout = 0;
    DWORD observed_close_timeout_size = sizeof(observed_close_timeout);
    if (!WinHttpQueryOption(
        upgraded,
        WINHTTP_OPTION_WEB_SOCKET_CLOSE_TIMEOUT,
        &observed_close_timeout,
        &observed_close_timeout_size
    ) || observed_close_timeout_size != sizeof(observed_close_timeout)
      || observed_close_timeout != close_timeout_ms) {
        DWORD error = GetLastError();
        og_windows_websocket_set_error(
            error == ERROR_SUCCESS ? ERROR_INVALID_DATA : error,
            "could not verify the bounded WebSocket close handshake"
        );
        goto cleanup;
    }
    if (InterlockedCompareExchange(&deadline.expired, 0, 0)) {
        og_windows_websocket_set_error(ERROR_TIMEOUT, "WebSocket connection deadline expired");
        goto cleanup;
    }

    OGWindowsWebSocket *state = calloc(1, sizeof(*state));
    if (state == NULL) {
        og_windows_websocket_set_error(ERROR_OUTOFMEMORY, "could not allocate WebSocket connection state");
        goto cleanup;
    }
    InitializeCriticalSection(&state->send_lock);
    InitializeCriticalSection(&state->receive_lock);
    state->session = session;
    state->connection = connection;
    state->websocket = upgraded;
    state->keepalive_milliseconds = keepalive_ms;
    session = NULL;
    connection = NULL;
    upgraded = NULL;
    *websocket = (int64_t)(intptr_t)state;
    success = 0;

cleanup:
    og_windows_websocket_stop_deadline(&deadline, watchdog);
    if (upgraded != NULL) WinHttpCloseHandle(upgraded);
    if (connection != NULL) WinHttpCloseHandle(connection);
    if (session != NULL) WinHttpCloseHandle(session);
    free(wide_headers);
    free(wide_target);
    free(wide_host);
    return success;
}

int og_windows_websocket_send(
    int64_t websocket,
    int is_text,
    const uint8_t *bytes,
    size_t length
) {
    OGWindowsWebSocket *state = og_windows_websocket_value(websocket);
    if (state == NULL) return -1;
    if ((bytes == NULL && length != 0) || length > UINT32_MAX) {
        og_windows_websocket_set_error(ERROR_INVALID_PARAMETER, "invalid WebSocket message payload");
        return -1;
    }

    EnterCriticalSection(&state->send_lock);
    if (InterlockedCompareExchange(&state->closed, 0, 0)) {
        LeaveCriticalSection(&state->send_lock);
        og_windows_websocket_set_error(ERROR_OPERATION_ABORTED, "WebSocket connection is closed");
        return -1;
    }

    WINHTTP_WEB_SOCKET_BUFFER_TYPE kind = is_text
        ? WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE
        : WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE;
    DWORD result = WinHttpWebSocketSend(
        state->websocket,
        kind,
        (void *)(uintptr_t)bytes,
        (DWORD)length
    );
    LeaveCriticalSection(&state->send_lock);
    if (result != ERROR_SUCCESS) {
        og_windows_websocket_set_error(result, "could not send a WebSocket message");
        return -1;
    }
    return 0;
}

int og_windows_websocket_receive(
    int64_t websocket,
    uint8_t *buffer,
    size_t capacity,
    size_t *bytes_read,
    int *message_kind,
    int *message_finished
) {
    OGWindowsWebSocket *state = og_windows_websocket_value(websocket);
    if (
        state == NULL || buffer == NULL || capacity == 0 || capacity > UINT32_MAX
        || bytes_read == NULL || message_kind == NULL || message_finished == NULL
    ) {
        og_windows_websocket_set_error(ERROR_INVALID_PARAMETER, "invalid WebSocket receive buffer");
        return -1;
    }

    EnterCriticalSection(&state->receive_lock);
    if (InterlockedCompareExchange(&state->closed, 0, 0)) {
        LeaveCriticalSection(&state->receive_lock);
        *bytes_read = 0;
        *message_kind = OG_WINDOWS_WEBSOCKET_MESSAGE_CLOSED;
        *message_finished = 1;
        return 0;
    }

    DWORD count = 0;
    WINHTTP_WEB_SOCKET_BUFFER_TYPE buffer_kind;
    DWORD result = WinHttpWebSocketReceive(
        state->websocket,
        buffer,
        (DWORD)capacity,
        &count,
        &buffer_kind
    );
    LeaveCriticalSection(&state->receive_lock);
    if (result != ERROR_SUCCESS) {
        og_windows_websocket_set_error(result, "could not receive a WebSocket message");
        return -1;
    }

    *bytes_read = (size_t)count;
    switch (buffer_kind) {
        case WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE:
            *message_kind = OG_WINDOWS_WEBSOCKET_MESSAGE_TEXT;
            *message_finished = 1;
            break;
        case WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE:
            *message_kind = OG_WINDOWS_WEBSOCKET_MESSAGE_TEXT;
            *message_finished = 0;
            break;
        case WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE:
            *message_kind = OG_WINDOWS_WEBSOCKET_MESSAGE_BINARY;
            *message_finished = 1;
            break;
        case WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE:
            *message_kind = OG_WINDOWS_WEBSOCKET_MESSAGE_BINARY;
            *message_finished = 0;
            break;
        case WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE:
            *message_kind = OG_WINDOWS_WEBSOCKET_MESSAGE_CLOSED;
            *message_finished = 1;
            break;
        default:
            og_windows_websocket_set_error(ERROR_INVALID_DATA, "WebSocket returned an unknown message kind");
            return -1;
    }
    return 0;
}

int og_windows_websocket_verify_keepalive(int64_t websocket) {
    OGWindowsWebSocket *state = og_windows_websocket_value(websocket);
    if (state == NULL) return -1;
    if (InterlockedCompareExchange(&state->closed, 0, 0)) {
        og_windows_websocket_set_error(ERROR_OPERATION_ABORTED, "WebSocket connection is closed");
        return -1;
    }
    if (state->keepalive_milliseconds != OG_WINDOWS_WEBSOCKET_KEEPALIVE_MS) {
        og_windows_websocket_set_error(ERROR_INVALID_DATA, "WebSocket keepalive is not armed");
        return -1;
    }
    return 0;
}

int og_windows_websocket_close(
    int64_t websocket,
    uint16_t code,
    const uint8_t *reason,
    size_t reason_length
) {
    OGWindowsWebSocket *state = og_windows_websocket_value(websocket);
    if (state == NULL) return -1;
    if (
        reason_length > WINHTTP_WEB_SOCKET_MAX_CLOSE_REASON_LENGTH
        || (reason == NULL && reason_length != 0)
    ) {
        og_windows_websocket_set_error(ERROR_INVALID_PARAMETER, "invalid WebSocket close reason");
        return -1;
    }
    if (InterlockedExchange(&state->closed, 1)) return 0;

    DWORD result = WinHttpWebSocketClose(
        state->websocket,
        (USHORT)code,
        (void *)(uintptr_t)reason,
        (DWORD)reason_length
    );
    if (result != ERROR_SUCCESS) {
        og_windows_websocket_set_error(result, "WebSocket close handshake failed");
        return -1;
    }
    return 0;
}

void og_windows_websocket_destroy(int64_t websocket) {
    OGWindowsWebSocket *state = og_windows_websocket_value(websocket);
    if (state == NULL) return;
    InterlockedExchange(&state->closed, 1);
    WinHttpCloseHandle(state->websocket);
    WinHttpCloseHandle(state->connection);
    WinHttpCloseHandle(state->session);
    DeleteCriticalSection(&state->receive_lock);
    DeleteCriticalSection(&state->send_lock);
    free(state);
}

int og_windows_websocket_last_error_code(void) {
    return (int)og_windows_websocket_error_code;
}

int og_windows_websocket_last_error_is_timeout(void) {
    return og_windows_websocket_error_code == ERROR_TIMEOUT
        || og_windows_websocket_error_code == ERROR_WINHTTP_TIMEOUT;
}

const char *og_windows_websocket_last_error_message(void) {
    return og_windows_websocket_error_message;
}

#else

int og_windows_websocket_is_available(void) { return 0; }
int og_windows_websocket_keepalive_interval_milliseconds(void) { return 0; }

#endif
