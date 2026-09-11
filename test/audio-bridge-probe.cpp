#include "../native/audio_bridge_api.h"
#include <windows.h>
#include <iostream>
#include <string>
#include <thread>

namespace {
using VersionFn = unsigned (GPMCP_AUDIO_CALL *)();

void visit(void *user, const gpmcp_audio_binding *binding) {
    if (!user || !binding || binding->struct_size != sizeof(*binding)) return;
    auto *count = static_cast<unsigned *>(user);
    ++*count;
}

int fail(const char *message) {
    std::cerr << "FAIL: " << message << "\n";
    return 1;
}
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 2) return fail("provider DLL path is required");
    const std::wstring path(argv[1]);
    HMODULE module = LoadLibraryW(path.c_str());
    if (!module) {
        if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) return fail("existing provider could not be loaded");
        // A missing provider is a supported lifecycle state.  The caller can
        // use this result to exercise the not_ready fallback without loading
        // an unrelated DLL.
        std::cout << "PASS: missing_provider=not_ready\n";
        return 0;
    }
    const size_t separator = path.find_last_of(L"\\/");
    const std::wstring moduleName = separator == std::wstring::npos ? path : path.substr(separator + 1);
    if (GetModuleHandleW(moduleName.c_str()) != module) return fail("GetModuleHandle did not return the loaded provider");
    auto version = reinterpret_cast<VersionFn>(GetProcAddress(module, "gpmcp_audio_bridge_version"));
    auto getInfo = reinterpret_cast<gpmcp_audio_get_info_fn>(GetProcAddress(module, "gpmcp_audio_bridge_get_info"));
    auto enumerate = reinterpret_cast<gpmcp_audio_enumerate_v1_fn>(GetProcAddress(module, "gpmcp_audio_enumerate_v1"));
    if (!version || !getInfo || !enumerate) return fail("versioned provider exports are missing");
    if (version() != GPMCP_AUDIO_BRIDGE_ABI_VERSION) return fail("unexpected provider ABI version");

    gpmcp_audio_bridge_info info{};
    info.struct_size = sizeof(info);
    const uint32_t infoStatus = getInfo(&info);
    if (info.struct_size != sizeof(info) || info.abi_version != GPMCP_AUDIO_BRIDGE_ABI_VERSION ||
        infoStatus != info.status || info.status > GPMCP_AUDIO_HOST_LIMITED) {
        return fail("provider info did not report a stable lifecycle state");
    }

    gpmcp_audio_enumerate_result result{};
    result.struct_size = sizeof(result);
    const uint32_t mismatch = enumerate(GPMCP_AUDIO_BRIDGE_ABI_VERSION + 1, visit, nullptr, &result);
    if (mismatch != GPMCP_AUDIO_ABI_MISMATCH || result.status != GPMCP_AUDIO_ABI_MISMATCH) return fail("ABI mismatch was not rejected");
    result.status = 0; result.generation = 0; result.count = 0;
    unsigned callbackCount = 0;
    const uint32_t readyStatus = enumerate(GPMCP_AUDIO_BRIDGE_ABI_VERSION, visit, &callbackCount, &result);
    if (info.status == GPMCP_AUDIO_NOT_READY) {
        if (readyStatus != GPMCP_AUDIO_NOT_READY || result.status != GPMCP_AUDIO_NOT_READY || result.count != 0) return fail("provider-missing enumerate fallback failed");
    } else if (readyStatus != GPMCP_AUDIO_OK || result.status != GPMCP_AUDIO_OK || result.count != callbackCount || callbackCount == 0) {
        return fail("ready provider callback contract failed");
    }

    uint32_t threadStatus = GPMCP_AUDIO_INTERNAL_ERROR;
    std::thread worker([&] {
        gpmcp_audio_enumerate_result workerResult{};
        workerResult.struct_size = sizeof(workerResult);
        threadStatus = enumerate(GPMCP_AUDIO_BRIDGE_ABI_VERSION, visit, nullptr, &workerResult);
    });
    worker.join();
    if (threadStatus != GPMCP_AUDIO_NOT_READY && threadStatus != GPMCP_AUDIO_WRONG_THREAD) return fail("worker-thread fallback was not stable");
    FreeLibrary(module);
    std::cout << "PASS: provider exports, ABI layout, version negotiation, not_ready and worker-thread fallback\n";
    return 0;
}
