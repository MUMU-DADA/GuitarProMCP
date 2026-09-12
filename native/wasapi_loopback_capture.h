#pragma once

// Windows process audio capture used by P14.  The capture object owns the
// COM/WASAPI worker and never calls Qt, performs object discovery, allocates,
// or touches the MCP server from the worker loop.  PCM is copied into the
// fixed SPSC ring supplied by the control plane.

#include <windows.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <ksmedia.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propidl.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace guitarpro {

// WASAPI's QPC timestamp is expressed in 100 ns units (REFERENCE_TIME),
// unlike QueryPerformanceCounter ticks.  Keep the conversion explicit so the
// metric remains monotonic and does not depend on the machine's QPC frequency.
inline uint64_t wasapiTimestampNs(uint64_t referenceTime100ns) noexcept {
    return referenceTime100ns <= UINT64_MAX / 100 ? referenceTime100ns * 100 : 0;
}

enum class AudioCaptureState : uint32_t {
    NotReady = 0,
    Ready = 1,
    Running = 2,
    Degraded = 3,
    Stopped = 4,
    Error = 5,
};

enum class AudioCaptureMode : uint32_t {
    Automatic = 0,
    ProcessLoopback = 1,
    RenderLoopback = 2,
};

struct AudioCaptureFormat {
    uint32_t sampleRate = 0;
    uint16_t channels = 0;
    uint16_t bytesPerSample = 0;
    bool floatingPoint = false;
    std::string sampleFormat = "unknown";
    std::string scope = "";
    std::string endpoint = "";
};

struct AudioCaptureStats {
    uint64_t frameCount = 0;
    uint64_t sampleCount = 0;
    uint64_t hostDroppedFrames = 0;
    uint64_t callbackCount = 0;
    uint64_t callbackTotalNs = 0;
    uint64_t callbackMaxNs = 0;
    uint64_t underrun = 0;
    uint64_t overrun = 0;
    uint64_t xrun = 0;
    uint64_t timestampJumps = 0;
    uint64_t discontinuities = 0;
    uint64_t timestampErrors = 0;
    uint64_t clipped = 0;
    uint64_t nonFinite = 0;
    double sampleSum = 0.0;
    double squareSum = 0.0;
    double peak = 0.0;
    uint64_t firstTimestampNs = 0;
    uint64_t lastTimestampNs = 0;
    uint32_t bufferFrames = 0;
    AudioCaptureState state = AudioCaptureState::NotReady;
    std::string reason;
    AudioCaptureFormat format;
};

class AudioStreamActivationHandler final : public IActivateAudioInterfaceCompletionHandler, public IAgileObject {
public:
    explicit AudioStreamActivationHandler(HANDLE completed) : completed_(completed) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IActivateAudioInterfaceCompletionHandler)) {
            *object = static_cast<IActivateAudioInterfaceCompletionHandler *>(this);
            AddRef();
            return S_OK;
        }
        if (iid == __uuidof(IAgileObject)) {
            *object = static_cast<IAgileObject *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG result = static_cast<ULONG>(InterlockedDecrement(&refs_));
        if (!result) delete this;
        return result;
    }

    HRESULT STDMETHODCALLTYPE ActivateCompleted(IActivateAudioInterfaceAsyncOperation *operation) override {
        IUnknown *activated = nullptr;
        HRESULT activation = E_FAIL;
        if (operation) {
            const HRESULT call = operation->GetActivateResult(&activation, &activated);
            if (FAILED(call)) activation = call;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            result_ = activation;
            activated_ = activated;
        }
        SetEvent(completed_);
        return S_OK;
    }

    HRESULT result() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return result_;
    }

    IUnknown *take() {
        std::lock_guard<std::mutex> lock(mutex_);
        IUnknown *result = activated_;
        activated_ = nullptr;
        return result;
    }

private:
    ~AudioStreamActivationHandler() {
        if (activated_) activated_->Release();
        if (completed_) CloseHandle(completed_);
    }

    LONG refs_ = 1;
    HANDLE completed_ = nullptr;
    mutable std::mutex mutex_;
    HRESULT result_ = E_FAIL;
    IUnknown *activated_ = nullptr;
};

