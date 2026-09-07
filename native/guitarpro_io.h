#pragma once
#include "guitarpro_audio.h"
#include <QtCore/QDataStream>
#include <QtCore/QCoreApplication>
#include <QtCore/qscopeguard.h>
#include <QtPrintSupport/QPrinter>
#include <QtGui/QPainter>
#include <QtGui/QImage>

namespace guitarpro {
inline QJsonObject presentation(const QJsonObject &args) {
    const auto document = choose(args);
    if (!document.object || !document.score) return {{"error", "Existing native document required"}};
    const QString operation = args.value("operation").toString("state");
    auto style = document.score->newStylesheet();
    if (!style) return {{"error", "Native stylesheet unavailable"}};
    auto resultState = [&]() {
        const auto size = gp::core::style::pageLayoutSizeValue(*style);
        const auto margins = gp::core::style::pageLayoutMarginsValue(*style);
        const auto orientation = gp::core::style::pageLayoutOrientationValue(*style);
        QJsonObject state{{"width", size.width}, {"height", size.height}, {"left", margins.left},
            {"top", margins.top}, {"right", margins.right}, {"bottom", margins.bottom},
            {"orientation", orientation == gp::core::style::generated::PageLayout::Orientation::Landscape ? "landscape" : "portrait"}};
        QJsonArray tracks;
        for (int i = 0; i < int(document.score->trackCount()); ++i)
            tracks.append(QJsonObject{{"track", i}, {"standard_notation", document.score->hasStdNotation(i)}, {"tablature", document.score->hasTablature(i)}});
        state["tracks"] = tracks;
        if (document.view) {
            state["zoom"] = QJsonValue::fromVariant(document.view->property("zoom"));
            state["design_mode"] = QJsonValue::fromVariant(document.view->property("designMode"));
            state["multivoice_edition"] = QJsonValue::fromVariant(document.view->property("multivoiceEdition"));
        }
        return state;
    };
    if (operation == "state") return {{"document", document.id()}, {"scope", "document"}, {"state", resultState()}, {"undoable", false}};
    if (operation != "set") return {{"error", "operation must be state or set"}};
    const bool pageChange = args.contains("width") || args.contains("height") || args.contains("left") || args.contains("top") || args.contains("right") || args.contains("bottom") || args.contains("orientation");
    const bool viewChange = args.contains("zoom") || args.contains("design_mode") || args.contains("multivoice_edition");
    const bool trackChange = args.contains("track");
    if ((pageChange ? 1 : 0) + (viewChange ? 1 : 0) + (trackChange ? 1 : 0) != 1)
        return {{"error", "Set one presentation group at a time: page, view, or track"}};
    for (const char *name : {"design_mode", "multivoice_edition", "standard_notation", "tablature"})
        if (args.contains(name) && !args.value(name).isBool()) return {{"error", "Presentation flags must be boolean"}};
    if ((args.contains("standard_notation") || args.contains("tablature")) && !trackChange) return {{"error", "Choose a track for notation changes"}};
    if (viewChange && int(args.contains("zoom")) + int(args.contains("design_mode")) + int(args.contains("multivoice_edition")) != 1)
        return {{"error", "Set one view property at a time"}};
    if (pageChange) {
        auto copy = std::make_shared<gp::core::style::Stylesheet>(*style);
        const auto old = resultState();
        const auto number = [&](const char *name, double fallback) {
            if (!args.contains(name)) return fallback;
            const auto value = args.value(name);
            return value.isDouble() && std::isfinite(value.toDouble()) ? value.toDouble() : std::numeric_limits<double>::quiet_NaN();
        };
        const auto width = number("width", old.value("width").toDouble());
        const auto height = number("height", old.value("height").toDouble());
        const auto left = number("left", old.value("left").toDouble());
        const auto top = number("top", old.value("top").toDouble());
        const auto right = number("right", old.value("right").toDouble());
        const auto bottom = number("bottom", old.value("bottom").toDouble());
        if (!(width >= 50 && width <= 1000 && height >= 50 && height <= 1000 && left >= 0 && top >= 0 && right >= 0 && bottom >= 0 && left + right + 20 <= width && top + bottom + 20 <= height))
            return {{"error", "Page sides must be 50..1000 mm; nonnegative margins must leave at least 20 mm of content per axis"}};
        gp::core::style::setPageLayoutSize(*copy, am::painting::Size{width, height});
        gp::core::style::setPageLayoutMargins(*copy, am::painting::Margins{left, top, right, bottom});
        if (args.contains("orientation")) {
            const auto value = args.value("orientation").toString();
            if (value != "portrait" && value != "landscape") return {{"error", "orientation must be portrait or landscape"}};
            gp::core::style::setPageLayoutOrientation(*copy, value == "landscape" ? std::optional<gp::core::style::generated::PageLayout::Orientation>(gp::core::style::generated::PageLayout::Orientation::Landscape) : std::optional<gp::core::style::generated::PageLayout::Orientation>(gp::core::style::generated::PageLayout::Orientation::Portrait));
        }
        bool changed = false;
        for (const char *name : {"width", "height", "left", "top", "right", "bottom", "orientation"})
            if (args.contains(name) && args.value(name) != old.value(name)) changed = true;
        if (!changed) return {{"document", document.id()}, {"scope", "document"}, {"state", old}, {"undoable", false}};
        *style = *copy;
        QMetaObject::invokeMethod(document.object, "setIsDirty", Qt::DirectConnection, Q_ARG(bool, true));
        if (document.view) document.view->update();
    }
    if (args.contains("zoom") || args.contains("design_mode") || args.contains("multivoice_edition")) {
        if (!document.view) return {{"error", "Document view unavailable"}};
        const QList<QPair<const char *, int>> fields{{"zoom", QMetaType::Double}, {"design_mode", QMetaType::Bool}, {"multivoice_edition", QMetaType::Bool}};
        for (const auto &field : fields) if (args.contains(field.first)) {
            const auto input = args.value(field.first);
            QVariant value = input.toVariant();
            const char *property = std::strcmp(field.first, "zoom") == 0 ? "zoom" : std::strcmp(field.first, "design_mode") == 0 ? "designMode" : "multivoiceEdition";
            if (field.second == QMetaType::Double && (!input.isDouble() || !std::isfinite(input.toDouble()) || input.toDouble() < 0.25 || input.toDouble() > 4))
                return {{"error", "zoom must be a number from 0.25 to 4"}};
            const bool written = field.second == QMetaType::Double
                ? QMetaObject::invokeMethod(document.view, "setScoreZoom", Qt::DirectConnection, Q_ARG(double, input.toDouble()), Q_ARG(bool, false))
                : document.view->setProperty(property, value);
            if (!written)
                return {{"error", "Document presentation property could not be written"}};
        }
    }
    if (trackChange) {
        const int trackIndex = args.value("track").toInt(-1);
        const auto tracks = document.score->tracks();
        if (trackIndex < 0 || trackIndex >= int(tracks.size()) || !tracks[trackIndex]) return {{"error", "track is outside the document"}};
        auto &track = *tracks[trackIndex];
        if (!args.contains("standard_notation") && !args.contains("tablature")) return {{"error", "Choose a notation property"}};
        const bool standard = args.value("standard_notation").toBool(document.score->hasStdNotation(trackIndex));
        const bool tab = args.value("tablature").toBool(document.score->hasTablature(trackIndex));
        if (!standard && !tab) return {{"error", "Keep at least one notation visible"}};
        if (args.contains("standard_notation")) document.score->setStdNotation(track, args.value("standard_notation").toBool());
        if (args.contains("tablature")) document.score->setTablature(track, args.value("tablature").toBool());
    }
    const auto state = resultState();
    QJsonObject result{{"document", document.id()}, {"scope", "document"}, {"state", state}, {"undoable", false}, {"status", "observed"}};
    for (const char *name : {"zoom", "design_mode", "multivoice_edition"})
        if (args.contains(name) && args.value(name) != state.value(name)) {
            result["status"] = "requested";
            result["requested"] = QJsonObject{{name, args.value(name)}};
        }
    return result;
}
inline bool ioSupported() {
    static const bool verified = supportedBuild() && verifiedHostFile("AMUtils.dll") && verifiedHostFile("GPIO.dll") && verifiedHostFile("AMPainting.dll") && verifiedHostFile("Qt5PrintSupport.dll");
    return verified;
}
inline QJsonObject fileFormats() {
    if (!ioSupported()) return {{"error", "File conversion requires the verified host"}};
    auto &core = gp::core::Core::instance();
    QJsonArray imports, exports;
    if (core.importersCount() > 64 || core.exportersCount() > 64) return {{"error", "Unexpected native format count"}};
    for (unsigned i = 0; i < core.importersCount(); ++i)
        imports.append(QJsonObject{{"name", core.importerDescription(i)}, {"extensions", QJsonArray::fromStringList(core.importerExtensions(i))}});
    for (unsigned i = 0; i < core.exportersCount(); ++i) {
        QJsonArray extensions;
        for (const auto &extension : core.exporterExtensions(i)) extensions.append(QString::fromStdString(extension));
        exports.append(QJsonObject{{"name", QString::fromStdString(core.exporterDescription(i))}, {"extensions", extensions}});
    }
    return {{"importers", imports}, {"exporters", exports},
        {"export_extensions", QJsonArray{"gp5", "gpx", "xml", "musicxml", "mid", "wav", "pdf", "png"}},
        {"native_save_tool", "gp_save"}, {"print_target", "PDF via native QPrinter"}};
}

// These non-exported routines are reached by the verified host's own MIDI
// export command. The writer owns only a vtable and an implementation pointer.
struct NativeMidiWriter {
    quintptr storage[2]{};
    explicit NativeMidiWriter(const gp::core::Score *score) {
        reinterpret_cast<void (*)(void *, const gp::core::Score *)>(quintptr(GetModuleHandleW(nullptr)) + 0xc53de0)(this, score);
    }
    ~NativeMidiWriter() {
        reinterpret_cast<void (*)(void *)>(quintptr(GetModuleHandleW(nullptr)) + 0xc541d0)(this);
    }
    void save(const QString &path) {
        reinterpret_cast<void (*)(void *, const QString &)>(quintptr(GetModuleHandleW(nullptr)) + 0xc58f60)(this, path);
    }
};
inline QJsonObject renderWave(const Document &document, const QString &path, const QList<QPointer<QObject>> &objects,
                              const std::function<bool()> &cancelled) {
    auto controller = audioController(document, objects);
    if (!controller || controller->isPlaying() || controller->isCountingDown()) return {{"error", "A stopped native audio document is required"}};
    constexpr qint64 limit = 30 * 60 * 44100;
    if (controller->conductor()->frameCount() > limit) return {{"error", "WAV export is limited to 30 minutes"}};
    gp::rse::AudioExportManager renderer(controller->conductor()->score());
    renderer.setExportMetronome(false); renderer.setExportCountdown(false); renderer.setExportSelection(false);
    renderer.prepareConductorForEncoding({});
    if (renderer.soundingLengthInFrames() <= 0 || renderer.soundingLengthInFrames() > limit)
        return {{"error", "Native audio length is outside the 30-minute bound"}};
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) return {{"error", file.errorString()}};
    QDataStream out(&file); out.setByteOrder(QDataStream::LittleEndian);
    out.writeRawData("RIFF", 4); out << quint32(0); out.writeRawData("WAVEfmt ", 8);
    out << quint32(16) << quint16(1) << quint16(2) << quint32(44100) << quint32(176400) << quint16(4) << quint16(16);
    out.writeRawData("data", 4); out << quint32(0);
    std::vector<float> left, right;
    qint64 frames = 0;
    while (true) {
        QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents, 5);
        if (cancelled()) return {{"cancelled", true}};
        const auto count = renderer.processFrame(left, right);
        if (!count) break;
        if (count > left.size() || count > right.size() || frames + count > limit)
            return {{"error", "Native audio buffer exceeds the export bound"}};
        for (unsigned i = 0; i < count; ++i) for (float sample : {left[i], right[i]}) {
            if (!std::isfinite(sample)) return {{"error", "Native audio contains a nonfinite sample"}};
            out << qint16(std::lround(qBound(-1.0f, sample, 1.0f) * 32767));
        }
        frames += count;
        if (out.status() != QDataStream::Ok) return {{"error", "Cannot write WAV samples"}};
    }
    if (!frames || !file.seek(4)) return {{"error", "Empty audio or WAV header write failure"}};
    out << quint32(36 + frames * 4);
    if (!file.seek(40)) return {{"error", "Cannot finalize WAV data length"}};
    out << quint32(frames * 4);
    if (out.status() != QDataStream::Ok || !file.flush()) return {{"error", "Cannot finalize WAV file"}};
    return {{"frames", double(frames)}, {"sample_rate", 44100}, {"channels", 2}, {"seconds", double(frames) / 44100}};
}
inline QJsonObject exportFile(const QJsonObject &args, const QList<QPointer<QObject>> &objects, const std::function<bool()> &cancelled) {
    if (!ioSupported()) return {{"error", "File conversion requires the verified host"}};
    const auto document = choose(args);
    if (!document.object || !document.score) return {{"error", "Existing native document required"}};
    const QFileInfo destination(args.value("path").toString());
    const QString extension = destination.suffix().toLower();
    const QSet<QString> supported{"gp5", "gpx", "xml", "musicxml", "mid", "wav", "pdf", "png"};
    if (!destination.isAbsolute() || destination.fileName().contains(':') || !destination.absoluteDir().exists() || !supported.contains(extension))
        return {{"error", "Use an absolute gp5/gpx/xml/musicxml/mid/wav/pdf/png path in an existing directory"}};
    if (args.contains("page") && (extension != "png" || !args.value("page").isDouble() || args.value("page").toDouble() != args.value("page").toInt() || args.value("page").toInt() < 1))
        return {{"error", "page is a positive integer for PNG output only"}};
    if (args.contains("overwrite") && !args.value("overwrite").isBool()) return {{"error", "overwrite must be boolean"}};
    const bool existed = destination.exists();
    if (destination.isSymLink() || (existed && !destination.isFile())) return {{"error", "Destination must be a regular file"}};
    if (existed && !args.value("overwrite").toBool()) return {{"error", "Destination exists; explicitly set overwrite=true"}};
    const auto identity = [](const QFileInfo &file) { return file.exists() ? file.canonicalFilePath() : file.absoluteFilePath(); };
    for (const auto &other : documents()) for (const char *property : {"openedFilePath", "saveFilePath"}) {
        const QString path = localDocumentPath(other.object->property(property).toString());
        if (!path.isEmpty() && identity(QFileInfo(path)).compare(identity(destination), Qt::CaseInsensitive) == 0)
            return {{"error", "Export destination belongs to an open document"}};
    }
    const QByteArray original = existed ? hash(destination.absoluteFilePath()) : QByteArray();
    if (existed && original.isEmpty()) return {{"error", "Cannot read the existing destination"}};
    QTemporaryDir staging(destination.absolutePath() + "/.gpmcp-export-XXXXXX");
    if (!staging.isValid()) return {{"error", "Cannot create an export directory beside the destination"}};
    const QString path = staging.filePath("output." + extension);
    QJsonObject result;
    QJsonArray warnings;
    if (extension == "mid") {
        NativeMidiWriter writer(document.score); writer.save(path);
    } else if (extension == "wav") {
        result = renderWave(document, path, objects, cancelled);
    } else if (extension == "pdf" || extension == "png") {
        const quintptr host = quintptr(GetModuleHandleW(nullptr));
        gp::core::ScoreView view;
        view.applyModel(document.score->activeView());
        gp::core::style::Stylesheet style(std::shared_ptr<gp::core::style::Stylesheet>{});
        style.applyModel(document.score->newStylesheet());
        gp::core::style::Stylesheet::setupStyleForExport(style);
        gp::core::style::setPageLayoutBackgroundColor(style, am::painting::Color{255, 255, 255, 255});
        auto rendering = reinterpret_cast<std::shared_ptr<void> (*)()>(host + 0x94bba0)();
        const auto context = quintptr(rendering.get());
        if (discovery::type(context) != ".?AVScoreEngravingContext@renderer@gp@@") return {{"error", "Native print context unavailable"}};
        reinterpret_cast<void (*)(void *, gp::core::ScoreView *)>(host + 0x957700)(rendering.get(), &view);
        reinterpret_cast<void (*)(void *, int)>(host + 0x9576b0)(rendering.get(), 0);
        reinterpret_cast<void (*)(void *, int)>(host + 0x957670)(rendering.get(), 2);
        reinterpret_cast<void (*)(void *, gp::core::style::Stylesheet *)>(host + 0x957ca0)(rendering.get(), &style);
        reinterpret_cast<void (*)(void *, bool)>(host + 0x9573e0)(rendering.get(), false);
        reinterpret_cast<void (*)(void *, bool)>(host + 0x95d080)(rendering.get(), true);
        quintptr first = 0, last = 0;
        if (!discovery::read(context + 0x138, first) || !discovery::read(context + 0x140, last) ||
            last <= first || (last - first) % 0xd0 || (last - first) / 0xd0 > 256)
            return {{"error", "Native page layout is unavailable or exceeds 256 pages"}};
        const int pages = int((last - first) / 0xd0);
        result["pages"] = pages;
        if (extension == "png") {
            const int page = args.value("page").toInt(1);
            if (page < 1 || page > pages) return {{"error", "page is outside the document"}, {"pages", pages}};
            const auto imported = [host](quintptr rva) { return *reinterpret_cast<quintptr *>(host + rva); };
            const auto pageView = reinterpret_cast<void *>(first + (page - 1) * 0xd0);
            const auto rect = reinterpret_cast<const double *(*)(void *)>(imported(0xe373a0))(pageView);
            constexpr double dpi = 144;
            const int width = int(std::ceil(rect[2] * dpi / 25.4)), height = int(std::ceil(rect[3] * dpi / 25.4));
            if (width < 1 || height < 1 || qint64(width) * height > 64000000) return {{"error", "Page exceeds 64 million pixels"}};
            QImage bitmap(width, height, QImage::Format_RGB32);
            if (bitmap.isNull()) return {{"error", "Cannot allocate page image"}};
            bitmap.fill(Qt::white);
            bitmap.setDotsPerMeterX(int(dpi / 0.0254)); bitmap.setDotsPerMeterY(int(dpi / 0.0254));
            QPainter painter(&bitmap); painter.setRenderHints(QPainter::Antialiasing | QPainter::TextAntialiasing);
            // Verified native printing uses a 24-byte Qt adapter, an 8-byte
            // AM painter, and a 16-byte score painter, destroyed in reverse order.
            quintptr adapter[3]{}, amPainter[1]{}, scorePainter[2]{};
            reinterpret_cast<void (*)(void *, QPainter *)>(host + 0xc14630)(adapter, &painter);
            const auto releaseAdapter = qScopeGuard([&]() { reinterpret_cast<void (*)(void *)>(host + 0xc148a0)(adapter); });
            reinterpret_cast<void (*)(void *, double)>(host + 0xc164f0)(adapter, dpi);
            reinterpret_cast<void (*)(void *, void *)>(imported(0xe307d0))(amPainter, adapter);
            const auto releaseAm = qScopeGuard([&]() { reinterpret_cast<void (*)(void *)>(imported(0xe307d8))(amPainter); });
            const auto rendererStyle = reinterpret_cast<void *(*)(void *)>(host + 0x95a6c0)(rendering.get());
            reinterpret_cast<void (*)(void *, void *, void *, float, bool, int)>(host + 0x997a90)(scorePainter, rendererStyle, amPainter, 1.0f, true, 0);
            const auto releaseScore = qScopeGuard([&]() { reinterpret_cast<void (*)(void *)>(host + 0x997c80)(scorePainter); });
            const double translation[2]{-rect[0], -rect[1]};
            reinterpret_cast<void (*)(void *, const void *)>(imported(0xe307e0))(amPainter, translation);
            const auto vtable = *reinterpret_cast<quintptr **>(rendering.get());
            reinterpret_cast<void (*)(void *, void *, const void *)>(vtable[0x90 / 8])(rendering.get(), scorePainter, rect);
            reinterpret_cast<void (*)(void *)>(imported(0xe307e8))(amPainter);
            painter.end();
            if (!bitmap.save(path, "PNG")) return {{"error", "Cannot write PNG page"}};
            result["page"] = page; result["width"] = width; result["height"] = height;
        } else {
        QPrinter printer(QPrinter::HighResolution);
        printer.setOutputFormat(QPrinter::PdfFormat); printer.setOutputFileName(path);
        printer.setCreator("GuitarProMCP"); printer.setResolution(144);
        reinterpret_cast<void (*)(void *, QPrinter *, int)>(host + 0xd2ad0)(rendering.get(), &printer, 0);
        if (printer.printerState() == QPrinter::Error || printer.printerState() == QPrinter::Aborted)
            return {{"error", "Native printing failed"}};
        }
    } else {
        auto &core = gp::core::Core::instance();
        auto exporter = core.exporterByExtension(extension.toStdString());
        if (!exporter || !core.fileSystem()) return {{"error", "Native converter unavailable"}};
        auto handle = core.fileSystem()->openHandle(path, am::filesystem::FileSystem::Mode::Write);
        if (!handle) return {{"error", "Native output file cannot be opened"}};
        const bool saved = exporter->saveFile(*handle, *document.score);
        for (const auto &warning : exporter->warnings()) warnings.append(QString::fromStdString(warning));
        if (!saved) return {{"error", "Native converter failed"}, {"warnings", warnings}};
    }
    if (result.contains("error") || result.value("cancelled").toBool()) return result;
    QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents, 5);
    if (cancelled()) return {{"cancelled", true}};
    QFile source(path);
    if (!source.open(QIODevice::ReadOnly) || source.size() < 1) return {{"error", "Native export produced no file"}};
    if (QFileInfo::exists(destination.absoluteFilePath()) != existed || (existed && hash(destination.absoluteFilePath()) != original))
        return {{"error", "Destination changed during export; output was not committed"}};
    QSaveFile output(destination.absoluteFilePath());
    if (!output.open(QIODevice::WriteOnly)) return {{"error", output.errorString()}};
    while (!source.atEnd()) {
        const auto bytes = source.read(1024 * 1024);
        if (source.error() != QFileDevice::NoError || output.write(bytes) != bytes.size()) return {{"error", "Cannot commit exported file"}};
    }
    if (!output.commit()) return {{"error", output.errorString()}};
    result["path"] = destination.absoluteFilePath(); result["document"] = document.id();
    result["bytes"] = double(source.size()); result["sha256"] = QString::fromLatin1(hash(destination.absoluteFilePath()));
    result["warnings"] = warnings;
    return result;
}
}
