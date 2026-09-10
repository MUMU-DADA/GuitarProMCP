#include "mcp_server.h"
#include "plugin_config.h"
#include <QtCore/QCoreApplication>
#include <QtCore/QDateTime>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QJsonDocument>
#include <QtCore/QLockFile>
#include <QtCore/QPointer>
#include <QtCore/QRegularExpression>
#include <QtCore/QSaveFile>
#include <QtCore/QTimer>
#include <QtCore/QUuid>
#include <QtCore/QUrl>
#include <QtNetwork/QTcpSocket>
#include <exception>
#include <cmath>
#include <QtCore/QScopedValueRollback>

namespace {
constexpr int MaxBody = 1024 * 1024, MaxHeaders = 16384;
const QString Version = "2025-06-18";
const QStringList Versions = {Version};
QString randomId() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
QJsonObject rpcError(const QJsonValue &id, int code, const QString &message) {
    return {{"jsonrpc", "2.0"}, {"id", id.isUndefined() ? QJsonValue() : id}, {"error", QJsonObject{{"code", code}, {"message", message}}}};
}
QJsonObject rpcResult(const QJsonValue &id, const QJsonObject &result) {
    return {{"jsonrpc", "2.0"}, {"id", id}, {"result", result}};
}
void reply(QTcpSocket *socket, int status, const QJsonObject &body = {}, const QByteArray &extra = {}) {
    const QByteArray reason = status == 200 ? "OK" : status == 202 ? "Accepted" : status == 204 ? "No Content" :
        status == 401 ? "Unauthorized" : status == 403 ? "Forbidden" : status == 404 ? "Not Found" :
        status == 405 ? "Method Not Allowed" : status == 409 ? "Conflict" : status == 413 ? "Payload Too Large" : status == 415 ? "Unsupported Media Type" : "Bad Request";
    const QByteArray data = body.isEmpty() ? QByteArray() : QJsonDocument(body).toJson(QJsonDocument::Compact);
    socket->setProperty("replied", true);
    socket->write("HTTP/1.1 " + QByteArray::number(status) + " " + reason + "\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: " +
                  QByteArray::number(data.size()) + "\r\nConnection: close\r\nCache-Control: no-store\r\n" + extra + "\r\n" + data);
    socket->disconnectFromHost();
}
struct Request { QByteArray method, target, body; QMap<QByteArray, QByteArray> headers; };
// One bounded HTTP request per connection. No keep-alive state or SSE stream is required.
int parse(const QByteArray &bytes, Request &request, QString &error) {
    const int headEnd = bytes.indexOf("\r\n\r\n");
    if (headEnd < 0) { if (bytes.size() > MaxHeaders) { error = "Headers too large"; return -1; } return 0; }
    if (headEnd > MaxHeaders) { error = "Headers too large"; return -1; }
    const auto lines = bytes.left(headEnd).split('\n');
    const auto first = lines[0].trimmed().split(' ');
    if (first.size() != 3 || first[2] != "HTTP/1.1") { error = "Expected HTTP/1.1 request"; return -1; }
    request.method = first[0]; request.target = first[1];
    for (int i = 1; i < lines.size(); ++i) {
        QByteArray line = lines[i]; if (line.endsWith('\r')) line.chop(1);
        const int colon = line.indexOf(':');
        if (colon <= 0 || line[0] == ' ' || line[0] == '\t') { error = "Malformed header"; return -1; }
        QByteArray name = line.left(colon).toLower(), value = line.mid(colon + 1).trimmed();
        if (!QRegularExpression("^[a-z0-9!#$%&'*+.^_`|~-]+$").match(QString::fromLatin1(name)).hasMatch() ||
            value.contains('\r') || value.contains('\n') || value.contains('\0') || request.headers.contains(name)) {
            error = "Invalid or duplicate header"; return -1;
        }
        request.headers.insert(name, value);
    }
    if (!request.headers.contains("host")) { error = "Host header required"; return -1; }
    const QByteArray body = bytes.mid(headEnd + 4);
    if (request.headers.contains("transfer-encoding")) {
        if (request.headers.contains("content-length") || request.headers["transfer-encoding"].toLower() != "chunked") {
            error = "Unsupported or ambiguous framing"; return -1;
        }
        int offset = 0;
        while (true) {
            const int end = body.indexOf("\r\n", offset);
            if (end < 0) return 0;
            bool valid = false;
            const auto sizeText = body.mid(offset, end - offset).split(';')[0];
            const quint64 length = sizeText.toULongLong(&valid, 16);
            if (!valid || !QRegularExpression("^[0-9a-fA-F]+$").match(QString::fromLatin1(sizeText)).hasMatch() || length > MaxBody || request.body.size() + length > MaxBody) { error = "Invalid chunk size"; return -1; }
            offset = end + 2;
            if (!length) {
                if (body.size() < offset + 2) return 0;
                if (body.mid(offset, 2) == "\r\n") offset += 2;
                else { const int trailerEnd = body.indexOf("\r\n\r\n", offset); if (trailerEnd < 0) return 0; offset = trailerEnd + 4; }
                if (body.size() != offset) { error = "Extra data after request"; return -1; }
                return 1;
            }
            if (body.size() < offset + qint64(length) + 2) return 0;
            request.body += body.mid(offset, int(length)); offset += int(length);
            if (body.mid(offset, 2) != "\r\n") { error = "Invalid chunk delimiter"; return -1; }
            offset += 2;
        }
    }
    bool valid = false;
    const QByteArray sizeText = request.headers.value("content-length", "0");
    const quint64 length = sizeText.toULongLong(&valid);
    if (!valid || !QRegularExpression("^[0-9]+$").match(QString::fromLatin1(sizeText)).hasMatch() || length > MaxBody) {
        error = "Invalid Content-Length"; return -1;
    }
    if (body.size() < qint64(length)) return 0;
    if (body.size() != qint64(length)) { error = "Extra data after request"; return -1; }
    request.body = body; return 1;
}
bool saveJson(const QString &path, const QJsonObject &data) {
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly)) return false;
    const QByteArray bytes = QJsonDocument(data).toJson();
    return file.write(bytes) == bytes.size() && file.commit();
}
}

