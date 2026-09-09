#include <QtGui/QGenericPlugin>
#include <QtCore/QJsonDocument>
#include <QtCore/QTimer>
#include <QtGui/QFileOpenEvent>
#include <QtWidgets/QMessageBox>
#include <stdexcept>
#include <cstring>
#include "guitarpro_api.h"

// Test-only native signal faults. Every open document must belong to the
// marked test directory before the probe can attach to a tab.
class TabFaultProbe : public QObject {
    Q_OBJECT
    QString directory, request, mode, target;
    QMetaObject::Connection connection;
    QTimer poll{this};
    int remaining = 0;
    inline static TabFaultProbe *active = nullptr;
    void **sendSlot = nullptr;
    void *originalSend = nullptr;
    static bool send(QObject *object, QEvent *event) {
        if (active && active->defer(object, event)) return true;
        bool failAfter = false;
        if (active && active->remaining > 0 && object == qApp && event->type() == QEvent::FileOpen) {
            const QString path = QDir::fromNativeSeparators(static_cast<QFileOpenEvent *>(event)->file());
            failAfter = (active->mode == "throw_after_open" && path.startsWith(active->directory + "/", Qt::CaseInsensitive)) ||
                (active->mode == "throw_after_create" && path.startsWith(":/GPBase/MainWindow/Templates/"));
            if (failAfter) --active->remaining;
        }
        const bool result = QCoreApplication::sendEvent(object, event);
        if (failAfter) {
            active->record({{"event", "native_exception"}, {"stage", "load_returned"}, {"send_result", result}});
            throw std::runtime_error("Isolated exception after native file loading");
        }
        return result;
    }
    bool replaceSend(bool install) {
        if (!sendSlot) return false;
        DWORD protection = 0;
        if (!VirtualProtect(sendSlot, sizeof(void *), PAGE_READWRITE, &protection)) return false;
        void *replacement = reinterpret_cast<void *>(&send);
        const bool changed = InterlockedCompareExchangePointer(sendSlot, install ? replacement : originalSend, install ? originalSend : replacement) == (install ? originalSend : replacement);
        DWORD unused = 0; VirtualProtect(sendSlot, sizeof(void *), protection, &unused);
        return changed;
    }
    bool hookSend() {
        const auto base = reinterpret_cast<unsigned char *>(GetModuleHandleW(L"guitarpro_mcp.dll"));
        if (!base) return false;
        const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
        const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64 *>(base + dos->e_lfanew);
        const auto imports = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
        if (!imports.VirtualAddress) return false;
        auto descriptor = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR *>(base + imports.VirtualAddress);
        for (; descriptor->Name; ++descriptor) {
            if (!descriptor->OriginalFirstThunk) continue;
            auto names = reinterpret_cast<const IMAGE_THUNK_DATA64 *>(base + descriptor->OriginalFirstThunk);
            auto addresses = reinterpret_cast<IMAGE_THUNK_DATA64 *>(base + descriptor->FirstThunk);
            for (; names->u1.AddressOfData; ++names, ++addresses) {
                if (IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal)) continue;
                const auto symbol = reinterpret_cast<const IMAGE_IMPORT_BY_NAME *>(base + names->u1.AddressOfData);
                if (!std::strstr(reinterpret_cast<const char *>(symbol->Name), "?sendEvent@QCoreApplication@@")) continue;
                sendSlot = reinterpret_cast<void **>(&addresses->u1.Function);
                originalSend = *sendSlot;
                return replaceSend(true);
            }
        }
        return false;
    }
    void record(QJsonObject event) const {
        event["request"] = request;
        QFile output(directory + "/probe.jsonl");
        if (output.open(QIODevice::WriteOnly | QIODevice::Append))
            output.write(QJsonDocument(event).toJson(QJsonDocument::Compact) + '\n');
    }
    void refresh() {
        QFile input(directory + "/control.json");
        if (!input.open(QIODevice::ReadOnly)) return;
        const auto config = QJsonDocument::fromJson(input.readAll()).object();
        const QString next = config.value("request").toString();
        if (next.isEmpty() || next == request) return;
        QObject::disconnect(connection);
        request = next; mode = config.value("mode").toString();
        target = QDir::fromNativeSeparators(config.value("document").toString());
        remaining = mode == "throw_recovery" ? 2 : 1;
        if (mode.isEmpty()) { record({{"event", "disarmed"}}); return; }
        const auto docs = guitarpro::documents();
        if (mode == "delay_open" || mode == "delay_create" || mode == "error_open" || mode == "error_create" || mode == "throw_after_open" || mode == "throw_after_create" ||
            mode == "throw_close" || mode == "close_external" || mode == "open_external") {
            for (const auto &doc : docs) {
                const QString path = QDir::fromNativeSeparators(doc.object->property("openedFilePath").toString());
                if (!path.isEmpty() && !path.startsWith(directory + "/", Qt::CaseInsensitive)) { record({{"event", "rejected"}}); mode.clear(); return; }
            }
            if (mode == "throw_close") {
                if (docs.size() != 1) { record({{"event", "rejected"}}); mode.clear(); return; }
                for (QObject *child : docs.first().view->window()->children())
                    if (QByteArray(child->metaObject()->className()) == "gp::gui::TabWidgetProxy")
                        connection = QObject::connect(child, SIGNAL(tabCloseRequested(int)), this, SLOT(onCloseRequested(int)), Qt::DirectConnection);
                if (!connection) { record({{"event", "rejected"}}); mode.clear(); return; }
            }
            if (mode == "close_external") {
                if (docs.isEmpty()) { record({{"event", "rejected"}}); mode.clear(); return; }
                for (const auto &doc : docs) if (doc.object->property("isDirty").toBool()) {
                    record({{"event", "rejected"}}); mode.clear(); return;
                }
                QPointer<QObject> proxy;
                for (QObject *child : docs.first().view->window()->children())
                    if (QByteArray(child->metaObject()->className()) == "gp::gui::TabWidgetProxy") proxy = child;
                if (!proxy) { record({{"event", "rejected"}}); mode.clear(); return; }
                QTimer::singleShot(0, this, [this, proxy, docs] {
                    for (int i = 0; i < docs.size() && proxy; ++i)
                        QMetaObject::invokeMethod(proxy, "tabCloseRequested", Qt::DirectConnection, Q_ARG(int, 0));
                    record({{"event", "external_close"}, {"remaining_documents", guitarpro::documents().size()}});
                });
            }
            record({{"event", "armed"}});
            if (mode == "open_external" && target.startsWith(directory + "/", Qt::CaseInsensitive) && QFile::exists(target)) {
                QTimer::singleShot(0, this, [this, path = target] {
                    QFileOpenEvent open(path);
                    QCoreApplication::sendEvent(qApp, &open);
                    record({{"event", "external_open"}, {"path", path}});
                });
            }
            return;
        }
        if (docs.size() != 4) { record({{"event", "rejected"}}); return; }
        for (const auto &doc : docs)
            if (!QDir::fromNativeSeparators(doc.object->property("openedFilePath").toString()).startsWith(directory + "/", Qt::CaseInsensitive)) {
                record({{"event", "rejected"}}); return;
            }
        const auto tabs = guitarpro::documentTabs(docs, nullptr);
        if (!tabs.pages || !tabs.layout) { record({{"event", "rejected"}}); return; }
        auto activeTab = tabs.layout->itemAt(tabs.pages->currentIndex())->widget();
        connection = QObject::connect(activeTab, SIGNAL(clicked()), this, SLOT(onClicked()), Qt::DirectConnection);
        record({{"event", "armed"}, {"mode", mode}, {"connected", bool(connection)}});
    }
    bool defer(QObject *object, QEvent *event) {
        if (object != qApp || event->type() != QEvent::FileOpen || remaining <= 0) return false;
        const QString path = QDir::fromNativeSeparators(static_cast<QFileOpenEvent *>(event)->file());
        const bool match = ((mode == "delay_open" || mode == "error_open") && path.startsWith(directory + "/", Qt::CaseInsensitive)) ||
            ((mode == "delay_create" || mode == "error_create") && path.startsWith(":/GPBase/MainWindow/Templates/"));
        if (!match) return false;
        --remaining;
        if (mode.startsWith("error_")) {
            QWidget *window = nullptr;
            for (auto widget : QApplication::topLevelWidgets())
                if (QByteArray(widget->metaObject()->className()) == "gp::gui::MainWindow") window = widget;
            if (!window) return false;
            QMessageBox dialog(QMessageBox::Critical, "Isolated load error", "Injected file loading failure", QMessageBox::Ok, window);
            QTimer::singleShot(8000, &dialog, &QDialog::reject);
            dialog.exec();
            record({{"event", "load_error_dismissed"}});
            event->accept();
            return true;
        }
        record({{"event", "deferred"}, {"path", path}});
        QTimer::singleShot(11500, this, [this, path] {
            QFileOpenEvent later(path);
            QCoreApplication::sendEvent(qApp, &later);
            record({{"event", "delivered"}, {"path", path}});
        });
        event->accept();
        return true;
    }
