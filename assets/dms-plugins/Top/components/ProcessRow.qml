import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.Common
import qs.Widgets

Item {
    id: root

    property var proc: null
    readonly property bool hovered: hoverArea.containsMouse

    signal contextRequested(real x, real y)

    visible: proc !== null
    height: 22

    MouseArea {
        id: hoverArea

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    Rectangle {
        anchors.fill: parent
        radius: 5
        color: Theme.withAlpha(Theme.surfaceText, root.hovered ? 0.06 : 0)

        Behavior on color {
            ColorAnimation {
                duration: 120
            }
        }
    }

    Item {
        id: iconBox

        width: 15
        height: 15
        x: 4
        anchors.verticalCenter: parent.verticalCenter

        IconImage {
            id: appIcon

            anchors.fill: parent
            source: root.proc && root.proc.icon ? Quickshell.iconPath(root.proc.icon, true) : ""
            visible: status === Image.Ready
        }

        DankIcon {
            visible: appIcon.status !== Image.Ready
            anchors.centerIn: parent
            name: "apps"
            size: 13
            color: Theme.surfaceVariantText
        }
    }

    StyledText {
        id: nameText

        anchors.left: iconBox.right
        anchors.leftMargin: 7
        anchors.right: memText.left
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        text: {
            const p = root.proc || ({});
            return (p.name || "—") + (p.count > 1 ? "  ×" + p.count : "");
        }
        elide: Text.ElideRight
        wrapMode: Text.NoWrap
        maximumLineCount: 1
        color: Theme.surfaceText
        font.pixelSize: 11
    }

    StyledText {
        id: memText

        anchors.right: cpuText.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: {
            const kb = root.proc ? (root.proc.memKB || 0) : 0;
            if (kb >= 1048576)
                return (kb / 1048576).toFixed(1) + "G";
            if (kb >= 1024)
                return Math.round(kb / 1024) + "M";
            return "0M";
        }
        color: Theme.surfaceVariantText
        wrapMode: Text.NoWrap
        maximumLineCount: 1
        font.pixelSize: 10
        font.features: ({
                "tnum": 1
            })
    }

    StyledText {
        id: cpuText

        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        text: {
            const cpu = root.proc ? (root.proc.cpu || 0) : 0;
            if (cpu >= 10) {
                return Math.round(cpu) + "%";
            }
            return cpu.toFixed(1) + "%";
        }
        color: Theme.surfaceVariantText
        wrapMode: Text.NoWrap
        maximumLineCount: 1
        font.pixelSize: 10
        font.features: ({
                "tnum": 1
            })
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function (mouse) {
            root.contextRequested(mouse.x, mouse.y);
        }
    }
}
