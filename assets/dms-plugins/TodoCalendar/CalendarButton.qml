import QtQuick
import QtQuick.Controls
import QtQuick.Templates as T
import qs.Common
import qs.Widgets

T.Button {
    id: root
    property string iconName: ""
    property string help: text
    property bool primary: false
    property bool danger: false
    property bool selected: false
    implicitHeight: 32
    implicitWidth: !text ? 32 : Math.max(64, label.implicitWidth + (iconName ? 48 : 24))
    padding: 8
    hoverEnabled: true
    activeFocusOnTab: true
    Accessible.name: text || help
    ToolTip.visible: hovered && help.length > 0
    ToolTip.text: help
    contentItem: Row {
        spacing: 8
        DankIcon {
            visible: root.iconName.length > 0
            name: root.iconName
            size: 16
            color: root.primary ? Theme.primaryText : root.danger ? Theme.error : Theme.surfaceVariantText
            anchors.verticalCenter: parent.verticalCenter
        }
        CalendarText {
            id: label
            visible: root.text.length > 0
            text: root.text
            font.pixelSize: 13
            font.weight: Font.Medium
            color: root.primary ? Theme.primaryText : root.danger ? Theme.error : Theme.surfaceText
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    background: Rectangle {
        radius: 4
        color: root.primary ? Theme.primary : root.down || root.hovered || root.selected ? Theme.surfaceContainerHigh : Theme.surfaceContainer
        opacity: root.enabled ? 1 : 0.5
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? Theme.primary : root.selected ? Theme.primary : Theme.outlineVariant
    }
}
