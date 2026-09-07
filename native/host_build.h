#pragma once
#include <QtCore/QCoreApplication>
#include <QtCore/QCryptographicHash>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QHash>

namespace guitarpro {
inline QByteArray hash(const QString &path) {
    QFile file(path); if (!file.open(QIODevice::ReadOnly)) return {};
    QCryptographicHash hash(QCryptographicHash::Sha256);
    if (!hash.addData(&file)) return {};
    return hash.result().toHex();
}
inline bool verifiedHostFile(const QString &name) {
    const QHash<QString, QByteArray> expected{
        {"GuitarPro.exe", "b233b0f1c87deb3aece693d51e8d3c3a841c88fee78828607b20034737c4c6df"},
        {"GPCore.dll", "9425f3e8eb627d328e0cb01146d43045d86d1ba639f73718bbe7fccf733bd250"},
        {"GPRSE.dll", "e983122951b94c2513a1f05828dd03dcb11620ddc50f6b497723cae0eb32ba6a"},
        {"AMAudio.dll", "0151b8d484a0dbedbb74aa1a43975932349f812a2d8929dfaad149efbd992394"},
        {"AMUtils.dll", "c11b33ae71a32b7b0ce762fc14f6141f8ba46240a6e21188f2ce411eb2290d51"},
        {"GPIO.dll", "c606cf3445e6d320c50574e060b3ccc642b8b067105a61ccc85d27ad6fb7a958"},
        {"AMPainting.dll", "29eec1afe7bf7b02b7468b0aaa14bb4c0a85780e80d7bebc6017472312c1adbf"},
        {"Qt5PrintSupport.dll", "bc4a798de74bac1d945a5088522c2571d7c2c4a37b525c102af5660c50695d88"},
        {"Qt5Core.dll", "c2f85bd55c31e5380dd99f0d517ee183a54c3852480bc497dc30a5483fd70ff2"},
        {"Qt5Gui.dll", "bd853bb77296301ea0dbd0c432b5a4268389d4054c15f39dd44f245af24eb407"}
    };
    return expected.contains(name) && hash(QDir(QCoreApplication::applicationDirPath()).filePath(name)) == expected.value(name);
}
inline bool supportedBuild() {
    static const bool supported = verifiedHostFile("GuitarPro.exe") && verifiedHostFile("GPCore.dll") && verifiedHostFile("Qt5Gui.dll");
    return supported;
}
}
