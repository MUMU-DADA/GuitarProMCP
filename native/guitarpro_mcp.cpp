#include <QtGui/QGenericPlugin>
#include <QtGui/QFileOpenEvent>
#include <QtGui/QWindow>
#include <QtWidgets/QApplication>
#include <QtWidgets/QAction>
#include <QtWidgets/QAbstractButton>
#include <QtWidgets/QPushButton>
#include <QtWidgets/QWidget>
#include <QtWidgets/QStackedWidget>
#include <QtWidgets/QDialog>
#include <QtWidgets/QDialogButtonBox>
#include <QtWidgets/QMessageBox>
#include <QtWidgets/QLabel>
#include <QtCore/QElapsedTimer>
#include <QtCore/QDateTime>
#include <QtCore/QFileInfo>
#include <QtCore/QDirIterator>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QMetaEnum>
#include <QtCore/QMetaProperty>
#include <QtCore/QMetaMethod>
#include <QtCore/QThread>
#include "mcp_server.h"
#include "plugin_config.h"
#include "discovery.h"
#include "guitarpro_api.h"
#include "guitarpro_audio.h"
#include "guitarpro_audio_stream.h"
#include "guitarpro_io.h"
#include "guitarpro_clipboard.h"
#include "guitarpro_semantics.h"
#include "object_registry.h"
#include "window_capture.h"
#include <QtCore/QEvent>
#include <QtCore/QPointer>
#include <QtCore/QSaveFile>
#include <QtCore/QSet>
#include <QtCore/QScopedValueRollback>
#include <QtCore/QTimer>
#include <QtCore/QUuid>
#include <QtNetwork/QTcpServer>
#include <QtNetwork/QTcpSocket>
#include <windows.h>
#include <cmath>
#include <cstddef>
#include <algorithm>
#include <cstring>

static QString nonce() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
static const QStringList writableNames = {"checked", "value", "currentIndex", "currentRow", "currentText", "text", "plainText"};

static QJsonValue preferenceJsonValue(const QMetaProperty &property, const QVariant &value) {
    if (property.isEnumType()) return value.isValid() ? QJsonValue(value.toInt()) : QJsonValue();
    if (value.type() == QVariant::StringList) return QJsonArray::fromStringList(value.toStringList());
    if (value.type() == QVariant::List) return QJsonValue::fromVariant(value);
    return QJsonValue::fromVariant(value);
}

static QJsonArray preferenceEnumChoices(const QMetaProperty &property) {
    QJsonArray choices;
    if (!property.isEnumType()) return choices;
    const QMetaEnum enumeration = property.enumerator();
    for (int i = 0; i < enumeration.keyCount(); ++i) choices.append(QString::fromLatin1(enumeration.key(i)));
    return choices;
}

static bool preferenceValue(const QMetaProperty &property, const QJsonValue &input, QVariant *result, QString *error) {
    if (property.isEnumType()) {
        int enumValue = 0;
        if (input.isString()) {
            bool found = false;
            enumValue = property.enumerator().keyToValue(input.toString().toLatin1().constData(), &found);
            if (!found) { if (error) *error = "Choose an enum key from property_info"; return false; }
        } else if (input.isDouble() && std::isfinite(input.toDouble()) && std::floor(input.toDouble()) == input.toDouble() && input.toDouble() >= -2147483648.0 && input.toDouble() <= 2147483647.0) {
            enumValue = input.toInt();
            if (property.enumerator().valueToKey(enumValue) == nullptr) { if (error) *error = "Choose an enum value from property_info"; return false; }
        } else { if (error) *error = "Enum preferences require a key or integer value"; return false; }
        QVariant converted(enumValue);
        if (!converted.convert(property.userType())) converted = QVariant(enumValue);
        *result = converted;
        return true;
    }
    const int type = property.userType();
    if (type == QMetaType::Bool) {
        if (!input.isBool()) { if (error) *error = "Preference requires a boolean"; return false; }
    } else if (type == QMetaType::QString) {
        if (!input.isString() || !guitarpro::validHostText(input.toString())) { if (error) *error = "Preference requires valid host text"; return false; }
    } else if (type == QMetaType::QStringList) {
        if (!input.isArray()) { if (error) *error = "Preference requires an array of strings"; return false; }
        QStringList values;
        for (const auto &item : input.toArray()) {
            if (!item.isString() || !guitarpro::validHostText(item.toString())) { if (error) *error = "Preference requires an array of valid host strings"; return false; }
            values.append(item.toString());
        }
        *result = values;
        return true;
    } else if (type == QMetaType::Int || type == QMetaType::UInt || type == QMetaType::LongLong || type == QMetaType::ULongLong) {
        if (!input.isDouble() || !std::isfinite(input.toDouble()) || std::floor(input.toDouble()) != input.toDouble()) { if (error) *error = "Preference requires an integer"; return false; }
        if ((type == QMetaType::Int && (input.toDouble() < -2147483648.0 || input.toDouble() > 2147483647.0)) ||
            (type == QMetaType::UInt && (input.toDouble() < 0 || input.toDouble() > 4294967295.0)) ||
            ((type == QMetaType::LongLong || type == QMetaType::ULongLong) && (std::abs(input.toDouble()) > 9007199254740991.0 || (type == QMetaType::ULongLong && input.toDouble() < 0)))) { if (error) *error = "Preference integer is outside the supported range"; return false; }
    } else if (type == QMetaType::Double) {
        if (!input.isDouble() || !std::isfinite(input.toDouble())) { if (error) *error = "Preference requires a finite number"; return false; }
    } else {
        if (error) *error = "Native preference type is not supported";
        return false;
    }
    QVariant converted = input.toVariant();
    if (!converted.convert(type)) { if (error) *error = "Preference value has the wrong type"; return false; }
    *result = converted;
    return true;
}

static bool samePreferenceValue(const QMetaProperty &property, const QVariant &left, const QVariant &right) {
    if (property.isEnumType()) return left.toInt() == right.toInt();
    return left == right;
}

class Bridge : public QObject {
    McpServer server{this};
    WindowCapture windows{server.instanceId()};
    ObjectRegistry registry;
    guitarpro::ScoreClipboard clipboardBuffer;
    guitarpro::AudioStreamRegistry audioStreams;

    QString sessionFile;
    QString snapshot;
    QElapsedTimer observedAt;
    QHash<int, QPointer<QObject>> observed;
    QHash<QObject *, QPointer<QObject>> nativeObjects;
    QJsonObject creation;
    QList<QPointer<QObject>> creationBefore;
    QPointer<QObject> creationDocument;
    QElapsedTimer creationElapsed;
    QTimer creationPoll{this};
    std::shared_ptr<gp::core::Score> creationPrepared;
    QJsonObject opening;
    QElapsedTimer openingElapsed;
    QTimer openingPoll{this};
    bool loadNativeActive = false;
    QString loadingKind;
    QPointer<QDialog> loadModal;
    QJsonObject saving;
    QJsonObject exporting;
    QJsonObject moving;
    QJsonObject editing;
    bool editingNativeActive = false;
    std::function<QJsonObject()> pendingRecovery;
    QString recoveryRequest;
    bool recoveryActive = false;
    QJsonObject *savingOperation = nullptr;
    QPointer<QDialog> saveModal;
    QHash<QString, QJsonObject> operationHistory;
    QStringList operationOrder;
    QJsonObject closing;
    QPointer<QWidget> closingView;
    QPointer<QWidget> closingModal;
    bool closingNativeActive = false;
    QElapsedTimer closingElapsed;
    bool hiddenMode = qEnvironmentVariable("GPMCP_BACKGROUND") == "1";
    bool shuttingDown = false;
    const bool originalQuitOnLastWindow = qApp->quitOnLastWindowClosed();
    QPointer<QWidget> noFocusWindow;

    void shutdown() {
        if (shuttingDown) return;
        shuttingDown = true;
        creationPoll.stop();
        openingPoll.stop();
        if (qApp) {
            qApp->removeEventFilter(this);
            qApp->setProperty("gpmcpBridge", QVariant());
            qApp->setProperty("gpmcpSessionFile", QVariant());
        }
        for (const auto &object : nativeObjects)
            if (object) QObject::disconnect(object, nullptr, this, nullptr);
        registry.uninstall();
        server.stop();
        clipboardBuffer = {};
        pendingRecovery = {};
        guitarpro::clearAudioBindings();
        audioStreams.clear();
        nativeObjects.clear(); observed.clear(); creationBefore.clear();
    }

