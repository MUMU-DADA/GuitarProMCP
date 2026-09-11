#include "../native/audio_bridge_api.h"
#include <windows.h>
#include <cstring>

namespace {
DWORD ownerThread = 0;
const char documentId[] = "fixture-document";
const char trackId[] = "fixture-track";
const char scoreKey[] = "fixture-score";
}

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) ownerThread = GetCurrentThreadId();
    return TRUE;
}

extern "C" GPMCP_AUDIO_EXPORT unsigned GPMCP_AUDIO_CALL gpmcp_audio_bridge_version() { return GPMCP_AUDIO_BRIDGE_ABI_VERSION; }

extern "C" GPMCP_AUDIO_EXPORT uint32_t GPMCP_AUDIO_CALL gpmcp_audio_bridge_get_info(gpmcp_audio_bridge_info *info) {
    if (!info || info->struct_size < sizeof(*info)) return GPMCP_AUDIO_ABI_MISMATCH;
    std::memset(info, 0, sizeof(*info));
    info->struct_size = sizeof(*info);
    info->abi_version = GPMCP_AUDIO_BRIDGE_ABI_VERSION;
    info->status = GPMCP_AUDIO_OK;
    info->generation = 1;
    info->capabilities = GPMCP_AUDIO_CAP_BINDINGS | GPMCP_AUDIO_CAP_CONTEXTS;
    std::memcpy(info->host_build_sha256, "fixture", 7);
    return info->status;
}

extern "C" GPMCP_AUDIO_EXPORT uint32_t GPMCP_AUDIO_CALL gpmcp_audio_enumerate_v1(
    uint32_t requestedAbi, gpmcp_audio_binding_visitor visitor, void *user,
    gpmcp_audio_enumerate_result *result) {
    if (!result || result->struct_size < sizeof(*result)) return GPMCP_AUDIO_ABI_MISMATCH;
    if (requestedAbi != GPMCP_AUDIO_BRIDGE_ABI_VERSION) {
        result->status = GPMCP_AUDIO_ABI_MISMATCH;
        return result->status;
    }
    result->status = GPMCP_AUDIO_INTERNAL_ERROR; result->generation = 1; result->count = 0;
    if (GetCurrentThreadId() != ownerThread) { result->status = GPMCP_AUDIO_WRONG_THREAD; return result->status; }
    if (!visitor) { result->status = GPMCP_AUDIO_INVALID_ARGUMENT; return result->status; }
    gpmcp_audio_binding binding{};
    binding.struct_size = sizeof(binding); binding.abi_version = GPMCP_AUDIO_BRIDGE_ABI_VERSION;
    binding.status = GPMCP_AUDIO_OK; binding.generation = 1; binding.chain = &binding;
    binding.track_index = 0; binding.sound_index = 0; binding.active_document = 1; binding.selected_track = 1;
    binding.document_id = documentId; binding.track_id = trackId; binding.score_key = scoreKey;
    visitor(user, &binding);
    result->status = GPMCP_AUDIO_OK; result->count = 1;
    return result->status;
}
