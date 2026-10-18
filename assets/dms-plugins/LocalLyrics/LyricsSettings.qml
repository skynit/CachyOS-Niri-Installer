import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "localLyrics"

    StyledText {
        width: parent.width
        text: "读取音乐文件的内嵌歌词并跟随播放进度。termusic 可通过本地媒体库定位歌曲，无需外部 LRC 文件。"
        wrapMode: Text.Wrap
    }

    ToggleSetting {
        settingKey: "doubleRow"
        label: "双行显示"
        description: "第一行当前句，第二行下一句。关闭后只显示当前句。"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "width"
        label: "状态栏歌词宽度"
        defaultValue: 320
        minimum: 120
        maximum: 800
        unit: "px"
    }

    SliderSetting {
        id: offsetSlider
        settingKey: "offset"
        label: "歌词时间偏移"
        description: "正数让歌词更晚显示，负数让歌词提前显示。"
        defaultValue: 0
        minimum: -10000
        maximum: 10000
        unit: "ms"
    }
    DankButton {
        objectName: "resetOffset"
        text: "复原"
        buttonHeight: 32
        horizontalPadding: 12
        enabled: root.hasPermission && offsetSlider.value !== 0
        Accessible.role: Accessible.Button
        Accessible.name: "将歌词时间偏移复原为 0 毫秒"
        onClicked: {
            root.saveValue("offset", 0);
            offsetSlider.loadValue();
        }
    }
}
