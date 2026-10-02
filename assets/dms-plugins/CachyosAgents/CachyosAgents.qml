import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Usage.js" as Usage

PluginComponent {
    id: root

    readonly property string label: Usage.barText(sampler.records, root.pluginData)

    UsageSource {
        id: sampler
        settings: root.pluginData
    }

    horizontalBarPill: Component {
        Item {
            id: pill
            readonly property real fontPixels: Math.max(8, Math.min(14, root.widgetThickness - 12))
            // 状态栏只放 token 数字：不要图标，也不要金额（金额看弹窗）。
            implicitWidth: Math.max(16, content.implicitWidth + 12)
            implicitHeight: root.widgetThickness
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "AI agent 用量：" + root.label
            Accessible.onPressAction: root.triggerPopout()
            Keys.onReturnPressed: root.triggerPopout()
            Keys.onSpacePressed: root.triggerPopout()

            StyledText {
                id: content
                anchors.centerIn: parent
                text: root.label
                font.pixelSize: pill.fontPixels
                color: Theme.widgetTextColor
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: 6
                color: "transparent"
                border.width: pill.activeFocus ? 2 : 0
                border.color: Theme.primary
            }
        }
    }

    // 显式判空而不是可选链：qmllint 解析不了 ?.，写成这样整份文件就能当门禁跑。
    readonly property real screenWidth: parentScreen && parentScreen.width ? parentScreen.width : 960
    readonly property real screenHeight: parentScreen && parentScreen.height ? parentScreen.height : 800

    popoutWidth: Math.min(560, root.screenWidth - 48)
    popoutContent: Component {
        UsageDetails {
            source: sampler
            maximumHeight: Math.max(240, Math.min(640, root.screenHeight - root.barThickness - 150))
        }
    }
    pillRightClickAction: () => PopoutService.openSettingsWithTab("plugins")
}
