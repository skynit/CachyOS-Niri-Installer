import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Status.js" as Status

PluginComponent {
    id: root

    readonly property real barWidth: Math.max(160, Math.min(pluginData.maxWidth || 360, (parentScreen?.width || 1600) - 64))
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
        const saved = pluginData["show_" + id];
        if (saved !== undefined)
            return saved !== false;
        const field = Status.fields.find(item => item.id === id);
        return field ? field.defaultEnabled !== false : true;
    }

    horizontalBarPill: Component {
        StatusStrip {
            fields: root.enabledFields
            values: root.readings
            doubleRow: root.doubleRow
            barWidth: root.barWidth
            textSize: root.textSize
            moduleSpacing: root.moduleSpacing
            verticalPadding: root.verticalPadding
            implicitHeight: root.widgetThickness
            onActivated: root.triggerPopout()
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

    popoutWidth: Math.min(560, (parentScreen?.width || 960) - 48)
    popoutContent: Component {
        StatusDetails {
            source: sampler
            maximumHeight: Math.max(240, Math.min(680, (root.parentScreen?.height || 800) - root.barThickness - 120))
        }
    }
    pillRightClickAction: () => PopoutService.openSettingsWithTab("plugins")
}
