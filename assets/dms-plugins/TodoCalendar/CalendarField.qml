import QtQuick
import QtQuick.Templates as T
import qs.Common

T.TextField {
    id: root
    implicitHeight: 32
    implicitWidth: 160
    padding: 8
    topPadding: 4
    bottomPadding: 4
    color: Theme.surfaceText
    placeholderTextColor: Theme.surfaceVariantText
    selectionColor: Theme.primary
    selectedTextColor: Theme.primaryText
    font.family: Theme.fontFamily
    font.pixelSize: 13
    font.letterSpacing: 0
    activeFocusOnTab: true
    selectByMouse: true
    background: Rectangle {
        radius: 4
        color: Theme.surfaceContainerLow
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? Theme.primary : Theme.outlineVariant
    }
}
