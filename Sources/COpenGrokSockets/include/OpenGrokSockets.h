#ifndef OPENGROK_SOCKETS_H
#define OPENGROK_SOCKETS_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
typedef intptr_t OGSocketHandle;
#else
typedef int64_t OGSocketHandle;
#endif

#define OG_SOCKET_INVALID ((OGSocketHandle)-1)

int og_socket_tcp_listen(
    const char *host,
    uint16_t port,
    OGSocketHandle *handle,
    uint16_t *bound_port
);
int og_socket_tcp_connect(
    const char *host,
    uint16_t port,
    double timeout_seconds,
    OGSocketHandle *handle
);
int og_socket_unix_listen(const char *path, OGSocketHandle *handle);
int og_socket_unix_connect(
    const char *path,
    double timeout_seconds,
    OGSocketHandle *handle
);
int og_socket_accept(OGSocketHandle listener, OGSocketHandle *handle);
int64_t og_socket_read(OGSocketHandle handle, void *buffer, size_t capacity);
int64_t og_socket_write_all(
    OGSocketHandle handle,
    const void *buffer,
    size_t length
);
int og_socket_close(OGSocketHandle handle);
int og_socket_last_error_code(void);
const char *og_socket_last_error_message(void);

#endif
