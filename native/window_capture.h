#pragma once
#include <QtCore/QBuffer>
#include <QtCore/QDateTime>
#include <QtCore/QElapsedTimer>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonObject>
#include <QtCore/QMap>
#include <QtCore/QPointer>
#include <QtCore/QRegularExpression>
#include <QtCore/QSet>
#include <QtGui/QPainter>
#include <QtGui/QScreen>
#include <QtGui/QWindow>
#include <QtWidgets/QApplication>
#include <QtWidgets/QWidget>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

// GUI-thread only. Identity belongs to a QObject lifetime, independently of
// gp_objects snapshots, window titles, native handles and MCP clients.
class WindowCapture {
    const QString instance;
    quint64 sequence = 0;
    QMap<quint64, QPointer<QObject>> identities;
    QList<QObject *> current;
    QHash<QWindow *, QWidget *> widgets;
    QStringList limitations;
    static constexpr int MaxWindows = 512, MaxScan = 20000;
    static constexpr qint64 MaxDimension = 4096, MaxPixels = 16 * 1024 * 1024, MaxEncodedBytes = 8 * 1024 * 1024;

    // Windows draws the title bar and resize border outside QWidget's paint
    // tree.  Keep this path in-process and read-only: WM_PRINT asks the
    // existing native window to paint only its non-client area into a DIB.
    // The client area is still rendered by QWidget::render below and then
    // composited into the native frame.  No handle is created for a hidden
    // widget; internalWinId() is deliberately used instead of winId().
    static bool captureNativeFrame(QWidget *target, QImage *frame, QPoint *clientOffset, QSize *clientSize,
                                   QString *reason, QString *error) {
#if !defined(Q_OS_WIN)
        Q_UNUSED(target); Q_UNUSED(frame); Q_UNUSED(clientOffset); Q_UNUSED(clientSize);
        if (reason) *reason = "platform_unsupported";
        if (error) *error = "Native title-bar capture is only available on Windows";
        return false;
#else
        if (!target->isWindow()) {
            if (reason) *reason = "not_top_level";
            if (error) *error = "Only a top-level QWidget has a system title bar";
            return false;
        }
        const auto flags = target->windowFlags();
        if (flags.testFlag(Qt::FramelessWindowHint)) {
            if (reason) *reason = "not_applicable";
            return true;
        }
        const HWND hwnd = reinterpret_cast<HWND>(target->internalWinId());
        if (!hwnd || !IsWindow(hwnd)) {
            if (reason) *reason = "frame_handle_unavailable";
            if (error) *error = "The QWidget has no existing native window handle";
            return false;
        }
        const LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        if (!(style & (WS_CAPTION | WS_BORDER | WS_THICKFRAME))) {
            if (reason) *reason = "not_applicable";
            return true;
        }
        RECT windowRect{}, clientRect{};
        if (!GetWindowRect(hwnd, &windowRect) || !GetClientRect(hwnd, &clientRect)) {
            if (reason) *reason = "frame_geometry_unavailable";
            if (error) *error = "Windows could not read the native window geometry";
            return false;
        }
        POINT origin{0, 0};
        if (!ClientToScreen(hwnd, &origin)) {
            if (reason) *reason = "frame_geometry_unavailable";
            if (error) *error = "Windows could not map the client area to screen coordinates";
            return false;
        }
        const int width = windowRect.right - windowRect.left;
        const int height = windowRect.bottom - windowRect.top;
        const int clientWidth = clientRect.right - clientRect.left;
        const int clientHeight = clientRect.bottom - clientRect.top;
        if (width <= 0 || height <= 0 || clientWidth <= 0 || clientHeight <= 0 ||
            origin.x < windowRect.left || origin.y < windowRect.top ||
            origin.x + clientWidth > windowRect.right || origin.y + clientHeight > windowRect.bottom) {
            if (reason) *reason = "frame_geometry_invalid";
            if (error) *error = "Windows returned an invalid native frame or client rectangle";
            return false;
        }
        if (width > MaxDimension || height > MaxDimension || qint64(width) * height > MaxPixels) {
            if (reason) *reason = "dimensions_limit";
            if (error) *error = "Native frame dimensions exceed the screenshot limit";
            return false;
        }
        BITMAPINFO info{};
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height; // top-down DIB
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;
        void *bits = nullptr;
        const HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
        if (!bitmap || !bits) {
            if (bitmap) DeleteObject(bitmap);
            if (reason) *reason = "frame_allocation_failed";
            if (error) *error = "Windows could not allocate a native frame bitmap";
            return false;
        }
        const HDC dc = CreateCompatibleDC(nullptr);
        if (!dc) {
            DeleteObject(bitmap);
            if (reason) *reason = "frame_allocation_failed";
            if (error) *error = "Windows could not allocate a native frame device context";
            return false;
        }
        const HGDIOBJ previous = SelectObject(dc, bitmap);
        if (!previous || previous == HGDI_ERROR) {
            DeleteDC(dc); DeleteObject(bitmap);
            if (reason) *reason = "frame_allocation_failed";
            if (error) *error = "Windows could not select the native frame bitmap";
            return false;
        }
        QImage native(static_cast<uchar *>(bits), width, height, width * 4, QImage::Format_RGB32);
        native.fill(Qt::black);
        const LRESULT painted = SendMessageW(hwnd, WM_PRINT, reinterpret_cast<WPARAM>(dc), PRF_NONCLIENT);
        GdiFlush();
        const QImage copy = native.convertToFormat(QImage::Format_ARGB32_Premultiplied);
        SelectObject(dc, previous);
        DeleteDC(dc);
        DeleteObject(bitmap);
        if (!painted || copy.isNull()) {
            if (reason) *reason = "frame_paint_failed";
            if (error) *error = "Windows could not paint the native title bar";
            return false;
        }
        // A popup or borderless window can legitimately have no non-client
        // pixels.  In that case the client already occupies the full bitmap.
        if (width == clientWidth && height == clientHeight && origin.x == windowRect.left && origin.y == windowRect.top) {
            if (reason) *reason = "not_applicable";
            return true;
        }
        *frame = copy;
        *clientOffset = QPoint(origin.x - windowRect.left, origin.y - windowRect.top);
        *clientSize = QSize(clientWidth, clientHeight);
        return true;
#endif
    }

