#pragma once

#include "audio_stream_api.h"
#include "guitarpro_audio.h"
#include <QtCore/QDateTime>
#include <QtCore/QHash>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonObject>
#include <QtCore/QPointer>
#include <QtCore/QSharedPointer>
#include <QtCore/QStringList>
#include <QtCore/QUuid>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace guitarpro {

// The callback-facing block has a fixed size.  A future verified host tap can
// write one of these blocks without allocating, calling Qt, or retaining a
// host pointer.  The current 8.1.1.17 host exposes no verified tap, so the
// registry below never claims that this ring contains live host PCM.
struct AudioStreamPcmBlock {
    static constexpr uint32_t MaxFrames = 256;
    static constexpr uint16_t MaxChannels = 8;
    uint64_t frame_start = 0;
    uint64_t timestamp_ns = 0;
    uint64_t generation = 0;
    uint32_t frames = 0;
    uint32_t sample_rate = 0;
    uint16_t channels = 0;
    uint16_t reserved = 0;
    float samples[MaxFrames * MaxChannels] = {};
};

class AudioStreamRing final {
public:
    static constexpr uint32_t Capacity = 32;

    bool push(const AudioStreamPcmBlock &block) noexcept {
        const uint64_t write = write_.load(std::memory_order_relaxed);
        const uint64_t read = read_.load(std::memory_order_acquire);
        if (write - read >= Capacity) {
            monitorDroppedFrames_.fetch_add(block.frames, std::memory_order_relaxed);
            return false;
        }
        blocks_[write % Capacity] = block;
        write_.store(write + 1, std::memory_order_release);
        return true;
    }

    bool pop(AudioStreamPcmBlock *block) noexcept {
        if (!block) return false;
        const uint64_t read = read_.load(std::memory_order_relaxed);
        if (read == write_.load(std::memory_order_acquire)) return false;
        *block = blocks_[read % Capacity];
        read_.store(read + 1, std::memory_order_release);
        return true;
    }

    uint64_t monitorDroppedFrames() const noexcept {
        return monitorDroppedFrames_.load(std::memory_order_relaxed);
    }

    void clear() noexcept {
        const uint64_t write = write_.load(std::memory_order_acquire);
        read_.store(write, std::memory_order_release);
        monitorDroppedFrames_.store(0, std::memory_order_release);
    }

private:
    std::array<AudioStreamPcmBlock, Capacity> blocks_{};
    std::atomic<uint64_t> write_{0};
    std::atomic<uint64_t> read_{0};
    std::atomic<uint64_t> monitorDroppedFrames_{0};
};

struct AudioStreamWindowMetrics {
    uint64_t frames = 0;
    uint64_t firstTimestampNs = 0;
    uint64_t lastTimestampNs = 0;
    double rms = 0.0;
    double peak = 0.0;
    double dc = 0.0;
    uint64_t clipped = 0;
    uint64_t nonFinite = 0;
};

inline AudioStreamWindowMetrics summarizeAudioBlock(const AudioStreamPcmBlock &block) noexcept {
    AudioStreamWindowMetrics result;
    result.frames = block.frames;
    result.firstTimestampNs = block.timestamp_ns;
    result.lastTimestampNs = block.timestamp_ns;
    const uint32_t frames = (std::min)(block.frames, AudioStreamPcmBlock::MaxFrames);
    const uint16_t channels = (std::min<uint16_t>)(block.channels, AudioStreamPcmBlock::MaxChannels);
    const uint64_t samples = uint64_t(frames) * channels;
    if (!samples) return result;
    double sum = 0.0, square = 0.0;
    for (uint64_t i = 0; i < samples; ++i) {
        const double sample = block.samples[i];
        if (!std::isfinite(sample)) {
            ++result.nonFinite;
            continue;
        }
        sum += sample;
        square += sample * sample;
        result.peak = (std::max)(result.peak, std::abs(sample));
        if (std::abs(sample) >= 1.0) ++result.clipped;
    }
    const uint64_t finite = samples - result.nonFinite;
    if (finite) {
        result.dc = sum / double(finite);
        result.rms = std::sqrt(square / double(finite));
    }
    return result;
}

