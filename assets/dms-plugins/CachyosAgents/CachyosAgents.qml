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
    readonly property bool showText: root.pluginData.displayMode !== "icon"

    UsageSource {
        id: sampler
        settings: root.pluginData
    }

    horizontalBarPill: Component {
        Item {
            id: pill
            readonly property real iconPixels: Math.max(10, Math.min(18, root.widgetThickness - 8))
            readonly property real fontPixels: Math.max(8, Math.min(14, root.widgetThickness - 12))
            implicitWidth: content.implicitWidth + 12
            implicitHeight: root.widgetThickness
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "AI agent 用量：" + root.label
            Accessible.onPressAction: root.triggerPopout()
            Keys.onReturnPressed: root.triggerPopout()
            Keys.onSpacePressed: root.triggerPopout()

            Row {
                id: content
                anchors.centerIn: parent
                spacing: 4
                DankIcon {
                    name: "smart_toy"
                    size: pill.iconPixels
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: root.label
                    visible: root.showText && text.length > 0
                    font.pixelSize: pill.fontPixels
                    color: Theme.widgetTextColor
                    anchors.verticalCenter: parent.verticalCenter
                }
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
