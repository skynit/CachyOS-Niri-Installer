pragma Singleton
import QtQuick
import qs.Common

QtObject {
    readonly property bool dark: !Theme.isLightMode
    readonly property color background: dark ? "#0F141A" : "#FFFFFF"
    readonly property color surface: dark ? "#171E26" : "#FFFFFF"
    readonly property color raised: dark ? "#1D2732" : "#F2F4F2"
    readonly property color selected: dark ? "#1D2732" : "#EDEDED"
    readonly property color border: dark ? "#2B3947" : "#E9E9E9"
    readonly property color subtle: dark ? "#202B35" : "#F0F0F0"
    readonly property color text: dark ? "#EEF3F8" : "#333333"
    readonly property color muted: dark ? "#9AA8B5" : "#636261"
    readonly property color icon: dark ? "#9AA8B5" : "#777774"
    readonly property color primary: dark ? "#4D8DFF" : "#245EC7"
    readonly property color focus: dark ? "#A9C7FF" : "#245EC7"
    readonly property color success: dark ? "#55B98B" : "#4B6F5A"
    readonly property color warning: dark ? "#D2A354" : "#855A15"
    readonly property color danger: dark ? "#E27878" : "#A33E3E"
}
