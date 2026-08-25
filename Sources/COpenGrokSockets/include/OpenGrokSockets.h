#ifndef OPENGROK_SOCKETS_H
#define OPENGROK_SOCKETS_H

#include <stddef.h>
#include <stdint.h>
#include "OpenGrokWindowsWebSocket.h"

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
int og_socket_accept_with_timeout(
    OGSocketHandle listener,
    double timeout_seconds,
    OGSocketHandle *handle
);
int64_t og_socket_read(OGSocketHandle handle, void *buffer, size_t capacity);
int64_t og_socket_write_all(
    OGSocketHandle handle,
    const void *buffer,
    size_t length
);
int og_socket_close(OGSocketHandle handle);

typedef intptr_t OGTLSHandle;

#define OG_TLS_INVALID ((OGTLSHandle)0)

int og_tls_connect(
    const char *url,
    double timeout_seconds,
    const void *trusted_pem_bundle,
    size_t trusted_pem_bundle_length,
    OGTLSHandle *handle
);
int64_t og_tls_read(OGTLSHandle handle, void *buffer, size_t capacity);
int64_t og_tls_write_all(OGTLSHandle handle, const void *buffer, size_t length);
void og_tls_interrupt(OGTLSHandle handle);
void og_tls_destroy(OGTLSHandle handle);
int og_tls_last_error_code(void);
const char *og_tls_last_error_message(void);

int og_named_pipe_listener_create(const char *pipe_name, OGSocketHandle *listener);
int og_named_pipe_secure_listener_create(const char *pipe_name, OGSocketHandle *listener);
int og_named_pipe_listener_accept(OGSocketHandle listener, OGSocketHandle *handle);
int og_named_pipe_listener_close(OGSocketHandle listener);
int og_named_pipe_listener_destroy(OGSocketHandle listener);
int og_named_pipe_connect(
    const char *pipe_name,
    double timeout_seconds,
    OGSocketHandle *handle
);
int og_named_pipe_is_ready(const char *pipe_name);
int64_t og_named_pipe_read(OGSocketHandle handle, void *buffer, size_t capacity);
int64_t og_named_pipe_write_all(
    OGSocketHandle handle,
    const void *buffer,
    size_t length
);
int og_named_pipe_close(OGSocketHandle handle);
int og_named_pipe_peer_is_current_user(OGSocketHandle handle, int server_side);
int og_file_lock_acquire(
    const char *path,
    const char *contents,
    OGSocketHandle *handle
);
int64_t og_file_lock_read_contents(const char *path, void *buffer, size_t capacity);
int og_file_lock_release(OGSocketHandle handle);
int64_t og_file_canonical_path(const char *path, char *buffer, size_t capacity);
int og_file_create_owner_only(const char *path, OGSocketHandle *handle);
int og_file_open_owner_only_append(const char *path, OGSocketHandle *handle);
int og_file_open_owner_only_lock(const char *path, int create, OGSocketHandle *handle);
int64_t og_file_handle_write_all(OGSocketHandle handle, const void *buffer, size_t length);
int og_file_handle_flush(OGSocketHandle handle);
int og_file_handle_close(OGSocketHandle handle);
int64_t og_file_descriptor_write_all(int descriptor, const void *buffer, size_t length);
int og_file_descriptor_create_exclusive(const char *path, int mode);
int og_file_descriptor_flush(int descriptor);
int og_file_descriptor_close(int descriptor);
int og_file_apply_owner_only(const char *path);
int og_file_is_owner_only(const char *path);
int og_directory_secure_current_user(const char *path);
int og_path_is_private_to_current_user(const char *path, int require_directory);
int og_file_handle_is_private_to_current_user(OGSocketHandle handle, int require_directory);
int og_socket_last_error_code(void);
const char *og_socket_last_error_message(void);

#endif
