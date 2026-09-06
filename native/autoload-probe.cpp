#include <QtGui/QImageIOPlugin>
#include <QtCore/QCoreApplication>
#include <QtCore/QFileInfo>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QSaveFile>
#include <QtCore/QTimer>

class AutoloadProbe : public QImageIOPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID "org.qt-project.Qt.QImageIOHandlerFactoryInterface" FILE "autoload-probe.json")
public:
    AutoloadProbe() {
        if (!qApp || QFileInfo(QCoreApplication::applicationFilePath()).baseName() != "GuitarPro") return;
        QTimer::singleShot(0, qApp, [] {
            QSaveFile output(QCoreApplication::applicationDirPath() + "/autoload-probe-result.json");
            if (!output.open(QIODevice::WriteOnly)) return;
            output.write(QJsonDocument(QJsonObject{
                {"pid", QCoreApplication::applicationPid()},
                {"executable", QCoreApplication::applicationFilePath()},
                {"qt", qVersion()},
                {"generic_environment", qEnvironmentVariable("QT_QPA_GENERIC_PLUGINS")}
            }).toJson());
            output.commit();
        });
    }
    Capabilities capabilities(QIODevice *, const QByteArray &) const override { return {}; }
    QImageIOHandler *create(QIODevice *, const QByteArray &) const override { return nullptr; }
};

#include "autoload-probe.moc"
