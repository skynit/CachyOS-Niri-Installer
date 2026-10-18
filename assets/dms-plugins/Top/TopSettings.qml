import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "top"

    StyledText {
        text: "面板"
        font.pixelSize: 16
        font.weight: Font.DemiBold
    }

    SliderSetting {
        settingKey: "intervalMs"
        label: "面板采样间隔"
        defaultValue: 1000
        minimum: 500
        maximum: 3000
        unit: "ms"
    }

    SelectionSetting {
        settingKey: "anchor"
        label: "默认位置"
        defaultValue: "center"
        options: [
            {
                label: "右上",
                value: "top-right"
            },
            {
                label: "左上",
                value: "top-left"
            },
            {
                label: "居中",
                value: "center"
            },
            {
                label: "右下",
                value: "bottom-right"
            }
        ]
    }

    SelectionSetting {
        settingKey: "sortBy"
        label: "应用排序"
        defaultValue: "cpu"
        options: [
            {
                label: "CPU",
                value: "cpu"
            },
            {
                label: "内存",
                value: "mem"
            }
        ]
    }

    SliderSetting {
        settingKey: "glass"
        label: "背景不透明度"
        defaultValue: 100
        minimum: 40
        maximum: 100
        unit: "%"
    }

    StyledText {
        Layout.topMargin: Theme.spacingM
        text: "内容"
        font.pixelSize: 16
        font.weight: Font.DemiBold
    }

    ToggleSetting {
        settingKey: "showProcs"
        label: "显示应用列表"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showFreq"
        label: "显示每核频率"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "groupCores"
        label: "按性能核 / 能效核分组"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "rows"
        label: "应用行数"
        defaultValue: 24
        minimum: 6
        maximum: 40
        unit: "行"
    }

    StyledText {
        Layout.topMargin: Theme.spacingM
        text: "用法"
        font.pixelSize: 16
        font.weight: Font.DemiBold
    }

    StyledText {
        Layout.fillWidth: true
        text: "Mod+BackSpace 呼出或收起面板；右键拖动移动面板，拖动右下角调整大小，点击状态栏上的百分比也能开关面板。"
        color: Theme.surfaceVariantText
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }
}
