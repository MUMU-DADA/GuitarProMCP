#pragma once

#include "audio_stream_api.h"
#include "guitarpro_audio.h"
#include <QtCore/QDateTime>
#include <QtCore/QHash>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
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
#include <memory>
#include <string>
#include <vector>

namespace guitarpro {

// The callback-facing block has a fixed size.  WASAPI copies one block without
// allocating, calling Qt, or retaining a host pointer.  The same block type is
// also used by the deterministic contract fixture.
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

    uint64_t depth() const noexcept {
        const uint64_t write = write_.load(std::memory_order_acquire);
        const uint64_t read = read_.load(std::memory_order_acquire);
        return write >= read ? write - read : 0;
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

} // namespace guitarpro

#include "wasapi_loopback_capture.h"

namespace guitarpro {

class AudioStreamRegistry final {
public:
    static constexpr int MaxReadFrames = 4096;
    static constexpr int MaxReadBytes = 1024 * 1024;
    static constexpr int MaxSessions = 32;
    static constexpr int MaxActiveSessions = 4;

    explicit AudioStreamRegistry(bool enableLiveCapture = true)
        : liveCapture_(enableLiveCapture) {}

    QJsonObject handle(const QJsonObject &args, const QString &document,
                       quint64 generation, const QJsonObject &provider) {
        const QString operation = args.value("operation").toString("state");
        refresh(generation);
        if (operation == "start") return start(args, document, generation, provider);
        if (operation == "stop") return stop(args, generation);
        if (operation == "snapshot") return snapshot(args, generation);
        if (operation == "read") return read(args, generation);
        if (operation == "diagnose") return diagnose(args, generation);
        if (operation == "recover") return recover(args, generation);
        if (operation == "state") return state(args, generation, provider);
        return error("operation must be state, start, stop, snapshot, read, diagnose or recover");
    }

    void refresh(quint64 generation) {
        for (auto &session : sessions_) {
            if (session.generation != generation) {
                if (session.capture) session.capture->stop();
                if (session.ring) session.ring->clear();
                session.hasPending = false;
                session.state = "stale";
                session.reason = "document_or_host_generation_changed";
            } else if (session.capture && session.state == "running" &&
                       session.capture->state() == AudioCaptureState::Error) {
                session.state = "error";
                session.reason = QString::fromStdString(session.capture->reason());
            }
        }
    }

    QJsonObject info(quint64 generation, const QByteArray &hostHash) {
        refresh(generation);
        QJsonArray capabilities{"session", "metrics", "diagnostics", "recovery"};
        if (liveCapture_) capabilities.prepend("pcm");
        QJsonObject result{{"abi_version", int(GPMCP_AUDIO_STREAM_ABI_VERSION)},
            {"status", liveCapture_ ? "ready" : "host_limited"}, {"generation", qint64(generation)},
            {"capabilities", capabilities},
            {"stream_count", sessions_.size()},
            {"scope", "process_loopback_with_render_endpoint_fallback"},
            {"host_build_sha256", QString::fromLatin1(hostHash)}};
        if (!liveCapture_) result["reason"] = "live_capture_disabled_for_fixture";
        return result;
    }

    uint32_t enumerate(uint32_t requestedAbi, gpmcp_audio_stream_state_visitor visitor,
                       void *user, gpmcp_audio_stream_enumerate_result *result,
                       quint64 generation) {
        if (!result || result->struct_size < sizeof(*result)) return GPMCP_AUDIO_STREAM_ABI_MISMATCH;
        result->status = GPMCP_AUDIO_STREAM_NOT_READY;
        result->generation = generation;
        result->count = 0;
        if (requestedAbi != GPMCP_AUDIO_STREAM_ABI_VERSION) return result->status = GPMCP_AUDIO_STREAM_ABI_MISMATCH;
        if (!visitor) return result->status = GPMCP_AUDIO_STREAM_INVALID_ARGUMENT;
        refresh(generation);
        for (const auto &entry : sessions_) {
            const Session &session = entry;
            gpmcp_audio_stream_state state{};
            state.struct_size = sizeof(state);
            state.abi_version = GPMCP_AUDIO_STREAM_ABI_VERSION;
            state.status = statusCode(session.state);
            state.state = stateCode(session.state);
            state.generation = session.generation;
            const auto stats = session.capture ? session.capture->stats() : AudioCaptureStats{};
            state.frame_count = stats.frameCount;
            state.host_dropped_frames = stats.hostDroppedFrames;
            state.monitor_dropped_frames = session.ring ? session.ring->monitorDroppedFrames() : 0;
            copyField(state.stream_id, sizeof(state.stream_id), session.id);
            copyField(state.document_id, sizeof(state.document_id), session.document);
            copyField(state.reason, sizeof(state.reason), session.reason);
            state.sample_rate = stats.format.sampleRate;
            state.channels = stats.format.channels;
            state.frames_per_block = AudioStreamPcmBlock::MaxFrames;
            copyField(state.sample_format, sizeof(state.sample_format), stats.format.sampleFormat);
            visitor(user, &state);
            ++result->count;
        }
        result->status = liveCapture_ ? GPMCP_AUDIO_STREAM_OK : GPMCP_AUDIO_STREAM_HOST_LIMITED;
        return result->status;
    }

