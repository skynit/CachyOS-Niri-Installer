import QtQuick
import QtQuick.Controls

ComboBox {
    id: root
    implicitWidth: 164
    implicitHeight: 32
    textRole: "label"
    valueRole: "value"
    activeFocusOnTab: true
    leftPadding: 12
    rightPadding: 32
    Accessible.name: "设置选项"
    contentItem: SettingsText {
        text: root.displayText
        font.pixelSize: 13
        color: root.enabled ? SettingsTheme.text : SettingsTheme.muted
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        wrapMode: Text.NoWrap
    }
    indicator: SettingsIcon { x: root.width - 24; y: 8; name: "chevron-down" }
    background: Rectangle {
        color: root.enabled ? SettingsTheme.surface : SettingsTheme.selected
        radius: 6
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? SettingsTheme.focus : SettingsTheme.border
    }
    delegate: ItemDelegate {
        required property var modelData
        required property int index
        width: root.width
        implicitHeight: 36
        highlighted: root.highlightedIndex === index
        contentItem: SettingsText { text: modelData.label; font.pixelSize: 13 }
        background: Rectangle { color: parent.highlighted ? SettingsTheme.selected : SettingsTheme.surface; radius: 4 }
    }
    popup: Popup {
        y: root.height + 4
        width: root.width
        padding: 4
        implicitHeight: Math.min(320, list.contentHeight + 8)
        contentItem: ListView {
            id: list
            clip: true
            implicitHeight: contentHeight
            model: root.popup.visible ? root.delegateModel : null
            currentIndex: root.highlightedIndex
            ScrollIndicator.vertical: ScrollIndicator {}
        }
        background: Rectangle { color: SettingsTheme.surface; radius: 6; border.color: SettingsTheme.border }
    }
}