    QJsonObject modalState() const {
        QWidget *modal = QApplication::activeModalWidget();
        if (!modal) return {{"blocked", false}};
        QJsonArray labels, buttons;
        for (QLabel *label : modal->findChildren<QLabel *>()) {
            if (labels.size() >= 24) break;
            if (!label->text().isEmpty()) labels.append(label->text().left(2048));
        }
        for (QAbstractButton *button : modal->findChildren<QAbstractButton *>()) {
            int standard = 0, role = -1;
            if (auto box = qobject_cast<QMessageBox *>(modal)) {
                standard = int(box->standardButton(button)); role = int(box->buttonRole(button));
            } else for (QDialogButtonBox *box : modal->findChildren<QDialogButtonBox *>()) {
                if (box->buttons().contains(button)) { standard = int(box->standardButton(button)); role = int(box->buttonRole(button)); break; }
            }
            buttons.append(QJsonObject{{"name", button->objectName()}, {"text", button->text()}, {"enabled", button->isEnabled()}, {"standard_button", standard}, {"button_role", role}});
        }
        return {{"blocked", true}, {"class", modal->metaObject()->className()}, {"name", modal->objectName()},
            {"title", modal->windowTitle()}, {"visible", modal->isVisible()}, {"labels", labels}, {"buttons", buttons}};
    }

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
        if (!pending(closing)) return;
        if (savingOperation == &closing) return;
        if (closingNativeActive) {
            if (QApplication::activeModalWidget()) closing["dialog"] = modalState();
            return;
        }
        if (!closingView) { closing["status"] = "closed"; closing.remove("outcome_unknown"); closing.remove("error"); }
        else if (closingElapsed.elapsed() > 10000) {
            closing["status"] = "error";
            closing["error"] = "Document still exists after close request; inspect documents and dialogs";
            closing["outcome_unknown"] = true;
        }
    }

    static void nativeFailure(QJsonObject &operation, const QString &message) {
        operation["status"] = "error";
        operation["error"] = message;
        operation["native_error"] = message;
        operation["outcome_unknown"] = true;
    }

    void checkCreation() {
        if (!creationPoll.isActive()) return;
        if (loadNativeActive && loadingKind == "create") {
            if (QApplication::activeModalWidget()) creation["dialog"] = modalState();
            return;
        }
        const QString path = creation.value("template_path").toString();
        for (const auto &document : guitarpro::documents()) {
            if (creationBefore.contains(document.object) || !document.score ||
                (document.object != creationDocument && document.object->property("saveFilePath").toString() != path)) continue;
            creationDocument = document.object;
            creation["document"] = document.id();
            const QString documentId = document.id();
            const QString openedBefore = document.object->property("openedFilePath").toString();
            const auto attempted = std::make_shared<bool>(false);
            const auto commitRecovery = std::make_shared<std::function<QJsonObject()>>();
            const auto adopt = [this, document, path, openedBefore, documentId, prepared = creationPrepared, attempted, commitRecovery]() -> QJsonObject {
                if (!document.object || !document.view)
                    return {{"resolution", "document_closed"}, {"document", documentId}};
                for (const char *property : {"openedFilePath", "saveFilePath"}) {
                    const QString current = document.object->property(property).toString();
                    const QString expected = QByteArray(property) == "openedFilePath" ? openedBefore : path;
                    if (!current.isEmpty() && current != expected)
                        return {{"error", "New document path changed; retained recovery cannot overwrite it"}, {"outcome_unknown", true}};
                }
                const QString empty;
                if (!QMetaObject::invokeMethod(document.object, "setOpenedFilePath", Qt::DirectConnection, Q_ARG(QString, empty)) ||
                    !document.object || !QMetaObject::invokeMethod(document.object, "setSaveFilePath", Qt::DirectConnection, Q_ARG(QString, empty)) ||
                    !document.object || !document.object->property("openedFilePath").toString().isEmpty() || !document.object->property("saveFilePath").toString().isEmpty())
                    return {{"error", "Native template path reset did not complete"}, {"outcome_unknown", true}};
                if (prepared) {
                    if (*attempted) {
                        if (!*commitRecovery) return {{"resolution", "created"}, {"document", documentId}};
                        auto observed = (*commitRecovery)();
                        if (observed.value("resolution") == "applied") observed["resolution"] = "created";
                        return observed;
                    }
                    const auto activated = guitarpro::activate({{"document", documentId}}, services());
                    if (activated.contains("error")) return activated;
                    *attempted = true;
                    const auto applied = guitarpro::semanticCommit(document, prepared, *commitRecovery);
                    creation["spec_result"] = applied;
                    if (applied.contains("error")) return applied;
                }
                return {{"resolution", "created"}, {"document", document.id()}};
            };
            QJsonObject result;
            try { result = adopt(); }
            catch (const std::exception &exception) { result = {{"error", QString::fromUtf8(exception.what())}, {"outcome_unknown", true}}; }
            catch (...) { result = {{"error", "Unknown native template path exception"}, {"outcome_unknown", true}}; }
            creationPoll.stop(); creationBefore.clear();
            if (result.contains("error")) {
                nativeFailure(creation, result.value("error").toString());
                pendingRecovery = adopt; recoveryRequest = creation.value("request").toString();
                creation["recovery_available"] = true;
            } else {
                creation["status"] = result.value("resolution") == "created" ? "created" : "error";
                creation.remove("outcome_unknown"); creation.remove("error");
                if (creation.value("status") == "error") creation["error"] = "New document closed before initialization completed";
            }
            creationPrepared.reset();
            return;
        }
        if (creation.value("status") == "cancelling" && creation.value("cancel_decision_available").toBool()) {
            creation["status"] = "cancelled"; creationPoll.stop(); creationBefore.clear(); return;
        }
        if (creationElapsed.elapsed() > 10000 && !creation.contains("error")) {
            creation["status"] = "error";
            creation["error"] = "No new template document observed within 10 seconds; inspect documents and dialogs";
            creation["outcome_unknown"] = true;
        }
    }

    static bool pending(const QJsonObject &operation) {
        const QString status = operation.value("status").toString();
        return status == "scheduled" || status == "requested" || status == "cancelling" || operation.value("outcome_unknown").toBool();
    }

    void archiveOperation(const QJsonObject &operation) {
        const QString request = operation.value("request").toString();
        if (request.isEmpty()) return;
        operationHistory.insert(request, operation); operationOrder.append(request);
        while (operationOrder.size() > 64) operationHistory.remove(operationOrder.takeFirst());
    }

    QJsonObject scheduleSemantic(const QString &tool, QJsonObject args) {
        const auto target = guitarpro::choose(args);
        if (!target.score || !target.view) return {{"error", "Choose an existing verified document"}};
        args["document"] = target.id();
        if (tool == "gp_apply_spec" || tool == "gp_import_json") {
            QJsonObject spec; QString error;
            if (!guitarpro::semanticParseSpec(args, &spec, &error) || !guitarpro::semanticValidateSpec(spec, &error)) return {{"error", error}};
            args["spec"] = spec;
        }
        archiveOperation(editing); pendingRecovery = {};
        editing = {{"request", nonce()}, {"status", "scheduled"}, {"kind", tool}, {"document", target.id()}};
        const QString request = editing.value("request").toString();
        const int delay = qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT") ? qBound(0, args.value("debug_delay_ms").toInt(), 2000) : 0;
        QTimer::singleShot(delay, this, [this, tool, args, request]() {
            if (editing.value("request") != request || editing.value("status") != "scheduled") return;
            QScopedValueRollback<bool> active(editingNativeActive, true);
            editing["status"] = "requested"; recoveryRequest = request;
            QJsonObject result;
            try {
                if (QApplication::activeModalWidget()) throw std::runtime_error("A dialog appeared before the edit; resolve it and issue a new request");
                result = guitarpro::activate({{"document", args.value("document")}}, services());
                guitarpro::semanticResult(result);
                if (tool == "gp_apply_spec" || tool == "gp_import_json") result = guitarpro::applySpec(args, pendingRecovery);
                else if (tool == "gp_insert_tab") result = guitarpro::insertTab(args, pendingRecovery);
                else if (tool == "gp_edit_chord") result = guitarpro::editChord(args, pendingRecovery);
                else if (tool == "gp_edit_lyrics") result = guitarpro::editLyrics(args, pendingRecovery);
                else if (tool == "gp_edit_section") result = guitarpro::editSection(args, pendingRecovery);
                else result = guitarpro::presentation(args, &pendingRecovery);
            } catch (const std::exception &e) { result = {{"error", QString::fromUtf8(e.what())}, {"outcome_unknown", bool(pendingRecovery)}}; }
            catch (...) { result = {{"error", "Unknown native semantic edit exception"}, {"outcome_unknown", bool(pendingRecovery)}}; }
            editing["result"] = result;
            editing["status"] = result.contains("error") ? "error" : result.value("status").toString("applied");
            editing["native_returned"] = true;
            editing["recovery_available"] = bool(pendingRecovery);
            if (result.contains("error")) editing["error"] = result.value("error");
            if (result.value("outcome_unknown").toBool()) editing["outcome_unknown"] = true;
        });
        return editing;
    }

    void checkOpening() {
        if (!openingPoll.isActive()) return;
        auto midiDialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
        if (loadingKind == "open" && QSet<QString>{"mid", "midi"}.contains(QFileInfo(opening.value("path").toString()).suffix().toLower()) &&
            midiDialog && QByteArray(midiDialog->metaObject()->className()) == "gp::gui::MidiImportDialog") {
            loadModal = midiDialog;
            opening["dialog"] = modalState();
            openingElapsed.restart();
            return;
        }
        if (loadNativeActive && loadingKind == "open") {
            if (QApplication::activeModalWidget()) opening["dialog"] = modalState();
            return;
        }
        for (const auto &document : guitarpro::documents()) {
            if (document.score && QFileInfo(guitarpro::localDocumentPath(document.object->property("openedFilePath").toString())).canonicalFilePath().compare(opening.value("path").toString(), Qt::CaseInsensitive) == 0) {
                opening["status"] = "opened"; opening["document"] = document.id();
                opening.remove("error"); opening.remove("outcome_unknown"); opening.remove("dialog"); openingPoll.stop(); return;
            }
        }
        if (opening.value("status") == "cancelling" && opening.value("cancel_decision_available").toBool()) { opening["status"] = "cancelled"; openingPoll.stop(); return; }
        if (openingElapsed.elapsed() > 10000 && !opening.contains("error")) {
            opening["status"] = "error";
            opening["error"] = "No document observed within 10 seconds; inspect documents and dialogs before retrying";
            opening["outcome_unknown"] = true;
        }
    }

    void dispatchLoad(const QString &kind, const QString &path) {
        const QString request = (kind == "open" ? opening : creation).value("request").toString();
        QTimer::singleShot(0, this, [this, kind, path, request]() {
            QJsonObject &operation = kind == "open" ? opening : creation;
            if (operation.value("request") != request || operation.value("status") != "scheduled") return;
            operation["status"] = "requested";
            if (kind == "open" && QFileInfo(path).suffix().compare("gp", Qt::CaseInsensitive) == 0) {
                const QString validation = guitarpro::validateGpFile(path);
                if (!validation.isEmpty()) {
                    operation["status"] = "error"; operation["error"] = validation; operation["failure_stage"] = "validation";
                    openingPoll.stop(); return;
                }
            }
            loadingKind = kind; loadModal.clear();
            {
                QScopedValueRollback<bool> active(loadNativeActive, true);
                try {
                    QFileOpenEvent event(path);
                    QCoreApplication::sendEvent(qApp, &event);
                } catch (const std::exception &exception) { nativeFailure(operation, QString::fromUtf8(exception.what())); }
                catch (...) { nativeFailure(operation, "Unknown native document load exception"); }
            }
            operation["native_returned"] = true;
            if (kind == "open") checkOpening(); else checkCreation();
            if (pending(operation) && !operation.contains("native_error") && !operation.value("recovery_available").toBool() && operation.contains("dialog") && !QApplication::activeModalWidget()) {
                operation["status"] = "error";
                operation["error"] = "Native file operation ended after a dialog without the expected document";
                operation.remove("outcome_unknown");
                if (kind == "open") openingPoll.stop(); else { creationPoll.stop(); creationBefore.clear(); }
            }
        });
    }

    void refreshOperations() {
        checkCreation(); checkOpening(); checkClosing();
        if (savingOperation && saveModal && saveModal == QApplication::activeModalWidget()) (*savingOperation)["dialog"] = modalState();
    }

    QJsonObject performSave(const QJsonObject &args, bool adopt, bool current, QJsonObject &operation) {
        QScopedValueRollback<QJsonObject *> running(savingOperation, &operation);
        saveModal.clear();
        pendingRecovery = {};
        recoveryRequest = operation.value("request").toString();
        try {
            auto result = guitarpro::save(args, pendingRecovery, adopt, current);
            result["recovery_available"] = bool(pendingRecovery);
            operation["recovery_available"] = bool(pendingRecovery);
            if (result.value("outcome_unknown").toBool()) operation["outcome_unknown"] = true;
            return result;
        }
        catch (const std::exception &exception) {
            operation["outcome_unknown"] = true;
            return {{"error", QString::fromUtf8(exception.what())}, {"outcome_unknown", true}};
        }
        catch (...) {
            operation["outcome_unknown"] = true;
            return {{"error", "Unknown native save exception"}, {"outcome_unknown", true}};
        }
    }

    static bool cancelledSave(const QJsonObject &operation, const QJsonObject &result) {
        return operation.value("cancel_requested").toBool() && operation.value("cancel_decision_available").toBool() && result.contains("error") &&
            result.value("file_restored").toBool() && result.value("save_path_restored").toBool() &&
            result.value("opened_path_restored").toBool() && result.value("dirty_state_restored").toBool() &&
            !result.value("native_exception").toBool() && !result.value("outcome_unknown").toBool();
    }

    QJsonObject cancelOperation(const QString &request) {
        for (auto operation : {&creation, &opening, &closing, &saving, &moving, &exporting, &editing}) {
            if (operation->value("request") != request) continue;
            if (!pending(*operation)) return {{"error", "Operation already completed"}, {"operation", *operation}};
            if (operation->value("status") == "scheduled") {
                (*operation)["status"] = "cancelled";
                if (operation == &creation) { creationPoll.stop(); creationBefore.clear(); }
                if (operation == &opening) openingPoll.stop();
                return *operation;
            }
            if (operation == &exporting) {
                (*operation)["cancel_requested"] = true;
                (*operation)["status"] = "cancelling";
                return *operation;
            }
            if (operation == savingOperation && saveModal && saveModal == QApplication::activeModalWidget()) {
                (*operation)["status"] = "cancelling";
                (*operation)["cancel_requested"] = true;
                bool cancelAvailable = false;
                if (auto box = qobject_cast<QMessageBox *>(saveModal)) cancelAvailable = box->button(QMessageBox::Cancel) != nullptr;
                else for (QDialogButtonBox *box : saveModal->findChildren<QDialogButtonBox *>()) cancelAvailable |= box->button(QDialogButtonBox::Cancel) != nullptr;
                (*operation)["cancel_decision_available"] = cancelAvailable;
                const QPointer<QDialog> dialog = saveModal;
                QTimer::singleShot(0, this, [this, dialog, request]() {
                    if (savingOperation && savingOperation->value("request") == request && dialog && dialog == QApplication::activeModalWidget()) dialog->reject();
                });
                return *operation;
            }
            if (operation == &closing && closingNativeActive && closingModal == QApplication::activeModalWidget()) {
                QPointer<QAbstractButton> cancel;
                if (auto box = qobject_cast<QMessageBox *>(closingModal)) cancel = box->button(QMessageBox::Cancel);
                else if (closingModal) for (QDialogButtonBox *box : closingModal->findChildren<QDialogButtonBox *>()) {
                    if (box->button(QDialogButtonBox::Cancel)) { cancel = box->button(QDialogButtonBox::Cancel); break; }
                }
                if (cancel && cancel->isEnabled()) {
                    (*operation)["status"] = "cancelling";
                    QTimer::singleShot(0, this, [this, request, cancel]() {
                        if (closing.value("request") == request && closingNativeActive && closingModal == QApplication::activeModalWidget() && cancel) cancel->click();
                    });
                    return *operation;
                }
            } else if ((loadNativeActive || (operation == &opening && loadModal && QByteArray(loadModal->metaObject()->className()) == "gp::gui::MidiImportDialog")) && loadModal == QApplication::activeModalWidget() && loadModal &&
                       ((operation == &opening && loadingKind == "open") || (operation == &creation && loadingKind == "create"))) {
                (*operation)["status"] = "cancelling";
                bool cancelAvailable = false;
                if (auto box = qobject_cast<QMessageBox *>(loadModal)) cancelAvailable = box->button(QMessageBox::Cancel) != nullptr;
                else for (auto box : loadModal->findChildren<QDialogButtonBox *>()) cancelAvailable |= box->button(QDialogButtonBox::Cancel) != nullptr;
                (*operation)["cancel_decision_available"] = cancelAvailable;
                QPointer<QDialog> dialog = loadModal;
                const QString kind = loadingKind;
                QTimer::singleShot(0, this, [this, dialog, kind, request]() {
                    if ((kind == "open" ? opening : creation).value("request") == request && loadingKind == kind &&
                        dialog && dialog == QApplication::activeModalWidget()) dialog->reject();
                });
                return *operation;
            }
            return {{"error", "Native operation has no cancellable dialog; inspect its outcome before retrying"}, {"operation", *operation}};
        }
        return {{"error", operationHistory.contains(request) ? "Operation already completed" : "Unknown or expired operation request"}};
    }

    QJsonObject recoverOperation(const QString &request) {
        if (recoveryActive || editingNativeActive || loadNativeActive || closingNativeActive || savingOperation || QApplication::activeModalWidget())
            return {{"error", "A native operation or dialog is still active; inspect gp_operation and gp_dialogs"}};
        for (auto operation : {&creation, &opening, &closing, &saving, &moving, &editing}) {
            if (operation->value("request") != request) continue;
            if (operation->value("status") != "error" || !operation->value("outcome_unknown").toBool() || request != recoveryRequest || !pendingRecovery)
                return {{"error", "This operation has no pending recoverable outcome"}, {"operation", *operation}};
            QScopedValueRollback<bool> running(recoveryActive, true);
            const auto retry = pendingRecovery;
            QJsonObject result;
            try { result = retry(); }
            catch (const std::exception &exception) { result = {{"error", QString::fromUtf8(exception.what())}, {"outcome_unknown", true}}; }
            catch (...) { result = {{"error", "Unknown native recovery exception"}, {"outcome_unknown", true}}; }
            const bool recovered = !result.contains("error") && !result.value("outcome_unknown").toBool();
            result["status"] = recovered ? "recovered" : "error";
            result["request"] = request;
            (*operation)["recovery"] = result;
            (*operation)["recovery_attempts"] = operation->value("recovery_attempts").toInt() + 1;
            if (recovered) {
                operation->remove("outcome_unknown");
                (*operation)["recovered"] = true;
                (*operation)["recovery_available"] = false;
                pendingRecovery = {};
                recoveryRequest.clear();
            }
            return result;
        }
        return {{"error", "Unknown, completed or expired recovery request"}};
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
                {"instance_id", server.instanceId()}, {"process_start_time", gpmcp::processStartTime(QCoreApplication::applicationPid())},
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
        QList<QPointer<QObject>> result;
        QSet<QObject *> seen;
        for (const auto &object : registry.objects()) if (object && !seen.contains(object.data())) { seen.insert(object.data()); result.append(object); }
        for (const auto &object : nativeObjects) if (object && !seen.contains(object.data())) { seen.insert(object.data()); result.append(object); }
        return result; // native operations may destroy objects in this snapshot
    }

    QJsonObject preferences(const QJsonObject &args) const {
        const QString scope = args.value("scope").toString("application");
        const QString operation = args.value("operation").toString("state");
        if (scope != "application") return {{"error", "scope must be application; use gp_presentation for document settings"}};
        if (!guitarpro::supportedBuild()) return {{"error", "Preferences are disabled on an unverified host build"}};
        const QString model = args.value("model").toString();
        const QHash<QString, QStringList> models{
            {"general", {"defaultTemplate", "defaultStylesheet", "pageMode", "zoom", "forceStylesheet", "forcePageMode", "forceZoom", "forceNotation", "forcePlayback", "restoreOpenFile", "embedAudioFiles"}},
            {"gui", {"autoOpenFxPopup", "highlightBar", "includeChordsInCopyPaste", "playSoundWhileEditing", "useMediaKeys", "showFretlightButton", "uiLanguage", "cursorStyle", "plusMinusKeyBehavior", "showMSB", "showExamples"}},
            {"score", {"barLengthError", "hoPoError", "outOfRangeError", "tupletError", "unreachableBarError"}},
            {"user_info", {"artist", "lyrics", "music", "copyright", "instructions", "tab"}},
            {"midi", {"midiInput", "selectedMidiOutputs", "midiCaptureSensitivity"}}
        };
        const QHash<QString, QStringList> classes{
            {"general", {"gp::base::GeneralPreferencesModel"}},
            {"gui", {"gp::base::GUIPreferencesModel"}},
            {"score", {"gp::base::ScorePreferencesModel"}},
            {"user_info", {"gp::base::UserInfoPreferencesModel"}},
            {"midi", {"gp::base::MidiPreferencesModel", "gp::base::MidiConfigurationWidgetModel", "gp::base::AudioConfigurationWidgetModel"}}
        };
        if (!models.contains(model)) return {{"error", "model must be general, gui, score, user_info or midi"}};
        const QStringList allowed = models.value(model);
        QPointer<QObject> object;
        for (const auto &candidate : services()) if (candidate && classes.value(model).contains(QString::fromLatin1(candidate->metaObject()->className()))) {
            if (model == "midi" && candidate->metaObject()->indexOfProperty("midiInput") < 0) continue;
            if (object && object != candidate) return {{"error", "Ambiguous native preference model"}};
            object = candidate;
        }
        if (!object) return {{"error", "Native preference model unavailable"}, {"model", model}, {"status", "host_limited"}};
        QJsonObject values, propertyInfo;
        for (const auto &name : allowed) {
            const int index = object->metaObject()->indexOfProperty(name.toLatin1().constData());
            if (index < 0) { propertyInfo[name] = QJsonObject{{"available", false}}; continue; }
            const auto property = object->metaObject()->property(index);
            QJsonObject details{{"available", true}, {"type", property.typeName()}, {"readable", property.isReadable()}, {"writable", property.isWritable()}};
            const auto enumChoices = preferenceEnumChoices(property);
            if (!enumChoices.isEmpty()) details["choices"] = enumChoices;
            if (name == "zoom") { details["minimum"] = 0.25; details["maximum"] = 4; }
            if (name == "defaultTemplate") {
                QJsonArray templates;
                const QDir directory(":/GPBase/MainWindow/Templates");
                for (const auto &file : directory.entryList({"*.gpt"}, QDir::Files, QDir::Name)) templates.append(QFileInfo(file).completeBaseName());
                details["choices"] = templates;
            }
            if (property.isReadable()) values[name] = preferenceJsonValue(property, property.read(object));
            propertyInfo[name] = details;
        }
        const auto state = [&]() { return QJsonObject{{"scope", scope}, {"model", model}, {"native_model", object ? object->metaObject()->className() : ""}, {"values", values}, {"property_info", propertyInfo}, {"undoable", false}}; };
        if (operation == "state") return state();
        if (operation != "set") return {{"error", "operation must be state or set"}};
        const QString name = args.value("property").toString();
        if (!allowed.contains(name)) return {{"error", "property is not in the explicit preference allowlist"}};
        const int index = object->metaObject()->indexOfProperty(name.toLatin1().constData());
        if (index < 0 || !object->metaObject()->property(index).isReadable() || !object->metaObject()->property(index).isWritable()) return {{"error", "Native preference property is unavailable or read-only"}};
        const auto property = object->metaObject()->property(index);
        const auto input = args.value("value");
        if (name == "zoom" && (!input.isDouble() || !std::isfinite(input.toDouble()) || input.toDouble() < 0.25 || input.toDouble() > 4)) return {{"error", "Use a zoom from 0.25 to 4"}};
        const QVariant before = property.read(object);
        if (name == "defaultTemplate" && property.userType() == QMetaType::QString && input != preferenceJsonValue(property, before) && !propertyInfo.value(name).toObject().value("choices").toArray().contains(input)) return {{"error", "Choose a defaultTemplate from property_info or gp_templates"}};
        QVariant value;
        QString error;
        if (!preferenceValue(property, input, &value, &error)) return {{"error", error}};
        if (!samePreferenceValue(property, before, value) && (!property.write(object, value) || !object || !samePreferenceValue(property, property.read(object), value))) {
            const bool restored = object && property.write(object, before) && samePreferenceValue(property, property.read(object), before);
            return {{"error", restored ? "Preference change failed; previous value restored" : "Preference change failed; inspect native preferences"}, {"scope", scope}, {"restored", restored}};
        }
        if (!object) return {{"error", "Native preference model was destroyed; reacquire state"}, {"scope", scope}};
        values[name] = preferenceJsonValue(property, property.read(object));
        return state();
    }

    QJsonObject audioStream(const QJsonObject &args) {
        const QString operation = args.value("operation").toString("state");
        QString document;
        if (operation == "start") {
            const auto target = guitarpro::choose(args);
            if (!target.score || !target.view) return {{"status", "error"}, {"error", "Choose a document with a verified native score"}};
            document = target.id();
        }
        gpmcp_audio_bridge_info providerInfo{};
        providerInfo.struct_size = sizeof(providerInfo);
        const uint32_t providerStatus = audioBridgeInfo(&providerInfo);
        const QString providerState = providerStatus == GPMCP_AUDIO_OK ? QStringLiteral("ready") :
            providerStatus == GPMCP_AUDIO_NOT_READY ? QStringLiteral("not_ready") : QStringLiteral("host_limited");
        const QJsonObject provider{{"abi_version", int(providerInfo.abi_version)}, {"status", providerState},
            {"generation", qint64(providerInfo.generation)}, {"host_build_sha256", QString::fromLatin1(providerInfo.host_build_sha256)}};
        return audioStreams.handle(args, document, guitarpro::currentAudioGeneration(), provider);
    }

    QJsonObject midiImport(const QJsonObject &args) {
        if (args.value("request") != opening.value("request") || !openingPoll.isActive() || !loadModal ||
            loadModal != QApplication::activeModalWidget() || QByteArray(loadModal->metaObject()->className()) != "gp::gui::MidiImportDialog")
            return {{"error", "The request has no active MIDI import dialog"}};
        QObject *settings = nullptr;
        for (const auto &candidate : services()) if (candidate && QByteArray(candidate->metaObject()->className()) == "gp::base::MidiImportSettingsModel") {
            if (settings) return {{"error", "Ambiguous native MIDI options"}};
            settings = candidate;
        }
        if (!settings) return {{"error", "Native MIDI options unavailable"}};
        const QStringList fields{"dot", "is2ChannelsPerTrack", "live", "multivoice", "quantization", "staccato", "triplet"};
        const QString operation = args.value("operation").toString("state");
        if (operation == "set") {
            const QString name = args.value("property").toString();
            const auto value = args.value("value");
            if (!fields.contains(name) || (name == "quantization" ? (!value.isDouble() || value.toDouble() != value.toInt() || value.toInt() < 2 || value.toInt() > 8) : !value.isBool()))
                return {{"error", "Choose a MIDI boolean option or quantization 2..8 (whole..64th)"}};
            if (!settings->setProperty(name.toLatin1().constData(), value.toVariant())) return {{"error", "Native MIDI option could not be set"}};
        } else if (operation == "accept") {
            const QPointer<QDialog> dialog = loadModal;
            QTimer::singleShot(0, this, [this, dialog]() {
                if (dialog && dialog == loadModal && dialog == QApplication::activeModalWidget()) {
                    if (auto button = dialog->findChild<QAbstractButton *>("newScoreButton")) button->click();
                    dialog->accept();
                }
            });
        } else if (operation != "state") return {{"error", "operation must be state, set or accept; use gp_cancel to cancel"}};
        QJsonObject values;
        for (const auto &name : fields) values[name] = QJsonValue::fromVariant(settings->property(name.toLatin1().constData()));
        return {{"scope", "import"}, {"request", opening.value("request")}, {"values", values}, {"status", operation == "accept" ? "scheduled" : "observed"}};
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
        if (QWidget *modal = QApplication::activeModalWidget()) {
            auto target = qobject_cast<QWidget *>(object.data());
            if (!target || (target != modal && !modal->isAncestorOf(target)))
                return {{"error", "A modal dialog blocks actions outside that dialog"}, {"dialog", modalState()}};
        }
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
        if (sessionFile.isEmpty()) sessionFile = QDir(gpmcp::dataDirectory()).filePath("native-session.json");
        if (!QDir().mkpath(QFileInfo(sessionFile).absolutePath())) {
            gpmcp::diagnostic("configuration_error", "Cannot create the MCP session directory"); return;
        }
        const QJsonObject str{{"type", "string"}}, integer{{"type", "integer"}}, boolean{{"type", "boolean"}}, anyObject{{"type", "object"}};
        const QJsonObject indices{{"type", "array"}, {"items", integer}, {"minItems", 1}, {"uniqueItems", true}};
        QJsonArray tools;
        auto add = [&](const QString &name, const QString &description, QJsonObject properties, QJsonArray required = {}) {
            if (name == "gp_apply_spec" && qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) {
                properties["debug_fault"] = QJsonObject{{"type", "string"}, {"enum", QJsonArray{"before_commit", "after_commit"}}};
                properties["debug_delay_ms"] = QJsonObject{{"type", "integer"}, {"minimum", 0}, {"maximum", 2000}};
            }
            tools.append(QJsonObject{{"name", name}, {"description", description},
                {"inputSchema", QJsonObject{{"type", "object"}, {"properties", properties}, {"required", required}, {"additionalProperties", false}}}});
        };
        if (qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) add("gp_debug_objects", "开发用：从已知 Qt 对象读取关联的 C++ RTTI，定位原生模型。", {});
        if (qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) add("gp_audio_probe", "开发验收：原生渲染最多 30 秒测试曲谱，返回 PCM 帧数、能量和哈希。", {{"document", str}});
        add("gp_audio_abi", "读取当前文档的 RSE EffectsChain 到不透明 track_id/chain_id 映射；可在开发模式用 buffer_probe 验证可写 AMAudio IAudioBuffer 和 EffectsChain::processDSP。", {{"document", str}, {"operation", str}, {"track", integer}, {"sound", integer}, {"track_id", str}, {"chain_id", str}, {"frames", integer}});
        add("gp_audio_device", "原生全局音频设备：state/set。property/value 必须来自返回的 choices；修改前停止播放，不加入曲谱撤销栈。", {{"operation", str}, {"property", str}, {"value", QJsonObject{{"anyOf", QJsonArray{str, integer, anyObject}}}}});
        add("gp_audio_stream", "P14 实时音频流会话：state/start/stop/snapshot/read/diagnose/recover。使用固定容量、端点无关的流模型；当前宿主没有核验 realtime tap 时明确返回 host_limited，不伪造 PCM 或设备输出。", {{"operation", str}, {"document", str}, {"stream_id", str}, {"layers", QJsonObject{{"type", "array"}, {"items", str}}}, {"max_frames", integer}, {"max_bytes", integer}});
        add("gp_p9_status", "读取 P9 编辑面板能力矩阵。每项明确返回已实现、已验证、实验性、未实现或宿主受限；只读，不改变曲谱。", {});
        add("gp_preferences", "读取或设置明确允许的全局原生偏好。scope 为 application，model 为 general/gui/score/user_info/midi。返回实际值、类型和宿主 choices；设置失败会恢复旧值。文档设置使用 gp_presentation。", {{"scope", str}, {"model", str}, {"operation", str}, {"property", str}, {"value", QJsonObject{{"anyOf", QJsonArray{boolean, str, QJsonObject{{"type", "number"}}, QJsonObject{{"type", "array"}}}}}}});
        add("gp_presentation", "读取或设置文档页面、页面元数据、缩放、编辑显示和谱表可见性。页面尺寸/边距使用毫米；一次只设置页面、page_metadata、视图或谱表一组。page_metadata 异步写入 title/author/composer/copyright，以及 even_header/odd_header、first_footer/even_footer/odd_footer、first_page_number/even_page_number/odd_page_number（对象含 text、visibility=0 可见/1 隐藏/2 折叠）。使用 gp_operation 查询终态，整组一次撤销。", {{"document", str}, {"operation", str}, {"width", QJsonObject{{"type", "number"}}}, {"height", QJsonObject{{"type", "number"}}}, {"left", QJsonObject{{"type", "number"}}}, {"top", QJsonObject{{"type", "number"}}}, {"right", QJsonObject{{"type", "number"}}}, {"bottom", QJsonObject{{"type", "number"}}}, {"orientation", str}, {"page_metadata", anyObject}, {"zoom", QJsonObject{{"type", "number"}}}, {"design_mode", boolean}, {"multivoice_edition", boolean}, {"track", integer}, {"standard_notation", boolean}, {"tablature", boolean}});
        if (qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) add("gp_debug_resources", "开发用：只读枚举宿主嵌入的 Qt 资源路径。", {{"query", str}});
        add("gp_templates", "枚举宿主内置曲谱模板，供 gp_new 使用。", {});
        add("gp_edit_connection", "原生编辑连奏和延音线，支持撤销。kind 为 legato/tie，enabled 必填；scope 为 cursor（默认）或 selection。cursor 的 legato 连接下一拍，tie 连接前一拍；tie 可用 string 或 note_index 指定单音，省略时整拍处理，可能改写音高/升降号或补入音符。selection 支持跨声部/音轨，沿用 128 小节、20000 拍上限。返回 observed_beats 和 changed_selected_beats，后者不含选区外的相邻端点；status=executed 不保证每个音符都可连接。重复命令可能增加原生撤销记录。", {{"document", str}, {"kind", str}, {"enabled", boolean}, {"scope", str}, {"string", integer}, {"note_index", integer}}, {"kind", "enabled"});
        add("gp_new", "使用宿主内置模板异步新建曲谱；轮询 gp_documents.creation 确认 request 对应的 created 状态。", {{"template", str}}, {"template"});
        add("gp_create_from_spec", "异步使用宿主模板创建曲谱，先在原生副本构建并核对规格，再创建文档、一次提交。用 gp_operation 查询 created/error 终态。", {{"template", str}, {"spec", guitarpro::semanticSpecSchema()}}, {"template", "spec"});
        add("gp_apply_spec", "在当前实时文档中批量应用元数据、音轨名称、谱表、小节、节拍、音符、和弦、歌词和拍号。replace 重建音轨和音符；append/insert 增加全局小节且拒绝更改现有音轨属性。未提供的元数据/主小节属性沿用原模型，音轨配置沿用所选模板或原音轨。异步返回 request，用 gp_operation 查询 applied/unchanged/error；一次原生撤销。", {{"document", str}, {"spec", guitarpro::semanticSpecSchema()}, {"mode", str}, {"bar", integer}}, {"spec"});
        add("gp_insert_tab", "将单弦 riff（0-2-2，r 为休止，| 分小节）写入指定音轨/谱表/声部。默认八分音符。append/insert 新增全局小节，replace 仅替换指定声部的已有小节。异步返回 request，用 gp_operation 查询终态；一次原生撤销。", {{"document", str}, {"text", str}, {"mode", str}, {"bar", integer}, {"track", integer}, {"staff", integer}, {"voice", integer}, {"string", integer}, {"denominator", integer}}, {"text"});
        add("gp_export_json", "返回 guitarpromcp.p8 v1 的 spec：音轨/谱表/小节/声部按数组从零定位；含音符、技法、连音、和弦、歌词、反复、段落、速度。上限为 32 轨、256 小节、总计 20000 拍。", {{"document", str}});
        add("gp_import_json", "导入 gp_export_json.spec 对象或其 JSON 字符串。replace 替换曲谱内容，append/insert 要求音轨和谱表与目标一致。先在原生副本构建，再一次提交。异步返回 request，用 gp_operation 查询终态。", {{"document", str}, {"spec", QJsonObject{{"anyOf", QJsonArray{guitarpro::semanticSpecSchema(), str}}}}, {"mode", str}, {"bar", integer}}, {"spec"});
        add("gp_export_tab", "导出 ASCII 六线谱；每拍一列，时值另列，各声部分开，高音弦在上。返回原生节拍和不可表示项；ASCII 不可逆。", {{"document", str}, {"track", integer}, {"staff", integer}, {"bar", integer}, {"count", integer}, {"voice", integer}});
        add("gp_structure", "读取统一歌曲结构摘要：主小节、拍号、调号、反复、跳转、段落、音轨和速度。", {{"document", str}});
        add("gp_read_chords", "按实际拍关联解引用宿主和弦集合，读取名称、根音、低音、类型、音程、转位和和弦图；types 返回原生类型选项。", {{"document", str}, {"track", integer}, {"staff", integer}, {"bar", integer}, {"count", integer}, {"voice", integer}});
        add("gp_edit_chord", "在指定拍设置/移除和弦语义对象。chord 含 root、可选 bass/name/type/degrees/diagram；diagram 含 first_fret、frets、barres、fingers。弦从低音弦零起算；frets 为绝对品位，指法/横按 fret 为图内相对品位。barres 的 finger 默认 1（食指），以原生重复指法位置持久化；实际音符独立。异步返回 request，用 gp_operation 查询终态。", {{"document", str}, {"track", integer}, {"staff", integer}, {"bar", integer}, {"voice", integer}, {"beat", integer}, {"operation", str}, {"chord", anyObject}}, {"track", "staff", "bar", "voice", "beat"});
        add("gp_read_lyrics", "读取实时拍歌词行和文本片段，并返回音轨/谱表/小节/声部/拍关联。", {{"document", str}, {"track", integer}, {"staff", integer}, {"bar", integer}, {"count", integer}, {"voice", integer}});
        add("gp_edit_lyrics", "在指定实时拍的 0..4 行写入一个歌词文本片段，空字符串清除；空格和连字符原样保留。异步返回 request，gp_operation 查询终态；一次原生撤销。", {{"document", str}, {"track", integer}, {"staff", integer}, {"bar", integer}, {"voice", integer}, {"beat", integer}, {"line", integer}, {"text", str}}, {"track", "staff", "bar", "voice", "beat", "line", "text"});
        add("gp_read_sections", "读取原生段落起点，end_bar 为下一段落前一小节或曲谱末尾。", {{"document", str}});
        add("gp_edit_section", "在指定主小节设置或清除段落名称和文本。异步返回 request，gp_operation 查询终态；段落结束由下一个起点决定。", {{"document", str}, {"operation", str}, {"bar", integer}, {"name", str}, {"text", str}}, {"bar"});
        add("gp_read_bars", "按小节读取实时音符、音高、品位、弦、时值和休止；每次最多 16 小节。include_dynamic/include_clef/include_stem=true 时额外返回节拍力度、小节谱号或符干方向，默认输出结构不变。", {{"document", str}, {"track", integer}, {"staff", integer}, {"bar", integer}, {"count", integer}, {"include_dynamic", boolean}, {"include_clef", boolean}, {"include_stem", boolean}});
        add("gp_set_fret", "通过原生命令修改当前光标节拍中一个已有音符的品位；弦索引从 0 开始。", {{"document", str}, {"string", integer}, {"fret", integer}}, {"string", "fret"});
        add("gp_edit_note", "在当前节拍或占位拍上原生增删音符。operation 为 set/remove；弦乐用 string 和 fret，键盘及打击乐用 midi 0..127，不混用两类定位。set 对已有 MIDI 音符不重复添加；打击乐 MIDI 必须属于当前乐器。", {{"document", str}, {"operation", str}, {"string", integer}, {"fret", integer}, {"midi", integer}}, {"operation"});
        add("gp_edit_note_effect", "原生修改当前拍音符技法，用 string 或 note_index 定位，支持撤销。palm_mute/let_ring/left_hand_tapping/right_hand_tapping/dead/hopo/staccato/staccatissimo/accent/heavy_accent/tenuto 使用布尔值；vibrato、anti_accent、left_fingering/right_fingering、ornament 使用原生名称。trill: {enabled:true,midi:0..127}（十六分音符）或 {enabled:false}；slide: {kind,enabled} 或 {kind:None}；harmonic: {type,fret} 或 {type:None}；bend: {enabled,origin_value,middle_value,destination_value,origin_offset,middle_offset1,middle_offset2,destination_offset}，音高值为 0..12 半音，位置 0..1，清除只传 {enabled:false}。", {{"document", str}, {"string", integer}, {"note_index", integer}, {"property", str}, {"value", QJsonObject{{"anyOf", QJsonArray{boolean, str, QJsonObject{{"type", "object"}}}}}}}, {"property", "value"});
        add("gp_edit_beat_effect", "修改光标单拍技法，支持原生撤销。grace、pick_stroke、fade、hairpin、golpe、ottavia、rasgueado、bar_vibrato、bass_attack、arpeggio、brush 使用原生名称，错误值返回 choices；通常 None 清除，hairpin 用 NoHairpin。琶音和扫弦采用宿主默认时序。whammy 与音符 bend 的七点格式相同，音高范围 -12..12 半音。dead_slap 用布尔值；tremolo 用 8/16/32/64 分音符，0 清除。装饰音转换会改变时值，死拍会清空音符，撤销可恢复。", {{"document", str}, {"property", str}, {"value", QJsonObject{{"anyOf", QJsonArray{boolean, str, integer, QJsonObject{{"type", "object"}}}}}}}, {"property", "value"});
        add("gp_transpose", "按半音移动光标单拍或选区音符的实际音高，支持撤销。semitones 为 -24..24，scope 为 cursor（默认）或 selection；打击乐和超出 MIDI 音域的请求会拒绝。记谱用移调乐器偏移通过 gp_edit_track 的 transposition 设置。", {{"document", str}, {"semitones", integer}, {"scope", str}}, {"semitones"});
        add("gp_edit_beat", "原生编辑节拍：insert 新增休止节拍，rhythm 设置基础时值并保留附点/连音，dots 设置附点，tuplet 设置连音，text 设置或清除节拍文本，dynamic 设置力度标记，stem 设置符干方向，clear 清空音符，remove 删除节拍。text 使用 text 字段并保留 Unicode/空白；dynamic 使用 dynamic 字段，值为 PPP、PP、P、MP、MF、F、FF 或 FFF（大小写不敏感）；stem 使用 orientation=auto、Upward 或 Downward，并按当前谱表显示模式清除或设置用户符干方向；清除力度标记没有核验的原生路径；tuplet 的 level 为 primary（默认）或 secondary；actual/normal 均为 1..255；enabled=false 清除指定层且不接受比例参数。scope 默认 cursor；selection 批量修改 rhythm/dots/tuplet/text/dynamic/stem/clear/remove，可用 tracks/staves/voices 非空索引数组筛选当前选区，本次调用生效，先用 gp_selection beats 核对相同筛选。最多 128 小节、20000 拍，跳过空占位拍，可一次撤销。", {{"document", str}, {"operation", str}, {"denominator", integer}, {"dots", integer}, {"text", str}, {"dynamic", str}, {"orientation", str}, {"scope", str}, {"level", str}, {"actual", integer}, {"normal", integer}, {"enabled", boolean}, {"tracks", indices}, {"staves", indices}, {"voices", indices}}, {"operation"});
        add("gp_edit_bars", "原生插入或删除小节，作用于整份曲谱的所有音轨。operation 为 insert/remove，index 从 0 开始，count 默认 1。", {{"document", str}, {"operation", str}, {"index", integer}, {"count", integer}}, {"operation", "index"});
        add("gp_score", "读取实时曲谱元数据、音轨小节数量、光标及撤销状态；直接调用 GPCore。", {{"document", str}});
        add("gp_read_master_bars", "读取全曲共享的小节拍号、实音调号、反复记号和小节线；分页最多 128 小节。", {{"document", str}, {"bar", integer}, {"count", integer}});
        add("gp_edit_measure", "原生修改光标小节，支持撤销。clef 使用 clef 字段并支持 G2、F4、C3；time_signature(numerator,denominator)、key_signature(accidentals,major)、repeat_start/repeat_end/double_bar/free_time(enabled)，反复次数 repeat_count 2..100。alternate_endings 使用 endings（1..8 的不重复数组，空数组清除）；direction 使用 gp_read_master_bars.direction_marks 中的 ID 和 enabled。", {{"document", str}, {"operation", str}, {"clef", str}, {"numerator", integer}, {"denominator", integer}, {"accidentals", integer}, {"major", boolean}, {"enabled", boolean}, {"repeat_count", integer}, {"endings", QJsonObject{{"type", "array"}, {"items", integer}}}, {"direction", integer}}, {"operation"});
        add("gp_edit_tempo", "原生修改曲谱初始速度，支持撤销。value 为 1..400 的整数，unit 使用 gp_score.tempo.units 中的值，默认保留当前单位和 label；不编辑后续变速点。", {{"document", str}, {"value", QJsonObject{{"type", "number"}, {"minimum", 1}, {"maximum", 400}, {"multipleOf", 1}}}, {"unit", str}, {"label", str}}, {"value"});
        add("gp_tempo", "原生速度自动化：state/set/remove。bar 为原谱小节，position 为小节内 0..1（不含 1）的比例；value 为 1..400 整数，linear 使用宿主渐变语义。初始点不可删除。支持撤销。", {{"document", str}, {"operation", str}, {"bar", integer}, {"position", QJsonObject{{"type", "number"}}}, {"value", integer}, {"unit", str}, {"linear", boolean}, {"label", str}});
        add("gp_automation", "读取宿主原生音轨自动化；operation=types/state 只读，set/remove 为实验性 DSPParam_00..DSPParam_31 曲线写入，提交前保留同轨道其他自动化和旁路状态，语义与播放影响需宿主专项验证。", {{"document", str}, {"operation", str}, {"track", integer}, {"parameter", integer}, {"bar", integer}, {"position", QJsonObject{{"type", "number"}}}, {"value", QJsonObject{{"type", "number"}}}, {"linear", boolean}, {"text", str}});
        add("gp_audio_track", "原生音色和已有效果链：state/select/copy/midi_program/effect_bypass/effect_parameter/effect_swap/effect_remove。select 的 sound=-1 恢复自动音色；copy 复用 source_document/source_track/source_sound。效果参数为 0..1；MIDI program 为 0..127，仅影响 MIDI 音源。音轨混音使用 gp_edit_track。", {{"document", str}, {"operation", str}, {"track", integer}, {"sound", integer}, {"source_document", str}, {"source_track", integer}, {"source_sound", integer}, {"effect", integer}, {"parameter", integer}, {"other", integer}, {"value", QJsonObject{{"type", "number"}}}, {"enabled", boolean}}, {"track"});
        add("gp_edit_track", "原生设置音轨 name/short_name、color (#RRGGBB)、volume/pan (0..1)、transposition（记谱移调偏移 -24..24 半音，保留发声音高）或 playback_state (Default/Solo/Mute)。播放状态不加入撤销栈，其余属性支持撤销。", {{"document", str}, {"track", integer}, {"property", str}, {"value", QJsonObject{{"anyOf", QJsonArray{str, QJsonObject{{"type", "number"}}}}}}}, {"track", "property", "value"});
        add("gp_edit_tracks", "原生复制、删除或交换音轨，支持撤销；operation 为 duplicate/remove/swap，复制到原轨之后，swap 需要 other 索引。", {{"document", str}, {"operation", str}, {"track", integer}, {"other", integer}}, {"operation", "track"});
        add("gp_edit_tuning", "原生修改弦乐音轨谱表调弦及变调夹，支持撤销。tuning 为按宿主弦顺序的 1..12 个 MIDI 音高；capo/partial_capo 为 0..24，partial_capo_strings 为逐弦布尔数组。preserve_pitch 默认 true。省略字段保留原值，staff 默认 0。", {{"document", str}, {"track", integer}, {"staff", integer}, {"tuning", QJsonObject{{"type", "array"}, {"items", integer}}}, {"capo", integer}, {"partial_capo", integer}, {"partial_capo_strings", QJsonObject{{"type", "array"}, {"items", boolean}}}, {"preserve_pitch", boolean}}, {"track"});
        add("gp_insert_track", "以已有音轨配置原生新增音轨，支持撤销。默认清空内容并匹配目标小节数；copy_content=true 复制音符，要求两者小节数相同。源文档默认目标文档，index 默认末尾。", {{"document", str}, {"source_document", str}, {"source_track", integer}, {"index", integer}, {"copy_content", boolean}}, {"source_track"});
        add("gp_edit_metadata", "通过原生命令修改一项曲谱元数据，支持宿主撤销。property 使用 gp_score 返回的键。", {{"document", str}, {"property", str}, {"value", str}}, {"property", "value"});
        add("gp_undo_redo", "调用原生曲谱撤销或重做；不依赖窗口焦点或 QAction 状态。", {{"document", str}, {"operation", str}}, {"operation"});
        add("gp_cursor", "移动实时曲谱光标的 track/staff/bar/voice/beat 索引；索引从 0 开始，声部为 0..3。", {{"document", str}, {"axis", str}, {"index", integer}}, {"axis", "index"});
        const QJsonObject endpoint{{"type", "object"}, {"properties", QJsonObject{{"track", integer}, {"staff", integer}, {"bar", integer}, {"voice", integer}, {"beat", integer}}},
            {"required", QJsonArray{"track", "staff", "bar", "voice", "beat"}}, {"additionalProperties", false}};
        add("gp_selection", "原生选区：state 读取状态；beats 列出明确选区的实际节拍位置和总数，可用 tracks/staves/voices 非空索引数组筛选本次结果，筛选不改变原生选区；跳过空占位拍，最多 128 小节、20000 拍。range 用 base/extent 指定同轨同谱表同声部的范围（含端点）；note 用 base 和 note_index 选择单音；all 选择当前谱表；clear 取消选区。range/all 可用 all_voices 扩展声部，all_tracks 扩展为所选整小节的全部音轨、谱表和声部。索引从 0 开始。", {{"document", str}, {"operation", str}, {"base", endpoint}, {"extent", endpoint}, {"note_index", integer}, {"all_voices", boolean}, {"all_tracks", boolean}, {"tracks", indices}, {"staves", indices}, {"voices", indices}});
        add("gp_activate", "通过原生文档导航方法切换指定文档并读回活动文档；无需前台窗口。", {{"document", str}}, {"document"});
        add("gp_move_document", "将指定文档标签移动到从 0 开始的 index，保留活动文档、曲谱内容和撤销历史；同步返回结果及 request，可用 gp_operation 查阅。失败时尝试恢复完整原顺序；rolled_back=false 且 outcome_unknown=true 时阻止后续修改。位置从 gp_documents.tab_index 读取；仅改变会话标签顺序，不加入曲谱撤销栈。", {{"document", str}, {"index", integer}}, {"document", "index"});
        add("gp_playback", "原生播放：state/play/stop/seek/seek_tick/set_loop/set_metronome/set_countdown。seek 使用原谱 bar 和小节内 tick；seek_tick 使用展开绝对 tick。timeline 分页读取实际反复/跳转序列。set_loop_range 用 base/extent（含端点）设置原生选区并启用循环；clear_loop_range 清选区并关闭循环。状态包含实际循环边界和帧数。", {{"document", str}, {"operation", str}, {"bar", integer}, {"tick", integer}, {"enabled", boolean}, {"base", endpoint}, {"extent", endpoint}, {"offset", integer}, {"limit", integer}, {"value", QJsonObject{{"type", "number"}}}});
        add("gp_formats", "读取宿主注册的曲谱导入导出格式。", {});
        add("gp_midi_import", "按 gp_open 的 request 读取或设置当前 MIDI 导入选项：state/set/accept；set 用 property/value，quantization 为 2..8（全音符至64分），其他选项布尔。accept 导入新文档，轮询 gp_operation；取消使用 gp_cancel。", {{"request", str}, {"operation", str}, {"property", str}, {"value", QJsonObject{{"anyOf", QJsonArray{boolean, integer}}}}}, {"request"});
        add("gp_export", "异步原生导出 GP5、GPX、MusicXML、MIDI、WAV、PDF 或 PNG；已有目标须 overwrite=true。PNG page 从 1 开始，默认第一页，144 DPI。轮询 gp_operation 的 exported/result，gp_cancel 在提交目标前取消。WAV 为 44.1 kHz 双声道 16 位，最多 30 分钟。", {{"document", str}, {"path", str}, {"overwrite", boolean}, {"page", integer}}, {"document", "path"});
        add("gp_open", "通过宿主原生文件打开事件异步打开 GP、GP3/4/5、GPX、MIDI、MusicXML；用 gp_operation 和 gp_documents 确认结果。", {{"path", str}}, {"path"});
        add("gp_close", "异步关闭文档；unsaved: reject（默认）、save、discard、cancel、prompt。save 可指定 path 和 overwrite；轮询 gp_documents.closing 确认结果。", {{"document", str}, {"unsaved", str}, {"path", str}, {"overwrite", boolean}}, {"document"});
        add("gp_documents", "按标签顺序读取实时文档 ID、tab_index、原生打开路径、保存路径和未保存状态；另存成功后两种路径都更新。映射不可用时 tab_order_available=false，不推断顺序。", {});
        add("gp_operation", "Read a new/open/save/close/tab-move operation by request ID, including the last 64 replaced records.", {{"request", str}}, {"request"});
        add("gp_cancel", "Cancel a queued document operation or its observed native dialog; poll gp_operation for the outcome.", {{"request", str}}, {"request"});
        add("gp_recover", "按 request 重试 recovery_available=true 的失败恢复：标签回滚和文档集变化核验、保存失败后的路径和未保存状态恢复、新建模板路径复原。只执行保留步骤，不重放保存、覆盖文件或重新打开文档；核验成功后解除写入阻塞，原失败和 recovery 结果由 gp_operation 保留。未知新建/打开结果继续自动观察，未确认前不能强制解除阻塞。", {{"request", str}}, {"request"});
        add("gp_save_as", "异步原生另存为 .gp；已有目标须 overwrite=true。轮询 gp_operation，saved 后读取 result。", {{"document", str}, {"path", str}, {"overwrite", boolean}}, {"path"});
        add("gp_save", "异步保存 .gp 副本并保留文档状态；已有目标须 overwrite=true。轮询 gp_operation 的 saved/result。", {{"document", str}, {"path", str}, {"overwrite", boolean}}, {"path"});
        add("gp_save_current", "异步保存当前 .gp 路径；轮询 gp_operation 的 saved/result。未命名文档须先 gp_save_as。", {{"document", str}});
        add("gp_window", "通过 Qt 原生窗口方法隐藏、最小化或恢复主窗口；restore 会显示并请求激活窗口，hide 重新进入不抢焦点的后台模式。", {{"state", str}}, {"state"});
        add("gp_windows", "只读枚举当前实例的 Qt 窗口、稳定 ID、父窗口关系及实际状态。include_hidden 默认 true；过滤不改变总数。不包含桌面和其他进程。", {{"include_hidden", boolean}});
        add("gp_screenshot", "读取指定 window_id 的 PNG；省略时优先活动模态，否则主窗口。使用 Qt 离屏渲染，不激活窗口、不抢焦点、不发送输入；include_frame=true 时在 Windows 上补入同一窗口的系统标题栏和边框。无效 ID 明确拒绝，无法可靠渲染返回 host_limited。", {{"window_id", str}, {"include_frame", boolean}});
        add("gp_capabilities", "原生 C++ 插件身份、后台控制能力及尚未覆盖的范围。", {});
        add("gp_dialogs", "Read the active modal dialog, its message labels and available buttons. Native score mutations are blocked until it is resolved.", {});
        add("gp_objects", "读取宿主 Qt 对象、属性和可调用方法；无需窗口可见或前台。", {{"query", str}, {"offset", integer}, {"limit", integer}, {"include_hidden", boolean}});
        add("gp_actions", "枚举原生 QAction；禁用状态可能受宿主内部上下文影响。", {{"query", str}, {"offset", integer}, {"limit", integer}, {"include_hidden", boolean}});
        QString clipboardDescription = "原生曲谱片段：state 查看插件缓冲区，copy/cut 复制或剪切明确选区，read 读取副本，paste 粘贴，clear 清空插件缓冲区。read/paste 需当前 id。scope 默认 cursor 插入，可用 selection 替换选区。跨小节或多轨粘贴会顺移全曲小节；多声部片段要求目标处于全部声部模式。read 的谱表索引见 tracks 与 source_selection。默认操作不访问系统剪贴板。";
        if (qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) clipboardDescription += " 实验性宿主互通，尚未完成隔离验证：native_state 查看宿主剪贴板；native_copy 将明确选区复制到宿主，会覆盖系统剪贴板但保留插件缓冲区；native_import 从同一 Guitar Pro 实例的剪贴板导入插件缓冲区。后两项需 native_state 的当前 sequence；跨进程剪贴板不支持。";
        clipboardDescription += " paste 可用 repeat=1..100 重复、include_text=true 包含节拍文本；重复结果最多 128 小节、20000 拍。有音高与无固定音高打击乐之间拒绝粘贴；弦乐要求原弦品位仍在 0..36，不搜索指法。";
        add("gp_clipboard", clipboardDescription, {{"operation", str}, {"document", str}, {"id", str}, {"scope", str}, {"repeat", integer}, {"include_text", boolean}, {"sequence", integer}, {"track", integer}, {"staff", integer}, {"bar", integer}, {"count", integer}});
        add("gp_trigger", "调用刚观察到的原生 QAction 或按钮方法；不发送输入事件。返回 scheduled 后需读回。", {{"snapshot", str}, {"id", integer}}, {"snapshot", "id"});
        add("gp_set_property", "原生 Qt 属性设置；需使用观察结果中允许写入的属性。", {{"snapshot", str}, {"id", integer}, {"property", str}, {"value", QJsonObject{}}}, {"snapshot", "id", "property", "value"});
        add("gp_close_window", "调用原生窗口关闭方法，保留未保存文档确认。", {{"snapshot", str}, {"id", integer}}, {"snapshot", "id"});
        if (!server.start(sessionFile, info(), tools, [this](const QString &tool, const QJsonObject &args) {
            refreshOperations();
            if (tool == "gp_dialogs") return modalState();
            if (tool == "gp_windows") return windows.enumerate(args.value("include_hidden").toBool(true));
            if (tool == "gp_screenshot") return windows.screenshot(args);
            if (tool == "gp_formats") return guitarpro::fileFormats();
            if (tool == "gp_midi_import") return midiImport(args);
            if (tool == "gp_operation") {
                const QString request = args.value("request").toString();
                for (const auto &operation : {creation, opening, closing, saving, moving, exporting, editing}) if (operation.value("request") == request) return QJsonObject{{"operation", operation}};
                if (operationHistory.contains(request)) return QJsonObject{{"operation", operationHistory.value(request)}};
                return QJsonObject{{"error", "Unknown or expired operation request"}};
            }
            if (tool == "gp_cancel") return cancelOperation(args.value("request").toString());
            if (tool == "gp_recover") return recoverOperation(args.value("request").toString());
            if (pending(exporting) && (tool == "gp_close_window" || tool == "gp_window" || tool == "gp_trigger" || tool == "gp_set_property"))
                return QJsonObject{{"error", "Export is active; cancel its request and observe completion first"}};
            const bool automationRead = tool == "gp_automation" && (args.value("operation").toString("types") == "types" || args.value("operation").toString("state") == "state");
            static const QSet<QString> modalReads{"gp_capabilities", "gp_p9_status", "gp_audio_abi", "gp_audio_stream", "gp_screenshot", "gp_documents", "gp_score", "gp_read_bars", "gp_read_master_bars", "gp_templates", "gp_objects", "gp_actions", "gp_debug_objects", "gp_debug_resources", "gp_formats", "gp_export_json", "gp_export_tab", "gp_structure", "gp_read_chords", "gp_read_lyrics", "gp_read_sections"};
            static const QSet<QString> dialogActions{"gp_trigger", "gp_set_property", "gp_close_window", "gp_window"};
            if (QApplication::activeModalWidget() && !modalReads.contains(tool) && !automationRead && !dialogActions.contains(tool))
                return QJsonObject{{"error", "A modal dialog blocks native operations; inspect gp_dialogs"}, {"dialog", modalState()}};
            const bool operationPending = recoveryActive || editingNativeActive || loadNativeActive || closingNativeActive || savingOperation ||
                pending(creation) || pending(opening) || pending(closing) || pending(saving) || pending(moving) || pending(exporting) || pending(editing);
            const bool outsideDialogEdit = !QApplication::activeModalWidget() && (tool == "gp_trigger" || tool == "gp_set_property");
            if (operationPending && !modalReads.contains(tool) && !automationRead && (!dialogActions.contains(tool) || outsideDialogEdit))
                return QJsonObject{{"error", "A document operation is pending; inspect gp_documents or cancel its request before another mutation"}};
            // Host command observers update the active document's dirty state.
            // Bind every model mutation to its document before calling native APIs.
            static const QSet<QString> mutations{"gp_edit_note", "gp_edit_note_effect", "gp_edit_beat_effect", "gp_edit_tuning", "gp_transpose", "gp_edit_connection", "gp_edit_beat", "gp_edit_bars", "gp_edit_track", "gp_edit_tracks", "gp_insert_track", "gp_edit_tempo", "gp_edit_measure", "gp_set_fret", "gp_edit_metadata", "gp_cursor", "gp_undo_redo", "gp_apply_spec", "gp_insert_tab", "gp_import_json", "gp_edit_chord", "gp_edit_lyrics", "gp_edit_section"};
            if (mutations.contains(tool) || (tool == "gp_automation" && args.value("operation").toString("types") != "types" && args.value("operation").toString("state") != "state") || ((tool == "gp_tempo" || tool == "gp_audio_track" || tool == "gp_presentation") && args.value("operation").toString("state") != "state") || (tool == "gp_preferences" && args.value("operation").toString("state") != "state" && args.value("scope").toString("application") == "document")) {
                const auto target = guitarpro::choose(args);
                if (!target.view || !target.score) return QJsonObject{{"error", "Choose a document with a verified native score"}};
                const QJsonObject activated = guitarpro::activate(QJsonObject{{"document", target.id()}}, services());
                if (activated.contains("error")) return activated;
            }
            if (tool == "gp_preferences") return preferences(args);
            if (tool == "gp_p9_status") return guitarpro::p9Status();
            if (tool == "gp_audio_abi") return guitarpro::audioAbi(args, services());
            if (tool == "gp_audio_stream") return audioStream(args);
            if (tool == "gp_automation") return guitarpro::automationState(args);
            if (tool == "gp_presentation") return args.contains("page_metadata") && args.value("operation") == "set" ? scheduleSemantic(tool, args) : guitarpro::presentation(args);
            if (tool == "gp_export_json") return guitarpro::exportJson(args);
            if (tool == "gp_import_json") return scheduleSemantic(tool, args);
            if (tool == "gp_export_tab") return guitarpro::exportTab(args);
            if (tool == "gp_structure") return guitarpro::structure(args);
            if (tool == "gp_read_chords") return guitarpro::readChords(args);
            if (tool == "gp_edit_chord") return scheduleSemantic(tool, args);
            if (tool == "gp_read_lyrics") return guitarpro::readLyrics(args);
            if (tool == "gp_edit_lyrics") return scheduleSemantic(tool, args);
            if (tool == "gp_read_sections") return guitarpro::readSections(args);
            if (tool == "gp_edit_section") return scheduleSemantic(tool, args);
            if (tool == "gp_apply_spec") return scheduleSemantic(tool, args);
            if (tool == "gp_insert_tab") return scheduleSemantic(tool, args);
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
                creationDocument.clear();
                creationPrepared.reset();
                for (const auto &document : guitarpro::documents()) creationBefore.append(document.object);
                const QString path = templates.filePath(name + ".gpt");
                archiveOperation(creation);
                creation = {{"request", nonce()}, {"status", "scheduled"}, {"kind", "create"}, {"template", name}, {"template_path", path}};
                creationElapsed.restart(); creationPoll.start(50);
                dispatchLoad("create", path);
                return creation;
            }
            if (tool == "gp_create_from_spec") {
                if (!guitarpro::supportedBuild()) return QJsonObject{{"error", "Template creation requires the verified host build"}};
                QJsonObject spec; QString specError;
                if (!guitarpro::semanticParseSpec(args, &spec, &specError) || !guitarpro::semanticValidateSpec(spec, &specError)) return QJsonObject{{"error", specError}};
                const QDir templates(":/GPBase/MainWindow/Templates");
                const QString name = args.value("template").toString();
                if (!templates.entryList({"*.gpt"}, QDir::Files).contains(name + ".gpt")) return QJsonObject{{"error", "Unknown built-in template name"}};
                if (creationPoll.isActive()) return QJsonObject{{"error", "A template creation is already pending"}, {"creation", creation}};
                const auto seed = std::make_shared<gp::core::Score>(); seed->load(templates.filePath(name + ".gpt"));
                QObject temporary;
                creationPrepared = guitarpro::semanticBuild({nullptr, &temporary, seed.get()}, spec, "replace", 0);
                creationBefore.clear(); creationDocument.clear();
                archiveOperation(creation);
                for (const auto &document : guitarpro::documents()) creationBefore.append(document.object);
                const QString path = templates.filePath(name + ".gpt");
                creation = {{"request", nonce()}, {"status", "scheduled"}, {"kind", "create_from_spec"}, {"template", name}, {"template_path", path}, {"spec_validated", true}};
                creationElapsed.restart(); creationPoll.start(50); dispatchLoad("create", path); return creation;
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
            if (tool == "gp_edit_tuning") return guitarpro::editTuning(args);
            if (tool == "gp_transpose") return guitarpro::transpose(args);
            if (tool == "gp_edit_tracks") return guitarpro::editTracks(args);
            if (tool == "gp_insert_track") return guitarpro::insertTrack(args);
            if (tool == "gp_edit_metadata") return guitarpro::editMetadata(args);
            if (tool == "gp_edit_tempo" || tool == "gp_tempo") {
                const auto result = tool == "gp_edit_tempo" ? guitarpro::editTempo(args) : guitarpro::tempoAutomation(args);
                if (!result.contains("error") && (tool == "gp_edit_tempo" || args.value("operation").toString("state") != "state"))
                    guitarpro::refreshTempo(args, services());
                return result;
            }
            if (tool == "gp_audio_track") return guitarpro::audioTrack(args);
            if (tool == "gp_audio_device") return guitarpro::audioDevice(args, services());
            if (tool == "gp_audio_probe" && qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) return guitarpro::audioProbe(args, services());
            if (tool == "gp_read_master_bars") return guitarpro::readMasterBars(args);
            if (tool == "gp_edit_note_effect") return guitarpro::editNoteEffect(args);
            if (tool == "gp_edit_beat_effect") return guitarpro::editBeatEffect(args);
            if (tool == "gp_edit_connection") return guitarpro::editConnection(args);
            if (tool == "gp_edit_measure") return guitarpro::editMeasure(args);
            if (tool == "gp_undo_redo") {
                const auto result = guitarpro::undoRedo(args);
                if (!result.contains("error")) guitarpro::refreshTempo(args, services());
                return result;
            }
            if (tool == "gp_cursor") return guitarpro::moveCursor(args);
            if (tool == "gp_selection") return guitarpro::selection(args, services());
            if (tool == "gp_clipboard") return guitarpro::clipboard(args, clipboardBuffer, services());
            if (tool == "gp_activate") return guitarpro::activate(args, services());
            if (tool == "gp_move_document") {
                archiveOperation(moving);
                pendingRecovery = {};
                moving = {{"request", nonce()}, {"kind", "move"}, {"document", args.value("document")}, {"status", "requested"}};
                recoveryRequest = moving.value("request").toString();
                QJsonObject result;
                try { result = guitarpro::moveDocument(args, services(), pendingRecovery); }
                catch (const std::exception &exception) { result = {{"error", QString::fromUtf8(exception.what())}, {"outcome_unknown", true}}; }
                catch (...) { result = {{"error", "Unknown native tab operation exception"}, {"outcome_unknown", true}}; }
                result["request"] = moving.value("request");
                result["recovery_available"] = bool(pendingRecovery);
                moving["result"] = result;
                moving["status"] = result.contains("error") ? QJsonValue("error") : result.value("status");
                if (result.contains("error")) moving["error"] = result.value("error");
                if (result.value("outcome_unknown").toBool()) moving["outcome_unknown"] = true;
                moving["recovery_available"] = bool(pendingRecovery);
                return result;
            }
            if (tool == "gp_playback") return guitarpro::playback(args, services());
            if (tool == "gp_open") {
                if (!guitarpro::supportedBuild()) return QJsonObject{{"error", "Document opening requires the verified host build"}};
                const QFileInfo file(args.value("path").toString());
                const QSet<QString> extensions{"gp", "gp3", "gp4", "gp5", "gpx", "mid", "midi", "xml", "musicxml", "mxl"};
                if (!file.isAbsolute() || !file.isFile() || !extensions.contains(file.suffix().toLower())) return QJsonObject{{"error", "Existing absolute GP, GP3/4/5, GPX, MIDI or MusicXML path required"}};
                const QString path = file.canonicalFilePath();
                for (const auto &document : guitarpro::documents()) {
                    for (const char *property : {"openedFilePath", "saveFilePath"})
                        if (QFileInfo(guitarpro::localDocumentPath(document.object->property(property).toString())).canonicalFilePath().compare(path, Qt::CaseInsensitive) == 0)
                            return QJsonObject{{"status", "already_open"}, {"document", document.id()}, {"path", path}};
                }
                archiveOperation(opening);
                opening = {{"request", nonce()}, {"status", "scheduled"}, {"kind", "open"}, {"path", path}};
                openingElapsed.restart(); openingPoll.start(50);
                dispatchLoad("open", path);
                return opening;
            }
            if (tool == "gp_documents") {
                QJsonObject result = guitarpro::list(services());
                if (!creation.isEmpty()) result["creation"] = creation;
                if (!opening.isEmpty()) result["opening"] = opening;
                if (!saving.isEmpty()) result["saving"] = saving;
                if (!exporting.isEmpty()) result["exporting"] = exporting;
                if (!moving.isEmpty()) result["moving"] = moving;
                if (!editing.isEmpty()) result["editing"] = editing;
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
                const QString policy = args.value("unsaved").toString("reject");
                if (!QStringList{"reject", "save", "discard", "cancel", "prompt"}.contains(policy)) return QJsonObject{{"error", "unsaved must be reject, save, discard, cancel or prompt"}};
                if (policy != "save" && (args.contains("path") || args.contains("overwrite"))) return QJsonObject{{"error", "path and overwrite apply only to unsaved=save"}};
                if (policy == "save" && args.contains("overwrite") && !args.contains("path")) return QJsonObject{{"error", "overwrite requires a Save As path"}};
                if (target.object->property("isDirty").toBool() && policy == "reject")
                    return QJsonObject{{"error", "Document has unsaved changes; save it before closing"}};
                archiveOperation(closing);
                closing = {{"request", nonce()}, {"status", policy == "cancel" ? "cancelled" : "scheduled"}, {"kind", "close"}, {"document", target.id()}, {"unsaved", policy}};
                if (policy == "cancel") return closing;
                closingView = target.view;
                closingModal.clear();
                closingElapsed.restart();
                const QString request = closing.value("request").toString();
                QTimer::singleShot(0, this, [this, args, target, policy, request]() {
                    if (closing.value("request") != request || closing.value("status") != "scheduled") return;
                    if (!target.view || !target.object || guitarpro::choose(args).object != target.object) {
                        closing["status"] = "error";
                        closing["error"] = "Document changed before close request";
                        return;
                    }
                    closing["status"] = "requested";
                    if (policy == "save") {
                        QJsonObject saved;
                        try {
                            saved = guitarpro::activate(args, services());
                            if (!saved.contains("error")) saved = performSave(args, true, !args.contains("path"), closing);
                        } catch (const std::exception &exception) { nativeFailure(closing, QString::fromUtf8(exception.what())); saved = {{"error", closing.value("error")}}; }
                        catch (...) { nativeFailure(closing, "Unknown native close/save exception"); saved = {{"error", closing.value("error")}}; }
                        closing["save"] = saved;
                        if (saved.contains("error")) { closing["status"] = cancelledSave(closing, saved) ? "cancelled" : "error"; closing["error"] = saved.value("error"); return; }
                    }
                    closing["status"] = "requested";
                    QJsonObject result;
                    {
                        QScopedValueRollback<bool> active(closingNativeActive, true);
                        try { result = guitarpro::closeDocument(args, services(), policy == "discard" || policy == "prompt"); }
                        catch (const std::exception &exception) { nativeFailure(closing, QString::fromUtf8(exception.what())); result = {{"error", closing.value("error")}}; }
                        catch (...) { nativeFailure(closing, "Unknown native document close exception"); result = {{"error", closing.value("error")}}; }
                    }
                    if (result.contains("error")) closing["status"] = "error";
                    if (result.contains("error")) closing["error"] = result.value("error");
                    if (closingView && closing.value("decision") == "cancel") closing["status"] = "cancelled";
                    checkClosing();
                });
                return closing;
            }
            if (tool == "gp_export") {
                const auto target = guitarpro::choose(args);
                if (!target.object || !target.score) return QJsonObject{{"error", "Existing document required"}};
                archiveOperation(exporting);
                exporting = {{"request", nonce()}, {"status", "scheduled"}, {"kind", "export"}, {"document", target.id()}};
                QJsonObject bound = args; bound["document"] = target.id();
                const QString request = exporting.value("request").toString();
                QTimer::singleShot(0, this, [this, bound, target, request]() {
                    if (exporting.value("request") != request || exporting.value("status") != "scheduled") return;
                    exporting["status"] = "requested";
                    QJsonObject result;
                    try {
                        if (!target.object || guitarpro::choose(bound).object != target.object) result = {{"error", "Document changed before export"}};
                        else {
                            result = guitarpro::activate(bound, services());
                            if (!result.contains("error")) result = guitarpro::exportFile(bound, services(), [this]() { return exporting.value("cancel_requested").toBool(); });
                        }
                    } catch (const std::exception &exception) { result = {{"error", QString::fromUtf8(exception.what())}}; }
                    catch (...) { result = {{"error", "Native export exception"}}; }
                    exporting["result"] = result;
                    exporting["status"] = result.value("cancelled").toBool() ? "cancelled" : result.contains("error") ? "error" : "exported";
                    if (result.contains("error")) exporting["error"] = result.value("error");
                });
                return exporting;
            }
            if (tool == "gp_save_as" || tool == "gp_save_current" || tool == "gp_save") {
                const auto target = guitarpro::choose(args);
                if (!target.object || !target.view) return QJsonObject{{"error", "Choose an existing document id from gp_documents"}};
                QJsonObject bound = args; bound["document"] = target.id();
                archiveOperation(saving);
                saving = {{"request", nonce()}, {"status", "scheduled"}, {"kind", "save"}, {"document", target.id()}, {"tool", tool}};
                const QString request = saving.value("request").toString();
                QTimer::singleShot(0, this, [this, bound, target, tool, request]() {
                    if (saving.value("request") != request || saving.value("status") != "scheduled") return;
                    saving["status"] = "requested";
                    QJsonObject result;
                    if (!target.object || !target.view || guitarpro::choose(bound).object != target.object) result = {{"error", "Document changed before saving"}};
                    else {
                        try {
                            result = guitarpro::activate(bound, services());
                            if (!result.contains("error")) result = performSave(bound, tool != "gp_save", tool == "gp_save_current", saving);
                        } catch (const std::exception &exception) { result = {{"error", QString::fromUtf8(exception.what())}, {"outcome_unknown", true}}; }
                        catch (...) { result = {{"error", "Unknown native save activation exception"}, {"outcome_unknown", true}}; }
                    }
                    saving["result"] = result;
                    saving["status"] = result.contains("error") ? "error" : "saved";
                    if (result.contains("error")) saving["error"] = result.value("error");
                    if (result.value("outcome_unknown").toBool()) saving["outcome_unknown"] = true;
                    if (cancelledSave(saving, result)) saving["status"] = "cancelled";
                });
                return saving;
            }
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
                        widget->activateWindow();
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
                result["session_file"] = sessionFile;
                result["plugin_data_directory"] = gpmcp::dataDirectory();
                result["modal_dialog"] = modalState();
                result["p9"] = guitarpro::p9Status();
                gpmcp_audio_bridge_info provider{};
                provider.struct_size = sizeof(provider);
                const uint32_t providerStatus = audioBridgeInfo(&provider);
                const QString providerStatusName = providerStatus == GPMCP_AUDIO_OK ? "ready" :
                    providerStatus == GPMCP_AUDIO_NOT_READY ? "not_ready" :
                    providerStatus == GPMCP_AUDIO_WRONG_THREAD ? "wrong_thread" :
                    providerStatus == GPMCP_AUDIO_ABI_MISMATCH ? "abi_mismatch" : "host_limited";
                result["audio_provider"] = QJsonObject{{"abi_version", int(provider.abi_version)},
                    {"status", providerStatusName}, {"generation", qint64(provider.generation)},
                    {"capabilities", qint64(provider.capabilities)}, {"host_build_sha256", QString::fromLatin1(provider.host_build_sha256)},
                    {"consumer_contract", "audio_bridge_api.h; callback metadata is valid only during the call"}};
                const QByteArray hostHash = guitarpro::hash(QCoreApplication::applicationFilePath());
                result["audio_stream"] = audioStreams.info(guitarpro::currentAudioGeneration(), hostHash);
                result["limitations"] = QJsonArray{"P9 status is exposed by gp_p9_status; unsupported engraving, arbitrary instrument/fingering and dynamics/volume automation remain explicitly host-limited. gp_automation DSP parameter writes are experimental and do not claim complete automation semantics.", "System clipboard interop remains experimental and disabled unless GPMCP_DEVELOPMENT=1 with an isolated validation environment.", "New/open/save/close workflows and playback can complete asynchronously; poll operation/document/playback state. Activate a document before playback control."};
                return result;
            }
            const QHash<QString, QString> operations{{"gp_objects", "native_objects"}, {"gp_actions", "native_actions"}, {"gp_trigger", "native_trigger"}, {"gp_set_property", "native_set_property"}, {"gp_close_window", "native_close_window"}};
            return execute(operations.value(tool), args);
        })) {
            gpmcp::diagnostic("service_error", server.errorString());
            qWarning("GuitarProMCP: failed to start native MCP HTTP server");
        } else {
            sessionFile = server.sessionFile();
            qApp->setProperty("gpmcpSessionFile", sessionFile);
            gpmcp::diagnostic("running");
        }
    }

