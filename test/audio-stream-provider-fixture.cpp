#include "../native/audio_stream_api.h"
#include <windows.h>
#include <cstring>

namespace { DWORD ownerThread = 0; }

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) ownerThread = GetCurrentThreadId();
    return TRUE;
}

extern "C" GPMCP_AUDIO_STREAM_EXPORT unsigned GPMCP_AUDIO_STREAM_CALL gpmcp_audio_stream_version() {
    return GPMCP_AUDIO_STREAM_ABI_VERSION;
}

extern "C" GPMCP_AUDIO_STREAM_EXPORT uint32_t GPMCP_AUDIO_STREAM_CALL gpmcp_audio_stream_get_info(
    gpmcp_audio_stream_info *info) {
    if (!info || info->struct_size < sizeof(*info)) return GPMCP_AUDIO_STREAM_ABI_MISMATCH;
    std::memset(info, 0, sizeof(*info));
    info->struct_size = sizeof(*info);
    info->abi_version = GPMCP_AUDIO_STREAM_ABI_VERSION;
    info->status = GPMCP_AUDIO_STREAM_HOST_LIMITED;
    info->capabilities = GPMCP_AUDIO_STREAM_CAP_SESSION | GPMCP_AUDIO_STREAM_CAP_METRICS |
        GPMCP_AUDIO_STREAM_CAP_DIAGNOSTICS | GPMCP_AUDIO_STREAM_CAP_RECOVERY;
    return info->status;
}

extern "C" GPMCP_AUDIO_STREAM_EXPORT uint32_t GPMCP_AUDIO_STREAM_CALL gpmcp_audio_stream_enumerate_v1(
    uint32_t requestedAbi, gpmcp_audio_stream_state_visitor visitor, void *user,
    gpmcp_audio_stream_enumerate_result *result) {
    if (!result || result->struct_size < sizeof(*result)) return GPMCP_AUDIO_STREAM_ABI_MISMATCH;
    result->status = GPMCP_AUDIO_STREAM_NOT_READY; result->generation = 1; result->count = 0;
    if (requestedAbi != GPMCP_AUDIO_STREAM_ABI_VERSION) return result->status = GPMCP_AUDIO_STREAM_ABI_MISMATCH;
    if (!visitor || user != nullptr) return result->status = GPMCP_AUDIO_STREAM_INVALID_ARGUMENT;
    if (GetCurrentThreadId() != ownerThread) return result->status = GPMCP_AUDIO_STREAM_WRONG_THREAD;
    return result->status = GPMCP_AUDIO_STREAM_HOST_LIMITED;
}
