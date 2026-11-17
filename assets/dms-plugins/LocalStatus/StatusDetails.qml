import QtQuick
import QtQuick.Controls
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
    property real maximumHeight: 680
    property var expandedRows: ({})
    readonly property real innerWidth: width - leftPadding - rightPadding
    readonly property color divider: Theme.withAlpha(Theme.outline, 0.18)
    readonly property var sections: [
        { label: "网络", fields: Status.fields.slice(0, 3) },
        { label: "资源", fields: ["cpu", "ram", "disk", "swap", "load", "netspeed"].map(function (id) {
            return Status.fields.find(function (field) { return field.id === id; });
        }) }
    ]
    padding: 16
    spacing: 8

    function toggleRow(id) {
        var next = Object.assign({}, expandedRows);
        next[id] = !next[id];
        expandedRows = next;
    }

    function valueColor(reading) {
        if (reading.tone === "success") return Theme.success;
        if (reading.tone === "warning") return Theme.warning;
        if (reading.tone === "danger" || reading.state === "unreachable") return Theme.error;
        return reading.state === "healthy" ? Theme.surfaceText : Theme.surfaceVariantText;
    }

    function percentColor(percent) {
        return percent >= 90 ? Theme.error : percent >= 75 ? Theme.warning : Theme.primary;
    }

    function showItem(item) {
        var top = item.mapToItem(body, 0, 0).y;
        if (top < scroller.contentY)
            scroller.contentY = top;
        else if (top + item.height > scroller.contentY + scroller.height)
            scroller.contentY = Math.max(0, top + item.height - scroller.height);
    }

    component StatusRow: Column {
        id: row
        required property var field
        readonly property var reading: root.source.values[field.id]
        readonly property bool expanded: root.expandedRows[field.id] === true
        readonly property bool hasPercent: reading.state === "healthy" && Status.valid(reading.percent) && reading.percent <= 100
        readonly property string percentText: Status.valid(reading.percent) ? reading.percent.toFixed(1) + "%" : ""
        readonly property string label: field.id === "ram" ? "内存（已用）"
            : field.id === "disk" ? "磁盘（可用）" : field.id === "swap" ? "Swap（已用）" : field.label
        readonly property string value: reading.value === "--" ? reading.detail : (reading.summary || reading.value)
        width: body.width

        AbstractButton {
            id: summary
            objectName: "status-row-" + row.field.id
            width: parent.width
            implicitHeight: Math.max(40, contentItem.implicitHeight + 16)
            hoverEnabled: true
            focusPolicy: Qt.StrongFocus
            text: row.label
            Accessible.role: Accessible.Button
            Accessible.name: text + "，" + row.value
                + (row.hasPercent ? "，已用比例 " + row.percentText : "")
            Accessible.description: row.expanded ? "收起详情" : "展开详情"
            Accessible.expandable: true
            Accessible.expanded: row.expanded
            Accessible.onPressAction: clicked()
            onClicked: root.toggleRow(row.field.id)
            onActiveFocusChanged: if (activeFocus) Qt.callLater(function () { root.showItem(summary); })
            Keys.onReturnPressed: clicked()
            Keys.onEnterPressed: clicked()
            Keys.onRightPressed: if (!row.expanded) clicked()
            Keys.onLeftPressed: if (row.expanded) clicked()
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            background: Rectangle {
                radius: 4
                color: summary.hovered || summary.down || row.expanded ? Theme.surfaceContainerHigh : "transparent"
                border.width: summary.activeFocus ? 2 : 0
                border.color: Theme.primary
            }
            contentItem: RowLayout {
                spacing: 8
                DankIcon {
                    name: row.field.icon
                    size: 18
                    color: Theme.surfaceVariantText
                    Layout.leftMargin: 8
                }
                StyledText {
                    text: row.label
                    font.pixelSize: 13
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    ToolTip.text: text
                    ToolTip.visible: truncated && labelHover.hovered
                    ToolTip.delay: 400
                    HoverHandler { id: labelHover }
                }
                Rectangle {
                    objectName: "status-meter-" + row.field.id
                    visible: row.hasPercent && root.innerWidth >= 480
                    Layout.preferredWidth: 64
                    Layout.preferredHeight: 4
                    Layout.rightMargin: visible ? 16 : 0
                    radius: 2
                    color: Theme.surfaceContainerHighest
                    Accessible.ignored: true
                    Rectangle {
                        width: parent.width * row.reading.percent / 100
                        height: parent.height
                        radius: 2
                        color: root.percentColor(row.reading.percent)
                    }
                }
                StyledText {
                    objectName: "status-value-" + row.field.id
                    text: row.value
                    font.pixelSize: row.field.id === "netspeed" ? 13 : 14
                    font.weight: Font.Medium
                    color: root.valueColor(row.reading)
                    horizontalAlignment: Text.AlignRight
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle
                    Layout.preferredWidth: row.field.id === "netspeed" ? Math.min(248, root.innerWidth * 0.55) : Math.min(136, root.innerWidth * 0.45)
                    Layout.maximumWidth: root.innerWidth * 0.55
                    Layout.minimumWidth: 0
                    ToolTip.text: text
                    ToolTip.visible: truncated && valueHover.hovered
                    ToolTip.delay: 400
                    HoverHandler { id: valueHover }
                }
                DankIcon {
                    name: row.expanded ? "expand_more" : "chevron_right"
                    size: 16
                    color: row.expanded ? Theme.primary : Theme.surfaceVariantText
                    Layout.rightMargin: 8
                }
            }
        }

        Loader {
            id: detailLoader
            objectName: "status-detail-" + row.field.id
            width: parent.width
            active: row.expanded
            visible: active
            height: item ? item.implicitHeight : 0
            sourceComponent: Column {
                id: details
                width: detailLoader.width
                padding: 12
                spacing: 8
                readonly property real contentWidth: width - leftPadding - rightPadding

                Repeater {
                    model: row.reading.details || []
                    delegate: RowLayout {
                        required property var modelData
                        width: details.contentWidth
                        spacing: 12
                        StyledText {
                            text: modelData.label
                            font.pixelSize: 12
                            color: Theme.surfaceVariantText
                            Layout.preferredWidth: 88
                            Layout.alignment: Qt.AlignTop
                            wrapMode: Text.Wrap
                        }
                        StyledText {
                            text: modelData.value
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignRight
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                        }
                    }
                }
                StyledText {
                    width: details.contentWidth
                    visible: (row.reading.details || []).length === 0 || row.reading.detail === "未配置 Swap"
                    text: row.reading.detail
                    font.pixelSize: 12
                    color: root.valueColor(row.reading)
                    wrapMode: Text.Wrap
                }
                Rectangle {
                    visible: row.hasPercent
                    width: details.contentWidth
                    height: 4
                    radius: 2
                    color: Theme.surfaceContainerHighest
                    Accessible.ignored: true
                    Rectangle {
                        width: parent.width * row.reading.percent / 100
                        height: parent.height
                        radius: 2
                        color: root.percentColor(row.reading.percent)
                    }
                }
                RowLayout {
                    visible: row.hasPercent
                    width: details.contentWidth
                    StyledText {
                        text: row.field.id === "disk" ? "磁盘已用比例" : "使用率"
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        Layout.fillWidth: true
                    }
                    StyledText {
                        text: row.percentText
                        font.pixelSize: 12
                        color: root.percentColor(row.reading.percent)
                    }
                }
                RowLayout {
                    width: details.contentWidth
                    spacing: 12
                    StyledText {
                        text: row.reading.reason ? "状态 / 原因" : "状态"
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        Layout.preferredWidth: 88
                        Layout.alignment: Qt.AlignTop
                        wrapMode: Text.Wrap
                    }
                    StyledText {
                        text: row.reading.reason ? row.reading.state + " / " + row.reading.reason : "可用（healthy）"
                        font.pixelSize: 12
                        color: root.valueColor(row.reading)
                        horizontalAlignment: Text.AlignRight
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                    }
                }
                StyledText {
                    width: details.contentWidth
                    visible: row.field.id === "wifi" || row.field.id === "lan" || row.field.id === "load" || row.field.id === "swap"
                    text: row.field.id === "load" ? "系统负载是任务的平均负载，不是 CPU 使用百分比。"
                        : row.field.id === "swap" ? "Swap 是由系统配置的磁盘交换空间，供内存管理使用。"
                        : "连接状态只表示网卡链路，不代表互联网可用。"
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                    wrapMode: Text.Wrap
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: root.divider }
    }

    RowLayout {
        id: header
        width: root.innerWidth
        height: 36
        spacing: 8
        DankIcon { name: "monitoring"; size: 20; color: Theme.primary }
        StyledText {
            text: "本机状态"
            font.pixelSize: 16
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        StatusButton {
            iconName: "refresh"
            tooltipText: "刷新采样"
            onClicked: root.source.refresh()
        }
        StatusButton {
            iconName: "tune"
            tooltipText: "插件设置"
            onClicked: {
                if (root.closePopout) root.closePopout();
                PopoutService.openSettingsWithTab("plugins");
            }
        }
        StatusButton {
            iconName: "close"
            tooltipText: "关闭详情"
            onClicked: if (root.closePopout) root.closePopout()
        }
    }

    DankFlickable {
        id: scroller
        objectName: "status-scroller"
        width: root.innerWidth
        height: Math.min(contentHeight, Math.max(0, root.maximumHeight - header.height - root.spacing - root.topPadding - root.bottomPadding))
        contentHeight: body.implicitHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onContentHeightChanged: contentY = Math.min(contentY, Math.max(0, contentHeight - height))
        Accessible.role: Accessible.Pane
        Accessible.name: "本机采样详情"
        Keys.onDownPressed: contentY = Math.min(Math.max(0, contentHeight - height), contentY + 40)
        Keys.onUpPressed: contentY = Math.max(0, contentY - 40)

        Column {
            id: body
            x: 2
            width: scroller.width - 4
            Repeater {
                model: root.sections
                delegate: Column {
                    required property var modelData
                    width: body.width
                    StyledText {
                        text: parent.modelData.label
                        width: parent.width
                        height: 32
                        leftPadding: 8
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                    }
                    Repeater {
                        model: parent.modelData.fields
                        delegate: StatusRow {
                            required property var modelData
                            field: modelData
                        }
                    }
                }
            }
        }
    }
}
