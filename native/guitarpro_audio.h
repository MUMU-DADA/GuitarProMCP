#pragma once
#include "guitarpro_api.h"
#include "audio_bridge_api.h"
#include <algorithm>
#include <QtCore/QMetaEnum>
#include <QtCore/QDateTime>
#include <QtCore/QHash>
#include <QtCore/QJsonArray>
#include <QtCore/QThread>
#include <QtCore/QSet>
#include <QtCore/QUuid>
#include <windows.h>
#include <cstddef>

namespace guitarpro {
inline QList<gp::rse::ConductorController *> audioControllers(
    const Document &document, const QList<QPointer<QObject>> &objects);
inline QString audioControllerKey(gp::rse::ConductorController *controller,
                                  const QList<QPointer<QObject>> &objects);
inline gp::rse::ConductorController *audioController(const Document &document, const QList<QPointer<QObject>> &objects) {
    const auto candidates = audioControllers(document, objects);
    return candidates.isEmpty() ? nullptr : candidates.first();
}

// During a score/sound rebuild Guitar Pro can keep more than one matching
// controller alive for a short period.  Keep every verified candidate so a
// caller can select the one that actually owns the runtime sound/chain.
inline QList<gp::rse::ConductorController *> audioControllers(
    const Document &document, const QList<QPointer<QObject>> &objects) {
    QList<gp::rse::ConductorController *> result;
    static const bool verified = verifiedHostFile("GPRSE.dll");
    if (!verified || !document.score) return result;
    for (const auto &object : objects) {
        if (!object || QByteArray(object->metaObject()->className()) !=
            "gp::rse::ConductorController") continue;
        auto *candidate = reinterpret_cast<gp::rse::ConductorController *>(object.data());
        const auto &conductor = candidate->conductor();
        if (!conductor || conductor->score().get() != document.score) continue;
        if (!result.contains(candidate)) result.append(candidate);
    }
    std::sort(result.begin(), result.end(), [&](auto *left, auto *right) {
        const QString leftKey = audioControllerKey(left, objects);
        const QString rightKey = audioControllerKey(right, objects);
        if (leftKey != rightKey) return leftKey < rightKey;
        return reinterpret_cast<quintptr>(left) < reinterpret_cast<quintptr>(right);
    });
    return result;
}
inline void refreshTempo(const QJsonObject &args, const QList<QPointer<QObject>> &objects) {
    const auto controller = audioController(choose(args), objects);
    if (controller) controller->conductor()->updateTempoManagerAsync({});
}

// Opaque handles are process-local capabilities.  They never contain a native
// address; every use re-resolves the current conductor and checks the Score,
// core Track, Musician, Sound and EffectsChain identity before dereferencing.
struct AudioTrackHandle {
    QString id;
    QString document;
    gp::core::Score *score = nullptr;
    gp::core::Track *track = nullptr;
    gp::rse::Musician *musician = nullptr;
    int index = -1;
    quint64 generation = 0;
    int controllerIndex = -1;
    QString controllerKey;
    std::weak_ptr<gp::core::Track> lifetime;
};
struct AudioChainHandle {
    QString id;
    QString document;
    gp::core::Score *score = nullptr;
    gp::core::Track *track = nullptr;
    gp::rse::Musician *musician = nullptr;
    gp::rse::Sound *sound = nullptr;
    gp::rse::EffectsChain *chain = nullptr;
    int trackIndex = -1;
    int soundIndex = -1;
    quint64 generation = 0;
    int controllerIndex = -1;
    QString controllerKey;
    std::weak_ptr<gp::rse::Sound> soundLifetime;
    std::weak_ptr<gp::rse::EffectsChain> chainLifetime;
};
inline QHash<QString, AudioTrackHandle> &audioTrackHandles() { static QHash<QString, AudioTrackHandle> value; return value; }
inline QHash<QString, AudioChainHandle> &audioChainHandles() { static QHash<QString, AudioChainHandle> value; return value; }

struct AudioDocumentGeneration {
    gp::core::Score *score = nullptr;
    quint64 trackFingerprint = 0;
    quint64 generation = 0;
};
inline QHash<QString, AudioDocumentGeneration> &audioDocumentGenerations() {
    static QHash<QString, AudioDocumentGeneration> value;
    return value;
}
inline quint64 &audioEpoch() { static quint64 value = 0; return value; }
inline quint64 audioTrackFingerprint(const Document &document) {
    if (!document.score) return 0;
    quint64 value = 1469598103934665603ull;
    for (const auto &track : document.score->tracks()) {
        value ^= quint64(reinterpret_cast<quintptr>(track.get()));
        value *= 1099511628211ull;
    }
    value ^= quint64(document.score->tracks().size());
    return value;
}
inline void pruneAudioHandles() {
    QSet<QString> live;
    for (const auto &document : documents()) live.insert(document.id());
    for (auto it = audioDocumentGenerations().begin(); it != audioDocumentGenerations().end();) {
        if (!live.contains(it.key())) { it = audioDocumentGenerations().erase(it); ++audioEpoch(); }
        else ++it;
    }
    for (auto it = audioChainHandles().begin(); it != audioChainHandles().end();) {
        if (!live.contains(it->document) || it->soundLifetime.expired() || it->chainLifetime.expired()) it = audioChainHandles().erase(it);
        else ++it;
    }
    for (auto it = audioTrackHandles().begin(); it != audioTrackHandles().end();) {
        if (!live.contains(it->document) || it->lifetime.expired()) it = audioTrackHandles().erase(it);
        else ++it;
    }
}
inline quint64 audioGeneration(const Document &document) {
    if (!document.object || !document.score) return 0;
    const QString documentId = document.id();
    const quint64 fingerprint = audioTrackFingerprint(document);
    auto &state = audioDocumentGenerations()[documentId];
    if (!state.generation) {
        state = {document.score, fingerprint, ++audioEpoch()};
    } else if (state.score != document.score || state.trackFingerprint != fingerprint) {
        state.generation = ++audioEpoch();
        state.score = document.score;
        state.trackFingerprint = fingerprint;
        for (auto it = audioChainHandles().begin(); it != audioChainHandles().end();) {
            if (it->document == documentId) it = audioChainHandles().erase(it);
            else ++it;
        }
        for (auto it = audioTrackHandles().begin(); it != audioTrackHandles().end();) {
            if (it->document == documentId) it = audioTrackHandles().erase(it);
            else ++it;
        }
    }
    return state.generation;
}
inline void clearAudioBindings() {
    audioTrackHandles().clear();
    audioChainHandles().clear();
    audioDocumentGenerations().clear();
    ++audioEpoch();
}
inline quint64 currentAudioGeneration() {
    pruneAudioHandles();
    for (const auto &document : documents()) audioGeneration(document);
    return audioEpoch();
}

inline QString audioControllerKey(gp::rse::ConductorController *controller,
                                  const QList<QPointer<QObject>> &objects) {
    if (!controller) return {};
    for (const auto &object : objects) {
        if (object && reinterpret_cast<void *>(object.data()) == reinterpret_cast<void *>(controller)) {
            const QString className = QString::fromLatin1(object->metaObject()->className());
            const QString objectName = object->objectName();
            return objectName.isEmpty() ? className : className + QStringLiteral("/") + objectName;
        }
    }
    return QStringLiteral("gp::rse::ConductorController");
}

inline int audioControllerIndex(const QList<gp::rse::ConductorController *> &controllers,
                                gp::rse::ConductorController *controller) {
    return controllers.indexOf(controller);
}

inline bool verifiedRseObject(const void *object, const char *rtti) {
    return object && discovery::type(reinterpret_cast<quintptr>(object)) == rtti;
}

inline QJsonObject audioAbi(const QJsonObject &args, const QList<QPointer<QObject>> &objects) {
    pruneAudioHandles();
    const bool rseVerified = supportedBuild() && verifiedHostFile("GPRSE.dll");
    const bool audioVerified = supportedBuild() && verifiedHostFile("AMAudio.dll");
    const QString operation = args.value("operation").toString("state");
    if (operation == "buffer_probe" && !qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT"))
        return {{"status", "host_limited"}, {"reason", "buffer_probe is development-only until the real host regression is recorded"},
            {"rse_abi_verified", rseVerified}, {"audio_abi_verified", audioVerified}};
    if (!rseVerified || (operation == "buffer_probe" && !audioVerified))
        return {{"status", "host_limited"}, {"reason", "GPRSE.dll/AMAudio.dll hash is not verified"},
            {"rse_abi_verified", rseVerified}, {"audio_abi_verified", audioVerified}};

    // Reject unknown capabilities before document lookup.  This keeps an old
    // or malformed ID distinguishable from a temporarily unavailable score.
    if (operation == "resolve") {
        const QString requestedTrackId = args.value("track_id").toString();
        const QString requestedChainId = args.value("chain_id").toString();
        if (!requestedTrackId.isEmpty() && !audioTrackHandles().contains(requestedTrackId))
            return {{"status", "error"}, {"reason", "unknown_or_expired_track_id"}};
        if (requestedTrackId.isEmpty() && !requestedChainId.isEmpty() && !audioChainHandles().contains(requestedChainId))
            return {{"status", "error"}, {"reason", "unknown_or_expired_chain_id"}};
    }
    if (operation == "buffer_probe" && args.contains("chain_id") &&
        !audioChainHandles().contains(args.value("chain_id").toString()))
        return {{"status", "error"}, {"reason", "unknown_or_expired_chain_id"}};

    const auto document = choose(args);
    if (!document.score) {
        if (operation == "resolve" && args.contains("track_id") && audioTrackHandles().contains(args.value("track_id").toString()))
            return {{"status", "error"}, {"reason", "stale_track_id"}, {"detail", "document is closed or no longer observable"}};
        if ((operation == "resolve" || operation == "buffer_probe") && args.contains("chain_id") && audioChainHandles().contains(args.value("chain_id").toString()))
            return {{"status", "error"}, {"reason", "stale_chain_id"}, {"detail", "document is closed or no longer observable"}};
        return {{"status", "host_limited"}, {"reason", "verified native score is unavailable"}};
    }
    const quint64 generation = audioGeneration(document);
    const auto controllers = audioControllers(document, objects);
    if (controllers.isEmpty())
        return {{"status", "host_limited"}, {"reason", "RSE conductor for this document is unavailable"}, {"document", document.id()}};

    const auto trackHandle = [&](int index, AudioTrackHandle *out, QString *error,
                                 gp::rse::ConductorController **owner = nullptr) {
        if (index < 0 || size_t(index) >= document.score->tracks().size()) { if (error) *error = "Existing track index required"; return false; }
        const auto &coreTrack = document.score->tracks()[size_t(index)];
        if (!coreTrack || !verifiedRseObject(coreTrack.get(), ".?AVTrack@core@gp@@")) { if (error) *error = "Core track RTTI validation failed"; return false; }
        gp::rse::Musician *musician = nullptr;
        gp::rse::ConductorController *selected = nullptr;
        for (auto *candidate : controllers) {
            const auto conductor = candidate ? candidate->conductor() : nullptr;
            if (!conductor || conductor->score().get() != document.score) continue;
            auto *value = conductor->musician(unsigned(index));
            if (!verifiedRseObject(value, ".?AVMusician@rse@gp@@")) continue;
            const auto &bound = value->coreTrack();
            if (!bound || bound.get() != coreTrack.get()) continue;
            musician = value;
            selected = candidate;
            break;
        }
        if (!musician) { if (error) *error = "RSE musician is unavailable for this track"; return false; }
        for (auto it = audioTrackHandles().begin(); it != audioTrackHandles().end(); ++it) {
            if (it->document == document.id() && it->score == document.score && it->track == coreTrack.get() &&
                !it->lifetime.expired() && it->lifetime.lock().get() == coreTrack.get()) {
                it->index = index;
                it->musician = musician;
                it->generation = generation;
                it->controllerIndex = audioControllerIndex(controllers, selected);
                it->controllerKey = audioControllerKey(selected, objects);
                if (out) *out = it.value();
                if (owner) *owner = selected;
                return true;
            }
        }
        AudioTrackHandle handle{QUuid::createUuid().toString(QUuid::WithoutBraces), document.id(), document.score, coreTrack.get(), musician,
            index, generation, audioControllerIndex(controllers, selected), audioControllerKey(selected, objects), coreTrack};
        audioTrackHandles().insert(handle.id, handle);
        if (out) *out = handle;
        if (owner) *owner = selected;
        return true;
    };
    const auto chainHandle = [&](int trackIndex, int soundIndex, AudioChainHandle *out, QString *error) {
        AudioTrackHandle track;
        gp::rse::ConductorController *owner = nullptr;
        if (!trackHandle(trackIndex, &track, error, &owner)) return false;
        if (soundIndex < 0 || size_t(soundIndex) >= document.score->tracks()[size_t(trackIndex)]->sounds().size()) { if (error) *error = "Existing sound index required"; return false; }
        auto *musician = track.musician;
        std::shared_ptr<gp::rse::Sound> sound;
        // Retry every matching conductor.  A stale controller may still be
        // registered while the host is rebuilding the active score.
        for (auto *candidate : controllers) {
            const auto conductor = candidate ? candidate->conductor() : nullptr;
            if (!conductor || conductor->score().get() != document.score) continue;
            auto *candidateMusician = conductor->musician(unsigned(trackIndex));
            if (!candidateMusician || !verifiedRseObject(candidateMusician, ".?AVMusician@rse@gp@@")) continue;
            if (candidateMusician->coreTrack().get() != track.track) continue;
            sound = conductor->sound(unsigned(trackIndex), unsigned(soundIndex));
            if (!sound) sound = candidateMusician->soundAtIndex(unsigned(soundIndex));
            if (sound && sound->effectChain()) {
                musician = candidateMusician;
                owner = candidate;
                break;
            }
            sound.reset();
        }
        // The typed return is reached through the hash-verified API.  Some
        // builds expose implementation RTTI names for these two objects, so
        // an exact public alias check would incorrectly discard a valid chain.
        if (!sound || !sound->effectChain()) { if (error) *error = "RSE sound is unavailable for this sound index"; return false; }
        const auto &chain = sound->effectChain();
        if (!chain) { if (error) *error = "RSE effect chain is unavailable"; return false; }
        for (auto it = audioChainHandles().begin(); it != audioChainHandles().end(); ++it) {
            if (it->document == document.id() && it->score == document.score && it->track == track.track && it->sound == sound.get() && it->chain == chain.get() &&
                !it->soundLifetime.expired() && it->soundLifetime.lock().get() == sound.get() &&
                !it->chainLifetime.expired() && it->chainLifetime.lock().get() == chain.get()) {
                it->trackIndex = trackIndex;
                it->soundIndex = soundIndex;
                it->musician = musician;
                it->generation = generation;
                it->controllerIndex = audioControllerIndex(controllers, owner);
                it->controllerKey = audioControllerKey(owner, objects);
                if (out) *out = it.value(); return true;
            }
        }
        AudioChainHandle handle{QUuid::createUuid().toString(QUuid::WithoutBraces), document.id(), document.score, track.track, musician, sound.get(), chain.get(),
            trackIndex, soundIndex, generation, audioControllerIndex(controllers, owner), audioControllerKey(owner, objects), sound, chain};
        audioChainHandles().insert(handle.id, handle); if (out) *out = handle; return true;
    };

    if (operation == "resolve") {
        const QString requestedTrackId = args.value("track_id").toString();
        if (!requestedTrackId.isEmpty()) {
            const auto foundTrack = audioTrackHandles().constFind(requestedTrackId);
            if (foundTrack == audioTrackHandles().end()) return {{"status", "error"}, {"reason", "unknown_or_expired_track_id"}};
            if (foundTrack->document != document.id()) return {{"status", "error"}, {"reason", "foreign_document_track_id"}, {"document", document.id()}};
            AudioTrackHandle current;
            QString error;
            const auto previous = foundTrack.value();
            if (!trackHandle(previous.index, &current, &error) || current.id != previous.id)
                return {{"status", "error"}, {"reason", "stale_track_id"}, {"detail", error}};
            return {{"status", "verified"}, {"document", document.id()}, {"generation", qint64(current.generation)},
                {"track_id", current.id}, {"track_index", current.index}, {"controller_index", current.controllerIndex},
                {"controller_key", current.controllerKey}, {"core_track_bound", true}};
        }
        const QString id = args.value("chain_id").toString();
        const auto found = audioChainHandles().find(id);
        if (found == audioChainHandles().end()) return {{"status", "error"}, {"reason", "unknown_or_expired_chain_id"}};
        AudioChainHandle current;
        QString error;
        const auto previous = found.value();
        if (!chainHandle(previous.trackIndex, previous.soundIndex, &current, &error) || current.id != previous.id)
            return {{"status", "error"}, {"reason", "stale_chain_id"}, {"detail", error}};
        QString trackId;
        for (auto it = audioTrackHandles().cbegin(); it != audioTrackHandles().cend(); ++it)
            if (it->document == current.document && it->score == current.score && it->track == current.track) { trackId = it.key(); break; }
        QJsonObject resolved{{"status", "verified"}, {"document", document.id()}, {"generation", qint64(current.generation)},
            {"chain_id", current.id}, {"track_id", trackId}, {"controller_index", current.controllerIndex},
            {"controller_key", current.controllerKey}};
        resolved["track_index"] = current.trackIndex; resolved["sound_index"] = current.soundIndex;
        resolved["chain_index"] = int(current.chain->index()); resolved["chain_name"] = QString::fromStdString(current.chain->name());
        return resolved;
    }

    if (operation == "buffer_probe") {
        const int frames = args.value("frames").toInt(64);
        if (frames < 1 || frames > 4096) return {{"status", "error"}, {"reason", "frames must be 1..4096"}};
        AudioChainHandle chain;
        QString error;
        const bool haveChain = args.contains("chain_id");
        if (haveChain) {
            const auto found = audioChainHandles().find(args.value("chain_id").toString());
            if (found == audioChainHandles().end()) return {{"status", "error"}, {"reason", "stale_chain_id"}};
            const auto previous = found.value();
            if (!chainHandle(previous.trackIndex, previous.soundIndex, &chain, &error) || chain.id != previous.id)
                return {{"status", "error"}, {"reason", "stale_chain_id"}, {"detail", error}};
        }
        am::audio::AudioBuffer buffer(2);
        const auto module = GetModuleHandleW(L"AMAudio.dll");
        using BufferU = void (__cdecl *)(am::audio::AudioBuffer *, unsigned);
        using BufferDtor = void (__cdecl *)(am::audio::AudioBuffer *);
        using IoVoid = void (__cdecl *)(am::audio::IAudioBuffer *);
        const auto setChannelCount = reinterpret_cast<BufferU>(module ? GetProcAddress(module, "?setChannelCount@AudioBuffer@audio@am@@UEAAXI@Z") : nullptr);
        const auto lock = reinterpret_cast<IoVoid>(module ? GetProcAddress(module, "?lock@IAudioBuffer@audio@am@@UEAAXXZ") : nullptr);
        const auto unlock = reinterpret_cast<IoVoid>(module ? GetProcAddress(module, "?unlock@IAudioBuffer@audio@am@@UEAAXXZ") : nullptr);
        const auto destroy = reinterpret_cast<BufferDtor>(module ? GetProcAddress(module, "??1AudioBuffer@audio@am@@UEAA@XZ") : nullptr);
        if (!setChannelCount || !lock || !unlock || !destroy) return {{"status", "host_limited"}, {"reason", "AMAudio buffer entry points are incomplete"}};
        setChannelCount(&buffer, 2); buffer.setFrameCount(frames);
        auto &audioCore = am::audio::AudioCore::Instance();
        audioCore.allocAudioBufferData(&buffer);
        am::audio::IAudioBuffer &io = reinterpret_cast<am::audio::IAudioBuffer &>(buffer);
        std::vector<float> input(size_t(frames) * 2), roundTrip(input.size());
        for (int i = 0; i < frames; ++i) { input[size_t(i) * 2] = 0.125f + float(i % 17) / 100.0f; input[size_t(i) * 2 + 1] = -0.25f + float(i % 11) / 100.0f; }
        io.fromInterleavedData(input.data(), unsigned(frames));
        lock(&io); unlock(&io);
        bool processInvoked = false;
        QString processSource;
        if (haveChain) {
            std::vector<am::audio::Tick> ticks;
            ticks.push_back(am::audio::Tick{1, 0, frames});
            chain.chain->processDSP(io, ticks);
            processInvoked = true; processSource = "bound_track_chain";
        } else {
            const int trackIndex = args.value("track").toInt(0), soundIndex = args.value("sound").toInt(0);
            if (trackIndex >= 0 && size_t(trackIndex) < document.score->tracks().size()) {
                const auto &sounds = document.score->tracks()[size_t(trackIndex)]->sounds();
                if (soundIndex >= 0 && size_t(soundIndex) < sounds.size() && sounds[size_t(soundIndex)]) {
                    const auto converted = gp::rse::SESoundConverter::convertEffectChain(sounds[size_t(soundIndex)]->rseSound().effectChain());
                    if (converted) {
                        std::vector<am::audio::Tick> ticks;
                        ticks.push_back(am::audio::Tick{1, 0, frames});
                        converted->processDSP(io, ticks); processInvoked = true; processSource = "converted_core_sound_chain";
                    }
                }
            }
        }
        io.toInterleavedData(roundTrip.data(), long long(roundTrip.size()));
        bool finite = true, changed = false;
        for (size_t i = 0; i < roundTrip.size(); ++i) { finite = finite && std::isfinite(roundTrip[i]); changed = changed || std::abs(roundTrip[i] - input[i]) > 1e-7f; }
        audioCore.freeAudioBuffer(&buffer); destroy(&buffer);
        if (!finite) return {{"status", "error"}, {"reason", "nonfinite_audio_buffer_result"}};
        return {{"status", "verified"}, {"document", document.id()}, {"frames", frames}, {"channels", 2},
            {"write_roundtrip", true}, {"lock_roundtrip", true}, {"process_dsp_invoked", processInvoked}, {"process_changed", changed},
            {"process_source", processSource}, {"chain_id", haveChain ? chain.id : QString()}, {"boundary", "AMAudio AudioBuffer -> IAudioBuffer -> GPRSE EffectsChain::processDSP"}};
    }
    if (operation != "state") return {{"status", "error"}, {"reason", "operation must be state, resolve or buffer_probe"}};

    QJsonArray tracks;
    int mappedChains = 0;
    bool chainHostLimited = false;
    const int requestedTrack = args.contains("track") ? args.value("track").toInt(-1) : -1;
    const int first = requestedTrack >= 0 ? requestedTrack : 0;
    const int last = requestedTrack >= 0 ? requestedTrack + 1 : int(document.score->tracks().size());
    if (first < 0 || last > int(document.score->tracks().size()) || last - first > 1024) return {{"status", "error"}, {"reason", "track range exceeds safety bound"}};
    for (int i = first; i < last; ++i) {
        AudioTrackHandle track;
        QString error;
        if (!trackHandle(i, &track, &error)) return {{"status", "host_limited"}, {"reason", error}, {"track", i}};
        QJsonObject row{{"track_id", track.id}, {"track_index", i}, {"generation", qint64(track.generation)},
            {"controller_index", track.controllerIndex}, {"controller_key", track.controllerKey}, {"core_track_bound", true}};
        if (args.contains("sound")) {
            AudioChainHandle chain;
            if (chainHandle(i, args.value("sound").toInt(-1), &chain, &error)) {
                ++mappedChains;
                QJsonObject chainRow{{"chain_id", chain.id}, {"generation", qint64(chain.generation)},
                    {"controller_index", chain.controllerIndex}, {"controller_key", chain.controllerKey}};
                chainRow["sound_index"] = chain.soundIndex; chainRow["chain_index"] = int(chain.chain->index());
                chainRow["name"] = QString::fromStdString(chain.chain->name());
                row["chains"] = QJsonArray{chainRow};
            }
            else { chainHostLimited = true; row["chain_status"] = QJsonObject{{"status", "host_limited"}, {"reason", error}}; }
        } else {
            QJsonArray chains;
            bool trackChainLimited = false;
            QString trackChainError;
            const auto &sounds = document.score->tracks()[size_t(i)]->sounds();
            if (sounds.size() > 256) return {{"status", "host_limited"}, {"reason", "sound count exceeds safety bound"}, {"track", i}};
            for (int s = 0; s < int(sounds.size()); ++s) {
                AudioChainHandle chain;
                if (!chainHandle(i, s, &chain, &error)) {
                    chainHostLimited = true; trackChainLimited = true;
                    if (trackChainError.isEmpty()) trackChainError = error;
                    continue;
                }
                ++mappedChains;
                QJsonObject chainRow{{"chain_id", chain.id}, {"generation", qint64(chain.generation)},
                    {"controller_index", chain.controllerIndex}, {"controller_key", chain.controllerKey}};
                chainRow["sound_index"] = s; chainRow["chain_index"] = int(chain.chain->index());
                chainRow["name"] = QString::fromStdString(chain.chain->name()); chains.append(chainRow);
            }
            row["chains"] = chains;
            if (trackChainLimited) row["chain_status"] = QJsonObject{{"status", "host_limited"}, {"reason", trackChainError}};
        }
        tracks.append(row);
    }
    const bool chainVerified = mappedChains > 0 && !chainHostLimited;
    const char *overallStatus = chainVerified ? "verified" : (tracks.isEmpty() ? "host_limited" : "experimental");
    return {{"status", overallStatus}, {"document", document.id()}, {"generation", qint64(generation)},
        {"controller_count", int(controllers.size())}, {"rse_abi_verified", true}, {"audio_abi_verified", audioVerified},
        {"track_binding_status", "verified"}, {"chain_mapping_status", chainVerified ? "verified" : "host_limited"},
        {"handle_policy", "opaque_process_local_revalidated"}, {"tracks", tracks},
        {"buffer_boundary", QJsonObject{{"status", "experimental"}, {"probe", "buffer_probe"}, {"abi", "AMAudio 8.1.1.17 AudioBuffer/IAudioBuffer"}}}};
}

// Both MCP and native consumers use audioAbi's verified binding registry.
// This snapshot never calls updateAll or DSP and never retains consumer pointers.
inline uint32_t enumerateAudioBindingsV1(const QList<QPointer<QObject>> &objects,
                                         uint32_t requestedAbi,
                                         gpmcp_audio_binding_visitor visitor, void *user,
                                         gpmcp_audio_enumerate_result *result) noexcept {
    if (!result || result->struct_size < sizeof(*result)) return GPMCP_AUDIO_ABI_MISMATCH;
    result->status = GPMCP_AUDIO_INTERNAL_ERROR;
    result->generation = 0;
    result->count = 0;
    if (requestedAbi != GPMCP_AUDIO_BRIDGE_ABI_VERSION) { result->status = GPMCP_AUDIO_ABI_MISMATCH; return result->status; }
    if (!visitor) { result->status = GPMCP_AUDIO_INVALID_ARGUMENT; return result->status; }
    if (!qApp) { result->status = GPMCP_AUDIO_NOT_READY; return result->status; }
    if (QThread::currentThread() != qApp->thread()) { result->status = GPMCP_AUDIO_WRONG_THREAD; return result->status; }
    try {
        if (!supportedBuild() || !verifiedHostFile("GPRSE.dll")) { result->status = GPMCP_AUDIO_HOST_LIMITED; return result->status; }
        result->generation = currentAudioGeneration();
        const auto available = documents();
        if (available.isEmpty()) { result->status = GPMCP_AUDIO_NOT_READY; return result->status; }
        QObject *active = activeDocument(objects);
        bool limited = false;
        for (const auto &document : available) {
            if (!document.score || !document.object) { limited = true; continue; }
            const auto state = audioAbi({{"document", document.id()}, {"operation", "state"}}, objects);
            const auto rows = state.value("tracks").toArray();
            if (state.value("chain_mapping_status").toString() == "host_limited") limited = true;
            if (rows.isEmpty() && !document.score->tracks().empty()) limited = true;
            QString scoreKey = localDocumentPath(document.object->property("saveFilePath").toString());
            if (scoreKey.isEmpty()) scoreKey = localDocumentPath(document.object->property("openedFilePath").toString());
            if (!scoreKey.isEmpty()) scoreKey = QFileInfo(scoreKey).absoluteFilePath();
            else scoreKey = document.id();
            const auto documentBytes = document.id().toUtf8();
            const auto scoreBytes = scoreKey.toUtf8();
            for (const auto &value : rows) {
                const auto row = value.toObject();
                const auto trackBytes = row.value("track_id").toString().toUtf8();
                gpmcp_audio_binding binding{};
                binding.struct_size = sizeof(binding);
                binding.abi_version = GPMCP_AUDIO_BRIDGE_ABI_VERSION;
                binding.generation = quint64(row.value("generation").toDouble());
                binding.controller_index = uint32_t(row.value("controller_index").toInt());
                binding.track_index = row.value("track_index").toInt(-1);
                binding.sound_index = -1;
                binding.active_document = active ? uint8_t(active == document.object.data()) : 2;
                binding.selected_track = binding.active_document == 2 ? 2 : uint8_t(
                    binding.active_document && document.score->cursor().trackIndex() == binding.track_index);
                binding.document_id = documentBytes.constData();
                binding.track_id = trackBytes.constData();
                binding.score_key = scoreBytes.constData();
                const auto chains = row.value("chains").toArray();
                if (chains.isEmpty()) {
                    binding.status = GPMCP_AUDIO_HOST_LIMITED;
                    visitor(user, &binding);
                    ++result->count;
                    limited = true;
                }
                for (const auto &chainValue : chains) {
                    const auto chainRow = chainValue.toObject();
                    const auto handle = audioChainHandles().value(chainRow.value("chain_id").toString());
                    if (!handle.chain || handle.chainLifetime.expired() || handle.soundLifetime.expired()) { limited = true; continue; }
                    binding.status = GPMCP_AUDIO_OK;
                    binding.chain = handle.chain;
                    binding.generation = handle.generation;
                    binding.controller_index = uint32_t(handle.controllerIndex);
                    binding.sound_index = handle.soundIndex;
                    visitor(user, &binding);
                    ++result->count;
                }
            }
        }
        result->generation = audioEpoch();
        result->status = limited ? GPMCP_AUDIO_HOST_LIMITED : GPMCP_AUDIO_OK;
    } catch (...) { result->status = GPMCP_AUDIO_INTERNAL_ERROR; }
    return result->status;
}
inline QJsonObject audioDevice(const QJsonObject &args, const QList<QPointer<QObject>> &objects) {
    static const bool verified = supportedBuild() && verifiedHostFile("AMAudio.dll");
    if (!verified) return {{"error", "Audio device ABI disabled on an unverified build"}};
    QPointer<QObject> model;
    for (const auto &object : objects)
        if (object && QByteArray(object->metaObject()->className()) == "gp::base::AudioConfigurationWidgetModel") {
            if (model) return {{"error", "Ambiguous native audio configuration"}};
            model = object;
        }
    if (!model) return {{"error", "Native audio configuration unavailable"}};
    auto &layer = am::audio::AudioLayer::instance();
    const auto deviceChoices = [&]() {
        QJsonArray outputs, inputs, buffers, backends{"Standard"};
        for (const auto &device : layer.outputDevices()) outputs.append(device.name);
        for (const auto &device : layer.inputDevices()) inputs.append(device.name);
        for (int buffer : layer.buffersSize()) buffers.append(buffer);
        if (layer.hasAsio()) backends.append("ASIO");
        QJsonObject choices{{"audioDevice", backends}, {"audioOutput", outputs}, {"audioInput", inputs}, {"audioBuffersSize", buffers}};
        const int channelsIndex = model->metaObject()->indexOfProperty("audioOutputChannels");
        if (channelsIndex >= 0) {
            const auto property = model->metaObject()->property(channelsIndex);
            const auto current = property.read(model);
            if (property.isEnumType()) {
                QJsonArray values;
                const auto enumeration = property.enumerator();
                for (int i = 0; i < enumeration.keyCount(); ++i) values.append(enumeration.value(i));
                choices["audioOutputChannels"] = values;
            } else if (current.type() == QVariant::StringList) choices["audioOutputChannels"] = QJsonArray::fromStringList(current.toStringList());
            else if (current.type() == QVariant::List) choices["audioOutputChannels"] = QJsonValue::fromVariant(current);
            else if (current.isValid()) choices["audioOutputChannels"] = QJsonArray{QJsonValue::fromVariant(current)};
        }
        return choices;
    };
    const auto operation = args.value("operation").toString("state");
    QString error;
    if (operation == "set") {
        for (const auto &document : documents()) {
            const auto controller = audioController(document, objects);
            if (controller && (controller->isPlaying() || controller->isCountingDown())) return {{"error", "Stop playback before changing application audio devices"}};
        }
        const auto name = args.value("property").toString();
        const auto value = args.value("value");
        const auto choices = deviceChoices();
        if (!choices.contains(name) || !choices.value(name).toArray().contains(value)) return {{"error", "Choose a property and an exact value from the returned choices"}};
        const int propertyIndex = model->metaObject()->indexOfProperty(name.toLatin1().constData());
        if (propertyIndex < 0) return {{"error", "Native audio property is unavailable"}};
        const auto property = model->metaObject()->property(propertyIndex);
        if (!property.isReadable() || !property.isWritable()) return {{"error", "Native audio property is read-only"}};
        const auto before = property.read(model);
        QVariant input = value.toVariant();
        if (property.isEnumType()) {
            if (!value.isDouble() || std::floor(value.toDouble()) != value.toDouble()) return {{"error", "Enum audio properties require an integer choice"}};
            input = QVariant(value.toInt());
            if (!input.convert(property.userType())) return {{"error", "Audio property value has the wrong enum type"}};
        } else if (!input.convert(property.userType())) {
            return {{"error", "Audio property value has the wrong type"}};
        }
        if (before != input && (!property.write(model, input) || property.read(model) != input || !layer.isRunning())) {
            const bool restored = property.write(model, before) && property.read(model) == before;
            error = restored ? "Native device change failed; previous setting restored" : "Native device change failed; inspect configuration before retrying";
        }
    } else if (operation != "state") return {{"error", "operation must be state or set"}};
    QJsonObject state, propertyTypes;
    for (const char *name : {"audioDevice", "audioInput", "audioOutput", "audioOutputChannels", "audioBuffersSize"}) {
        const int index = model->metaObject()->indexOfProperty(name);
        if (index < 0) continue;
        const auto property = model->metaObject()->property(index);
        if (!property.isReadable()) continue;
        state[name] = QJsonValue::fromVariant(property.read(model));
        propertyTypes[name] = property.typeName();
    }
    QJsonObject result{{"scope", "application"}, {"configuration", state}, {"running", layer.isRunning()}, {"undoable", false},
        {"property_types", propertyTypes}, {"choices", deviceChoices()}};
    if (!error.isEmpty()) result["error"] = error;
    return result;
}

// Development-only PCM verification, bounded to short fixture scores.
inline QJsonObject audioProbe(const QJsonObject &args, const QList<QPointer<QObject>> &objects) {
    const auto document = choose(args);
    const auto controller = audioController(document, objects);
    if (!controller || controller->isPlaying() || controller->isCountingDown()) return {{"error", "Activate a stopped document first"}};
    if (controller->conductor()->frameCount() > 30 * 44100) return {{"error", "Audio probe is limited to 30-second fixtures"}};
    gp::rse::AudioExportManager renderer(controller->conductor()->score());
    renderer.setExportMetronome(false); renderer.setExportCountdown(false); renderer.setExportSelection(false);
    renderer.prepareConductorForEncoding({});
    const auto expected = renderer.soundingLengthInFrames();
    if (expected <= 0 || expected > 30 * 44100) return {{"error", "Native render length is outside the 30-second probe bound"}};
    QCryptographicHash digest(QCryptographicHash::Sha256);
    std::vector<float> left, right;
    long long frames = 0; double energy[2]{}, peak = 0;
    while (frames <= 30 * 44100) {
        const auto count = renderer.processFrame(left, right);
        if (!count) break;
        if (count > left.size() || count > right.size()) return {{"error", "Native audio buffer length differs"}};
        for (unsigned i = 0; i < count; ++i) {
            if (!std::isfinite(left[i]) || !std::isfinite(right[i])) return {{"error", "Native audio contains a nonfinite sample"}};
            energy[0] += double(left[i]) * left[i]; energy[1] += double(right[i]) * right[i];
            peak = qMax(peak, double(qMax(std::abs(left[i]), std::abs(right[i]))));
        }
        digest.addData(reinterpret_cast<const char *>(left.data()), int(count * sizeof(float)));
        digest.addData(reinterpret_cast<const char *>(right.data()), int(count * sizeof(float)));
        frames += count;
    }
    return {{"document", document.id()}, {"frames", double(frames)}, {"expected_frames", double(expected)},
        {"left_rms", frames ? std::sqrt(energy[0] / frames) : 0}, {"right_rms", frames ? std::sqrt(energy[1] / frames) : 0},
        {"peak", peak}, {"pcm_sha256", QString::fromLatin1(digest.result().toHex())}, {"source", "Native AudioExportManager stereo float PCM"}};
}
inline QJsonArray tempoPoints(const std::vector<std::shared_ptr<gp::core::Automation>> &points) {
    QJsonArray result;
    for (const auto &point : points) {
        if (!point || discovery::type(reinterpret_cast<quintptr>(point.get())) != ".?AVTempoAutomation@core@gp@@")
            throw std::runtime_error("Unexpected native tempo automation type");
        const auto tempo = static_cast<const gp::core::TempoAutomation *>(point.get());
        result.append(QJsonObject{{"bar", int(point->gp::core::Automation::barIndex())}, {"position", point->position()},
            {"value", point->value()}, {"linear", point->isLinear()}, {"label", QString::fromStdString(point->text())},
            {"unit", QString::fromStdString(gp::core::tempoUnitToString(tempo->unit()))}});
    }
    return result;
}
inline QJsonObject tempoAutomation(const QJsonObject &args, const Document &bound = {}) {
    const auto document = bound.score ? bound : choose(args);
    if (!document.score || !document.score->masterTrack()) return {{"error", "Native master track required"}};
    const auto master = document.score->masterTrack();
    const auto type = static_cast<gp::core::Automation::Type>(0x200);
    std::vector<std::shared_ptr<gp::core::Automation>> points;
    master->gp::core::AutomationContainerProxy::getAutomations(type, points);
    if (points.empty() || points.size() > 4096) return {{"error", "Expected 1..4096 native tempo points"}};
    const auto before = tempoPoints(points);
    const auto operation = args.value("operation").toString("state");
    if (operation != "state") {
        if (operation != "set" && operation != "remove") return {{"error", "operation must be state, set or remove"}};
        const int bar = args.value("bar").toInt(-1);
        const double position = args.value("position").toDouble(0);
        if (bar < 0 || unsigned(bar) >= master->masterBarCount() ||
            (args.contains("position") && !args.value("position").isDouble()) || !std::isfinite(position) || position < 0 || float(position) >= 1)
            return {{"error", "bar must exist; position must be a fraction in [0,1) of that score bar"}};
        const auto found = std::find_if(points.begin(), points.end(), [&](const auto &p) {
            return p->gp::core::Automation::barIndex() == unsigned(bar) && p->position() == float(position);
        });
        if (operation == "remove") {
            if (bar == 0 && float(position) == 0) return {{"error", "The initial tempo point cannot be removed"}};
            if (found != points.end()) points.erase(found);
        } else {
            const double value = args.value("value").toDouble(-1);
            if (!args.value("value").isDouble() || !std::isfinite(value) || value < 1 || value > 400 || std::floor(value) != value)
                return {{"error", "value must be an integer in 1..400"}};
            if (args.contains("linear") && !args.value("linear").isBool()) return {{"error", "linear must be a boolean"}};
            auto original = found == points.end() ? points.front() : *found;
            const auto source = static_cast<gp::core::TempoAutomation *>(original.get());
            auto unit = source->unit();
            if (args.contains("unit")) {
                unit = static_cast<gp::core::TempoUnit>(0);
                for (int i = 1; i <= 5; ++i)
                    if (QString::fromStdString(gp::core::tempoUnitToString(static_cast<gp::core::TempoUnit>(i))) == args.value("unit").toString())
                        unit = static_cast<gp::core::TempoUnit>(i);
            }
            if (int(unit) < 1 || int(unit) > 5) return {{"error", "Choose a unit from gp_score.tempo.units"}};
            const auto label = args.value("label").toString(found == points.end() ? QString() : QString::fromStdString(original->text()));
            if (!validHostText(label)) return {{"error", "Invalid tempo label"}};
            auto replacement = source->gp::core::TempoAutomation::cloneAutomation();
            replacement->gp::core::Automation::setBarIndex(unsigned(bar));
            replacement->setPosition(float(position)); replacement->setValue(float(value));
            replacement->setLinear(args.value("linear").toBool(found != points.end() && original->isLinear()));
            replacement->setText(label.toStdString());
            static_cast<gp::core::TempoAutomation *>(replacement.get())->setUnit(unit);
            if (found == points.end()) {
                if (points.size() == 4096) return {{"error", "At most 4096 tempo points are supported"}};
                points.push_back(replacement);
            } else *found = replacement;
        }
        std::sort(points.begin(), points.end(), [](const auto &a, const auto &b) {
            return std::make_pair(a->gp::core::Automation::barIndex(), a->position()) < std::make_pair(b->gp::core::Automation::barIndex(), b->position());
        });
        if (tempoPoints(points) != before) document.score->modifyMasterTrackAutomations(points, {});
        points.clear();
        master->gp::core::AutomationContainerProxy::getAutomations(type, points);
    }
    return {{"document", document.id()}, {"points", tempoPoints(points)}, {"undoable", true},
        {"dirty", document.object->property("isDirty").toBool()}};
}

inline QJsonObject soundState(const gp::core::Sound &sound) {
    QJsonArray effects;
    const auto &chain = sound.rseSound().effectChain().effects();
    if (chain.size() > 64) throw std::runtime_error("Native effect chain exceeds 64 effects");
    for (const auto &effect : chain) {
        if (!effect || effect->parameters().size() > 256) throw std::runtime_error("Invalid native effect");
        QJsonArray parameters;
        for (float value : effect->parameters()) parameters.append(value);
        effects.append(QJsonObject{{"id", QString::fromStdString(effect->id())}, {"bypass", effect->isBypass()}, {"parameters", parameters}});
    }
    return {{"name", QString::fromStdString(sound.name())}, {"label", QString::fromStdString(sound.label())},
        {"midi_program", int(sound.midiSound().program())}, {"midi_msb", int(sound.midiSound().msbBank())},
        {"midi_lsb", int(sound.midiSound().lsbBank())}, {"effects", effects}};
}
inline QJsonObject audioTrack(const QJsonObject &args) {
    const auto document = choose(args);
    const int index = args.value("track").toInt(-1);
    if (!document.score || index < 0 || size_t(index) >= document.score->tracks().size()) return {{"error", "Existing track index required"}};
    const auto track = document.score->tracks()[size_t(index)];
    const auto &sounds = track->sounds();
    if (sounds.size() > 256) return {{"error", "At most 256 sounds per track are supported"}};
    const auto operation = args.value("operation").toString("state");
    if (operation == "select") {
        const int sound = args.value("sound").toInt(-2);
        if (sound < -1 || sound >= int(sounds.size())) return {{"error", "sound must be -1 (score automations) or an existing sound index"}};
        if (track->forcedSoundIndex() != sound) document.score->setForcedSoundIndex(*track, sound);
    } else if (operation != "state") {
        const int sound = args.value("sound").toInt(0);
        if (sound < 0 || size_t(sound) >= sounds.size() || !sounds[size_t(sound)]) return {{"error", "Existing sound index required"}};
        gp::core::Sound copy(*sounds[size_t(sound)]);
        if (operation == "copy") {
            if (args.value("source_document").toString().isEmpty()) return {{"error", "source_document is required"}};
            const auto source = choose(QJsonObject{{"document", args.value("source_document")}});
            const int sourceTrack = args.value("source_track").toInt(-1), sourceSound = args.value("source_sound").toInt(0);
            if (!source.score || sourceTrack < 0 || size_t(sourceTrack) >= source.score->tracks().size()) return {{"error", "Existing source document and track required"}};
            const auto from = source.score->tracks()[size_t(sourceTrack)];
            if (gp::core::InstrumentSet::isUnpitched(from->type()) != gp::core::InstrumentSet::isUnpitched(track->type()))
                return {{"error", "Cannot mix pitched and percussion sounds"}};
            if (sourceSound < 0 || size_t(sourceSound) >= from->sounds().size() || !from->sounds()[size_t(sourceSound)]) return {{"error", "Existing source sound required"}};
            document.score->setTrackSound(*track, unsigned(sound), *from->sounds()[size_t(sourceSound)], false);
        } else {
            if (operation == "midi_program") {
                const int program = args.value("value").toInt(-1);
                if (program < 0 || program > 127) return {{"error", "MIDI program must be 0..127"}};
                copy.mutableMidiSound().setProgram(unsigned(program));
            } else {
                auto &chain = copy.mutableRseSound().mutableEffectChain();
                const int effectIndex = args.value("effect").toInt(-1);
                if (effectIndex < 0 || size_t(effectIndex) >= chain.effects().size()) return {{"error", "Existing effect index required"}};
                auto effect = chain.effect(unsigned(effectIndex));
                if (operation == "effect_bypass") {
                    if (!args.value("enabled").isBool()) return {{"error", "enabled boolean required"}};
                    effect->setBypass(args.value("enabled").toBool());
                } else if (operation == "effect_parameter") {
                    const int parameter = args.value("parameter").toInt(-1);
                    const double value = args.value("value").toDouble(-1);
                    if (parameter < 0 || size_t(parameter) >= effect->parameters().size() || !args.value("value").isDouble() || !std::isfinite(value) || value < 0 || value > 1)
                        return {{"error", "Existing parameter and normalized value in 0..1 required"}};
                    effect->setParameter(unsigned(parameter), float(value));
                } else if (operation == "effect_remove") chain.removeEffect(unsigned(effectIndex));
                else if (operation == "effect_swap") {
                    const int other = args.value("other").toInt(-1);
                    if (other < 0 || size_t(other) >= chain.effects().size()) return {{"error", "Existing other effect index required"}};
                    chain.swapEffects(unsigned(effectIndex), unsigned(other));
                } else return {{"error", "Unknown audio track operation"}};
            }
            if (soundState(copy) != soundState(*sounds[size_t(sound)])) document.score->setTrackSound(*track, unsigned(sound), copy, false);
        }
    }
    QJsonArray result;
    for (const auto &sound : sounds) {
        if (!sound) return {{"error", "Missing native sound"}};
        result.append(soundState(*sound));
    }
    return {{"document", document.id()}, {"track", index}, {"sounds", result}, {"forced_sound", track->forcedSoundIndex()},
        {"dirty", document.object->property("isDirty").toBool()}, {"undoable", operation != "select"}};
}
}
