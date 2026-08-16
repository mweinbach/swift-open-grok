#include "OpenGrokSockets.h"

#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <io.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
typedef int og_socklen_t;
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
typedef socklen_t og_socklen_t;
#endif

static _Thread_local int og_last_error = 0;
static _Thread_local char og_last_error_text[256];

static void og_set_error(int code, const char *detail) {
    og_last_error = code;
    if (detail && detail[0] != '\0') {
        snprintf(og_last_error_text, sizeof(og_last_error_text), "%s", detail);
        return;
    }
#ifdef _WIN32
    FormatMessageA(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL,
        (DWORD)code,
        0,
        og_last_error_text,
        (DWORD)sizeof(og_last_error_text),
        NULL
    );
#else
    snprintf(og_last_error_text, sizeof(og_last_error_text), "%s", strerror(code));
#endif
}

static void og_set_system_error(const char *detail) {
#ifdef _WIN32
    og_set_error((int)WSAGetLastError(), detail);
#else
    og_set_error(errno, detail);
#endif
}

#ifdef _WIN32
static void og_set_windows_error(const char *detail) {
    og_set_error((int)GetLastError(), detail);
}

static wchar_t *og_utf8_to_wide(const char *value) {
    if (!value) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return NULL;
    }
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (length <= 0) return NULL;
    wchar_t *wide = (wchar_t *)calloc((size_t)length, sizeof(wchar_t));
    if (!wide) {
        SetLastError(ERROR_OUTOFMEMORY);
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, wide, length) <= 0) {
        free(wide);
        return NULL;
    }
    return wide;
}
#endif

int og_socket_last_error_code(void) {
    return og_last_error;
}

const char *og_socket_last_error_message(void) {
    return og_last_error_text;
}

#ifdef _WIN32

static INIT_ONCE og_winsock_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK og_start_winsock(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    WSADATA data;
    return WSAStartup(MAKEWORD(2, 2), &data) == 0;
}

static int og_ensure_winsock(void) {
    BOOL ok = InitOnceExecuteOnce(&og_winsock_once, og_start_winsock, NULL, NULL);
    if (!ok) {
        og_set_system_error("WSAStartup failed");
        return -1;
    }
    return 0;
}

static SOCKET og_socket_value(OGSocketHandle handle) {
    return (SOCKET)(uintptr_t)handle;
}

static OGSocketHandle og_socket_handle(SOCKET socket_value) {
    return (OGSocketHandle)(uintptr_t)socket_value;
}

static int og_is_in_progress(int code) {
    return code == WSAEINPROGRESS || code == WSAEWOULDBLOCK || code == WSAEALREADY;
}

static int og_set_nonblocking(SOCKET socket_value, int enabled) {
    u_long mode = enabled ? 1UL : 0UL;
    return ioctlsocket(socket_value, FIONBIO, &mode);
}

#else

static int og_socket_value(OGSocketHandle handle) {
    return (int)handle;
}

static OGSocketHandle og_socket_handle(int socket_value) {
    return (OGSocketHandle)socket_value;
}

static int og_is_in_progress(int code) {
    return code == EINPROGRESS || code == EWOULDBLOCK || code == EALREADY;
}

static int og_set_nonblocking(int socket_value, int enabled) {
    int flags = fcntl(socket_value, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(socket_value, F_SETFL, enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK));
}

#endif

/* Ask for EPIPE instead of SIGPIPE on a dead peer. Linux exposes this per-call
   as MSG_NOSIGNAL; Apple exposes it per-socket as SO_NOSIGPIPE and has no send
   flag. Exactly one of the two applies on any given platform, so both are
   defined unconditionally and each collapses to a no-op where it is absent. */
#if defined(MSG_NOSIGNAL)
#define OG_SEND_NOSIGNAL_FLAGS MSG_NOSIGNAL
#else
#define OG_SEND_NOSIGNAL_FLAGS 0
#endif

static void og_disable_sigpipe(OGSocketHandle handle) {
#if !defined(_WIN32) && defined(SO_NOSIGPIPE)
    int on = 1;
    (void)setsockopt(
        og_socket_value(handle), SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on)
    );
#else
    (void)handle;
