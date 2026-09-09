#include <QtGui/QGenericPlugin>
#include <QtCore/QCoreApplication>
#include <QtCore/QFile>
#include <QtCore/QDir>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QHash>
#include <QtCore/QTimer>
#include <QtCore/QRegularExpression>
#include <QtCore/QThread>
#include <windows.h>
#include <tlhelp32.h>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include "guitarpro_api.h"

// This isolated probe substitutes Windows imports in memory. It is excluded
// from the production build and only faults handles for the test target.
class FaultProbe : public QObject {
    Q_OBJECT
    struct WriteState { int writer; QString mode; bool failed = false; };
    struct Import { void **slot; void *original; void *replacement; };
    inline static FaultProbe *active = nullptr;
    QString directory, target, backupTarget, request, mode;
    int writers = 0, selectedWriter = 1;
    std::recursive_mutex mutex;
    HANDLE lock = INVALID_HANDLE_VALUE;
    QHash<HANDLE, WriteState> streams;
    QPointer<QObject> exceptionDocument;
    QList<Import> imports;
    QTimer poll{this};

    void record(QJsonObject event) const {
        event["request"] = request; event["pid"] = QCoreApplication::applicationPid();
        const QByteArray bytes = QJsonDocument(event).toJson(QJsonDocument::Compact) + '\n';
        const QString path = directory + "/probe.jsonl";
        const HANDLE file = CreateFileW(reinterpret_cast<LPCWSTR>(path.utf16()), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file != INVALID_HANDLE_VALUE) { DWORD written = 0; WriteFile(file, bytes.constData(), DWORD(bytes.size()), &written, nullptr); CloseHandle(file); }
    }
    void release() {
        if (lock != INVALID_HANDLE_VALUE) { CloseHandle(lock); lock = INVALID_HANDLE_VALUE; record({{"event", "lock_released"}}); }
    }
    void refresh() {
        std::lock_guard<std::recursive_mutex> guard(mutex);
        QFile input(directory + "/control.json");
        if (!input.open(QIODevice::ReadOnly)) return;
        const auto config = QJsonDocument::fromJson(input.readAll()).object();
        if (config.value("request").toString().isEmpty()) return;
        if (config.value("request").toString() != request) {
            release(); writers = 0; streams.clear(); exceptionDocument.clear(); request = config.value("request").toString();
            record({{"event", "configuration"}, {"mode", config.value("mode")}});
        }
        mode = config.value("mode").toString(); selectedWriter = config.value("writer").toInt(1);
        if (mode.isEmpty()) release();
    }
    QString filePath(HANDLE file) const {
        if (GetFileType(file) != FILE_TYPE_DISK) return {};
        wchar_t path[32768];
        const DWORD length = GetFinalPathNameByHandleW(file, path, DWORD(std::size(path)), FILE_NAME_NORMALIZED);
        if (!length || length >= std::size(path)) return {};
        QString result = QString::fromWCharArray(path, int(length));
        if (result.startsWith("\\\\?\\")) result.remove(0, 4);
        return QDir::cleanPath(QDir::fromNativeSeparators(result));
    }
    bool matches(const QString &path) const {
        const int slash = path.lastIndexOf('/');
        const QString folder = path.left(slash);
        if (folder.compare(directory, Qt::CaseInsensitive) && folder.compare(backupTarget.left(backupTarget.lastIndexOf('/')), Qt::CaseInsensitive)) return false;
        const QString stem = target.mid(directory.size() + 1).chopped(3);
        return QRegularExpression("^" + QRegularExpression::escape(stem) + "(?:\\([0-9]+\\))?\\.gp$", QRegularExpression::CaseInsensitiveOption).match(path.mid(slash + 1)).hasMatch();
    }
    static BOOL WINAPI write(HANDLE file, LPCVOID data, DWORD size, LPDWORD written, LPOVERLAPPED overlapped) {
        auto &probe = *active;
        std::lock_guard<std::recursive_mutex> guard(probe.mutex);
        probe.refresh();
        if (probe.mode.isEmpty()) return WriteFile(file, data, size, written, overlapped);
        if ((probe.mode == "post_validate" || probe.mode == "post_exception" || probe.mode == "path_exception" || probe.mode == "recovery_exception" || probe.mode == "dirty_recovery_exception") && QThread::currentThread() == qApp->thread()) {
            for (const auto &document : guitarpro::documents()) {
                QObject::connect(document.object, SIGNAL(isDirtyChanged(bool)), &probe, SLOT(onDirtyChanged(bool)), Qt::ConnectionType(Qt::DirectConnection | Qt::UniqueConnection));
                QObject::connect(document.object, SIGNAL(openedFilePathChanged(QString)), &probe, SLOT(onOpenedPathChanged(QString)), Qt::ConnectionType(Qt::DirectConnection | Qt::UniqueConnection));
            }
        }
        const QString candidate = probe.filePath(file);
        if (probe.matches(candidate)) probe.record({{"event", "candidate"}, {"path", candidate}, {"overlapped", overlapped != nullptr}, {"bytes", double(size)}});
        if (!size || overlapped) return WriteFile(file, data, size, written, overlapped);
        auto entry = probe.streams.find(file);
        if (entry == probe.streams.end()) {
            const QString path = probe.filePath(file);
            if (!probe.matches(path)) return WriteFile(file, data, size, written, overlapped);
            const int writer = ++probe.writers;
            entry = probe.streams.insert(file, {writer, writer >= probe.selectedWriter ? probe.mode : QString()});
            probe.record({{"event", "write_started"}, {"writer", writer}, {"mode", entry->mode}, {"path", path}, {"bytes_requested", double(size)}});
        }
        if (entry->mode == "write" || entry->mode == "recovery") {
            if (!entry->failed) {
                DWORD partial = 0;
                WriteFile(file, data, qMin<DWORD>(32, size), &partial, nullptr);
                FlushFileBuffers(file); entry->failed = true;
                probe.record({{"event", "write_failed"}, {"writer", entry->writer}, {"bytes_written", double(partial)}, {"bytes_requested", double(size)}});
            }
            if (written) *written = 0;
            SetLastError(ERROR_DISK_FULL); return FALSE;
        }
        return WriteFile(file, data, size, written, overlapped);
    }
    static BOOL WINAPI close(HANDLE file) {
        auto &probe = *active;
        std::lock_guard<std::recursive_mutex> guard(probe.mutex);
        if (!probe.streams.contains(file)) return CloseHandle(file);
        const auto entry = probe.streams.take(file);
        if (entry.mode == "corrupt") {
            LARGE_INTEGER position{}, before{}, after{};
            DWORD written = 0;
            const char invalidSignature[4] = {};
            const bool corrupted = GetFileSizeEx(file, &before) && SetFilePointerEx(file, position, nullptr, FILE_BEGIN) &&
                WriteFile(file, invalidSignature, sizeof(invalidSignature), &written, nullptr) && written == sizeof(invalidSignature) && GetFileSizeEx(file, &after);
            probe.record({{"event", "output_corrupted"}, {"writer", entry.writer}, {"corrupted", corrupted}, {"bytes_before", double(before.QuadPart)}, {"bytes_after", double(after.QuadPart)}});
        }
        const BOOL result = CloseHandle(file);
        const DWORD error = GetLastError();
        if (entry.failed && entry.mode == "recovery" && probe.lock == INVALID_HANDLE_VALUE) {
            probe.lock = CreateFileW(reinterpret_cast<LPCWSTR>(probe.target.utf16()), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            probe.record({{"event", "recovery_locked"}, {"locked", probe.lock != INVALID_HANDLE_VALUE}, {"win32_error", double(GetLastError())}});
        }
        probe.record({{"event", "write_closed"}, {"writer", entry.writer}, {"closed", bool(result)}, {"failed", entry.failed}});
        SetLastError(error);
        return result;
    }
    static bool replace(Import &import, bool installing) {
        DWORD protection = 0;
        if (!VirtualProtect(import.slot, sizeof(void *), PAGE_READWRITE, &protection)) return false;
        const auto expected = installing ? import.original : import.replacement;
        const auto replacement = installing ? import.replacement : import.original;
        const bool changed = InterlockedCompareExchangePointer(import.slot, replacement, expected) == expected;
        DWORD unused = 0; VirtualProtect(import.slot, sizeof(void *), protection, &unused);
        return changed;
    }
    void install(HMODULE module) {
        const auto base = reinterpret_cast<unsigned char *>(module);
        const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
        const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64 *>(base + dos->e_lfanew);
        const auto directory = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
        if (!directory.VirtualAddress) return;
        auto descriptor = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR *>(base + directory.VirtualAddress);
        for (; descriptor->Name; ++descriptor) {
            if (!descriptor->OriginalFirstThunk) continue;
            auto names = reinterpret_cast<const IMAGE_THUNK_DATA64 *>(base + descriptor->OriginalFirstThunk);
            auto addresses = reinterpret_cast<IMAGE_THUNK_DATA64 *>(base + descriptor->FirstThunk);
            for (; names->u1.AddressOfData; ++names, ++addresses) {
                if (IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal)) continue;
                const auto symbol = reinterpret_cast<const IMAGE_IMPORT_BY_NAME *>(base + names->u1.AddressOfData);
                const char *name = reinterpret_cast<const char *>(symbol->Name);
                void *original = nullptr, *replacement = nullptr;
                if (!std::strcmp(name, "WriteFile")) { original = reinterpret_cast<void *>(&WriteFile); replacement = reinterpret_cast<void *>(&write); }
                if (!std::strcmp(name, "CloseHandle")) { original = reinterpret_cast<void *>(&CloseHandle); replacement = reinterpret_cast<void *>(&close); }
                if (!original || addresses->u1.Function != reinterpret_cast<ULONGLONG>(original)) continue;
                Import import{reinterpret_cast<void **>(&addresses->u1.Function), original, replacement};
                if (replace(import, true)) imports.append(import);
            }
        }
    }
    void stop() {
        std::lock_guard<std::recursive_mutex> guard(mutex);
        poll.stop();
        for (auto &import : imports) replace(import, false);
        imports.clear(); release(); streams.clear();
    }
private slots:
    void onDirtyChanged(bool dirty) {
        std::lock_guard<std::recursive_mutex> guard(mutex);
        if (mode == "dirty_recovery_exception" && sender() &&
            ((!dirty && !sender()->property("saveFilePath").toString().compare(target, Qt::CaseInsensitive)) ||
             (dirty && exceptionDocument == sender()))) {
            exceptionDocument = sender();
            record({{"event", "native_exception"}, {"stage", dirty ? "restored_dirty" : "saved_state"}, {"native_dirty", dirty}});
            throw std::runtime_error("Isolated exception after native dirty-state notification");
        }
        if (dirty || !sender() || sender()->property("saveFilePath").toString().compare(target, Qt::CaseInsensitive)) return;
        if (mode == "post_exception") {
            record({{"event", "native_exception"}, {"stage", "saved_state"}, {"native_dirty", dirty}});
            throw std::runtime_error("Isolated exception after native saved-state notification");
        }
        if (mode != "post_validate") return;
        const HANDLE file = CreateFileW(reinterpret_cast<LPCWSTR>(target.utf16()), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return;
        LARGE_INTEGER before{}, after{};
        DWORD written = 0;
        const char invalidSignature[4] = {};
        const bool corrupted = GetFileSizeEx(file, &before) && WriteFile(file, invalidSignature, sizeof(invalidSignature), &written, nullptr) && written == sizeof(invalidSignature) && GetFileSizeEx(file, &after);
        CloseHandle(file);
        record({{"event", "output_corrupted"}, {"writer", writers}, {"corrupted", corrupted}, {"bytes_before", double(before.QuadPart)}, {"bytes_after", double(after.QuadPart)}, {"native_dirty", dirty}, {"native_clean_observed", true}});
    }
    void onOpenedPathChanged(const QString &path) {
        std::lock_guard<std::recursive_mutex> guard(mutex);
        if ((mode != "path_exception" && mode != "recovery_exception") || !sender()) return;
        const bool adopting = !path.compare(target, Qt::CaseInsensitive);
        if (!adopting && (mode != "recovery_exception" || exceptionDocument != sender())) return;
        if (adopting) exceptionDocument = sender();
        record({{"event", "native_exception"}, {"stage", adopting ? "opened_path" : "restored_path"}, {"native_dirty", sender()->property("isDirty").toBool()}, {"opened_path", path}});
        throw std::runtime_error("Isolated exception after native opened-path notification");
    }
public:
    FaultProbe(const QString &path, const QString &name) : directory(path), target(path + "/" + name),
        backupTarget(QDir::fromNativeSeparators(qEnvironmentVariable("APPDATA")) + "/Arobas Music/guitarpro8/backups/" + name) {
        if (QFile::exists(backupTarget)) return;
        HMODULE self = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, reinterpret_cast<LPCWSTR>(&write), &self)) return;
        const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
        if (snapshot == INVALID_HANDLE_VALUE) return;
        active = this;
        MODULEENTRY32W module{}; module.dwSize = sizeof(module);
        if (Module32FirstW(snapshot, &module)) do {
            if (module.hModule != self && _wcsicmp(module.szModule, L"kernel32.dll") && _wcsicmp(module.szModule, L"kernelbase.dll")) install(module.hModule);
        } while (Module32NextW(snapshot, &module));
        CloseHandle(snapshot);
        connect(&poll, &QTimer::timeout, this, [this] { refresh(); });
        connect(qApp, &QCoreApplication::aboutToQuit, this, [this] { stop(); });
        poll.start(50); record({{"event", "ready"}, {"target", target}, {"backup_target", backupTarget}, {"imports", imports.size()}});
    }
    ~FaultProbe() override { stop(); }
};

class SaveFaultPlugin : public QGenericPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QGenericPluginFactoryInterface_iid FILE "save-fault-probe.json")
public:
    QObject *create(const QString &name, const QString &) override {
        if (name != "guitarpro_save_fault_probe" || !guitarpro::supportedBuild() || !guitarpro::verifiedHostFile("Qt5Core.dll")) return nullptr;
        const QString path = QDir::cleanPath(QDir::fromNativeSeparators(qEnvironmentVariable("GPMCP_SAVE_FAULT_DIRECTORY")));
        if (!QDir::isAbsolutePath(path)) return nullptr;
        QFile marker(path + "/isolated-save-fault-test");
        if (!marker.open(QIODevice::ReadOnly) || marker.readAll().trimmed() != "gpmcp-save-fault-test") return nullptr;
        QFile targetName(path + "/target-name");
        if (!targetName.open(QIODevice::ReadOnly)) return nullptr;
        const QString nameValue = QString::fromUtf8(targetName.readAll()).trimmed();
        if (!QRegularExpression("^gpmcp-save-recovery-[0-9a-f]{32}\\.gp$").match(nameValue).hasMatch()) return nullptr;
        return new FaultProbe(path, nameValue);
    }
};
#include "save-fault-probe.moc"
