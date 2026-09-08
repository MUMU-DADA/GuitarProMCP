#pragma once
#include "guitarpro_page.h"
#include <QtCore/QJsonDocument>
#include <QtCore/QRegularExpression>
#include <QtCore/QTextStream>

namespace guitarpro {
inline void semanticRequire(bool condition, const QString &message) {
    if (!condition) throw std::runtime_error(message.toUtf8().constData());
}
inline bool semanticInteger(const QJsonValue &v, int *out, int low, int high) {
    if (!v.isDouble() || !std::isfinite(v.toDouble()) || v.toDouble() < low || v.toDouble() > high || v.toDouble() != std::floor(v.toDouble())) return false;
    if (out) *out = v.toInt();
    return true;
}
inline int semanticInt(const QJsonValue &v, int low, int high, const QString &field) {
    int result = 0;
    semanticRequire(semanticInteger(v, &result, low, high), field + " must be an integer in " + QString::number(low) + ".." + QString::number(high));
    return result;
}
inline QString semanticText(const QJsonValue &v, int maximum = 4096) {
    semanticRequire(v.isString() && v.toString().size() <= maximum && validHostText(v.toString()), "Invalid or excessive native text");
    return v.toString();
}
inline void semanticKeys(const QJsonObject &object, const QSet<QString> &keys) {
    for (auto i = object.begin(); i != object.end(); ++i) semanticRequire(keys.contains(i.key()), "Unsupported field: " + i.key());
}
inline void semanticResult(const QJsonObject &result) { semanticRequire(!result.contains("error"), result.value("error").toString()); }
inline QJsonValue semanticDefault(const QJsonObject &o, const char *key, const QJsonValue &fallback) { return o.contains(key) ? o.value(key) : fallback; }
inline QJsonObject semanticPosition(int track, int staff, int bar, int voice, int beat) {
    return {{"track", track}, {"staff", staff}, {"bar", bar}, {"voice", voice}, {"beat", beat}};
}
inline std::shared_ptr<gp::core::Staff> semanticStaff(gp::core::Score *score, int track, int staff) {
    semanticRequire(score && track >= 0 && size_t(track) < score->tracks().size(), "Track does not exist");
    const auto &staves = score->tracks()[size_t(track)]->staves();
    semanticRequire(staff >= 0 && size_t(staff) < staves.size() && bool(staves[size_t(staff)]), "Staff does not exist");
    return staves[size_t(staff)];
}
inline void semanticMove(gp::core::Score *score, int track, int staff, int bar, int voice, int beat) {
    auto &cursor = score->cursor();
    semanticRequire(cursor.trySetTrackIndex(track) && cursor.trySetStaffIndex(unsigned(staff)), "Native track/staff position unavailable");
    cursor.setVoiceIndex(unsigned(voice));
    semanticRequire(cursor.trySetBarIndex(bar) && cursor.trySetBeatIndex(beat), "Native bar/beat position unavailable");
    cursor.endMultiSelection(); cursor.setMultiVoice(false);
}
inline std::shared_ptr<gp::core::Score> semanticCopy(gp::core::Score *score) {
    auto result = std::make_shared<gp::core::Score>(); result->copyFrom(score->shared_from_this(), nullptr); return result;
}
inline void semanticMatch(const QJsonValue &, const QJsonValue &, const QString &);
}
#include "guitarpro_chords.h"
namespace guitarpro {
inline QJsonArray semanticLyrics(const gp::core::Beat &beat) {
    QJsonArray lyrics;
    for (int line = 0; line < 5; ++line) {
        const auto &text = beat.lyrics()[size_t(line)].text();
        if (!text.empty()) lyrics.append(QJsonObject{{"line", line}, {"text", QString::fromStdString(text)}});
    }
    return lyrics;
}
inline QJsonObject semanticBeat(const gp::core::Beat &beat, const gp::core::Staff &staff, bool stringed = true) {
    QJsonArray notes;
    for (const auto &note : beat.notes()) {
        semanticRequire(bool(note), "Missing native note"); auto value = noteState(*note);
        if (!stringed) { value.remove("string"); value.remove("fret"); }
        notes.append(value);
    }
    const int value = int(beat.rhythm().getNoteValue());
    semanticRequire(value >= 2 && value <= 9, "JSON v1 cannot represent this native note value");
    const auto chord = semanticChord(staff, beat.chord());
    return {{"denominator", 1 << (value - 2)}, {"dots", int(beat.rhythm().getAugmentationDot())}, {"tuplets", tupletState(beat.rhythm())},
        {"rest", beat.isRest()}, {"notes", notes}, {"effects", beatEffects(beat)}, {"text", QString::fromStdString(beat.freeText())},
        {"lyrics", semanticLyrics(beat)}, {"chord", chord.isEmpty() ? QJsonValue() : QJsonValue(chord)},
        {"legato", QJsonObject{{"origin", beat.isLegatoOrigin()}, {"destination", beat.isLegatoDestination()}}}};
}
inline QJsonArray semanticSections(gp::core::Score *score) {
    QJsonArray result;
    const int count = int(score->masterTrack()->masterBarCount());
    for (int b = 0; b < count; ++b) {
        const auto bar = masterBar(score, unsigned(b));
        if (!bar->hasSection()) continue;
        if (!result.isEmpty()) { auto previous = result.last().toObject(); previous["end_bar"] = b - 1; result[result.size() - 1] = previous; }
        const auto &section = bar->section();
        result.append(QJsonObject{{"name", QString::fromStdString(section.name)}, {"text", QString::fromStdString(section.text)}, {"start_bar", b}, {"end_bar", count - 1}});
    }
    return result;
}
inline QJsonArray semanticMasterBars(gp::core::Score *score) {
    const int count = int(score->masterTrack()->masterBarCount());
    semanticRequire(count >= 1 && count <= 256, "P8 supports 1..256 master bars per request");
    QJsonArray bars;
    for (int i = 0; i < count; ++i) {
        auto value = masterBarState(score, unsigned(i)); semanticResult(value); value.remove("index");
        const auto bar = masterBar(score, unsigned(i));
        value["section"] = bar->hasSection() ? QJsonValue(QJsonObject{{"name", QString::fromStdString(bar->section().name)}, {"text", QString::fromStdString(bar->section().text)}}) : QJsonValue();
        bars.append(value);
    }
    return bars;
}
inline QJsonObject semanticScore(gp::core::Score *score) {
    semanticRequire(score && score->trackCount() >= 1 && score->trackCount() <= 32, "P8 supports 1..32 tracks");
    const auto masters = semanticMasterBars(score);
    QJsonArray tracks; int inspected = 0;
    for (int t = 0; t < int(score->trackCount()); ++t) {
        const auto track = score->tracks()[size_t(t)]; const auto base = trackBase(score, unsigned(t));
        semanticRequire(bool(base), "Invalid native track"); QJsonArray staves;
        for (const auto &staff : track->staves()) {
            QJsonArray bars, tuning, partial;
            for (int midi : staff->tuning().midiNumbers()) tuning.append(midi);
            for (bool flag : staff->partialCapoStringFlags()) partial.append(flag);
            for (const auto &bar : staff->bars()) {
                QJsonArray voices;
                for (const auto &voice : static_cast<const gp::core::Bar &>(*bar).voices()) {
                    QJsonArray beats;
                    if (voice) for (const auto &beat : voice->beats()) {
                        semanticRequire(++inspected <= 20000 && bool(beat), "P8 supports at most 20000 beats in total");
                        if (!beat->isPlaceholder()) beats.append(semanticBeat(*beat, *staff, gp::core::InstrumentSet::isStringed(track->type())));
                    }
                    voices.append(QJsonObject{{"beats", beats}});
                }
                bars.append(QJsonObject{{"voices", voices}});
            }
            QJsonObject value{{"bars", bars}};
            if (gp::core::InstrumentSet::isStringed(track->type())) {
                value["tuning"] = tuning; value["capo"] = staff->capoFret(); value["partial_capo"] = staff->partialCapoFret(); value["partial_capo_strings"] = partial;
            }
            staves.append(value);
        }
        tracks.append(QJsonObject{{"name", QString::fromStdString(base->name())}, {"short_name", QString::fromStdString(base->shortName())},
            {"instrument_type", QString::fromStdString(gp::core::InstrumentSet::typeToString(track->type()))}, {"transposition", track->transpositionOffset()}, {"staves", staves}});
    }
    std::vector<std::shared_ptr<gp::core::Automation>> points;
    score->masterTrack()->gp::core::AutomationContainerProxy::getAutomations(static_cast<gp::core::Automation::Type>(0x200), points);
    auto page = pageMetadata(score);
    for (const char *key : {"title", "author", "composer", "copyright"}) page.remove(key); // Already in metadata.
    return {{"schema", "guitarpromcp.p8"}, {"version", 1}, {"metadata", metadata(score)}, {"page_metadata", page}, {"master_bars", masters}, {"tempo_points", tempoPoints(points)}, {"tracks", tracks}};
}
inline QJsonObject exportJson(const QJsonObject &args) {
    const auto document = choose(args); semanticRequire(document.score, "Native document required");
    return {{"document", document.id()}, {"spec", semanticScore(document.score)}, {"index_base", 0}};
}
inline QJsonObject structure(const QJsonObject &args) {
    const auto document = choose(args); semanticRequire(document.score, "Native document required"); QJsonArray tracks;
    for (int i = 0; i < int(document.score->trackCount()); ++i) {
        const auto base = trackBase(document.score, unsigned(i));
        tracks.append(QJsonObject{{"index", i}, {"name", QString::fromStdString(base->name())}, {"staves", int(document.score->tracks()[size_t(i)]->staves().size())}});
    }
    return {{"document", document.id()}, {"metadata", metadata(document.score)}, {"bar_count", int(document.score->masterTrack()->masterBarCount())},
        {"tracks", tracks}, {"bars", semanticMasterBars(document.score)}, {"sections", semanticSections(document.score)}, {"tempo_points", tempoAutomation({}, document).value("points")}};
}
inline QJsonObject readSections(const QJsonObject &args) {
    const auto document = choose(args); semanticRequire(document.score, "Native document required");
    return {{"document", document.id()}, {"sections", semanticSections(document.score)}};
}
inline QJsonObject readSemanticBeats(const QJsonObject &args, bool chords) {
    const auto document = choose(args); semanticRequire(document.score, "Native document required");
    const int track = semanticInt(semanticDefault(args, "track", 0), 0, 1023, "track"), staff = semanticInt(semanticDefault(args, "staff", 0), 0, 15, "staff");
    const auto st = semanticStaff(document.score, track, staff);
    const int from = semanticInt(semanticDefault(args, "bar", 0), 0, int(st->bars().size()) - 1, "bar");
    const int count = semanticInt(semanticDefault(args, "count", qMin(128, int(st->bars().size()) - from)), 1, qMin(128, int(st->bars().size()) - from), "count");
    const int onlyVoice = args.contains("voice") ? semanticInt(args.value("voice"), 0, 3, "voice") : -1;
    QJsonArray output; int inspected = 0;
    for (int b = from; b < from + count; ++b) {
        const auto &voices = static_cast<const gp::core::Bar &>(*st->bars()[size_t(b)]).voices();
        for (int v = 0; v < int(voices.size()); ++v) if (voices[size_t(v)] && (onlyVoice < 0 || onlyVoice == v)) {
            const auto &beats = voices[size_t(v)]->beats();
            for (int k = 0; k < int(beats.size()); ++k) {
                semanticRequire(++inspected <= 20000, "Read exceeds 20000 beats");
                const auto position = semanticPosition(track, staff, b, v, k);
                if (chords) { auto value = semanticChord(*st, beats[size_t(k)]->chord()); if (!value.isEmpty()) { value["position"] = position; output.append(value); } }
                else for (const auto lyric : semanticLyrics(*beats[size_t(k)])) { auto value = lyric.toObject(); value["position"] = position; output.append(value); }
            }
        }
    }
    QJsonObject result{{"document", document.id()}, {chords ? "chords" : "lyrics", output}};
    if (chords) {
        QJsonArray types;
        // Chord::type (0xDA5D1) searches IDs 28 down to 0.
        for (int i = 0; i <= 28; ++i) types.append(QJsonObject{{"id", i}, {"name", gp::core::chord::Chord::chordTypeToString(static_cast<gp::core::chord::Chord::Type>(i))}});
        result["types"] = types;
    }
    return result;
}
inline QJsonObject readChords(const QJsonObject &args) { return readSemanticBeats(args, true); }
inline QJsonObject readLyrics(const QJsonObject &args) { return readSemanticBeats(args, false); }

inline QJsonObject semanticCommit(const Document &document, const std::shared_ptr<gp::core::Score> &staged, std::function<QJsonObject()> &recovery, const QString &fault = {}) {
    const auto expected = semanticScore(staged.get());
    const auto before = semanticScore(document.score);
    if (before == expected) return {{"document", document.id()}, {"status", "unchanged"}};
    // Recovery only observes. It never replays the replacement or guesses undo.
    recovery = [document, before, expected]() -> QJsonObject {
        if (!document.object || !document.view) return {{"resolution", "document_closed"}};
        const auto actual = semanticScore(document.score);
        if (actual == expected) return {{"resolution", "applied"}, {"document", document.id()}};
        if (actual == before) return {{"resolution", "not_applied"}, {"document", document.id()}};
        return {{"error", "Native score matches neither the previous nor expected semantic state; editing remains blocked"}, {"outcome_unknown", true}};
    };
    try {
        if (fault == "before_commit") throw std::runtime_error("Development exception before native replacement");
        document.score->replaceScore(staged, 0);
        if (fault == "after_commit") throw std::runtime_error("Development exception after native replacement");
        semanticRequire(semanticScore(document.score) == expected, "Native replacement readback differs");
        recovery = {};
        return {{"document", document.id()}, {"status", "applied"}, {"dirty", document.object->property("isDirty").toBool()}, {"undo_available", document.score->undoAvailable()}};
    } catch (const std::exception &e) { return {{"document", document.id()}, {"error", QString::fromUtf8(e.what())}, {"outcome_unknown", true}}; }
    catch (...) { return {{"document", document.id()}, {"error", "Native replacement threw an unknown exception"}, {"outcome_unknown", true}}; }
}
inline QJsonObject editSemanticBeat(const QJsonObject &args, bool chord, std::function<QJsonObject()> &recovery) {
    const auto document = choose(args); semanticRequire(document.score, "Native document required");
    const int track = semanticInt(args.value("track"), 0, 1023, "track"), staff = semanticInt(args.value("staff"), 0, 15, "staff"),
        bar = semanticInt(args.value("bar"), 0, 255, "bar"), voice = semanticInt(args.value("voice"), 0, 3, "voice"), beat = semanticInt(args.value("beat"), 0, 19999, "beat");
    const auto staged = semanticCopy(document.score); semanticMove(staged.get(), track, staff, bar, voice, beat);
    semanticRequire(staged->cursor().beat() && !staged->cursor().beat()->isPlaceholder(), "Choose an existing real beat");
    gp::core::ScoreModelRange range(staged->cursor().modelIndex(), 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
    if (chord) {
        if (args.value("operation").toString("set") == "remove") staged->unsetChord(range);
        else {
            semanticRequire(args.value("operation").toString("set") == "set" && args.value("chord").isObject(), "set requires a chord object");
            const bool stringed = gp::core::InstrumentSet::isStringed(staged->tracks()[size_t(track)]->type());
            semanticSetChord(staged.get(), range, args.value("chord").toObject(), stringed ? int(semanticStaff(staged.get(), track, staff)->tuning().stringCount()) : 0);
            semanticMatch(args.value("chord"), semanticChord(*semanticStaff(staged.get(), track, staff), staged->cursor().beat()->chord()), "chord");
        }
    } else {
        const int line = semanticInt(args.value("line"), 0, 4, "line"); const QString text = semanticText(args.value("text"));
        // Operate on the isolated native beat; Score::setLyrics dispatches
        // spaces/hyphens into following beats instead of setting one fragment.
        staged->cursor().beat()->setLyrics(text.toStdString(), unsigned(line));
        semanticRequire(staged->cursor().beat()->lyrics()[size_t(line)].text() == text.toStdString(), "Native lyric readback differs");
    }
    auto result = semanticCommit(document, staged, recovery); result["position"] = semanticPosition(track, staff, bar, voice, beat); return result;
}
inline QJsonObject editChord(const QJsonObject &args, std::function<QJsonObject()> &recovery) { return editSemanticBeat(args, true, recovery); }
inline QJsonObject editLyrics(const QJsonObject &args, std::function<QJsonObject()> &recovery) { return editSemanticBeat(args, false, recovery); }
inline QJsonObject editSection(const QJsonObject &args, std::function<QJsonObject()> &recovery) {
    const auto document = choose(args); semanticRequire(document.score, "Native document required");
    const int bar = semanticInt(args.value("bar"), 0, int(document.score->masterTrack()->masterBarCount()) - 1, "bar");
    const auto staged = semanticCopy(document.score); const QString operation = args.value("operation").toString("set");
    if (operation == "remove") {
        gp::core::ScoreModelIndex index(staged->modelPrivate().get(), 0, bar, 0, 0, 0);
        gp::core::ScoreModelRange range(index, 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0)); staged->unsetMasterBarSection(range);
    } else {
        semanticRequire(operation == "set", "operation must be set or remove");
        const QString name = semanticText(args.value("name"), 256), text = semanticText(semanticDefault(args, "text", ""));
        staged->setMasterBarSection(unsigned(bar), true, gp::core::MasterBar::Section{name.toStdString(), text.toStdString()}, false);
    }
    return semanticCommit(document, staged, recovery);
}
} // namespace guitarpro
#include "guitarpro_spec.h"
