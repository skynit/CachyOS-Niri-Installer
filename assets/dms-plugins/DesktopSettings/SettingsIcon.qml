import QtQuick
import QtQuick.Effects

Item {
    id: root
    property string name: "settings-2"
    property color color: SettingsTheme.icon
    implicitWidth: 16
    implicitHeight: 16
    Image {
        id: image
        anchors.fill: parent
        source: Qt.resolvedUrl("icons/" + root.name + ".svg")
        sourceSize: Qt.size(root.width * 2, root.height * 2)
        visible: false
    }
    MultiEffect {
        anchors.fill: image
        source: image
        colorization: 1
        colorizationColor: root.color
    }
}
