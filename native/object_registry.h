#pragma once
#include <QtCore/QHash>
#include <QtCore/QPointer>
#include <QtCore/QObject>
#include <QtCore/QList>
#include <windows.h>
#include <atomic>

// Qt 5.15 QObject lifecycle observation. The caller checks the exact Qt DLL hash.
// Only GUI-thread objects are retained; ThreadChange removes objects before a move.
class ObjectRegistry {
    inline static ObjectRegistry *active = nullptr; // accessed only on GUI thread
    inline static std::atomic<DWORD> guiThread{0};
    QHash<QObject *, QPointer<QObject>> entries;
    quintptr *hooks = nullptr;
    bool overflow = false;
    static void added(QObject *object) {
        if (GetCurrentThreadId() != guiThread.load() || !active) return;
        // ponytail: bounded discovery; huge scores use the paged native model API.
        if (active->entries.size() >= 100000) { active->overflow = true; return; }
        active->entries.insert(object, QPointer<QObject>(object));
    }
    static void removed(QObject *object) {
        if (GetCurrentThreadId() == guiThread.load() && active) active->entries.remove(object);
    }
public:
    bool install() {
        if (active) return false;
        hooks = reinterpret_cast<quintptr *>(GetProcAddress(GetModuleHandleW(L"Qt5Core.dll"), "?qtHookData@@3PA_KA"));
        // QHooks indices/version from the matching Qt source. Do not replace another observer.
        if (!hooks || hooks[0] != 3 || hooks[1] < 7 || hooks[2] != 0x050f03 || hooks[3] || hooks[4]) { hooks = nullptr; return false; }
        HMODULE module = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                               reinterpret_cast<LPCWSTR>(&added), &module)) { hooks = nullptr; return false; }
        guiThread.store(GetCurrentThreadId()); active = this;
        hooks[3] = reinterpret_cast<quintptr>(&added);
        hooks[4] = reinterpret_cast<quintptr>(&removed);
        return true;
    }
    ~ObjectRegistry() {
        if (!hooks) return;
        if (hooks[3] == reinterpret_cast<quintptr>(&added)) hooks[3] = 0;
        if (hooks[4] == reinterpret_cast<quintptr>(&removed)) hooks[4] = 0;
        active = nullptr;
    }
    void forget(QObject *object) { entries.remove(object); }
    QList<QPointer<QObject>> objects() const {
        QList<QPointer<QObject>> result;
        for (const auto &object : entries) if (object) result.append(object);
        return result;
    }
    bool installed() const { return hooks != nullptr; }
    bool truncated() const { return overflow; }
};
