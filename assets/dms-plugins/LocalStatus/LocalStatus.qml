import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Status.js" as Status

PluginComponent {
    id: root

    readonly property real widthLimit: Math.max(160, Math.min(pluginData.maxWidth || 1200, (parentScreen?.width || 1600) - 64))
    readonly property real textSize: Theme.barTextSize(barThickness, barConfig?.fontScale, barConfig?.maximizeWidgetText)
    readonly property real moduleSpacing: Math.max(0, Math.min(32, pluginData.moduleSpacing ?? 4))
    readonly property real verticalPadding: Math.max(0, Math.min(6, pluginData.verticalPadding ?? 2))
    readonly property bool doubleRow: pluginData.layoutMode === "double"
    readonly property var enabledFields: Status.fields.filter(field => root.fieldEnabled(field.id))
    readonly property var readings: sampler.values

    StatusSource {
        id: sampler
        settings: root.pluginData
    }

    function fieldEnabled(id) {
        return pluginData["show_" + id] !== false;
    }

    function valueColor(reading) {
        if (reading.tone === "success")
            return Theme.success;
        if (reading.tone === "warning")
            return Theme.warning;
        if (reading.state !== "healthy")
            return Theme.surfaceVariantText;
        if (reading.percent !== null && reading.percent >= 90)
            return Theme.error;
        return Theme.widgetTextColor;
    }

    horizontalBarPill: Component {
        Item {
            id: strip
            readonly property real contentHeight: Math.max(2, root.widgetThickness - root.verticalPadding * 2)
            readonly property real rowHeight: contentHeight / (root.doubleRow ? 2 : 1)
            readonly property real fontSize: Math.max(1, Math.min(root.textSize, Math.floor(rowHeight / 1.2)))
            readonly property real sidePadding: 4
            implicitWidth: Math.min(Math.max(20, metrics.implicitWidth + sidePadding * 2), root.widthLimit)
            implicitHeight: root.widgetThickness
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "本机状态：" + root.enabledFields.map(field => field.label + " " + root.readings[field.id].value).join("，")
            Accessible.onPressAction: root.triggerPopout()
            Keys.onReturnPressed: root.triggerPopout()
            Keys.onSpacePressed: root.triggerPopout()

            Item {
                anchors.fill: parent
                anchors.leftMargin: strip.sidePadding
                anchors.rightMargin: strip.sidePadding
                anchors.topMargin: root.verticalPadding
                anchors.bottomMargin: root.verticalPadding
                clip: true
                GridLayout {
                    id: metrics
                    anchors.verticalCenter: parent.verticalCenter
                    columns: Math.max(1, root.doubleRow ? Math.ceil(root.enabledFields.length / 2) : root.enabledFields.length)
                    columnSpacing: root.moduleSpacing
                    rowSpacing: 0
                    Repeater {
                        model: root.enabledFields
                        delegate: Row {
                            id: field
                            required property var modelData
                            readonly property var reading: root.readings[modelData.id]
                            Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                            spacing: 4
                            height: strip.rowHeight
                            DankIcon {
                                name: field.modelData.icon
                                size: Math.min(16, strip.rowHeight)
                                color: root.valueColor(field.reading)
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText {
                                height: strip.rowHeight
                                visible: text.length > 0
                                text: field.modelData.short
                                font.pixelSize: strip.fontSize
                                fontSizeMode: Text.VerticalFit
                                minimumPixelSize: 1
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledTextMetrics {
                                id: baseline
                                text: field.modelData.id === "time" ? (root.pluginData.showDate ? "8888-88-88 " : "") + (root.pluginData.showSeconds === false ? "88:88" : "88:88:88") : field.modelData.baseline
                                font.pixelSize: strip.fontSize
                            }
                            StyledText {
                                height: strip.rowHeight
                                width: baseline.width
                                text: field.reading.value
                                font.pixelSize: strip.fontSize
                                fontSizeMode: Text.VerticalFit
                                minimumPixelSize: 1
                                color: root.valueColor(field.reading)
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }
            }
            DankIcon {
                anchors.centerIn: parent
                visible: root.enabledFields.length === 0
                name: "monitoring"
                size: Math.min(18, strip.contentHeight)
                color: Theme.surfaceVariantText
            }
            Rectangle {
                anchors.fill: parent
                anchors.margins: -4
                radius: 6
                color: "transparent"
                border.width: strip.activeFocus ? 2 : 0
                border.color: Theme.primary
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: 20
            implicitHeight: 24
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "本机状态详情"
            Accessible.onPressAction: root.triggerPopout()
            Keys.onReturnPressed: root.triggerPopout()
            Keys.onSpacePressed: root.triggerPopout()
            DankIcon {
                anchors.centerIn: parent
                name: "monitoring"
                size: 20
                color: Theme.primary
            }
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: 4
                border.color: Theme.primary
                border.width: parent.activeFocus ? 2 : 0
            }
        }
    }

    popoutWidth: Math.min(520, (parentScreen?.width || 960) - 48)
    popoutContent: Component {
        StatusDetails {
            source: sampler
            maximumHeight: Math.max(240, Math.min(560, (root.parentScreen?.height || 800) - root.barThickness - 160))
        }
    }
    pillRightClickAction: () => PopoutService.openSettingsWithTab("plugins")
}
