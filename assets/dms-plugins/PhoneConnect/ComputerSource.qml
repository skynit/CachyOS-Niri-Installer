import QtQuick
import Quickshell.Io

Item {
    id: root
    readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("phone-connect").toString().replace(/^file:\/\//, ""))
    property bool busy: false
    property bool failed: false
    property string message: ""
    property string logPath: ""
    property var pending: []
    property var failedRequest: null
    property int sequence: 0
    property var settings: ({})
    property var saveSetting: null
    property var history: []
    property bool historyDirty: false
    property string historyError: ""
    readonly property bool connecting: (busy && worker.action === "rdp") || pending.some(task => task.action === "rdp")
    signal passwordLoaded(var profile, string password, int requestId)

    onSettingsChanged: {
        if (!historyDirty)
            history = Array.isArray(settings.rdpHistory) ? settings.rdpHistory : [];
    }

    function saveHistory(entries) {
        history = entries;
        historyDirty = true;
        const saved = saveSetting && saveSetting("rdpHistory", entries);
        historyDirty = !saved;
        historyError = saved ? "" : "无法保存历史连接，记录暂留在本次会话中，请重试。";
        return !!saved;
    }
    function retryHistory() {
        if (historyDirty)
            saveHistory(history);
    }
    function remember(profile) {
        // Only connection settings are persisted; never copy passwords or queue metadata.
        const entry = {
            host: profile.host.trim(), port: profile.port || "3389",
            user: profile.user.trim(), domain: (profile.domain || "").trim(),
            scale: profile.scale || "180", encoding: profile.encoding || "avc420",
            wallpaper: profile.wallpaper === true, windowDrag: profile.windowDrag === true,
            menuAnimations: profile.menuAnimations === true,
            dynamicResolution: profile.dynamicResolution !== false,
            ignoreCertificate: profile.ignoreCertificate === true, debug: profile.debug === true,
            startedAt: Date.now()
        };
        const key = targetKey(entry);
        saveHistory([entry].concat(history.filter(item => targetKey(item) !== key)).slice(0, 20));
    }
    function removeHistory(profile) {
        const key = targetKey(profile);
        saveHistory(history.filter(item => targetKey(item) !== key));
    }

    function targetKey(profile) {
        return JSON.stringify([profile.host.trim().toLowerCase(), Number(profile.port || "3389"), profile.user.trim(), (profile.domain || "").trim()]);
    }

    function connect(profile, password) {
        request("rdp", profile, password, "");
    }
    function loadPassword(profile) {
        return request("rdp-password", profile, "", "load");
    }
    function savePassword(profile, password) {
        request("rdp-password", profile, password, "save");
    }
    function retry() {
        if (!failedRequest)
            return;
        const task = failedRequest;
        failedRequest = null;
        failed = false;
        request(task.action, task.profile, task.password, task.operation);
    }
    function request(action, profile, password, operation) {
        const task = {action: action, profile: Object.assign({}, profile), password: password, operation: operation, id: ++sequence};
        const key = targetKey(profile);
        // Coalesce waiting edits, but preserve writes for other accounts and running work.
        pending = pending.filter(item => !(item.action === action && item.operation === operation
            && (operation === "load" || (operation === "save" && targetKey(item.profile) === key))));
        pending = pending.concat([task]);
        startNext();
        return task.id;
    }
    function startNext() {
        if (busy || pending.length === 0)
            return;
        const task = pending[0];
        pending = pending.slice(1);
        busy = true;
        if (!failed) {
            message = task.action === "rdp" ? "正在启动远程桌面…" : "正在访问系统密钥环…";
            logPath = "";
        }
        worker.task = task;
        worker.action = task.action;
        worker.input = JSON.stringify(Object.assign({}, task.profile, {password: task.password, operation: task.operation, savePassword: true}));
        worker.stdinEnabled = true;
        worker.running = true;
    }
    function finish(response, ok) {
        const task = worker.task;
        if (ok && response.ok === true && task.action === "rdp")
            remember(task.profile);
        const error = !ok || response.ok !== true || !!response.passwordWarning;
        if (error) {
            failed = true;
            failedRequest = task;
            message = response.message || "连接操作失败，请重试。";
            if (response.passwordWarning) {
                message += "\n" + response.passwordWarning;
                // Retry only the failed password write, without opening another desktop.
                if (response.ok && task.action === "rdp")
                    failedRequest = Object.assign({}, task, {action: "rdp-password", operation: "save"});
            }
            logPath = response.logPath || "";
        } else if (task.operation !== "load") {
            // A background lookup must not hide a previous save or connection error.
            if (!failedRequest || (targetKey(failedRequest.profile) === targetKey(task.profile)
                && failedRequest.operation === task.operation && failedRequest.action === task.action)) {
                failed = false;
                failedRequest = null;
                message = response.message || "";
                if (response.passwordSaved)
                    message += "\n密码已自动保存到系统密钥环。";
                logPath = response.logPath || "";
            }
        } else if (!failed) {
            message = response.found ? "已从系统密钥环读取密码。" : "此账号尚未保存密码。";
        }
        if (ok && response.ok && task.operation === "load")
            passwordLoaded(task.profile, response.found ? response.password : "", task.id);
        worker.task = null;
        busy = false;
        Qt.callLater(startNext);
    }

    Process {
        id: worker
        property string action: "rdp"
        property var task: null
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
                root.finish({message: "无法启动连接辅助程序，请检查插件是否完整安装。"}, false);
            }
        }
        stdout: StdioCollector { id: output }
        onExited: (code, status) => {
            if (!task)
                return;
            input = "";
            try {
                const response = JSON.parse(output.text);
                root.finish(response, code === 0);
            } catch (error) {
                root.finish({message: "无法读取连接辅助程序的响应，请检查插件是否完整安装。"}, false);
            }
        }
    }
}
