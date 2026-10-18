import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "localLyrics"
    readonly property alias source: source
    readonly property bool hasSong: !!source.player && !source.stopped && (source.title.trim().length > 0 || source.url.length > 0)
    visible: hasSong
    onHasSongChanged: setVisibilityOverride(hasSong)
    Component.onCompleted: setVisibilityOverride(hasSong)
    readonly property bool doubleRow: pluginData.doubleRow ?? true
    readonly property real widthLimit: Math.max(120, Math.min(800, pluginData.width ?? 320, (parentScreen?.width || 960) - 64))
    LyricsSource {
        id: source
        settings: root.pluginData
    }

    horizontalBarPill: Component {
        Item {
            id: strip
            implicitWidth: root.widthLimit
            implicitHeight: root.widgetThickness
            readonly property real rowHeight: Math.max(1, (height - 4) / (root.doubleRow ? 2 : 1))
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "本地歌词：" + root.source.currentText
            Accessible.onPressAction: root.triggerPopout()
            Keys.onReturnPressed: root.triggerPopout()
            Keys.onSpacePressed: root.triggerPopout()
            Column {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                StyledText {
                    width: parent.width
                    height: strip.rowHeight
                    text: root.source.currentText
                    font.pixelSize: Math.min(Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText), strip.rowHeight / 1.2)
                    color: Theme.widgetTextColor
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                }
                StyledText {
                    visible: root.doubleRow
                    width: parent.width
                    height: strip.rowHeight
                    text: root.source.nextText
                    font.pixelSize: Math.min(12, strip.rowHeight / 1.2)
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                }
            }
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: 6
                border.width: strip.activeFocus ? 2 : 0
                border.color: Theme.primary
            }
        }
    }
    verticalBarPill: Component {
        Item {
            implicitWidth: 24
            implicitHeight: 24
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "打开本地歌词"
            Accessible.onPressAction: root.triggerPopout()
            Keys.onReturnPressed: root.triggerPopout()
            Keys.onSpacePressed: root.triggerPopout()
            DankIcon {
                anchors.centerIn: parent
                name: "lyrics"
                size: 22
                color: Theme.primary
            }
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: 4
                border.width: parent.activeFocus ? 2 : 0
                border.color: Theme.primary
            }
        }
    }
    popoutWidth: Math.min(560, (parentScreen?.width || 960) - 48)
    popoutContent: Component {
        LyricsPopout {
            source: root.source
            maximumHeight: Math.min(560, (root.parentScreen?.height || 800) - root.barThickness - 100)
        }
    }
    pillRightClickAction: () => PopoutService.openSettingsWithTab("plugins")
}
