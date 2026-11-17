import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root

    pluginId: "localTranslate"
    popoutWidth: Math.min(420, root.parentScreen ? root.parentScreen.width - 48 : 420)

    horizontalBarPill: Component {
        DankIcon {
            id: icon
            name: "translate"
            size: root.iconSize
            color: Theme.surfaceText
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "离线翻译"
            Accessible.onPressAction: root.triggerPopout()
            Keys.onReturnPressed: root.triggerPopout()
            Keys.onEnterPressed: root.triggerPopout()
            Keys.onSpacePressed: root.triggerPopout()
            ToolTip.text: "离线翻译"
            ToolTip.visible: hover.hovered
            ToolTip.delay: 400
            HoverHandler { id: hover }
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: 4
                color: "transparent"
                border.width: icon.activeFocus ? 2 : 0
                border.color: Theme.primary
            }
        }
    }

    verticalBarPill: horizontalBarPill

    popoutContent: Component {
        TranslatePopout {
            settings: root.pluginData
            availableHeight: root.parentScreen ? root.parentScreen.height - root.barThickness - 80 : 420
        }
    }
}
