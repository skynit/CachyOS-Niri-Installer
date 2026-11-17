import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "desktopSettings"
    function open() { if (!opener.running) opener.running = true; }
    Process { id: opener; command: ["dms", "ipc", "call", "desktopSettings", "open"] }
    pillClickAction: () => root.open()
    horizontalBarPill: Component {
        Item {
            implicitWidth: root.widgetThickness
            implicitHeight: root.widgetThickness
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "打开桌面设置"
            Accessible.onPressAction: root.open()
            Keys.onReturnPressed: root.open()
            Keys.onSpacePressed: root.open()
            DankIcon { anchors.centerIn: parent; name: "tune"; size: Math.min(20, root.widgetThickness - 4); color: Theme.surfaceText }
            HoverHandler {
                onHoveredChanged: {
                    if (hovered) tooltip.show("桌面设置", parent, 0, 0);
                    else tooltip.hide();
                }
            }
            DankTooltipV2 { id: tooltip }
            Rectangle { anchors.centerIn: parent; width: 24; height: 24; color: "transparent"; radius: 4; border.width: parent.activeFocus ? 2 : 0; border.color: Theme.primary }
        }
    }
    verticalBarPill: horizontalBarPill
}
