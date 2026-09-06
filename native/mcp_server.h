#pragma once
#include <QtCore/QObject>
#include <QtCore/QJsonObject>
#include <QtCore/QJsonArray>
#include <QtCore/QHash>
#include <QtNetwork/QTcpServer>
#include <functional>

class McpServer final : public QObject {
    struct Session { QString version; bool initialized = false; qint64 touched = 0; };
    QTcpServer listener{this};
    QString token, descriptorPath, startupError;
    bool invoking = false;
    QHash<QString, Session> sessions;
    QJsonArray catalog;
    std::function<QJsonObject(const QString &, const QJsonObject &)> invoke;
    void accept();
public:
    explicit McpServer(QObject *parent = nullptr) : QObject(parent) {}
    ~McpServer() override;
    void stop();
    QString errorString() const { return startupError; }
    bool start(const QString &path, QJsonObject identity, QJsonArray tools,
               std::function<QJsonObject(const QString &, const QJsonObject &)> call);
};