protected:
    bool eventFilter(QObject *object, QEvent *event) override {
        if (event->type() == QEvent::ThreadChange) { registry.forget(object); nativeObjects.remove(object); return false; }
        const QByteArray name = object->metaObject()->className();
        if (savingOperation && event->type() == QEvent::Show) {
            if (auto modal = qobject_cast<QDialog *>(object)) {
                const auto target = guitarpro::choose({{"document", savingOperation->value("document")}});
                if (modal->isModal() && target.view && modal->parentWidget() == target.view->window()) {
                    saveModal = modal;
                    const QString request = savingOperation->value("request").toString();
                    const auto cancelled = [this, request]() {
                        if (savingOperation && savingOperation->value("request") == request) {
                            (*savingOperation)["cancel_requested"] = true;
                            (*savingOperation)["cancel_decision_available"] = true;
                        }
                    };
                    if (auto box = qobject_cast<QMessageBox *>(modal)) {
                        if (auto button = box->button(QMessageBox::Cancel)) connect(button, &QAbstractButton::clicked, this, cancelled);
                    } else for (auto box : modal->findChildren<QDialogButtonBox *>()) {
                        if (auto button = box->button(QDialogButtonBox::Cancel)) connect(button, &QAbstractButton::clicked, this, cancelled);
                    }
                }
            }
        }
        if (loadNativeActive && event->type() == QEvent::Show) {
            if (auto modal = qobject_cast<QDialog *>(object)) {
                if (modal->isModal() && modal->parentWidget() && QByteArray(modal->parentWidget()->metaObject()->className()) == "gp::gui::MainWindow") {
                    loadModal = modal;
                    (loadingKind == "open" ? opening : creation)["dialog"] = modalState();
                }
            }
        }
        if (closingNativeActive && event->type() == QEvent::Show) {
            if (auto modal = qobject_cast<QDialog *>(object)) {
                if (modal->isModal() && closingView && modal->parentWidget() == closingView->window()) {
                    QAbstractButton *discard = nullptr, *cancel = nullptr, *save = nullptr;
                    if (auto box = qobject_cast<QMessageBox *>(modal)) {
                        discard = box->button(QMessageBox::Discard); cancel = box->button(QMessageBox::Cancel); save = box->button(QMessageBox::Save);
                    } else for (QDialogButtonBox *box : modal->findChildren<QDialogButtonBox *>()) {
                        if (box->button(QDialogButtonBox::Save) && box->button(QDialogButtonBox::Discard) && box->button(QDialogButtonBox::Cancel)) {
                            discard = box->button(QDialogButtonBox::Discard); cancel = box->button(QDialogButtonBox::Cancel); save = box->button(QDialogButtonBox::Save); break;
                        }
                    }
                    if (discard && cancel && save) {
                        closingModal = modal;
                        const QString request = closing.value("request").toString();
                        connect(cancel, &QAbstractButton::clicked, this, [this, request]() { if (closing.value("request") == request) closing["decision"] = "cancel"; });
                        connect(discard, &QAbstractButton::clicked, this, [this, request]() { if (closing.value("request") == request) closing["decision"] = "discard"; });
                        connect(save, &QAbstractButton::clicked, this, [this, request]() { if (closing.value("request") == request) closing["decision"] = "save"; });
                        connect(modal, &QDialog::rejected, this, [this, request]() { if (closing.value("request") == request) closing["decision"] = "cancel"; });
                        if (closing.value("unsaved") == "discard") {
                            QPointer<QAbstractButton> button = discard;
                            QTimer::singleShot(0, this, [this, button, request]() {
                                if (closing.value("request") == request && closingNativeActive && closingModal == QApplication::activeModalWidget() && button && button->isEnabled()) button->click();
                            });
                        }
                    }
                }
            }
        }
        if (name == "gp::gui::MainWindow" && event->type() == QEvent::Polish) {
            // Hidden mode disables Qt's last-visible-window exit; an accepted host close still exits.
            connect(object, &QObject::destroyed, this, [this] {
                if (hiddenMode && !shuttingDown) QCoreApplication::quit();
            });
        }
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
        if (name.startsWith("gp::") && (name.contains("Manager") || name.contains("PreferencesModel") || name.contains("ConfigurationWidgetModel") || name.startsWith("gp::rse::") || name == "gp::gui::IAudioDocument") &&
            nativeObjects.size() < 1024 && !nativeObjects.contains(object)) {
            nativeObjects.insert(object, QPointer<QObject>(object));
            connect(object, &QObject::destroyed, this, [this, object]() { nativeObjects.remove(object); });
        }
        return false;
    }
