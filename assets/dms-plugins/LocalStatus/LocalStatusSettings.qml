import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "Status.js" as Status

PluginSettings {
    id: root
    pluginId: "localStatus"

    StyledText {
        text: "显示项目"
        font.pixelSize: 16
        font.weight: Font.DemiBold
    }
    Repeater {
        model: Status.fields
        delegate: ToggleSetting {
            id: toggle
            required property var modelData
            settingKey: "show_" + modelData.id
            label: modelData.label
            defaultValue: true
            Connections {
                target: root.pluginService
                function onPluginDataChanged(changedPluginId) {
                    if (changedPluginId === root.pluginId)
                        toggle.loadValue();
                }
            }
        }
    }
    ToggleSetting {
        settingKey: "showDate"
        label: "显示日期"
        defaultValue: false
    }
    ToggleSetting {
        settingKey: "showSeconds"
        label: "显示秒数"
        defaultValue: true
    }
    StringSetting {
        settingKey: "mount"
        label: "磁盘挂载点"
        defaultValue: "/"
        placeholder: "/"
    }
    SelectionSetting {
        settingKey: "ipSource"
        label: "IP 来源"
        defaultValue: "auto"
        options: [
            {
                label: "自动",
                value: "auto"
            },
            {
                label: "无线网卡",
                value: "wifi"
            },
            {
                label: "有线网卡",
                value: "lan"
            }
        ]
    }
    StringSetting {
        settingKey: "wifiInterface"
        label: "无线网卡"
        defaultValue: ""
        placeholder: "自动"
    }
    StringSetting {
        settingKey: "lanInterface"
        label: "有线网卡"
        defaultValue: ""
        placeholder: "自动"
    }
    SelectionSetting {
        settingKey: "layoutMode"
        label: "显示布局"
        defaultValue: "single"
        options: [
            {
                label: "单行",
                value: "single"
            },
            {
                label: "双行",
                value: "double"
            }
        ]
    }
    SliderSetting {
        settingKey: "moduleSpacing"
        label: "模块间距"
        defaultValue: 4
        minimum: 0
        maximum: 32
        unit: "px"
    }
    SliderSetting {
        settingKey: "verticalPadding"
        label: "上下内边距"
        defaultValue: 2
        minimum: 0
        maximum: 6
        unit: "px"
    }
    SliderSetting {
        settingKey: "maxWidth"
        label: "状态条宽度上限"
        defaultValue: 1200
        minimum: 160
        maximum: 1600
        unit: "px"
    }
    SliderSetting {
        settingKey: "networkInterval"
        label: "网络采样间隔"
        defaultValue: 5
        minimum: 3
        maximum: 60
        unit: "s"
    }
}
