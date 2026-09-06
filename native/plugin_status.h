#pragma once
#include "plugin_config.h"
#include <QtWidgets/QApplication>
#include <QtWidgets/QCheckBox>
#include <QtWidgets/QDialog>
#include <QtWidgets/QDialogButtonBox>
#include <QtWidgets/QFormLayout>
#include <QtWidgets/QLabel>
#include <QtWidgets/QMainWindow>
#include <QtWidgets/QMenuBar>
#include <QtWidgets/QMessageBox>
#include <QtWidgets/QPushButton>
#include <QtWidgets/QStyle>
#include <QtGui/QDesktopServices>
#include <QtCore/QTimer>
#include <QtCore/QUrl>

namespace gpmcp {
inline void showStatus(QWidget *parent) {
    auto dialog = new QDialog(parent);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->setObjectName("gpmcpStatusDialog");
    dialog->setWindowModality(Qt::WindowModal);
    dialog->setWindowTitle("Guitar Pro MCP");
    auto layout = new QFormLayout(dialog);
    auto status = new QLabel(qApp->property("gpmcpStatus").toString(), dialog);
    status->setObjectName("gpmcpServiceStatus");
    layout->addRow("Service", status);
    if (!qApp->property("gpmcpStatusDetail").toString().isEmpty()) {
        auto detail = new QLabel(qApp->property("gpmcpStatusDetail").toString(), dialog);
        detail->setWordWrap(true);
        layout->addRow(detail);
    }
    QString session = qApp->property("gpmcpSessionFile").toString();
    if (session.isEmpty()) session = qEnvironmentVariable("GPMCP_SESSION_FILE");
    if (session.isEmpty()) session = QDir(dataDirectory()).filePath("native-session.json");
    QFile descriptor(session);
    QString endpoint = "Unavailable";
    QString config;
    if (descriptor.open(QIODevice::ReadOnly)) {
        const auto identity = QJsonDocument::fromJson(descriptor.readAll()).object();
        if (identity.value("pid").toVariant().toLongLong() == QCoreApplication::applicationPid()) {
            endpoint = identity.value("url").toString();
            config = identity.value("client_config").toString();
        }
    }
    auto address = new QLabel(endpoint, dialog);
    address->setTextInteractionFlags(Qt::TextSelectableByMouse);
    layout->addRow("Endpoint", address);
    QJsonObject settings;
    const bool valid = readSettings(settings);
    auto enabled = new QCheckBox("Load at startup", dialog);
    enabled->setObjectName("gpmcpEnabled");
    enabled->setChecked(valid && settings.value("enabled").toBool(true));
    enabled->setEnabled(valid);
    layout->addRow(enabled);
    auto pending = new QLabel(dialog);
    layout->addRow(pending);
    QObject::connect(enabled, &QCheckBox::toggled, dialog, [dialog, pending](bool checked) {
        if (writeEnabled(checked)) pending->setText("Restart required");
        else QMessageBox::warning(dialog, "Guitar Pro MCP", "Cannot update settings.json");
    });
    auto openConfig = new QPushButton(dialog->style()->standardIcon(QStyle::SP_DirOpenIcon), "Open client configuration", dialog);
    openConfig->setEnabled(QFileInfo::exists(config));
    QObject::connect(openConfig, &QPushButton::clicked, dialog, [config] { QDesktopServices::openUrl(QUrl::fromLocalFile(config)); });
    layout->addRow(openConfig);
    auto buttons = new QDialogButtonBox(QDialogButtonBox::Close, dialog);
    QObject::connect(buttons, &QDialogButtonBox::rejected, dialog, &QDialog::close);
    layout->addRow(buttons);
    dialog->setMinimumWidth(400);
    dialog->show();
}
inline void installStatusAction() {
    auto timer = new QTimer(qApp);
    timer->setInterval(200);
    QObject::connect(timer, &QTimer::timeout, timer, [timer] {
        for (QWidget *widget : QApplication::topLevelWidgets()) {
            if (QByteArray(widget->metaObject()->className()) != "gp::gui::MainWindow") continue;
            auto window = qobject_cast<QMainWindow *>(widget);
            if (!window) continue;
            if (!window->findChild<QAction *>("gpmcpStatusAction")) {
                auto action = window->menuBar()->addAction("MCP");
                action->setObjectName("gpmcpStatusAction");
                QObject::connect(action, &QAction::triggered, window, [window] { showStatus(window); });
            }
            timer->deleteLater(); return;
        }
        const int attempts = timer->property("attempts").toInt() + 1;
        timer->setProperty("attempts", attempts);
        if (attempts >= 150) timer->deleteLater();
    });
    timer->start();
}
}
