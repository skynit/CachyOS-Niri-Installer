import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    pluginId: "localTranslate"

    StyledText {
        width: parent.width
        text: "内置 CC-CEDICT 字典，完全离线查询中文、英文词条和短语。"
        wrapMode: Text.Wrap
    }

    SelectionSetting {
        settingKey: "direction"
        label: "默认翻译方向"
        defaultValue: "auto"
        options: [{
            "label": "自动识别",
            "value": "auto"
        }, {
            "label": "中文 → 英文",
            "value": "zh"
        }, {
            "label": "英文 → 中文",
            "value": "en"
        }]
    }

    ToggleSetting {
        settingKey: "showLabel"
        label: "在状态栏显示“翻译”文字"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showPinyin"
        label: "显示拼音"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoSearch"
        label: "输入后自动查询"
        description: "关闭后，按 Enter 或点击“查询”。"
        defaultValue: true
    }

}