public:
    uint32_t audioBridgeInfo(gpmcp_audio_bridge_info *info) {
        if (!info || info->struct_size < sizeof(*info)) return GPMCP_AUDIO_ABI_MISMATCH;
        if (qApp && QThread::currentThread() != qApp->thread()) return GPMCP_AUDIO_WRONG_THREAD;
        std::memset(info, 0, sizeof(*info));
        info->struct_size = sizeof(*info);
        info->abi_version = GPMCP_AUDIO_BRIDGE_ABI_VERSION;
        info->generation = guitarpro::currentAudioGeneration();
        info->capabilities = GPMCP_AUDIO_CAP_BINDINGS | GPMCP_AUDIO_CAP_CONTEXTS;
        if (qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT")) info->capabilities |= GPMCP_AUDIO_CAP_BUFFER_PROBE;
        const QByteArray hostHash = guitarpro::hash(QCoreApplication::applicationFilePath());
        const size_t hashLength = hostHash.size() < qint64(sizeof(info->host_build_sha256) - 1)
            ? size_t(hostHash.size()) : sizeof(info->host_build_sha256) - 1;
        if (hashLength) std::memcpy(info->host_build_sha256, hostHash.constData(), hashLength);
        info->status = !guitarpro::supportedBuild() || !guitarpro::verifiedHostFile("GPRSE.dll")
            ? GPMCP_AUDIO_HOST_LIMITED : (guitarpro::documents().isEmpty() ? GPMCP_AUDIO_NOT_READY : GPMCP_AUDIO_OK);
        return info->status;
    }
    uint32_t enumerateAudioBindingsV1(uint32_t requestedAbi, gpmcp_audio_binding_visitor visitor,
                                      void *user, gpmcp_audio_enumerate_result *result) {
        if (!qApp || QThread::currentThread() != qApp->thread()) {
            if (result && result->struct_size >= sizeof(*result)) {
                result->status = qApp ? GPMCP_AUDIO_WRONG_THREAD : GPMCP_AUDIO_NOT_READY;
                result->generation = 0;
                result->count = 0;
            }
            return qApp ? GPMCP_AUDIO_WRONG_THREAD : GPMCP_AUDIO_NOT_READY;
        }
        return guitarpro::enumerateAudioBindingsV1(services(), requestedAbi, visitor, user, result);
    }

    Bridge() {
        // Qt owns generic-plugin return values; release resources without deleting its object.
        connect(qApp, &QCoreApplication::aboutToQuit, this, [this] { shutdown(); });
        if (hiddenMode) qApp->setQuitOnLastWindowClosed(false);
        connect(&creationPoll, &QTimer::timeout, this, [this]() { checkCreation(); });
        connect(&openingPoll, &QTimer::timeout, this, [this]() { checkOpening(); });
        qApp->installEventFilter(this);
        const QString qtCore = QDir(QCoreApplication::applicationDirPath()).filePath("Qt5Core.dll");
        if (guitarpro::supportedBuild() && guitarpro::hash(qtCore) == "c2f85bd55c31e5380dd99f0d517ee183a54c3852480bc497dc30a5483fd70ff2") registry.install();
        setObjectName("GuitarProMCPBridge");
        qApp->setProperty("gpmcpBridge", QVariant::fromValue<QObject *>(this));
        QTimer::singleShot(0, this, [this]() { if (!shuttingDown) start(); });
    }
    ~Bridge() override { shutdown(); }
};

