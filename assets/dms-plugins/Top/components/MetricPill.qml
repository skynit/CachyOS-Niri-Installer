import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: root

    property string icon: "download"
    property color accent: Theme.primary
    property string value: "—"
    property string unit: ""

    implicitWidth: pillRow.implicitWidth
    implicitHeight: 24

    Row {
        id: pillRow

        spacing: 8

        Rectangle {
            width: 22
            height: 22
            radius: 11
            color: Theme.withAlpha(root.accent, 0.14)

            DankIcon {
                anchors.centerIn: parent
                name: root.icon
                size: 13
                color: root.accent
            }
        }

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            StyledText {
                id: valueText

                text: root.value
                color: Theme.surfaceText
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.features: ({
                        "tnum": 1
                    })
            }

            StyledText {
                text: root.unit
                color: Theme.surfaceVariantText
                font.pixelSize: 10
                anchors.baseline: valueText.baseline
            }
        }
    }
}
