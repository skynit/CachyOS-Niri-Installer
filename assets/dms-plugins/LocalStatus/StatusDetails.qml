import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Services
import qs.Widgets
import "Status.js" as Status

Column {
    id: root
    required property var source
    property var closePopout: null
    property var parentPopout: null
    property real maximumHeight: 560
    padding: 16
    spacing: 16

    function tone(value) {
        if (value.tone === "success")
            return Theme.success;
        if (value.tone === "warning")
            return Theme.warning;
        return value.state === "healthy" ? Theme.surfaceText : Theme.surfaceVariantText;
    }

    RowLayout {
        id: header
        width: root.width - root.leftPadding - root.rightPadding
        spacing: 8
        DankIcon {
            name: "monitoring"
            size: 20
            color: Theme.primary
        }
        StyledText {
            text: "本机状态"
            font.pixelSize: 16
            font.weight: Font.DemiBold
            Layout.fillWidth: true
        }
        StatusButton {
            iconName: "refresh"
            tooltipText: "刷新采样"
            onClicked: root.source.refresh()
        }
        StatusButton {
            iconName: "settings"
            tooltipText: "插件设置"
            onClicked: {
                root.closePopout?.();
                PopoutService.openSettingsWithTab("plugins");
            }
        }
        StatusButton {
            iconName: "close"
            tooltipText: "关闭详情"
            onClicked: root.closePopout?.()
        }
    }

    DankFlickable {
        width: root.width - root.leftPadding - root.rightPadding
        height: Math.min(contentHeight, Math.max(0, root.maximumHeight - header.height - root.spacing - root.topPadding - root.bottomPadding))
        contentHeight: body.implicitHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        activeFocusOnTab: true
        Accessible.role: Accessible.Pane
        Accessible.name: "本机采样详情"
        Keys.onDownPressed: contentY = Math.min(Math.max(0, contentHeight - height), contentY + 40)
        Keys.onUpPressed: contentY = Math.max(0, contentY - 40)

        Column {
            id: body
            width: parent.width
            spacing: 12

            StyledText {
                width: parent.width
                text: DgopService.cpuModel || "等待设备信息"
                font.pixelSize: 12
                color: Theme.surfaceVariantText
                wrapMode: Text.Wrap
            }

            Repeater {
                model: Status.fields.slice(0, 3)
                delegate: Column {
                    id: networkRow
                    required property var modelData
                    readonly property var reading: root.source.values[modelData.id]
                    width: body.width
                    spacing: 4
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        DankIcon {
                            name: networkRow.modelData.icon
                            size: 18
                            color: Theme.primary
                        }
                        StyledText {
                            text: networkRow.modelData.label
                            font.pixelSize: 13
                            Layout.fillWidth: true
                        }
                        StyledText {
                            text: networkRow.reading.value
                            font.pixelSize: 13
                            color: root.tone(networkRow.reading)
                            wrapMode: Text.NoWrap
                        }
                    }
                    StyledText {
                        width: parent.width
                        text: networkRow.reading.detail + (networkRow.reading.reason ? " · " + networkRow.reading.state + " / " + networkRow.reading.reason : "")
                        color: Theme.surfaceVariantText
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.outlineVariant
                    }
                }
            }

            GridLayout {
                width: parent.width
                columns: 2
                uniformCellWidths: true
                columnSpacing: 16
                rowSpacing: 16
                Repeater {
                    model: [Status.fields[3], Status.fields[5], Status.fields[7], Status.fields[6], Status.fields[4], Status.fields[8]]
                    delegate: ColumnLayout {
                        id: metric
                        required property var modelData
                        readonly property var reading: root.source.values[modelData.id]
                        Layout.fillWidth: true
                        Layout.preferredWidth: (body.width - 16) / 2
                        Layout.alignment: Qt.AlignTop
                        spacing: 8
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            DankIcon {
                                name: metric.modelData.icon
                                size: 18
                                color: Theme.surfaceVariantText
                            }
                            StyledText {
                                text: metric.modelData.label
                                font.pixelSize: 13
                                color: Theme.surfaceVariantText
                                Layout.fillWidth: true
                            }
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: metric.reading.value
                            font.pixelSize: metric.modelData.id === "time" ? 16 : 20
                            font.weight: Font.DemiBold
                            wrapMode: Text.Wrap
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            height: 4
                            visible: metric.reading.percent !== null
                            color: Theme.surfaceContainerHigh
                            Rectangle {
                                width: parent.width * Math.max(0, Math.min(100, metric.reading.percent || 0)) / 100
                                height: parent.height
                                color: metric.reading.percent >= 90 ? Theme.error : metric.reading.percent >= 75 ? Theme.warning : Theme.primary
                            }
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: metric.reading.detail + (metric.reading.reason ? "\n" + metric.reading.state + " / " + metric.reading.reason : "")
                            font.pixelSize: 12
                            color: Theme.surfaceVariantText
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.outlineVariant
            }
            StyledText {
                width: parent.width
                text: "资源采样 " + (root.source.statsAt ? Qt.formatDateTime(new Date(root.source.statsAt), "HH:mm:ss") : "--") + " · 网络采样 " + (root.source.networkAt ? Qt.formatDateTime(new Date(root.source.networkAt), "HH:mm:ss") : "--")
                color: Theme.surfaceVariantText
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
        }
    }
}
