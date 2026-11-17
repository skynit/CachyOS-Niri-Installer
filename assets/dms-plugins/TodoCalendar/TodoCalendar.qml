import QtQuick
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "todoCalendar"
    CalendarSource { id: store }
    CalendarWindow { id: calendar; source: store }
    function open() { calendar.open(); }
    function addToBar() {
        const bar = (SettingsData.barConfigs || []).find(config => config.enabled);
        if (!bar) return "BAR_UNAVAILABLE";
        for (const section of ["leftWidgets", "centerWidgets", "rightWidgets"]) {
            if ((bar[section] || []).some(widget => (typeof widget === "string" ? widget : widget.id) === root.pluginId)) return "BAR_ENTRY_PRESENT";
        }
        const widgets = JSON.parse(JSON.stringify(bar.rightWidgets || []));
        widgets.push({id: root.pluginId, enabled: true});
        SettingsData.updateBarConfig(bar.id, {rightWidgets: widgets});
        return "BAR_ENTRY_ADDED";
    }
    IpcHandler {
        target: "todoCalendar"
        function open(): void { root.open(); }
        function openAI(): void { root.open(); calendar.openAI(); }
        function aiStatus(): string { return calendar.aiStatus(); }
        function close(): void { calendar.closeCalendar(); }
        function addToBar(): string { return root.addToBar(); }
        function status(): string { return JSON.stringify({visible: calendar.visible, loaded: store.loaded, busy: store.busy, state: store.capabilityState, reason: store.reason, stale: store.stale, month: store.month, notes: store.notes.length, drafts: calendar.drafts}); }
    }
}