#endif
}

static int og_wait_connected(
    OGSocketHandle handle,
    double timeout_seconds
) {
    int timeout_ms = timeout_seconds <= 0.0
        ? 0
        : (int)(timeout_seconds * 1000.0 + 0.5);
    if (timeout_ms < 1) timeout_ms = 1;

#ifdef _WIN32
    SOCKET socket_value = og_socket_value(handle);
    fd_set writable;
    FD_ZERO(&writable);
    FD_SET(socket_value, &writable);
    struct timeval timeout;
    timeout.tv_sec = timeout_ms / 1000;
    timeout.tv_usec = (timeout_ms % 1000) * 1000;
    int selected = select(0, NULL, &writable, NULL, &timeout);
#else
    struct pollfd descriptor;
    descriptor.fd = og_socket_value(handle);
    descriptor.events = POLLOUT;
    descriptor.revents = 0;
    int selected = poll(&descriptor, 1, timeout_ms);
#endif
    if (selected == 0) {
        og_set_error(ETIMEDOUT, "connection timed out");
        return -1;
    }
    if (selected < 0) {
        og_set_system_error(NULL);
        return -1;
    }

    int socket_error = 0;
#ifdef _WIN32
    int length = (int)sizeof(socket_error);
    if (getsockopt(og_socket_value(handle), SOL_SOCKET, SO_ERROR, (char *)&socket_error, &length) != 0) {
        og_set_system_error(NULL);
        return -1;
    }
#else
    socklen_t length = (socklen_t)sizeof(socket_error);
    if (getsockopt(og_socket_value(handle), SOL_SOCKET, SO_ERROR, &socket_error, &length) != 0) {
        og_set_system_error(NULL);
        return -1;
    }
#endif
    if (socket_error != 0) {
        og_set_error(socket_error, NULL);
        return -1;
    }
    return 0;
}

static int og_connect_socket(
    OGSocketHandle handle,
    const struct sockaddr *address,
    og_socklen_t address_length,
    double timeout_seconds
) {
#ifdef _WIN32
    SOCKET socket_value = og_socket_value(handle);
#else
    int socket_value = og_socket_value(handle);
#endif
    if (og_set_nonblocking(socket_value, 1) != 0) {
        og_set_system_error(NULL);
        return -1;
    }
    int connected = connect(socket_value, address, address_length);
    if (connected != 0) {
#ifdef _WIN32
        int code = WSAGetLastError();
#else
        int code = errno;
#endif
        if (!og_is_in_progress(code)) {
            og_set_error(code, NULL);
            return -1;
        }
        if (og_wait_connected(handle, timeout_seconds) != 0) return -1;
    }
    if (og_set_nonblocking(socket_value, 0) != 0) {
        og_set_system_error(NULL);
        return -1;
    }
    return 0;
}

