#include "OpenGrokWASAPI.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propidl.h>

enum {
    OG_WASAPI_START_TIMEOUT_MS = 5000,
    OG_WASAPI_START_FAILURE_STOP_TIMEOUT_MS = 2000,
    OG_WASAPI_MAX_PACKET_BYTES = 1024 * 1024,
};

/* The SDK declares these identifiers but its ARM64 uuid.lib does not contain
   their definitions. Private constants keep COM activation link-stable. */
static const CLSID og_mmdevice_enumerator_clsid = {
    0xbcde0395,
    0xe52f,
    0x467c,
    {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e},
};
static const IID og_immdevice_enumerator_iid = {
    0xa95664d2,
    0x9614,
    0x4f35,
    {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6},
};
static const IID og_iaudio_client_iid = {
    0x1cb9ad4c,
    0xdbfa,
    0x4c32,
    {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2},
};
static const IID og_iaudio_capture_client_iid = {
    0xc8adbd64,
    0xe71e,
    0x48a0,
    {0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17},
};

typedef struct {
    HANDLE thread;
    HANDLE ready;
    HANDLE stop;
    HANDLE audio_ready;
    volatile LONG references;
    volatile LONG startup_reported;
    uint32_t sample_rate;
    HRESULT startup_status;
    char startup_detail[256];
    OGWASAPIAudioCallback audio_callback;
    OGWASAPIErrorCallback error_callback;
    OGWASAPIContextRelease release_context;
    void *context;
} OGWASAPISession;

static _Thread_local HRESULT og_wasapi_error_code;
static _Thread_local char og_wasapi_error_detail[256];

static void og_wasapi_set_error(HRESULT status, const char *detail) {
    og_wasapi_error_code = FAILED(status) ? status : E_FAIL;
    snprintf(
        og_wasapi_error_detail,
        sizeof(og_wasapi_error_detail),
        "%s (HRESULT 0x%08lx)",
        detail,
        (unsigned long)(uint32_t)og_wasapi_error_code
    );
}

static void og_wasapi_release_session(OGWASAPISession *session) {
    if (InterlockedDecrement(&session->references) != 0) return;
    if (session->thread != NULL) CloseHandle(session->thread);
    if (session->audio_ready != NULL) CloseHandle(session->audio_ready);
    if (session->stop != NULL) CloseHandle(session->stop);
    if (session->ready != NULL) CloseHandle(session->ready);
    free(session);
}

static void og_wasapi_publish_startup(
    OGWASAPISession *session,
    HRESULT status,
    const char *detail
) {
    if (InterlockedCompareExchange(&session->startup_reported, 1, 0) != 0) return;
    session->startup_status = status;
    snprintf(session->startup_detail, sizeof(session->startup_detail), "%s", detail);
    SetEvent(session->ready);
}

static HRESULT og_wasapi_default_capture_device(IMMDevice **device) {
    IMMDeviceEnumerator *enumerator = NULL;
    HRESULT status = CoCreateInstance(
        &og_mmdevice_enumerator_clsid,
        NULL,
        CLSCTX_INPROC_SERVER,
        &og_immdevice_enumerator_iid,
        (void **)&enumerator
    );
    if (FAILED(status)) return status;

    /* cpal 0.15 selects eConsole for its Windows default capture endpoint. */
    status = IMMDeviceEnumerator_GetDefaultAudioEndpoint(
        enumerator,
        eCapture,
        eConsole,
        device
    );
    IMMDeviceEnumerator_Release(enumerator);
    return status;
}

static HRESULT og_wasapi_copy_device_name(
    IMMDevice *device,
    char *output,
    size_t capacity
) {
    if (capacity == 0 || capacity > INT_MAX) return E_INVALIDARG;
    output[0] = '\0';

    IPropertyStore *properties = NULL;
    HRESULT status = IMMDevice_OpenPropertyStore(device, STGM_READ, &properties);
    if (FAILED(status)) return status;

    PROPVARIANT value;
    PropVariantInit(&value);
    status = IPropertyStore_GetValue(properties, &PKEY_Device_FriendlyName, &value);
    if (SUCCEEDED(status)) {
        if (value.vt != VT_LPWSTR || value.pwszVal == NULL) {
            status = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        } else if (WideCharToMultiByte(
            CP_UTF8,
            WC_ERR_INVALID_CHARS,
            value.pwszVal,
            -1,
            output,
            (int)capacity,
            NULL,
            NULL
        ) == 0) {
            status = HRESULT_FROM_WIN32(GetLastError());
        }
    }
    PropVariantClear(&value);
    IPropertyStore_Release(properties);
    return status;
}