    void clear() {
        for (auto &entry : sessions_) if (entry.capture) entry.capture->stop();
        sessions_.clear();
    }

    ~AudioStreamRegistry() { clear(); }

private:
    struct Session {
        QString id;
        QString document;
        QStringList layers;
        QString state = QStringLiteral("not_ready");
        QString reason = QStringLiteral("not_started");
        quint64 generation = 0;
        qint64 createdAt = 0;
        int maxFrames = 1024;
        int maxBytes = 256 * 1024;
        QString backend = QStringLiteral("auto");
        std::shared_ptr<AudioStreamRing> ring;
        std::shared_ptr<WasapiLoopbackCapture> capture;
        AudioStreamPcmBlock pending{};
        bool hasPending = false;
        int recoveryCount = 0;
    };

    QHash<QString, Session> sessions_;

    bool liveCapture_ = true;

    static QJsonObject error(const QString &message) { return {{"status", "error"}, {"error", message}}; }

    static uint32_t statusCode(const QString &state) {
        if (state == "running" || state == "ready") return GPMCP_AUDIO_STREAM_OK;
        if (state == "stale") return GPMCP_AUDIO_STREAM_STALE;
        if (state == "stopped") return GPMCP_AUDIO_STREAM_NOT_READY;
        if (state == "error") return GPMCP_AUDIO_STREAM_INTERNAL_ERROR;
        if (state == "host_limited") return GPMCP_AUDIO_STREAM_HOST_LIMITED;
        return GPMCP_AUDIO_STREAM_NOT_READY;
    }

    static uint32_t stateCode(const QString &state) {
        if (state == "ready") return 1;
        if (state == "running") return 2;
        if (state == "degraded") return 3;
        if (state == "stopped") return 4;
        if (state == "stale") return 5;
        if (state == "error") return 6;
        return 0;
    }

    static void copyField(char *destination, size_t capacity, const QString &value) {
        if (!destination || !capacity) return;
        const QByteArray bytes = value.toUtf8();
        const size_t count = (std::min)(capacity - 1, static_cast<size_t>(bytes.size()));
        std::memset(destination, 0, capacity);
        if (count) std::memcpy(destination, bytes.constData(), count);
    }

    static void copyField(char *destination, size_t capacity, const std::string &value) {
        if (!destination || !capacity) return;
        const size_t count = (std::min)(capacity - 1, value.size());
        std::memset(destination, 0, capacity);
        if (count) std::memcpy(destination, value.data(), count);
    }

    static QStringList requestedLayers(const QJsonValue &value) {
        if (!value.isArray()) return {"input", "source", "track", "effects", "mix", "audiolayer", "endpoint"};
        QStringList result;
        static const QStringList allowed{"input", "source", "track", "effects", "mix", "audiolayer", "endpoint"};
        for (const auto &item : value.toArray()) if (item.isString() && allowed.contains(item.toString()) && !result.contains(item.toString())) result.append(item.toString());
        return result;
    }

