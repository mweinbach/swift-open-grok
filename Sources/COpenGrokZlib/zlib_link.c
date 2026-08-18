#include "COpenGrokZlib.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <limits.h>
#include <wchar.h>

typedef unsigned long (__cdecl *open_grok_compress_bound_fn)(unsigned long);
typedef int (__cdecl *open_grok_compress_fn)(
    unsigned char *, unsigned long *, const unsigned char *, unsigned long, int
);
typedef int (__cdecl *open_grok_uncompress_fn)(
    unsigned char *, unsigned long *, const unsigned char *, unsigned long
);

static INIT_ONCE open_grok_zlib_once = INIT_ONCE_STATIC_INIT;
static HMODULE open_grok_zlib_module = NULL;
static open_grok_compress_bound_fn open_grok_compress_bound_symbol = NULL;
static open_grok_compress_fn open_grok_compress_symbol = NULL;
static open_grok_uncompress_fn open_grok_uncompress_symbol = NULL;

static HMODULE open_grok_load_zlib_path(const wchar_t *path) {
    wchar_t full_path[32768];
    DWORD length = GetFullPathNameW(path, 32768, full_path, NULL);
    if (length == 0 || length >= 32768) {
        return NULL;
    }
    return LoadLibraryW(full_path);
}

static void open_grok_parent_directory(wchar_t *path) {
    wchar_t *backslash = wcsrchr(path, L'\\');
    wchar_t *slash = wcsrchr(path, L'/');
    wchar_t *last = backslash;
    if (slash != NULL && (last == NULL || slash > last)) {
        last = slash;
    }
    if (last != NULL) {
        *last = L'\0';
    }
}

static HMODULE open_grok_load_zlib_from_directory(const wchar_t *directory) {
    static const wchar_t *relative_paths[] = {
        L"zlib1.dll",
        L"..\\clangarm64\\bin\\zlib1.dll",
        L"..\\mingw64\\bin\\zlib1.dll",
        L"..\\mingw32\\bin\\zlib1.dll",
        L"..\\ucrt64\\bin\\zlib1.dll",
        L"..\\..\\clangarm64\\bin\\zlib1.dll",
        L"..\\..\\mingw64\\bin\\zlib1.dll",
        L"..\\..\\mingw32\\bin\\zlib1.dll",
        L"..\\..\\ucrt64\\bin\\zlib1.dll",
    };
    wchar_t candidate[32768];
    size_t count = sizeof(relative_paths) / sizeof(relative_paths[0]);
    for (size_t index = 0; index < count; index++) {
        int written = _snwprintf_s(
            candidate,
            32768,
            _TRUNCATE,
            L"%ls\\%ls",
            directory,
            relative_paths[index]
        );
        if (written > 0) {
            HMODULE module = open_grok_load_zlib_path(candidate);
            if (module != NULL) {
                return module;
            }
        }
    }
    return NULL;
}

static HMODULE open_grok_find_zlib(void) {
    wchar_t path[32768];
    DWORD length = GetModuleFileNameW(NULL, path, 32768);
    if (length > 0 && length < 32768) {
        open_grok_parent_directory(path);
        HMODULE module = open_grok_load_zlib_from_directory(path);
        if (module != NULL) {
            return module;
        }
    }

    length = SearchPathW(NULL, L"git.exe", NULL, 32768, path, NULL);
    if (length > 0 && length < 32768) {
        open_grok_parent_directory(path);
        HMODULE module = open_grok_load_zlib_from_directory(path);
        if (module != NULL) {
            return module;
        }
    }

    static const wchar_t *roots[] = {L"ProgramFiles", L"LocalAppData"};
    static const wchar_t *git_paths[] = {
        L"Git\\clangarm64\\bin\\zlib1.dll",
        L"Git\\mingw64\\bin\\zlib1.dll",
        L"Git\\mingw32\\bin\\zlib1.dll",
        L"Git\\ucrt64\\bin\\zlib1.dll",
        L"Programs\\Git\\clangarm64\\bin\\zlib1.dll",
        L"Programs\\Git\\mingw64\\bin\\zlib1.dll",
        L"Programs\\Git\\mingw32\\bin\\zlib1.dll",
        L"Programs\\Git\\ucrt64\\bin\\zlib1.dll",
    };
    wchar_t root[32768];
    wchar_t candidate[32768];
    size_t root_count = sizeof(roots) / sizeof(roots[0]);
    size_t path_count = sizeof(git_paths) / sizeof(git_paths[0]);
    for (size_t root_index = 0; root_index < root_count; root_index++) {
        length = GetEnvironmentVariableW(roots[root_index], root, 32768);
        if (length == 0 || length >= 32768) {
            continue;
        }
        for (size_t path_index = 0; path_index < path_count; path_index++) {
            int written = _snwprintf_s(
                candidate,
                32768,
                _TRUNCATE,
                L"%ls\\%ls",
                root,
                git_paths[path_index]
            );
            if (written > 0) {
                HMODULE module = open_grok_load_zlib_path(candidate);
                if (module != NULL) {
                    return module;
                }
            }
        }
    }
    return NULL;
}