class GuitarProPlugin : public QGenericPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QGenericPluginFactoryInterface_iid FILE "guitarpro_mcp.json")
public:
    QObject *create(const QString &name, const QString &) override {
        if (name.compare("guitarpro_mcp", Qt::CaseInsensitive) ||
            QFileInfo(QCoreApplication::applicationFilePath()).baseName().compare("GuitarPro", Qt::CaseInsensitive) ||
            !QString::fromLatin1(qVersion()).startsWith("5.15.")) return nullptr;
        if (qApp->property("gpmcpBridge").value<QObject *>()) return nullptr;
        return new Bridge;
    }
};

// Internal same-process bridge for native plugin consumers. It intentionally
// exposes only a callback over the verified native object boundary; MCP clients
// continue to receive opaque UUID handles and never see these addresses.
extern "C" GPMCP_AUDIO_EXPORT unsigned GPMCP_AUDIO_CALL gpmcp_audio_bridge_version() noexcept { return GPMCP_AUDIO_BRIDGE_ABI_VERSION; }

extern "C" GPMCP_AUDIO_EXPORT uint32_t GPMCP_AUDIO_CALL gpmcp_audio_bridge_get_info(
    gpmcp_audio_bridge_info *info) noexcept {
    if (!info || info->struct_size < sizeof(*info)) return GPMCP_AUDIO_ABI_MISMATCH;
    std::memset(info, 0, sizeof(*info));
    info->struct_size = sizeof(*info);
    info->abi_version = GPMCP_AUDIO_BRIDGE_ABI_VERSION;
    info->status = GPMCP_AUDIO_NOT_READY;
    if (!qApp) return info->status;
    if (QThread::currentThread() != qApp->thread()) {
        info->status = GPMCP_AUDIO_WRONG_THREAD;
        return info->status;
    }
    try {
        auto *object = qApp->property("gpmcpBridge").value<QObject *>();
        if (object && object->objectName() == QStringLiteral("GuitarProMCPBridge"))
            return static_cast<Bridge *>(object)->audioBridgeInfo(info);
    } catch (...) { info->status = GPMCP_AUDIO_INTERNAL_ERROR; }
    return info->status;
}

