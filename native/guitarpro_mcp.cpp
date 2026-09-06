#include <QtGui/QGenericPlugin>
#include <QtGui/QFileOpenEvent>
#include <QtGui/QWindow>
#include <QtWidgets/QApplication>
#include <QtWidgets/QAction>
#include <QtWidgets/QAbstractButton>
#include <QtWidgets/QWidget>
#include <QtWidgets/QStackedWidget>
#include <QtCore/QElapsedTimer>
#include <QtCore/QFileInfo>
#include <QtCore/QDirIterator>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QMetaProperty>
#include <QtCore/QMetaMethod>
#include <QtCore/QThread>
#include "mcp_server.h"
#include "discovery.h"
#include "guitarpro_api.h"
#include "guitarpro_clipboard.h"
#include "object_registry.h"
#include <QtCore/QEvent>
#include <QtCore/QPointer>
#include <QtCore/QSaveFile>
#include <QtCore/QSet>
#include <QtCore/QTimer>
#include <QtCore/QUuid>
#include <QtNetwork/QTcpServer>
#include <QtNetwork/QTcpSocket>
#include <windows.h>
#include <cmath>

static QString nonce() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
static const QStringList writableNames = {"checked", "value", "currentIndex", "currentText", "text", "plainText"};

class Bridge : public QObject {
    McpServer server{this};
    ObjectRegistry registry;
    guitarpro::ScoreClipboard clipboardBuffer;

    QString sessionFile;
    QString snapshot;
    QElapsedTimer observedAt;
    QHash<int, QPointer<QObject>> observed;
    QHash<QObject *, QPointer<QObject>> nativeObjects;
    QJsonObject creation;
    QList<QPointer<QObject>> creationBefore;
    QElapsedTimer creationElapsed;
    QTimer creationPoll{this};
    QJsonObject closing;
    QPointer<QWidget> closingView;
    QElapsedTimer closingElapsed;
    bool hiddenMode = true;
    const bool originalQuitOnLastWindow = qApp->quitOnLastWindowClosed();
    QPointer<QWidget> noFocusWindow;

    void preventActivation(QWidget *window) {
        qApp->setQuitOnLastWindowClosed(false);
        if (!window->windowFlags().testFlag(Qt::WindowDoesNotAcceptFocus)) {
            noFocusWindow = window;
            window->setWindowFlag(Qt::WindowDoesNotAcceptFocus, true);
        }
        // A hidden QWidget can defer its flags update until the next show.
        // The host calls requestActivate on its existing QWindow meanwhile.
        if (window->windowHandle()) window->windowHandle()->setFlag(Qt::WindowDoesNotAcceptFocus, true);
    }

    void checkClosing() {
        if (closing.value("status") != "requested") return;
        if (!closingView) closing["status"] = "closed";
        else if (closingElapsed.elapsed() > 10000) {
            closing["status"] = "error";
            closing["error"] = "Document still exists after close request; inspect documents and dialogs";
        }
    }

    void checkCreation() {
        const QString path = creation.value("template_path").toString();
        for (const auto &document : guitarpro::documents()) {
            if (creationBefore.contains(document.object) || !document.score || document.object->property("saveFilePath").toString() != path) continue;
            const QString empty;
            const bool adopted = QMetaObject::invokeMethod(document.object, "setOpenedFilePath", Qt::DirectConnection, Q_ARG(QString, empty)) &&
                QMetaObject::invokeMethod(document.object, "setSaveFilePath", Qt::DirectConnection, Q_ARG(QString, empty));
            creation["document"] = document.view->objectName();
            creation["status"] = adopted && document.object->property("saveFilePath").toString().isEmpty() &&
                document.object->property("openedFilePath").toString().isEmpty() ? "created" : "error";
            creationPoll.stop(); creationBefore.clear(); return;
        }
        if (creationElapsed.elapsed() > 10000) {
            creation["status"] = "error";
            creation["error"] = "No new template document observed within 10 seconds; inspect documents and dialogs";
            creationPoll.stop(); creationBefore.clear();
        }
    }

    QJsonObject info() const {
        wchar_t filename[MAX_PATH] = {};
        GetModuleFileNameW(GetModuleHandleW(L"guitarpro_mcp.dll"), filename, MAX_PATH);
        const HWND foreground = GetForegroundWindow();
        DWORD foregroundPid = 0;
        GetWindowThreadProcessId(foreground, &foregroundPid);
        wchar_t title[512] = {}, className[256] = {};
        GetWindowTextW(foreground, title, 512);
        GetClassNameW(foreground, className, 256);
        const QWidget *foregroundWidget = foregroundPid == GetCurrentProcessId()
            ? QWidget::find(WId(foreground)) : nullptr;
        wchar_t station[256] = {};
        DWORD stationBytes = 0;
        GetUserObjectInformationW(GetProcessWindowStation(), UOI_NAME, station, sizeof(station), &stationBytes);
        return {{"backend", "in_process_qt_plugin"},
                {"pid", double(QCoreApplication::applicationPid())}, {"qt_version", qVersion()},
                {"host_exe", QCoreApplication::applicationFilePath()},
                {"plugin_path", QString::fromWCharArray(filename)},
                {"hidden_mode", hiddenMode},
                {"window_station", QString::fromWCharArray(station)},
                {"foreground_pid", double(foregroundPid)},
                {"foreground_window", QJsonObject{{"handle", QString::number(quintptr(foreground), 16)},
                    {"class", QString::fromWCharArray(className)}, {"title", QString::fromWCharArray(title)},
                    {"visible", bool(IsWindowVisible(foreground))}, {"minimized", bool(IsIconic(foreground))},
                    {"qt_class", foregroundWidget ? foregroundWidget->metaObject()->className() : ""},
                    {"qt_name", foregroundWidget ? foregroundWidget->objectName() : QString()}}},
                {"qt_thread", QThread::currentThread() == qApp->thread()}, {"state_scope", "Live native score metadata, tracks, notes, cursor and Qt objects; see coverage for unimplemented state"}};
    }