static const char *og_wasapi_format_name(const WAVEFORMATEX *format) {
    WORD tag = format->wFormatTag;
    if (tag == WAVE_FORMAT_EXTENSIBLE) {
        const WAVEFORMATEXTENSIBLE *extended = (const WAVEFORMATEXTENSIBLE *)format;
        tag = (WORD)extended->SubFormat.Data1;
    }
    if (tag == WAVE_FORMAT_IEEE_FLOAT) return "F32";
    if (tag == WAVE_FORMAT_PCM && format->wBitsPerSample == 16) return "I16";
    if (tag == WAVE_FORMAT_PCM) return "PCM";
    return "unknown";
}

int og_wasapi_is_available(void) { return 1; }

int og_wasapi_probe(
    int include_format,
    char *device_name,
    size_t device_name_capacity,
    char *device_detail,
    size_t device_detail_capacity,
    int32_t *result_status
) {
    if (
        device_name == NULL || device_name_capacity == 0 || device_detail == NULL
        || device_detail_capacity == 0 || result_status == NULL
    ) {
        og_wasapi_set_error(E_INVALIDARG, "invalid microphone probe buffer");
        return -1;
    }

    *result_status = S_OK;
    device_name[0] = '\0';
    device_detail[0] = '\0';

    HRESULT apartment = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) {
        *result_status = apartment;
        og_wasapi_set_error(apartment, "could not initialize microphone COM apartment");
        return -1;
    }
    int uninitialize = SUCCEEDED(apartment);

    IMMDevice *device = NULL;
    IAudioClient *audio = NULL;
    WAVEFORMATEX *format = NULL;
    HRESULT status = og_wasapi_default_capture_device(&device);
    if (FAILED(status)) {
        og_wasapi_set_error(status, "no accessible default microphone input device");
        goto cleanup;
    }

    status = og_wasapi_copy_device_name(device, device_name, device_name_capacity);
    if (FAILED(status)) {
        og_wasapi_set_error(status, "could not inspect the default microphone device");
        goto cleanup;
    }

    if (include_format) {
        status = IMMDevice_Activate(
            device,
            &og_iaudio_client_iid,
            CLSCTX_INPROC_SERVER,
            NULL,
            (void **)&audio
        );
        if (FAILED(status)) {
            og_wasapi_set_error(status, "microphone permission denied or audio device unavailable");
            goto cleanup;
        }
        status = IAudioClient_GetMixFormat(audio, &format);
        if (FAILED(status)) {
            og_wasapi_set_error(status, "default microphone audio format is unavailable");
            goto cleanup;
        }
        snprintf(
            device_detail,
            device_detail_capacity,
            "%lu Hz, %u ch, %s",
            (unsigned long)format->nSamplesPerSec,
            (unsigned)format->nChannels,
            og_wasapi_format_name(format)
        );
    } else {
        snprintf(device_detail, device_detail_capacity, "%s", "Windows default input device");
    }

cleanup:
    if (format != NULL) CoTaskMemFree(format);
    if (audio != NULL) IAudioClient_Release(audio);
    if (device != NULL) IMMDevice_Release(device);
    if (uninitialize) CoUninitialize();
    *result_status = (int32_t)status;
    return SUCCEEDED(status) ? 0 : -1;
}

static HRESULT og_wasapi_open_audio_client(
    IMMDevice *device,
    uint32_t sample_rate,
    HANDLE ready_event,
    IAudioClient **audio_output,
    IAudioCaptureClient **capture_output
) {
    IAudioClient *audio = NULL;
    IAudioCaptureClient *capture = NULL;
    HRESULT status = IMMDevice_Activate(
        device,
        &og_iaudio_client_iid,
        CLSCTX_INPROC_SERVER,
        NULL,
        (void **)&audio
    );
    if (FAILED(status)) return status;

    WAVEFORMATEX target = {0};
    target.wFormatTag = WAVE_FORMAT_PCM;
    target.nChannels = 1;
    target.nSamplesPerSec = sample_rate;
    target.wBitsPerSample = 16;
    target.nBlockAlign = sizeof(int16_t);
    target.nAvgBytesPerSec = sample_rate * target.nBlockAlign;

    WAVEFORMATEX *closest = NULL;
    HRESULT native = IAudioClient_IsFormatSupported(
        audio,
        AUDCLNT_SHAREMODE_SHARED,
        &target,
        &closest
    );
    if (closest != NULL) CoTaskMemFree(closest);

    DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    if (native != S_OK) {
        flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
            | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    }
    const REFERENCE_TIME duration = 2 * 1000 * 1000;
    status = IAudioClient_Initialize(
        audio,
        AUDCLNT_SHAREMODE_SHARED,
        flags,
        duration,
        0,
        &target,
        NULL
    );
    if (FAILED(status)) goto cleanup;

    status = IAudioClient_SetEventHandle(audio, ready_event);
    if (FAILED(status)) goto cleanup;

    status = IAudioClient_GetService(
        audio,
        &og_iaudio_capture_client_iid,
        (void **)&capture
    );
    if (FAILED(status)) goto cleanup;

    status = IAudioClient_Start(audio);
    if (FAILED(status)) goto cleanup;

    *audio_output = audio;
    *capture_output = capture;
    return S_OK;

cleanup:
    if (capture != NULL) IAudioCaptureClient_Release(capture);
    if (audio != NULL) IAudioClient_Release(audio);
    return status;
}

