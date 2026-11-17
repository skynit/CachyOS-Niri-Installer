import QtQuick
import QtQuick.Templates as T

T.TextField {
    id: root
    property bool invalid: false
    implicitHeight: 32
    implicitWidth: 88
    padding: 8
    topPadding: 4
    bottomPadding: 4
    activeFocusOnTab: true
    selectByMouse: true
    verticalAlignment: TextInput.AlignVCenter
    color: enabled ? SettingsTheme.text : SettingsTheme.muted
    placeholderTextColor: SettingsTheme.muted
    selectionColor: SettingsTheme.primary
    selectedTextColor: "#FFFFFF"
    font.family: "Noto Sans CJK SC"
    font.pixelSize: 13
    SettingsText {
        x: root.leftPadding
        y: root.topPadding
        width: root.availableWidth
        height: root.availableHeight
        visible: !root.length && !root.preeditText
        text: root.placeholderText
        font: root.font
        color: root.placeholderTextColor
        horizontalAlignment: root.horizontalAlignment
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
    }
    background: Rectangle {
        radius: 6
        color: root.enabled ? SettingsTheme.surface : SettingsTheme.selected
        border.width: root.activeFocus ? 2 : 1
        border.color: root.invalid ? SettingsTheme.danger : root.activeFocus ? SettingsTheme.focus : SettingsTheme.border
    }
}
