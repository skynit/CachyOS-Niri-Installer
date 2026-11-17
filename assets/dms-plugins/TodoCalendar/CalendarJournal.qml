import QtQuick
import Quickshell.Io

Item {
    id: root
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("todo-calendar-helper").toString().replace(/^file:\/\//, ""))
    property string date: ""
    property var entries: ({})
    property var messages: ({})
    property var statuses: ({})
    property var loaded: ({})
    property var pending: ({})
    property bool busy: false
    property bool received: false
    property bool cancelling: false
    readonly property var entry: entries[date] || null
    readonly property string statusText: messages[date] || "尚未采集当天会话"
    readonly property string stateText: statuses[date] || "degraded / not_collected"
    readonly property string taskDate: pending.local_date || ""

    function setStatus(day, message, state) {
        messages = Object.assign({}, messages, {[day]: message});
        statuses = Object.assign({}, statuses, {[day]: state});
    }
    function request(action) {
        if (busy || worker.running || !date) return false;
        pending = {action: action, local_date: date};
        busy = true; received = false; cancelling = false;
        setStatus(date, action === "journal_summarize" ? "正在生成总结，最长约 8 分钟" : action === "journal_collect" ? "正在采集当天会话" : "正在读取 AI 缓存", "degraded / loading");
        worker.stdinEnabled = true;
        worker.running = true;
        deadline.interval = action === "journal_summarize" ? 495000 : 35000;
        deadline.restart();
        return true;
    }
    function load() { if (date && !loaded[date] && !busy) request("journal_cache"); }
    onDateChanged: Qt.callLater(load)
    function cancel() {
        if (!busy || cancelling) return;
        cancelling = true;
        setStatus(taskDate, "正在取消 AI 任务", "degraded / cancelling");
        worker.signal(15);
    }
    function finish(result) {
        if (received) return;
        received = true; deadline.stop();
        const day = taskDate;
        const valid = result.data && result.data.journal;
        if (valid && (result.ok || valid.summary)) {
            if (!valid.collection || valid.collection.local_date !== day) {
                setStatus(day, "返回的日期不匹配，已保留原结果", "degraded / journal_date_mismatch");
                return;
            }
            entries = Object.assign({}, entries, {[day]: valid});
        } else if (result.ok && pending.action === "journal_cache") entries = Object.assign({}, entries, {[day]: null});
        loaded = Object.assign({}, loaded, {[day]: true});
        setStatus(day, result.ok && !valid ? "尚未采集当天会话" : result.message + (!result.ok && entries[day] ? "；保留上次结果" : ""), result.ok && !valid ? "degraded / not_collected" : result.state + " / " + result.reason);
    }
    Timer {
        id: deadline
        onTriggered: {
            root.finish({ok: false, state: "unreachable", reason: "journal_timeout", message: "AI 任务超时，已有结果与日志草稿仍保留。"});
            root.cancelling = true;
            worker.signal(15);
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
            if (!root.received) {
                try {
                    const result = JSON.parse(output.text);
                    if (code !== 0 || typeof result.ok !== "boolean" || !["healthy", "degraded", "unsupported", "unreachable"].includes(result.state) || typeof result.message !== "string" || typeof result.reason !== "string") throw new Error("invalid_response");
                    root.finish(result);
                } catch (error) {
                    root.finish({ok: false, state: "unreachable", reason: "journal_unavailable", message: "AI 辅助程序不可用，请检查插件安装后重试。"});
                }
            }
            root.busy = false;
            root.cancelling = false;
            if (root.date !== root.taskDate) Qt.callLater(root.load);
        }
        onRunningChanged: if (!running && root.busy) Qt.callLater(() => {
            if (!worker.running && root.busy) {
                if (!root.received) root.finish({ok: false, state: "unreachable", reason: "journal_unavailable", message: "AI 辅助程序未能启动，请检查插件安装。"});
                root.busy = false;
            }
        })
    }
}