int og_socket_tcp_listen(
    const char *host,
    uint16_t port,
    OGSocketHandle *handle,
    uint16_t *bound_port
) {
    if (!host || !handle || !bound_port) {
        og_set_error(EINVAL, "invalid TCP listener arguments");
        return -1;
    }
#ifdef _WIN32
    if (og_ensure_winsock() != 0) return -1;
#endif
    char service[16];
    snprintf(service, sizeof(service), "%u", (unsigned)port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    struct addrinfo *results = NULL;
    int lookup = getaddrinfo(host, service, &hints, &results);
    if (lookup != 0) {
#ifdef _WIN32
        og_set_error(lookup, gai_strerrorA(lookup));
#else
        og_set_error(lookup, gai_strerror(lookup));
#endif
        return -1;
    }
    int result = -1;
    for (struct addrinfo *entry = results; entry; entry = entry->ai_next) {
#ifdef _WIN32
        SOCKET socket_value = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (socket_value == INVALID_SOCKET) continue;
        BOOL reuse = TRUE;
        setsockopt(socket_value, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));
        if (bind(socket_value, entry->ai_addr, (int)entry->ai_addrlen) != 0 || listen(socket_value, 128) != 0) {
            closesocket(socket_value);
            continue;
        }
        struct sockaddr_storage resolved;
        int resolved_length = (int)sizeof(resolved);
        if (getsockname(socket_value, (struct sockaddr *)&resolved, &resolved_length) != 0) {
            closesocket(socket_value);
            continue;
        }
#else
        int socket_value = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (socket_value < 0) continue;
        int reuse = 1;
        setsockopt(socket_value, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        if (bind(socket_value, entry->ai_addr, entry->ai_addrlen) != 0 || listen(socket_value, 128) != 0) {
            close(socket_value);
            continue;
        }
        struct sockaddr_storage resolved;
        socklen_t resolved_length = (socklen_t)sizeof(resolved);
        if (getsockname(socket_value, (struct sockaddr *)&resolved, &resolved_length) != 0) {
            close(socket_value);
            continue;
        }
#endif
        *handle = og_socket_handle(socket_value);
        if (resolved.ss_family == AF_INET) {
            *bound_port = ntohs(((struct sockaddr_in *)&resolved)->sin_port);
        } else if (resolved.ss_family == AF_INET6) {
            *bound_port = ntohs(((struct sockaddr_in6 *)&resolved)->sin6_port);
        } else {
            *bound_port = port;
        }
        result = 0;
        break;
    }
    freeaddrinfo(results);
    if (result != 0) og_set_system_error("could not bind TCP listener");
    return result;
}

int og_socket_tcp_connect(
    const char *host,
    uint16_t port,
    double timeout_seconds,
    OGSocketHandle *handle
) {
    if (!host || !handle) {
        og_set_error(EINVAL, "invalid TCP connection arguments");
        return -1;
    }
#ifdef _WIN32
    if (og_ensure_winsock() != 0) return -1;
#endif
    char service[16];
    snprintf(service, sizeof(service), "%u", (unsigned)port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *results = NULL;
    int lookup = getaddrinfo(host, service, &hints, &results);
    if (lookup != 0) {
#ifdef _WIN32
        og_set_error(lookup, gai_strerrorA(lookup));
#else
        og_set_error(lookup, gai_strerror(lookup));
#endif
        return -1;
    }
    int result = -1;
    for (struct addrinfo *entry = results; entry; entry = entry->ai_next) {
#ifdef _WIN32
        SOCKET socket_value = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (socket_value == INVALID_SOCKET) continue;
        OGSocketHandle candidate = og_socket_handle(socket_value);
#else
        int socket_value = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (socket_value < 0) continue;
        OGSocketHandle candidate = og_socket_handle(socket_value);
#endif
        if (og_connect_socket(candidate, entry->ai_addr, (og_socklen_t)entry->ai_addrlen, timeout_seconds) == 0) {
            og_disable_sigpipe(candidate);
            *handle = candidate;
            result = 0;
            break;
        }
#ifdef _WIN32
        closesocket(socket_value);
#else
        close(socket_value);
#endif
    }
    freeaddrinfo(results);
    if (result != 0 && og_last_error_text[0] == '\0') og_set_system_error("could not connect TCP socket");
    return result;
}

#ifndef _WIN32

static int og_fill_unix_address(const char *path, struct sockaddr_un *address, socklen_t *length) {
    if (!path || !address || !length) {
        og_set_error(EINVAL, "invalid Unix socket arguments");
        return -1;
    }
    size_t path_length = strlen(path);
    if (path_length >= sizeof(address->sun_path)) {
        og_set_error(ENAMETOOLONG, "Unix socket path is too long");
        return -1;
    }
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, path, path_length);
    *length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + path_length + 1);
    return 0;
}

int og_socket_unix_listen(const char *path, OGSocketHandle *handle) {
    if (!handle) {
        og_set_error(EINVAL, "invalid Unix listener handle");
        return -1;
    }
    struct sockaddr_un address;
    socklen_t length;
    if (og_fill_unix_address(path, &address, &length) != 0) return -1;
    int socket_value = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_value < 0) {
        og_set_system_error(NULL);
        return -1;
    }
    if (bind(socket_value, (struct sockaddr *)&address, length) != 0 || listen(socket_value, 128) != 0) {
        og_set_system_error("could not bind Unix listener");
        close(socket_value);
        return -1;
    }
    *handle = og_socket_handle(socket_value);
    return 0;
}

