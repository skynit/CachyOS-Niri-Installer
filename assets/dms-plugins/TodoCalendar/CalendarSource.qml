import QtQuick
import Quickshell.Io
import "Calendar.js" as Calendar

Item {
    id: root
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("todo-calendar-helper").toString().replace(/^file:\/\//, ""))
    property string month: Calendar.monthKey(new Date())
    property var notes: []
    property bool busy: false
    property bool loaded: false
    property bool stale: false
    property string capabilityState: "degraded"
    property string reason: "loading"
    property string message: "正在读取本地记录"
    property double readAt: 0
    property var pending: ({})
    property bool received: false
    signal completed(string action, var result, var request)

    function request(action, data) {
        if (busy) return false;
        pending = Object.assign({}, data || {}, {action: action, month: month});
        busy = true;
        received = false;
        worker.stdinEnabled = true;
        worker.running = true;
        deadline.restart();
        return true;
    }
    function finish(result) {
        if (received) return;
        received = true;
        deadline.stop();
        const sent = pending;
        busy = false;
        capabilityState = result.state;
        reason = result.reason;
        message = result.message;
        if (result.ok && result.data && Array.isArray(result.data.notes)) {
            notes = result.data.notes;
            loaded = true;
            stale = false;
            readAt = result.data.read_at_ms;
            if (sent.action === "save") message = "记录已保存";
            else if (sent.action === "delete") message = "记录已删除";
            else if (sent.action === "import") message = "导入 " + result.data.imported + " 条，跳过 " + result.data.skipped + " 条相同记录";
        } else stale = loaded;
        completed(sent.action || "snapshot", result, sent);
    }
    function refresh() { return request("snapshot", {}); }
    Timer {
        id: deadline
        interval: 12000
        onTriggered: {
            root.finish({ok: false, state: "unreachable", reason: "helper_timeout", message: "读取或保存超时。结果尚未确认，请刷新核对；草稿仍保留。"});
            worker.signal(9);
        }
    }
    Process {
        id: worker
        command: [root.helper]
        stdinEnabled: true
        onStarted: { write(JSON.stringify(root.pending)); stdinEnabled = false; }
        stdout: StdioCollector { id: output }
        stderr: StdioCollector {}
        onExited: (code, status) => {
            if (root.received) return;
            try {
                const result = JSON.parse(output.text);
                if (code !== 0 || status !== 0 || typeof result.ok !== "boolean" || !["healthy", "degraded", "unsupported", "unreachable"].includes(result.state) || typeof result.reason !== "string" || typeof result.message !== "string") throw new Error("invalid_response");
                root.finish(result);
            } catch (error) {
                root.finish({ok: false, state: "unreachable", reason: "helper_unavailable", message: "无法启动或读取日历存储程序，请检查插件安装后重试。草稿仍保留。"});
            }
        }
        onRunningChanged: {
            if (!running && root.busy) Qt.callLater(() => {
                if (root.busy && !worker.running && !root.received) root.finish({ok: false, state: "unreachable", reason: "helper_unavailable", message: "日历存储程序未能运行，草稿仍保留。"});
            });
        }
    }
}
