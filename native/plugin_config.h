#pragma once
#include <QtCore/QCoreApplication>
#include <QtCore/QDateTime>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QSaveFile>
#include <QtCore/QStandardPaths>

namespace gpmcp {
inline QString dataDirectory() {
    const QString configured = qEnvironmentVariable("GPMCP_DATA_DIR");
    return configured.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/GuitarProMCP" : configured;
}
inline bool readSettings(QJsonObject &settings) {
    QFile file(QDir(dataDirectory()).filePath("settings.json"));
    if (!file.exists()) return true;
    if (!file.open(QIODevice::ReadOnly)) return false;
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return false;
    settings = document.object();
    return !settings.contains("enabled") || settings.value("enabled").isBool();
}
inline bool writeEnabled(bool enabled) {
    QJsonObject settings;
    if (!readSettings(settings) || !QDir().mkpath(dataDirectory())) return false;
    settings["enabled"] = enabled;
    QSaveFile file(QDir(dataDirectory()).filePath("settings.json"));
    const auto bytes = QJsonDocument(settings).toJson();
    return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size() && file.commit();
}
inline void diagnostic(const QString &status, const QString &detail = {}) {
    qApp->setProperty("gpmcpStatus", status);
    qApp->setProperty("gpmcpStatusDetail", detail);
    if (!QDir().mkpath(dataDirectory())) return;
    QSaveFile file(QDir(dataDirectory()).filePath("status.json"));
    if (!file.open(QIODevice::WriteOnly)) return;
    file.write(QJsonDocument(QJsonObject{{"status", status}, {"detail", detail},
        {"pid", QCoreApplication::applicationPid()}, {"executable", QCoreApplication::applicationFilePath()},
        {"time", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)}}).toJson());
    file.commit();
}
}
