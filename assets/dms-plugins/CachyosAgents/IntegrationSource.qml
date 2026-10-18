import QtQuick
import Quickshell.Io

Item {
    id: root
    readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("ai-settings").toString().replace(/^file:\/\//, ""))
    property var state: ({})
    property bool loaded: false
    property string readError: ""
    property string operationError: ""
    readonly property string error: readError || operationError
    property string message: ""
    readonly property bool busy: reader.running || writer.running
    property string operation: ""
    signal operationSucceeded(string action)

    function refresh() {
        if (!root.busy)
            reader.running = true;
    }

    function execute(args) {
        if (root.busy)
            return;
        root.operationError = "";
        root.message = "";
        root.operation = args[0] === "cachyos-ai-settings" ? args[1] : args[0];
        writer.command = args[0] === "cachyos-ai-settings" ? [root.helperPath].concat(args.slice(1)) : args;
        writer.running = true;
    }

    function setValue(key, value) {
        execute(["cachyos-ai-settings", "set", key, String(value)]);
    }

    Component.onCompleted: refresh()

    Process {
        id: reader
        command: [root.helperPath, "state"]
        stdout: StdioCollector { id: stateOutput }
        stderr: StdioCollector { id: stateError }
        onExited: (code, status) => {
            if (code !== 0) {
                root.readError = stateError.text.trim() || "无法读取 AI 设置";
                return;
            }
            try {
                root.state = JSON.parse(stateOutput.text);
                root.loaded = true;
                root.readError = "";
            } catch (error) {
                root.readError = "AI 设置返回了无效数据";
            }
        }
    }

    Process {
        id: writer
        stderr: StdioCollector { id: writeError }
        onExited: (code, status) => {
            if (code !== 0) {
                root.operationError = writeError.text.trim() || "操作失败（退出码 " + code + "）";
            } else {
                root.message = "已完成";
                root.operationSucceeded(root.operation);
            }
            root.refresh();
        }
    }
}
