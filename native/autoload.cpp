#include <QtGui/QImageIOPlugin>
#include <QtGui/QGenericPlugin>
#include <QtCore/QFileInfo>
#include <QtCore/QPluginLoader>
#include <QtCore/QTimer>
#include "host_build.h"
#include "plugin_config.h"
#include "plugin_status.h"

class GuitarProAutoload : public QImageIOPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID "org.qt-project.Qt.QImageIOHandlerFactoryInterface" FILE "autoload.json")
public:
    GuitarProAutoload() {
        if (!qApp || QFileInfo(QCoreApplication::applicationFilePath()).baseName().compare("GuitarPro", Qt::CaseInsensitive) ||
            qApp->property("gpmcpAutoloadScheduled").toBool()) return;
        qApp->setProperty("gpmcpAutoloadScheduled", true);
        // Image-plugin discovery can precede QApplication construction finishing.
        QTimer::singleShot(0, qApp, [] {
            gpmcp::installStatusAction();
            if (qApp->property("gpmcpBridge").value<QObject *>()) return;
            QJsonObject settings;
            if (!gpmcp::readSettings(settings)) { gpmcp::diagnostic("configuration_error", "Invalid settings.json"); return; }
            if (!settings.value("enabled").toBool(true)) { gpmcp::diagnostic("disabled"); return; }
            if (!guitarpro::supportedBuild() || !guitarpro::verifiedHostFile("GPRSE.dll") || !guitarpro::verifiedHostFile("Qt5Core.dll")) {
                gpmcp::diagnostic("unsupported_host", "Private interface files do not match a verified build"); return;
            }
            auto loader = new QPluginLoader(QCoreApplication::applicationDirPath() + "/Plugins/generic/guitarpro_mcp.dll", qApp);
            loader->setLoadHints(QLibrary::PreventUnloadHint);
            auto plugin = qobject_cast<QGenericPlugin *>(loader->instance());
            QObject *bridge = plugin ? plugin->create("guitarpro_mcp", {}) : nullptr;
            if (!bridge) {
                gpmcp::diagnostic("load_error", loader->errorString());
                delete loader;
            } else {
                // This path calls create directly, so Qt's generic-plugin list does not own it.
                qApp->connect(qApp, &QCoreApplication::aboutToQuit, bridge, &QObject::deleteLater);
            }
        });
    }
    Capabilities capabilities(QIODevice *, const QByteArray &) const override { return {}; }
    QImageIOHandler *create(QIODevice *, const QByteArray &) const override { return nullptr; }
};

#include "autoload.moc"