    static QJsonObject common(const Session &session, const QString &statusOverride = {}) {
        const QString status = statusOverride.isEmpty() ? session.state : statusOverride;
        const auto stats = session.capture ? session.capture->stats() : AudioCaptureStats{};
        QJsonObject result{{"status", status}, {"state", session.state}, {"stream_id", session.id},
            {"document", session.document}, {"generation", qint64(session.generation)},
            {"reason", session.reason}, {"created_at_ms", session.createdAt},
            {"observed_at_ms", QDateTime::currentMSecsSinceEpoch()}, {"recovery_count", session.recoveryCount},
            {"layers", QJsonArray::fromStringList(session.layers)},
            {"backend", session.backend}, {"capture_scope", QString::fromStdString(stats.format.scope)},
            {"endpoint", QString::fromStdString(stats.format.endpoint)},
            {"sample_rate", int(stats.format.sampleRate)}, {"channels", int(stats.format.channels)},
            {"sample_format", QString::fromStdString(stats.format.sampleFormat)},
            {"frames_per_block", int(AudioStreamPcmBlock::MaxFrames)}, {"frame_count", qint64(stats.frameCount)},
            {"host_dropped_frames", qint64(stats.hostDroppedFrames)},
            {"monitor_dropped_frames", session.ring ? qint64(session.ring->monitorDroppedFrames()) : 0},
            {"callback_count", qint64(stats.callbackCount)},
            {"callback_total_ns", qint64(stats.callbackTotalNs)},
            {"callback_max_ns", qint64(stats.callbackMaxNs)},
            {"buffer_depth", session.ring ? qint64(session.ring->depth()) : 0},
            {"buffer_capacity", int(AudioStreamRing::Capacity)},
            {"underrun", qint64(stats.underrun)}, {"overrun", qint64(stats.overrun)},
            {"xrun", qint64(stats.xrun)}, {"timestamp_jumps", qint64(stats.timestampJumps)},
            {"discontinuities", qint64(stats.discontinuities)}, {"timestamp_errors", qint64(stats.timestampErrors)},
            {"metric_sources", QJsonObject{{"pcm", "wasapi_capture_client"}, {"host_dropped_frames", "device_position_gap"},
                {"monitor_dropped_frames", "fixed_spsc_ring"}, {"underrun", "not_observed"}}},
            {"pcm_available", session.capture && stats.state == AudioCaptureState::Running}};
        QJsonArray layerStates;
        for (const auto &layer : session.layers) {
            const bool endpoint = layer == "endpoint";
            layerStates.append(QJsonObject{{"layer", layer},
                {"status", endpoint && stats.format.sampleRate ? "observed" : "not_observed"},
                {"reason", endpoint && stats.format.sampleRate ? "process_or_render_loopback" : "no_samples_at_this_layer"}});
        }
        result["layer_states"] = layerStates;
        return result;
    }

    static AudioCaptureMode captureMode(const QString &backend) {
        const QString value = backend.toLower();
        if (value == "process_loopback") return AudioCaptureMode::ProcessLoopback;
        if (value == "render_loopback") return AudioCaptureMode::RenderLoopback;
        return AudioCaptureMode::Automatic;
    }

    Session *find(const QJsonObject &args, quint64 generation, QJsonObject *failure) {
        const QString id = args.value("stream_id").toString();
        if (id.isEmpty()) { if (failure) *failure = error("stream_id is required"); return nullptr; }
        auto it = sessions_.find(id);
        if (it == sessions_.end()) { if (failure) *failure = {{"status", "stale"}, {"error", "Unknown or expired stream_id"}, {"reason", "stream_not_found"}}; return nullptr; }
        if (args.contains("document") && args.value("document").toString() != it->document) {
            if (failure) *failure = error("stream_id belongs to another document");
            return nullptr;
        }
        return &it.value();
    }

