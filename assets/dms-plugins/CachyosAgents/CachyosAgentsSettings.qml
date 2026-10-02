import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "cachyosAgents"

    StyledText {
        text: "显示的 agent"
        font.pixelSize: 16
        font.weight: Font.DemiBold
    }
    ToggleSetting {
        settingKey: "show_claude"
        label: "Claude Code"
        defaultValue: true
    }
    ToggleSetting {
        settingKey: "show_codex"
        label: "Codex"
        defaultValue: true
    }
    ToggleSetting {
        settingKey: "show_opencode"
        label: "OpenCode"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "show_dsh"
        label: "DSH（DeepSeek Harness）"
        defaultValue: true
    }

    StyledText {
        text: "状态条显示"
        font.pixelSize: 16
        font.weight: Font.DemiBold
    }
    SelectionSetting {
        settingKey: "barAgent"
        label: "状态栏统计范围"
        defaultValue: "auto"
        options: [
            { label: "全部 agent 合计", value: "auto" },
            { label: "只看 Claude Code", value: "claude" },
            { label: "只看 Codex", value: "codex" },
            { label: "只看 OpenCode", value: "opencode" },
            { label: "只看 DSH", value: "dsh" }
        ]
    }

    SelectionSetting {
        settingKey: "displayMode"
        label: "状态栏显示"
        defaultValue: "bare"
        options: [
            { label: "只显示数字（默认，不带日期）", value: "bare" },
            { label: "今天（无数据时显示最近一天）", value: "today" },
            { label: "近 7 天", value: "week" },
            { label: "累计 token", value: "total" }
        ]
    }
    SelectionSetting {
        settingKey: "refreshSeconds"
        label: "自动刷新间隔"
        defaultValue: "900"
        options: [
            { label: "5 分钟", value: "300" },
            { label: "15 分钟", value: "900" },
            { label: "1 小时", value: "3600" }
        ]
    }
    SelectionSetting {
        settingKey: "maxModels"
        label: "每个 agent 显示的模型数"
        defaultValue: "3"
        options: [
            { label: "1 个", value: "1" },
            { label: "3 个", value: "3" },
            { label: "5 个", value: "5" },
            { label: "全部", value: "50" }
        ]
    }
}
