import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Item {
    id: root

    required property var fields
    required property var values
    property bool doubleRow: false
    property real barWidth: 360
    property real textSize: 13
    property real moduleSpacing: 4
    property real verticalPadding: 2
    readonly property real contentHeight: Math.max(2, height - verticalPadding * 2)
    readonly property real rowHeight: contentHeight / (doubleRow ? 2 : 1)
    readonly property real valueSize: Math.max(1, Math.min(textSize, Math.floor(rowHeight / 1.2)))
    readonly property real labelSize: Math.max(1, valueSize - 1)
    readonly property real iconSize: Math.min(16, rowHeight)
    readonly property real sidePadding: 4
    readonly property real gap: 4
    readonly property int columnCount: Math.max(1, doubleRow ? Math.ceil(fields.length / 2) : fields.length)
    readonly property var columnLabelWidths: {
        const widths = Array(columnCount).fill(0);
        fields.forEach(function (field, index) {
            widths[index % columnCount] = Math.max(widths[index % columnCount], labelFont.advanceWidth(field.short));
        });
        return widths;
    }
    readonly property string description: fields.map(function (field) {
        const reading = values[field.id];
        return field.label + "：" + reading.value + "，" + reading.detail
            + (reading.reason ? "（" + reading.reason + "）" : "");
    }).join("\n")
    signal activated

    implicitWidth: fields.length === 0 ? 28 : barWidth
    implicitHeight: 30
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: fields.length === 0 ? "本机状态：未选择显示项目" : "本机状态：" + description
    Accessible.description: "打开本机状态详情"
    Accessible.onPressAction: activated()
    Keys.onReturnPressed: activated()
    Keys.onEnterPressed: activated()
    Keys.onSpacePressed: activated()

    function valueText(reading) {
        if (reading.value !== "--") return reading.value;
        if (reading.reason === "sample_stale" || reading.reason === "speed_sample_stale") return "已过期";
        if (reading.reason.indexOf("waiting_for_") === 0) return "等待";
        return reading.state === "unsupported" ? "不支持" : "不可用";
    }

    function valueColor(reading) {
        if (reading.tone === "danger" || reading.state === "unreachable") return Theme.error;
        if (reading.tone === "warning" || reading.state === "degraded") return Theme.warning;
        if (reading.state !== "healthy") return Theme.surfaceVariantText;
        if (reading.percent !== null && reading.percent >= 90) return Theme.error;
        if (reading.percent !== null && reading.percent >= 75) return Theme.warning;
        if (reading.tone === "success") return Theme.success;
        return Theme.surfaceText;
    }

    FontMetrics {
        id: labelFont
        font.family: Theme.fontFamily
        font.pixelSize: root.labelSize
        font.weight: Font.Normal
    }
    FontMetrics {
        id: valueFont
        font.family: Theme.fontFamily
        font.pixelSize: root.valueSize
        font.weight: Font.Medium
        font.features: ({ "tnum": 1 })
    }

    HoverHandler { id: hover }
    ToolTip.visible: hover.hovered || root.activeFocus
    ToolTip.delay: root.activeFocus ? 0 : 600
    ToolTip.text: root.fields.length === 0 ? "未选择显示项目，打开详情查看本机状态" : root.description

    GridLayout {
        id: metrics
        x: root.sidePadding
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, root.width - root.sidePadding * 2)
        columns: root.columnCount
        columnSpacing: root.moduleSpacing
        rowSpacing: 0

        Repeater {
            model: root.fields
            delegate: Item {
                id: field
                required property var modelData
                required property int index
                readonly property var reading: root.values[modelData.id]
                readonly property real labelWidth: root.columnLabelWidths[index % root.columnCount]
                readonly property real valueWidth: valueFont.advanceWidth(modelData.baseline)
                objectName: "status-strip-field-" + modelData.id
                implicitWidth: root.iconSize + labelWidth + valueWidth + root.gap * 3
                implicitHeight: root.rowHeight
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: implicitWidth
                Layout.preferredHeight: implicitHeight

                Rectangle {
                    objectName: "status-strip-divider-" + field.modelData.id
                    visible: field.index > 0 && field.index < root.columnCount
                    x: -root.moduleSpacing / 2
                    y: 2
                    width: 1
                    height: Math.max(0, root.contentHeight - 4)
                    color: Theme.withAlpha(Theme.outlineVariant, 0.55)
                    Accessible.ignored: true
                }
                DankIcon {
                    id: icon
                    objectName: "status-strip-icon-" + field.modelData.id
                    anchors.left: parent.left
                    anchors.leftMargin: root.gap
                    anchors.verticalCenter: parent.verticalCenter
                    visible: field.width >= root.iconSize + root.gap * 2
                    name: field.modelData.icon
                    size: root.iconSize
                    color: Theme.surfaceVariantText
                }
                StyledText {
                    id: label
                    objectName: "status-strip-label-" + field.modelData.id
                    x: icon.visible ? icon.x + icon.width + root.gap : root.gap
                    height: root.rowHeight
                    width: Math.min(field.labelWidth, Math.max(0, parent.width
                        - (icon.visible ? root.iconSize + root.gap : 0) - root.gap * 2))
                    text: field.modelData.short
                    font.pixelSize: root.labelSize
                    font.weight: Font.Normal
                    color: Theme.surfaceVariantText
                    wrapMode: Text.NoWrap
                }
                StyledText {
                    objectName: "status-strip-value-" + field.modelData.id
                    x: label.x + label.width + root.gap
                    anchors.verticalCenter: parent.verticalCenter
                    height: root.rowHeight
                    width: Math.max(0, parent.width - x - root.gap)
                    text: root.valueText(field.reading)
                    font.pixelSize: root.valueSize
                    font.weight: Font.Medium
                    font.features: ({ "tnum": 1 })
                    color: root.valueColor(field.reading)
                    horizontalAlignment: Text.AlignLeft
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle
                }
            }
        }
    }

    DankIcon {
        anchors.centerIn: parent
        visible: root.fields.length === 0
        name: "monitoring"
        size: Math.min(16, root.contentHeight)
        color: Theme.surfaceVariantText
    }
    Rectangle {
        anchors.fill: parent
        radius: 4
        color: "transparent"
        border.width: root.activeFocus ? 2 : 0
        border.color: Theme.primary
    }
}