bool McpServer::start(const QString &path, QJsonObject identity, QJsonArray tools,
                     std::function<QJsonObject(const QString &, const QJsonObject &)> call) {
    catalog = tools; invoke = std::move(call);
    auto fail = [this](const QString &message) { startupError = message; return false; };
    startupError.clear();
    listener.setMaxPendingConnections(32);
    if (path.isEmpty()) return fail("Missing MCP session path");
    const QDir directory(QFileInfo(path).absolutePath());
    QLockFile startupLock(directory.filePath("mcp-startup.lock"));
    if (!startupLock.tryLock(1000)) return fail("Another instance is publishing its MCP connection; restart after it finishes");
    QFile tokenFile(directory.filePath("mcp-auth-token"));
    if (tokenFile.exists()) {
        if (!tokenFile.open(QIODevice::ReadOnly)) return fail("Cannot read local authentication token: " + tokenFile.errorString());
        token = QString::fromUtf8(tokenFile.readAll()).trimmed();
    } else {
        token = randomId() + randomId();
        QSaveFile file(tokenFile.fileName());
        if (!file.open(QIODevice::WriteOnly) || file.write(token.toUtf8()) != token.size() || !file.commit()) return fail("Cannot save local authentication token: " + file.errorString());
    }
    if (!QRegularExpression("^[A-Za-z0-9-]{32,128}$").match(token).hasMatch()) return fail("Invalid local authentication token");
    bool valid = true;
    const QString configuredPort = qEnvironmentVariable("GPMCP_PORT");
    const int port = configuredPort.isEmpty() ? 18432 : configuredPort.toInt(&valid);
    if (!valid || port < 1 || port > 65535) return fail("GPMCP_PORT must be an integer from 1 to 65535");
    if (!listener.listen(QHostAddress::LocalHost, quint16(port)) &&
        (!configuredPort.isEmpty() || !listener.listen(QHostAddress::LocalHost, 0)))
        return fail("Cannot listen on local MCP port: " + listener.errorString());
    const QString url = QString("http://127.0.0.1:%1/mcp").arg(listener.serverPort());
    descriptorPath = directory.filePath("native-session-" + instanceIdentity + ".json");
    instanceClientPath = directory.filePath("mcp-client-" + instanceIdentity + ".json");
    QFile previous(path);
    if (!previous.open(QIODevice::ReadOnly) || !gpmcp::liveDescriptor(QJsonDocument::fromJson(previous.readAll()).object())) aliasPath = path;
    previous.close();
    identity["instance_id"] = instanceIdentity;
    identity["process_start_time"] = gpmcp::processStartTime(QCoreApplication::applicationPid());
    identity["session_file"] = descriptorPath;
    identity["client_config"] = aliasPath.isEmpty() ? instanceClientPath : directory.filePath("mcp-client.json");
    identity["instance_client_config"] = instanceClientPath;
    identity["port"] = int(listener.serverPort()); identity["url"] = url;
    identity["preferred_port"] = port; identity["port_fallback"] = listener.serverPort() != port;
    identity["transport"] = "streamable-http"; identity["protocolVersion"] = Version;
    auto clientConfig = [&]() {
        QJsonObject headers{{"Authorization", "Bearer " + token}, {"GuitarProMCP-Instance-Id", instanceIdentity}};
        return QJsonObject{{"mcpServers", QJsonObject{{"guitarpro", QJsonObject{{"type", "streamable-http"}, {"url", url}, {"headers", headers}}}}}};
    };
    if (!saveJson(instanceClientPath, clientConfig()) || !saveJson(descriptorPath, identity) ||
        (!aliasPath.isEmpty() && (!saveJson(directory.filePath("mcp-client.json"), clientConfig()) || !saveJson(aliasPath, identity)))) {
        stop(); return fail("Cannot publish MCP session or client configuration");
    }
    connect(&listener, &QTcpServer::newConnection, this, &McpServer::accept);
    auto timer = new QTimer(this);
    connect(timer, &QTimer::timeout, this, [this]() {
        const qint64 expiry = QDateTime::currentMSecsSinceEpoch() - 30 * 60 * 1000;
        for (auto it = sessions.begin(); it != sessions.end();) { if (it->touched < expiry) it = sessions.erase(it); else ++it; }
    });
    timer->start(60000);
    return true;
}

