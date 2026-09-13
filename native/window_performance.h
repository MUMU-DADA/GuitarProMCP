#pragma once

#include "window_capture.h"
#include <QtCore/QDateTime>
#include <QtCore/QElapsedTimer>
#include <QtCore/QHash>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonObject>
#include <QtCore/QPointer>
#include <QtCore/QTimer>
#include <QtCore/QUuid>
#include <QtWidgets/QWidget>
#include <algorithm>
#include <cmath>
#include <cstring>

#ifdef Q_OS_WIN
#include <dwmapi.h>
#endif

// Read-only, GUI-thread window performance observer. It deliberately keeps
// the implementation small: Qt paint events and screen reference data are
// sampled in-process; no screenshot, activation, input or external monitor
// process is used. Windows per-window presentation timing is kept unknown
// until a source with verifiable PID/HWND attribution is available.
class WindowPerformance final : public QObject {
    struct Session {
        QString id;
        QString windowId;
        QPointer<QObject> target;
        QString source;
        QString measurementSource;
        QElapsedTimer elapsed;
        QDateTime startedAt;
        int sampleMs = 1000;
        qint64 finishedDurationMs = 0;
        bool completed = false;
        bool dwmAvailable = false;
        bool hasDwmBaseline = false;
        quint64 baseDisplayed = 0;
        quint64 baseDropped = 0;
        quint64 baseMissed = 0;
        quint64 dwmDisplayed = 0;
        quint64 dwmDropped = 0;
        quint64 dwmMissed = 0;
        quint64 lastDisplayed = 0;
        qint64 lastFrameQpc = 0;
        QVector<qint64> frameIntervalsUs;
        quint64 frameIntervalGaps = 0;
        QVector<qint64> paintTimesMs;
        quint64 paintOverflow = 0;
    };

    WindowCapture &windows;
    QTimer timer{this};
    QHash<QString, Session> sessions;
    const QString instance;
    static constexpr int MaxSessions = 4;
    static constexpr int MaxSamples = 32768;

#ifdef Q_OS_WIN
    static bool readDwm(HWND hwnd, DWM_TIMING_INFO *info) {
        if (!hwnd || !IsWindow(hwnd) || !info) return false;
        std::memset(info, 0, sizeof(*info));
        info->cbSize = sizeof(*info);
        return SUCCEEDED(DwmGetCompositionTimingInfo(hwnd, info));
    }
    static HWND hwndFor(QObject *object) {
        if (auto widget = qobject_cast<QWidget *>(object))
            return reinterpret_cast<HWND>(widget->internalWinId());
        return nullptr;
    }
#else
    static bool readDwm(void *, void *) { return false; }
    static void *hwndFor(QObject *) { return nullptr; }
#endif

    static bool isPaintFor(QObject *watched, QObject *target) {
        if (!watched || !target) return false;
        auto child = qobject_cast<QWidget *>(watched);
        auto root = qobject_cast<QWidget *>(target);
        if (!child || !root || (child != root && !root->isAncestorOf(child))) return false;
        // A top-level or Qt::SubWindow child has an independent window
        // lifecycle and must be sampled by its own window_id.
        if (child != root && child->window() != root->window()) return false;
        if (child != root && child->windowType() == Qt::SubWindow) return false;
        return true;
    }

    static QJsonValue nullable(quint64 value, bool available) {
        return available ? QJsonValue(double(value)) : QJsonValue();
    }

    static double percentile(QVector<qint64> values, double fraction) {
        if (values.isEmpty()) return 0.0;
        std::sort(values.begin(), values.end());
        const int index = qBound(0, int(std::ceil(fraction * values.size())) - 1, values.size() - 1);
        return double(values[index]) / 1000.0;
    }

    static QJsonObject intervals(const Session &session, double expectedMs) {
        if (session.frameIntervalsUs.isEmpty())
            return QJsonObject{{"observed", false}, {"complete", session.frameIntervalGaps == 0},
                               {"skipped_samples", double(session.frameIntervalGaps)}};
        qint64 total = 0, maximum = 0;
        int jank = 0;
        for (const qint64 value : session.frameIntervalsUs) {
            total += value; maximum = (std::max)(maximum, value);
            if (expectedMs > 0.0 && double(value) / 1000.0 > expectedMs * 1.5) ++jank;
        }
        return QJsonObject{{"observed", true},
                {"count", session.frameIntervalsUs.size()},
                {"average_ms", double(total) / 1000.0 / session.frameIntervalsUs.size()},
                {"p50_ms", percentile(session.frameIntervalsUs, .50)},
                {"p95_ms", percentile(session.frameIntervalsUs, .95)},
                {"p99_ms", percentile(session.frameIntervalsUs, .99)},
                {"max_ms", double(maximum) / 1000.0},
                {"expected_interval_ms", expectedMs},
                {"jank_threshold_ms", expectedMs > 0.0 ? QJsonValue(expectedMs * 1.5) : QJsonValue()},
                {"jank_frames", jank}, {"complete", session.frameIntervalGaps == 0},
                {"skipped_samples", double(session.frameIntervalGaps)}};
    }