static HRESULT og_wasapi_drain_packets(
    OGWASAPISession *session,
    IAudioCaptureClient *capture
) {
    for (;;) {
        UINT32 available = 0;
        HRESULT status = IAudioCaptureClient_GetNextPacketSize(capture, &available);
        if (FAILED(status) || available == 0) return status;

        BYTE *bytes = NULL;
        UINT32 frames = 0;
        DWORD flags = 0;
        status = IAudioCaptureClient_GetBuffer(capture, &bytes, &frames, &flags, NULL, NULL);
        if (status == AUDCLNT_S_BUFFER_EMPTY) return S_OK;
        if (FAILED(status)) return status;

        uint64_t length = (uint64_t)frames * sizeof(int16_t);
        if (
            length > OG_WASAPI_MAX_PACKET_BYTES
            || (bytes == NULL && !(flags & AUDCLNT_BUFFERFLAGS_SILENT))
        ) {
            IAudioCaptureClient_ReleaseBuffer(capture, frames);
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        }
        if (length != 0 && WaitForSingleObject(session->stop, 0) != WAIT_OBJECT_0) {
            session->audio_callback(
                (flags & AUDCLNT_BUFFERFLAGS_SILENT) ? NULL : bytes,
                (size_t)length,
                (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0,
                session->context
            );
        }
        status = IAudioCaptureClient_ReleaseBuffer(capture, frames);
        if (FAILED(status)) return status;
    }
}

static DWORD WINAPI og_wasapi_capture_worker(void *opaque_session) {
    OGWASAPISession *session = opaque_session;
    IMMDevice *device = NULL;
    IAudioClient *audio = NULL;
    IAudioCaptureClient *capture = NULL;
    int started = 0;

    HRESULT apartment = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(apartment)) {
        og_wasapi_publish_startup(session, apartment, "could not initialize microphone COM apartment");
        goto finish_without_apartment;
    }

    HRESULT status = og_wasapi_default_capture_device(&device);
    if (FAILED(status)) {
        og_wasapi_publish_startup(session, status, "no accessible default microphone input device");
        goto finish;
    }
    if (WaitForSingleObject(session->stop, 0) == WAIT_OBJECT_0) {
        og_wasapi_publish_startup(session, HRESULT_FROM_WIN32(ERROR_CANCELLED), "microphone startup was cancelled");
        goto finish;
    }

    status = og_wasapi_open_audio_client(
        device,
        session->sample_rate,
        session->audio_ready,
        &audio,
        &capture
    );
    if (FAILED(status)) {
        og_wasapi_publish_startup(session, status, "microphone permission, device format, or audio service rejected capture");
        goto finish;
    }
    started = 1;
    og_wasapi_publish_startup(session, S_OK, "");

    HANDLE events[] = {session->stop, session->audio_ready};
    for (;;) {
        DWORD signaled = WaitForMultipleObjects(2, events, FALSE, 1000);
        if (signaled == WAIT_OBJECT_0) break;
        if (signaled == WAIT_TIMEOUT) continue;
        if (signaled != WAIT_OBJECT_0 + 1) {
            status = HRESULT_FROM_WIN32(GetLastError());
            break;
        }
        status = og_wasapi_drain_packets(session, capture);
        if (FAILED(status)) break;
    }

    if (FAILED(status) && WaitForSingleObject(session->stop, 0) != WAIT_OBJECT_0) {
        session->error_callback(status, "microphone capture device failed", session->context);
    }

finish:
    if (started) IAudioClient_Stop(audio);
    if (capture != NULL) IAudioCaptureClient_Release(capture);
    if (audio != NULL) IAudioClient_Release(audio);
    if (device != NULL) IMMDevice_Release(device);
    CoUninitialize();

finish_without_apartment:
    if (session->release_context != NULL) session->release_context(session->context);
    og_wasapi_release_session(session);
    return 0;
}

