#pragma once
#include "guitarpro_api.h"

namespace guitarpro {
inline gp::rse::ConductorController *audioController(const Document &document, const QList<QPointer<QObject>> &objects) {
    static const bool verified = verifiedHostFile("GPRSE.dll");
    if (!verified || !document.score) return nullptr;
    for (const auto &object : objects) {
        if (!object || QByteArray(object->metaObject()->className()) != "gp::rse::ConductorController") continue;
        auto controller = reinterpret_cast<gp::rse::ConductorController *>(object.data());
        if (controller->conductor() && controller->conductor()->score().get() == document.score) return controller;
    }
    return nullptr;
}
inline void refreshTempo(const QJsonObject &args, const QList<QPointer<QObject>> &objects) {
    const auto controller = audioController(choose(args), objects);
    if (controller) controller->conductor()->updateTempoManagerAsync({});
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
        return QJsonObject{{"audioDevice", backends}, {"audioOutput", outputs}, {"audioInput", inputs}, {"audioBuffersSize", buffers}};
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
        const auto property = model->metaObject()->property(model->metaObject()->indexOfProperty(name.toLatin1().constData()));
        if (!property.isWritable()) return {{"error", "Native audio property is read-only"}};
        const auto before = property.read(model);
        if (before != value.toVariant() && (!property.write(model, value.toVariant()) || property.read(model) != value.toVariant() || !layer.isRunning())) {
            const bool restored = property.write(model, before) && property.read(model) == before;
            error = restored ? "Native device change failed; previous setting restored" : "Native device change failed; inspect configuration before retrying";
        }
    } else if (operation != "state") return {{"error", "operation must be state or set"}};
    QJsonObject state;
    for (const char *name : {"audioDevice", "audioInput", "audioOutput", "audioOutputChannels", "audioBuffersSize"}) {
        const auto property = model->metaObject()->property(model->metaObject()->indexOfProperty(name));
        state[name] = QJsonValue::fromVariant(property.read(model));
    }
    QJsonObject result{{"scope", "application"}, {"configuration", state}, {"running", layer.isRunning()}, {"undoable", false},
        {"choices", deviceChoices()}};
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
inline QJsonObject tempoAutomation(const QJsonObject &args) {
    const auto document = choose(args);
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
