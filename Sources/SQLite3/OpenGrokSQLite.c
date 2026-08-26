#include "OpenGrokSQLite.h"

int opengrok_sqlite_runtime_version(void) {
    return sqlite3_libversion_number();
}
