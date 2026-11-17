import QtQuick
import QtQuick.Controls
import QtQuick.Templates as T

T.Button {
    id: root
    property bool primary: false
    property string iconName: ""
    property string help: text
    implicitHeight: 32
    padding: 0
    implicitWidth: iconName && !text ? 32 : Math.max(64, label.implicitWidth + 24)
    hoverEnabled: true
    activeFocusOnTab: true
    Accessible.name: text || help
    ToolTip.visible: hovered && help.length > 0
    ToolTip.text: help
    contentItem: Item {
        implicitWidth: label.implicitWidth + (root.iconName ? 24 : 0)
        implicitHeight: 20
        SettingsIcon {
            visible: root.iconName.length > 0
            name: root.iconName
            anchors.verticalCenter: parent.verticalCenter
            anchors.horizontalCenter: root.text ? undefined : parent.horizontalCenter
            color: root.primary && root.enabled ? "white" : SettingsTheme.muted
        }
        SettingsText {
            id: label
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: root.iconName && root.text ? 12 : 0
            text: root.text
            font.pixelSize: 13
            color: !root.enabled ? SettingsTheme.muted : root.primary ? "white" : SettingsTheme.text
        }
    }
    background: Rectangle {
        radius: 6
        color: !root.enabled ? SettingsTheme.selected : root.primary ? SettingsTheme.primary : root.down || root.hovered ? SettingsTheme.raised : SettingsTheme.surface
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? SettingsTheme.focus : root.primary || !root.enabled ? "transparent" : SettingsTheme.border
    }
}