extern "C" GPMCP_AUDIO_EXPORT uint32_t GPMCP_AUDIO_CALL gpmcp_audio_enumerate_v1(
    uint32_t requestedAbi, gpmcp_audio_binding_visitor visitor, void *user,
    gpmcp_audio_enumerate_result *result) noexcept {
    if (!result || result->struct_size < sizeof(*result)) return GPMCP_AUDIO_ABI_MISMATCH;
    result->status = GPMCP_AUDIO_NOT_READY;
    result->generation = 0;
    result->count = 0;
    if (requestedAbi != GPMCP_AUDIO_BRIDGE_ABI_VERSION) {
        result->status = GPMCP_AUDIO_ABI_MISMATCH;
        return result->status;
    }
    if (!qApp) return result->status;
    if (QThread::currentThread() != qApp->thread()) {
        result->status = GPMCP_AUDIO_WRONG_THREAD;
        return result->status;
    }
    try {
        auto *object = qApp->property("gpmcpBridge").value<QObject *>();
        if (object && object->objectName() == QStringLiteral("GuitarProMCPBridge"))
            return static_cast<Bridge *>(object)->enumerateAudioBindingsV1(requestedAbi, visitor, user, result);
    } catch (...) { result->status = GPMCP_AUDIO_INTERNAL_ERROR; }
    return result->status;
}