int og_wasapi_start(
    uint32_t sample_rate,
    OGWASAPIAudioCallback audio_callback,
    OGWASAPIErrorCallback error_callback,
    OGWASAPIContextRelease release_context,
    void *context,
    int64_t *output_session,
    int32_t *result_status
) {
    if (
        sample_rate < 8000 || sample_rate > 384000 || audio_callback == NULL
        || error_callback == NULL || release_context == NULL || context == NULL
        || output_session == NULL || result_status == NULL
    ) {
        if (release_context != NULL && context != NULL) release_context(context);
        if (result_status != NULL) *result_status = (int32_t)E_INVALIDARG;
        og_wasapi_set_error(E_INVALIDARG, "invalid microphone capture configuration");
        return -1;
    }

    *output_session = -1;
    *result_status = S_OK;
    OGWASAPISession *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        release_context(context);
        *result_status = (int32_t)E_OUTOFMEMORY;
        og_wasapi_set_error(E_OUTOFMEMORY, "could not allocate microphone capture session");
        return -1;
    }

    session->references = 1;
    session->sample_rate = sample_rate;
    session->audio_callback = audio_callback;
    session->error_callback = error_callback;
    session->release_context = release_context;
    session->context = context;
    session->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    session->stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    session->audio_ready = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (session->ready == NULL || session->stop == NULL || session->audio_ready == NULL) {
        HRESULT status = HRESULT_FROM_WIN32(GetLastError());
        release_context(context);
        *result_status = (int32_t)status;
        og_wasapi_set_error(status, "could not create microphone capture events");
        og_wasapi_release_session(session);
        return -1;
    }

    session->thread = CreateThread(
        NULL,
        0,
        og_wasapi_capture_worker,
        session,
        CREATE_SUSPENDED,
        NULL
    );
    if (session->thread == NULL) {
        HRESULT status = HRESULT_FROM_WIN32(GetLastError());
        release_context(context);
        *result_status = (int32_t)status;
        og_wasapi_set_error(status, "could not create microphone capture worker");
        og_wasapi_release_session(session);
        return -1;
    }

    InterlockedIncrement(&session->references);
    if (ResumeThread(session->thread) == (DWORD)-1) {
        HRESULT status = HRESULT_FROM_WIN32(GetLastError());
        SetEvent(session->stop);
        /* A suspended thread cannot observe stop or release its worker share. */
        TerminateThread(session->thread, 1);
        release_context(context);
        og_wasapi_release_session(session);
        *result_status = (int32_t)status;
        og_wasapi_set_error(status, "could not start microphone capture worker");
        og_wasapi_release_session(session);
        return -1;
    }

    DWORD ready = WaitForSingleObject(session->ready, OG_WASAPI_START_TIMEOUT_MS);
    if (ready != WAIT_OBJECT_0 || FAILED(session->startup_status)) {
        HRESULT status = ready == WAIT_TIMEOUT
            ? HRESULT_FROM_WIN32(WAIT_TIMEOUT)
            : ready == WAIT_OBJECT_0
                ? session->startup_status
                : HRESULT_FROM_WIN32(GetLastError());
        const char *detail = ready == WAIT_OBJECT_0
            ? session->startup_detail
            : "microphone capture did not start within 5s";
        *result_status = (int32_t)status;
        og_wasapi_set_error(status, detail);
        SetEvent(session->stop);
        WaitForSingleObject(session->thread, OG_WASAPI_START_FAILURE_STOP_TIMEOUT_MS);
        og_wasapi_release_session(session);
        return -1;
    }

    *output_session = (int64_t)(intptr_t)session;
    return 0;
}

static OGWASAPISession *og_wasapi_session(int64_t value) {
    if (value == 0 || value == -1) return NULL;
    return (OGWASAPISession *)(intptr_t)value;
}

int og_wasapi_stop(int64_t value, uint32_t timeout_milliseconds, int32_t *result_status) {
    OGWASAPISession *session = og_wasapi_session(value);
    if (session == NULL || result_status == NULL || timeout_milliseconds == 0) {
        if (result_status != NULL) *result_status = (int32_t)E_INVALIDARG;
        og_wasapi_set_error(E_INVALIDARG, "invalid microphone capture stop request");
        return -1;
    }

    SetEvent(session->stop);
    DWORD stopped = WaitForSingleObject(session->thread, timeout_milliseconds);
    if (stopped != WAIT_OBJECT_0) {
        HRESULT status = stopped == WAIT_TIMEOUT
            ? HRESULT_FROM_WIN32(WAIT_TIMEOUT)
            : HRESULT_FROM_WIN32(GetLastError());
        *result_status = (int32_t)status;
        og_wasapi_set_error(status, "microphone capture did not stop before its deadline");
        return -1;
    }
    *result_status = S_OK;
    return 0;
}

void og_wasapi_destroy(int64_t value) {
    OGWASAPISession *session = og_wasapi_session(value);
    if (session == NULL) return;
    SetEvent(session->stop);
    og_wasapi_release_session(session);
}

int32_t og_wasapi_last_error_code(void) { return (int32_t)og_wasapi_error_code; }
const char *og_wasapi_last_error_message(void) { return og_wasapi_error_detail; }

#else

int og_wasapi_is_available(void) { return 0; }

#endif