    QList<QPointer<QObject>> services() const {
        QList<QPointer<QObject>> result = registry.objects();
        for (const auto &object : nativeObjects) if (object) result.append(object);
        return result; // native operations may destroy objects in this snapshot
    }

    QList<QObject*> objects() const {
        QList<QObject*> pending{qApp}, result;
        for (const auto &object : services()) if (object) pending.append(object.data());
        for (QWidget *widget : QApplication::allWidgets()) pending.append(widget);
        QSet<QObject*> seen;
        while (!pending.isEmpty() && result.size() < 20000) {
            QObject *object = pending.takeLast();
            if (!object || seen.contains(object) || object == this || object == &server) continue;
            QObject *owner = object;
            while (owner && owner != this) owner = owner->parent();
            if (owner == this) continue;
            seen.insert(object);
            result.append(object);
            pending.append(object->children());
            if (auto widget = qobject_cast<QWidget*>(object))
                for (QAction *action : widget->actions()) pending.append(action);
        }
        return result;
    }

    static QJsonObject properties(QObject *object) {
        QJsonObject result;
        const QMetaObject *meta = object->metaObject();
        for (int i = 0; i < meta->propertyCount(); ++i) {
            QMetaProperty property = meta->property(i);
            if (!property.isReadable()) continue;
            const int type = property.userType();
            if (type != QMetaType::Bool && type != QMetaType::Int && type != QMetaType::UInt &&
                type != QMetaType::LongLong && type != QMetaType::ULongLong && type != QMetaType::Double &&
                type != QMetaType::QString && type != QMetaType::QStringList) continue;
            QVariant value = property.read(object);
            switch (value.type()) {
            case QVariant::Bool: case QVariant::Int: case QVariant::UInt:
            case QVariant::LongLong: case QVariant::ULongLong: case QVariant::Double:
                result[property.name()] = QJsonValue::fromVariant(value); break;
            case QVariant::String:
                result[property.name()] = value.toString().left(4096); break;
            case QVariant::StringList:
                result[property.name()] = QJsonArray::fromStringList(value.toStringList().mid(0, 64)); break;
            default: break; // QObject pointers and arbitrary C++ values are not exposed.
            }
        }
        return result;
    }