class WasapiLoopbackCapture final {
public:
    explicit WasapiLoopbackCapture(std::shared_ptr<class AudioStreamRing> ring,
                                    uint64_t generation,
                                    AudioCaptureMode mode = AudioCaptureMode::Automatic)
        : ring_(std::move(ring)), generation_(generation), mode_(mode) {
        stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        readyEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        dataEvent_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    }

    ~WasapiLoopbackCapture() {
        stop();
        if (dataEvent_) CloseHandle(dataEvent_);
        if (readyEvent_) CloseHandle(readyEvent_);
        if (stopEvent_) CloseHandle(stopEvent_);
    }

    WasapiLoopbackCapture(const WasapiLoopbackCapture &) = delete;
    WasapiLoopbackCapture &operator=(const WasapiLoopbackCapture &) = delete;

    bool start(std::string *error = nullptr) {
        if (!stopEvent_ || !readyEvent_ || !dataEvent_) {
            setReason("audio_capture_event_allocation_failed");
            if (error) *error = reason();
            return false;
        }
        if (worker_.joinable()) {
            if (error) *error = "audio_capture_already_started";
            return false;
        }
        ResetEvent(stopEvent_);
        ResetEvent(readyEvent_);
        state_.store(AudioCaptureState::NotReady, std::memory_order_release);
        worker_ = std::thread([this] { run(); });
        const DWORD wait = WaitForSingleObject(readyEvent_, 5000);
        if (wait != WAIT_OBJECT_0 || state_.load(std::memory_order_acquire) != AudioCaptureState::Running) {
            if (wait != WAIT_OBJECT_0) setReason("audio_capture_start_timeout");
            if (error) *error = reason();
            stop();
            return false;
        }
        return true;
    }

    void stop() noexcept {
        if (!worker_.joinable()) {
            state_.store(AudioCaptureState::Stopped, std::memory_order_release);
            return;
        }
        SetEvent(stopEvent_);
        SetEvent(dataEvent_);
        worker_.join();
        state_.store(AudioCaptureState::Stopped, std::memory_order_release);
    }

    AudioCaptureState state() const noexcept { return state_.load(std::memory_order_acquire); }
    uint64_t generation() const noexcept { return generation_; }

    AudioCaptureStats stats() const {
        AudioCaptureStats result;
        result.frameCount = frameCount_.load(std::memory_order_relaxed);
        result.sampleCount = sampleCount_.load(std::memory_order_relaxed);
        result.hostDroppedFrames = hostDroppedFrames_.load(std::memory_order_relaxed);
        result.callbackCount = callbackCount_.load(std::memory_order_relaxed);
        result.callbackTotalNs = callbackTotalNs_.load(std::memory_order_relaxed);
        result.callbackMaxNs = callbackMaxNs_.load(std::memory_order_relaxed);
        result.underrun = underrun_.load(std::memory_order_relaxed);
        result.overrun = overrun_.load(std::memory_order_relaxed);
        result.xrun = xrun_.load(std::memory_order_relaxed);
        result.timestampJumps = timestampJumps_.load(std::memory_order_relaxed);
        result.discontinuities = discontinuities_.load(std::memory_order_relaxed);
        result.timestampErrors = timestampErrors_.load(std::memory_order_relaxed);
        result.clipped = clipped_.load(std::memory_order_relaxed);
        result.nonFinite = nonFinite_.load(std::memory_order_relaxed);
        result.sampleSum = sampleSum_.load(std::memory_order_relaxed);
        result.squareSum = squareSum_.load(std::memory_order_relaxed);
        result.peak = peak_.load(std::memory_order_relaxed);
        result.firstTimestampNs = firstTimestampNs_.load(std::memory_order_relaxed);
        result.lastTimestampNs = lastTimestampNs_.load(std::memory_order_relaxed);
        result.bufferFrames = bufferFrames_.load(std::memory_order_relaxed);
        result.state = state();
        {
            std::lock_guard<std::mutex> lock(infoMutex_);
            result.reason = reason_;
            result.format = format_;
        }
        return result;
    }

