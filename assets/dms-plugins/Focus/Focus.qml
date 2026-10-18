import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "focus"

    property bool active: false
    property string capabilityState: "degraded"
    property string reason: "正在读取状态"
    property string windowTitle: ""
    property bool busy: false
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("focus-helper").toString().replace(/^file:\/\//, ""))
    readonly property string label: active ? "专注已开启" : "专注已关闭"

    function update(result) {
        if (typeof result.active === "boolean")
            active = result.active;
        capabilityState = result.state || "unreachable";
        reason = result.reason || "unknown";
        windowTitle = result.title || "";
    }

    function toggle() {
        if (busy || commandProcess.running)
            return;
        busy = true;
        commandProcess.command = [helper, "toggle"];
        commandProcess.running = true;
    }

    function refresh() {
        if (busy || statusProcess.running)
            return;
        statusProcess.running = true;
    }

    Component.onCompleted: refresh()

    Process {
        id: commandProcess
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.update(JSON.parse(text)); }
                catch (error) { root.capabilityState = "unreachable"; root.reason = "无法解析辅助程序结果"; }
            }
        }
        onExited: (code) => {
            root.busy = false;
            if (code !== 0 && root.capabilityState !== "unreachable") {
                root.capabilityState = "degraded";
                root.reason = "操作未完成";
            }
        }
    }

    Process {
        id: statusProcess
        command: [root.helper, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.update(JSON.parse(text)); }
                catch (error) { root.capabilityState = "unreachable"; root.reason = "无法读取辅助程序状态"; }
            }
        }
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    pillClickAction: () => root.toggle()
    pillRightClickAction: () => root.triggerPopout()

    horizontalBarPill: Component {
        Item {
            id: pill
            implicitWidth: 16
            implicitHeight: root.widgetThickness
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: root.label + "，按下切换"
            Accessible.onPressAction: root.toggle()
            Keys.onReturnPressed: root.toggle()
            Keys.onSpacePressed: root.toggle()
            DankIcon {
                anchors.centerIn: parent
                name: root.active ? "center_focus_strong" : "center_focus_weak"
                size: Math.min(18, root.widgetThickness - 4)
                color: root.capabilityState === "unreachable" ? Theme.error : root.capabilityState === "degraded" ? Theme.warning : root.active ? Theme.success : Theme.surfaceVariantText
            }
            HoverHandler {
                onHoveredChanged: {
                    if (hovered) tooltip.show(root.label, pill, 0, 0);
                    else tooltip.hide();
                }
            }
            DankTooltipV2 { id: tooltip }
            Rectangle {
                width: 22
                height: Math.min(22, parent.height)
                anchors.centerIn: parent
                radius: 4
                color: "transparent"
                border.width: pill.activeFocus ? 2 : 0
                border.color: Theme.primary
            }
        }
    }

    verticalBarPill: Component {
        Item {
            id: pill
            implicitWidth: root.widgetThickness
            implicitHeight: root.widgetThickness
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: root.label + "，按下切换"
            Accessible.onPressAction: root.toggle()
            Keys.onReturnPressed: root.toggle()
            Keys.onSpacePressed: root.toggle()
            DankIcon {
                anchors.centerIn: parent
                name: root.active ? "center_focus_strong" : "center_focus_weak"
                size: 20
                color: root.capabilityState === "unreachable" ? Theme.error : root.capabilityState === "degraded" ? Theme.warning : root.active ? Theme.success : Theme.surfaceVariantText
            }
            HoverHandler {
                onHoveredChanged: {
                    if (hovered) tooltip.show(root.label, pill, 0, 0);
                    else tooltip.hide();
                }
            }
            DankTooltipV2 { id: tooltip }
            Rectangle {
                anchors.fill: parent
                radius: 4
                color: "transparent"
                border.width: pill.activeFocus ? 2 : 0
                border.color: Theme.primary
            }
        }
    }

    popoutWidth: 320
    popoutContent: Component {
        Column {
            width: Math.min(320, (root.parentScreen?.width || 960) - 48)
            padding: 16
            spacing: 12
            StyledText {
                text: "专注"
                font.pixelSize: 16
                font.weight: Font.DemiBold
                color: Theme.surfaceText
            }
            StyledText {
                width: parent.width - 32
                text: root.label + (root.busy ? " · 正在切换" : "")
                color: root.active ? Theme.success : Theme.surfaceVariantText
            }
            StyledText {
                width: parent.width - 32
                visible: root.active && root.windowTitle.length > 0
                text: "保持：" + root.windowTitle
                wrapMode: Text.WrapAnywhere
                color: Theme.surfaceText
            }
            StyledText {
                width: parent.width - 32
                visible: root.reason !== "on" && root.reason !== "off"
                text: root.reason === "window_closed" ? "原窗口已关闭，已退出专注" : root.reason === "dnd_disabled" ? "通知免打扰已被其他操作关闭" : root.reason === "guard_stopped" ? "焦点监听已停止，请退出后重新开启" : root.reason
                wrapMode: Text.WrapAnywhere
                color: root.capabilityState === "unreachable" ? Theme.error : Theme.warning
            }
            DankButton {
                text: root.active ? "退出专注" : "开始专注"
                iconName: root.active ? "stop" : "center_focus_strong"
                enabled: !root.busy
                onClicked: root.toggle()
            }
        }
    }
}