    QJsonObject inspect(const QJsonObject &args, bool actionsOnly) {
        const int offset = args.value("offset").toInt(0), limit = args.value("limit").toInt(100);
        if (offset < 0 || limit < 1 || limit > 500) return {{"error", "offset >= 0 and limit 1..500 required"}};
        const QString query = args.value("query").toString();
        observed.clear(); snapshot = nonce(); observedAt.start();
        QJsonArray rows;
        int matched = 0;
        const auto candidates = objects();
        for (QObject *object : candidates) {
            QAction *action = qobject_cast<QAction*>(object);
            QWidget *widget = qobject_cast<QWidget*>(object);
            if (actionsOnly && !action) continue;
            if (!args.value("include_hidden").toBool(true) &&
                ((widget && !widget->isVisible()) || (action && !action->isVisible()))) continue;
            QString search = object->objectName() + " " + object->metaObject()->className();
            if (action) search += " " + action->text();
            if (widget) search += " " + widget->windowTitle() + " " + widget->toolTip();
            if (auto button = qobject_cast<QAbstractButton*>(object)) search += " " + button->text();
            if (!query.isEmpty() && !search.contains(query, Qt::CaseInsensitive)) continue;
            ++matched;
            if (matched <= offset || rows.size() >= limit) continue;
            const int id = rows.size() + 1;
            observed.insert(id, object);
            QJsonArray methods, signalSignatures;
            const QMetaObject *meta = object->metaObject();
            for (int m = 0; m < meta->methodCount(); ++m) {
                QMetaMethod method = meta->method(m);
                if (method.methodType() == QMetaMethod::Signal) {
                    signalSignatures.append(QString::fromLatin1(method.methodSignature()));
                    continue;
                }
                methods.append(QJsonObject{{"signature", QString::fromLatin1(method.methodSignature())}, {"return_type", QString::fromLatin1(method.typeName())}, {"access", int(method.access())}});
            }
            QJsonArray writable;
            for (const QString &name : writableNames) {
                int index = object->metaObject()->indexOfProperty(name.toUtf8());
                if (index >= 0 && object->metaObject()->property(index).isWritable()) writable.append(name);
            }
            QJsonObject row{{"id", id}, {"class", object->metaObject()->className()},
                            {"object_name", object->objectName()}, {"action", action != nullptr},
                            {"button", qobject_cast<QAbstractButton*>(object) != nullptr},
                            {"parent_name", object->parent() ? object->parent()->objectName() : QString()},
                            {"properties", properties(object)}, {"methods", methods}, {"signals", signalSignatures}, {"writable_properties", writable}};
            if (action) {
                row["text"] = action->text(); row["enabled"] = action->isEnabled();
                row["checked"] = action->isChecked(); row["checkable"] = action->isCheckable();
                row["shortcut"] = action->shortcut().toString();
            } else if (widget) {
                row["enabled"] = widget->isEnabled(); row["visible"] = widget->isVisible();
                if (widget->isWindow()) {
                    row["window_flags"] = int(widget->windowFlags());
                    if (widget->windowHandle()) row["native_window_flags"] = int(widget->windowHandle()->flags());
                }
            }
            if (auto stack = qobject_cast<QStackedWidget *>(object)) {
                QJsonArray pages;
                for (int page = 0; page < stack->count(); ++page) {
                    QWidget *child = stack->widget(page);
                    pages.append(QJsonObject{{"index", page}, {"class", child->metaObject()->className()}, {"object_name", child->objectName()}});
                }
                row["pages"] = pages;
            }
            rows.append(row);
        }
        return {{"snapshot", snapshot}, {"objects", rows}, {"matched", matched},
                {"next_offset", offset + rows.size() < matched ? QJsonValue(offset + rows.size()) : QJsonValue()},
                {"truncated", candidates.size() >= 20000}, {"pid", double(QCoreApplication::applicationPid())}};
    }

    QJsonObject execute(const QString &operation, const QJsonObject &args) {
        if (operation == "native_info") return info();
        if (operation == "native_actions" || operation == "native_objects") return inspect(args, operation == "native_actions");
        if (operation != "native_trigger" && operation != "native_set_property" && operation != "native_close_window") return {{"error", "Unknown native operation"}};
        if (snapshot.isEmpty() || args.value("snapshot").toString() != snapshot || !observedAt.isValid() || observedAt.elapsed() > 60000)
            return {{"error", "Stale snapshot; observe again"}};
        QPointer<QObject> object = observed.value(args.value("id").toInt());
        if (!object) return {{"error", "Observed object no longer exists"}};
        if (auto widget = qobject_cast<QWidget*>(object.data()))
            if (!widget->isEnabled()) return {{"error", "Widget is disabled"}};
        if (operation == "native_trigger") {
            QPointer<QAction> action = qobject_cast<QAction*>(object.data());
            QPointer<QAbstractButton> button = qobject_cast<QAbstractButton*>(object.data());
            if (action && action->isEnabled()) {
                QTimer::singleShot(0, action.data(), [action]() { if (action && action->isEnabled()) action->trigger(); });
            } else if (button && button->isEnabled()) {
                QTimer::singleShot(0, button.data(), [button]() { if (button && button->isEnabled()) button->click(); });
            } else return {{"error", "Action or button is unavailable"}};
            // Reply before invoking: modal actions may enter a nested event loop.
            snapshot.clear();
        } else if (operation == "native_close_window") {
            QPointer<QWidget> window = qobject_cast<QWidget*>(object.data());
            if (!window || !window->isWindow()) return {{"error", "Object is not a window"}};
            snapshot.clear();
            const bool mainWindow = QByteArray(window->metaObject()->className()) == "gp::gui::MainWindow";
            QTimer::singleShot(0, window.data(), [window, mainWindow]() {
                if (window && window->close() && mainWindow) QCoreApplication::quit();
            });
        } else {
            const QByteArray name = args.value("property").toString().toUtf8();
            const int index = object->metaObject()->indexOfProperty(name.constData());
            if (!writableNames.contains(QString::fromUtf8(name)) || index < 0 || !object->metaObject()->property(index).isWritable())
                return {{"error", "Property is not in the observed writable allowlist"}};
            QMetaProperty property = object->metaObject()->property(index);
            const QJsonValue input = args.value("value");
            const int type = property.userType();
            if ((type == QMetaType::Bool && !input.isBool()) ||
                (type == QMetaType::QString && !input.isString()) ||
                ((type == QMetaType::Int || type == QMetaType::Double) && !input.isDouble()) ||
                (type == QMetaType::Int && (std::floor(input.toDouble()) != input.toDouble() || std::abs(input.toDouble()) > 2147483647.0)) ||
                (type != QMetaType::Bool && type != QMetaType::QString && type != QMetaType::Int && type != QMetaType::Double))
                return {{"error", "Property value has an unsupported type"}};
            QVariant value = input.toVariant();
            if (!value.convert(type)) return {{"error", "Cannot convert property value"}};
            snapshot.clear();
            QTimer::singleShot(0, object.data(), [object, name, value]() { if (object) object->setProperty(name.constData(), value); });
        }
        return {{"status", "scheduled; observe the result before issuing another mutation"}};
    }