int og_socket_unix_connect(
    const char *path,
    double timeout_seconds,
    OGSocketHandle *handle
) {
    if (!handle) {
        og_set_error(EINVAL, "invalid Unix connection handle");
        return -1;
    }
    struct sockaddr_un address;
    socklen_t length;
    if (og_fill_unix_address(path, &address, &length) != 0) return -1;
    int socket_value = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_value < 0) {
        og_set_system_error(NULL);
        return -1;
    }
    OGSocketHandle candidate = og_socket_handle(socket_value);
    if (og_connect_socket(candidate, (struct sockaddr *)&address, length, timeout_seconds) != 0) {
        close(socket_value);
        return -1;
    }
    og_disable_sigpipe(candidate);
    *handle = candidate;
    return 0;
}

#else

int og_socket_unix_listen(const char *path, OGSocketHandle *handle) {
    (void)path;
    (void)handle;
    og_set_error(WSAEAFNOSUPPORT, "Windows leader IPC requires named pipes");
    return -1;
}

int og_socket_unix_connect(
    const char *path,
    double timeout_seconds,
    OGSocketHandle *handle
) {
    (void)path;
    (void)timeout_seconds;
    (void)handle;
    og_set_error(WSAEAFNOSUPPORT, "Windows leader IPC requires named pipes");
    return -1;
}

#endif

int og_socket_accept(OGSocketHandle listener, OGSocketHandle *handle) {
    if (!handle) {
#ifdef _WIN32
        og_set_error(WSAEINVAL, "invalid accept handle");
#else
        og_set_error(EINVAL, "invalid accept handle");
#endif
        return -1;
    }
#ifdef _WIN32
    SOCKET accepted = accept(og_socket_value(listener), NULL, NULL);
    if (accepted == INVALID_SOCKET) {
        og_set_system_error(NULL);
        return -1;
    }
#else
    int accepted = accept(og_socket_value(listener), NULL, NULL);
    if (accepted < 0) {
        og_set_system_error(NULL);
        return -1;
    }
#endif
    og_disable_sigpipe(og_socket_handle(accepted));
    *handle = og_socket_handle(accepted);
    return 0;
}

int64_t og_socket_read(OGSocketHandle handle, void *buffer, size_t capacity) {
    if (!buffer || capacity == 0) return 0;
    for (;;) {
#ifdef _WIN32
        int count = recv(og_socket_value(handle), (char *)buffer, (int)capacity, 0);
        if (count >= 0) return count;
        int code = WSAGetLastError();
        if (code == WSAEINTR) continue;
        og_set_error(code, NULL);
        return -1;
#else
        ssize_t count = read(og_socket_value(handle), buffer, capacity);
        if (count >= 0) return (int64_t)count;
        if (errno == EINTR) continue;
        og_set_system_error(NULL);
        return -1;
#endif
    }
}

int64_t og_socket_write_all(
    OGSocketHandle handle,
    const void *buffer,
    size_t length
) {
    size_t written = 0;
    while (written < length) {
#ifdef _WIN32
        int count = send(og_socket_value(handle), (const char *)buffer + written, (int)(length - written), 0);
        if (count > 0) {
            written += (size_t)count;
            continue;
        }
        if (count == 0) {
            og_set_error(WSAECONNRESET, "socket closed while writing");
            return -1;
        }
        int code = WSAGetLastError();
        if (code == WSAEINTR) continue;
        og_set_error(code, NULL);
        return -1;
#else
        /* `write()` on a socket raises SIGPIPE once the peer is gone, and
           SIGPIPE is fatal by default — which killed the entire test process on
           Linux a moment into the suite. Apple never reaches this branch (the
           Swift layer takes the Network.framework path whenever it can import
           it), so the failure was invisible to every macOS run. `send` with
           MSG_NOSIGNAL asks the kernel for EPIPE instead of the signal;
           platforms without the flag rely on SO_NOSIGPIPE, set at accept/
           connect time by og_disable_sigpipe. */
        ssize_t count = send(
            og_socket_value(handle),
            (const char *)buffer + written,
            length - written,
            OG_SEND_NOSIGNAL_FLAGS
        );
        if (count > 0) {
            written += (size_t)count;
            continue;
        }
        if (count == 0) {
            og_set_error(EPIPE, "socket closed while writing");
            return -1;
        }
        if (errno == EINTR) continue;
        og_set_system_error(NULL);
        return -1;
#endif
    }
    return (int64_t)written;
}

