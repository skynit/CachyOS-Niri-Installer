import QtQuick
import qs.Common
import qs.Widgets

DankActionButton {
    id: root
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: tooltipText || iconName
    Accessible.onPressAction: root.clicked()
    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed: root.clicked()

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: "transparent"
        border.width: root.activeFocus ? 2 : 0
        border.color: Theme.primary
    }
}