static BOOL CALLBACK open_grok_initialize_zlib(
    PINIT_ONCE once,
    PVOID parameter,
    PVOID *context
) {
    (void)once;
    (void)parameter;
    (void)context;
    open_grok_zlib_module = open_grok_find_zlib();
    if (open_grok_zlib_module == NULL) {
        return TRUE;
    }
    open_grok_compress_bound_symbol = (open_grok_compress_bound_fn)GetProcAddress(
        open_grok_zlib_module,
        "compressBound"
    );
    open_grok_compress_symbol = (open_grok_compress_fn)GetProcAddress(
        open_grok_zlib_module,
        "compress2"
    );
    open_grok_uncompress_symbol = (open_grok_uncompress_fn)GetProcAddress(
        open_grok_zlib_module,
        "uncompress"
    );
    if (open_grok_compress_bound_symbol == NULL
        || open_grok_compress_symbol == NULL
        || open_grok_uncompress_symbol == NULL) {
        FreeLibrary(open_grok_zlib_module);
        open_grok_zlib_module = NULL;
        open_grok_compress_bound_symbol = NULL;
        open_grok_compress_symbol = NULL;
        open_grok_uncompress_symbol = NULL;
    }
    return TRUE;
}

static void open_grok_ensure_zlib(void) {
    InitOnceExecuteOnce(
        &open_grok_zlib_once,
        open_grok_initialize_zlib,
        NULL,
        NULL
    );
}

int open_grok_zlib_is_available(void) {
    open_grok_ensure_zlib();
    return open_grok_zlib_module != NULL;
}

size_t open_grok_zlib_compress_bound(size_t source_length) {
    open_grok_ensure_zlib();
    if (open_grok_compress_bound_symbol == NULL || source_length > ULONG_MAX) {
        return 0;
    }
    return (size_t)open_grok_compress_bound_symbol((unsigned long)source_length);
}

int open_grok_zlib_compress(
    uint8_t *destination,
    size_t *destination_length,
    const uint8_t *source,
    size_t source_length,
    int level
) {
    open_grok_ensure_zlib();
    if (open_grok_compress_symbol == NULL
        || destination_length == NULL
        || *destination_length > ULONG_MAX
        || source_length > ULONG_MAX) {
        return -6;
    }
    unsigned long output_length = (unsigned long)*destination_length;
    int status = open_grok_compress_symbol(
        destination,
        &output_length,
        source,
        (unsigned long)source_length,
        level
    );
    *destination_length = (size_t)output_length;
    return status;
}

int open_grok_zlib_uncompress(
    uint8_t *destination,
    size_t *destination_length,
    const uint8_t *source,
    size_t source_length
) {
    open_grok_ensure_zlib();
    if (open_grok_uncompress_symbol == NULL
        || destination_length == NULL
        || *destination_length > ULONG_MAX
        || source_length > ULONG_MAX) {
        return -6;
    }
    unsigned long output_length = (unsigned long)*destination_length;
    int status = open_grok_uncompress_symbol(
        destination,
        &output_length,
        source,
        (unsigned long)source_length
    );
    *destination_length = (size_t)output_length;
    return status;
}
#else
const char *open_grok_zlib_version(void) {
    return zlibVersion();
}
#endif
