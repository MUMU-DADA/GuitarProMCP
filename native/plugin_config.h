#pragma once
#include <QtCore/QCoreApplication>
#include <QtCore/QDateTime>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QSaveFile>
#include <QtCore/QStandardPaths>
#include <windows.h>

namespace gpmcp {
inline QString processStartTime(qint64 pid) {
    if (pid < 1 || quint64(pid) > MAXDWORD) return {};
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, DWORD(pid));
    if (!process) return {};
    FILETIME created{}, exited{}, kernel{}, user{};
    const bool read = GetProcessTimes(process, &created, &exited, &kernel, &user);
    CloseHandle(process);
    if (!read || exited.dwHighDateTime || exited.dwLowDateTime) return {};
    return QString::number((quint64(created.dwHighDateTime) << 32) | created.dwLowDateTime);
}
inline bool liveDescriptor(const QJsonObject &identity) {
    const QString created = processStartTime(identity.value("pid").toVariant().toLongLong());
    // Preserve a live older descriptor that predates process-start identities.
    return !created.isEmpty() && (!identity.contains("process_start_time") || identity.value("process_start_time") == created);
}
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
