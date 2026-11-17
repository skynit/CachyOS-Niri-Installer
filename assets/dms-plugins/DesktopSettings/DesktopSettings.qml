import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "desktopSettings"
    SettingsSource { id: store }
    SettingsWindow {
        id: editor
        source: store
        onNativeRequested: tab => root.openNative(tab)
    }
    Component.onCompleted: {
        store.request("snapshot", {});
    }
    function open() {
        editor.visible = true;
        editor.minimized = false;
        if (!store.loaded) store.request("snapshot", {});
    }
    function openPage(page) {
        const index = editor.pages.findIndex(item => item.id === page);
        if (index < 0) return "PAGE_NOT_FOUND";
        editor.page = index;
        root.open();
        return "PAGE_OPENED";
    }
    function openNative(tab) {
        const allowed = ["mouse_touchpad", "display_config", "keyboard", "compositor_layout", "theme", "power_sleep", "about"];
        if (allowed.indexOf(tab) < 0 || native.running) return;
        native.command = ["dms", "ipc", "call", "settings", "openWith", tab];
        native.running = true;
    }
    function setValue(key, value) {
        const setting = (store.snapshot.settings || []).find(s => s.group === "dms" && s.key === key && s.id === "dms." + key);
        if (!setting) return "SETTINGS_SET_FAILURE: unknown_setting";
        if (!SettingsData._hasLoaded || SettingsData._loading || SettingsData._parseError) return "SETTINGS_SET_FAILURE: settings_not_ready";
        if (SettingsData.isGreeterMode || SettingsData._isReadOnly || SettingsData._hasUnsavedChanges) return "SETTINGS_SET_FAILURE: settings_not_writable";
        try {
            const parsed = JSON.parse(value);
            if (typeof parsed !== typeof SettingsData[key] || (typeof parsed === "number" && !isFinite(parsed))) return "SETTINGS_SET_FAILURE: invalid_type";
            if (setting.kind === "number" || setting.kind === "duration") {
                const minimum = setting.min === undefined ? 0 : setting.min;
                if (typeof parsed !== "number" || parsed < minimum || parsed > setting.max || (setting.step >= 1 && Math.floor(parsed) !== parsed)) return "SETTINGS_SET_FAILURE: invalid_range";
            } else if (setting.kind === "bool") {
                if (typeof parsed !== "boolean") return "SETTINGS_SET_FAILURE: invalid_type";
            } else if (setting.kind === "choice") {
                if (!(setting.choices || []).some(choice => JSON.stringify(choice.value) === JSON.stringify(parsed))) return "SETTINGS_SET_FAILURE: invalid_choice";
            } else return "SETTINGS_SET_FAILURE: unsupported_kind";
            SettingsData.set(key, parsed);
            if (SettingsData._isReadOnly || SettingsData._hasUnsavedChanges) return "SETTINGS_SET_FAILURE: save_failed";
            return "SETTINGS_SET_SUCCESS";
        } catch (error) {
            return "SETTINGS_SET_FAILURE: " + String(error);
        }
    }
    function addToBar() {
        const bar = SettingsData.getEnabledBarConfigs()[0];
        if (!bar) return "BAR_UNAVAILABLE";
        for (const section of ["leftWidgets", "centerWidgets", "rightWidgets"]) {
            if ((bar[section] || []).some(widget => (typeof widget === "string" ? widget : widget.id) === root.pluginId)) return "BAR_ENTRY_PRESENT";
        }
        const widgets = JSON.parse(JSON.stringify(bar.leftWidgets || []));
        widgets.push({id: root.pluginId, enabled: true});
        SettingsData.updateBarConfig(bar.id, {leftWidgets: widgets});
        return "BAR_ENTRY_ADDED";
    }
    Process {
        id: native
        stderr: StdioCollector { id: nativeErrors }
        onExited: code => {
            if (code !== 0) {
                store.state = "unreachable";
                store.reason = "dms_settings_unavailable";
                store.message = "无法打开 DMS 设置：" + nativeErrors.text.slice(0, 400);
            }
        }
    }
    IpcHandler {
        target: "desktopSettings"
        function open(): void { root.open(); }
        function openPage(page: string): string { return root.openPage(page); }
        function close(): void { editor.closeEditor(); }
        function setValue(key: string, value: string): string { return root.setValue(key, value); }
        function powerStatus(): string {
            return JSON.stringify({enabled: IdleService.enabled, idleInhibited: SessionService.idleInhibited, externalInhibit: IdleService.externalInhibitActive, onBattery: IdleService.isOnBattery, batteryPresent: BatteryService.batteryAvailable, loginAvailable: SessionService.loginctlAvailable});
        }
        function addToBar(): string { return root.addToBar(); }
        function status(): string { return JSON.stringify({visible: editor.visible, loaded: store.loaded, state: store.state, reason: store.reason, page: editor.pageId, stale: store.stale, drafts: store.draftCount, dark: SettingsTheme.dark}); }
    }
}