class AudioStreamRegistry final {
public:
    static constexpr int MaxReadFrames = 4096;
    static constexpr int MaxReadBytes = 1024 * 1024;

    QJsonObject handle(const QJsonObject &args, const QString &document,
                       quint64 generation, const QJsonObject &provider) {
        const QString operation = args.value("operation").toString("state");
        if (operation == "start") return start(args, document, generation, provider);
        if (operation == "stop") return stop(args, generation);
        if (operation == "snapshot") return snapshot(args, generation);
        if (operation == "read") return read(args, generation);
        if (operation == "diagnose") return diagnose(args, generation);
        if (operation == "recover") return recover(args, generation);
        if (operation == "state") return state(args, generation, provider);
        return error("operation must be state, start, stop, snapshot, read, diagnose or recover");
    }

    QJsonObject info(quint64 generation, const QByteArray &hostHash) const {
        QJsonObject result{{"abi_version", int(GPMCP_AUDIO_STREAM_ABI_VERSION)},
            {"status", "host_limited"}, {"generation", qint64(generation)},
            {"capabilities", QJsonArray{"session", "metrics", "diagnostics", "recovery"}},
            {"stream_count", sessions_.size()},
            {"reason", "no_verified_realtime_tap"},
            {"host_build_sha256", QString::fromLatin1(hostHash)}};
        return result;
    }

    void clear() { sessions_.clear(); }

private:
    struct Session {
        QString id;
        QString document;
        QStringList layers;
        QString state = QStringLiteral("host_limited");
        QString reason = QStringLiteral("no_verified_realtime_tap");
        quint64 generation = 0;
        qint64 createdAt = 0;
        int maxFrames = 1024;
        int maxBytes = 256 * 1024;
        quint64 frameCount = 0;
        quint64 hostDroppedFrames = 0;
        QSharedPointer<AudioStreamRing> ring;
    };

    QHash<QString, Session> sessions_;

    static QJsonObject error(const QString &message) { return {{"status", "error"}, {"error", message}}; }

    static QStringList requestedLayers(const QJsonValue &value) {
        if (!value.isArray()) return {"input", "track", "effects", "mix", "endpoint"};
        QStringList result;
        static const QStringList allowed{"input", "source", "track", "effects", "mix", "audiolayer", "endpoint"};
        for (const auto &item : value.toArray()) if (item.isString() && allowed.contains(item.toString()) && !result.contains(item.toString())) result.append(item.toString());
        return result;
    }

    static QJsonObject common(const Session &session, const QString &statusOverride = {}) {
        const QString status = statusOverride.isEmpty() ? session.state : statusOverride;
        return {{"status", status}, {"state", session.state}, {"stream_id", session.id},
            {"document", session.document}, {"generation", qint64(session.generation)},
            {"reason", session.reason}, {"created_at_ms", session.createdAt},
            {"layers", QJsonArray::fromStringList(session.layers)},
            {"sample_rate", 0}, {"channels", 0}, {"sample_format", "unknown"},
            {"frames_per_block", 0}, {"frame_count", qint64(session.frameCount)},
            {"host_dropped_frames", qint64(session.hostDroppedFrames)},
            {"monitor_dropped_frames", session.ring ? qint64(session.ring->monitorDroppedFrames()) : 0},
            {"pcm_available", false}};
    }

    Session *find(const QJsonObject &args, quint64 generation, QJsonObject *failure) {
        const QString id = args.value("stream_id").toString();
        if (id.isEmpty()) { if (failure) *failure = error("stream_id is required"); return nullptr; }
        auto it = sessions_.find(id);
        if (it == sessions_.end()) { if (failure) *failure = {{"status", "stale"}, {"error", "Unknown or expired stream_id"}, {"reason", "stream_not_found"}}; return nullptr; }
        if (it->generation != generation && it->state != "stopped") {
            it->state = "stale";
            it->reason = "document_or_host_generation_changed";
        }
        return &it.value();
    }