    static bool windowWidget(QWidget *widget) {
        return (widget->isWindow() || widget->windowType() == Qt::SubWindow) &&
            widget->windowType() != Qt::Desktop && !widget->inherits("QDesktopScreenWidget");
    }
    QString id(QObject *object) {
        if (!object) return {};
        for (auto it = identities.cbegin(); it != identities.cend(); ++it)
            if (it.value() == object) return instance + ":window:" + QString::number(it.key());
        identities.insert(++sequence, QPointer<QObject>(object));
        return instance + ":window:" + QString::number(sequence);
    }
    QJsonValue optionalId(QObject *object) {
        return object && current.contains(object) ? QJsonValue(id(object)) : QJsonValue();
    }
    void discover() {
        for (auto it = identities.begin(); it != identities.end();)
            if (it.value().isNull()) it = identities.erase(it); else ++it;
        current.clear(); widgets.clear(); limitations.clear();
        auto append = [this](QObject *object) {
            if (current.contains(object)) return;
            if (current.size() == MaxWindows) {
                if (!limitations.contains("window_limit_512")) limitations.append("window_limit_512");
                return;
            }
            current.append(object); id(object);
        };
        const auto topLevels = QApplication::topLevelWidgets();
        const auto allWidgets = QApplication::allWidgets();
        if (allWidgets.size() > MaxScan) limitations.append("widget_scan_limit_20000");
        // Include existing handles even for excluded desktop/embedded widgets.
        // windowHandle() is read-only; winId() would create a native window.
        for (auto widget : topLevels) {
            if (widget->windowHandle()) widgets.insert(widget->windowHandle(), widget);
            if (windowWidget(widget)) append(widget);
        }
        for (auto widget : allWidgets.mid(0, MaxScan)) {
            if (widget->windowHandle()) widgets.insert(widget->windowHandle(), widget);
            if (windowWidget(widget)) append(widget);
        }
        const auto allWindows = QGuiApplication::allWindows();
        if (allWindows.size() > MaxScan) limitations.append("qwindow_scan_limit_20000");
        // When the widget scan is incomplete, unknown handles cannot safely be
        // counted again as QWindow-only windows.
        if (allWidgets.size() <= MaxScan) for (auto window : allWindows.mid(0, MaxScan)) {
            if (!widgets.contains(window) && window->type() != Qt::Desktop && window->type() != Qt::ForeignWindow &&
                (window->isTopLevel() || window->type() != Qt::Widget)) append(window);
        }
    }
    QObject *parentWindow(QObject *object) const {
        if (auto widget = qobject_cast<QWidget *>(object)) {
            for (auto parent = widget->parentWidget(); parent; parent = parent->parentWidget())
                if (windowWidget(parent)) return current.contains(parent) ? parent : nullptr;
        }
        auto window = qobject_cast<QWindow *>(object);
        if (!window) if (auto widget = qobject_cast<QWidget *>(object)) window = widget->windowHandle();
        if (!window) return nullptr;
        auto parent = window->transientParent() ? window->transientParent() : window->parent();
        QObject *candidate = widgets.contains(parent) ? static_cast<QObject *>(widgets.value(parent)) : parent;
        return current.contains(candidate) ? candidate : nullptr;
    }
    QObject *activeModal() const {
        if (auto widget = QApplication::activeModalWidget()) return widget;
        auto window = QGuiApplication::modalWindow();
        return widgets.contains(window) ? static_cast<QObject *>(widgets.value(window)) : window;
    }
    QJsonObject state(QObject *object) {
        const auto widget = qobject_cast<QWidget *>(object);
        const auto window = qobject_cast<QWindow *>(object);
        const Qt::WindowType type = widget ? widget->windowType() : window->type();
        const auto modality = widget ? widget->windowModality() : window->modality();
        const auto flags = widget ? widget->windowState() : window->windowStates();
        const bool main = QByteArray(object->metaObject()->className()) == "gp::gui::MainWindow";
        const QString kind = main ? "main" : type == Qt::SubWindow ? "subwindow" :
            type == Qt::Dialog || type == Qt::Sheet ? "dialog" : type == Qt::Tool ? "tool" :
            type == Qt::Popup ? "popup" : type == Qt::ToolTip ? "tooltip" :
            type == Qt::SplashScreen ? "splash" : "window";
        const QPoint position = widget ? widget->mapToGlobal(QPoint()) : window->mapToGlobal(QPoint());
        const QSize size = widget ? widget->size() : window->size();
        const auto screen = window ? window->screen() : nullptr;
        const QString title = widget ? widget->windowTitle() : window->title();
        return {{"window_id", id(object)}, {"parent_window_id", optionalId(parentWindow(object))},
            {"kind", kind}, {"class", object->metaObject()->className()},
            {"object_name", object->objectName().left(256)}, {"title", title.left(1024)},
            {"text_truncated", object->objectName().size() > 256 || title.size() > 1024},
            {"source", widget ? "qwidget" : "qwindow"}, {"qt_window_type", int(type)},
            {"visible", widget ? widget->isVisible() : window->isVisible()},
            {"minimized", flags.testFlag(Qt::WindowMinimized)}, {"maximized", flags.testFlag(Qt::WindowMaximized)},
            {"fullscreen", flags.testFlag(Qt::WindowFullScreen)},
            {"active", widget ? widget->isActiveWindow() : window->isActive()},
            {"modality", modality == Qt::ApplicationModal ? "application_modal" : modality == Qt::WindowModal ? "window_modal" : "non_modal"},
            {"active_modal", object == activeModal()},
            {"geometry", QJsonObject{{"x", position.x()}, {"y", position.y()}, {"width", size.width()}, {"height", size.height()}}},
            {"dpi", QJsonObject{{"x", widget ? double(widget->logicalDpiX()) : screen ? screen->logicalDotsPerInchX() : 0},
                                {"y", widget ? double(widget->logicalDpiY()) : screen ? screen->logicalDotsPerInchY() : 0}}},
            {"device_pixel_ratio", widget ? widget->devicePixelRatioF() : window->devicePixelRatio()}};
    }
    QJsonObject identity() const {
        return {{"instance_id", instance}, {"pid", double(QCoreApplication::applicationPid())}};
    }
public:
    explicit WindowCapture(const QString &instanceId) : instance(instanceId) {}

