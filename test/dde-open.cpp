#include <windows.h>
#include <cstdio>
#include <cwchar>
#include <string>

static HDDEDATA CALLBACK callback(UINT, UINT, HCONV, HSZ, HSZ, HDDEDATA, ULONG_PTR, ULONG_PTR) { return nullptr; }

int wmain(int argc, wchar_t **argv) {
    if (argc != 3) { std::fprintf(stderr, "Usage: dde-open expected-pid absolute-score-path\n"); return 2; }
    wchar_t *end = nullptr;
    const DWORD expected = std::wcstoul(argv[1], &end, 10);
    const std::wstring path = argv[2];
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (!expected || !end || *end || path.find(L'"') != std::wstring::npos ||
        attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) return 2;
    DWORD instance = 0;
    const UINT error = DdeInitializeW(&instance, callback, APPCMD_CLIENTONLY, 0);
    if (error) { std::fprintf(stderr, "DdeInitialize: %u\n", error); return 3; }
    const HSZ service = DdeCreateStringHandleW(instance, L"Guitar Pro 8", CP_WINUNICODE);
    const HSZ topic = DdeCreateStringHandleW(instance, L"system", CP_WINUNICODE);
    HCONV connection = DdeConnect(instance, service, topic, nullptr);
    int result = 1;
    if (!connection) std::fprintf(stderr, "DdeConnect: %u\n", DdeGetLastError(instance));
    else {
        CONVINFO info{}; info.cb = sizeof(info);
        DWORD receiver = 0;
        if (DdeQueryConvInfo(connection, QID_SYNC, &info)) GetWindowThreadProcessId(info.hwndPartner, &receiver);
        std::printf("receiver_pid=%lu expected_pid=%lu code_page=%d\n", receiver, expected, info.ConvCtxt.iCodePage);
        // A global DDE service name must never redirect this test to a user host.
        if (receiver != expected) std::puts("DDE receiver identity does not match; no command sent.");
        else {
            const std::wstring command = L"[open(\"" + path + L"\")]";
            DWORD transaction = 0;
            const auto response = DdeClientTransaction(reinterpret_cast<LPBYTE>(const_cast<wchar_t *>(command.c_str())), DWORD((command.size() + 1) * sizeof(wchar_t)), connection, nullptr, 0, XTYP_EXECUTE, 10000, &transaction);
            std::printf("acknowledged=%d error=%u transaction=%lu\n", response != nullptr, DdeGetLastError(instance), transaction);
            if (response) result = 0;
        }
        DdeDisconnect(connection);
    }
    DdeFreeStringHandle(instance, topic); DdeFreeStringHandle(instance, service);
    DdeUninitialize(instance);
    return result;
}
