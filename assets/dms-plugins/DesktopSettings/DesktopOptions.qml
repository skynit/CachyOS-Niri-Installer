import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "desktopSettings"
    StyledText {
        width: parent.width
        text: "桌面设置使用独立窗口。关闭窗口会保留本次 DMS 进程中的草稿；只有点击应用才会写入设置。"
        wrapMode: Text.Wrap
        color: Theme.surfaceVariantText
    }
    SettingsButton {
        text: "打开桌面设置"
        enabled: !opener.running
        onClicked: opener.running = true
    }
    Process { id: opener; command: ["dms", "ipc", "call", "desktopSettings", "open"] }
}
