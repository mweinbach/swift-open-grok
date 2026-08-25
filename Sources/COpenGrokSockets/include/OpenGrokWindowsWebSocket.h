#ifndef OPENGROK_WINDOWS_WEBSOCKET_H
#define OPENGROK_WINDOWS_WEBSOCKET_H

#include <stddef.h>
#include <stdint.h>

#define OG_WINDOWS_WEBSOCKET_MESSAGE_CLOSED 0
#define OG_WINDOWS_WEBSOCKET_MESSAGE_TEXT 1
#define OG_WINDOWS_WEBSOCKET_MESSAGE_BINARY 2

int og_windows_websocket_is_available(void);
int og_windows_websocket_keepalive_interval_milliseconds(void);

int og_windows_websocket_connect(
    const char *host,
    uint16_t port,
    const char *target,
    const char *headers,
    int use_tls,
    double timeout_seconds,
    int64_t *websocket,
    int *http_status
);

int og_windows_websocket_send(
    int64_t websocket,
    int is_text,
    const uint8_t *bytes,
    size_t length
);

int og_windows_websocket_receive(
    int64_t websocket,
    uint8_t *buffer,
    size_t capacity,
    size_t *bytes_read,
    int *message_kind,
    int *message_finished
);

int og_windows_websocket_verify_keepalive(int64_t websocket);

int og_windows_websocket_close(
    int64_t websocket,
    uint16_t code,
    const uint8_t *reason,
    size_t reason_length
);

void og_windows_websocket_destroy(int64_t websocket);

int og_windows_websocket_last_error_code(void);
int og_windows_websocket_last_error_is_timeout(void);
const char *og_windows_websocket_last_error_message(void);

#endif
