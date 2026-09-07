#pragma once
#include <QtCore/QJsonObject>
#include <QtCore/QJsonArray>
#include <QtCore/QSet>
#include <QtCore/QQueue>
#include <QtWidgets/QWidget>
#include <windows.h>
#include <array>

namespace discovery {
template<class T> bool read(quintptr address, T &out) {
    SIZE_T size = 0;
    return address && ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<const void *>(address), &out, sizeof(out), &size) && size == sizeof(out);
}
inline QString type(quintptr object) {
    quintptr vtable = 0, locator = 0;
    MEMORY_BASIC_INFORMATION memory{};
    if (!read(object, vtable) || !VirtualQuery(reinterpret_cast<void *>(vtable), &memory, sizeof(memory)) || memory.Type != MEM_IMAGE || !read(vtable - 8, locator)) return {};
    struct Locator { quint32 signature, offset, constructionOffset, typeRva, hierarchyRva, selfRva; } col{};
    if (!read(locator, col) || col.signature != 1 || locator - col.selfRva != reinterpret_cast<quintptr>(memory.AllocationBase)) return {};
    std::array<char, 256> name{};
    if (!read(locator - col.selfRva + col.typeRva + 16, name)) return {};
    name.back() = 0;
    const QString result = QString::fromLatin1(name.data());
    return result.startsWith(".?A") ? result : QString();
}
inline QObject *asQObject(quintptr object) {
    quintptr vtable = 0, locator = 0;
    if (!read(object, vtable) || !read(vtable - 8, locator)) return nullptr;
    struct Locator { quint32 signature, offset, constructionOffset, typeRva, hierarchyRva, selfRva; } col{};
    if (!read(locator, col) || col.signature != 1) return nullptr;
    const quintptr base = locator - col.selfRva;
    struct Hierarchy { quint32 signature, attributes, count, arrayRva; } hierarchy{};
    if (!read(base + col.hierarchyRva, hierarchy) || hierarchy.count > 128) return nullptr;
    for (quint32 i = 0; i < hierarchy.count; ++i) {
        quint32 entry = 0;
        struct Base { quint32 typeRva, contained; qint32 displacement, vbtable, vdisp; quint32 attributes; } descriptor{};
        std::array<char, 96> name{};
        if (!read(base + hierarchy.arrayRva + i * 4, entry) || !read(base + entry, descriptor) || !read(base + descriptor.typeRva + 16, name)) continue;
        name.back() = 0;
        if (QByteArray(name.data()) == ".?AVQObject@@" && descriptor.vbtable == -1 && descriptor.displacement >= 0)
            return reinterpret_cast<QObject *>(object - col.offset + descriptor.displacement);
    }
    return nullptr;
}
// Development-only, read-only walk from known Qt object roots. No address is accepted from clients.
inline QJsonArray inspect(const QList<QObject *> &roots) {
    struct Candidate { quintptr pointer; QString path; int depth; };
    QQueue<Candidate> queue;
    for (QObject *object : roots) {
        const QString cls = object->metaObject()->className();
        if (cls == "QAction" && (object->objectName() == "actionEditCopy" || object->objectName() == "actionEditPaste"))
            queue.enqueue({reinterpret_cast<quintptr>(object), cls + "[" + object->objectName() + "]", 0});
        if (cls == "gp::gui::MainWindow" || cls == "gp::gui::IDocumentView" || cls == "gp::gui::ScoreEngravingWidget" || cls == "gp::gui::TransportBar" || cls == "gp::gui::DocumentViewResponder" || cls == "gp::gui::IDocumentsManager" || cls == "gp::rse::ConductorController")
            queue.enqueue({reinterpret_cast<quintptr>(object), cls, 0});
    }
    QJsonArray result;
    QSet<quintptr> visited;
    while (!queue.isEmpty() && visited.size() < 12000) {
        const Candidate candidate = queue.dequeue();
        if (visited.contains(candidate.pointer)) continue;
        visited.insert(candidate.pointer);
        const QString name = type(candidate.pointer);
        if (!name.isEmpty()) result.append(QJsonObject{{"path", candidate.path}, {"rtti", name}, {"address", QString::number(candidate.pointer, 16)}});
        if (candidate.depth >= 5 || (candidate.depth && !name.isEmpty() && !name.contains("@gp@@") && !name.contains("GPDocument"))) continue;
        std::array<quintptr, 128> fields{};
        if (!read(candidate.pointer, fields)) continue;
        for (size_t i = 1; i < fields.size(); ++i) {
            const quintptr next = fields[i];
            MEMORY_BASIC_INFORMATION region{};
            if (next < 0x10000 || (next % 8) || !VirtualQuery(reinterpret_cast<void *>(next), &region, sizeof(region)) || region.State != MEM_COMMIT || region.Type != MEM_PRIVATE || (region.Protect & (PAGE_NOACCESS | PAGE_GUARD))) continue;
            const QString childType = type(next);
            if (childType.isEmpty() && candidate.depth >= 3) continue;
            queue.enqueue({next, candidate.path + QString("+0x%1").arg(i * 8, 0, 16), candidate.depth + 1});
        }
    }
    return result;
}
}


