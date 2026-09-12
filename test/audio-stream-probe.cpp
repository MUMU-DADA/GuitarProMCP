#include "../native/guitarpro_audio_stream.h"
#include <windows.h>
#include <cmath>
#include <iostream>
#include <thread>

namespace {
using VersionFn = unsigned (GPMCP_AUDIO_STREAM_CALL *)();
void visit(void *, const gpmcp_audio_stream_state *) {}
}

int main(int argc, char **argv) {
    using namespace guitarpro;
    static_assert(GPMCP_AUDIO_STREAM_ABI_VERSION == 1u, "P14 ABI version changed");
    static_assert(sizeof(gpmcp_audio_stream_info) >= 96, "stream info must remain explicit and bounded");

    AudioStreamRing ring;
    AudioStreamPcmBlock block;
    block.frames = 4;
    block.channels = 2;
    block.sample_rate = 48000;
    block.samples[0] = 1.0f;
    block.samples[1] = -1.0f;
    block.samples[2] = 0.25f;
    block.samples[3] = std::nanf("");
    const auto metrics = summarizeAudioBlock(block);
    if (metrics.frames != 4 || metrics.nonFinite != 1 || metrics.clipped != 2 ||
        std::abs(metrics.peak - 1.0) > 1e-9 || metrics.rms <= 0.0) {
        std::cerr << "FAIL: finite-value and signal metrics\n";
        return 1;
    }

    for (uint32_t i = 0; i < AudioStreamRing::Capacity; ++i) {
        block.frame_start = i * block.frames;
        if (!ring.push(block)) { std::cerr << "FAIL: ring rejected capacity block\n"; return 1; }
    }
    if (ring.push(block) || ring.monitorDroppedFrames() != block.frames) {
        std::cerr << "FAIL: ring capacity or drop counter\n";
        return 1;
    }
    AudioStreamPcmBlock read;
    for (uint32_t i = 0; i < AudioStreamRing::Capacity; ++i) {
        if (!ring.pop(&read) || read.frame_start != i * block.frames) {
            std::cerr << "FAIL: ring FIFO order\n";
            return 1;
        }
    }
    if (ring.pop(&read)) { std::cerr << "FAIL: empty ring pop\n"; return 1; }
    AudioStreamRegistry registry;
    const QJsonObject provider{{"abi_version", 1}, {"status", "host_limited"}};
    const QJsonObject startedArgs{{"operation", "start"}, {"layers", QJsonArray{"track", "endpoint"}}};
    const QJsonObject started = registry.handle(startedArgs, QStringLiteral("fixture"), 7, provider);
    const QString streamId = started.value("stream_id").toString();
    if (started.value("status") != "host_limited" || streamId.isEmpty() || started.value("pcm_available").toBool()) {
        std::cerr << "FAIL: host-limited stream start\n"; return 1;
    }
    const QJsonObject streamArgs{{"stream_id", streamId}};
    QJsonObject snapArgs = streamArgs; snapArgs["operation"] = "snapshot";
    const QJsonObject snap = registry.handle(snapArgs, {}, 7, provider);
    if (snap.value("status") != "host_limited" || !snap.contains("continuity") || snap.value("window").toObject().value("non_finite") != 0) {
        std::cerr << "FAIL: stream snapshot contract\n"; return 1;
    }
    QJsonObject readArgs = streamArgs; readArgs["operation"] = "read";
    const QJsonObject readResult = registry.handle(readArgs, {}, 7, provider);
    if (readResult.value("frames") != 0 || readResult.value("pcm_available").toBool() || !readResult.value("chunks").toArray().isEmpty()) {
        std::cerr << "FAIL: stream read bound\n"; return 1;
    }
    QJsonObject diagnoseArgs = streamArgs; diagnoseArgs["operation"] = "diagnose";
    const QJsonObject diagnosis = registry.handle(diagnoseArgs, {}, 7, provider);
    if (diagnosis.value("diagnostic_status") != "host_limited" || diagnosis.value("checks").toArray().size() != 5) {
        std::cerr << "FAIL: stream diagnostic contract\n"; return 1;
    }
    QJsonObject staleArgs = streamArgs; staleArgs["operation"] = "state";
    const QJsonObject stale = registry.handle(staleArgs, {}, 8, provider);
    if (stale.value("status") != "stale" || stale.value("reason") != "document_or_host_generation_changed") {
        std::cerr << "FAIL: stream generation invalidation\n"; return 1;
    }
    QJsonObject stopArgs = streamArgs; stopArgs["operation"] = "stop";
    const QJsonObject stopped = registry.handle(stopArgs, {}, 8, provider);
    if (stopped.value("status") != "stopped" || stopped.value("state") != "stopped") {
        std::cerr << "FAIL: stream stop transition\n"; return 1;
    }
    if (argc > 1) {
        HMODULE provider = LoadLibraryA(argv[1]);
        if (!provider) { std::cerr << "FAIL: stream provider fixture did not load\n"; return 1; }
        auto version = reinterpret_cast<VersionFn>(GetProcAddress(provider, "gpmcp_audio_stream_version"));
        auto getInfo = reinterpret_cast<gpmcp_audio_stream_get_info_fn>(GetProcAddress(provider, "gpmcp_audio_stream_get_info"));
        auto enumerate = reinterpret_cast<gpmcp_audio_stream_enumerate_v1_fn>(GetProcAddress(provider, "gpmcp_audio_stream_enumerate_v1"));
        if (!version || !getInfo || !enumerate || version() != GPMCP_AUDIO_STREAM_ABI_VERSION) {
            std::cerr << "FAIL: stream provider ABI exports\n"; return 1;
        }
        gpmcp_audio_stream_info info{}; info.struct_size = sizeof(info);
        if (getInfo(&info) != GPMCP_AUDIO_STREAM_HOST_LIMITED || info.abi_version != GPMCP_AUDIO_STREAM_ABI_VERSION) {
            std::cerr << "FAIL: stream provider host-limited info\n"; return 1;
        }
        gpmcp_audio_stream_enumerate_result result{}; result.struct_size = sizeof(result);
        if (enumerate(GPMCP_AUDIO_STREAM_ABI_VERSION + 1, visit, nullptr, &result) != GPMCP_AUDIO_STREAM_ABI_MISMATCH) {
            std::cerr << "FAIL: stream ABI mismatch\n"; return 1;
        }
        std::atomic<uint32_t> workerStatus{GPMCP_AUDIO_STREAM_INTERNAL_ERROR};
        std::thread worker([&] {
            gpmcp_audio_stream_enumerate_result workerResult{}; workerResult.struct_size = sizeof(workerResult);
            workerStatus.store(enumerate(GPMCP_AUDIO_STREAM_ABI_VERSION, visit, nullptr, &workerResult));
        });
        worker.join();
        if (workerStatus.load() != GPMCP_AUDIO_STREAM_WRONG_THREAD) {
            std::cerr << "FAIL: stream worker-thread rejection\n"; return 1;
        }
        FreeLibrary(provider);
    }
    std::cout << "PASS: P14 ABI v" << GPMCP_AUDIO_STREAM_ABI_VERSION
              << ", fixed ring capacity " << AudioStreamRing::Capacity
              << ", metrics, overflow counters and provider exports\n";
    return 0;
}
