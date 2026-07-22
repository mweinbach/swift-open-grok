/* Ensures the COpenGrokZlib target produces an object file and links libz.
 * All zlib symbols used by OpenGrokGitStatus come from the system libz. */
#include "COpenGrokZlib.h"

/* Reference a zlib symbol so the linker always pulls libz for this module. */
const char *open_grok_zlib_version(void) {
    return zlibVersion();
}