int og_socket_close(OGSocketHandle handle) {
#ifdef _WIN32
    if (handle == OG_SOCKET_INVALID) return 0;
    SOCKET socket_value = og_socket_value(handle);
    shutdown(socket_value, SD_BOTH);
    return closesocket(socket_value);
#else
    if (handle == OG_SOCKET_INVALID) return 0;
    shutdown(og_socket_value(handle), SHUT_RDWR);
    return close(og_socket_value(handle));
#endif
}

#ifdef _WIN32

typedef struct OGNamedPipeListener {
    wchar_t *pipe_name;
    HANDLE pending;
    CRITICAL_SECTION lock;
    int closed;
} OGNamedPipeListener;

static HANDLE og_named_pipe_create_instance(const wchar_t *pipe_name, int first) {
    DWORD open_mode = PIPE_ACCESS_DUPLEX;
    if (first) open_mode |= FILE_FLAG_FIRST_PIPE_INSTANCE;
    return CreateNamedPipeW(
        pipe_name,
        open_mode,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        64 * 1024,
        64 * 1024,
        0,
        NULL
    );
}

int og_named_pipe_listener_create(const char *pipe_name, OGSocketHandle *listener) {
    if (!pipe_name || !listener) {
        og_set_error(ERROR_INVALID_PARAMETER, "invalid named-pipe listener arguments");
        return -1;
    }
    wchar_t *wide = og_utf8_to_wide(pipe_name);
    if (!wide) {
        og_set_windows_error("named-pipe name is not valid UTF-8");
        return -1;
    }
    HANDLE pending = og_named_pipe_create_instance(wide, 1);
    if (pending == INVALID_HANDLE_VALUE) {
        og_set_windows_error("could not create named-pipe listener");
        free(wide);
        return -1;
    }
    OGNamedPipeListener *state = (OGNamedPipeListener *)calloc(1, sizeof(*state));
    if (!state) {
        CloseHandle(pending);
        free(wide);
        og_set_error(ERROR_OUTOFMEMORY, "could not allocate named-pipe listener");
        return -1;
    }
    state->pipe_name = wide;
    state->pending = pending;
    InitializeCriticalSection(&state->lock);
    *listener = (OGSocketHandle)(uintptr_t)state;
    return 0;
}

int og_named_pipe_listener_accept(OGSocketHandle listener, OGSocketHandle *handle) {
    if (listener == OG_SOCKET_INVALID || !handle) {
        og_set_error(ERROR_INVALID_PARAMETER, "invalid named-pipe accept arguments");
        return -1;
    }
    OGNamedPipeListener *state = (OGNamedPipeListener *)(uintptr_t)listener;
    EnterCriticalSection(&state->lock);
    if (state->closed) {
        LeaveCriticalSection(&state->lock);
        og_set_error(ERROR_OPERATION_ABORTED, "named-pipe listener is closed");
        return -1;
    }
    if (state->pending == INVALID_HANDLE_VALUE) {
        state->pending = og_named_pipe_create_instance(state->pipe_name, 0);
    }
    HANDLE pending = state->pending;
    LeaveCriticalSection(&state->lock);
    if (pending == INVALID_HANDLE_VALUE) {
        og_set_windows_error("could not create the next named-pipe instance");
        return -1;
    }

    BOOL connected = ConnectNamedPipe(pending, NULL);
    if (!connected && GetLastError() != ERROR_PIPE_CONNECTED) {
        og_set_windows_error("could not accept a named-pipe client");
        return -1;
    }

    EnterCriticalSection(&state->lock);
    if (state->closed) {
        LeaveCriticalSection(&state->lock);
        CloseHandle(pending);
        og_set_error(ERROR_OPERATION_ABORTED, "named-pipe listener is closed");
        return -1;
    }
    if (state->pending == pending) {
        state->pending = og_named_pipe_create_instance(state->pipe_name, 0);
    }
    LeaveCriticalSection(&state->lock);
    *handle = (OGSocketHandle)(uintptr_t)pending;
    return 0;
}

