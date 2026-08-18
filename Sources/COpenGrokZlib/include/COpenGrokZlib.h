#ifndef COPENGROK_ZLIB_SHIM_H
#define COPENGROK_ZLIB_SHIM_H

#if defined(_WIN32)
#include <stddef.h>
#include <stdint.h>

int open_grok_zlib_is_available(void);
size_t open_grok_zlib_compress_bound(size_t source_length);
int open_grok_zlib_compress(
    uint8_t *destination,
    size_t *destination_length,
    const uint8_t *source,
    size_t source_length,
    int level
);
int open_grok_zlib_uncompress(
    uint8_t *destination,
    size_t *destination_length,
    const uint8_t *source,
    size_t source_length
);
#else
#include <zlib.h>
#endif

#endif /* COPENGROK_ZLIB_SHIM_H */