    QJsonObject start(const QJsonObject &args, const QString &document, quint64 generation, const QJsonObject &) {
        if (document.isEmpty()) return error("Choose a verified document before starting an audio stream");
        const int maxFrames = args.value("max_frames").toInt(1024);
        const int maxBytes = args.value("max_bytes").toInt(256 * 1024);
        if (maxFrames < 1 || maxFrames > MaxReadFrames || maxBytes < 4096 || maxBytes > MaxReadBytes)
            return error("max_frames must be 1..4096 and max_bytes must be 4096..1048576");
        int active = 0;
        for (const auto &entry : sessions_) if (entry.state == "running") ++active;
        if (active >= MaxActiveSessions) return error("Stop an existing stream before starting more than four captures");
        if (args.contains("layers")) {
            const auto layers = args.value("layers");
            if (!layers.isArray() || layers.toArray().isEmpty() || requestedLayers(layers).size() != layers.toArray().size())
                return error("layers must contain unique input/source/track/effects/mix/audiolayer/endpoint names");
        }
        Session session;
        session.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        session.document = document;
        session.layers = requestedLayers(args.value("layers"));
        session.generation = generation;
        session.createdAt = QDateTime::currentMSecsSinceEpoch();
        session.maxFrames = maxFrames;
        session.maxBytes = maxBytes;
        session.backend = args.value("backend").toString("auto");
        if (!QStringList{"auto", "standard", "asio", "process_loopback", "render_loopback"}.contains(session.backend.toLower()))
            return error("backend must be auto, standard, asio, process_loopback or render_loopback");
        session.ring = std::make_shared<AudioStreamRing>();
        if (liveCapture_) {
            session.capture = std::make_shared<WasapiLoopbackCapture>(session.ring, generation, captureMode(session.backend));
            std::string captureError;
            if (!session.capture->start(&captureError)) {
                session.state = "error";
                session.reason = QString::fromStdString(captureError.empty() ? "audio_capture_start_failed" : captureError);
            } else {
                session.state = "running";
                const auto captureStats = session.capture->stats();
                session.reason = QString::fromStdString(captureStats.reason.empty() ? "audio_capture_running" : captureStats.reason);
            }
        } else {
            session.state = "host_limited";
            session.reason = "live_capture_disabled_for_fixture";
        }
        if (sessions_.size() >= MaxSessions) {
            auto oldest = sessions_.end();
            for (auto it = sessions_.begin(); it != sessions_.end(); ++it)
                if (it->state != "running" && (oldest == sessions_.end() || it->createdAt < oldest->createdAt)) oldest = it;
            if (oldest != sessions_.end()) sessions_.erase(oldest);
        }
        sessions_.insert(session.id, session);
        QJsonObject result = common(sessions_.value(session.id), sessions_.value(session.id).state);
        if (sessions_.value(session.id).state == "error") result["error"] = sessions_.value(session.id).reason;
        return result;
    }

    QJsonObject stop(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        if (session->capture) session->capture->stop();
        session->state = "stopped";
        session->reason = "stopped_by_client";
        if (session->ring) session->ring->clear();
        session->hasPending = false;
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
        return {{"status", liveCapture_ ? "ready" : "host_limited"}, {"state", sessions_.isEmpty() ? "not_ready" : "ready"},
            {"reason", liveCapture_ ? "process_loopback_available" : "live_capture_disabled_for_fixture"}, {"generation", qint64(generation)},
            {"provider", provider}, {"sessions", sessions},
            {"pcm_available", liveCapture_}, {"scope", "current_mcp_instance"},
            {"capture_scope", "process_loopback_with_render_endpoint_fallback"}};
    }

    QJsonObject snapshot(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        const auto stats = session->capture ? session->capture->stats() : AudioCaptureStats{};
        const uint64_t finite = stats.sampleCount > stats.nonFinite ? stats.sampleCount - stats.nonFinite : 0;
        const double rms = finite ? std::sqrt(stats.squareSum / finite) : 0.0;
        const double dc = finite ? stats.sampleSum / finite : 0.0;
        QJsonObject result = common(*session);
        result["window"] = QJsonObject{{"scope", "since_start_or_recover"}, {"frames", qint64(stats.frameCount)}, {"rms", rms}, {"peak", stats.peak}, {"dc", dc},
            {"clipped", qint64(stats.clipped)}, {"non_finite", qint64(stats.nonFinite)}, {"first_timestamp_ns", qint64(stats.firstTimestampNs)}, {"last_timestamp_ns", qint64(stats.lastTimestampNs)}};
        result["continuity"] = QJsonObject{{"expected_frames", qint64(stats.frameCount + stats.hostDroppedFrames)}, {"actual_frames", qint64(stats.frameCount)},
            {"host_dropped_frames", qint64(stats.hostDroppedFrames)},
            {"monitor_dropped_frames", session->ring ? qint64(session->ring->monitorDroppedFrames()) : 0},
            {"buffer_depth", session->ring ? qint64(session->ring->depth()) : 0},
            {"underrun", qint64(stats.underrun)}, {"overrun", qint64(stats.overrun)}, {"xrun", qint64(stats.xrun)}, {"timestamp_jumps", qint64(stats.timestampJumps)},
            {"discontinuities", qint64(stats.discontinuities)}, {"timestamp_errors", qint64(stats.timestampErrors)}};
        return result;
    }