    QJsonObject enumerate(bool includeHidden = true) {
        discover();
        QJsonArray rows;
        int visible = 0;
        // Stable output order also makes interleaved clients easy to compare.
        for (auto object : identities) if (object && current.contains(object)) {
            const auto row = state(object);
            if (row.value("visible").toBool()) ++visible;
            if (includeHidden || row.value("visible").toBool()) rows.append(row);
        }
        auto result = identity();
        result["scope"] = "qt_windows";
        result["scope_note"] = "Current-instance Qt windows, including hidden and Qt::SubWindow objects; excludes desktop proxies, foreign-window wrappers, ordinary embedded widgets, unconstructed windows, pure system-native and external-process windows.";
        result["total_count"] = current.size(); result["visible_count"] = visible;
        result["hidden_count"] = current.size() - visible; result["returned_count"] = rows.size();
        result["windows"] = rows; result["truncated"] = !limitations.isEmpty();
        result["truncation_reasons"] = QJsonArray::fromStringList(limitations);
        result["count_scope"] = limitations.isEmpty() ? "complete_qt_set" : "observed_subset";
        result["observed_at"] = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
        return result;
    }

    QJsonObject screenshot(const QJsonObject &args) {
        discover();
        auto result = identity();
        auto failure = [&result](const QString &status, const QString &reason, const QString &error) {
            result["status"] = status; result["reason"] = reason; result["error"] = error;
            return result;
        };
        QObject *selected = nullptr;
        if (args.contains("window_id")) {
            const QString requested = args.value("window_id").toString();
            result["window_id"] = requested;
            static const QRegularExpression pattern("\\A([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):window:([1-9][0-9]{0,19})\\z");
            const auto match = pattern.match(requested);
            bool validSequence = false;
            const auto number = match.captured(2).toULongLong(&validSequence);
            if (!args.value("window_id").isString() || !match.hasMatch() || !validSequence)
                return failure("error", "invalid_window_id", "window_id must be a nonempty ID returned by gp_windows");
            if (match.captured(1) != instance)
                return failure("error", "foreign_instance", "window_id belongs to another instance or an earlier host run");
            selected = identities.value(number);
            if (!selected)
                return failure("error", "window_not_found", "Window ID is unknown or its object was destroyed; enumerate again");
            if (!current.contains(selected))
                return failure("error", "window_not_available", "Object is no longer an observed window; enumerate again");
        } else {
            selected = QApplication::activeModalWidget();
            if (!selected) for (auto object : current) {
                const auto widget = qobject_cast<QWidget *>(object);
                if (!widget || QByteArray(widget->metaObject()->className()) != "gp::gui::MainWindow") continue;
                if (!selected || widget->isVisible()) selected = widget;
                if (widget->isVisible()) break;
            }
        }
        result["active_modal_window_id"] = optionalId(activeModal());
        if (!selected) return failure("host_limited", "no_window", "No Guitar Pro main window or active modal dialog is available");
        const auto record = state(selected);
        for (auto it = record.begin(); it != record.end(); ++it) result[it.key()] = it.value();
        result["target_window"] = record.value("active_modal").toBool() ? "active_modal" : record.value("kind") == "main" ? "main" : "window";
        result["target_class"] = record.value("class"); result["target_object_name"] = record.value("object_name");
        const bool includeFrame = args.value("include_frame").toBool(false);
        result["frame_requested"] = includeFrame;
        result["capture_mode"] = "qt_widget_render";
        QPointer<QWidget> target = qobject_cast<QWidget *>(selected);
        if (!target) return failure("host_limited", "qwindow_render_unsupported", "QWindow-only content has no verified QWidget rendering path");
        auto children = target->findChildren<QWidget *>();
        if (children.size() > MaxScan) return failure("host_limited", "render_scan_limit", "Too many child widgets to verify the rendering path");
        children.prepend(target);
        for (auto child : children) {
            // Independent top-level children are excluded by QWidget::render.
            if (child != target && child->window() != target->window()) continue;
            if (child != target && !child->isVisibleTo(target)) continue;
            if (child->testAttribute(Qt::WA_PaintOnScreen) || child->inherits("QOpenGLWidget") ||
                child->inherits("QQuickWidget") || child->inherits("QWindowContainer"))
                return failure("host_limited", "special_rendering", "Target contains native or GPU content without a verified QWidget rendering path");
            if (child != target && child->windowType() == Qt::SubWindow)
                return failure("host_limited", "embedded_subwindow", "QWidget rendering would include another independent SubWindow; capture that window by ID");
        }
        const QSize logicalSize = target->size();
        const qreal ratio = target->devicePixelRatioF();
        const qint64 pixelWidth = qRound64(logicalSize.width() * ratio), pixelHeight = qRound64(logicalSize.height() * ratio);
        if (pixelWidth <= 0 || pixelHeight <= 0 || pixelWidth > MaxDimension || pixelHeight > MaxDimension || pixelWidth * pixelHeight > MaxPixels)
            return failure("host_limited", "dimensions_limit", "Window dimensions are unavailable or exceed the screenshot limit");
        // QWidget::render prepares hidden widgets and can adjustSize() their
        // top-level window. Never let a read initialize an unlaid-out menu.
        if (!target->isVisible() && (!target->window()->testAttribute(Qt::WA_Resized) || !target->testAttribute(Qt::WA_WState_Polished)))
            return failure("host_limited", "unprepared_hidden_window", "Hidden window layout is not prepared; Qt rendering could resize or polish it");
        QElapsedTimer timer; timer.start();
        QImage nativeFrame;
        QPoint clientOffset;
        QSize nativeClientSize;
        QString frameReason;
        QString frameError;
        bool frameIncluded = false;
        if (includeFrame) {
            if (!captureNativeFrame(target, &nativeFrame, &clientOffset, &nativeClientSize, &frameReason, &frameError))
                return failure("host_limited", frameReason.isEmpty() ? "frame_capture_failed" : frameReason,
                               frameError.isEmpty() ? "Windows could not capture the native title bar" : frameError);
            if (!target) return failure("host_limited", "window_destroyed", "Target was destroyed during native frame rendering");
            if (!nativeFrame.isNull()) {
                if (nativeClientSize != QSize(int(pixelWidth), int(pixelHeight)))
                    return failure("host_limited", "frame_geometry_mismatch", "Native client pixels do not match Qt rendering pixels");
                frameIncluded = true;
            }
        }
        const qint64 outputWidth = frameIncluded ? nativeFrame.width() : pixelWidth;
        const qint64 outputHeight = frameIncluded ? nativeFrame.height() : pixelHeight;
        if (outputWidth <= 0 || outputHeight <= 0 || outputWidth > MaxDimension || outputHeight > MaxDimension || outputWidth * outputHeight > MaxPixels)
            return failure("host_limited", "dimensions_limit", "Window dimensions are unavailable or exceed the screenshot limit");
        result["frame_included"] = frameIncluded;
        result["frame_reason"] = frameIncluded ? "win32_wm_print" : (frameReason.isEmpty() ? "not_requested" : frameReason);
        if (frameIncluded) {
            result["frame_insets"] = QJsonObject{{"left", clientOffset.x()}, {"top", clientOffset.y()},
                                                  {"right", nativeFrame.width() - clientOffset.x() - int(pixelWidth)},
                                                  {"bottom", nativeFrame.height() - clientOffset.y() - int(pixelHeight)}};
            result["client_width"] = pixelWidth; result["client_height"] = pixelHeight;
        }
        QImage image(int(pixelWidth), int(pixelHeight), QImage::Format_ARGB32_Premultiplied);
        if (image.isNull()) return failure("host_limited", "allocation_failed", "Qt could not allocate the screenshot image");
        image.setDevicePixelRatio(ratio); image.fill(Qt::transparent);
        QPainter painter(&image);
        {
            // Qt 5.15 prepareToRender sends deferred geometry events throughout
            // the top-level tree, including unrelated hidden popup windows.
            // Keep those events pending for the host's normal show/layout path.
            struct DeferredGeometry {
                struct Pending { QPointer<QWidget> widget; bool move, resize; };
                QList<Pending> items;
                ~DeferredGeometry() {
                    for (const auto &item : items) if (item.widget) {
                        if (item.move) item.widget->setAttribute(Qt::WA_PendingMoveEvent);
                        if (item.resize) item.widget->setAttribute(Qt::WA_PendingResizeEvent);
                    }
                }
            } deferred;
            auto tree = target->window()->findChildren<QWidget *>();
            tree.prepend(target->window());
            if (tree.size() > MaxScan) return failure("host_limited", "render_scan_limit", "Too many widgets to preserve deferred geometry events");
            for (auto widget : tree) {
                const bool move = widget->testAttribute(Qt::WA_PendingMoveEvent);
                const bool resize = widget->testAttribute(Qt::WA_PendingResizeEvent);
                if (!move && !resize) continue;
                deferred.items.append({widget, move, resize});
                widget->setAttribute(Qt::WA_PendingMoveEvent, false);
                widget->setAttribute(Qt::WA_PendingResizeEvent, false);
            }
            target->render(&painter, QPoint(), QRegion(), QWidget::DrawWindowBackground | QWidget::DrawChildren);
        }
        painter.end();
        if (!target) return failure("host_limited", "window_destroyed", "Target was destroyed during rendering");
        if (frameIncluded) {
            // Native offsets are physical pixels. Avoid applying Qt's device
            // ratio a second time to the inset or shrinking the client image.
            image.setDevicePixelRatio(1);
            QPainter framePainter(&nativeFrame);
            framePainter.setCompositionMode(QPainter::CompositionMode_Source);
            framePainter.drawImage(clientOffset, image);
            framePainter.end();
            nativeFrame.setDevicePixelRatio(ratio);
            image = nativeFrame;
            result["capture_mode"] = "qt_widget_render_with_win32_frame";
        }
        QByteArray encoded; QBuffer buffer(&encoded);
        if (!buffer.open(QIODevice::WriteOnly) || !image.save(&buffer, "PNG") || encoded.isEmpty())
            return failure("host_limited", "encoding_failed", "PNG encoding failed");
        const QByteArray base64 = encoded.toBase64();
        result["capture_ms"] = timer.elapsed();
        if (timer.elapsed() > 2000) return failure("host_limited", "render_timeout", "Qt rendering exceeded 2000 ms (checked after rendering returns)");
        if (encoded.size() > MaxEncodedBytes || base64.size() > MaxEncodedBytes)
            return failure("host_limited", "image_size_limit", "PNG exceeds the response size limit");
        result["status"] = "experimental";
        result["width"] = image.width(); result["height"] = image.height();
        result["captured_at"] = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
        result["__mcp_image"] = QJsonObject{{"mimeType", "image/png"}, {"data", QString::fromLatin1(base64)}};
        return result;
    }
};
