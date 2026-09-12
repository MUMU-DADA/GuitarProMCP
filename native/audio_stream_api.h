#pragma once

// P14 realtime stream ABI.  This is deliberately separate from the P13
// binding ABI: stream state and PCM metadata may evolve without changing the
// existing audio_bridge_api.h structures.
#include <stdint.h>

#if defined(_WIN32)
#  define GPMCP_AUDIO_STREAM_EXPORT __declspec(dllexport)
#  define GPMCP_AUDIO_STREAM_CALL __cdecl
#else
#  define GPMCP_AUDIO_STREAM_EXPORT
#  define GPMCP_AUDIO_STREAM_CALL
#endif

#define GPMCP_AUDIO_STREAM_ABI_VERSION 1u
#define GPMCP_AUDIO_STREAM_ID_BYTES 40u
#define GPMCP_AUDIO_STREAM_DOCUMENT_BYTES 80u
#define GPMCP_AUDIO_STREAM_REASON_BYTES 160u
#define GPMCP_AUDIO_STREAM_FORMAT_BYTES 16u

enum gpmcp_audio_stream_status : uint32_t {
    GPMCP_AUDIO_STREAM_OK = 0,
    GPMCP_AUDIO_STREAM_NOT_READY = 1,
    GPMCP_AUDIO_STREAM_HOST_LIMITED = 2,
    GPMCP_AUDIO_STREAM_ABI_MISMATCH = 3,
    GPMCP_AUDIO_STREAM_WRONG_THREAD = 4,
    GPMCP_AUDIO_STREAM_INVALID_ARGUMENT = 5,
    GPMCP_AUDIO_STREAM_STALE = 6,
    GPMCP_AUDIO_STREAM_OVERFLOW = 7,
    GPMCP_AUDIO_STREAM_INTERNAL_ERROR = 8,
};

enum gpmcp_audio_stream_capability : uint64_t {
    GPMCP_AUDIO_STREAM_CAP_SESSION = 1ull << 0,
    GPMCP_AUDIO_STREAM_CAP_PCM = 1ull << 1,
    GPMCP_AUDIO_STREAM_CAP_METRICS = 1ull << 2,
    GPMCP_AUDIO_STREAM_CAP_DIAGNOSTICS = 1ull << 3,
    GPMCP_AUDIO_STREAM_CAP_RECOVERY = 1ull << 4,
};

typedef struct gpmcp_audio_stream_info {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t status;
    uint32_t reserved;
    uint64_t generation;
    uint64_t capabilities;
    uint32_t stream_count;
    uint32_t reserved2;
    char host_build_sha256[65];
} gpmcp_audio_stream_info;

typedef struct gpmcp_audio_stream_state {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t status;
    uint32_t state;
    uint64_t generation;
    uint64_t frame_count;
    uint64_t host_dropped_frames;
    uint64_t monitor_dropped_frames;
    char stream_id[GPMCP_AUDIO_STREAM_ID_BYTES];
    char document_id[GPMCP_AUDIO_STREAM_DOCUMENT_BYTES];
    char reason[GPMCP_AUDIO_STREAM_REASON_BYTES];
    uint32_t sample_rate;
    uint16_t channels;
    uint16_t reserved;
    uint32_t frames_per_block;
    char sample_format[GPMCP_AUDIO_STREAM_FORMAT_BYTES];
} gpmcp_audio_stream_state;

typedef struct gpmcp_audio_stream_enumerate_result {
    uint32_t struct_size;
    uint32_t status;
    uint64_t generation;
    uint32_t count;
    uint32_t reserved;
} gpmcp_audio_stream_enumerate_result;

typedef void (GPMCP_AUDIO_STREAM_CALL *gpmcp_audio_stream_state_visitor)(
    void *user, const gpmcp_audio_stream_state *state);

typedef unsigned (GPMCP_AUDIO_STREAM_CALL *gpmcp_audio_stream_version_fn)();
typedef uint32_t (GPMCP_AUDIO_STREAM_CALL *gpmcp_audio_stream_get_info_fn)(
    gpmcp_audio_stream_info *info);
typedef uint32_t (GPMCP_AUDIO_STREAM_CALL *gpmcp_audio_stream_enumerate_v1_fn)(
    uint32_t requestedAbi, gpmcp_audio_stream_state_visitor visitor, void *user,
    gpmcp_audio_stream_enumerate_result *result);