extern "C" GPMCP_AUDIO_STREAM_EXPORT unsigned GPMCP_AUDIO_STREAM_CALL gpmcp_audio_stream_version() noexcept {
    return GPMCP_AUDIO_STREAM_ABI_VERSION;
}

extern "C" GPMCP_AUDIO_STREAM_EXPORT uint32_t GPMCP_AUDIO_STREAM_CALL gpmcp_audio_stream_get_info(
    gpmcp_audio_stream_info *info) noexcept {
    if (!info || info->struct_size < sizeof(*info)) return GPMCP_AUDIO_STREAM_ABI_MISMATCH;
    std::memset(info, 0, sizeof(*info));
    info->struct_size = sizeof(*info);
    info->abi_version = GPMCP_AUDIO_STREAM_ABI_VERSION;
    info->status = GPMCP_AUDIO_STREAM_HOST_LIMITED;
    info->capabilities = GPMCP_AUDIO_STREAM_CAP_SESSION | GPMCP_AUDIO_STREAM_CAP_METRICS |
        GPMCP_AUDIO_STREAM_CAP_DIAGNOSTICS | GPMCP_AUDIO_STREAM_CAP_RECOVERY;
    if (!qApp) return info->status;
    if (QThread::currentThread() != qApp->thread()) {
        info->status = GPMCP_AUDIO_STREAM_WRONG_THREAD;
        return info->status;
    }
    try {
        info->generation = guitarpro::currentAudioGeneration();
        const QByteArray hash = guitarpro::hash(QCoreApplication::applicationFilePath());
        const size_t length = (std::min<size_t>)(hash.size(), sizeof(info->host_build_sha256) - 1);
        if (length) std::memcpy(info->host_build_sha256, hash.constData(), length);
        auto *object = qApp->property("gpmcpBridge").value<QObject *>();
        if (object && object->objectName() == QStringLiteral("GuitarProMCPBridge")) {
            // The MCP-facing registry owns sessions; the C ABI intentionally
            // reports the same host-limited state until a verified callback is
            // available, without exposing Qt or host pointers.
            info->stream_count = 0;
        }
    } catch (...) { info->status = GPMCP_AUDIO_STREAM_INTERNAL_ERROR; }
    return info->status;
}

