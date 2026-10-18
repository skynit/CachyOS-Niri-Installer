import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Common
import qs.Services
import qs.Widgets
import "Timeline.js" as Timeline

Item {
    id: root
    required property var source
    property var parentPopout: null
    property var closePopout: null
    property real maximumHeight: 560
    property bool follow: true
    implicitHeight: Math.max(300, maximumHeight)

    function centerLine() {
        if (follow && source.currentIndex >= 0)
            lyrics.positionViewAtIndex(source.currentIndex, ListView.Center);
    }
    Connections {
        target: root.source
        function onCurrentIndexChanged() {
            Qt.callLater(root.centerLine);
        }
        function onResultChanged() {
            root.follow = true;
            Qt.callLater(root.centerLine);
        }
    }
    Connections {
        target: root.parentPopout
        function onShouldBeVisibleChanged() {
            if (root.parentPopout.shouldBeVisible) {
                root.follow = true;
                Qt.callLater(root.centerLine);
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            DankIcon {
                name: "lyrics"
                size: 24
                color: Theme.primary
            }
            StyledText {
                Layout.fillWidth: true
                text: root.source.title || "本地歌词"
                font.pixelSize: 20
                font.weight: Font.DemiBold
                maximumLineCount: 2
                wrapMode: Text.Wrap
                elide: Text.ElideRight
            }
            DankButton {
                visible: root.closePopout !== null
                text: "关闭"
                buttonHeight: 32
                horizontalPadding: 12
                backgroundColor: "transparent"
                textColor: Theme.surfaceVariantText
                Accessible.role: Accessible.Button
                Accessible.name: "关闭歌词"
                onClicked: root.closePopout()
            }
        }
        StyledText {
            Layout.fillWidth: true
            text: [root.source.artist, root.source.player?.identity || ""].filter(value => value).join(" · ")
            visible: text.length > 0
            color: Theme.surfaceVariantText
            font.pixelSize: 13
            maximumLineCount: 2
            wrapMode: Text.Wrap
            elide: Text.ElideRight
        }
        RowLayout {
            Layout.fillWidth: true
            StyledText {
                Layout.fillWidth: true
                text: root.source.message
                color: root.source.result.status === "error" ? Theme.error : Theme.surfaceVariantText
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }
            StyledText {
                text: Timeline.clock(root.source.position)
                color: Theme.surfaceVariantText
                font.pixelSize: 13
            }
        }
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Theme.outlineMedium
        }
        ListView {
            id: lyrics
            objectName: "lyricsList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.source.lines
            spacing: 8
            boundsBehavior: Flickable.StopAtBounds
            activeFocusOnTab: true
            Accessible.name: "完整歌词"
            onMovementStarted: root.follow = false
            Keys.onPressed: event => {
                let amount = 0;
                if (event.key === Qt.Key_Down)
                    amount = 40;
                else if (event.key === Qt.Key_Up)
                    amount = -40;
                else if (event.key === Qt.Key_PageDown)
                    amount = height;
                else if (event.key === Qt.Key_PageUp)
                    amount = -height;
                else
                    return;
                root.follow = false;
                contentY = Math.max(0, Math.min(Math.max(0, contentHeight - height), contentY + amount));
                event.accepted = true;
            }
            Controls.ScrollBar.vertical: Controls.ScrollBar {}
            delegate: Rectangle {
                id: line
                required property var modelData
                required property int index
                readonly property bool current: index === root.source.currentIndex
                width: lyrics.width - 12
                height: lineText.implicitHeight + 16
                radius: 6
                color: current ? Theme.surfaceContainerHigh : "transparent"
                border.width: current ? 1 : 0
                border.color: Theme.primary
                StyledText {
                    id: lineText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 12
                    y: 8
                    text: line.modelData.text || "♪"
                    color: line.current ? Theme.primary : Theme.surfaceText
                    font.pixelSize: 16
                    font.weight: line.current ? Font.DemiBold : Font.Normal
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    Accessible.name: (line.current ? "当前句：" : "") + text
                }
            }
            header: Item {
                width: lyrics.width - 16
                height: emptyHint.visible ? emptyHint.implicitHeight : 0
                StyledText {
                    id: emptyHint
                    width: parent.width
                    visible: root.source.lines.length === 0
                    text: {
                        if (!root.source.player)
                            return "播放歌曲后，在这里查看歌词。";
                        if (root.source.result.status === "loading")
                            return "";
                        if (root.source.result.status === "error")
                            return "检查音频文件或播放器媒体库后，点击“重新读取”。";
                        return "请确认歌曲的音频标签中包含歌词。修改内嵌歌词后，点击“重新读取”。";
                    }
                    wrapMode: Text.Wrap
                    font.pixelSize: 14
                    color: Theme.surfaceVariantText
                }
            }
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.color: Theme.primary
                border.width: lyrics.activeFocus ? 1 : 0
                radius: 6
            }
        }
        StyledText {
            Layout.fillWidth: true
            visible: !!root.source.result.path
            text: root.source.result.path || ""
            font.pixelSize: 12
            color: Theme.surfaceVariantText
            elide: Text.ElideMiddle
            wrapMode: Text.NoWrap
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            DankButton {
                text: "重新读取"
                buttonHeight: 32
                horizontalPadding: 12
                enabled: !!root.source.player
                Accessible.role: Accessible.Button
                Accessible.name: text
                onClicked: root.source.reload()
            }
            DankButton {
                text: "跟随当前句"
                visible: root.source.result.status === "synced"
                enabled: root.source.currentIndex >= 0
                buttonHeight: 32
                horizontalPadding: 12
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                Accessible.role: Accessible.Button
                Accessible.name: text
                onClicked: {
                    root.follow = true;
                    root.centerLine();
                }
            }
            Item {
                Layout.fillWidth: true
            }
            DankButton {
                text: "设置"
                buttonHeight: 32
                horizontalPadding: 12
                backgroundColor: "transparent"
                textColor: Theme.primary
                Accessible.role: Accessible.Button
                Accessible.name: "打开插件设置"
                onClicked: {
                    if (root.closePopout)
                        root.closePopout();
                    PopoutService.openSettingsWithTab("plugins");
                }
            }
        }
    }
}
