import QtQuick
import Quickshell.Io

Item {
    id: root
    readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("phone-connect").toString().replace(/^file:\/\//, ""))
    property bool busy: false
    property bool failed: false
    property string message: ""
    property string logPath: ""
    signal passwordLoaded(var profile, string password)

    function connect(profile, password) {
        request("rdp", profile, password, "");
    }
    function loadPassword(profile) {
        request("rdp-password", profile, "", "load");
    }
    function savePassword(profile, password) {
        request("rdp-password", profile, password, "save");
    }
    function forgetPassword(profile) {
        request("rdp-password", profile, "", "clear");
    }
    function request(action, profile, password, operation) {
        if (busy)
            return;
        busy = true;
        failed = false;
        message = action === "rdp" ? "正在启动远程桌面…" : "正在访问系统密钥环…";
        logPath = "";
        worker.action = action;
        worker.profile = Object.assign({}, profile);
        worker.operation = operation;
        worker.input = JSON.stringify(Object.assign({}, profile, {password: password, operation: operation, savePassword: true}));
        worker.stdinEnabled = true;
        worker.running = true;
    }

    Process {
        id: worker
        property string action: "rdp"
        property var profile: ({})
        property string operation: ""
        property string input: ""
        command: [root.helperPath, action]
        stdinEnabled: true
        onStarted: {
            write(input);
            input = "";
            stdinEnabled = false;
        }
        onRunningChanged: {
            if (!running && input.length > 0) {
                input = "";
                root.failed = true;
                root.message = "无法启动连接辅助程序，请检查插件是否完整安装。";
                root.busy = false;
            }
        }
        stdout: StdioCollector { id: output }
        onExited: (code, status) => {
            input = "";
            try {
                const response = JSON.parse(output.text);
                root.failed = code !== 0 || response.ok !== true || !!response.passwordWarning;
                root.message = response.message || "";
                if (response.passwordWarning)
                    root.message += "\n" + response.passwordWarning;
                else if (response.passwordSaved)
                    root.message += "\n密码已自动保存到系统密钥环。";
                root.logPath = response.logPath || "";
                if (action === "rdp-password" && operation === "load" && response.ok)
                    root.passwordLoaded(profile, response.found ? response.password : "");
            } catch (error) {
                root.failed = true;
                root.message = "无法读取连接辅助程序的响应，请检查插件是否完整安装。";
            }
            root.busy = false;
        }
    }
}
