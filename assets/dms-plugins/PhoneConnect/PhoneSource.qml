import QtQuick
import Quickshell.Io

Item {
    id: root
    readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("phone-connect").toString().replace(/^file:\/\//, ""))
    property bool busy: false
    property string message: ""
    property bool failed: false
    property bool connected: false
    property bool statusKnown: false
    property var saved: null
    property var pairing: []
    property var connections: []
    property bool pushing: false
    property int pushPercent: -1
    property string pushName: ""
    property string pushTarget: ""
    property int pushCount: 0
    property int pushIndex: 0
    property var pushNames: []
    property bool pushFailed: false
    property bool pushFinal: false
    property string phonePath: ""
    property var phoneEntries: []
    property bool phoneLimited: false
    property bool listing: false
    property string listError: ""
    property bool pulling: false
    property int pullPercent: -1
    property string pullName: ""
    property bool pullFailed: false
    property bool pullFinal: false
    signal result(string action, var data)
    signal pushFinished(bool ok, string message)
    signal pullFinished(bool ok, string message)

    function request(action, data) {
        if (busy)
            return;
        busy = true;
        failed = false;
        message = "正在" + ({state: "读取设备", scan: "扫描", pair: "配对并连接", connect: "连接", reconnect: "重新连接", forget: "移除设备"}[action] || "处理") + "…";
        const worker = task.createObject(root, {action: action, input: JSON.stringify(data || {})});
        worker.running = true;
    }

    function refreshStatus() {
        if (!statusReader.running)
            statusReader.running = true;
    }

    function push(paths) {
        if (busy || pushing)
            return;
        const list = paths || [];
        if (list.length === 0) {
            failed = true;
            message = "请选择要推送的文件";
            return;
        }
        busy = true;
        pushing = true;
        pushFailed = false;
        pushFinal = false;
        pushPercent = -1;
        pushName = "";
        pushTarget = "";
        pushCount = list.length;
        pushIndex = 1;
        pushNames = list;
        message = list.length > 1 ? ("正在推送 " + list.length + " 个文件…") : "正在准备推送…";
        pushProcess.stdinEnabled = true;
        pushProcess.input = JSON.stringify({paths: list});
        console.log("phoneConnect: push start files=" + list.length);
        pushProcess.running = true;
    }

    function cancelPush() {
        if (pushing && pushProcess.running)
            pushProcess.signal(15);
    }

    function finishPush(ok, text) {
        pushFinal = true;
        pushing = false;
        busy = false;
        pushFailed = !ok;
        if (ok)
            pushPercent = 100;
        message = text;
        console.log("phoneConnect: push finished ok=" + ok + " " + text);
        pushFinished(ok, text);
    }

    function handlePushLine(line) {
        let event;
        try {
            event = JSON.parse(line);
        } catch (error) {
            return;
        }
        if (event.final === true) {
            finishPush(event.ok === true, event.message || (event.ok === true ? "推送完成" : "推送失败"));
            return;
        }
        if (event.event === "done") {
            finishPush(true, event.message || "推送完成");
            return;
        }
        if (event.event === "start") {
            pushNames = event.names || pushNames;
            pushCount = event.count || pushNames.length;
            pushIndex = pushCount > 0 ? 1 : 0;
            pushName = pushNames.length > 0 ? pushNames[0] : "";
            pushTarget = event.target || "";
            message = pushCount > 1 ? ("正在推送 " + pushCount + " 个文件…") : ("正在推送 " + pushName + "…");
            return;
        }
        if (event.event === "progress" && typeof event.percent === "number") {
            pushPercent = Math.max(0, Math.min(100, event.percent));
            if (event.name)
                pushName = event.name;
            if (typeof event.index === "number")
                pushIndex = event.index;
            if (typeof event.count === "number")
                pushCount = event.count;
        }
    }

    function browse(path) {
        if (listing || pulling)
            return;
        listing = true;
        listError = "";
        message = "正在读取手机目录…";
        listProcess.stdinEnabled = true;
        listProcess.input = JSON.stringify({path: path});
        listProcess.running = true;
    }

    function pull(path) {
        if (pulling || pushing || busy)
            return;
        const target = (path || "").trim();
        if (target.length === 0) {
            failed = true;
            message = "请选择要下载的文件";
            return;
        }
        pulling = true;
        pullFailed = false;
        pullFinal = false;
        pullPercent = -1;
        pullName = target.split("/").pop();
        message = "正在下载 " + pullName + "…";
        pullProcess.stdinEnabled = true;
        pullProcess.input = JSON.stringify({path: target});
        pullProcess.running = true;
    }

    function cancelPull() {
        if (pulling && pullProcess.running)
            pullProcess.signal(15);
    }

    function finishPull(ok, text) {
        pullFinal = true;
        pulling = false;
        pullFailed = !ok;
        if (ok)
            pullPercent = 100;
        message = text;
        console.log("phoneConnect: pull finished ok=" + ok + " " + text);
        pullFinished(ok, text);
    }

    function handlePullLine(line) {
        let event;
        try {
            event = JSON.parse(line);
        } catch (error) {
            return;
        }
        if (event.final === true) {
            finishPull(event.ok === true, event.message || (event.ok === true ? "下载完成" : "下载失败"));
            return;
        }
        if (event.event === "done") {
            finishPull(true, event.message || "下载完成");
            return;
        }
        if (event.event === "start") {
            if (event.names && event.names.length > 0)
                pullName = event.names[0];
            message = "正在下载 " + pullName + "…";
            return;
        }
        if (event.event === "progress" && typeof event.percent === "number") {
            pullPercent = Math.max(0, Math.min(100, event.percent));
            if (event.name)
                pullName = event.name;
        }
    }

    Component.onCompleted: {
        request("state", {});
        refreshStatus();
    }

    Timer {
        interval: 10000
        running: true
        repeat: true
        onTriggered: root.refreshStatus()
    }

    Process {
        id: statusReader
        command: [root.helperPath, "status"]
        stdout: StdioCollector { id: statusOutput }
        onExited: (code, status) => {
            try {
                const response = JSON.parse(statusOutput.text);
                root.statusKnown = code === 0 && response.ok;
                root.connected = root.statusKnown && response.connected === true;
            } catch (error) {
                root.statusKnown = false;
                root.connected = false;
            }
        }
    }

    Process {
        id: pushProcess
        property string input: ""
        command: [root.helperPath, "push"]
        stdinEnabled: true
        onStarted: {
            write(input);
            stdinEnabled = false;
        }
        stdout: SplitParser {
            onRead: line => root.handlePushLine(line)
        }
        onExited: (code, status) => {
            if (!root.pushFinal) {
                root.pushPercent = -1;
                root.finishPush(false, code === 0 ? "推送结束，但没有收到结果" : "推送失败（连接程序退出码 " + code + "）");
            }
            Qt.callLater(() => root.refreshStatus());
        }
    }

    Process {
        id: listProcess
        property string input: ""
        command: [root.helperPath, "list"]
        stdinEnabled: true
        onStarted: {
            write(input);
            stdinEnabled = false;
        }
        stdout: StdioCollector { id: listOutput }
        stderr: StdioCollector { id: listErrors }
        onExited: (code, status) => {
            root.listing = false;
            try {
                const response = JSON.parse(listOutput.text);
                if (code === 0 && response.ok === true) {
                    root.phonePath = response.path || root.phonePath;
                    root.phoneEntries = response.entries || [];
                    root.phoneLimited = response.limited === true;
                    root.listError = "";
                    root.message = root.phonePath + "（" + root.phoneEntries.length + " 项）";
                } else {
                    root.listError = response.message || "读取手机目录失败";
                    root.message = root.listError;
                }
            } catch (error) {
                root.listError = listErrors.text.trim() || "读取手机目录失败";
                root.message = root.listError;
            }
        }
    }

    Process {
        id: pullProcess
        property string input: ""
        command: [root.helperPath, "pull"]
        stdinEnabled: true
        onStarted: {
            write(input);
            stdinEnabled = false;
        }
        stdout: SplitParser {
            onRead: line => root.handlePullLine(line)
        }
        onExited: (code, status) => {
            if (!root.pullFinal) {
                root.pullPercent = -1;
                root.finishPull(false, code === 0 ? "下载结束，但没有收到结果" : "下载失败（连接程序退出码 " + code + "）");
            }
            Qt.callLater(() => root.refreshStatus());
        }
    }

    Component {
        id: task
        Process {
            id: process
            required property string action
            required property string input
            property bool finished: false
            command: [root.helperPath, action]
            stdinEnabled: true
            stdout: StdioCollector { id: output }
            stderr: StdioCollector { id: errors }

            onStarted: {
                write(input);
                stdinEnabled = false;
            }
            onExited: (code, status) => {
                if (finished)
                    return;
                finished = true;
                root.busy = false;
                try {
                    const response = JSON.parse(output.text);
                    root.failed = !response.ok;
                    root.message = response.message || (root.failed ? "操作失败" : "");
                    if (response.saved !== undefined)
                        root.saved = response.saved;
                    if (response.pairing !== undefined)
                        root.pairing = response.pairing;
                    if (response.connections !== undefined)
                        root.connections = response.connections;
                    if (response.ok || response.paired || response.connected)
                        root.result(action, response);
                } catch (error) {
                    root.failed = true;
                    root.message = errors.text.trim() || "手机连接服务未返回有效结果";
                }
                Qt.callLater(() => {
                    root.refreshStatus();
                    process.destroy();
                });
            }
            onRunningChanged: {
                if (!running && !finished)
                    Qt.callLater(() => {
                        if (!finished) {
                            finished = true;
                            root.busy = false;
                            root.failed = true;
                            root.message = "无法启动手机连接程序，请重新构建并安装插件";
                            process.destroy();
                        }
                    });
            }
        }
    }
}