    std::string reason() const {
        std::lock_guard<std::mutex> lock(infoMutex_);
        return reason_;
    }

private:
    template <typename T> static void release(T *&object) noexcept {
        if (object) object->Release();
        object = nullptr;
    }

    static uint64_t nowNs() noexcept {
        const auto now = std::chrono::steady_clock::now().time_since_epoch();
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(now).count());
    }

    static std::string narrow(const wchar_t *value) {
        if (!value) return {};
        const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
        if (size <= 1) return {};
        std::string result(static_cast<size_t>(size), '\0');
        WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr, nullptr);
        if (!result.empty() && result.back() == '\0') result.pop_back();
        return result;
    }

    void setReason(const char *reason) {
        std::lock_guard<std::mutex> lock(infoMutex_);
        reason_ = reason ? reason : "audio_capture_error";
    }

    static std::string hresultReason(const char *prefix, HRESULT hr) {
        char buffer[32]{};
        sprintf_s(buffer, "0x%08lX", static_cast<unsigned long>(hr));
        return std::string(prefix) + "_" + buffer;
    }

    HRESULT activateProcessLoopback(IAudioClient **client) {
        if (!client) return E_POINTER;
        *client = nullptr;
        HANDLE completed = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!completed) return HRESULT_FROM_WIN32(GetLastError());
        auto *handler = new AudioStreamActivationHandler(completed);
        AUDIOCLIENT_ACTIVATION_PARAMS parameters{};
        parameters.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
        parameters.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
        parameters.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
        PROPVARIANT activation{};
        PropVariantInit(&activation);
        activation.vt = VT_BLOB;
        activation.blob.cbSize = sizeof(parameters);
        activation.blob.pBlobData = static_cast<BYTE *>(CoTaskMemAlloc(sizeof(parameters)));
        if (!activation.blob.pBlobData) {
            handler->Release();
            return E_OUTOFMEMORY;
        }
        std::memcpy(activation.blob.pBlobData, &parameters, sizeof(parameters));
        IActivateAudioInterfaceAsyncOperation *operation = nullptr;
        HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
                                                   __uuidof(IAudioClient), &activation,
                                                   handler, &operation);
        if (SUCCEEDED(hr)) {
            const DWORD wait = WaitForSingleObject(completed, 5000);
            if (wait != WAIT_OBJECT_0) hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
            else hr = handler->result();
        }
        if (SUCCEEDED(hr)) {
            IUnknown *unknown = handler->take();
            if (!unknown) hr = E_NOINTERFACE;
            else {
                hr = unknown->QueryInterface(__uuidof(IAudioClient), reinterpret_cast<void **>(client));
                unknown->Release();
            }
        }
        PropVariantClear(&activation);
        release(operation);
        handler->Release();
        return hr;
    }

    HRESULT activateRenderLoopback(IAudioClient **client, std::string *endpoint) {
        if (!client) return E_POINTER;
        *client = nullptr;
        IMMDeviceEnumerator *enumerator = nullptr;
        IMMDevice *device = nullptr;
        HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                      __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator));
        if (SUCCEEDED(hr)) hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
        if (SUCCEEDED(hr)) hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                                  reinterpret_cast<void **>(client));
        if (SUCCEEDED(hr) && endpoint) {
            LPWSTR id = nullptr;
            if (SUCCEEDED(device->GetId(&id)) && id) {
                *endpoint = "render:" + narrow(id);
                CoTaskMemFree(id);
            }
            IPropertyStore *store = nullptr;
            if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &store)) && store) {
                PROPVARIANT value;
                PropVariantInit(&value);
                if (SUCCEEDED(store->GetValue(PKEY_Device_FriendlyName, &value)) && value.vt == VT_LPWSTR && value.pwszVal)
                    *endpoint = std::string("render:") + narrow(value.pwszVal);
                PropVariantClear(&value);
                store->Release();
            }
        }
        release(device);
        release(enumerator);
        return hr;
    }

    HRESULT setup() {
        IAudioClient *client = nullptr;
        std::string endpoint;
        HRESULT hr = mode_ == AudioCaptureMode::RenderLoopback ? E_NOTIMPL : activateProcessLoopback(&client);
        std::string scope = "process_loopback";
        std::string fallbackReason;
        if (FAILED(hr)) {
            if (mode_ == AudioCaptureMode::ProcessLoopback) {
                setReason(hresultReason("process_loopback_activation_failed", hr).c_str());
                return hr;
            }
            if (mode_ != AudioCaptureMode::RenderLoopback)
                fallbackReason = hresultReason("process_loopback_activation_failed", hr);
            hr = activateRenderLoopback(&client, &endpoint);
            scope = "render_endpoint_loopback";
        }
        if (FAILED(hr) || !client) {
            setReason(hresultReason("audio_client_activation_failed", hr).c_str());
            return FAILED(hr) ? hr : E_NOINTERFACE;
        }
        WAVEFORMATEX processFormat{};
        processFormat.wFormatTag = WAVE_FORMAT_PCM;
        processFormat.nChannels = 2;
        processFormat.nSamplesPerSec = 44100;
        processFormat.wBitsPerSample = 16;
        processFormat.nBlockAlign = processFormat.nChannels * processFormat.wBitsPerSample / 8;
        processFormat.nAvgBytesPerSec = processFormat.nSamplesPerSec * processFormat.nBlockAlign;
        WAVEFORMATEX *format = scope == "process_loopback" ? &processFormat : nullptr;
        if (!format) hr = client->GetMixFormat(&format);
        if (FAILED(hr) || !format) {
            release(client);
            setReason(hresultReason("audio_mix_format_failed", hr).c_str());
            return hr;
        }
        const WAVEFORMATEXTENSIBLE *extended = nullptr;
        if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX))
            extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(format);
        const GUID subFormat = extended ? extended->SubFormat : GUID{};
        const bool floating = extended ? IsEqualGUID(subFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)
                                       : format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
        const uint16_t bits = extended ? extended->Samples.wValidBitsPerSample : format->wBitsPerSample;
        const uint32_t sampleRate = format->nSamplesPerSec;
        const uint16_t channels = format->nChannels;
        const uint16_t blockAlign = format->nBlockAlign;
        const uint16_t bytesPerSample = channels ? static_cast<uint16_t>(blockAlign / channels) : 0;
        if (!channels || channels > 8 || !sampleRate || !bits || bits > 32 || !bytesPerSample || bytesPerSample > 4) {
            if (format != &processFormat) CoTaskMemFree(format);
            release(client);
            setReason("audio_mix_format_unsupported");
            return E_INVALIDARG;
        }
        const DWORD flags = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2000000, 0, format, nullptr);
        if (SUCCEEDED(hr)) hr = client->SetEventHandle(dataEvent_);
        IAudioCaptureClient *capture = nullptr;
        if (SUCCEEDED(hr)) hr = client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void **>(&capture));
        UINT32 bufferFrames = 0;
        if (SUCCEEDED(hr)) hr = client->GetBufferSize(&bufferFrames);
        IAudioClock *clock = nullptr;
        if (SUCCEEDED(hr)) client->GetService(__uuidof(IAudioClock), reinterpret_cast<void **>(&clock));
        if (format != &processFormat) CoTaskMemFree(format);
        if (FAILED(hr) || !capture) {
            release(clock);
            release(capture);
            release(client);
            setReason(hresultReason("audio_client_initialize_failed", hr).c_str());
            return hr;
        }
        {
            std::lock_guard<std::mutex> lock(infoMutex_);
            format_.sampleRate = formatSampleRate_ = sampleRate;
            format_.channels = formatChannels_ = channels;
            format_.bytesPerSample = formatBytes_ = bytesPerSample;
            format_.floatingPoint = formatFloating_ = floating;
            format_.sampleFormat = floating ? "f32" : (bits == 16 ? "s16" : bits == 24 ? "s24" : "s32");
            format_.scope = scope;
            format_.endpoint = endpoint.empty() ? (scope == "process_loopback" ? "GuitarPro.exe" : "default") : endpoint;
            reason_ = fallbackReason.empty() ? "running" : "running_" + fallbackReason;
        }
        bufferFrames_.store(bufferFrames, std::memory_order_release);
        formatBlockAlign_ = blockAlign;
        client_ = client;
        capture_ = capture;
        clock_ = clock;
        return S_OK;
    }

    float sample(const BYTE *data, uint32_t frame, uint16_t channel) const noexcept {
        const uint32_t channels = formatChannels_;
        const size_t index = static_cast<size_t>(frame) * formatBlockAlign_ + static_cast<size_t>(channel) * formatBytes_;
        if (!data || !formatBytes_) return 0.0f;
        const BYTE *value = data + index;
        if (formatFloating_ && formatBytes_ >= 4) {
            float output = 0.0f;
            std::memcpy(&output, value, sizeof(output));
            return output;
        }
        if (formatBytes_ == 1) return (static_cast<float>(*value) - 128.0f) / 128.0f;
        if (formatBytes_ == 2) {
            int16_t output = 0;
            std::memcpy(&output, value, sizeof(output));
            return static_cast<float>(output) / 32768.0f;
        }
        if (formatBytes_ == 3) {
            const int32_t output = (static_cast<int32_t>(value[0]) |
                                    (static_cast<int32_t>(value[1]) << 8) |
                                    (static_cast<int32_t>(value[2]) << 16));
            const int32_t signedValue = (output & 0x00800000) ? (output | ~0x00FFFFFF) : output;
            return static_cast<float>(signedValue) / 8388608.0f;
        }
        int32_t output = 0;
        std::memcpy(&output, value, sizeof(output));
        return static_cast<float>(output) / 2147483648.0f;
    }

    void updateMetrics(const float *samples, uint32_t frames, uint16_t channels,
                       uint64_t timestamp) noexcept {
        if (!frames || !channels) return;
        const uint64_t count = static_cast<uint64_t>(frames) * channels;
        sampleCount_.fetch_add(count, std::memory_order_relaxed);
        if (!firstTimestampNs_.load(std::memory_order_relaxed))
            firstTimestampNs_.store(timestamp, std::memory_order_relaxed);
        lastTimestampNs_.store(timestamp, std::memory_order_relaxed);
        double blockSum = 0.0;
        double blockSquare = 0.0;
        double blockPeak = 0.0;
        uint64_t blockClipped = 0;
        uint64_t blockNonFinite = 0;
        for (uint64_t i = 0; i < count; ++i) {
            const float value = samples[i];
            if (!std::isfinite(value)) {
                ++blockNonFinite;
                continue;
            }
            const double absolute = std::abs(static_cast<double>(value));
            blockSum += static_cast<double>(value);
            blockSquare += absolute * absolute;
            blockPeak = (std::max)(blockPeak, absolute);
            if (absolute >= 1.0) ++blockClipped;
        }
        nonFinite_.fetch_add(blockNonFinite, std::memory_order_relaxed);
        clipped_.fetch_add(blockClipped, std::memory_order_relaxed);
        // The capture thread is the sole writer.  Atomic stores keep the
        // control-thread snapshot race-free without integer scaling overflow.
        addAtomic(sampleSum_, blockSum);
        addAtomic(squareSum_, blockSquare);
        double currentPeak = peak_.load(std::memory_order_relaxed);
        while (blockPeak > currentPeak && !peak_.compare_exchange_weak(currentPeak, blockPeak,
                                                                        std::memory_order_relaxed,
                                                                        std::memory_order_relaxed)) {}
    }

    void processPacket(const BYTE *data, uint32_t frames, DWORD flags,
                       uint64_t devicePosition, uint64_t qpcPosition) noexcept {
        if (!frames || !ring_) return;
        const uint16_t channels = static_cast<uint16_t>((std::min<uint32_t>)(formatChannels_, 8));
        const uint64_t startFrame = frameCount_.load(std::memory_order_relaxed);
        if (haveDevicePosition_ && devicePosition && devicePosition > expectedDevicePosition_)
            hostDroppedFrames_.fetch_add(devicePosition - expectedDevicePosition_, std::memory_order_relaxed);
        if (haveDevicePosition_ && (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY)) {
            discontinuities_.fetch_add(1, std::memory_order_relaxed);
            xrun_.fetch_add(1, std::memory_order_relaxed);
        }
        if (devicePosition) {
            expectedDevicePosition_ = devicePosition + frames;
            haveDevicePosition_ = true;
        }
        uint64_t timestamp = wasapiTimestampNs(qpcPosition);
        if (!timestamp) timestamp = nowNs();
        if (flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) timestampErrors_.fetch_add(1, std::memory_order_relaxed);
        const uint64_t previous = lastPacketTimestampNs_.exchange(timestamp, std::memory_order_relaxed);
        if (previous && timestamp <= previous) timestampJumps_.fetch_add(1, std::memory_order_relaxed);
        uint32_t offset = 0;
        while (offset < frames) {
            AudioStreamPcmBlock block{};
            block.frame_start = startFrame + offset;
            block.timestamp_ns = timestamp + (formatSampleRate_ ? static_cast<uint64_t>((static_cast<long double>(offset) * 1000000000.0L) / formatSampleRate_) : 0);
            block.generation = generation_;
            block.frames = (std::min<uint32_t>)(frames - offset, AudioStreamPcmBlock::MaxFrames);
            block.sample_rate = formatSampleRate_;
            block.channels = channels;
            for (uint32_t frame = 0; frame < block.frames; ++frame) {
                for (uint16_t channel = 0; channel < channels; ++channel) {
                    const float value = (flags & AUDCLNT_BUFFERFLAGS_SILENT) ? 0.0f : sample(data, offset + frame, channel);
                    block.samples[static_cast<size_t>(frame) * channels + channel] = value;
                }
            }
            updateMetrics(block.samples, block.frames, block.channels, block.timestamp_ns);
            if (!ring_->push(block)) {
                // AudioStreamRing owns the monitor drop counter.  The host
                // frame counter remains authoritative even when the reader
                // is slower than the endpoint.
            }
            offset += block.frames;
        }
        frameCount_.fetch_add(frames, std::memory_order_relaxed);
    }

    bool drain() noexcept {
        if (!capture_) return false;
        bool healthy = true;
        const auto begin = std::chrono::steady_clock::now();
        UINT32 packetFrames = 0;
        HRESULT hr = capture_->GetNextPacketSize(&packetFrames);
        while (SUCCEEDED(hr) && packetFrames) {
            BYTE *data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            UINT64 devicePosition = 0, qpcPosition = 0;
            hr = capture_->GetBuffer(&data, &frames, &flags, &devicePosition, &qpcPosition);
            if (FAILED(hr)) {
                xrun_.fetch_add(1, std::memory_order_relaxed);
                healthy = false;
                setReason(hresultReason("audio_capture_get_buffer_failed", hr).c_str());
                break;
            }
            processPacket(data, frames, flags, devicePosition, qpcPosition);
            const HRESULT releaseResult = capture_->ReleaseBuffer(frames);
            if (FAILED(releaseResult)) {
                xrun_.fetch_add(1, std::memory_order_relaxed);
                healthy = false;
                setReason(hresultReason("audio_capture_release_failed", releaseResult).c_str());
                break;
            }
            hr = capture_->GetNextPacketSize(&packetFrames);
        }
        if (FAILED(hr) && hr != AUDCLNT_S_BUFFER_EMPTY) {
            overrun_.fetch_add(1, std::memory_order_relaxed);
            healthy = false;
            setReason(hresultReason("audio_capture_packet_query_failed", hr).c_str());
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - begin).count();
        callbackCount_.fetch_add(1, std::memory_order_relaxed);
        callbackTotalNs_.fetch_add(static_cast<uint64_t>(elapsed), std::memory_order_relaxed);
        uint64_t current = callbackMaxNs_.load(std::memory_order_relaxed);
        while (static_cast<uint64_t>(elapsed) > current && !callbackMaxNs_.compare_exchange_weak(current, static_cast<uint64_t>(elapsed), std::memory_order_relaxed)) {}
        return healthy;
    }

    void run() noexcept {
        const HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(init) && init != RPC_E_CHANGED_MODE) {
            setReason(hresultReason("audio_com_initialization_failed", init).c_str());
            state_.store(AudioCaptureState::Error, std::memory_order_release);
            SetEvent(readyEvent_);
            return;
        }
        HRESULT hr = setup();
        if (SUCCEEDED(hr)) hr = client_->Start();
        if (FAILED(hr)) {
            if (reason() == "running") setReason(hresultReason("audio_capture_start_failed", hr).c_str());
            state_.store(AudioCaptureState::Error, std::memory_order_release);
            SetEvent(readyEvent_);
            release(clock_);
            release(capture_);
            release(client_);
            if (SUCCEEDED(init)) CoUninitialize();
            return;
        }
        state_.store(AudioCaptureState::Running, std::memory_order_release);
        SetEvent(readyEvent_);
        bool faulted = false;
        while (WaitForSingleObject(stopEvent_, 0) != WAIT_OBJECT_0) {
            const HANDLE events[] = {stopEvent_, dataEvent_};
            const DWORD wait = WaitForMultipleObjects(2, events, FALSE, 100);
            if (wait == WAIT_OBJECT_0) break;
            if (wait == WAIT_FAILED) {
                setReason(hresultReason("audio_capture_wait_failed", HRESULT_FROM_WIN32(GetLastError())).c_str());
                faulted = true;
                break;
            }
            if (!drain()) {
                faulted = true;
                break;
            }
        }
        if (client_) client_->Stop();
        release(clock_);
        release(capture_);
        release(client_);
        state_.store(faulted ? AudioCaptureState::Error : AudioCaptureState::Stopped, std::memory_order_release);
        if (SUCCEEDED(init)) CoUninitialize();
    }

    std::shared_ptr<class AudioStreamRing> ring_;
    const uint64_t generation_ = 0;
    const AudioCaptureMode mode_ = AudioCaptureMode::Automatic;
    HANDLE stopEvent_ = nullptr;
    HANDLE readyEvent_ = nullptr;
    HANDLE dataEvent_ = nullptr;
    std::thread worker_;
    IAudioClient *client_ = nullptr;
    IAudioCaptureClient *capture_ = nullptr;
    IAudioClock *clock_ = nullptr;
    std::atomic<AudioCaptureState> state_{AudioCaptureState::NotReady};
    mutable std::mutex infoMutex_;
    std::string reason_ = "not_ready";
    AudioCaptureFormat format_;
    uint32_t formatSampleRate_ = 0;
    uint16_t formatChannels_ = 0;
    uint16_t formatBytes_ = 0;
    uint16_t formatBlockAlign_ = 0;
    bool formatFloating_ = false;
    std::atomic<uint32_t> bufferFrames_{0};
    std::atomic<uint64_t> frameCount_{0};
    std::atomic<uint64_t> sampleCount_{0};
    std::atomic<uint64_t> hostDroppedFrames_{0};
    std::atomic<uint64_t> callbackCount_{0};
    std::atomic<uint64_t> callbackTotalNs_{0};
    std::atomic<uint64_t> callbackMaxNs_{0};
    std::atomic<uint64_t> underrun_{0};
    std::atomic<uint64_t> overrun_{0};
    std::atomic<uint64_t> xrun_{0};
    std::atomic<uint64_t> timestampJumps_{0};
    std::atomic<uint64_t> discontinuities_{0};
    std::atomic<uint64_t> timestampErrors_{0};
    std::atomic<uint64_t> clipped_{0};
    std::atomic<uint64_t> nonFinite_{0};
    std::atomic<double> sampleSum_{0.0};
    std::atomic<double> squareSum_{0.0};
    std::atomic<double> peak_{0.0};
    std::atomic<uint64_t> firstTimestampNs_{0};
    std::atomic<uint64_t> lastTimestampNs_{0};
    std::atomic<uint64_t> lastPacketTimestampNs_{0};
    uint64_t expectedDevicePosition_ = 0;
    bool haveDevicePosition_ = false;

    static void addAtomic(std::atomic<double> &target, double value) noexcept {
        double current = target.load(std::memory_order_relaxed);
        while (!target.compare_exchange_weak(current, current + value,
                                              std::memory_order_relaxed,
                                              std::memory_order_relaxed)) {}
    }
};

} // namespace guitarpro
