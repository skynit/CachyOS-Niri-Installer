import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "todoCalendar"
    function open() { if (!opener.running) opener.running = true; }
    pillClickAction: () => root.open()
    Process { id: opener; command: ["dms", "ipc", "call", "todoCalendar", "open"] }
    horizontalBarPill: Component {
        Item {
            implicitWidth: root.widgetThickness
            implicitHeight: root.widgetThickness
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "打开待办日历"
            Accessible.onPressAction: root.open()
            Keys.onReturnPressed: root.open()
            Keys.onSpacePressed: root.open()
            DankIcon { anchors.centerIn: parent; name: "calendar_month"; size: Math.min(20, root.widgetThickness - 4); color: Theme.surfaceText }
            HoverHandler { onHoveredChanged: { if (hovered) tooltip.show("待办日历", parent, 0, 0); else tooltip.hide(); } }
            DankTooltipV2 { id: tooltip }
            Rectangle { anchors.centerIn: parent; width: 24; height: 24; color: "transparent"; radius: 4; border.width: parent.activeFocus ? 2 : 0; border.color: Theme.primary }
        }
    }
    verticalBarPill: horizontalBarPill
}