void McpServer::accept() {
    while (QTcpSocket *socket = listener.nextPendingConnection()) {
        connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
        QTimer::singleShot(10000, socket, [socket]() { socket->abort(); });
        connect(socket, &QTcpSocket::readyRead, socket, [this, socket]() {
            if (socket->property("replied").toBool()) return;
            const QByteArray bytes = socket->property("buffer").toByteArray() + socket->readAll();
            if (bytes.size() > MaxBody + MaxHeaders + 65536) { reply(socket, 413); return; }
            socket->setProperty("buffer", bytes);
            Request request; QString error;
            const int complete = parse(bytes, request, error);
            if (!complete) {
                if (request.headers.value("expect").toLower() == "100-continue" && !socket->property("continue").toBool()) {
                    socket->setProperty("continue", true); socket->write("HTTP/1.1 100 Continue\r\n\r\n");
                }
                return;
            }
            if (complete < 0) { reply(socket, 400, {{"error", error}}); return; }
            const QByteArray port = QByteArray::number(listener.serverPort());
            if (request.headers["host"].toLower() != "127.0.0.1:" + port && request.headers["host"].toLower() != "localhost:" + port) {
                reply(socket, 403, {{"error", "Invalid Host"}}); return;
            }
            if (request.headers.contains("origin")) {
                const QByteArray origin = request.headers["origin"].toLower();
                if (origin != "http://127.0.0.1:" + port && origin != "http://localhost:" + port) {
                    reply(socket, 403, {{"error", "Invalid Origin"}}); return;
                }
            }
            if (request.headers.value("authorization") != "Bearer " + token.toUtf8()) {
                reply(socket, 401, {{"error", "Bearer token required"}}, "WWW-Authenticate: Bearer realm=\"GuitarProMCP\"\r\n"); return;
            }
            if (request.headers.contains("guitarpromcp-instance-id") && request.headers.value("guitarpromcp-instance-id") != instanceIdentity.toUtf8()) {
                reply(socket, 409, {{"error", "Guitar Pro instance changed; discover and explicitly select the intended instance"}}); return;
            }
            if (request.target != "/mcp") { reply(socket, 404); return; }
            const QString sessionId = QString::fromUtf8(request.headers.value("mcp-session-id"));
            if (request.method == "DELETE") {
                if (sessionId.isEmpty() || !sessions.remove(sessionId)) reply(socket, 404);
                else reply(socket, 204);
                return;
            }
            if (request.method != "POST") { reply(socket, 405, {}, "Allow: POST, DELETE\r\n"); return; }
            if (request.headers.value("content-type").split(';')[0].trimmed().toLower() != "application/json") { reply(socket, 415); return; }
            QJsonParseError parseError;
            const QJsonDocument document = QJsonDocument::fromJson(request.body, &parseError);
            if (parseError.error != QJsonParseError::NoError) { reply(socket, 400, rpcError({}, -32700, "Parse error")); return; }
            if (!document.isObject()) { reply(socket, 400, rpcError({}, -32600, "Expected a single JSON-RPC object")); return; }
            const QJsonObject rpc = document.object();
            const QJsonValue id = rpc.value("id");
            const QString method = rpc.value("method").toString();
            if (rpc.value("jsonrpc") != "2.0" || method.isEmpty() || (!id.isUndefined() && !id.isString() && !id.isDouble()) ||
                (rpc.contains("params") && !rpc.value("params").isObject())) {
                reply(socket, 400, rpcError({}, -32600, "Invalid JSON-RPC request")); return;
            }
            const QJsonObject params = rpc.value("params").toObject();
            if (method == "initialize") {
                if (id.isUndefined() || params.value("protocolVersion").toString().isEmpty() || !params.value("capabilities").isObject() ||
                    params.value("clientInfo").toObject().value("name").toString().isEmpty() || params.value("clientInfo").toObject().value("version").toString().isEmpty()) {
                    reply(socket, 400, rpcError(id, -32602, "id, protocolVersion, capabilities and clientInfo are required")); return;
                }
                if (sessions.size() >= 32) { reply(socket, 200, rpcError(id, -32000, "Too many sessions")); return; }
                const QString version = Versions.contains(params.value("protocolVersion").toString()) ? params.value("protocolVersion").toString() : Version;
                const QString key = randomId();
                sessions.insert(key, {version, false, QDateTime::currentMSecsSinceEpoch()});
                reply(socket, 200, rpcResult(id, {{"protocolVersion", version}, {"serverInfo", QJsonObject{{"name", "GuitarProMCP"}, {"version", "0.5.0"}}},
                      {"_meta", QJsonObject{{"instance_id", instanceIdentity}, {"pid", QCoreApplication::applicationPid()}}},
                      {"capabilities", QJsonObject{{"tools", QJsonObject{{"listChanged", false}}}}},
                      {"instructions", "Native C++ plugin. No Python, simulated input or foreground window is required. Inspect capabilities and observed state; verify mutations."}}),
                      "Mcp-Session-Id: " + key.toUtf8() + "\r\n"); return;
            }
            if (sessionId.isEmpty()) { reply(socket, 400, {{"error", "Mcp-Session-Id required"}}); return; }
            if (!sessions.contains(sessionId)) { reply(socket, 404, {{"error", "Session expired"}}); return; }
            auto &session = sessions[sessionId]; session.touched = QDateTime::currentMSecsSinceEpoch();
            if (request.headers.contains("mcp-protocol-version") && QString::fromUtf8(request.headers["mcp-protocol-version"]) != session.version) {
                reply(socket, 400, {{"error", "Protocol version differs from negotiation"}}); return;
            }
            if (id.isUndefined()) {
                if (method == "notifications/initialized") session.initialized = true;
                reply(socket, 202); return;
            }
            if (method == "ping") { reply(socket, 200, rpcResult(id, {})); return; }
            if (!session.initialized) { reply(socket, 200, rpcError(id, -32002, "Send notifications/initialized first")); return; }
            if (method == "tools/list") { reply(socket, 200, rpcResult(id, {{"tools", catalog}})); return; }
            if (method != "tools/call") { reply(socket, 200, rpcError(id, -32601, "Method not found")); return; }
            const QString name = params.value("name").toString();
            QJsonObject schema;
            for (const QJsonValue &tool : catalog)
                if (tool.toObject().value("name").toString() == name) schema = tool.toObject().value("inputSchema").toObject();
            if (schema.isEmpty() || (params.contains("arguments") && !params.value("arguments").isObject())) { reply(socket, 200, rpcError(id, -32602, "Unknown tool or invalid arguments")); return; }
            const QJsonObject arguments = params.value("arguments").toObject(), fields = schema.value("properties").toObject();
            QString invalid;
            for (const QJsonValue &key : schema.value("required").toArray())
                if (!arguments.contains(key.toString())) invalid = "Missing argument: " + key.toString();
            for (auto field = arguments.begin(); field != arguments.end(); ++field) {
                if (!fields.contains(field.key())) { invalid = "Unknown argument: " + field.key(); break; }
                const QString type = fields.value(field.key()).toObject().value("type").toString();
                const auto value = field.value();
                if ((type == "string" && !value.isString()) || (type == "boolean" && !value.isBool()) ||
                    (type == "integer" && (!value.isDouble() || std::floor(value.toDouble()) != value.toDouble() || std::abs(value.toDouble()) > 2147483647.0))) {
                    invalid = "Invalid argument type: " + field.key(); break;
                }
            }
            if (!invalid.isEmpty()) { reply(socket, 200, rpcError(id, -32602, invalid)); return; }
            if (invoking) { reply(socket, 200, rpcError(id, -32000, "Another native operation is running")); return; }
            QScopedValueRollback<bool> running(invoking, true);
            QJsonObject result;
            try { result = invoke(name, arguments); }
            catch (const std::exception &exception) { result = {{"error", QString::fromUtf8(exception.what())}}; }
            // Native tools normally return one structured object.  A tool may add
            // the private __mcp_image object when the response also needs standard
            // MCP image content; strip it before exposing structuredContent.
            const QJsonObject image = result.take("__mcp_image").toObject();
            QJsonArray content{QJsonObject{{"type", "text"},
                {"text", QString::fromUtf8(QJsonDocument(result).toJson(QJsonDocument::Compact))}}};
            if (!image.isEmpty() && image.value("data").isString() && image.value("mimeType").isString()) {
                content.append(QJsonObject{{"type", "image"}, {"data", image.value("data")},
                                           {"mimeType", image.value("mimeType")}});
            }
            reply(socket, 200, rpcResult(id, {{"content", content},
                  {"structuredContent", result}, {"isError", result.contains("error")}}));
        });
    }
}

void McpServer::stop() {
    for (const QString &path : {descriptorPath, aliasPath}) {
        if (path.isEmpty()) continue;
        QFile descriptor(path);
        if (descriptor.open(QIODevice::ReadOnly)) {
            const auto identity = QJsonDocument::fromJson(descriptor.readAll()).object();
            if (identity.value("instance_id") == instanceIdentity) {
                descriptor.close(); descriptor.remove();
            }
        }
    }
    descriptorPath.clear(); aliasPath.clear();
    if (!instanceClientPath.isEmpty()) { QFile::remove(instanceClientPath); instanceClientPath.clear(); }
    listener.close();
    for (auto socket : listener.findChildren<QTcpSocket *>()) socket->abort();
    sessions.clear();
}
McpServer::~McpServer() { stop(); }
