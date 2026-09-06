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
