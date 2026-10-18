import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root

    pluginId: "localTranslate"
    popoutWidth: 560

    horizontalBarPill: Component {
        Row {
            spacing: 6

            DankIcon {
                name: "translate"
                size: root.iconSize
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.pluginData.showLabel ?? true
                text: "翻译"
                font.pixelSize: 13
                anchors.verticalCenter: parent.verticalCenter
            }

        }

    }

    verticalBarPill: Component {
        DankIcon {
            name: "translate"
            size: root.iconSize
            color: Theme.surfaceText
        }

    }

    popoutContent: Component {
        TranslatePopout {
            settings: root.pluginData
            availableHeight: root.parentScreen ? root.parentScreen.height - root.barThickness - 80 : 560
        }

    }

}