private slots:
    void onCloseRequested(int) {
        if (mode != "throw_close" || remaining-- <= 0) return;
        record({{"event", "native_exception"}, {"stage", "close_notified"}});
        throw std::runtime_error("Isolated exception after native close notification");
    }
    void onClicked() {
        if (remaining-- <= 0) return;
        record({{"event", "fault"}, {"mode", mode}, {"remaining", remaining}});
        if (mode == "throw" || mode == "throw_recovery") throw std::runtime_error("Isolated tab activation exception");
        const auto docs = guitarpro::documents();
        const auto tabs = guitarpro::documentTabs(docs, nullptr);
        if (!tabs.pages || !tabs.layout) { record({{"event", "invalid_mapping"}}); return; }
        if (mode == "switch_active") {
            auto next = tabs.layout->itemAt((tabs.pages->currentIndex() + 1) % tabs.pages->count())->widget();
            QMetaObject::invokeMethod(next, "clicked", Qt::DirectConnection);
        } else if (mode == "extra_reorder") {
            QList<int> indexes;
            for (const auto &doc : docs)
                if (doc.id() != target && doc.view != tabs.pages->currentWidget()) indexes.append(tabs.pages->indexOf(doc.view));
            if (indexes.size() != 2) { record({{"event", "invalid_targets"}}); return; }
            const int low = qMin(indexes[0], indexes[1]), high = qMax(indexes[0], indexes[1]);
            const QSignalBlocker blocked(tabs.pages);
            auto active = tabs.pages->currentWidget(), first = tabs.pages->widget(low), last = tabs.pages->widget(high);
            auto lastItem = tabs.layout->takeAt(high), firstItem = tabs.layout->takeAt(low);
            tabs.layout->insertItem(low, lastItem); tabs.layout->insertItem(high, firstItem);
            tabs.pages->removeWidget(last); tabs.pages->removeWidget(first);
            tabs.pages->insertWidget(low, last); tabs.pages->insertWidget(high, first);
            tabs.pages->setCurrentWidget(active);
        }
        QJsonArray order;
        for (int i = 0; i < tabs.pages->count(); ++i)
            for (const auto &doc : docs) if (doc.view == tabs.pages->widget(i)) order.append(doc.id());
        record({{"event", "changed"}, {"order", order}, {"active_index", tabs.pages->currentIndex()}});
    }
