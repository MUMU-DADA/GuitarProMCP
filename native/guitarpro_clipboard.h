#pragma once
#include "guitarpro_api.h"
#include <QtCore/QUuid>
#include <QtCore/QMimeData>
#include <QtGui/QClipboard>

namespace guitarpro {
struct ScoreClipboard {
    std::shared_ptr<gp::core::SerializedScore> content;
    QJsonObject metadata;
    QJsonObject state() const {
        auto result = metadata;
        result["available"] = bool(content);
        result["storage"] = "native in-process score snapshot; not the system clipboard";
        return result;
    }
};
inline QJsonObject clipboardMetadata(const gp::core::SerializedScore &content) {
    QJsonArray tracks;
    for (const auto &track : content.score().tracks()) {
        if (!track) return {{"error", "Native clipboard contains an unavailable track"}};
        tracks.append(QJsonObject{{"index", tracks.size()}, {"staves", int(track->staffCount())}});
    }
    return {{"id", QUuid::createUuid().toString(QUuid::WithoutBraces)}, {"bar_count", int(content.barCount())},
        {"track_count", int(content.score().trackCount())}, {"multi_track", content.isMultiTrack()},
        {"multi_voice", content.isMultiVoice()}, {"tracks", tracks}};
}
struct NativeClipboard {
    QPointer<QObject> feature;
    quintptr implementation = 0;
    std::shared_ptr<gp::core::SerializedScore> content;
    DWORD sequence = 0;
    QJsonObject state;
};
inline NativeClipboard nativeClipboard(const QList<QPointer<QObject>> &objects) {
    NativeClipboard result;
    if (!supportedBuild()) { result.state = {{"error", "Native clipboard requires the verified host build"}}; return result; }
    for (const auto &object : objects) {
        if (!object || QByteArray(object->metaObject()->className()) != "gp::base::EditFeature") continue;
        if (result.feature && result.feature != object) {
            result.state = {{"error", "Ambiguous native edit feature"}}; return result;
        }
        result.feature = object;
    }
    const quintptr address = reinterpret_cast<quintptr>(result.feature.data());
    quintptr back = 0;
    // The verified EditFeature destructor owns Impl at +0x20; Impl owns the snapshot at +8.
    if (!address || discovery::type(address) != ".?AVEditFeature@base@gp@@" ||
        !discovery::read(address + 0x20, result.implementation) ||
        !discovery::read(result.implementation, back) || back != address) {
        result.state = {{"error", "Native edit feature is unavailable"}}; return result;
    }
    result.sequence = GetClipboardSequenceNumber();
    auto system = QApplication::clipboard();
    const bool owned = system->ownsClipboard();
    const auto mime = owned ? system->mimeData() : nullptr;
    const bool marker = mime && mime->hasFormat("app/gp") && mime->data("app/gp") == QByteArray(" ");
    const quintptr base = reinterpret_cast<quintptr>(GetModuleHandleW(nullptr));
    std::array<quintptr, 2> snapshot{};
    quintptr vtable = 0, controlVtable = 0;
    qint32 references = 0;
    const bool valid = owned && marker && result.feature &&
        discovery::read(result.implementation + 8, snapshot) && snapshot[0] == snapshot[1] + 16 &&
        discovery::read(snapshot[0], vtable) && vtable == base + 0xE66780 &&
        discovery::read(snapshot[1], controlVtable) && controlVtable == base + 0xE66EF8 &&
        discovery::read(snapshot[1] + 8, references) && references > 0 &&
        discovery::type(snapshot[0]) == ".?AVSerializedScore@core@gp@@";
    if (valid) {
        // Copy the host's shared_ptr on its GUI thread, retaining ownership across future copies.
        result.content = *reinterpret_cast<const std::shared_ptr<gp::core::SerializedScore> *>(result.implementation + 8);
    }
    const bool stable = result.sequence && GetClipboardSequenceNumber() == result.sequence && system->ownsClipboard() == owned;
    if (!stable) result.content.reset();
    result.state = {{"available", bool(result.content)}, {"owned_by_host", owned}, {"score_marker", marker},
        {"stable", stable}, {"sequence", double(result.sequence)}, {"scope", "Current Guitar Pro instance only"}};
    if (result.content) {
        auto metadata = clipboardMetadata(*result.content);
        metadata.remove("id");
        for (auto it = metadata.begin(); it != metadata.end(); ++it) result.state[it.key()] = it.value();
    }
    return result;
}
inline QJsonObject clipboard(const QJsonObject &args, ScoreClipboard &buffer, const QList<QPointer<QObject>> &objects) {
    if (!supportedBuild()) return {{"error", "Clipboard ABI requires the verified host build"}};
    const QString operation = args.value("operation").toString("state");
    QSet<QString> allowed{"operation"};
    if (operation == "copy" || operation == "cut") allowed.insert("document");
    else if (operation == "native_copy") allowed.unite({"document", "sequence"});
    else if (operation == "native_import") allowed.insert("sequence");
    else if (operation == "paste") allowed.unite({"document", "id", "scope"});
    else if (operation == "read") allowed.unite({"id", "track", "staff", "bar", "count"});
    else if (operation != "state" && operation != "clear" && operation != "native_state")
        return {{"error", "operation must be state, copy, cut, paste, read, clear, native_state, native_copy or native_import"}};
    for (auto it = args.begin(); it != args.end(); ++it)
        if (!allowed.contains(it.key())) return {{"error", "Argument does not apply to this clipboard operation: " + it.key()}};
    if (operation == "state") return buffer.state();
    if (operation == "clear") { buffer.content.reset(); buffer.metadata = {}; return buffer.state(); }
    NativeClipboard native;
    if (operation.startsWith("native_")) {
        if (!qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT"))
            return {{"error", "Host clipboard interop is experimental and requires GPMCP_DEVELOPMENT=1; isolated validation is pending"}};
        native = nativeClipboard(objects);
        if (native.state.contains("error") || operation == "native_state") return native.state;
        const auto sequence = args.value("sequence");
        if (!sequence.isDouble() || !native.state.value("stable").toBool() || sequence.toDouble() != double(native.sequence))
            return {{"error", "sequence must match the current native_state; clipboard changed or sequence was omitted"}};
        if (operation == "native_import") {
            if (!native.content) return {{"error", "The current clipboard is not a verified score from this Guitar Pro instance"}};
            auto metadata = clipboardMetadata(*native.content);
            if (metadata.contains("error")) return metadata;
            metadata["origin"] = "guitar_pro_clipboard";
            metadata["native_sequence"] = double(native.sequence);
            if (GetClipboardSequenceNumber() != native.sequence || !QApplication::clipboard()->ownsClipboard())
                return {{"error", "Native clipboard changed during import; read native_state again"}};
            buffer.content = std::move(native.content);
            buffer.metadata = std::move(metadata);
            return buffer.state();
        }
    }
    if (operation == "paste" || operation == "read") {
        if (!buffer.content || args.value("id").toString().isEmpty() || args.value("id") != buffer.metadata.value("id"))
            return {{"error", "id must match the current clipboard snapshot; read clipboard state first"}};
        if (operation == "read") {
            auto result = readBarsForScore(&buffer.content->score(), args);
            result["id"] = buffer.metadata.value("id");
            result["scope"] = "Native copied score snapshot; indices are relative to the serialized score";
            return result;
        }
    }
    const Document document = choose(args);
    if (!document.score) return {{"error", "Choose a document with a verified native score"}};
    auto &cursor = document.score->cursor();
    if (operation == "copy" || operation == "cut" || operation == "native_copy") {
        BeatSelection selected;
        const auto error = collectBeatSelection(document.score, selected);
        if (!error.isEmpty()) return {{"error", error}};
        if (selected.beats.empty()) return {{"error", "Copy requires an explicit selection containing real beats"}};
        const auto &selection = cursor.selectionRange();
        const gp::core::ScoreModelRange range(selection.lowerModelIndex(), selection.upperModelIndex(), selection.selectionModes(),
            static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
        std::shared_ptr<gp::core::SerializedScore> copied;
        if (operation == "native_copy") {
            if (!native.feature || GetClipboardSequenceNumber() != native.sequence)
                return {{"error", "Native clipboard changed before copying; read native_state again"}};
            const quintptr base = reinterpret_cast<quintptr>(GetModuleHandleW(nullptr));
            using Copy = void (*)(void *, const gp::core::ScoreModelRange &, bool);
            reinterpret_cast<Copy>(base + 0x10E690)(reinterpret_cast<void *>(native.implementation), range, range.isMultiTrack());
            if (native.feature) reinterpret_cast<void (*)(QObject *)>(base + 0x3D60D0)(native.feature.data());
            native = nativeClipboard(objects);
            if (!native.content || native.state.contains("error"))
                return {{"error", "Native copy did not leave a verified host clipboard; inspect native_state before retrying"}};
            copied = native.content;
        } else copied = std::make_shared<gp::core::SerializedScore>(range);
        if (copied->barCount() != range.barCount() || copied->score().tracks().empty() || copied->isMultiTrack() != range.isMultiTrack())
            return {{"error", "Native clipboard snapshot does not match the selected range"}};
        auto metadata = clipboardMetadata(*copied);
        if (metadata.contains("error")) return metadata;
        metadata["source_document"] = document.view->objectName();
        metadata["source_selection"] = selectionState(cursor);
        metadata["source_beats"] = selected.positions;
        metadata["beat_count"] = int(selected.beats.size());
        if (operation == "native_copy") {
            metadata.remove("id");
            metadata["operation"] = operation;
            metadata["native_sequence"] = double(native.sequence);
            metadata["native_state"] = native.state;
            return metadata;
        }
        if (operation == "cut") {
            const auto active = activate(QJsonObject{{"document", document.view->objectName()}}, objects);
            if (active.contains("error")) return active;
            if (range.isMultiTrack()) document.score->removeBarRange(unsigned(range.lowerModelIndex().barIndex()), unsigned(range.upperModelIndex().barIndex()));
            else if (range.isMultiVoice()) {
                // The native multi-voice removal pads short voices outside undo.
                // Independent voice ranges keep the original model restorable.
                gp::core::MacroCommandRecorder recorder(document.score, true);
                for (const auto &part : selected.ranges) document.score->removeBeatRange(*part);
                recorder.commit();
            }
            else document.score->removeBeatRange(range);
        }
        buffer.content = std::move(copied);
        buffer.metadata = metadata;
        auto result = buffer.state();
        result["operation"] = operation;
        result["dirty"] = document.object->property("isDirty").toBool();
        result["cursor"] = cursorState(document.score);
        return result;
    }
    const QString scope = args.value("scope").toString("cursor");
    if (scope != "cursor" && scope != "selection") return {{"error", "scope must be cursor or selection"}};
    const auto &tracks = document.score->tracks();
    if (cursor.trackIndex() < 0 || size_t(cursor.trackIndex()) >= tracks.size() || !cursor.staff() || cursor.barIndex() < 0)
        return {{"error", "Paste requires a cursor in an existing track, staff and bar"}};
    const auto master = document.score->masterTrack();
    if (!master || master->masterBarCount() > 100000 || unsigned(cursor.barIndex()) + buffer.content->barCount() > 100000)
        return {{"error", "Paste would exceed the supported score size"}};
    const unsigned previousBars = master->masterBarCount();
    const bool bars = buffer.content->isMultiTrack() || buffer.content->barCount() > 1;
    if (bars && previousBars + buffer.content->barCount() > 100000)
        return {{"error", "Bar insertion would exceed the supported score size"}};
    if (!buffer.content->isCompatibleWith(*document.score))
        return {{"error", "Native clipboard is incompatible with the destination score or cursor mode; multi-voice fragments require an all-voices destination"},
            {"native_incompatibility", QString::number(buffer.content->incompatiblePasteTypeWith(*document.score))}};
    if (scope == "selection") {
        BeatSelection destination;
        const auto error = collectBeatSelection(document.score, destination);
        if (!error.isEmpty()) return {{"error", error}};
    }
    const auto &selection = cursor.selectionRange();
    const auto &base = scope == "selection" ? selection.lowerModelIndex() : cursor.modelIndex();
    const auto &extent = scope == "selection" ? selection.upperModelIndex() : cursor.modelIndex();
    const unsigned modes = scope == "selection" ? selection.selectionModes() : buffer.content->isMultiVoice() ? 2u : 0u;
    const gp::core::ScoreModelRange destination(base, extent, modes, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
    const auto active = activate(QJsonObject{{"document", document.view->objectName()}}, objects);
    if (active.contains("error")) return active;
    // Verified normal-paste dispatch in GuitarPro.exe (RVA 0x10A574).
    // Mode 0 follows its non-adapting normal paste; special-paste flags are separate.
    const auto mode = static_cast<gp::core::SerializedScore::OverridingMode>(0);
    if (bars) document.score->pasteBarRange(buffer.content, destination, 1, mode);
    else document.score->pasteBeatRange(buffer.content, destination, 1, mode);
    auto result = scoreState(QJsonObject{{"document", document.view->objectName()}});
    result["clipboard_id"] = buffer.metadata.value("id");
    result["native_method"] = bars ? "Score::pasteBarRange" : "Score::pasteBeatRange";
    result["previous_bar_count"] = int(previousBars);
    result["global_bar_delta"] = int(master->masterBarCount()) - int(previousBars);
    return result;
}
}
