#include <QtGui/QGenericPlugin>
#include <QtCore/QJsonDocument>
#include <QtCore/QTimer>
#include <stdexcept>
#include "guitarpro_api.h"

// Test-only native signal faults. Every open document must belong to the
// marked test directory before the probe can attach to a tab.
class TabFaultProbe : public QObject {
    Q_OBJECT
    QString directory, request, mode, target;
    QMetaObject::Connection connection;
    QTimer poll{this};
    int remaining = 0;
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
        target = config.value("document").toString();
        remaining = mode == "throw_recovery" ? 2 : 1;
        if (mode.isEmpty()) { record({{"event", "disarmed"}}); return; }
        const auto docs = guitarpro::documents();
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
private slots:
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
        connect(&poll, &QTimer::timeout, this, [this] { refresh(); });
        poll.start(20);
        record({{"event", "ready"}});
    }
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