    QJsonObject read(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        const int requested = args.value("max_frames").toInt(session->maxFrames);
        if (requested < 1 || requested > MaxReadFrames) return error("max_frames must be 1..4096");
        const int maxBytes = args.value("max_bytes").toInt(session->maxBytes);
        if (maxBytes < 4096 || maxBytes > MaxReadBytes) return error("max_bytes must be 4096..1048576");
        QJsonArray chunks;
        int frames = 0;
        int bytes = 0;
        const auto makeResult = [&]() {
            return QJsonObject{{"status", session->state}, {"stream_id", session->id}, {"generation", qint64(session->generation)},
                {"frames", frames}, {"chunks", chunks}, {"pcm_available", frames > 0},
                {"monitor_dropped_frames", session->ring ? qint64(session->ring->monitorDroppedFrames()) : 0},
                {"reason", session->reason}, {"max_frames", requested}, {"max_bytes", maxBytes}, {"bytes", bytes},
                {"serialized_bytes", maxBytes}};
        };
        AudioStreamPcmBlock block;
        while (frames < requested && (session->hasPending || (session->ring && session->ring->pop(&block)))) {
            if (session->hasPending) {
                block = session->pending;
                session->hasPending = false;
            }
            const uint32_t take = (std::min<uint32_t>)(block.frames, static_cast<uint32_t>(requested - frames));
            uint32_t boundedTake = take;
            const size_t maxRawBytes = static_cast<size_t>((std::max)(0, maxBytes - bytes)) * 3 / 4;
            const uint32_t byBytes = block.channels ? static_cast<uint32_t>(maxRawBytes / (block.channels * sizeof(float))) : 0;
            boundedTake = (std::min)(boundedTake, byBytes);
            if (!boundedTake) {
                session->pending = block;
                session->hasPending = true;
                break;
            }
            QByteArray pcm;
            QByteArray encoded;
            int chunkBytes = 0;
            QJsonObject candidate;
            // max_bytes bounds the compact structured result.  Shrink a
            // chunk before returning it so metadata and base64 overhead are
            // included in the limit as well as the raw PCM bytes.
            while (boundedTake) {
                const size_t samples = static_cast<size_t>(boundedTake) * block.channels;
                pcm = QByteArray(reinterpret_cast<const char *>(block.samples), static_cast<int>(samples * sizeof(float)));
                encoded = pcm.toBase64();
                chunkBytes = encoded.size();
                QJsonArray candidateChunks = chunks;
                candidateChunks.append(QJsonObject{{"layer", "endpoint"}, {"frame_start", qint64(block.frame_start)},
                    {"timestamp_ns", qint64(block.timestamp_ns)}, {"frames", int(boundedTake)}, {"sample_rate", int(block.sample_rate)},
                    {"channels", int(block.channels)}, {"format", "f32le"}, {"bytes", int(pcm.size())}, {"pcm_base64", QString::fromLatin1(encoded)}});
                candidate = makeResult();
                candidate["chunks"] = candidateChunks;
                candidate["frames"] = frames + int(boundedTake);
                candidate["bytes"] = bytes + chunkBytes;
                if (QJsonDocument(candidate).toJson(QJsonDocument::Compact).size() <= maxBytes) break;
                boundedTake /= 2;
            }
            if (!boundedTake) {
                session->pending = block;
                session->hasPending = true;
                break;
            }
            chunks.append(QJsonObject{{"layer", "endpoint"}, {"frame_start", qint64(block.frame_start)},
                {"timestamp_ns", qint64(block.timestamp_ns)}, {"frames", int(boundedTake)}, {"sample_rate", int(block.sample_rate)},
                {"channels", int(block.channels)}, {"format", "f32le"}, {"bytes", pcm.size()}, {"pcm_base64", QString::fromLatin1(encoded)}});
            frames += static_cast<int>(boundedTake);
            bytes += chunkBytes;
            if (boundedTake < block.frames) {
                const uint32_t remaining = block.frames - boundedTake;
                const size_t remainingSamples = static_cast<size_t>(remaining) * block.channels;
                std::memmove(block.samples, block.samples + static_cast<size_t>(boundedTake) * block.channels,
                             remainingSamples * sizeof(float));
                block.frame_start += boundedTake;
                block.timestamp_ns += block.sample_rate ? static_cast<uint64_t>((static_cast<long double>(boundedTake) * 1000000000.0L) / block.sample_rate) : 0;
                block.frames = remaining;
                session->pending = block;
                session->hasPending = true;
                break;
            }
        }
        QJsonObject result = makeResult();
        result["serialized_bytes"] = QJsonDocument(result).toJson(QJsonDocument::Compact).size();
        result["serialized_bytes"] = QJsonDocument(result).toJson(QJsonDocument::Compact).size();
        return result;
    }

