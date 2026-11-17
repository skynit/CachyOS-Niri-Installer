import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    required property var setting
    required property var source
    property bool last: false
    readonly property var value: source.valueFor(setting)
    readonly property bool edited: source.changed(setting.id)
    readonly property bool writable: setting.state === "healthy" && !source.busy
    implicitHeight: Math.max(80, texts.implicitHeight + 24)
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        spacing: 12
        Rectangle {
            Layout.preferredWidth: 32
            Layout.preferredHeight: 32
            radius: 8
            color: SettingsTheme.raised
            border.color: SettingsTheme.border
            SettingsIcon { anchors.centerIn: parent; name: root.setting.icon }
        }
        ColumnLayout {
            id: texts
            Layout.fillWidth: true
            Layout.minimumWidth: 120
            spacing: 4
            SettingsText {
                Layout.fillWidth: true
                text: root.setting.label + (root.edited ? " · 待应用" : "")
                color: root.edited ? SettingsTheme.primary : SettingsTheme.text
            }
            SettingsText {
                Layout.fillWidth: true
                text: root.source.errors[root.setting.id] || (root.setting.state !== "healthy" ? root.setting.description + "\n" + root.source.readableReason(root.setting.reason) + " · " + root.setting.state + " / " + root.setting.reason : root.setting.description)
                font.pixelSize: 12
                color: source.errors[root.setting.id] ? SettingsTheme.danger : SettingsTheme.muted
            }
        }
        Loader {
            Layout.preferredWidth: root.setting.kind === "number" ? (root.width < 760 ? 204 : 264) : root.setting.kind === "duration" ? 204 : 180
            Layout.preferredHeight: 32
            enabled: root.writable
            sourceComponent: root.setting.kind === "number" ? numberControl : root.setting.kind === "duration" ? durationControl : root.setting.kind === "choice" ? choiceControl : boolControl
        }
    }
    Rectangle { visible: !root.last; x: 24; width: parent.width - 48; height: 1; anchors.bottom: parent.bottom; color: SettingsTheme.subtle }
    Component {
        id: numberControl
        RowLayout {
            spacing: 12
            Slider {
                id: slider
                Layout.fillWidth: true
                Layout.minimumWidth: 48
                Layout.preferredHeight: 32
                from: root.setting.min || 0
                to: root.setting.max
                stepSize: root.setting.step
                value: root.value === null ? Math.max(from, Math.min(to, 0)) : Number(root.value)
                live: true
                activeFocusOnTab: true
                Accessible.name: root.setting.label
                onMoved: root.source.setDraft(root.setting, Math.round(value * 100) / 100)
                background: Rectangle {
                    x: slider.leftPadding
                    y: slider.topPadding + slider.availableHeight / 2 - 1
                    width: slider.availableWidth
                    height: 3
                    color: SettingsTheme.border
                    Rectangle { width: slider.visualPosition * parent.width; height: parent.height; color: SettingsTheme.icon }
                }
                handle: Rectangle {
                    x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
                    y: slider.topPadding + slider.availableHeight / 2 - height / 2
                    width: slider.activeFocus ? 14 : 10
                    height: width
                    radius: width / 2
                    color: SettingsTheme.text
                    border.width: slider.activeFocus ? 2 : 0
                    border.color: SettingsTheme.focus
                }
            }
            SettingsField {
                id: number
                Layout.preferredWidth: root.setting.group === "dms" ? 88 : 72
                Layout.preferredHeight: 32
                placeholderText: "默认"
                horizontalAlignment: TextInput.AlignHCenter
                invalid: !!root.source.errors[root.setting.id]
                Binding {
                    target: number
                    property: "text"
                    when: !number.activeFocus && !root.source.errors[root.setting.id]
                    value: root.value === null ? "" : String(root.value)
                    restoreMode: Binding.RestoreNone
                }
                Accessible.name: root.setting.label + "，精确数值"
                onTextEdited: {
                    const n = Number(text);
                    const minimum = root.setting.min === undefined ? 0 : root.setting.min;
                    const valid = text.trim().length > 0 && isFinite(n) && n >= minimum && n <= root.setting.max && (root.setting.step < 1 || Math.floor(n) === n);
                    root.source.setError(root.setting.id, valid ? "" : "请输入 " + minimum + " 至 " + root.setting.max + (root.setting.step >= 1 ? " 之间的整数" : " 之间的数值"));
                    if (valid) root.source.setDraft(root.setting, n);
                }

            }
            SettingsButton {
                visible: root.setting.group !== "dms" && root.setting.group !== "cachyos"
                Layout.preferredWidth: 32
                iconName: "rotate-ccw"
                help: "删除显式配置，使用系统默认"
                onClicked: root.source.setDraft(root.setting, null)
            }
        }
    }
    Component {
        id: durationControl
        RowLayout {
            spacing: 8
            SettingsField {
                id: seconds
                Layout.fillWidth: true
                Layout.preferredHeight: 32
                horizontalAlignment: TextInput.AlignHCenter
                inputMethodHints: Qt.ImhDigitsOnly
                invalid: !!root.source.errors[root.setting.id]
                Accessible.name: root.setting.label + "，整数秒，0 表示关闭"
                Binding { target: seconds; property: "text"; when: !seconds.activeFocus && !root.source.errors[root.setting.id]; value: root.value === null ? "" : String(root.value); restoreMode: Binding.RestoreNone }
                onTextEdited: {
                    const n = Number(text), minimum = root.setting.min === undefined ? 0 : root.setting.min;
                    const valid = /^\d+$/.test(text) && isFinite(n) && n >= minimum && n <= root.setting.max;
                    root.source.setError(root.setting.id, valid ? "" : "请输入 " + minimum + " 至 " + root.setting.max + " 之间的整数秒");
                    if (valid) root.source.setDraft(root.setting, n);
                }
            }
            SettingsText { text: "秒"; font.pixelSize: 12; color: SettingsTheme.muted }
            SettingsText { text: root.value === 0 ? "已禁用" : root.value >= 60 ? (Math.round(root.value / 60 * 10) / 10) + " 分钟" : root.value + " 秒"; font.pixelSize: 12; color: SettingsTheme.muted; Layout.preferredWidth: 64 }
        }
    }
    Component {
        id: choiceControl
        SettingsSelect {
            model: root.setting.choices
            currentIndex: {
                const values = root.setting.choices || [];
                for (let i = 0; i < values.length; i++) if (JSON.stringify(values[i].value) === JSON.stringify(root.value)) return i;
                return -1;
            }
            Accessible.name: root.setting.label
            onActivated: index => root.source.setDraft(root.setting, root.setting.choices[index].value)
        }
    }
    Component {
        id: boolControl
        RowLayout {
            spacing: 12
            Item { Layout.fillWidth: true }
            SettingsText { text: root.value === null ? "系统默认" : root.value ? "开启" : "关闭"; font.pixelSize: 12; color: SettingsTheme.muted }
            Switch {
                id: toggle
                checked: root.value === true
                implicitWidth: 36
                implicitHeight: 32
                padding: 0
                activeFocusOnTab: true
                Accessible.name: root.setting.label + "，" + (root.value === null ? "系统默认" : checked ? "开启" : "关闭")
                onToggled: root.source.setDraft(root.setting, checked)
                indicator: Rectangle {
                    x: 0; y: 5; width: 36; height: 22; radius: 11
                    color: toggle.checked ? SettingsTheme.success : SettingsTheme.border
                    border.width: toggle.activeFocus ? 2 : 0
                    border.color: SettingsTheme.focus
                    Rectangle { x: toggle.checked ? 18 : 2; y: 3; width: 16; height: 16; radius: 8; color: "#FFFFFF" }
                }
            }
            SettingsButton {
                visible: root.setting.group !== "dms" && root.setting.group !== "cachyos"
                Layout.preferredWidth: 32
                iconName: "rotate-ccw"
                help: "删除显式配置，使用系统默认"
                onClicked: root.source.setDraft(root.setting, null)
            }
        }
    }
}
