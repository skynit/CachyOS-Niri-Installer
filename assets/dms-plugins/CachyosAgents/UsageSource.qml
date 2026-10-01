import QtQuick
import Quickshell
import Quickshell.Io
import "Usage.js" as Usage

// 数据源：定期让 cachyos-agent-usage-update 重新采集，再把记录目录读成数组。
//
// 之所以让编排器写文件、面板读文件，而不是面板直接调采集器：新增一个 agent 只需要加一个
// 采集器，面板不用改；面板也只依赖一个稳定的目录约定。
Item {
    id: root

    property var settings: ({})
    property var records: []
    property bool refreshing: false
    property string lastError: ""
    property double updatedAt: 0

    readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/cachyos-desktop/agents/usage"
    readonly property int refreshSeconds: {
        const value = Number(settings.refreshSeconds);
        return isFinite(value) && value >= 60 ? Math.min(value, 3600) : 900;
    }
    readonly property var summary: Usage.summarise(root.records, root.settings)
    readonly property string barText: Usage.barText(root.records, root.settings)

    function refresh(withUpdate) {
        if (withUpdate) {
            if (!updateProcess.running)
                updateProcess.running = true;
        } else if (!readProcess.running) {
            readProcess.running = true;
        }
    }

    Component.onCompleted: refresh(false)

    Process {
        id: updateProcess
        command: ["cachyos-agent-usage-update"]
        onExited: (exitCode, exitStatus) => {
            // 采集失败不该清空已有数据：把原因说出来，继续读上一份记录。
            if (exitCode !== 0)
                root.lastError = "采集器退出码 " + exitCode + "（显示的是上一次的数据）";
            root.refresh(false);
        }
    }

    Process {
        id: readProcess
        // 用 jq 把目录下的记录合成一个数组：加 agent 不需要改这里。
        command: ["sh", "-c", "jq -s . \"$1\"/*.json 2>/dev/null || echo '[]'", "sh", root.usageDir]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(text);
                    if (!Array.isArray(parsed))
                        throw new Error("records must be an array");
                    root.records = parsed;
                    root.updatedAt = Date.now();
                    root.lastError = parsed.length === 0 ? "还没有采集到用量，点刷新重试" : "";
                } catch (error) {
                    root.lastError = "无法解析用量记录";
                }
            }
        }
    }

    Timer {
        interval: root.refreshSeconds * 1000
        running: true
        repeat: true
        onTriggered: root.refresh(true)
    }
}