extern "C" GPMCP_AUDIO_STREAM_EXPORT uint32_t GPMCP_AUDIO_STREAM_CALL gpmcp_audio_stream_enumerate_v1(
    uint32_t requestedAbi, gpmcp_audio_stream_state_visitor visitor, void *user,
    gpmcp_audio_stream_enumerate_result *result) noexcept {
    if (!result || result->struct_size < sizeof(*result)) return GPMCP_AUDIO_STREAM_ABI_MISMATCH;
    result->status = GPMCP_AUDIO_STREAM_NOT_READY;
    result->generation = 0;
    result->count = 0;
    if (requestedAbi != GPMCP_AUDIO_STREAM_ABI_VERSION) {
        result->status = GPMCP_AUDIO_STREAM_ABI_MISMATCH;
        return result->status;
    }
    if (!visitor) {
        result->status = GPMCP_AUDIO_STREAM_INVALID_ARGUMENT;
        return result->status;
    }
    if (!qApp) return result->status;
    if (QThread::currentThread() != qApp->thread()) {
        result->status = GPMCP_AUDIO_STREAM_WRONG_THREAD;
        return result->status;
    }
    result->generation = guitarpro::currentAudioGeneration();
    // No verified host callback is available in 8.1.1.17.  Returning an empty
    // enumeration is intentional and keeps consumers from mistaking a
    // synthetic/offline buffer for live endpoint audio.
    result->status = GPMCP_AUDIO_STREAM_HOST_LIMITED;
    Q_UNUSED(user);
    return result->status;
}
#include "guitarpro_mcp.moc"
