import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: root

    property real usage: 0
    property real freqMHz: -1
    property real maxMHz: 0
    property color accent: Theme.primary
    property real barWidth: 14
    property real trackHeight: 84
    property bool showFreq: true

    implicitWidth: barWidth
    implicitHeight: trackHeight + (showFreq ? 30 : 16)

    Rectangle {
        id: track

        width: root.barWidth
        height: root.trackHeight
        radius: Math.min(width, height) / 2
        color: Theme.withAlpha(Theme.surfaceVariant, 0.32)
    }

    Item {
        id: fillLayer

        width: root.barWidth
        height: Math.max(3, root.trackHeight * Math.max(0, Math.min(100, root.usage)) / 100)
        anchors.bottom: track.bottom

        Rectangle {
            anchors.fill: parent
            radius: Math.min(root.barWidth, height) / 2
            gradient: Gradient {
                GradientStop {
                    position: 0.0
                    color: Qt.lighter(root.accent, 1.06)
                }
                GradientStop {
                    position: 1.0
                    color: Qt.darker(root.accent, 1.35)
                }
            }
        }

        Rectangle {
            width: parent.width
            height: Math.min(parent.height, root.barWidth / 2)
            anchors.bottom: parent.bottom
            color: Qt.darker(root.accent, 1.35)
        }

        Behavior on height {
            NumberAnimation {
                duration: 340
                easing.type: Easing.OutCubic
            }
        }
    }

    Rectangle {
        id: tick

        width: Math.max(3, root.barWidth - 4)
        height: 2
        x: 2
        radius: 1
        visible: root.maxMHz > 0 && root.freqMHz > 0
        color: Theme.withAlpha(Theme.surfaceText, 0.92)
        y: root.trackHeight * (1 - Math.max(0, Math.min(1, root.freqMHz / root.maxMHz)))

        Behavior on y {
            NumberAnimation {
                duration: 340
                easing.type: Easing.OutCubic
            }
        }
    }

    Column {
        anchors.top: track.bottom
        anchors.topMargin: 6
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: -1

        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Math.round(root.usage)
            color: Theme.surfaceText
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.features: ({
                    "tnum": 1
                })
        }

        StyledText {
            visible: root.showFreq && root.freqMHz > 0
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.freqMHz > 0 ? (root.freqMHz / 1000).toFixed(2) : "—"
            color: Theme.surfaceVariantText
            font.pixelSize: 9
            font.features: ({
                    "tnum": 1
                })
        }
    }
}