    void updateDwm(Session &session) {
#ifdef Q_OS_WIN
        if (session.measurementSource != "dwm_timing" || !session.target) return;
        DWM_TIMING_INFO info{};
        if (!readDwm(hwndFor(session.target), &info)) { session.dwmAvailable = false; return; }
        session.dwmAvailable = true;
        if (!session.hasDwmBaseline) {
            session.hasDwmBaseline = true;
            session.baseDisplayed = info.cFramesDisplayed;
            session.baseDropped = info.cFramesDropped;
            session.baseMissed = info.cFramesMissed;
            session.dwmDisplayed = session.dwmDropped = session.dwmMissed = 0;
            session.lastDisplayed = info.cFramesDisplayed;
            session.lastFrameQpc = static_cast<qint64>(info.qpcFrameDisplayed);
            return;
        }
        session.dwmDisplayed = info.cFramesDisplayed >= session.baseDisplayed ? info.cFramesDisplayed - session.baseDisplayed : 0;
        session.dwmDropped = info.cFramesDropped >= session.baseDropped ? info.cFramesDropped - session.baseDropped : 0;
        session.dwmMissed = info.cFramesMissed >= session.baseMissed ? info.cFramesMissed - session.baseMissed : 0;
        const qint64 currentFrameQpc = static_cast<qint64>(info.qpcFrameDisplayed);
        if (info.cFramesDisplayed > session.lastDisplayed && currentFrameQpc > session.lastFrameQpc && session.lastFrameQpc > 0) {
            const quint64 deltaFrames = info.cFramesDisplayed - session.lastDisplayed;
            static LARGE_INTEGER frequency = [] { LARGE_INTEGER value{}; QueryPerformanceFrequency(&value); return value; }();
            if (frequency.QuadPart > 0) {
                const qint64 delta = currentFrameQpc - session.lastFrameQpc;
                if (deltaFrames == 1 && delta > 0 && session.frameIntervalsUs.size() < MaxSamples)
                    session.frameIntervalsUs.append(delta * 1000000 / frequency.QuadPart);
                else if (deltaFrames > 1)
                    ++session.frameIntervalGaps;
            }
            session.lastDisplayed = info.cFramesDisplayed;
            session.lastFrameQpc = currentFrameQpc;
        }
#else
        Q_UNUSED(session);
#endif
    }

