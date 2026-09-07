#pragma once
#include "discovery.h"
#include "guitarpro_abi.h"
#include "host_build.h"
#include <QtCore/QCryptographicHash>
#include <QtCore/QFile>
#include <QtCore/QDir>
#include <QtCore/QFileInfo>
#include <QtCore/QMetaMethod>
#include <QtCore/QPointer>
#include <QtCore/QUuid>
#include <QtCore/QSaveFile>
#include <QtCore/QTemporaryDir>
#include <QtCore/QXmlStreamReader>
#include <QtCore/QSignalBlocker>
#include <QtGui/private/qzipreader_p.h>
#include <QtWidgets/QApplication>
#include <QtWidgets/QStackedWidget>
#include <QtWidgets/QBoxLayout>
#include <QtGui/QColor>
#include <cmath>

namespace guitarpro {
inline QString validateGpFile(const QString &path) {
    QZipReader archive(path);
    if (!archive.isReadable()) return "Cannot read the Guitar Pro archive";
    const auto entries = archive.fileInfoList();
    int matching = 0;
    for (const auto &entry : entries) if (entry.filePath == "Content/score.gpif") {
        if (!entry.isFile || entry.isSymLink || entry.size < 1 || entry.size > 64 * 1024 * 1024)
            return "GPIF must be a regular archive entry of at most 64 MiB";
        ++matching;
    }
    if (archive.status() != QZipReader::NoError || matching != 1) return "Expected one Content/score.gpif entry in a readable Guitar Pro archive";
    const QByteArray content = archive.fileData("Content/score.gpif");
    if (archive.status() != QZipReader::NoError || content.isEmpty() || content.size() > 64 * 1024 * 1024) return "Cannot decompress the GPIF entry";
    QXmlStreamReader xml(content);
    bool root = false;
    while (!xml.atEnd()) {
        const auto token = xml.readNext();
        if (token == QXmlStreamReader::DTD) return "GPIF document type declarations are not supported";
        if (!root && token == QXmlStreamReader::StartElement) {
            if (xml.name() != "GPIF") return "Expected a GPIF XML root";
            root = true;
        }
    }
    if (!root) return "Expected a GPIF XML root";
    return xml.hasError() ? "Invalid GPIF XML: " + xml.errorString() : QString();
}
struct Document {
    QPointer<QWidget> view;
    QPointer<QObject> object;
    gp::core::Score *score = nullptr;
    QString id() const {
        if (!object) return {};
        QString value = object->property("gpmcpDocumentId").toString();
        if (value.isEmpty()) {
            value = QUuid::createUuid().toString(QUuid::WithoutBraces);
            object->setProperty("gpmcpDocumentId", value);
        }
        return value;
    }
};
inline QList<Document> documents() {
    QList<Document> result;
    if (!supportedBuild()) return result;
    for (QWidget *view : QApplication::allWidgets()) {
        if (QByteArray(view->metaObject()->className()) != "gp::gui::IDocumentView") continue;
        quintptr implementation = 0, document = 0;
        if (!discovery::read(reinterpret_cast<quintptr>(view) + 0x30, implementation) || !discovery::read(implementation + 0x98, document)) continue;
        if (discovery::type(document) != ".?AVIDocument@gui@gp@@") continue;
        QObject *object = discovery::asQObject(document);
        if (!object || QByteArray(object->metaObject()->className()) != "gp::gui::IDocument") continue;
        // GP 8.1.1.17 x64: IDocument::Impl owns a shared_ptr<Score> at +0x68.
        // Hash and independent RTTI checks are mandatory before dereferencing it.
        quintptr impl = 0, score = 0, control = 0, model = 0, self = 0;
        gp::core::Score *nativeScore = nullptr;
        if (discovery::read(document + 0x10, impl) && discovery::read(impl + 0x68, score) &&
            discovery::read(impl + 0x70, control) && discovery::type(control) == ".?AV?$_Ref_count_obj2@VScore@core@gp@@@std@@" &&
            discovery::read(score, self) && self == score && discovery::read(score + 0x38, model) &&
            discovery::type(model) == ".?AVScoreModel@core@gp@@") {
            auto candidate = reinterpret_cast<gp::core::Score *>(score);
            if (reinterpret_cast<quintptr>(candidate->modelPrivate().get()) == model) nativeScore = candidate;
        }
        result.append({view, object, nativeScore});
    }
    return result;
}
inline QObject *activeDocument(const QList<QPointer<QObject>> &objects) {
    QObject *result = nullptr;
    for (const auto &guard : objects) {
        QObject *object = guard.data();
        if (!object) continue;
        if (QByteArray(object->metaObject()->className()) != "gp::gui::IDocumentsManager") continue;
        const quintptr manager = reinterpret_cast<quintptr>(object);
        quintptr impl = 0, back = 0, current = 0;
        if (discovery::type(manager) != ".?AVIDocumentsManager@gui@gp@@" ||
            !discovery::read(manager + 0x10, impl) || !discovery::read(impl + 0x50, back) || back != manager ||
            !discovery::read(impl + 0x70, current) || discovery::type(current) != ".?AVIDocument@gui@gp@@") continue;
        QObject *candidate = discovery::asQObject(current);
        if (result && result != candidate) return nullptr;
        result = candidate;
    }
    return result;
}
struct DocumentTabs {
    QPointer<QStackedWidget> pages;
    QPointer<QBoxLayout> layout;
    QString error;
};
inline DocumentTabs documentTabs(const QList<Document> &available, QObject *current) {
    DocumentTabs result;
    result.error = "Native document tab mapping is unavailable";
    if (available.isEmpty()) return result;
    const auto first = available.first().view;
    if (!first) return result;
    auto pages = qobject_cast<QStackedWidget *>(first->parentWidget());
    QWidget *window = first->window();
    if (!pages || !window || QByteArray(window->metaObject()->className()) != "gp::gui::MainWindow" || pages->count() != available.size()) return result;
    for (const auto &document : available)
        if (!document.view || !document.object || document.view->parentWidget() != pages || pages->indexOf(document.view) < 0) return result;
    QBoxLayout *layout = nullptr;
    for (auto widget : window->findChildren<QWidget *>()) {
        if (QByteArray(widget->metaObject()->className()) != "am::gui::TabBar") continue;
        for (auto candidate : widget->findChildren<QBoxLayout *>()) {
            bool matches = candidate->count() == available.size();
            for (int i = 0; matches && i < candidate->count(); ++i) {
                auto tab = candidate->itemAt(i)->widget();
                matches = tab && QByteArray(tab->metaObject()->className()) == "am::gui::Tab";
            }
            if (!matches) continue;
            if (layout) { result.error = "Ambiguous native document tab layout"; return result; }
            layout = candidate;
        }
    }
    if (!layout || pages->currentIndex() < 0) return result;
    for (int i = 0; i < pages->count(); ++i) {
        const Document *document = nullptr;
        for (const auto &candidate : available) if (candidate.view == pages->widget(i)) { document = &candidate; break; }
        auto tab = layout->itemAt(i)->widget();
        if (!document || tab->metaObject()->indexOfSignal("clicked()") < 0 ||
            tab->property("selected").toBool() != (i == pages->currentIndex()) ||
            tab->property("dirty").toBool() != document->object->property("isDirty").toBool() ||
            (current && (document->object == current) != (i == pages->currentIndex()))) return result;
        const QString path = QDir::fromNativeSeparators(tab->toolTip());
        const QString opened = QDir::fromNativeSeparators(document->object->property("openedFilePath").toString());
        const QString saved = QDir::fromNativeSeparators(document->object->property("saveFilePath").toString());
        // Unnamed tabs can retain an empty tooltip after Save As; dirty tabs
        // prepend a localized label to the original opened path.
        const auto matchesPath = [&](const QString &expected) {
            return !expected.isEmpty() && (path == expected || (tab->property("dirty").toBool() && path.endsWith(" " + expected)));
        };
        if (!opened.isEmpty() && !matchesPath(opened) && !matchesPath(saved)) { result.error = "Native tab path differs from its document page"; return result; }
    }
    result.pages = pages;
    result.layout = layout;
    result.error.clear();
    return result;
}
inline QJsonObject list(const QList<QPointer<QObject>> &objects = {}) {
    if (!supportedBuild()) return {{"error", "Private document ABI disabled: this Guitar Pro build is not verified"}};
    QJsonArray result;
    QObject *current = activeDocument(objects);
    auto available = documents();
    const auto tabs = documentTabs(available, current);
    if (tabs.pages) {
        QList<Document> ordered;
        for (int i = 0; i < tabs.pages->count(); ++i)
            for (const auto &document : available) if (document.view == tabs.pages->widget(i)) ordered.append(document);
        available = ordered;
    }
    QString activeId;
    for (const auto &document : available) {
        if (document.object == current) activeId = document.id();
        result.append(QJsonObject{{"id", document.id()}, {"opened_path", document.object->property("openedFilePath").toString()},
            {"save_path", document.object->property("saveFilePath").toString()}, {"dirty", document.object->property("isDirty").toBool()}, {"native_score_available", document.score != nullptr}, {"active", current ? QJsonValue(document.object == current) : QJsonValue()},
            {"tab_index", tabs.pages ? QJsonValue(tabs.pages->indexOf(document.view)) : QJsonValue()}});
    }
    QJsonObject state{{"documents", result}, {"active_document", activeId.isEmpty() ? QJsonValue() : QJsonValue(activeId)},
        {"tab_order_available", available.isEmpty() || bool(tabs.pages)}, {"source", "Live gp::gui::IDocument objects inside GuitarPro.exe"}};
    if (!available.isEmpty() && !tabs.pages) state["tab_order_error"] = tabs.error;
    return state;
}
inline Document choose(const QJsonObject &args) {
    const auto available = documents();
    const QString id = args.value("document").toString();
    for (const auto &document : available)
        if (document.id() == id || (id.isEmpty() && available.size() == 1)) return document;
    return {};
}
inline QJsonObject moveDocument(const QJsonObject &args, const QList<QPointer<QObject>> &objects) {
    const Document target = choose(args);
    if (!target.object || !target.view) return {{"error", "Choose an existing document id"}};
    QObject *current = activeDocument(objects);
    if (!current) return {{"error", "Native active-document state is unavailable"}};
    const auto tabs = documentTabs(documents(), current);
    if (!tabs.pages || !tabs.layout) return {{"error", tabs.error}};
    const int from = tabs.pages->indexOf(target.view), to = args.value("index").toInt(-1);
    if (to < 0 || to >= tabs.pages->count()) return {{"error", "Tab index is outside the document list"}};
    if (from == to) return {{"status", "unchanged"}, {"document", target.id()}, {"previous_index", from}, {"tab_index", to}, {"undoable", false}};
    QPointer<QWidget> activePage = tabs.pages->currentWidget();
    QPointer<QWidget> activeTab = tabs.layout->itemAt(tabs.pages->currentIndex())->widget();
    // The host has no drag-reorder handler. Keep its tab layout and page stack
    // aligned, then let the original tab activation signal update host state.
    {
        const QSignalBlocker blocked(tabs.pages);
        auto item = tabs.layout->takeAt(from);
        tabs.layout->insertItem(to, item);
        tabs.pages->removeWidget(target.view);
        tabs.pages->insertWidget(to, target.view);
        tabs.pages->setCurrentWidget(activePage);
    }
    const bool invoked = activeTab && QMetaObject::invokeMethod(activeTab, "clicked", Qt::DirectConnection);
    const auto observed = documentTabs(documents(), activeDocument(objects));
    if (!invoked || !observed.pages || !target.view || observed.pages->indexOf(target.view) != to || observed.pages->currentWidget() != activePage || activeDocument(objects) != current)
        return {{"error", "Native tab order did not match the requested result; inspect gp_documents before retrying"}, {"outcome_unknown", true}};
    return {{"status", "moved"}, {"document", target.id()}, {"previous_index", from}, {"tab_index", to}, {"undoable", false}};
}
inline QJsonObject activate(const QJsonObject &args, const QList<QPointer<QObject>> &objects) {
    const Document target = choose(args);
    if (!target.object) return {{"error", "Choose an existing document id"}};
    QObject *current = activeDocument(objects);
    if (!current) return {{"error", "Native active-document state is unavailable"}};
    QPointer<QWidget> window;
    for (QWidget *widget : QApplication::topLevelWidgets())
        if (QByteArray(widget->metaObject()->className()) == "gp::gui::MainWindow") window = widget;
    if (!window) return {{"error", "Native main window is unavailable"}};
    const int limit = documents().size();
    for (int i = 0; i <= limit; ++i) {
        if (!target.object || !target.view || !window) return {{"error", "Document or window was closed during activation"}};
        if (current == target.object) return {{"status", "active"}, {"document", target.id()}};
        if (i == limit || !QMetaObject::invokeMethod(window, "activateNextDocumentView", Qt::DirectConnection)) break;
        QObject *next = activeDocument(objects);
        if (!next || next == current) break;
        current = next;
    }
    return {{"error", "Native document navigation did not reach the requested document; read gp_documents before retrying"}};
}
inline QJsonObject closeDocument(const QJsonObject &args, const QList<QPointer<QObject>> &objects, bool allowPrompt = false) {
    const Document target = choose(args);
    if (!target.object || !target.view) return {{"error", "Choose an existing document id"}};
    if (target.object->property("isDirty").toBool() && !allowPrompt) return {{"error", "Document has unsaved changes; save it before closing"}};
    if (QApplication::activeModalWidget()) return {{"error", "Close the active modal dialog before closing a document"}};
    const QJsonObject activated = activate(args, objects);
    if (activated.contains("error")) return activated;
    if (!target.view || !target.object) return {{"error", "Document disappeared during activation"}};
    const auto tabs = documentTabs(documents(), activeDocument(objects));
    auto stack = tabs.pages.data();
    QWidget *window = target.view->window();
    if (!stack || !window || QByteArray(window->metaObject()->className()) != "gp::gui::MainWindow" ||
        stack->currentWidget() != target.view || stack->count() != documents().size())
        return {{"error", tabs.error.isEmpty() ? "Native document page mapping is unavailable" : tabs.error}};
    for (int i = 0; i < stack->count(); ++i)
        if (QByteArray(stack->widget(i)->metaObject()->className()) != "gp::gui::IDocumentView")
            return {{"error", "Unexpected page in native document stack"}};
    QObject *proxy = nullptr;
    for (QObject *child : window->children()) {
        if (QByteArray(child->metaObject()->className()) != "gp::gui::TabWidgetProxy") continue;
        if (proxy) return {{"error", "Ambiguous native document tab proxy"}};
        proxy = child;
    }
    // Use the host's document-close request, never QWidget::close on a score view.
    const int index = stack->indexOf(target.view);
    if (!proxy || index < 0) return {{"error", "Native document close request is unavailable"}};
    // Closing the last score can close a host window. Keep MCP alive for reopen.
    const bool quitOnLastWindow = qApp->quitOnLastWindowClosed();
    qApp->setQuitOnLastWindowClosed(false);
    const bool invoked = QMetaObject::invokeMethod(proxy, "tabCloseRequested", Qt::DirectConnection, Q_ARG(int, index));
    qApp->setQuitOnLastWindowClosed(quitOnLastWindow);
    if (!invoked)
        return {{"error", "Native document close request is unavailable"}};
    return {{"status", "requested"}};
}
inline QJsonObject indexState(const gp::core::ScoreModelIndex &index) {
    return {{"track", index.trackIndex()}, {"staff", int(index.staffIndex())}, {"bar", index.barIndex()},
        {"voice", int(index.voiceIndex())}, {"beat", index.beatIndex()},
        {"note_string", int(index.noteString())}, {"note_midi", int(index.noteMidi())}};
}
inline QJsonObject selectionState(const gp::core::ScoreCursor &cursor) {
    const auto &range = cursor.selectionRange();
    return {{"bars", int(range.barCount())}, {"beats", int(range.beatCount())},
        {"multi_selection", range.isMultiSelection()}, {"multi_track", range.isMultiTrack()},
        {"multi_voice", range.isMultiVoice()}, {"placeholder", range.isPlaceholder()},
        {"native_modes", int(range.selectionModes())}, {"base", indexState(range.baseModelIndex())},
        {"extent", range.isMultiSelection() ? QJsonValue(indexState(range.extentModelIndex())) : QJsonValue()},
        {"lower", indexState(range.lowerModelIndex())}, {"upper", indexState(range.upperModelIndex())},
        {"base_matches_cursor", range.baseModelIndex().beat() == cursor.beat()}};
}
inline QJsonObject cursorState(gp::core::Score *score) {
    const auto &cursor = score->cursor();
    return {{"track", cursor.trackIndex()}, {"staff", int(cursor.staffIndex())},
        {"bar", cursor.barIndex()}, {"voice", int(cursor.voiceIndex())}, {"beat", cursor.beatIndex()},
        {"selection", selectionState(cursor)},
        {"note_string", int(cursor.noteString())}, {"note_midi", int(cursor.noteMidi())}, {"index_base", 0}};
}
inline QJsonObject metadata(gp::core::Score *score) {
    QJsonObject result;
    // The verified export's switch accepts the eleven ScoreProperty values 0..10.
    for (int i = 0; i <= 10; ++i) {
        const auto property = static_cast<gp::core::ScoreProperty>(i);
        const std::string value = score->property(property);
        result[gp::core::scorePropertyToQString(property)] = QString::fromUtf8(value.data(), int(value.size()));
    }
    return result;
}
inline std::shared_ptr<gp::core::TrackBase> trackBase(gp::core::Score *score, unsigned index) {
    const auto &tracks = score->tracks();
    if (index >= tracks.size() || !tracks[index]) return {};
    // Native overload performs the base conversion; Type 0 is a normal track.
    const auto base = score->track(static_cast<gp::core::TrackBase::Type>(0), index);
    if (!base || reinterpret_cast<void *>(base.get()) != reinterpret_cast<void *>(tracks[index].get()) ||
        discovery::type(reinterpret_cast<quintptr>(base.get())) != ".?AVTrack@core@gp@@" ||
        base->index() != int(index) || base->parentScoreModel() != score->modelPrivate().get()) return {};
    return base;
}
inline bool validHostText(const QString &text) {
    if (text.size() > 16384) return false;
    for (QChar character : text)
        if (character.isSurrogate() || character.unicode() >= 0xfffe ||
            (character.unicode() < 0x20 && character != '\t' && character != '\n' && character != '\r')) return false;
    return true;
}
inline QJsonObject tempoState(gp::core::Score *score) {
    const auto master = score->masterTrack();
    if (!master) return {{"error", "Native master track unavailable"}};
    const auto unit = master->tempoUnit();
    QJsonArray units;
    // The verified conversion table accepts only units 1..5; 2 is Quarter.
    for (int i = 1; i <= 5; ++i) units.append(QString::fromStdString(gp::core::tempoUnitToString(static_cast<gp::core::TempoUnit>(i))));
    return {{"value", master->tempoValue()}, {"unit", QString::fromStdString(gp::core::tempoUnitToString(unit))},
        {"label", QString::fromStdString(master->tempoLabel())}, {"units", units},
        {"quarter_bpm", int(unit) >= 1 && int(unit) <= 5 ? QJsonValue(gp::core::convertTempo(master->tempoValue(), unit, static_cast<gp::core::TempoUnit>(2))) : QJsonValue()},
        {"scope", "initial score tempo; later tempo automations are not included"}};
}
inline QJsonObject editTempo(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const double value = args.value("value").toDouble(-1);
    if (!args.value("value").isDouble() || !std::isfinite(value) || value < 1 || value > 400 || std::floor(value) != value)
        return {{"error", "Tempo value must be an integer in 1..400, expressed in the requested beat unit; the host truncates fractions"}};
    const auto master = document.score->masterTrack();
    if (!master) return {{"error", "Native master track unavailable"}};
    auto unit = master->tempoUnit();
    if (args.contains("unit")) {
        unit = static_cast<gp::core::TempoUnit>(0);
        for (int i = 1; i <= 5; ++i) {
            const auto candidate = static_cast<gp::core::TempoUnit>(i);
            if (QString::fromStdString(gp::core::tempoUnitToString(candidate)) == args.value("unit").toString()) unit = candidate;
        }
    }
    if (int(unit) < 1 || int(unit) > 5) return {{"error", "Choose a unit from gp_score.tempo.units"}};
    const QString label = args.value("label").toString(QString::fromStdString(master->tempoLabel()));
    if (!validHostText(label)) return {{"error", "Tempo label must be at most 16384 UTF-16 units and compatible with the host GPIF writer"}};
    if (master->tempoValue() != float(value) || master->tempoUnit() != unit || master->tempoLabel() != label.toStdString())
        document.score->setTempo(label.toStdString(), unit, float(value));
    if (std::abs(master->tempoValue() - float(value)) > 0.0001f || master->tempoUnit() != unit || master->tempoLabel() != label.toStdString())
        return {{"error", "Native tempo readback differs; inspect gp_score before retrying"}, {"tempo", tempoState(document.score)}};
    return {{"document", document.id()}, {"tempo", tempoState(document.score)},
        {"dirty", document.object->property("isDirty").toBool()}, {"undo_available", document.score->undoAvailable()}};
}
inline QJsonObject scoreState(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable; choose a document from gp_documents on the verified build"}};
    QJsonArray tracks;
    const auto &nativeTracks = document.score->tracks();
    if (nativeTracks.size() > 1024) return {{"error", "Native track count exceeds safety bound"}};
    for (size_t i = 0; i < nativeTracks.size(); ++i) {
        const auto &track = nativeTracks[i];
        if (!track || discovery::type(reinterpret_cast<quintptr>(track.get())) != ".?AVTrack@core@gp@@")
            return {{"error", "Native track type validation failed"}};
        const auto base = trackBase(document.score, unsigned(i));
        if (!base) return {{"error", "Native TrackBase validation failed"}};
        const auto &color = base->color();
        tracks.append(QJsonObject{{"index", int(i)}, {"bars", int(track->barCount())}, {"staves", int(track->staffCount())},
            {"name", QString::fromStdString(base->name())}, {"short_name", QString::fromStdString(base->shortName())},
            {"playback_state", QString::fromStdString(gp::core::playbackStateToString(base->playbackState()))},
            {"volume", base->volume()}, {"pan", base->pan()}, {"transposition", track->transpositionOffset()},
            {"color", QColor(color.red, color.green, color.blue).name()},
            {"instrument_type", QString::fromStdString(gp::core::InstrumentSet::typeToString(track->type()))}});
    }
    return {{"document", document.id()}, {"metadata", metadata(document.score)}, {"tracks", tracks}, {"tempo", tempoState(document.score)},
        {"track_count", int(document.score->trackCount())}, {"cursor", cursorState(document.score)},
        {"dirty", document.object->property("isDirty").toBool()}, {"undo_available", document.score->undoAvailable()},
        {"redo_available", document.score->redoAvailable()}, {"source", "GPCore native Score API"}};
}
inline QJsonObject editMetadata(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    if (!args.value("property").isString() || !args.value("value").isString() || args.value("value").toString().size() > 16384)
        return {{"error", "property and value must be strings; value is limited to 16384 characters"}};
    const QString input = args.value("value").toString();
    if (!validHostText(input)) return {{"error", "This host's GPIF writer cannot reliably preserve supplementary Unicode or invalid XML characters"}};
    const QString name = args.value("property").toString();
    for (int i = 0; i <= 10; ++i) {
        const auto property = static_cast<gp::core::ScoreProperty>(i);
        if (gp::core::scorePropertyToQString(property) != name) continue;
        const QByteArray bytes = args.value("value").toString().toUtf8();
        const std::string value(bytes.constData(), size_t(bytes.size()));
        if (document.score->property(property) != value) document.score->setProperty(property, value);
        if (document.score->property(property) != value) return {{"error", "Native metadata readback differs"}};
        return {{"document", document.id()}, {"property", name}, {"value", args.value("value")},
            {"dirty", document.object->property("isDirty").toBool()}, {"undo_available", document.score->undoAvailable()}};
    }
    return {{"error", "Unknown metadata property; use the exact key from gp_score.metadata"}};
}
inline QJsonObject editTrack(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const int index = args.value("track").toInt(-1);
    const auto base = index < 0 ? nullptr : trackBase(document.score, unsigned(index));
    if (!base) return {{"error", "Choose an existing track index"}};
    const QString property = args.value("property").toString();
    if (property == "volume" || property == "pan") {
        const double requested = args.value("value").toDouble(-1);
        if (!args.value("value").isDouble() || !std::isfinite(requested) || requested < 0 || requested > 1)
            return {{"error", "volume and pan require a normalized number in 0..1"}};
        const float value = float(requested);
        const float before = property == "volume" ? base->volume() : base->pan();
        if (before != value) document.score->setTrackChannelStripParameter(*base, property == "volume" ? 12u : 11u, value);
        const float after = property == "volume" ? base->volume() : base->pan();
        if (std::abs(after - value) > 0.000001f) return {{"error", "Native track mix readback differs"}};
        QJsonObject result = scoreState(args);
        result["undoable"] = true;
        return result;
    }
    if (!args.value("value").isString()) return {{"error", "Track text, color and playback state require a string"}};
    const QString value = args.value("value").toString();
    if (property == "name" || property == "short_name") {
        if (!validHostText(value)) return {{"error", "Track text must be at most 16384 UTF-16 units and compatible with the host GPIF writer"}};
        const std::string text = value.toStdString();
        if (property == "name" && base->name() != text) document.score->setTrackName(*base, text);
        else if (property == "short_name" && base->shortName() != text) document.score->setTrackShortName(*base, text);
        if ((property == "name" ? base->name() : base->shortName()) != text) return {{"error", "Native track text readback differs"}};
    } else if (property == "color") {
        const QColor requested(value);
        if (value.size() != 7 || !value.startsWith('#') || !requested.isValid()) return {{"error", "color must be #RRGGBB"}};
        const am::utils::Color color{static_cast<unsigned char>(requested.red()), static_cast<unsigned char>(requested.green()), static_cast<unsigned char>(requested.blue())};
        const auto &before = base->color();
        if (before.red != color.red || before.green != color.green || before.blue != color.blue) document.score->setTrackColor(*base, color);
        const auto &after = base->color();
        if (after.red != color.red || after.green != color.green || after.blue != color.blue) return {{"error", "Native track color readback differs"}};
    } else if (property == "playback_state") {
        const int state = QStringList{"Default", "Solo", "Mute"}.indexOf(value);
        if (state < 0) return {{"error", "playback_state must be Default, Solo or Mute"}};
        if (int(base->playbackState()) != state) document.score->setTrackPlaybackState(*base, static_cast<gp::core::PlaybackState>(state));
        if (int(base->playbackState()) != state) return {{"error", "Native track playback readback differs"}};
    } else return {{"error", "property must be name, short_name, color, volume, pan or playback_state"}};
    QJsonObject result = scoreState(args);
    result["undoable"] = property != "playback_state";
    return result;
}
inline QJsonObject editTracks(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const auto before = document.score->tracks();
    const int index = args.value("track").toInt(-1), other = args.value("other").toInt(-1);
    const QString operation = args.value("operation").toString();
    if (index < 0 || size_t(index) >= before.size() || before.size() > 1024) return {{"error", "Choose an existing track index; at most 1024 tracks supported"}};
    if (operation != "swap" && args.contains("other")) return {{"error", "other requires operation swap"}};
    if (operation == "duplicate") {
        if (before.size() == 1024) return {{"error", "Result would exceed 1024 tracks"}};
        document.score->duplicateTrack(unsigned(index));
    } else if (operation == "remove") document.score->removeTrack(unsigned(index));
    else if (operation == "swap") {
        if (other < 0 || size_t(other) >= before.size()) return {{"error", "Choose an existing other track index"}};
        if (other != index) document.score->swapTracks(unsigned(index), unsigned(other));
    } else return {{"error", "operation must be duplicate, remove or swap"}};
    const auto &after = document.score->tracks();
    const size_t expected = operation == "duplicate" ? before.size() + 1 : operation == "remove" ? before.size() - 1 : before.size();
    if (after.size() != expected) return {{"error", "Native track count readback differs; inspect score before retrying"}};
    for (size_t i = 0; i < after.size(); ++i) {
        if (operation == "duplicate" && i == size_t(index + 1)) {
            if (after[i] == before[index]) return {{"error", "Duplicated track aliases its source"}};
            continue;
        }
        size_t source = i;
        if (operation == "duplicate" && i > size_t(index + 1)) source = i - 1;
        if (operation == "remove" && i >= size_t(index)) source = i + 1;
        if (operation == "swap") source = i == size_t(index) ? size_t(other) : i == size_t(other) ? size_t(index) : i;
        if (after[i] != before[source]) return {{"error", "Native track order readback differs; inspect score before retrying"}};
    }
    QJsonObject result = scoreState(args);
    result["operation"] = operation;
    result["previous_track_count"] = int(before.size());
    return result;
}
inline QJsonObject insertTrack(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native target score unavailable"}};
    const QString sourceId = args.value("source_document").toString(document.id());
    const Document source = choose(QJsonObject{{"document", sourceId}});
    if (!source.score) return {{"error", "Native source score unavailable"}};
    const int sourceIndex = args.value("source_track").toInt(-1);
    const auto before = document.score->tracks();
    const int index = args.value("index").toInt(int(before.size()));
    if (index < 0 || size_t(index) > before.size() || before.size() >= 1024 || sourceIndex < 0 ||
        size_t(sourceIndex) >= source.score->tracks().size()) return {{"error", "Valid source track and target insertion index required; target must have fewer than 1024 tracks"}};
    const auto prototype = source.score->tracks()[sourceIndex];
    if (!prototype || !trackBase(source.score, unsigned(sourceIndex))) return {{"error", "Native source track validation failed"}};
    const auto master = document.score->masterTrack();
    if (!master) return {{"error", "Native master track unavailable"}};
    const unsigned expectedBars = qMax(1u, master->masterBarCount());
    if (expectedBars > 100000 || prototype->barCount() > 100000) return {{"error", "Track insertion supports at most 100000 bars"}};
    const bool copyContent = args.value("copy_content").toBool(false);
    if (copyContent && prototype->barCount() != expectedBars)
        return {{"error", "Copying track content currently requires matching source and target bar counts"}};
    // The host clones the prototype. The first bool clears/rebuilds its bars;
    // remaining flags configure views, with no solo view and automatic layout.
    document.score->createTrack(unsigned(index), prototype, unsigned(qMax(0, prototype->defaultBarCountBySystem())), !copyContent, false, false, 0);
    const auto &after = document.score->tracks();
    if (after.size() != before.size() + 1 || !after[index] || after[index] == prototype ||
        after[index]->barCount() != expectedBars || after[index]->staffCount() != prototype->staffCount())
        return {{"error", "Native inserted track readback differs; inspect score before retrying"}};
    for (size_t i = 0; i < before.size(); ++i)
        if (after[i < size_t(index) ? i : i + 1] != before[i]) return {{"error", "Track insertion changed existing track order"}};
    QJsonObject result = scoreState(args);
    result["inserted_track"] = index;
    result["copied_content"] = copyContent;
    return result;
}
inline QJsonObject undoRedo(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const QString operation = args.value("operation").toString();
    if (operation == "undo" && document.score->undoAvailable()) document.score->undo();
    else if (operation == "redo" && document.score->redoAvailable()) document.score->redo();
    else return {{"error", "operation must be an available undo or redo"}};
    return scoreState(args);
}
inline QJsonObject moveCursor(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const double value = args.value("index").toDouble(-1);
    if (value < 0 || value > 100000 || value != int(value)) return {{"error", "index must be a nonnegative integer <= 100000"}};
    const QString axis = args.value("axis").toString();
    auto &cursor = document.score->cursor();
    bool changed = false;
    if (axis == "track") changed = cursor.trySetTrackIndex(int(value));
    else if (axis == "bar") changed = cursor.trySetBarIndex(int(value));
    else if (axis == "beat") changed = cursor.trySetBeatIndex(int(value));
    else if (axis == "staff") {
        const int track = cursor.trackIndex();
        const auto &tracks = document.score->tracks();
        if (track < 0 || size_t(track) >= tracks.size() || !tracks[track] || unsigned(value) >= tracks[track]->staffCount())
            return {{"error", "Staff does not exist in the current track"}};
        changed = cursor.trySetStaffIndex(unsigned(value));
    } else if (axis == "voice") {
        if (value > 3) return {{"error", "voice index must be 0..3"}};
        cursor.setVoiceIndex(unsigned(value));
        changed = true;
    } else return {{"error", "axis must be track, staff, bar, voice or beat"}};
    const int observed = cursorState(document.score).value(axis).toInt(-1);
    if (!changed || observed != int(value)) return {{"error", "Native cursor rejected or clamped the requested index"}, {"cursor", cursorState(document.score)}};
    return {{"document", document.id()}, {"cursor", cursorState(document.score)}};
}
inline std::shared_ptr<gp::core::Beat> selectionBeat(gp::core::Score *score, const QJsonValue &endpoint) {
    if (!endpoint.isObject()) return {};
    const auto object = endpoint.toObject();
    if (object.size() != 5) return {};
    for (const char *key : {"track", "staff", "bar", "voice", "beat"}) {
        const auto value = object.value(key);
        if (!value.isDouble() || value.toDouble() < 0 || value.toDouble() > 100000 || std::floor(value.toDouble()) != value.toDouble()) return {};
    }
    const int track = object.value("track").toInt(), staff = object.value("staff").toInt(), bar = object.value("bar").toInt();
    const int voice = object.value("voice").toInt(), beat = object.value("beat").toInt();
    const auto &tracks = score->tracks();
    if (size_t(track) >= tracks.size() || !tracks[track]) return {};
    const auto &staves = tracks[track]->staves();
    if (size_t(staff) >= staves.size() || !staves[staff]) return {};
    const auto &bars = staves[staff]->bars();
    if (size_t(bar) >= bars.size() || !bars[bar] || bars[bar]->isSimileBar()) return {};
    const auto &voices = static_cast<const gp::core::Bar &>(*bars[bar]).voices();
    if (size_t(voice) >= voices.size() || !voices[voice]) return {};
    const auto &beats = voices[voice]->beats();
    return size_t(beat) < beats.size() ? beats[beat] : nullptr;
}
struct BeatSelection {
    std::vector<std::shared_ptr<gp::core::Beat>> beats;
    QJsonArray positions;
    std::vector<std::unique_ptr<gp::core::ScoreModelRange>> ranges;
    int placeholders = 0;
};
inline QString collectBeatSelection(gp::core::Score *score, BeatSelection &output) {
    const auto &range = score->cursor().selectionRange();
    const auto &lower = range.lowerModelIndex(), &upper = range.upperModelIndex();
    const int first = lower.barIndex(), last = upper.barIndex();
    const auto &tracks = score->tracks();
    if (!range.isMultiSelection() || first < 0 || last < first || last - first >= 128 || tracks.size() > 1024)
        return "An explicit selection of at most 128 bars and a score of at most 1024 tracks are required";
    if (lower.trackIndex() != upper.trackIndex() || lower.staffIndex() != upper.staffIndex() || lower.voiceIndex() != upper.voiceIndex())
        return "Selection endpoints must share a track, staff and voice";
    if (lower.trackIndex() < 0 || size_t(lower.trackIndex()) >= tracks.size() || lower.voiceIndex() >= 4)
        return "Selection track or voice is unavailable";
    struct Candidate { std::shared_ptr<gp::core::Beat> beat; int track, staff, bar, voice, index; };
    std::vector<Candidate> candidates;
    const bool allTracks = range.isMultiTrack(), allVoices = allTracks || range.isMultiVoice();
    // Bound the real model before asking the native iterator to allocate. That
    // iterator maps voices by musical time, but never expands across tracks.
    for (size_t t = 0; t < tracks.size(); ++t) {
        if (!allTracks && int(t) != lower.trackIndex()) continue;
        if (!tracks[t]) return "Selection contains an unavailable track";
        const auto &staves = tracks[t]->staves();
        if (!allTracks && lower.staffIndex() >= staves.size()) return "Selection staff is unavailable";
        for (size_t s = 0; s < staves.size(); ++s) {
            if (!allTracks && s != lower.staffIndex()) continue;
            if (!staves[s] || size_t(last) >= staves[s]->bars().size()) return "Selection contains an unavailable staff or bar";
            for (unsigned v = 0; v < 4; ++v) {
                if (!allVoices && v != lower.voiceIndex()) continue;
                for (int b = first; b <= last; ++b) {
                    const auto &bar = staves[s]->bars()[b];
                    if (!bar || bar->isSimileBar()) return "Selection contains unavailable or simile bars";
                    const auto &voice = static_cast<const gp::core::Bar &>(*bar).voices()[v];
                    if (!voice) continue;
                    const auto &beats = voice->beats();
                    for (size_t k = 0; k < beats.size(); ++k) {
                        if (!beats[k] || candidates.size() >= 20000) return "Selection bar region contains unavailable beats or exceeds 20000 beats";
                        candidates.push_back({beats[k], int(t), int(s), b, int(v), int(k)});
                    }
                }
            }
        }
    }
    QSet<gp::core::Beat *> selected;
    if (!allTracks) {
        for (auto *beat : gp::core::flatten::beats(range)) {
            if (!beat || selected.contains(beat)) return "Native selection contains null or duplicate beats";
            selected.insert(beat);
        }
    }
    std::vector<Candidate> targets;
    for (const auto &candidate : candidates) {
        if (!allTracks && !selected.remove(candidate.beat.get())) continue;
        if (candidate.beat->isPlaceholder()) {
            if (!candidate.beat->isRest() || !candidate.beat->notes().empty()) return "Unexpected musical content in a placeholder";
            ++output.placeholders;
        } else targets.push_back(candidate);
    }
    if (!selected.empty()) return "Native selection escaped the inspected bar region";
    for (size_t start = 0; start < targets.size();) {
        size_t end = start + 1;
        const auto &a = targets[start];
        while (end < targets.size() && targets[end].track == a.track && targets[end].staff == a.staff && targets[end].voice == a.voice) ++end;
        const auto &z = targets[end - 1];
        const gp::core::ScoreModelIndex from(score->modelPrivate().get(), a.track, a.bar, a.index, unsigned(a.voice), unsigned(a.staff));
        const gp::core::ScoreModelIndex to(score->modelPrivate().get(), z.track, z.bar, z.index, unsigned(z.voice), unsigned(z.staff));
        auto part = std::make_unique<gp::core::ScoreModelRange>(from, to, 1u, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
        const auto native = gp::core::flatten::beats(*part);
        if (native.size() != end - start) return "Selection cannot be represented without gaps or interior placeholders";
        for (size_t i = start; i < end; ++i) {
            const auto &item = targets[i];
            if (native[i - start] != item.beat.get()) return "Native single-voice edit range differs from selected beats";
            output.beats.push_back(item.beat);
            output.positions.append(QJsonObject{{"track", item.track}, {"staff", item.staff}, {"bar", item.bar}, {"voice", item.voice}, {"beat", item.index}});
        }
        output.ranges.push_back(std::move(part));
        start = end;
    }
    return {};
}
inline QJsonObject selection(const QJsonObject &args, const QList<QPointer<QObject>> &objects) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Choose a document with a verified native score"}};
    const QString operation = args.value("operation").toString("state");
    QSet<QString> allowed{"document", "operation"};
    if (operation == "range") allowed.unite({"base", "extent", "all_voices", "all_tracks"});
    else if (operation == "note") allowed.unite({"base", "note_index"});
    else if (operation == "all") allowed.unite({"all_voices", "all_tracks"});
    else if (operation != "state" && operation != "beats" && operation != "clear") return {{"error", "operation must be state, beats, range, note, all or clear"}};
    for (auto it = args.begin(); it != args.end(); ++it)
        if (!allowed.contains(it.key())) return {{"error", "Argument does not apply to this selection operation: " + it.key()}};
    auto &cursor = document.score->cursor();
    if (operation == "state") return {{"document", document.id()}, {"cursor", cursorState(document.score)}};
    if (operation == "beats") {
        BeatSelection targets;
        const auto error = collectBeatSelection(document.score, targets);
        if (!error.isEmpty()) return {{"error", error}};
        return {{"document", document.id()}, {"beats", targets.positions}, {"count", int(targets.beats.size())},
            {"skipped_placeholders", targets.placeholders}, {"cursor", cursorState(document.score)}};
    }
    const bool allTracks = args.value("all_tracks").toBool(), allVoices = args.value("all_voices").toBool();
    if (allTracks && args.contains("all_voices") && !allVoices) return {{"error", "All-track selection includes all voices"}};
    const auto base = args.value("base").toObject(), extent = args.value("extent").toObject();
    std::shared_ptr<gp::core::Beat> baseBeat, extentBeat;
    std::shared_ptr<const gp::core::Note> note;
    if (operation == "range" || operation == "note") {
        baseBeat = selectionBeat(document.score, args.value("base"));
        if (!baseBeat) return {{"error", "base requires exactly five existing integer indices: track, staff, bar, voice, beat; simile bars are unsupported"}};
        if (operation == "range") {
            extentBeat = selectionBeat(document.score, args.value("extent"));
            if (!extentBeat) return {{"error", "extent requires exactly five existing integer indices: track, staff, bar, voice, beat; simile bars are unsupported"}};
            for (const char *key : {"track", "staff", "voice"})
                if (base.value(key) != extent.value(key)) return {{"error", "Range endpoints must use the same track, staff and voice; use all_voices or all_tracks to expand"}};
        } else {
            const int index = args.value("note_index").toInt(-1);
            if (index < 0 || size_t(index) >= baseBeat->notes().size() || !baseBeat->notes()[index]) return {{"error", "note_index must identify an existing element of gp_read_bars notes"}};
            note = baseBeat->notes()[index];
        }
    }
    if (document.score->tracks().empty() || !cursor.staff()) return {{"error", "Selection requires a current staff"}};
    gp::core::ScoreCursor candidate;
    candidate.copy(cursor);
    if (&candidate.selectionRange() == &cursor.selectionRange() || &candidate.selectionRange().baseModelIndex() == &cursor.selectionRange().baseModelIndex())
        return {{"error", "Native cursor copy shares selection storage"}};
    candidate.endMultiSelection();
    // Only mutate the independently owned copy. The host cursor is committed
    // through moveToCursorAndNotify, which updates native observers.
    auto &candidateRange = const_cast<gp::core::ScoreModelRange &>(candidate.selectionRange());
    candidateRange.setSelectionModes(0);
    candidate.setMultiVoice(allVoices);
    if (operation == "range") {
        const gp::core::ScoreModelIndex from(document.score->modelPrivate().get(), base.value("track").toInt(), base.value("bar").toInt(), base.value("beat").toInt(),
            unsigned(base.value("voice").toInt()), unsigned(base.value("staff").toInt()));
        const gp::core::ScoreModelIndex to(document.score->modelPrivate().get(), extent.value("track").toInt(), extent.value("bar").toInt(), extent.value("beat").toInt(),
            unsigned(extent.value("voice").toInt()), unsigned(extent.value("staff").toInt()));
        if (from.beat() != baseBeat || to.beat() != extentBeat) return {{"error", "Native endpoint mapping differs from requested beats"}};
        candidate.select(from, to);
        if (candidateRange.baseModelIndex().beat() != baseBeat || candidateRange.extentModelIndex().beat() != extentBeat)
            return {{"error", "Native selection normalized the requested endpoints; original cursor was retained"}};
    } else if (operation == "note") candidate.selectNote(note, 0); // The verified export ignores its final integer.
    else if (operation == "all") candidate.selectAll();
    if (allTracks) candidate.selectMultiTrack();
    if ((operation == "range" || operation == "all") && !candidateRange.isMultiSelection())
        return {{"error", "Native selection found no selectable range; original cursor was retained"}};
    candidate.setLastUserSelectionRange(candidateRange);
    const auto expected = selectionState(candidate);
    const auto activated = activate(QJsonObject{{"document", document.id()}}, objects);
    if (activated.contains("error")) return activated;
    cursor.moveToCursorAndNotify(candidate, nullptr);
    QJsonObject result{{"document", document.id()}, {"cursor", cursorState(document.score)}, {"index_base", 0}};
    // Notification can fill the cursor's note fields from its visual staff line.
    const auto observed = selectionState(cursor);
    bool matched = expected.value("native_modes") == observed.value("native_modes");
    for (const char *end : {"base", "extent"})
        for (const char *axis : {"track", "staff", "bar", "voice", "beat"})
            matched = matched && expected.value(end).toObject().value(axis) == observed.value(end).toObject().value(axis);
    if (note) matched = matched && cursor.modelIndex().note() == note;
    if (!matched) result["error"] = "Native selection readback differs; inspect returned cursor before retrying";
    return result;
}
inline QStringList slideKinds() {
    return {"Shift", "Legato", "OutDownwards", "OutUpwards", "InFromBelow", "InFromAbove",
        "OutDownwardsPickScrape", "OutUpwardsPickScrape"};
}
inline double harmonicFretValue(int index) {
    return std::round(gp::core::Harmonic::fretToFloat(static_cast<gp::core::Harmonic::Fret>(index)) * 10.0) / 10.0;
}
inline QJsonObject noteState(const gp::core::Note &note) {
    QJsonArray slides;
    const auto names = slideKinds();
    for (int i = 0; i < names.size(); ++i) if (note.slideFlags() & (1u << i)) slides.append(names[i]);
    const int harmonicFret = int(note.harmonicFret());
    const QJsonObject harmonic{{"type", note.isHarmonic() ? QString::fromStdString(gp::core::Harmonic::typeToString(note.harmonicType())) : "None"},
        {"fret", note.isHarmonic() && harmonicFret >= 0 && harmonicFret < 17 ? QJsonValue(harmonicFretValue(harmonicFret)) : QJsonValue()}};
    return {{"string", int(note.string())}, {"fret", note.fret()}, {"midi", note.midi()}, {"accidental", int(note.accidental())},
        {"tie", QJsonObject{{"origin", note.isTieOrigin()}, {"destination", note.isTieDestination()}}},
        {"effects", QJsonObject{{"palm_mute", note.isPalmMuted()}, {"let_ring", note.hasLetRing()},
            {"harmonic", harmonic}, {"slide", QJsonObject{{"flags", int(note.slideFlags())}, {"kinds", slides},
                {"valid", note.isSlideValid()}, {"shift_destination", note.isShiftSlideDestination()},
                {"legato_destination", note.isLegatoSlideDestination()}}},
            {"left_hand_tapping", note.isLeftHandTapped()}, {"right_hand_tapping", note.isTapped()},
            {"vibrato", QString::fromStdString(gp::core::vibratoToString(note.vibrato()))},
            {"anti_accent", QString::fromStdString(gp::core::antiAccentToString(note.antiAccent()))},
            {"left_fingering", QString::fromStdString(gp::core::fingeringToString(note.leftHandFingering()))},
            {"right_fingering", QString::fromStdString(gp::core::fingeringToString(note.rightHandFingering()))}}}};
}
inline QJsonObject tupletState(const gp::core::RhythmValue &rhythm) {
    QJsonObject result;
    for (int i = 0; i < 2; ++i) {
        const auto level = static_cast<gp::core::TupletLevel>(i);
        const auto &ratio = rhythm.getTupletRatio(level);
        result[i == 0 ? "primary" : "secondary"] = QJsonObject{{"enabled", rhythm.hasTuplet(level)},
            {"actual", int(ratio.first)}, {"normal", int(ratio.second)}};
    }
    return result;
}
inline QJsonObject readBarsForScore(const gp::core::Score *score, const QJsonObject &args) {
    if (!score) return {{"error", "Native score unavailable"}};
    const int trackIndex = args.value("track").toInt(0), staffIndex = args.value("staff").toInt(0);
    const int from = args.value("bar").toInt(0), count = args.value("count").toInt(1);
    if (trackIndex < 0 || staffIndex < 0 || from < 0 || count < 1 || count > 16) return {{"error", "Indices must be nonnegative; count must be 1..16"}};
    const auto &tracks = score->tracks();
    if (size_t(trackIndex) >= tracks.size() || !tracks[trackIndex]) return {{"error", "Track does not exist"}};
    const auto &staves = tracks[trackIndex]->staves();
    if (size_t(staffIndex) >= staves.size() || !staves[staffIndex]) return {{"error", "Staff does not exist"}};
    const auto &bars = staves[staffIndex]->bars();
    if (size_t(from) >= bars.size() || size_t(from) + count > bars.size()) return {{"error", "Requested bar range does not exist"}};
    QJsonArray output;
    int inspected = 0;
    for (int b = from; b < from + count; ++b) {
        if (!bars[b]) return {{"error", "Native bar is missing"}};
        QJsonArray voices;
        const auto &nativeVoices = static_cast<const gp::core::Bar &>(*bars[b]).voices();
        for (size_t v = 0; v < nativeVoices.size(); ++v) {
            if (!nativeVoices[v]) continue;
            QJsonArray beats;
            const auto &nativeBeats = nativeVoices[v]->beats();
            for (size_t k = 0; k < nativeBeats.size(); ++k) {
                if (!nativeBeats[k] || ++inspected > 20000) return {{"error", "Read bound reached; request fewer bars"}};
                const auto &beat = *nativeBeats[k];
                QJsonArray notes;
                for (const auto &note : beat.notes()) {
                    if (!note || ++inspected > 20000) return {{"error", "Read bound reached; request fewer bars"}};
                    notes.append(noteState(*note));
                }
                beats.append(QJsonObject{{"index", int(k)}, {"rest", beat.isRest()}, {"placeholder", beat.isPlaceholder()}, {"rhythm", beat.rhythm().toQString()},
                    {"native_note_value", int(beat.rhythm().getNoteValue())}, {"dots", int(beat.rhythm().getAugmentationDot())},
                    {"tuplets", tupletState(beat.rhythm())},
                    {"legato", QJsonObject{{"origin", beat.isLegatoOrigin()}, {"destination", beat.isLegatoDestination()}}}, {"notes", notes}});
            }
            voices.append(QJsonObject{{"index", int(v)}, {"beats", beats}});
        }
        output.append(QJsonObject{{"index", b}, {"voices", voices}});
    }
    return {{"track", trackIndex}, {"staff", staffIndex}, {"bars", output}, {"index_base", 0},
        {"scope", "Live notes, pitch, fret, string, rhythm, tuplets, legato, ties, rests, tapping, palm mute, let ring, vibrato, anti-accent and fingering; other notation/effects not yet exposed"}};
}
inline QJsonObject readBars(const QJsonObject &args) {
    const Document document = choose(args);
    auto result = readBarsForScore(document.score, args);
    if (document.view) result["document"] = document.id();
    return result;
}
inline std::shared_ptr<gp::core::MasterBar> masterBar(gp::core::Score *score, unsigned index) {
    const auto master = score->masterTrack();
    if (!master || index >= master->masterBarCount()) return {};
    const auto bar = master->masterBar(index);
    if (!bar || discovery::type(reinterpret_cast<quintptr>(bar.get())) != ".?AVMasterBar@core@gp@@" ||
        bar->index() != index || bar->model() != score->modelPrivate().get()) return {};
    return bar;
}
inline QJsonObject masterBarState(gp::core::Score *score, unsigned index) {
    const auto bar = masterBar(score, index);
    if (!bar) return {{"error", "Native master bar is missing or failed validation"}};
    const auto &time = bar->timeSignature();
    const auto &key = bar->concertKeySignature();
    return {{"index", int(index)}, {"time_signature", QJsonObject{{"numerator", int(time.getNumerator())}, {"denominator", int(time.getDenominator())}}},
        {"key_signature", QJsonObject{{"accidentals", key.accidentalCount()}, {"major", key.isMajor()}, {"native_label", key.toQString()}}},
        {"repeat_start", bar->hasRepeatStart()}, {"repeat_end", bar->hasRepeatEnd()}, {"repeat_count", int(bar->repeatCount())},
        {"double_bar", bar->hasDoubleBar()}, {"free_time", bar->hasFreeTime()}};
}
inline QJsonObject readMasterBars(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const int from = args.value("bar").toInt(0), count = args.value("count").toInt(1);
    const auto master = document.score->masterTrack();
    if (!master || from < 0 || count < 1 || count > 128 || unsigned(from) >= master->masterBarCount() ||
        unsigned(count) > master->masterBarCount() - unsigned(from)) return {{"error", "Existing master bar range required; count must be 1..128"}};
    QJsonArray bars;
    for (int i = from; i < from + count; ++i) {
        const auto bar = masterBarState(document.score, unsigned(i));
        if (bar.contains("error")) return bar;
        bars.append(bar);
    }
    return {{"document", document.id()}, {"bars", bars}, {"bar_count", int(master->masterBarCount())},
        {"scope", "Score-wide master bars; key signatures use concert pitch"}, {"index_base", 0}};
}
inline QJsonObject editMeasure(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const QString operation = args.value("operation").toString();
    QSet<QString> allowed{"document", "operation"};
    if (operation == "time_signature") allowed.unite({"numerator", "denominator"});
    else if (operation == "key_signature") allowed.unite({"accidentals", "major"});
    else if (operation == "repeat_end") allowed.unite({"enabled", "repeat_count"});
    else if (operation == "repeat_start" || operation == "double_bar" || operation == "free_time") allowed.insert("enabled");
    else return {{"error", "Unknown measure operation"}};
    for (auto it = args.begin(); it != args.end(); ++it) if (!allowed.contains(it.key())) return {{"error", "Argument does not apply to this operation: " + it.key()}};
    const int numerator = args.value("numerator").toInt(0), denominator = args.value("denominator").toInt(0);
    const int accidentals = args.value("accidentals").toInt(-100), repeats = args.value("repeat_count").toInt(2);
    const bool enabled = args.value("enabled").toBool();
    if (operation == "time_signature" && (numerator < 1 || numerator > 64 || denominator < 1 || denominator > 128 || (denominator & (denominator - 1))))
        return {{"error", "Time signature requires numerator 1..64 and denominator 1,2,4,8,16,32,64,128"}};
    if (operation == "key_signature" && (accidentals < -7 || accidentals > 7 || !args.value("major").isBool()))
        return {{"error", "Key signature requires accidentals -7..7 (negative means flats) and major boolean"}};
    if (allowed.contains("enabled") && !args.value("enabled").isBool()) return {{"error", "enabled boolean required"}};
    if (operation == "repeat_end" && ((enabled && (repeats < 2 || repeats > 100)) || (!enabled && args.contains("repeat_count"))))
        return {{"error", "Enabled repeat end accepts repeat_count 2..100 (default 2); disabled repeat end accepts no count"}};
    auto &cursor = document.score->cursor();
    const int index = cursor.barIndex();
    if (index < 0) return {{"error", "Cursor must point to a master bar"}};
    const auto before = masterBarState(document.score, unsigned(index));
    if (before.contains("error")) return before;
    gp::core::ScoreModelRange range(cursor.modelIndex(), 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
    // Explicit selection prevents the host from extending signatures to later bars.
    range.setMultiSelection(true);
    if (range.barCount() != 1 || !range.isMultiSelection()) return {{"error", "Cannot construct a native single-bar selection"}};
    QJsonObject expected = before;
    if (operation == "time_signature") {
        expected["time_signature"] = QJsonObject{{"numerator", numerator}, {"denominator", denominator}};
        if (expected != before) {
            const auto time = gp::core::TimeSignature::fromValues(unsigned(numerator), unsigned(denominator));
            document.score->setMasterBarTimeSignature(range, true, time);
        }
    } else if (operation == "key_signature") {
        const gp::core::KeySignature key(accidentals, args.value("major").toBool());
        expected["key_signature"] = QJsonObject{{"accidentals", accidentals}, {"major", args.value("major").toBool()}, {"native_label", key.toQString()}};
        if (expected != before) document.score->setMasterBarKeySignature(range, true, key, true);
    } else {
        expected[operation] = enabled;
        if (operation == "repeat_end" && enabled) expected["repeat_count"] = repeats;
        if (expected != before) {
            if (operation == "repeat_start") document.score->setBarRepeatStart(range, enabled);
            else if (operation == "repeat_end") document.score->setBarRepeatEnd(range, enabled, enabled ? repeats : 0);
            else if (operation == "double_bar") document.score->setMasterBarDoubleBar(range, enabled);
            else document.score->setMasterBarFreeTime(range, enabled);
        }
    }
    const auto after = masterBarState(document.score, unsigned(index));
    if (after != expected) return {{"error", "Native measure readback differs; inspect master bars before retrying"}, {"observed", after}};
    return {{"document", document.id()}, {"bar", after}, {"dirty", document.object->property("isDirty").toBool()},
        {"undo_available", document.score->undoAvailable()}};
}
inline QJsonObject setFret(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const int string = args.value("string").toInt(-1), fret = args.value("fret").toInt(-1);
    if (string < 0 || string > 15 || fret < 0 || fret > 36) return {{"error", "string must be 0..15 and fret 0..36"}};
    auto &cursor = document.score->cursor();
    auto beat = cursor.beat();
    if (!beat) return {{"error", "Cursor has no existing beat"}};
    for (const auto &note : beat->notes()) {
        if (!note || note->string() != unsigned(string)) continue;
        if (note->fret() < 0) return {{"error", "Selected note has no guitar fret"}};
        if (note->fret() != fret) document.score->setStringedNoteFret(cursor.modelIndex(), unsigned(string), fret, note->accidental());
        const auto updated = cursor.beat();
        if (updated) for (const auto &value : updated->notes()) {
            if (value && value->string() == unsigned(string) && value->fret() == fret)
                return {{"document", document.id()}, {"cursor", cursorState(document.score)}, {"note", noteState(*value)},
                    {"dirty", document.object->property("isDirty").toBool()}};
        }
        return {{"error", "Native fret readback differs; inspect score before retrying"}};
    }
    return {{"error", "No existing note on that string at the cursor; this tool does not create notes"}};
}
inline bool singleBeatRange(const gp::core::ScoreModelRange &range, gp::core::ScoreCursor &cursor, bool allowEmpty = false) {
    return range.barCount() == 1 && !range.isMultiTrack() && !range.isMultiVoice() &&
        ((range.beatCount() == 1 && !range.isPlaceholder()) || (allowEmpty && range.beatCount() <= 1)) &&
        range.baseModelIndex().beat() == cursor.beat();
}
inline QJsonObject editConnection(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const QString kind = args.value("kind").toString(), scope = args.value("scope").toString("cursor");
    if ((kind != "legato" && kind != "tie") || (scope != "cursor" && scope != "selection") || !args.value("enabled").isBool())
        return {{"error", "kind must be legato or tie; scope must be cursor or selection; enabled must be boolean"}};
    if (args.contains("string") && (kind != "tie" || scope != "cursor")) return {{"error", "string is supported only for a cursor tie"}};
    auto &cursor = document.score->cursor();
    gp::core::ScoreModelRange single(cursor.modelIndex(), 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
    const auto &range = scope == "selection" ? cursor.selectionRange() : single;
    BeatSelection batch;
    if (scope == "selection") {
        const auto error = collectBeatSelection(document.score, batch);
        if (!error.isEmpty()) return {{"error", error}};
        if (batch.beats.empty()) return {{"error", "Selection contains no real beats"}};
    } else {
        if (!singleBeatRange(single, cursor)) return {{"error", "Cursor must point to a real beat"}};
        batch.beats.push_back(cursor.beat());
        batch.positions.append(QJsonObject{{"track", cursor.trackIndex()}, {"staff", int(cursor.staffIndex())},
            {"bar", cursor.barIndex()}, {"voice", int(cursor.voiceIndex())}, {"beat", cursor.beatIndex()}});
    }
    std::shared_ptr<gp::core::Note> selected;
    if (args.contains("string")) {
        const auto value = args.value("string");
        const int string = value.toInt(-1);
        if (!value.isDouble() || string < 0 || string > 15 || value.toDouble() != string)
            return {{"error", "string must be an integer in 0..15"}};
        for (const auto &note : cursor.beat()->notes()) if (note && note->string() == unsigned(string)) {
            if (selected) return {{"error", "String identifies multiple notes; choose an unambiguous stringed note"}};
            selected = note;
        }
        if (!selected) return {{"error", "No note on that string at the cursor"}};
        single.mutableBaseModelIndex().setNoteString(unsigned(string));
        single.mutableExtentModelIndex().setNoteString(unsigned(string));
        single.mutableBaseModelIndex().setNoteMidi(unsigned(selected->midi()));
        single.mutableExtentModelIndex().setNoteMidi(unsigned(selected->midi()));
        if (single.baseModelIndex().note() != selected) return {{"error", "Cannot construct native single-note range"}};
    }
    const auto beforeCursor = cursorState(document.score);
    const bool enabled = args.value("enabled").toBool();
    auto states = [&]() {
        QJsonArray output;
        for (size_t i = 0; i < batch.beats.size(); ++i) {
            const auto &beat = *batch.beats[i];
            QJsonArray notes;
            for (const auto &note : beat.notes()) if (note) notes.append(noteState(*note));
            auto state = batch.positions[int(i)].toObject();
            state["legato"] = QJsonObject{{"origin", beat.isLegatoOrigin()}, {"destination", beat.isLegatoDestination()}};
            state["notes"] = notes;
            output.append(state);
        }
        return output;
    };
    const auto before = states();
    auto apply = [&](const gp::core::ScoreModelRange &part) {
        if (kind == "legato") document.score->setBeatLegato(part, enabled);
        else if (selected) {
            // SetNoteTied captures Score::cursor in addition to its range.
            // Bind that native context to the requested chord note, then restore it.
            struct RestoreCursor {
                gp::core::ScoreCursor &cursor;
                gp::core::ScoreCursor saved;
                RestoreCursor(gp::core::ScoreCursor &value) : cursor(value) { saved.copy(value); }
                ~RestoreCursor() { cursor.moveToCursorAndNotify(saved, nullptr); }
            } restore(cursor);
            gp::core::ScoreCursor target;
            target.copy(cursor);
            target.endMultiSelection();
            const_cast<gp::core::ScoreModelRange &>(target.selectionRange()).setSelectionModes(0);
            target.setMultiVoice(false);
            target.selectNote(selected, 0);
            cursor.moveToCursorAndNotify(target, nullptr);
            document.score->setNoteTied(part, enabled);
        }
        else document.score->setBeatTied(part, enabled);
    };
    if (scope == "cursor") apply(range);
    else if (batch.ranges.size() == 1) apply(*batch.ranges.front());
    else {
        gp::core::MacroCommandRecorder recorder(document.score, true);
        for (const auto &part : batch.ranges) apply(*part);
        recorder.commit();
    }
    const auto after = states();
    int changed = 0;
    for (int i = 0; i < after.size(); ++i) if (before[i] != after[i]) ++changed;
    return {{"document", document.id()}, {"kind", kind}, {"requested_enabled", enabled},
        {"changed_selected_beats", changed}, {"observed_beats", after}, {"status", "executed"},
        {"cursor", cursorState(document.score)}, {"cursor_preserved", beforeCursor == cursorState(document.score)},
        {"dirty", document.object->property("isDirty").toBool()}, {"undo_available", document.score->undoAvailable()}};
}
inline QJsonObject editNoteEffect(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const QString property = args.value("property").toString();
    QJsonValue value = args.value("value");
    const QSet<QString> toggles{"palm_mute", "let_ring", "left_hand_tapping", "right_hand_tapping"};
    int harmonicType = -1, harmonicFret = -1, slideFlag = 0;
    bool slideEnabled = false;
    QStringList choices;
    if (property == "slide") {
        const auto object = value.toObject();
        const QString kind = object.value("kind").toString();
        const int index = slideKinds().indexOf(kind);
        if (!value.isObject() || (kind != "None" && (index < 0 || !object.value("enabled").isBool())) ||
            object.size() != (kind == "None" ? 1 : 2))
            return {{"error", "slide requires {kind, enabled: boolean}, or {kind: None} to clear all flags"},
                {"kinds", QJsonArray::fromStringList(slideKinds())}};
        slideFlag = index < 0 ? 0 : 1 << index;
        slideEnabled = object.value("enabled").toBool();
    } else if (property == "harmonic") {
        const auto object = value.toObject();
        const QString type = object.value("type").toString();
        for (int i = 0; i < 6; ++i)
            if (type == QString::fromStdString(gp::core::Harmonic::typeToString(static_cast<gp::core::Harmonic::Type>(i)))) harmonicType = i;
        QJsonArray frets;
        for (int i = 0; i < 17; ++i) {
            const double fret = harmonicFretValue(i);
            frets.append(fret);
            if (object.value("fret").isDouble() && object.value("fret").toDouble() == fret) harmonicFret = i;
        }
        if (!value.isObject() || (type != "None" && (harmonicType < 0 || harmonicFret < 0)) ||
            object.size() != (type == "None" ? 1 : 2))
            return {{"error", "harmonic requires {type, fret}, or {type: None}; types: Natural/Artificial/Pinch/Tap/Semi/Feedback"}, {"frets", frets}};
        value = QJsonObject{{"type", type}, {"fret", harmonicType < 0 ? QJsonValue() : QJsonValue(harmonicFretValue(harmonicFret))}};
    } else if (property == "vibrato") for (int i = 0; i <= 2; ++i) choices.append(QString::fromStdString(gp::core::vibratoToString(static_cast<gp::core::Vibrato>(i))));
    else if (property == "anti_accent") for (int i = 0; i <= 3; ++i) choices.append(QString::fromStdString(gp::core::antiAccentToString(static_cast<gp::core::AntiAccent>(i))));
    else if (property == "left_fingering" || property == "right_fingering") for (int i = 0; i <= 6; ++i) choices.append(QString::fromStdString(gp::core::fingeringToString(static_cast<gp::core::Fingering>(i))));
    else if (!toggles.contains(property)) return {{"error", "Unknown note effect property"}};
    const int option = choices.indexOf(value.toString());
    if ((!choices.isEmpty() && (!value.isString() || option < 0)) || (toggles.contains(property) && !value.isBool()))
        return {{"error", "Note effect value has the wrong type or is not a supported choice"}, {"choices", QJsonArray::fromStringList(choices)}};
    const int string = args.value("string").toInt(-1);
    auto &cursor = document.score->cursor();
    const auto beat = cursor.beat();
    const auto staff = cursor.staff();
    if (!beat || beat->isPlaceholder() || !staff || string < 0 || string > 15 || unsigned(string) >= staff->tuning().stringCount())
        return {{"error", "Choose an existing stringed note at the cursor"}};
    std::shared_ptr<gp::core::Note> selected;
    QJsonObject otherNotes;
    for (const auto &note : beat->notes()) if (note) {
        if (note->string() == unsigned(string)) selected = note;
        else otherNotes[QString::number(note->string())] = noteState(*note);
    }
    if (!selected || selected->fret() < 0) return {{"error", "No existing fretted note on that string"}};
    const auto before = noteState(*selected);
    const auto matches = [&](const QJsonObject &state) {
        const auto effect = state.value("effects").toObject().value(property);
        if (property != "slide") return effect == value;
        const int flags = effect.toObject().value("flags").toInt();
        return slideFlag ? bool(flags & slideFlag) == slideEnabled : flags == 0;
    };
    if (!matches(before)) {
        gp::core::ScoreModelRange range(cursor.modelIndex(), 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
        // Mode zero selects one note. Set both local endpoints without changing the UI selection.
        range.mutableBaseModelIndex().setNoteString(unsigned(string));
        range.mutableBaseModelIndex().setNoteMidi(unsigned(selected->midi()));
        range.mutableExtentModelIndex().setNoteString(unsigned(string));
        range.mutableExtentModelIndex().setNoteMidi(unsigned(selected->midi()));
        if (!singleBeatRange(range, cursor) || range.isMultiSelection() || range.baseModelIndex().note() != selected)
            return {{"error", "Cannot construct a native range for the selected note"}};
        const bool enabled = value.toBool();
        if (property == "palm_mute") document.score->setStringedNotePalmMute(range, enabled, false);
        else if (property == "let_ring") document.score->setNoteLetRing(range, enabled, false);
        else if (property == "left_hand_tapping") document.score->setStringedNoteLeftHandTapping(range, enabled);
        else if (property == "right_hand_tapping") document.score->setStringedNoteRightHandTapping(range, enabled);
        else if (property == "vibrato") document.score->setStringedNoteVibrato(range, option != 0, static_cast<gp::core::Vibrato>(option));
        else if (property == "anti_accent") document.score->setNoteAntiAccent(range, option != 0, static_cast<gp::core::AntiAccent>(option));
        else if (property == "left_fingering") document.score->setNoteLeftHandFingering(range, option != 0, static_cast<gp::core::Fingering>(option));
        else if (property == "right_fingering") document.score->setNoteRightHandFingering(range, option != 0, static_cast<gp::core::Fingering>(option));
        else if (property == "slide") {
            // -1 disables native pick-scrape note creation; the selected note must already exist.
            if (slideFlag) document.score->setStringedNoteSlide(range, slideEnabled, static_cast<gp::core::SlideFlag>(slideFlag), -1, -1);
            else document.score->unsetStringedNoteSlide(range);
        } else if (harmonicType < 0) document.score->unsetStringedNoteHarmonic(range);
        else if (harmonicType == 0) document.score->setStringedNoteNaturalHarmonic(range, true, static_cast<gp::core::Harmonic::Fret>(harmonicFret));
        else document.score->setStringedNoteArtificialHarmonic(range, true, static_cast<gp::core::Harmonic::Type>(harmonicType), static_cast<gp::core::Harmonic::Fret>(harmonicFret));
    }
    const auto updated = cursor.beat();
    if (!updated) return {{"error", "Note effect edit left no beat; inspect score before retrying"}};
    QJsonObject after, currentOtherNotes;
    for (const auto &note : updated->notes()) if (note) {
        if (note->string() == unsigned(string)) after = noteState(*note);
        else currentOtherNotes[QString::number(note->string())] = noteState(*note);
    }
    if (!matches(after) || after.value("midi") != before.value("midi") ||
        after.value("fret") != before.value("fret") || currentOtherNotes != otherNotes)
        return {{"error", "Native note effect readback differs; inspect score before retrying"}, {"observed", after}};
    return {{"document", document.id()}, {"note", after}, {"dirty", document.object->property("isDirty").toBool()},
        {"undo_available", document.score->undoAvailable()}};
}
inline QJsonObject editNote(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const QString operation = args.value("operation").toString();
    const int string = args.value("string").toInt(-1), fret = args.value("fret").toInt(-1);
    if (operation != "set" && operation != "remove") return {{"error", "operation must be set or remove"}};
    if (operation == "set" && (fret < 0 || fret > 36)) return {{"error", "set requires fret 0..36"}};
    if (operation == "remove" && args.contains("fret")) return {{"error", "remove does not accept fret"}};
    auto &cursor = document.score->cursor();
    const auto beat = cursor.beat();
    const auto staff = cursor.staff();
    if (!staff || (!beat && operation == "remove")) return {{"error", "Cursor must point to a staff and removal requires an existing beat"}};
    if (string < 0 || string > 15 || unsigned(string) >= staff->tuning().stringCount()) return {{"error", "String does not exist in this staff's tuning"}};
    const gp::core::ScoreModelRange range(cursor.modelIndex(), 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
    if (!singleBeatRange(range, cursor, operation == "set")) return {{"error", "Cannot construct a native single-beat range at the cursor"}};
    std::shared_ptr<gp::core::Note> existing;
    if (beat) for (const auto &note : beat->notes()) if (note && note->string() == unsigned(string)) existing = note;
    if (operation == "set" && existing) return setFret(args);
    if (operation == "remove" && !existing) return {{"status", "unchanged"}, {"document", document.id()}};
    const int expectedMidi = operation == "set" ? staff->midi(unsigned(string), fret) : existing->midi();
    if (operation == "set" && (expectedMidi < 0 || expectedMidi > 127)) return {{"error", "Requested fret is outside MIDI pitch range"}};
    // Native bool is add/remove, followed by string and fret. -3 requests the
    // host's automatic accidental spelling when creating a note.
    document.score->setStringedNote(range, operation == "set", string, operation == "set" ? fret : existing->fret(),
        operation == "set" ? static_cast<am::music::Accidental>(-3) : existing->accidental(), beat && !range.isPlaceholder() ? beat->rhythm() : cursor.nextInsertRhythm());
    const auto updated = cursor.beat();
    if (!updated) return {{"error", "Native note edit left no beat at the cursor; inspect score before retrying"}};
    QJsonArray notes;
    bool matched = operation == "remove";
    for (const auto &note : updated->notes()) if (note) {
        notes.append(noteState(*note));
        if (note->string() == unsigned(string)) matched = operation == "set" && note->fret() == fret && note->midi() == expectedMidi;
    }
    if (!matched) return {{"error", "Native note readback differs; inspect the score before retrying"}};
    return {{"document", document.id()}, {"operation", operation}, {"notes", notes},
        {"rest", updated->isRest()}, {"cursor", cursorState(document.score)}, {"dirty", document.object->property("isDirty").toBool()}};
}
inline QJsonObject editBeat(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score) return {{"error", "Native score unavailable"}};
    const QString operation = args.value("operation").toString();
    const QString scope = args.value("scope").toString("cursor");
    if (scope != "cursor" && scope != "selection") return {{"error", "scope must be cursor or selection"}};
    if (scope == "selection" && operation != "rhythm" && operation != "dots" && operation != "tuplet")
        return {{"error", "Selection editing supports rhythm, dots and tuplet"}};
    for (const char *key : {"level", "actual", "normal", "enabled"})
        if (operation != "tuplet" && args.contains(key)) return {{"error", "Tuplet parameters require operation tuplet"}};
    auto &cursor = document.score->cursor();
    const auto beat = cursor.beat();
    if (!beat && operation != "insert" && scope != "selection") return {{"error", "Cursor must point to an existing beat"}};
    const gp::core::ScoreModelRange single(cursor.modelIndex(), 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
    const auto &range = scope == "selection" ? cursor.selectionRange() : single;
    std::vector<std::shared_ptr<gp::core::Beat>> targets;
    BeatSelection batch;
    if (scope == "selection") {
        const auto error = collectBeatSelection(document.score, batch);
        if (!error.isEmpty()) return {{"error", error}};
        if (batch.beats.empty()) return {{"error", "Selection contains no real beats"}};
        targets = batch.beats;
    } else {
        if (!singleBeatRange(range, cursor, operation == "insert")) return {{"error", "Cannot construct a native single-beat range at the cursor"}};
        if (beat) targets.push_back(beat);
    }
    auto applyToRanges = [&](auto differs, auto apply) {
        std::vector<const gp::core::ScoreModelRange *> changes;
        if (scope == "selection") {
            for (const auto &part : batch.ranges)
                for (auto *target : gp::core::flatten::beats(*part)) if (differs(target)) { changes.push_back(part.get()); break; }
        } else if (differs(beat.get())) changes.push_back(&range);
        if (changes.size() == 1) apply(*changes.front());
        else if (!changes.empty()) {
            // Host commands are queued, then executed on the recorder's
            // committed destruction, producing one native undo entry.
            gp::core::MacroCommandRecorder recorder(document.score, true);
            for (const auto *part : changes) apply(*part);
            recorder.commit();
        }
    };
    const int track = cursor.trackIndex(), staff = int(cursor.staffIndex()), bar = cursor.barIndex();
    if (operation == "tuplet") {
        const QString levelName = args.value("level").toString("primary");
        if (levelName != "primary" && levelName != "secondary") return {{"error", "level must be primary or secondary"}};
        if (args.contains("denominator") || args.contains("dots")) return {{"error", "Tuplet changes preserve note value and dots; edit those separately"}};
        if (args.contains("enabled") && !args.value("enabled").isBool()) return {{"error", "enabled must be a boolean"}};
        const bool enabled = args.value("enabled").toBool(true);
        const int actual = args.value("actual").toInt(), normal = args.value("normal").toInt();
        if (enabled && (!args.value("actual").isDouble() || !args.value("normal").isDouble() ||
            actual < 1 || actual > 255 || normal < 1 || normal > 255 ||
            args.value("actual").toDouble() != actual || args.value("normal").toDouble() != normal || (actual == 1 && normal == 1)))
            return {{"error", "Enabled tuplets require actual and normal integers in 1..255; use enabled=false instead of 1:1"}};
        if (!enabled && (args.contains("actual") || args.contains("normal"))) return {{"error", "Disabling a tuplet does not accept actual or normal"}};
        const auto level = static_cast<gp::core::TupletLevel>(levelName == "primary" ? 0 : 1);
        const gp::core::TupletRatio ratio{static_cast<unsigned char>(enabled ? actual : 0), static_cast<unsigned char>(enabled ? normal : 0)};
        applyToRanges([&](const gp::core::Beat *target) { return target->rhythm().getTupletRatio(level) != ratio; },
            [&](const gp::core::ScoreModelRange &part) { document.score->setBeatTuplet(part, enabled, ratio, level); });
        for (const auto &target : targets)
            if (target->rhythm().getTupletRatio(level) != ratio || target->rhythm().hasTuplet(level) != enabled)
                return {{"error", "Native tuplet readback differs; inspect the score before retrying"}};
    } else if (operation == "insert" || operation == "rhythm" || operation == "dots") {
        const QList<int> values{1, 2, 4, 8, 16, 32, 64, 128};
        const int denominator = args.value("denominator").toInt(0), dots = args.value("dots").toInt(-1);
        const int index = values.indexOf(denominator);
        if (operation == "rhythm" && (index < 0 || args.contains("dots"))) return {{"error", "rhythm requires denominator 1,2,4,8,16,32,64,128; use operation dots separately"}};
        if (operation == "dots" && (dots < 0 || dots > 2 || args.contains("denominator"))) return {{"error", "dots requires dots 0..2 and no denominator"}};
        if (operation == "insert") {
            const int insertDots = args.value("dots").toInt(0);
            if (index < 0 || insertDots < 0 || insertDots > 2) return {{"error", "insert requires a supported denominator and optional dots 0..2"}};
            const gp::core::RhythmValue rhythm(static_cast<gp::core::RhythmValue::Value>(index + 2), insertDots, 0, 0);
            document.score->createBeat(range, rhythm);
        } else if (operation == "rhythm") {
            const gp::core::RhythmValue rhythm(static_cast<gp::core::RhythmValue::Value>(index + 2), 0, 0, 0);
            // The native command changes note value while preserving dots/tuplets.
            applyToRanges([&](const gp::core::Beat *target) { return target->rhythm().getNoteValue() != rhythm.getNoteValue(); },
                [&](const gp::core::ScoreModelRange &part) { document.score->setBeatRhythm(part, rhythm); });
            for (const auto &target : targets)
                if (target->rhythm().getNoteValue() != rhythm.getNoteValue()) return {{"error", "Native rhythm readback differs; inspect the score before retrying"}};
        } else {
            applyToRanges([&](const gp::core::Beat *target) { return target->rhythm().getAugmentationDot() != unsigned(dots); },
                [&](const gp::core::ScoreModelRange &part) { document.score->setNoteAugmentationDot(part, dots != 0, unsigned(dots)); });
            for (const auto &target : targets)
                if (target->rhythm().getAugmentationDot() != unsigned(dots)) return {{"error", "Native dots readback differs; inspect the score before retrying"}};
        }
    } else {
        if (args.contains("denominator") || args.contains("dots")) return {{"error", "Rhythm parameters require operation rhythm"}};
        if (operation == "clear") {
            document.score->clearBeat(cursor.modelIndex());
            if (!beat->notes().empty() || !beat->isRest()) return {{"error", "Native clear readback differs"}};
        } else if (operation == "remove") document.score->removeBeat(cursor.modelIndex());
        else return {{"error", "operation must be insert, rhythm, dots, tuplet, clear or remove"}};
    }
    if (scope == "selection") return {{"document", document.id()}, {"affected_beats", int(targets.size())},
        {"beats", batch.positions}, {"skipped_placeholders", batch.placeholders},
        {"cursor", cursorState(document.score)}, {"dirty", document.object->property("isDirty").toBool()}};
    return readBars(QJsonObject{{"document", document.id()}, {"track", track}, {"staff", staff}, {"bar", bar}});
}
inline QJsonObject editBars(const QJsonObject &args) {
    const Document document = choose(args);
    if (!document.score || document.score->tracks().empty()) return {{"error", "Native score with tracks required"}};
    const QString operation = args.value("operation").toString();
    const int index = args.value("index").toInt(-1), count = args.value("count").toInt(1);
    const unsigned before = document.score->tracks().front()->barCount();
    if (index < 0 || unsigned(index) > before || count < 1 || count > 128 || before > 100000)
        return {{"error", "Valid bar index and count 1..128 required; score must have at most 100000 bars"}};
    if (operation == "insert") {
        if (before + unsigned(count) > 100000) return {{"error", "Result would exceed 100000 bars"}};
        document.score->createBars(unsigned(index), unsigned(count));
    }
    else if (operation == "remove") {
        if (unsigned(index) >= before || unsigned(count) > before - unsigned(index)) return {{"error", "Requested removal range does not exist"}};
        document.score->removeBarRange(unsigned(index), unsigned(index + count - 1));
    } else return {{"error", "operation must be insert or remove"}};
    QJsonObject result = scoreState(args);
    const unsigned expected = operation == "insert" ? before + unsigned(count) : qMax(1u, before - unsigned(count));
    for (const auto &track : document.score->tracks())
        if (!track || track->barCount() != expected) result["error"] = "Native bar count readback differs; inspect score before retrying";
    result["previous_bar_count"] = int(before);
    result["operation"] = operation;
    result["index"] = index;
    result["count"] = count;
    return result;
}
inline QJsonObject playback(const QJsonObject &args, const QList<QPointer<QObject>> &objects) {
    static const bool rseVerified = hash(QDir(QCoreApplication::applicationDirPath()).filePath("GPRSE.dll")) ==
        "e983122951b94c2513a1f05828dd03dcb11620ddc50f6b497723cae0eb32ba6a";
    if (!rseVerified) return {{"error", "Playback ABI disabled on unverified GPRSE build"}};
    const Document document = choose(args);
    if (!document.score) return {{"error", "Choose a document with a verified native score"}};
    gp::rse::ConductorController *controller = nullptr;
    QPointer<QObject> controllerObject;
    for (const auto &guard : objects) {
        QObject *object = guard.data();
        if (!object) continue;
        if (QByteArray(object->metaObject()->className()) != "gp::rse::ConductorController" ||
            discovery::type(reinterpret_cast<quintptr>(object)) != ".?AVConductorController@rse@gp@@") continue;
        auto candidate = reinterpret_cast<gp::rse::ConductorController *>(object);
        const auto &conductor = candidate->conductor();
        if (!conductor || conductor->score().get() != document.score) continue;
        if (controller && controller != candidate) return {{"error", "More than one playback controller matches this score"}};
        controller = candidate; controllerObject = object;
    }
    if (!controller) return {{"error", "No native playback controller is bound to this document; activate it with gp_activate first"}};
    const QString operation = args.value("operation").toString("state");
    if (operation == "play") controller->play();
    else if (operation == "stop") controller->stop();
    else if (operation == "seek") {
        const int bar = args.value("bar").toInt(-1), tick = args.value("tick").toInt(0);
        const auto &conductor = controller->conductor();
        if (bar < 0 || unsigned(bar) >= conductor->barCount() || tick < 0) return {{"error", "Invalid playback bar or tick"}};
        const auto nativeBar = masterBar(document.score, unsigned(bar));
        if (!nativeBar || nativeBar->tickCount() <= 0 || tick >= nativeBar->tickCount() || conductor->tickOffset(unsigned(bar)) < 0)
            return {{"error", "Tick offset lies outside this score bar, or bar is absent from playback"}};
        controller->seek(unsigned(bar), tick);
    } else if (operation == "seek_tick") {
        const int tick = args.value("tick").toInt(-1);
        if (args.contains("bar") || args.contains("enabled") || tick < 0 || tick >= controller->conductor()->tickCount())
            return {{"error", "seek_tick requires tick in 0..total_ticks-1 and accepts no bar or enabled parameter"}};
        controller->seek(tick);
    } else if (operation == "set_loop" || operation == "set_metronome" || operation == "set_countdown") {
        if (!args.value("enabled").isBool()) return {{"error", "enabled boolean required"}};
        const bool enabled = args.value("enabled").toBool();
        if (operation == "set_loop") controller->setLoopEnabled(enabled);
        else if (operation == "set_metronome") controller->setMetronomeEnabled(enabled);
        else controller->setCountdownEnabled(enabled);
    } else if (operation != "state") return {{"error", "Unknown playback operation"}};
    if (!controllerObject || !document.view) return {{"error", "Document or playback controller was closed during the operation"}};
    const auto &conductor = controller->conductor();
    return {{"document", document.id()}, {"requested", operation}, {"status", operation == "state" ? "observed" : "requested; poll state for completion"}, {"playing", controller->isPlaying()},
        {"loop", controller->isLoopEnabled()}, {"metronome", controller->metronome().isEnabled()},
        {"countdown", controller->metronome().isCountdownEnabled()}, {"counting_down", controller->isCountingDown()},
        {"countdown_bars", int(controller->metronome().countdownBarCount())}, {"metronome_volume", controller->metronomeVolume()},
        {"tick", conductor->tickOffset()}, {"total_ticks", conductor->tickCount()}, {"score_bar_count", int(conductor->barCount())}, {"frame", double(conductor->frameOffset())},
        {"source", "Native GPRSE ConductorController matched to the document Score"}};
}
inline QJsonObject save(const QJsonObject &args, bool adopt = false, bool current = false) {
    const Document chosen = choose(args);
    if (!chosen.object || !chosen.view) return {{"error", "Choose an existing document id from gp_documents"}};
    const QString oldPath = chosen.object->property("saveFilePath").toString();
    const bool dirtyBefore = chosen.object->property("isDirty").toBool();
    const QString path = current ? oldPath : args.value("path").toString();
    const QFileInfo destination(path);
    if (path.isEmpty() || !destination.isAbsolute() || destination.fileName().contains(':') || destination.suffix().toLower() != "gp" || !destination.absoluteDir().exists()) return {{"error", "Specify an absolute .gp output path in an existing directory"}};
    const QString absolute = destination.absoluteFilePath();
    auto samePath = [&](const QString &other) {
        if (other.isEmpty()) return false;
        const QFileInfo candidate(other);
        const QString left = destination.exists() ? destination.canonicalFilePath() : QDir::cleanPath(absolute);
        const QString right = candidate.exists() ? candidate.canonicalFilePath() : QDir::cleanPath(candidate.absoluteFilePath());
        return left.compare(right, Qt::CaseInsensitive) == 0;
    };
    for (const auto &document : documents()) {
        if (samePath(document.object->property("saveFilePath").toString()) || samePath(document.object->property("openedFilePath").toString())) {
            if (document.object != chosen.object) return {{"error", "Destination belongs to another open document"}};
            if (!adopt) return {{"error", "Use gp_save_current to save the open document, or choose a separate copy path"}};
        }
    }
    const bool existed = destination.exists();
    if (existed && !current && !args.value("overwrite").toBool()) return {{"error", "Destination exists; explicitly set overwrite=true"}};
    if (existed && (!destination.isFile() || destination.isSymLink())) return {{"error", "Destination must be a regular file, not a directory or link"}};
    const int copyMethod = chosen.object->metaObject()->indexOfMethod("saveToFile(QString)");
    if (copyMethod < 0 || (adopt && (chosen.object->metaObject()->indexOfMethod("save()") < 0 || chosen.object->metaObject()->indexOfMethod("setSaveFilePath(QString)") < 0)))
        return {{"error", "Native document save methods are unavailable"}};
    // Preserve existing bytes before the host writes, and retain the backup if
    // recovery cannot finish. All files stay on the destination volume.
    QTemporaryDir recovery(destination.absolutePath() + "/.gpmcp-save-XXXXXX");
    if (!recovery.isValid()) return {{"error", "Cannot create a recovery directory beside the destination"}};
    const QString backup = recovery.filePath("original.gp");
    if (existed && !QFile::copy(absolute, backup)) return {{"error", "Cannot back up the existing destination"}};
    QFile probe(absolute);
    if (!probe.open(existed ? QIODevice::ReadWrite : QIODevice::WriteOnly | QIODevice::NewOnly))
        return {{"error", "Destination is not writable: " + probe.errorString()}};
    probe.close();
    if (!existed && !probe.remove()) return {{"error", "Cannot release the new destination before native saving"}};
    auto recover = [&](const QString &message) {
        bool restored = false;
        if (existed) {
            QFile source(backup);
            QSaveFile output(absolute);
            if (source.open(QIODevice::ReadOnly) && output.open(QIODevice::WriteOnly)) {
                bool copied = true;
                while (!source.atEnd()) {
                    const QByteArray bytes = source.read(1024 * 1024);
                    if (source.error() != QFileDevice::NoError || output.write(bytes) != bytes.size()) { copied = false; break; }
                }
                restored = copied && output.commit();
            }
        } else restored = !QFileInfo::exists(absolute) || QFile::remove(absolute);
        const bool pathRestored = chosen.object &&
            (chosen.object->property("saveFilePath").toString() == oldPath ||
             (QMetaObject::invokeMethod(chosen.object, "setSaveFilePath", Qt::DirectConnection, Q_ARG(QString, oldPath)) && chosen.object->property("saveFilePath").toString() == oldPath));
        if (dirtyBefore && chosen.object && !chosen.object->property("isDirty").toBool())
            QMetaObject::invokeMethod(chosen.object, "setIsDirty", Qt::DirectConnection, Q_ARG(bool, true));
        QJsonObject result{{"error", message}, {"file_restored", restored}, {"save_path_restored", pathRestored}, {"dirty_before", dirtyBefore},
            {"dirty_state_restored", chosen.object && chosen.object->property("isDirty").toBool() == dirtyBefore},
            {"dirty", chosen.object ? QJsonValue(chosen.object->property("isDirty").toBool()) : QJsonValue()}};
        if (!restored && existed) { recovery.setAutoRemove(false); result["recovery_path"] = backup; }
        return result;
    };
    bool saved = false;
    if (!chosen.object->metaObject()->method(copyMethod).invoke(chosen.object, Qt::DirectConnection, Q_RETURN_ARG(bool, saved), Q_ARG(QString, absolute)) || !saved)
        return recover("Native copy save did not report success; inspect recovery and document state before retrying");
    if (adopt) {
        bool committed = false;
        if (!chosen.object || !QMetaObject::invokeMethod(chosen.object, "setSaveFilePath", Qt::DirectConnection, Q_ARG(QString, absolute)) ||
            !QMetaObject::invokeMethod(chosen.object, "save", Qt::DirectConnection, Q_RETURN_ARG(bool, committed)) ||
            !committed || !chosen.object || chosen.object->property("isDirty").toBool())
            return recover("Native document save did not complete; inspect recovery and document state before retrying");
    }
    const QFileInfo output(absolute);
    if (!output.isFile() || !output.size()) return recover("Native save returned without a completed file");
    const QString validation = validateGpFile(absolute);
    if (!validation.isEmpty()) return recover("Native output validation failed: " + validation);
    return {{"path", absolute}, {"bytes", double(output.size())}, {"document", chosen.id()},
        {"copy_only", !adopt}, {"overwrote", existed}, {"dirty", chosen.object->property("isDirty").toBool()},
        {"native_method", adopt ? "IDocument::saveToFile, setSaveFilePath, save" : "IDocument::saveToFile(QString)"}};
}
}