int og_named_pipe_listener_close(OGSocketHandle listener) {
    if (listener == OG_SOCKET_INVALID) return 0;
    OGNamedPipeListener *state = (OGNamedPipeListener *)(uintptr_t)listener;
    EnterCriticalSection(&state->lock);
    if (!state->closed) {
        state->closed = 1;
        if (state->pending != INVALID_HANDLE_VALUE) {
            CancelIoEx(state->pending, NULL);
            CloseHandle(state->pending);
            state->pending = INVALID_HANDLE_VALUE;
        }
    }
    LeaveCriticalSection(&state->lock);
    return 0;
}

int og_named_pipe_listener_destroy(OGSocketHandle listener) {
    if (listener == OG_SOCKET_INVALID) return 0;
    OGNamedPipeListener *state = (OGNamedPipeListener *)(uintptr_t)listener;
    og_named_pipe_listener_close(listener);
    DeleteCriticalSection(&state->lock);
    free(state->pipe_name);
    free(state);
    return 0;
}

int og_named_pipe_connect(
    const char *pipe_name,
    double timeout_seconds,
    OGSocketHandle *handle
) {
    if (!pipe_name || !handle) {
        og_set_error(ERROR_INVALID_PARAMETER, "invalid named-pipe connection arguments");
        return -1;
    }
    wchar_t *wide = og_utf8_to_wide(pipe_name);
    if (!wide) {
        og_set_windows_error("named-pipe name is not valid UTF-8");
        return -1;
    }
    double milliseconds = timeout_seconds <= 0.0 ? 1.0 : timeout_seconds * 1000.0;
    DWORD timeout = milliseconds >= (double)MAXDWORD ? MAXDWORD : (DWORD)(milliseconds + 0.5);
    if (!WaitNamedPipeW(wide, timeout)) {
        og_set_windows_error("timed out waiting for named-pipe leader");
        free(wide);
        return -1;
    }
    HANDLE pipe = CreateFileW(
        wide,
        GENERIC_READ | GENERIC_WRITE,
        0,
        NULL,
        OPEN_EXISTING,
        0,
        NULL
    );
    free(wide);
    if (pipe == INVALID_HANDLE_VALUE) {
        og_set_windows_error("could not connect to named-pipe leader");
        return -1;
    }
    DWORD mode = PIPE_READMODE_BYTE;
    if (!SetNamedPipeHandleState(pipe, &mode, NULL, NULL)) {
        og_set_windows_error("could not configure named-pipe byte mode");
        CloseHandle(pipe);
        return -1;
    }
    *handle = (OGSocketHandle)(uintptr_t)pipe;
    return 0;
}

int og_named_pipe_is_ready(const char *pipe_name) {
    wchar_t *wide = og_utf8_to_wide(pipe_name);
    if (!wide) return 0;
    BOOL ready = WaitNamedPipeW(wide, 1);
    DWORD error = ready ? ERROR_SUCCESS : GetLastError();
    free(wide);
    if (ready) return 1;
    return error == ERROR_FILE_NOT_FOUND ? 0 : 1;
}

int64_t og_named_pipe_read(OGSocketHandle handle, void *buffer, size_t capacity) {
    if (!buffer || capacity == 0) return 0;
    DWORD count = 0;
    if (ReadFile((HANDLE)(uintptr_t)handle, buffer, (DWORD)capacity, &count, NULL)) {
        return (int64_t)count;
    }
    DWORD error = GetLastError();
    if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED) return 0;
    og_set_error((int)error, NULL);
    return -1;
}

int64_t og_named_pipe_write_all(
    OGSocketHandle handle,
    const void *buffer,
    size_t length
) {
    size_t written = 0;
    while (written < length) {
        DWORD count = 0;
        DWORD chunk = length - written > (size_t)MAXDWORD
            ? MAXDWORD
            : (DWORD)(length - written);
        if (!WriteFile(
                (HANDLE)(uintptr_t)handle,
                (const char *)buffer + written,
                chunk,
                &count,
                NULL
            )) {
            og_set_windows_error("named-pipe write failed");
            return -1;
        }
        if (count == 0) {
            og_set_error(ERROR_BROKEN_PIPE, "named pipe closed while writing");
            return -1;
        }
        written += (size_t)count;
    }
    return (int64_t)written;
}