public:
    explicit TabFaultProbe(const QString &path) : directory(path) {
        active = this;
        const bool hooked = hookSend();
        connect(qApp, &QCoreApplication::aboutToQuit, this, [this] { replaceSend(false); active = nullptr; });
        connect(&poll, &QTimer::timeout, this, [this] { refresh(); });
        poll.start(20);
        record({{"event", "ready"}, {"load_hook", hooked}});
    }
    ~TabFaultProbe() override { replaceSend(false); if (active == this) active = nullptr; }
};

class TabFaultPlugin : public QGenericPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QGenericPluginFactoryInterface_iid FILE "tab-fault-probe.json")
public:
    QObject *create(const QString &name, const QString &) override {
        if (name != "guitarpro_tab_fault_probe" || !guitarpro::supportedBuild()) return nullptr;
        const QString path = QDir::cleanPath(QDir::fromNativeSeparators(qEnvironmentVariable("GPMCP_TAB_FAULT_DIRECTORY")));
        if (!QDir::isAbsolutePath(path)) return nullptr;
        QFile marker(path + "/isolated-tab-fault-test");
        if (!marker.open(QIODevice::ReadOnly) || marker.readAll().trimmed() != "gpmcp-tab-fault-test") return nullptr;
        return new TabFaultProbe(path);
    }
};
#include "tab-fault-probe.moc"
