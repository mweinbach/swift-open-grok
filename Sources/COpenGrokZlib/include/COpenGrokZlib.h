#ifndef COPENGROK_ZLIB_SHIM_H
#define COPENGROK_ZLIB_SHIM_H

/* System zlib used for Git loose-object inflate/deflate on platforms without
 * Apple's Compression framework (notably Linux). Linked via the COpenGrokZlib
 * SwiftPM C target (`linkerSettings: linkedLibrary("z")`). */
#include <zlib.h>

#endif /* COPENGROK_ZLIB_SHIM_H */
