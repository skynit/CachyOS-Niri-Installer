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

    // 默认 agent 的状态：面板只负责显示与点击，进程留在这里（弹窗保持纯展示，
    // 也因此能在没有 Quickshell 运行时的情况下被单独渲染/校验）。
    property string defaultAgent: ""
    property var installedAgents: ({})
    property string agentStateError: ""

    function refreshAgentState() {
        if (!agentStateProcess.running) {
            agentStateProcess.running = true;
        }
    }

    function setDefaultAgent(id) {
        if (!id)
            return;
        agentStateError = "";
        setDefaultProcess.command = ["cachyos-default-agent", id];
        setDefaultProcess.running = true;
    }

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

    Component.onCompleted: {
        refresh(false);
        refreshAgentState();
    }

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

    // 读"当前默认 + 各 agent 是否已安装"：两个稳定接口的输出拼起来，
    // 面板不解析任何会话文件。解析逻辑在 Usage.js（有 node 测试）。
    Process {
        id: agentStateProcess
        command: ["sh", "-c",
            "printf 'default=%s\\n' \"$(cachyos-default-agent 2>/dev/null || true)\"; "
            + "cachyos-agent --list 2>/dev/null | sed 's/^/list=/'"]
        stdout: StdioCollector {
            onStreamFinished: {
                const state = Usage.parseAgentState(text);
                root.defaultAgent = state.default;
                root.installedAgents = state.installed;
            }
        }
    }

    // 写成功后重读一次：徽标与按钮立刻反映真实值，而不是等下一次刷新。
    Process {
        id: setDefaultProcess
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.agentStateError = "设置默认 agent 失败（退出码 " + exitCode + "）";
                return;
            }
            root.refreshAgentState();
        }
    }
}