    QJsonObject diagnose(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        const auto stats = session->capture ? session->capture->stats() : AudioCaptureStats{};
        const auto addCheck = [](QJsonArray &checks, const QString &name, const QString &status,
                                 const QString &reason, const QString &confidence) {
            checks.append(QJsonObject{{"name", name}, {"status", status}, {"reason", reason}, {"confidence", confidence}});
        };
        QJsonArray checks;
        addCheck(checks, "topology", session->capture ? "observed" : "not_ready",
                 session->capture ? QString::fromStdString(stats.format.scope) : "capture_not_started", session->capture ? "observed" : "unknown");
        addCheck(checks, "format", stats.format.sampleRate ? "observed" : "not_ready",
                 stats.format.sampleRate ? QString::fromStdString(stats.format.sampleFormat) : "format_unavailable", stats.format.sampleRate ? "observed" : "unknown");
        addCheck(checks, "continuity", (stats.hostDroppedFrames || stats.xrun || stats.timestampJumps || stats.discontinuities) ? "degraded" : (stats.frameCount ? "ok" : "not_ready"),
                 stats.hostDroppedFrames || stats.xrun || stats.timestampJumps || stats.discontinuities ? "continuity_counter_nonzero" : "no_continuity_fault_observed", stats.frameCount ? "observed" : "unknown");
        addCheck(checks, "signal", stats.nonFinite ? "degraded" : (stats.sampleCount ? "ok" : "not_ready"),
                 stats.nonFinite ? "nonfinite_samples" : stats.sampleCount ? "finite_samples" : "no_samples", stats.sampleCount ? "observed" : "unknown");
        addCheck(checks, "endpoint", session->capture && stats.state == AudioCaptureState::Running ? "observed" : "error",
                 session->capture ? QString::fromStdString(stats.format.endpoint) : "endpoint_unavailable", session->capture ? "observed" : "unknown");
        QJsonObject result = common(*session);
        result["diagnostic_status"] = session->capture && stats.state == AudioCaptureState::Running ? "ok" : "error";
        result["checks"] = checks;
        result["suggested_action"] = stats.hostDroppedFrames || stats.xrun || stats.discontinuities ? "Restart the process loopback after checking the endpoint" : "Continue polling snapshot while playback is active";
        return result;
    }

    QJsonObject recover(const QJsonObject &args, quint64 generation) {
        QJsonObject failure;
        Session *session = find(args, generation, &failure);
        if (!session) return failure;
        if (session->state == "stale" || session->generation != generation)
            return {{"status", "stale"}, {"stream_id", session->id}, {"generation", qint64(session->generation)},
                {"reason", "document_or_host_generation_changed"}, {"recovered", false}};
        if (session->capture) session->capture->stop();
        if (session->ring) session->ring->clear();
        session->hasPending = false;
        session->ring = std::make_shared<AudioStreamRing>();
        session->capture = std::make_shared<WasapiLoopbackCapture>(session->ring, generation, captureMode(session->backend));
        std::string errorText;
        const bool restarted = liveCapture_ && session->capture->start(&errorText);
        if (restarted) {
            session->generation = generation;
            session->state = "running";
            session->reason = "recovered_process_loopback";
            ++session->recoveryCount;
            QJsonObject result = common(*session, "running");
            result["recovered"] = true;
            result["action"] = "restart_loopback";
            return result;
        }
        session->state = "error";
        session->reason = QString::fromStdString(errorText.empty() ? "audio_capture_recovery_failed" : errorText);
        QJsonObject result = common(*session, "error");
        result["recovered"] = false;
        result["action"] = "restart_loopback";
        result["outcome_unknown"] = false;
        return result;
    }
};

} // namespace guitarpro
