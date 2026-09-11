#pragma once

// Stable, C-callable boundary for in-process audio consumers.  The provider
// owns every native object; consumers copy the metadata supplied during a
// callback and never retain the pointers after it returns.
// Calls run synchronously on the host Qt control thread, never a real-time
// audio thread. Callbacks must not edit the host, process Qt events, re-enter
// the Provider or throw exceptions. Resolve exports again after DLL reload;
// never call an address belonging to an unloaded Provider.
#include <stdint.h>

#if defined(_WIN32)
#  define GPMCP_AUDIO_CALL __cdecl
#  define GPMCP_AUDIO_EXPORT __declspec(dllexport)
#else
#  define GPMCP_AUDIO_CALL
#  define GPMCP_AUDIO_EXPORT
#endif

#define GPMCP_AUDIO_BRIDGE_ABI_VERSION 1u

typedef enum gpmcp_audio_status {
    GPMCP_AUDIO_OK = 0,
    GPMCP_AUDIO_NOT_READY = 1,
    GPMCP_AUDIO_HOST_LIMITED = 2,
    GPMCP_AUDIO_ABI_MISMATCH = 3,
    GPMCP_AUDIO_WRONG_THREAD = 4,
    GPMCP_AUDIO_INVALID_ARGUMENT = 5,
    GPMCP_AUDIO_INTERNAL_ERROR = 6
} gpmcp_audio_status;

enum {
    GPMCP_AUDIO_CAP_BINDINGS = 1ull << 0,
    GPMCP_AUDIO_CAP_CONTEXTS = 1ull << 1,
    GPMCP_AUDIO_CAP_BUFFER_PROBE = 1ull << 2
};

typedef struct gpmcp_audio_bridge_info {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t status;
    uint32_t reserved;
    uint64_t generation;
    uint64_t capabilities;
    // Lower-case SHA-256 of the verified GuitarPro.exe, or an empty string.
    char host_build_sha256[65];
} gpmcp_audio_bridge_info;

typedef struct gpmcp_audio_binding {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t status;
    uint32_t controller_index;
    uint64_t generation;
    void *chain;
    int32_t track_index;
    int32_t sound_index;
    // 0 = false, 1 = true, 2 = unknown (no authoritative active document).
    uint8_t active_document;
    uint8_t selected_track;
    uint16_t reserved;
    // These pointers are valid only for the callback invocation.
    const char *document_id;
    const char *track_id;
    const char *score_key;
} gpmcp_audio_binding;

typedef void (GPMCP_AUDIO_CALL *gpmcp_audio_binding_visitor)(
    void *user, const gpmcp_audio_binding *binding);

typedef struct gpmcp_audio_enumerate_result {
    uint32_t struct_size;
    uint32_t status;
    uint64_t generation;
    uint64_t count;
} gpmcp_audio_enumerate_result;

// HOST_LIMITED may still deliver verified track contexts: chain = NULL,
// sound_index = -1 and binding.status = HOST_LIMITED. No PCM is provided.
// generation is an observed topology revision, not a native pointer lease.
// A document ID plus its binding generation identifies one document revision;
// result.generation is the Provider revision across all observed documents.

typedef uint32_t (GPMCP_AUDIO_CALL *gpmcp_audio_get_info_fn)(
    gpmcp_audio_bridge_info *info);
typedef uint32_t (GPMCP_AUDIO_CALL *gpmcp_audio_enumerate_v1_fn)(
    uint32_t requested_abi, gpmcp_audio_binding_visitor visitor, void *user,
    gpmcp_audio_enumerate_result *result);

#ifdef __cplusplus
static_assert(sizeof(gpmcp_audio_bridge_info) == 104, "audio bridge info ABI changed");
static_assert(sizeof(gpmcp_audio_binding) == 72, "audio binding ABI changed");
static_assert(sizeof(gpmcp_audio_enumerate_result) == 24, "audio enumerate result ABI changed");
#endif
