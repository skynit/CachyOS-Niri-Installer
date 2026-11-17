import QtQuick
import qs.Common
import qs.Widgets

DankButton {
    buttonHeight: 32
    horizontalPadding: 12
    radius: 4
    backgroundColor: Theme.surfaceContainerHigh
    textColor: Theme.surfaceText
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: clicked()
}