    QJsonObject start(const QJsonObject &args, const QString &document, quint64 generation, const QJsonObject &) {
        if (document.isEmpty()) return error("Choose a verified document before starting an audio stream");
        const int maxFrames = args.value("max_frames").toInt(1024);
        const int maxBytes = args.value("max_bytes").toInt(256 * 1024);
        if (maxFrames < 1 || maxFrames > MaxReadFrames || maxBytes < 4096 || maxBytes > MaxReadBytes)
            return error("max_frames must be 1..4096 and max_bytes must be 4096..1048576");
        Session session;
        session.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        session.document = document;
        session.layers = requestedLayers(args.value("layers"));
        session.generation = generation;
        session.createdAt = QDateTime::currentMSecsSinceEpoch();
        session.maxFrames = maxFrames;
        session.maxBytes = maxBytes;
        session.ring.reset(new AudioStreamRing);
        sessions_.insert(session.id, session);
        QJsonObject result = common(sessions_.value(session.id), "host_limited");
        result["status"] = "host_limited";
        result["state"] = "host_limited";
        result["suggested_action"] = "Use a Guitar Pro build with a verified realtime audio tap; no PCM was captured";
        return result;
    }

    QJsonObject stop(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        session->state = "stopped";
        session->reason = "stopped_by_client";
        if (session->ring) session->ring->clear();
        return common(*session, "stopped");
    }

    QJsonObject state(const QJsonObject &args, quint64 generation, const QJsonObject &provider) {
        if (args.contains("stream_id")) {
            QJsonObject failure;
            Session *session = find(args, generation, &failure);
            return session ? common(*session) : failure;
        }
        QJsonArray sessions;
        for (const auto &session : sessions_) sessions.append(common(session));
        return {{"status", "host_limited"}, {"state", "not_ready"},
            {"reason", "no_verified_realtime_tap"}, {"generation", qint64(generation)},
            {"provider", provider}, {"sessions", sessions},
            {"pcm_available", false}, {"scope", "current_mcp_instance"}};
    }

    QJsonObject snapshot(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        QJsonObject result = common(*session);
        result["window"] = QJsonObject{{"frames", 0}, {"rms", 0.0}, {"peak", 0.0}, {"dc", 0.0},
            {"clipped", 0}, {"non_finite", 0}, {"first_timestamp_ns", 0}, {"last_timestamp_ns", 0}};
        result["continuity"] = QJsonObject{{"expected_frames", 0}, {"actual_frames", 0},
            {"host_dropped_frames", qint64(session->hostDroppedFrames)},
            {"monitor_dropped_frames", session->ring ? qint64(session->ring->monitorDroppedFrames()) : 0},
            {"underrun", 0}, {"overrun", 0}, {"xrun", 0}, {"timestamp_jumps", 0}};
        return result;
    }

    QJsonObject read(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        const int requested = args.value("max_frames").toInt(session->maxFrames);
        if (requested < 1 || requested > MaxReadFrames) return error("max_frames must be 1..4096");
        return {{"status", session->state}, {"stream_id", session->id}, {"generation", qint64(session->generation)},
            {"frames", 0}, {"chunks", QJsonArray{}}, {"pcm_available", false},
            {"monitor_dropped_frames", session->ring ? qint64(session->ring->monitorDroppedFrames()) : 0},
            {"reason", session->reason}, {"max_frames", requested}};
    }

    QJsonObject diagnose(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        QJsonArray checks;
        const QStringList names{"topology", "format", "continuity", "signal", "endpoint"};
        for (const auto &name : names) checks.append(QJsonObject{{"name", name}, {"status", "host_limited"},
            {"reason", name == "endpoint" ? "no_verified_realtime_endpoint" : "no_verified_realtime_tap"},
            {"confidence", "unverified"}});
        QJsonObject result = common(*session);
        result["diagnostic_status"] = "host_limited";
        result["checks"] = checks;
        result["suggested_action"] = "Do not infer device or driver failure from missing tap evidence";
        return result;
    }

    QJsonObject recover(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        return {{"status", "host_limited"}, {"state", session->state}, {"stream_id", session->id},
            {"generation", qint64(session->generation)}, {"recovered", false},
            {"reason", "no_verified_realtime_tap"}, {"action", "none"},
            {"outcome_unknown", false}};
    }
};

} // namespace guitarpro
