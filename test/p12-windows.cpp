#include "window_capture.h"
#include <QtWidgets/QDialog>
#include <QtWidgets/QLabel>
#include <QtWidgets/QOpenGLWidget>
#include <QtWidgets/QMenu>
#include <QtCore/QUuid>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <vector>

static int checks = 0;
static void check(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
    ++checks;
}
static QJsonObject row(const QJsonObject &list, const QString &name) {
    for (const auto &item : list.value("windows").toArray())
        if (item.toObject().value("object_name") == name) return item.toObject();
    return {};
}
static QJsonObject capture(WindowCapture &windows, const QJsonObject &record) {
    return windows.screenshot({{"window_id", record.value("window_id")}});
}
class DeferredPopup : public QWidget {
public:
    int resized = 0;
    explicit DeferredPopup(QWidget *parent) : QWidget(parent, Qt::Tool) {}
    void resizeEvent(QResizeEvent *event) override {
        ++resized; QWidget::resizeEvent(event);
        resize(83, 24);
    }
};
int main(int argc, char **argv) {
    QApplication app(argc, argv);
    app.setQuitOnLastWindowClosed(false);
    try {
        const auto instance = QUuid::createUuid().toString(QUuid::WithoutBraces);
        WindowCapture windows(instance);
        QWidget parent; parent.setObjectName("parent"); parent.resize(320, 240);
        QLabel embedded("embedded", &parent); embedded.setObjectName("embedded");
        QWidget tool(&parent, Qt::Tool); tool.setObjectName("tool"); tool.resize(220, 100);
        tool.setStyleSheet("background: rgb(21, 137, 63)");
        tool.ensurePolished();
        QWidget sub(&parent, Qt::SubWindow); sub.setObjectName("sub"); sub.resize(120, 80);
        QWindow native; native.setObjectName("native"); native.resize(100, 80);
        auto list = windows.enumerate();
        check(!row(list, "parent").isEmpty() && !row(list, "tool").isEmpty(), "missing hidden windows");
        check(row(list, "embedded").isEmpty(), "embedded widget counted as a window");
        check(row(list, "sub").value("kind") == "subwindow", "Qt::SubWindow omitted");
        check(row(list, "tool").value("parent_window_id") == row(list, "parent").value("window_id"), "tool parent mismatch");
        check(row(list, "sub").value("parent_window_id") == row(list, "parent").value("window_id"), "subwindow parent mismatch");
        check(!parent.windowHandle() && !tool.windowHandle(), "enumeration created a native handle");
        auto filtered = windows.enumerate(false);
        check(filtered.value("total_count") == list.value("total_count") && filtered.value("returned_count").toInt() == 0, "hidden filter changes totals");
        auto image = capture(windows, row(list, "tool"));
        check(image.value("status") == "experimental" && !tool.isVisible(), "hidden capture changed visibility or failed");
        const auto png = QByteArray::fromBase64(image.value("__mcp_image").toObject().value("data").toString().toLatin1());
        const auto pixels = QImage::fromData(png, "PNG");
        check(!pixels.isNull() && pixels.pixelColor(pixels.width()/2, pixels.height()/2) == QColor(21,137,63), "wrong target pixels");
        check(pixels.width() == qRound(tool.width()*tool.devicePixelRatioF()), "DPI dimensions mismatch");
        auto oldTool = row(list, "tool");
        tool.setWindowTitle("renamed"); tool.show(); app.processEvents();
        list = windows.enumerate();
        check(row(list, "tool").value("window_id") == oldTool.value("window_id"), "show/title changed ID");
        int toolRows = 0;
        for (const auto &item : list.value("windows").toArray()) if (item.toObject().value("window_id") == oldTool.value("window_id")) ++toolRows;
        check(toolRows == 1, "QWidget and QWindow double counted");
        tool.hide();
        check(row(windows.enumerate(), "tool").value("window_id") == oldTool.value("window_id"), "hide changed ID");
        QDialog modal(&parent); modal.setObjectName("modal"); modal.setWindowModality(Qt::ApplicationModal); modal.show(); app.processEvents();
        auto modalRow = row(windows.enumerate(), "modal");
        check(modalRow.value("active_modal").toBool(), "modal status missing");
        auto underModal = capture(windows, oldTool);
        check(underModal.value("window_id") == oldTool.value("window_id") && !underModal.value("active_modal").toBool() &&
              underModal.value("active_modal_window_id") == modalRow.value("window_id"), "modal replaced explicit target");
        QDialog upper(&modal); upper.setObjectName("upper"); upper.setWindowModality(Qt::ApplicationModal); upper.show(); app.processEvents();
        const auto upperRow = row(windows.enumerate(), "upper");
        const auto lowerCapture = capture(windows, modalRow);
        check(upperRow.value("parent_window_id") == modalRow.value("window_id") &&
              lowerCapture.value("window_id") == modalRow.value("window_id") && !lowerCapture.value("active_modal").toBool() &&
              lowerCapture.value("active_modal_window_id") == upperRow.value("window_id"), "nested modal replaced lower target");
        upper.hide();
        modal.hide();
        parent.show(); sub.show(); app.processEvents();
        const auto subCapture = capture(windows, row(windows.enumerate(), "sub"));
        check(subCapture.value("status") == "experimental" && subCapture.value("kind") == "subwindow", "explicit SubWindow capture failed");
        check(capture(windows, row(windows.enumerate(), "parent")).value("reason") == "embedded_subwindow", "parent silently composited an independent SubWindow");
        sub.hide(); parent.hide();
        const auto nativeResult = capture(windows, row(windows.enumerate(), "native"));
        check(nativeResult.value("reason") == "qwindow_render_unsupported" && !nativeResult.contains("__mcp_image"), "QWindow produced fake success");
        QOpenGLWidget unsupported; unsupported.setObjectName("special");
        check(capture(windows, row(windows.enumerate(), "special")).value("reason") == "special_rendering", "special rendering not rejected");
        QWidget oversized; oversized.setObjectName("large"); oversized.resize(5000, 20);
        check(capture(windows, row(windows.enumerate(), "large")).value("reason") == "dimensions_limit", "oversized target accepted");
        oversized.resize(0, 0);
        check(capture(windows, row(windows.enumerate(), "large")).value("reason") == "dimensions_limit", "empty target accepted");
        QMenu menu; menu.setObjectName("unprepared"); menu.addAction("A real menu entry");
        const auto menuSize = menu.size();
        const auto unprepared = capture(windows, row(windows.enumerate(), "unprepared"));
        check(unprepared.value("reason") == "unprepared_hidden_window" && !unprepared.contains("__mcp_image") && menu.size() == menuSize,
              "capture resized an unprepared hidden menu");
        QWidget eventParent; eventParent.setObjectName("eventParent"); eventParent.resize(320, 160);
        DeferredPopup deferredPopup(&eventParent); deferredPopup.resize(100, 30);
        eventParent.show(); app.processEvents();
        check(deferredPopup.resized == 0 && deferredPopup.testAttribute(Qt::WA_PendingResizeEvent), "deferred event fixture was already delivered");
        check(capture(windows, row(windows.enumerate(), "eventParent")).value("status") == "experimental", "parent capture failed");
        check(deferredPopup.resized == 0 && deferredPopup.size() == QSize(100,30) && deferredPopup.testAttribute(Qt::WA_PendingResizeEvent), "parent capture delivered or lost another window's resize event");
        deferredPopup.show(); app.processEvents();
        check(deferredPopup.resized > 0 && deferredPopup.size() == QSize(83,24), "preserved resize event was lost on show");
        // Reuse the exact allocation, proving QPointer lifetime protection rather
        // than relying on a different address after destruction.
        alignas(QWidget) unsigned char storage[sizeof(QWidget)];
        auto first = new (storage) QWidget; first->setObjectName("reuse");
        auto old = row(windows.enumerate(), "reuse");
        first->~QWidget();
        auto replacement = new (storage) QWidget; replacement->setObjectName("reuse");
        auto fresh = row(windows.enumerate(), "reuse");
        check(old.value("window_id") != fresh.value("window_id"), "address reuse reused ID");
        auto expired = capture(windows, old);
        check(expired.value("reason") == "window_not_found" && !expired.contains("__mcp_image"), "destroyed ID fell back");
        replacement->~QWidget();
        for (const auto &value : QJsonArray{"", "garbage", instance+":window:0", instance+":window:18446744073709551616", oldTool.value("window_id").toString()+"\n"})
            check(windows.screenshot({{"window_id", value}}).value("reason") == "invalid_window_id", "malformed ID accepted");
        check(windows.screenshot({{"window_id", instance+":window:999999"}}).value("reason") == "window_not_found", "unknown ID accepted");
        WindowCapture restarted(QUuid::createUuid().toString(QUuid::WithoutBraces));
        check(capture(restarted, oldTool).value("reason") == "foreign_instance", "cross-instance ID accepted");
        std::vector<std::unique_ptr<QWidget>> many;
        for (int i=0; i<520; ++i) many.push_back(std::make_unique<QWidget>());
        auto truncated = windows.enumerate();
        check(truncated.value("truncated").toBool() && truncated.value("total_count").toInt() == 512 &&
              truncated.value("count_scope") == "observed_subset", "enumeration limit misreported completeness");
        many.clear();
        check(!windows.enumerate().value("truncated").toBool(), "destroyed entries did not recover");
        std::printf("PASS: %d Qt window fixture checks; device pixel ratio %.2f\n", checks, tool.devicePixelRatioF());
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL after %d checks: %s\n", checks, error.what()); return 1;
    }
}