    void start() {
        sessionFile = qEnvironmentVariable("GPMCP_SESSION_FILE");
        const QJsonObject str{{"type", "string"}}, integer{{"type", "integer"}}, boolean{{"type", "boolean"}};
        QJsonArray tools;
        auto add = [&](const QString &name, const QString &description, QJsonObject properties, QJsonArray required = {}) {
            tools.append(QJsonObject{{"name", name}, {"description", description},
                {"inputSchema", QJsonObject{{"type", "object"}, {"properties", properties}, {"required", required}, {"additionalProperties", false}}}});
        };
        if (qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) add("gp_debug_objects", "开发用：从已知 Qt 对象读取关联的 C++ RTTI，定位原生模型。", {});
        if (qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) add("gp_debug_resources", "开发用：只读枚举宿主嵌入的 Qt 资源路径。", {{"query", str}});
        add("gp_templates", "枚举宿主内置曲谱模板，供 gp_new 使用。", {});
        add("gp_edit_connection", "原生编辑连奏和延音线，支持撤销。kind 为 legato/tie，enabled 必填；scope 为 cursor（默认）或 selection。cursor 的 legato 连接下一拍，tie 连接前一拍；tie 可用 string 指定单音，省略时整拍处理，可能改写音高/升降号或补入音符。selection 支持跨声部/音轨，沿用 128 小节、20000 拍上限。返回 observed_beats 和 changed_selected_beats，后者不含选区外的相邻端点；status=executed 不保证每个音符都可连接。重复命令可能增加原生撤销记录。", {{"document", str}, {"kind", str}, {"enabled", boolean}, {"scope", str}, {"string", integer}}, {"kind", "enabled"});
        add("gp_new", "使用宿主内置模板异步新建曲谱；轮询 gp_documents.creation 确认 request 对应的 created 状态。", {{"template", str}}, {"template"});
        add("gp_read_bars", "按小节读取实时音符、音高、品位、弦、时值和休止；每次最多 16 小节。", {{"document", str}, {"track", integer}, {"staff", integer}, {"bar", integer}, {"count", integer}});
        add("gp_set_fret", "通过原生命令修改当前光标节拍中一个已有音符的品位；弦索引从 0 开始。", {{"document", str}, {"string", integer}, {"fret", integer}}, {"string", "fret"});
        add("gp_edit_note", "在当前节拍或空白占位拍上原生新增/修改弦乐音符或删除指定弦音符。operation 为 set/remove，set 需要 fret；不移动到下一拍。", {{"document", str}, {"operation", str}, {"string", integer}, {"fret", integer}}, {"operation", "string"});
        add("gp_edit_note_effect", "原生修改当前拍指定弦的已有音符，支持撤销。property: palm_mute/let_ring/left_hand_tapping/right_hand_tapping 使用布尔值；vibrato 为 None/Slight/Wide；anti_accent 为 None/Soft/Normal/Strong；left_fingering/right_fingering 为 None/P/I/M/A/C/Open。", {{"document", str}, {"string", integer}, {"property", str}, {"value", QJsonObject{{"anyOf", QJsonArray{boolean, str}}}}}, {"string", "property", "value"});
        add("gp_edit_beat", "原生编辑节拍：insert 新增休止节拍，rhythm 设置基础时值并保留附点/连音，dots 设置附点，tuplet 设置连音，clear 清空音符，remove 删除节拍。tuplet 的 level 为 primary（默认）或 secondary；actual/normal 表示实际演奏音符数与占用的普通音符数，均为 1..255；enabled=false 清除指定层且不接受比例参数。scope 默认 cursor；selection 对选区批量修改 rhythm/dots/tuplet，支持全部声部和音轨，最多 128 小节、20000 拍，跳过空占位拍，可一次撤销。", {{"document", str}, {"operation", str}, {"denominator", integer}, {"dots", integer}, {"scope", str}, {"level", str}, {"actual", integer}, {"normal", integer}, {"enabled", boolean}}, {"operation"});
        add("gp_edit_bars", "原生插入或删除小节，作用于整份曲谱的所有音轨。operation 为 insert/remove，index 从 0 开始，count 默认 1。", {{"document", str}, {"operation", str}, {"index", integer}, {"count", integer}}, {"operation", "index"});
        add("gp_score", "读取实时曲谱元数据、音轨小节数量、光标及撤销状态；直接调用 GPCore。", {{"document", str}});
        add("gp_read_master_bars", "读取全曲共享的小节拍号、实音调号、反复记号和小节线；分页最多 128 小节。", {{"document", str}, {"bar", integer}, {"count", integer}});
        add("gp_edit_measure", "原生修改光标所在的单个小节，支持撤销。operation: time_signature(numerator,denominator)、key_signature(accidentals,major)、repeat_start/repeat_end/double_bar/free_time(enabled)。反复结束可指定 repeat_count 2..100。", {{"document", str}, {"operation", str}, {"numerator", integer}, {"denominator", integer}, {"accidentals", integer}, {"major", boolean}, {"enabled", boolean}, {"repeat_count", integer}}, {"operation"});
        add("gp_edit_tempo", "原生修改曲谱初始速度，支持撤销。value 为 1..400 的整数，unit 使用 gp_score.tempo.units 中的值，默认保留当前单位和 label；不编辑后续变速点。", {{"document", str}, {"value", QJsonObject{{"type", "number"}, {"minimum", 1}, {"maximum", 400}, {"multipleOf", 1}}}, {"unit", str}, {"label", str}}, {"value"});
        add("gp_edit_track", "原生设置音轨 name/short_name、color (#RRGGBB)、volume/pan (0..1) 或 playback_state (Default/Solo/Mute)。播放状态不加入撤销栈，其余属性支持撤销。", {{"document", str}, {"track", integer}, {"property", str}, {"value", QJsonObject{{"anyOf", QJsonArray{str, QJsonObject{{"type", "number"}}}}}}}, {"track", "property", "value"});
        add("gp_edit_tracks", "原生复制、删除或交换音轨，支持撤销；operation 为 duplicate/remove/swap，复制到原轨之后，swap 需要 other 索引。", {{"document", str}, {"operation", str}, {"track", integer}, {"other", integer}}, {"operation", "track"});
        add("gp_insert_track", "以已有音轨配置原生新增音轨，支持撤销。默认清空内容并匹配目标小节数；copy_content=true 复制音符，要求两者小节数相同。源文档默认目标文档，index 默认末尾。", {{"document", str}, {"source_document", str}, {"source_track", integer}, {"index", integer}, {"copy_content", boolean}}, {"source_track"});
        add("gp_edit_metadata", "通过原生命令修改一项曲谱元数据，支持宿主撤销。property 使用 gp_score 返回的键。", {{"document", str}, {"property", str}, {"value", str}}, {"property", "value"});
        add("gp_undo_redo", "调用原生曲谱撤销或重做；不依赖窗口焦点或 QAction 状态。", {{"document", str}, {"operation", str}}, {"operation"});
        add("gp_cursor", "移动实时曲谱光标的 track/staff/bar/voice/beat 索引；索引从 0 开始，声部为 0..3。", {{"document", str}, {"axis", str}, {"index", integer}}, {"axis", "index"});
        const QJsonObject endpoint{{"type", "object"}, {"properties", QJsonObject{{"track", integer}, {"staff", integer}, {"bar", integer}, {"voice", integer}, {"beat", integer}}},
            {"required", QJsonArray{"track", "staff", "bar", "voice", "beat"}}, {"additionalProperties", false}};
        add("gp_selection", "原生选区：state 读取状态；beats 列出明确选区的实际节拍位置和总数，跳过空占位拍，最多 128 小节、20000 拍；range 用 base/extent 指定同轨同谱表同声部的节拍范围（含端点）；note 用 base 和 notes 数组的 note_index 选择单音；all 选择当前谱表；clear 取消选区并停在末端。range/all 可用 all_voices 扩展声部，all_tracks 扩展为所选整小节的全部音轨、谱表和声部。所有索引从 0 开始。", {{"document", str}, {"operation", str}, {"base", endpoint}, {"extent", endpoint}, {"note_index", integer}, {"all_voices", boolean}, {"all_tracks", boolean}});
        add("gp_activate", "通过原生文档导航方法切换指定文档并读回活动文档；无需前台窗口。", {{"document", str}}, {"document"});
        add("gp_playback", "调用原生播放控制器。seek 使用原曲谱 bar 与小节内 tick；seek_tick 使用展开反复后的时间线绝对 tick。另支持 state/play/stop/set_loop/set_metronome/set_countdown。", {{"document", str}, {"operation", str}, {"bar", integer}, {"tick", integer}, {"enabled", boolean}});
        add("gp_open", "通过宿主原生文件打开事件异步打开已有 .gp 文件；用 gp_documents 的路径读回确认完成。", {{"path", str}}, {"path"});
        add("gp_close", "原生关闭指定的已保存文档，拒绝未保存修改；轮询 gp_documents.closing 并匹配请求 ID 确认 closed。", {{"document", str}}, {"document"});
        add("gp_documents", "读取实时文档 ID、原始路径、保存路径和未保存状态。", {});
        add("gp_save_as", "原生另存为新的 .gp 文件并切换保存路径，通过宿主 save 方法更新保存状态。", {{"document", str}, {"path", str}}, {"path"});
        add("gp_save", "调用原生文档 saveToFile 保存新副本；不使用对话框或输入模拟。", {{"document", str}, {"path", str}}, {"path"});
        add("gp_window", "通过 Qt 原生窗口方法设置测试窗口状态；控制操作本身不需要前台窗口。", {{"state", str}}, {"state"});
        add("gp_capabilities", "原生 C++ 插件身份、后台控制能力及尚未覆盖的范围。", {});
        add("gp_objects", "读取宿主 Qt 对象、属性和可调用方法；无需窗口可见或前台。", {{"query", str}, {"offset", integer}, {"limit", integer}, {"include_hidden", boolean}});
        add("gp_actions", "枚举原生 QAction；禁用状态可能受宿主内部上下文影响。", {{"query", str}, {"offset", integer}, {"limit", integer}, {"include_hidden", boolean}});
        QString clipboardDescription = "原生曲谱片段：state 查看插件缓冲区，copy/cut 复制或剪切明确选区，read 读取副本，paste 粘贴，clear 清空插件缓冲区。read/paste 需当前 id。scope 默认 cursor 插入，可用 selection 替换选区。跨小节或多轨粘贴会顺移全曲小节；多声部片段要求目标处于全部声部模式。read 的谱表索引见 tracks 与 source_selection。默认操作不访问系统剪贴板。";
        if (qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) clipboardDescription += " 实验性宿主互通，尚未完成隔离验证：native_state 查看宿主剪贴板；native_copy 将明确选区复制到宿主，会覆盖系统剪贴板但保留插件缓冲区；native_import 从同一 Guitar Pro 实例的剪贴板导入插件缓冲区。后两项需 native_state 的当前 sequence；跨进程剪贴板不支持。";
        add("gp_clipboard", clipboardDescription, {{"operation", str}, {"document", str}, {"id", str}, {"scope", str}, {"sequence", integer}, {"track", integer}, {"staff", integer}, {"bar", integer}, {"count", integer}});
        add("gp_trigger", "调用刚观察到的原生 QAction 或按钮方法；不发送输入事件。返回 scheduled 后需读回。", {{"snapshot", str}, {"id", integer}}, {"snapshot", "id"});
        add("gp_set_property", "原生 Qt 属性设置；需使用观察结果中允许写入的属性。", {{"snapshot", str}, {"id", integer}, {"property", str}, {"value", QJsonObject{}}}, {"snapshot", "id", "property", "value"});
        add("gp_close_window", "调用原生窗口关闭方法，保留未保存文档确认。", {{"snapshot", str}, {"id", integer}}, {"snapshot", "id"});
        if (!server.start(sessionFile, info(), tools, [this](const QString &tool, const QJsonObject &args) {
            // Host command observers update the active document's dirty state.
            // Bind every model mutation to its document before calling native APIs.
            static const QSet<QString> mutations{"gp_edit_note", "gp_edit_note_effect", "gp_edit_connection", "gp_edit_beat", "gp_edit_bars", "gp_edit_track", "gp_edit_tracks", "gp_insert_track", "gp_edit_tempo", "gp_edit_measure", "gp_set_fret", "gp_edit_metadata", "gp_cursor", "gp_undo_redo", "gp_save_as"};
            if (mutations.contains(tool)) {
                const auto target = guitarpro::choose(args);
                if (!target.view || !target.score) return QJsonObject{{"error", "Choose a document with a verified native score"}};
                const QJsonObject activated = guitarpro::activate(QJsonObject{{"document", target.view->objectName()}}, services());
                if (activated.contains("error")) return activated;
            }
            if (tool == "gp_templates" || tool == "gp_new") {
                if (!guitarpro::supportedBuild()) return QJsonObject{{"error", "Template creation requires the verified host build"}};
                const QDir templates(":/GPBase/MainWindow/Templates");
                QStringList names;
                for (const QString &file : templates.entryList({"*.gpt"}, QDir::Files, QDir::Name)) names.append(QFileInfo(file).completeBaseName());
                if (tool == "gp_templates") return QJsonObject{{"templates", QJsonArray::fromStringList(names)}};
                const QString name = args.value("template").toString();
                if (!templates.entryList({"*.gpt"}, QDir::Files).contains(name + ".gpt")) return QJsonObject{{"error", "Unknown built-in template name"}};
                if (creationPoll.isActive()) return QJsonObject{{"error", "A template creation is already pending"}, {"creation", creation}};
                creationBefore.clear();
                for (const auto &document : guitarpro::documents()) creationBefore.append(document.object);
                const QString path = templates.filePath(name + ".gpt");
                creation = {{"request", nonce()}, {"status", "scheduled"}, {"template", name}, {"template_path", path}};
                creationElapsed.restart(); creationPoll.start(50);
                QCoreApplication::postEvent(qApp, new QFileOpenEvent(path));
                return creation;
            }
            if (tool == "gp_debug_resources" && qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) {
                QJsonArray paths;
                QDirIterator iterator(":/", QDir::Files, QDirIterator::Subdirectories);
                int inspected = 0;
                while (iterator.hasNext() && inspected++ < 50000 && paths.size() < 500) {
                    const QString path = iterator.next();
                    if (path.contains(args.value("query").toString(), Qt::CaseInsensitive)) paths.append(path);
                }
                return QJsonObject{{"paths", paths}, {"truncated", iterator.hasNext()}};
            }
            if (tool == "gp_debug_objects" && qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) {
                if (!guitarpro::supportedBuild()) return QJsonObject{{"error", "Development inspection requires the verified host build"}};
                QJsonArray found = discovery::inspect(objects());
                for (int i = 0; i < found.size(); ++i) {
                    QJsonObject item = found[i].toObject();
                    const QString rtti = item.value("rtti").toString();
                    if (rtti == ".?AVIDocument@gui@gp@@" || rtti == ".?AVConductorController@rse@gp@@" || rtti == ".?AVIAudioDocument@gui@gp@@") {
                        if (QObject *object = discovery::asQObject(item.value("address").toString().toULongLong(nullptr, 16))) {
                            item["qt_class"] = object->metaObject()->className(); item["properties"] = properties(object);
                            QJsonArray methods;
                            for (int m = 0; m < object->metaObject()->methodCount(); ++m) {
                                QMetaMethod method = object->metaObject()->method(m);
                                if (method.methodType() != QMetaMethod::Signal) methods.append(QJsonObject{{"signature", QString::fromLatin1(method.methodSignature())}, {"return_type", QString::fromLatin1(method.typeName())}});
                            }
                            item["methods"] = methods;
                        }
                    }
                    found[i] = item;
                }
                return QJsonObject{{"objects", found}};
            }
            if (tool == "gp_read_bars") return guitarpro::readBars(args);
            if (tool == "gp_set_fret") return guitarpro::setFret(args);
            if (tool == "gp_edit_note") return guitarpro::editNote(args);
            if (tool == "gp_edit_beat") return guitarpro::editBeat(args);
            if (tool == "gp_edit_bars") return guitarpro::editBars(args);
            if (tool == "gp_score") return guitarpro::scoreState(args);
            if (tool == "gp_edit_track") return guitarpro::editTrack(args);
            if (tool == "gp_edit_tracks") return guitarpro::editTracks(args);
            if (tool == "gp_insert_track") return guitarpro::insertTrack(args);
            if (tool == "gp_edit_metadata") return guitarpro::editMetadata(args);
            if (tool == "gp_edit_tempo") return guitarpro::editTempo(args);
            if (tool == "gp_read_master_bars") return guitarpro::readMasterBars(args);
            if (tool == "gp_edit_note_effect") return guitarpro::editNoteEffect(args);
            if (tool == "gp_edit_connection") return guitarpro::editConnection(args);
            if (tool == "gp_edit_measure") return guitarpro::editMeasure(args);
            if (tool == "gp_undo_redo") return guitarpro::undoRedo(args);
            if (tool == "gp_cursor") return guitarpro::moveCursor(args);
            if (tool == "gp_selection") return guitarpro::selection(args, services());
            if (tool == "gp_clipboard") return guitarpro::clipboard(args, clipboardBuffer, services());
            if (tool == "gp_activate") return guitarpro::activate(args, services());
            if (tool == "gp_playback") return guitarpro::playback(args, services());
            if (tool == "gp_open") {
                if (!guitarpro::supportedBuild()) return QJsonObject{{"error", "Document opening requires the verified host build"}};
                const QFileInfo file(args.value("path").toString());
                if (!file.isAbsolute() || !file.isFile() || file.suffix().toLower() != "gp") return QJsonObject{{"error", "Existing absolute .gp path required"}};
                const QString path = file.canonicalFilePath();
                for (const auto &document : guitarpro::documents()) {
                    for (const char *property : {"openedFilePath", "saveFilePath"})
                        if (QFileInfo(document.object->property(property).toString()).canonicalFilePath().compare(path, Qt::CaseInsensitive) == 0)
                            return QJsonObject{{"status", "already_open"}, {"document", document.view->objectName()}, {"path", path}};
                }
                QCoreApplication::postEvent(qApp, new QFileOpenEvent(path));
                return QJsonObject{{"status", "scheduled"}, {"path", path}, {"verify", "Read gp_documents until the path appears; event dispatch is not completion"}};
            }
            if (tool == "gp_documents") {
                QJsonObject result = guitarpro::list(services());
                if (!creation.isEmpty()) result["creation"] = creation;
                checkClosing();
                if (!closing.isEmpty()) result["closing"] = closing;
                return result;
            }
            if (tool == "gp_close") {
                checkClosing();
                if (closing.value("status") == "scheduled" || closing.value("status") == "requested")
                    return QJsonObject{{"error", "A document close is already pending"}, {"closing", closing}};
                const auto target = guitarpro::choose(args);
                if (!target.object || !target.view) return QJsonObject{{"error", "Choose an existing document id"}};
                if (target.object->property("isDirty").toBool())
                    return QJsonObject{{"error", "Document has unsaved changes; save it before closing"}};
                closing = {{"request", nonce()}, {"status", "scheduled"}, {"document", args.value("document")}};
                closingView = target.view;
                closingElapsed.restart();
                QTimer::singleShot(0, this, [this, args, target]() {
                    if (!target.view || !target.object || guitarpro::choose(args).object != target.object) {
                        closing["status"] = "error";
                        closing["error"] = "Document changed before close request";
                        return;
                    }
                    const auto result = guitarpro::closeDocument(args, services());
                    closing["status"] = result.contains("error") ? "error" : "requested";
                    if (result.contains("error")) closing["error"] = result.value("error");
                    checkClosing();
                });
                return closing;
            }
            if (tool == "gp_save_as") return guitarpro::save(args, true);
            if (tool == "gp_save") return guitarpro::save(args);
            if (tool == "gp_window") {
                for (QWidget *widget : QApplication::topLevelWidgets()) {
                    if (QByteArray(widget->metaObject()->className()) != "gp::gui::MainWindow") continue;
                    const QString state = args.value("state").toString();
                    if (state != "minimize" && state != "hide" && state != "restore")
                        return QJsonObject{{"error", "state must be minimize, hide or restore"}};
                    hiddenMode = state == "hide";
                    if (state == "restore") {
                        if (noFocusWindow == widget) {
                            noFocusWindow.clear(); widget->setWindowFlag(Qt::WindowDoesNotAcceptFocus, false);
                            if (widget->windowHandle()) widget->windowHandle()->setFlag(Qt::WindowDoesNotAcceptFocus, false);
                        }
                        widget->showNormal();
                        qApp->setQuitOnLastWindowClosed(originalQuitOnLastWindow);
                    } else {
                        preventActivation(widget);
                        if (state == "minimize") widget->showMinimized();
                        else widget->hide();
                    }
                    return QJsonObject{{"minimized", widget->isMinimized()}, {"visible", widget->isVisible()}};
                }
                return QJsonObject{{"error", "No main window exists"}};
            }
            if (tool == "gp_capabilities") {
                QJsonObject result = info();
                result["protocol_version"] = "2025-06-18";
                result["full_control"] = false;
                result["qobject_registry"] = registry.installed();
                result["qobject_registry_truncated"] = registry.truncated();
                result["native_score_abi_verified"] = guitarpro::supportedBuild();
                result["runtime"] = "C++ DLL inside GuitarPro.exe, no external language runtime";
                result["transport"] = "MCP Streamable HTTP";
                result["limitations"] = QJsonArray{"Full control remains incomplete: closing with unsaved changes, complete notation/effects, track management, import/export, audio/settings and compatibility need further native adapters and verification.", "New/open/close document workflows and playback can complete asynchronously; poll document/playback state. Activate a document before playback control."};
                return result;
            }
            const QHash<QString, QString> operations{{"gp_objects", "native_objects"}, {"gp_actions", "native_actions"}, {"gp_trigger", "native_trigger"}, {"gp_set_property", "native_set_property"}, {"gp_close_window", "native_close_window"}};
            return execute(operations.value(tool), args);
        })) qWarning("GuitarProMCP: failed to start native MCP HTTP server");
    }

protected:
    bool eventFilter(QObject *object, QEvent *event) override {
        if (event->type() == QEvent::ThreadChange) { registry.forget(object); nativeObjects.remove(object); return false; }
        const QByteArray name = object->metaObject()->className();
        // The host may request activation late in startup and document opening.
        // Set the Qt focus policy before showing, then keep explicit hidden mode.
        if (hiddenMode && name == "gp::gui::MainWindow" && (event->type() == QEvent::Polish || event->type() == QEvent::Show)) {
            if (auto window = qobject_cast<QWidget *>(object)) {
                preventActivation(window);
                if (event->type() == QEvent::Show) {
                    QPointer<QWidget> guard = window;
                    QTimer::singleShot(0, this, [this, guard]() { if (hiddenMode && guard) guard->hide(); });
                }
            }
        }
        // Observe real Qt event recipients to discover non-parented host services.
        if (name.startsWith("gp::") && (name.contains("Manager") || name.startsWith("gp::rse::") || name == "gp::gui::IAudioDocument") &&
            nativeObjects.size() < 1024 && !nativeObjects.contains(object)) {
            nativeObjects.insert(object, QPointer<QObject>(object));
            connect(object, &QObject::destroyed, this, [this, object]() { nativeObjects.remove(object); });
        }
        return false;
    }
public:
    Bridge() {
        qApp->setQuitOnLastWindowClosed(false);
        connect(&creationPoll, &QTimer::timeout, this, [this]() { checkCreation(); });
        qApp->installEventFilter(this);
        const QString qtCore = QDir(QCoreApplication::applicationDirPath()).filePath("Qt5Core.dll");
        if (guitarpro::supportedBuild() && guitarpro::hash(qtCore) == "c2f85bd55c31e5380dd99f0d517ee183a54c3852480bc497dc30a5483fd70ff2") registry.install();
        setObjectName("GuitarProMCPBridge"); QTimer::singleShot(0, this, [this]() { start(); });
    }
};

class GuitarProPlugin : public QGenericPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QGenericPluginFactoryInterface_iid FILE "guitarpro_mcp.json")
public:
    QObject *create(const QString &name, const QString &) override {
        if (name.compare("guitarpro_mcp", Qt::CaseInsensitive) ||
            QFileInfo(QCoreApplication::applicationFilePath()).baseName().compare("GuitarPro", Qt::CaseInsensitive) ||
            !QString::fromLatin1(qVersion()).startsWith("5.15.")) return nullptr;
        return new Bridge;
    }
};
#include "guitarpro_mcp.moc"
