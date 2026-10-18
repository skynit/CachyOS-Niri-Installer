import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Column {
    id: root
    required property var options
    required property var saveOption
    property string error: ""
    spacing: 12

    StyledText {
        width: parent.width
        visible: root.error.length > 0
        text: root.error
        color: Theme.warning
        font.pixelSize: 12
        wrapMode: Text.WordWrap
    }

    StyledText { text: "屏幕与唤醒"; font.pixelSize: 14; font.weight: Font.DemiBold }
    DankToggle {
        width: parent.width
        text: "关闭手机实体屏幕 (-S)"
        checked: root.options.screenOff === true
        onToggled: checked => root.saveOption("screenOff", checked)
    }
    DankToggle {
        width: parent.width
        text: "接电时保持唤醒 (-w)"
        checked: root.options.stayAwake === true
        onToggled: checked => root.saveOption("stayAwake", checked)
    }
    DankToggle {
        width: parent.width
        text: "持续模拟用户活动"
        checked: root.options.keepActive === true
        onToggled: checked => root.saveOption("keepActive", checked)
    }
    DankToggle {
        width: parent.width
        text: "启动时不主动点亮屏幕"
        checked: root.options.noPowerOn === true
        onToggled: checked => root.saveOption("noPowerOn", checked)
    }

    Rectangle { width: parent.width; height: 1; color: Theme.outlineMedium }
    StyledText { text: "声音"; font.pixelSize: 14; font.weight: Font.DemiBold }
    DankDropdown {
        width: parent.width
        text: "音频传输"
        dropdownWidth: Math.min(230, root.width * 0.56)
        options: ["默认", "手机与电脑同时播放", "不传输声音"]
        currentValue: options[["default", "duplicate", "none"].indexOf(root.options.audio || "default")] || options[0]
        onValueChanged: value => root.saveOption("audio", ["default", "duplicate", "none"][options.indexOf(value)])
    }
    StyledText {
        width: parent.width
        text: "同时播放要求 Android 13 或更高版本，部分应用不允许捕获声音。"
        font.pixelSize: 12
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle { width: parent.width; height: 1; color: Theme.outlineMedium }
    StyledText { text: "录制"; font.pixelSize: 14; font.weight: Font.DemiBold }
    DankToggle {
        width: parent.width
        text: "连接时录制到 ~/Videos"
        checked: root.options.record === true
        onToggled: checked => root.saveOption("record", checked)
    }
    RowLayout {
        width: parent.width
        spacing: 8
        DankTextField {
            id: recordName
            Layout.fillWidth: true
            labelText: "文件名 (.mp4/.mkv)"
            text: root.options.recordName || "phone.mp4"
            Accessible.name: "录制文件名"
            onAccepted: root.saveOption("recordName", text.trim())
        }
        DankActionButton {
            iconName: "save"
            tooltipText: "保存录制文件名"
            enabled: recordName.text.trim() !== (root.options.recordName || "phone.mp4")
            onClicked: root.saveOption("recordName", recordName.text.trim())
        }
    }
    DankDropdown {
        width: parent.width
        text: "录制时长"
        dropdownWidth: Math.min(230, root.width * 0.56)
        options: ["不限时", "10 分钟", "30 分钟", "60 分钟"]
        currentValue: options[["0", "600", "1800", "3600"].indexOf(String(root.options.timeLimit || "0"))] || options[0]
        onValueChanged: value => root.saveOption("timeLimit", ["0", "600", "1800", "3600"][options.indexOf(value)])
    }
    StyledText {
        width: parent.width
        text: "时限只在录制时生效，结束时投屏也会停止。"
        font.pixelSize: 12
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle { width: parent.width; height: 1; color: Theme.outlineMedium }
    StyledText { text: "输入"; font.pixelSize: 14; font.weight: Font.DemiBold }
    DankToggle {
        width: parent.width
        text: "将电脑键盘作为实体键盘 (-K)"
        checked: root.options.keyboardUhid === true
        onToggled: checked => root.saveOption("keyboardUhid", checked)
    }
}
