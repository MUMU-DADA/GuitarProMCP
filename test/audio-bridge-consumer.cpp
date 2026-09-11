#include "../native/audio_bridge_api.h"
#include <QtGui/QGenericPlugin>
#include <QtCore/QCoreApplication>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QSaveFile>
#include <QtCore/QTimer>
#include <windows.h>
#include <thread>

// A real, separately compiled native consumer. It knows only the public C ABI,
// copies callback metadata, and neither parses nor saves host object pointers.
class AudioConsumer : public QObject {
    QString directory, lastRequest;
    QTimer poll;
    static void visit(void *user, const gpmcp_audio_binding *binding) {
        auto &rows = *static_cast<QJsonArray *>(user);
        rows.append(QJsonObject{{"struct_size", int(binding->struct_size)},
            {"abi_version", int(binding->abi_version)}, {"status", int(binding->status)},
            {"generation", qint64(binding->generation)}, {"controller_index", int(binding->controller_index)},
            {"document_id", QString::fromUtf8(binding->document_id)},
            {"track_id", QString::fromUtf8(binding->track_id)}, {"score_key", QString::fromUtf8(binding->score_key)},
            {"track_index", binding->track_index}, {"sound_index", binding->sound_index},
            {"active_document", binding->active_document}, {"selected_track", binding->selected_track},
            {"has_chain", binding->chain != nullptr}});
    }
    QJsonObject snapshot() {
        const auto module = GetModuleHandleW(L"guitarpro_mcp.dll");
        if (!module) return {{"status", "not_ready"}};
        using Version = unsigned (GPMCP_AUDIO_CALL *)();
        const auto version = reinterpret_cast<Version>(GetProcAddress(module, "gpmcp_audio_bridge_version"));
        const auto infoFn = reinterpret_cast<gpmcp_audio_get_info_fn>(GetProcAddress(module, "gpmcp_audio_bridge_get_info"));
        const auto enumerate = reinterpret_cast<gpmcp_audio_enumerate_v1_fn>(GetProcAddress(module, "gpmcp_audio_enumerate_v1"));
        if (!version || !infoFn || !enumerate || version() != GPMCP_AUDIO_BRIDGE_ABI_VERSION)
            return {{"status", "abi_mismatch"}};
        gpmcp_audio_bridge_info info{};
        info.struct_size = sizeof(info);
        const auto infoStatus = infoFn(&info);
        QJsonArray rows;
        gpmcp_audio_enumerate_result result{};
        result.struct_size = sizeof(result);
        const auto status = enumerate(GPMCP_AUDIO_BRIDGE_ABI_VERSION, visit, &rows, &result);
        gpmcp_audio_enumerate_result bad{};
        bad.struct_size = sizeof(bad);
        const auto mismatch = enumerate(GPMCP_AUDIO_BRIDGE_ABI_VERSION + 1, visit, &rows, &bad);
        const auto nullVisitor = enumerate(GPMCP_AUDIO_BRIDGE_ABI_VERSION, nullptr, nullptr, &bad);
        bad.struct_size = sizeof(bad) - 1;
        const auto shortResult = enumerate(GPMCP_AUDIO_BRIDGE_ABI_VERSION, visit, &rows, &bad);
        gpmcp_audio_bridge_info truncatedInfo{};
        truncatedInfo.struct_size = sizeof(truncatedInfo) - 1;
        const auto shortInfo = infoFn(&truncatedInfo);
        uint32_t workerInfo = 0, workerEnum = 0;
        std::thread worker([&] {
            gpmcp_audio_bridge_info threadInfo{};
            threadInfo.struct_size = sizeof(threadInfo);
            workerInfo = infoFn(&threadInfo);
            gpmcp_audio_enumerate_result threadResult{};
            threadResult.struct_size = sizeof(threadResult);
            workerEnum = enumerate(GPMCP_AUDIO_BRIDGE_ABI_VERSION, visit, &rows, &threadResult);
        });
        worker.join();
        return {{"status", "observed"}, {"info_status", int(infoStatus)}, {"info_status_field", int(info.status)},
            {"abi_version", int(info.abi_version)}, {"host_sha256", QString::fromLatin1(info.host_build_sha256)},
            {"enumerate_status", int(status)}, {"enumerate_status_field", int(result.status)},
            {"generation", qint64(result.generation)}, {"count", qint64(result.count)}, {"bindings", rows},
            {"abi_mismatch", int(mismatch)}, {"short_result", int(shortResult)}, {"short_info", int(shortInfo)},
            {"null_visitor", int(nullVisitor)}, {"worker_info", int(workerInfo)}, {"worker_enumerate", int(workerEnum)}};
    }
    void record(const QString &name, QJsonObject state) {
        state["pid"] = QCoreApplication::applicationPid();
        QSaveFile output(directory + "/" + name);
        if (output.open(QIODevice::WriteOnly)) { output.write(QJsonDocument(state).toJson()); output.commit(); }
    }
public:
    explicit AudioConsumer(const QString &path) : directory(path) {
        record("consumer-start.json", snapshot());
        connect(&poll, &QTimer::timeout, this, [this] {
            QFile request(directory + "/consumer-request.txt");
            if (!request.open(QIODevice::ReadOnly)) return;
            const auto id = QString::fromUtf8(request.readAll()).trimmed();
            if (id.isEmpty() || id == lastRequest) return;
            lastRequest = id;
            auto state = snapshot(); state["request"] = id;
            record("consumer-result.json", state);
        });
        poll.start(100);
        connect(qApp, &QCoreApplication::aboutToQuit, this, [this] {
            poll.stop();
            // Provider and consumer shutdown ordering is intentionally not assumed.
            record("consumer-exit.json", snapshot());
        });
    }
};

class AudioConsumerPlugin : public QGenericPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QGenericPluginFactoryInterface_iid FILE "audio-bridge-consumer.json")
public:
    QObject *create(const QString &name, const QString &) override {
        const auto directory = qEnvironmentVariable("GPMCP_AUDIO_CONSUMER_DIRECTORY");
        if (name != "guitarpro_audio_consumer" || !QDir::isAbsolutePath(directory)) return nullptr;
        QFile marker(directory + "/isolated-audio-consumer-test");
        if (!marker.open(QIODevice::ReadOnly) || marker.readAll().trimmed() != "gpmcp-audio-consumer-test") return nullptr;
        return new AudioConsumer(directory);
    }
};
#include "audio-bridge-consumer.moc"
