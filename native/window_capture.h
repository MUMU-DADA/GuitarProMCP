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
        constexpr qint64 MaxDimension = 4096, MaxPixels = 16 * 1024 * 1024, MaxEncodedBytes = 8 * 1024 * 1024;
        if (pixelWidth <= 0 || pixelHeight <= 0 || pixelWidth > MaxDimension || pixelHeight > MaxDimension || pixelWidth * pixelHeight > MaxPixels)
            return failure("host_limited", "dimensions_limit", "Window dimensions are unavailable or exceed the screenshot limit");
        // QWidget::render prepares hidden widgets and can adjustSize() their
        // top-level window. Never let a read initialize an unlaid-out menu.
        if (!target->isVisible() && (!target->window()->testAttribute(Qt::WA_Resized) || !target->testAttribute(Qt::WA_WState_Polished)))
            return failure("host_limited", "unprepared_hidden_window", "Hidden window layout is not prepared; Qt rendering could resize or polish it");
        QElapsedTimer timer; timer.start();
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