    QJsonObject result(Session &session, const QString &statusOverride = {}) {
        if (!session.completed) updateDwm(session);
        const qint64 duration = (std::max<qint64>)(1, session.completed && session.finishedDurationMs > 0 ? session.finishedDurationMs : session.elapsed.isValid() ? session.elapsed.elapsed() : 0);
        const auto state = windows.describe(session.target);
        const bool visible = state.value("visible").toBool(false);
        const bool minimized = state.value("minimized").toBool(false);
        const double refresh = state.value("screen_refresh_rate_hz").toDouble(0.0);
        const double expected = refresh > 0.0 ? 1000.0 / refresh : 0.0;
        const bool dwm = session.measurementSource == "dwm_timing" && session.dwmAvailable && session.hasDwmBaseline;
        const bool paint = session.measurementSource == "qt_paint" || session.measurementSource == "dwm_timing";
        const QString observation = session.measurementSource == "dwm_timing" ? (dwm ? "observed" : "host_limited") :
            session.measurementSource == "qt_paint" ? "qt_only" : "not_observed";
        const QString status = !statusOverride.isEmpty() ? statusOverride :
            (!session.target ? "stale" : session.completed ? "completed" : "running");
        QJsonObject out{{"instance_id", instance}, {"monitor_id", session.id}, {"window_id", session.windowId},
                        {"pid", double(QCoreApplication::applicationPid())}, {"status", status},
                        {"measurement_source", session.measurementSource}, {"requested_source", session.source},
                        {"observation_status", observation},
                        {"sample_started_at", session.startedAt.toUTC().toString(Qt::ISODateWithMs)},
                        {"sample_duration_ms", duration}, {"visible", visible}, {"minimized", minimized},
                        {"fullscreen", state.value("fullscreen")}, {"native_hwnd_available", hwndFor(session.target) != nullptr},
                        {"occluded", QJsonValue()}, {"occlusion_status", "not_observed"},
                        {"refresh_rate_hz", refresh > 0.0 ? QJsonValue(refresh) : QJsonValue()},
                        {"screen_name", state.value("screen_name")}, {"screen_selection", "window_screen"},
                        {"paint_count", paint ? QJsonValue(double(session.paintTimesMs.size())) : QJsonValue()},
                        {"presented_frames", QJsonValue()},
                        {"displayed_frames", nullable(session.dwmDisplayed, dwm)},
                        {"dropped_frames", nullable(session.dwmDropped, dwm)},
                        {"missed_frames", nullable(session.dwmMissed, dwm)},
                        {"paint_fps", paint ? QJsonValue(double(session.paintTimesMs.size()) * 1000.0 / duration) : QJsonValue()},
                        {"presented_fps", QJsonValue()},
                        {"displayed_fps", dwm ? QJsonValue(double(session.dwmDisplayed) * 1000.0 / duration) : QJsonValue()},
                        {"frame_intervals", dwm ? intervals(session, expected) : QJsonValue()},
                        {"paint_overflow", double(session.paintOverflow)},
                        {"reasons", QJsonArray{}}};
        QJsonArray reasons;
        if (!session.target) reasons.append("window_destroyed");
        else if (!visible || minimized) reasons.append("window_not_visible");
        if (!dwm && session.measurementSource == "dwm_timing") reasons.append("dwm_timing_unavailable");
        if (session.source == "auto" && session.measurementSource != "dwm_timing") reasons.append("dwm_timing_unavailable_fallback");
        if (!state.value("native_hwnd_available").toBool(true) && session.measurementSource == "dwm_timing") reasons.append("native_hwnd_unavailable");
        if (!reasons.isEmpty()) out["reasons"] = reasons;
        if (status == "running" && session.measurementSource == "screen_refresh") out["status"] = "not_observed";
        if (status != "stale" && (!visible || minimized)) out["status"] = "not_observed";
        if (session.measurementSource == "dwm_timing") out["status"] = "host_limited";
        if (session.measurementSource == "screen_refresh" && status != "stale") out["status"] = "not_observed";
        if (session.source == "auto" && session.measurementSource != "dwm_timing" && status != "stale") out["status"] = "host_limited";
        return out;
    }

    QString sourceName(const QString &source, QObject *target, bool *available) {
        if (available) *available = true;
        const auto state = windows.describe(target);
        const bool hasWidget = qobject_cast<QWidget *>(target) != nullptr;
#ifdef Q_OS_WIN
        DWM_TIMING_INFO timing{};
        const bool hasDwm = readDwm(hwndFor(target), &timing);
#else
        const bool hasDwm = false;
#endif
        if (source == "etw") { if (available) *available = false; return "windows_graphics_etw"; }
        if (source == "dwm") { if (!hasDwm && available) *available = false; return "dwm_timing"; }
        if (source == "qt_paint") { if (!hasWidget && available) *available = false; return "qt_paint"; }
        if (source == "screen") { if (state.value("screen_name").toString().isEmpty() && available) *available = false; return "screen_refresh"; }
        if (hasDwm) return "dwm_timing";
        if (hasWidget) return "qt_paint";
        if (state.value("screen_name").toString().isEmpty() && available) *available = false;
        return "screen_refresh";
    }