int og_named_pipe_close(OGSocketHandle handle) {
    if (handle == OG_SOCKET_INVALID) return 0;
    HANDLE pipe = (HANDLE)(uintptr_t)handle;
    CancelIoEx(pipe, NULL);
    return CloseHandle(pipe) ? 0 : -1;
}

int og_file_lock_acquire(
    const char *path,
    const char *contents,
    OGSocketHandle *handle
) {
    if (!path || !handle) {
        og_set_error(ERROR_INVALID_PARAMETER, "invalid file-lock arguments");
        return -1;
    }
    wchar_t *wide = og_utf8_to_wide(path);
    if (!wide) {
        og_set_windows_error("file-lock path is not valid UTF-8");
        return -1;
    }
    HANDLE file = CreateFileW(
        wide,
        GENERIC_READ | GENERIC_WRITE,
        0,
        NULL,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    free(wide);
    if (file == INVALID_HANDLE_VALUE) {
        og_set_windows_error("could not acquire exclusive file lock");
        return -1;
    }
    SetFilePointer(file, 0, NULL, FILE_BEGIN);
    if (!SetEndOfFile(file)) {
        og_set_windows_error("could not truncate file lock");
        CloseHandle(file);
        return -1;
    }
    if (contents && contents[0] != '\0') {
        DWORD length = (DWORD)strlen(contents);
        DWORD count = 0;
        if (!WriteFile(file, contents, length, &count, NULL) || count != length) {
            og_set_windows_error("could not write file-lock owner");
            CloseHandle(file);
            return -1;
        }
    }
    FlushFileBuffers(file);
    *handle = (OGSocketHandle)(uintptr_t)file;
    return 0;
}

int og_file_lock_release(OGSocketHandle handle) {
    if (handle == OG_SOCKET_INVALID) return 0;
    return CloseHandle((HANDLE)(uintptr_t)handle) ? 0 : -1;
}

#else

int og_named_pipe_listener_create(const char *pipe_name, OGSocketHandle *listener) {
    (void)pipe_name; (void)listener;
    og_set_error(ENOTSUP, "named pipes are only available on Windows");
    return -1;
}
int og_named_pipe_listener_accept(OGSocketHandle listener, OGSocketHandle *handle) {
    (void)listener; (void)handle;
    og_set_error(ENOTSUP, "named pipes are only available on Windows");
    return -1;
}
int og_named_pipe_listener_close(OGSocketHandle listener) { (void)listener; return 0; }
int og_named_pipe_listener_destroy(OGSocketHandle listener) { (void)listener; return 0; }
int og_named_pipe_connect(const char *pipe_name, double timeout_seconds, OGSocketHandle *handle) {
    (void)pipe_name; (void)timeout_seconds; (void)handle;
    og_set_error(ENOTSUP, "named pipes are only available on Windows");
    return -1;
}
int og_named_pipe_is_ready(const char *pipe_name) { (void)pipe_name; return 0; }
int64_t og_named_pipe_read(OGSocketHandle handle, void *buffer, size_t capacity) {
    (void)handle; (void)buffer; (void)capacity;
    og_set_error(ENOTSUP, "named pipes are only available on Windows");
    return -1;
}
int64_t og_named_pipe_write_all(OGSocketHandle handle, const void *buffer, size_t length) {
    (void)handle; (void)buffer; (void)length;
    og_set_error(ENOTSUP, "named pipes are only available on Windows");
    return -1;
}
int og_named_pipe_close(OGSocketHandle handle) { (void)handle; return 0; }
int og_file_lock_acquire(const char *path, const char *contents, OGSocketHandle *handle) {
    (void)path; (void)contents; (void)handle;
    og_set_error(ENOTSUP, "portable file locks are only available on Windows");
    return -1;
}
int og_file_lock_release(OGSocketHandle handle) { (void)handle; return 0; }

#endif
