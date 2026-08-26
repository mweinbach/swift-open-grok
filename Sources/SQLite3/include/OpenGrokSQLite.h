#ifndef OPEN_GROK_SQLITE_H
#define OPEN_GROK_SQLITE_H

#if defined(_WIN32)
#include <winsqlite/winsqlite3.h>
#else
#include <sqlite3.h>
#endif

int opengrok_sqlite_runtime_version(void);

#endif