    QJsonObject start(const QJsonObject &args) {
        if (sessions.size() >= MaxSessions) return {{"status", "error"}, {"reason", "session_limit"}, {"error", "At most four window performance monitors may run"}};
        const QString requested = args.value("source").toString("auto");
        if (!QStringList{"auto", "etw", "dwm", "qt_paint", "screen"}.contains(requested)) return {{"status", "error"}, {"reason", "invalid_source"}, {"error", "source must be auto, etw, dwm, qt_paint or screen"}};
        QString status, reason;
        QObject *target = windows.resolve(args, &status, &reason);
        if (!target) return {{"status", status.isEmpty() ? "error" : status}, {"reason", reason}, {"error", "The requested window is unavailable"}};
        bool available = true;
        const QString measurement = sourceName(requested, target, &available);
        if (!available) return {{"status", requested == "etw" ? "host_limited" : "not_observed"}, {"reason", requested == "etw" ? "etw_not_available" : measurement == "dwm_timing" ? "dwm_timing_unavailable" : "source_unavailable"}, {"error", "The requested window performance source is unavailable"}, {"window_id", windows.describe(target).value("window_id")}};
        Session session;
        session.id = instance + ":monitor:" + QUuid::createUuid().toString(QUuid::WithoutBraces);
        session.windowId = windows.describe(target).value("window_id").toString();
        session.target = target; session.source = requested; session.measurementSource = measurement;
        if (args.contains("sample_ms") && (args.value("sample_ms").toInt() < 250 || args.value("sample_ms").toInt() > 10000))
            return {{"status", "error"}, {"reason", "invalid_sample_ms"}, {"error", "sample_ms must be between 250 and 10000"}};
        session.sampleMs = args.value("sample_ms").toInt(1000);
        session.startedAt = QDateTime::currentDateTimeUtc(); session.elapsed.start();
        if (measurement == "dwm_timing") updateDwm(session);
        sessions.insert(session.id, session);
        if (!timer.isActive()) timer.start();
        return result(sessions[session.id]);
    }

    QJsonObject access(const QJsonObject &args, bool stop) {
        const QString id = args.value("monitor_id").toString();
        if (id.isEmpty() || !sessions.contains(id)) {
            if (!id.isEmpty() && !id.startsWith(instance + ":monitor:"))
                return {{"status", "error"}, {"reason", "foreign_instance"}, {"error", "monitor_id belongs to another instance"}};
            return {{"status", "error"}, {"reason", "monitor_not_found"}, {"error", "monitor_id is unknown or expired"}};
        }
        Session &session = sessions[id];
        if (args.contains("window_id") && args.value("window_id").toString() != session.windowId)
            return {{"status", "error"}, {"reason", "window_mismatch"}, {"error", "monitor_id is bound to another window"}};
        QString resolveStatus, resolveReason;
        QObject *current = windows.resolve({{"window_id", session.windowId}}, &resolveStatus, &resolveReason);
        if (!current) { session.target.clear(); const auto stale = result(session, "stale"); sessions.remove(id); if (sessions.isEmpty()) timer.stop(); return stale; }
        session.target = current;
        if (stop && !session.completed) {
            updateDwm(session);
            session.completed = true;
            session.finishedDurationMs = (std::max<qint64>)(1, session.elapsed.elapsed());
        } else if (session.elapsed.elapsed() >= session.sampleMs && !session.completed) {
            session.completed = true;
            session.finishedDurationMs = session.elapsed.elapsed();
        }
        const auto out = result(session);
        if (stop) { sessions.remove(id); if (sessions.isEmpty()) timer.stop(); }
        return out;
    }

    void poll() {
        bool active = false;
        for (auto it = sessions.begin(); it != sessions.end(); ++it) {
            if (!it->completed) {
                updateDwm(it.value());
                if (it->elapsed.elapsed() >= it->sampleMs) {
                    it->completed = true;
                    it->finishedDurationMs = it->elapsed.elapsed();
                }
            }
            if (!it->completed) active = true;
        }
        if (!active) timer.stop();
    }

public:
    explicit WindowPerformance(WindowCapture &capture, const QString &instanceId, QObject *parent = nullptr)
        : QObject(parent), windows(capture), instance(instanceId) {
        timer.setInterval(16);
        connect(&timer, &QTimer::timeout, this, [this] { poll(); });
    }

    QJsonObject call(const QJsonObject &args) {
        const QString operation = args.value("operation").toString();
        if (operation == "start") return start(args);
        if (operation == "snapshot") return access(args, false);
        if (operation == "stop") return access(args, true);
        return {{"status", "error"}, {"reason", "invalid_operation"}, {"error", "operation must be start, snapshot or stop"}};
    }

    void observePaint(QObject *object, QEvent *event) {
        if (!object || !event || event->type() != QEvent::Paint) return;
        for (auto it = sessions.begin(); it != sessions.end(); ++it) {
            if (!it->completed && (it->measurementSource == "qt_paint" || it->measurementSource == "dwm_timing") && isPaintFor(object, it->target)) {
                if (it->paintTimesMs.size() < MaxSamples) it->paintTimesMs.append(it->elapsed.elapsed());
                else ++it->paintOverflow;
            }
        }
    }

    void clear() { sessions.clear(); timer.stop(); }
};
