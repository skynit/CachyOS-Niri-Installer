import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Column {
    id: root
    objectName: "ai-settings-form"
    required property var source
    property string selectedAction: "explain"
    property bool promptDirty: false
    property bool promptPending: false
    property bool loadingPrompt: false
    readonly property var state: source.state
    readonly property var actions: state.actions || []
    spacing: 12

    function loadPrompt() {
        if (promptDirty)
            return;
        let entry = actions.find(function (row) { return row.id === selectedAction; });
        if (!entry && selectedAction.length > 0 && actions.length > 0) {
            selectedAction = actions[0].id;
            entry = actions[0];
        }
        loadingPrompt = true;
        actionId.text = selectedAction;
        promptText.text = entry ? entry.prompt : "";
        loadingPrompt = false;
    }

    onActionsChanged: loadPrompt()
    Connections {
        target: root.source
        function onOperationSucceeded(action) {
            if (action === "prompt-set" || action === "prompt-reset") {
                root.promptDirty = false;
                root.promptPending = true;
            }
        }
        function onStateChanged() {
            if (root.promptPending) {
                root.promptPending = false;
                root.loadPrompt();
            }
        }
    }

    StyledText {
        width: parent.width
        visible: !root.source.loaded
        text: root.source.busy ? "正在读取 AI 设置…" : "AI 设置未加载"
        color: Theme.surfaceVariantText
    }

    Column {
        width: parent.width
        visible: root.source.loaded
        spacing: 12
        enabled: !root.source.busy

        DankDropdown {
            width: parent.width
            text: "默认 Agent"
            dropdownWidth: Math.min(220, root.width * 0.52)
            options: (root.state.agents || []).filter(function (row) { return row.installed; }).map(function (row) { return row.id; })
            currentValue: root.state.defaultAgent || "未选择"
            emptyText: "没有已安装的 Agent"
            onValueChanged: value => root.source.execute(["cachyos-default-agent", value])
        }

        DankDropdown {
            width: parent.width
            text: "任务结束通知"
            dropdownWidth: Math.min(220, root.width * 0.52)
            options: ["长任务或失败时", "每次结束", "关闭"]
            currentValue: options[Math.max(0, ["auto", "always", "off"].indexOf(root.state.notifyMode))]
            onValueChanged: value => root.source.setValue("notify-mode", ["auto", "always", "off"][options.indexOf(value)])
        }

        StyledText { text: "后台服务"; font.pixelSize: 14; font.weight: Font.DemiBold }
        Repeater {
            model: root.state.services || []
            delegate: DankToggle {
                required property var modelData
                width: parent.width
                text: modelData.label
                description: modelData.active ? "运行中" : (modelData.enabled ? "已开启 · 未运行" : "已关闭")
                checked: modelData.enabled
                onToggled: checked => root.source.execute(["cachyos-ai-settings", "service", modelData.key, checked ? "on" : "off"])
            }
        }

        Repeater {
            model: root.state.groups || []
            delegate: Column {
                required property var modelData
                width: parent.width
                spacing: 8
                StyledText { text: modelData.title; font.pixelSize: 14; font.weight: Font.DemiBold }
                Repeater {
                    model: modelData.fields
                    delegate: Column {
                        id: field
                        required property var modelData
                        width: parent.width
                        spacing: 4
                        readonly property var spec: modelData

                        DankToggle {
                            visible: field.spec.kind === "toggle"
                            width: parent.width
                            height: visible ? implicitHeight : 0
                            // DankToggle defines height rather than implicitHeight.
                            implicitHeight: 48
                            text: field.spec.label
                            checked: field.spec.value === "1"
                            onToggled: checked => root.source.setValue(field.spec.key, checked ? "1" : "0")
                        }
                        DankDropdown {
                            visible: field.spec.kind === "choice"
                            width: parent.width
                            height: visible ? 52 : 0
                            text: field.spec.label
                            dropdownWidth: Math.min(220, root.width * 0.52)
                            options: field.spec.key === "CACHYOS_ASK_SESSION" ? ["当天复用会话", "每次新建会话"] : field.spec.options
                            currentValue: options[Math.max(0, field.spec.options.indexOf(field.spec.value))] || ""
                            onValueChanged: value => root.source.setValue(field.spec.key, field.spec.options[options.indexOf(value)])
                        }
                        StyledText {
                            visible: field.spec.kind === "number" || field.spec.kind === "text"
                            width: parent.width
                            text: field.spec.label
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            visible: field.spec.kind === "number" || field.spec.kind === "text"
                            width: parent.width
                            DankTextField {
                                id: valueInput
                                Layout.fillWidth: true
                                text: field.spec.value
                                maximumLength: 512
                                Accessible.name: field.spec.label
                                onAccepted: root.source.setValue(field.spec.key, text)
                            }
                            DankActionButton {
                                iconName: "save"
                                tooltipText: "保存" + field.spec.label
                                enabled: valueInput.text !== field.spec.value
                                onClicked: root.source.setValue(field.spec.key, valueInput.text)
                            }
                        }
                    }
                }
            }
        }

        RowLayout {
            width: parent.width
            StyledText { text: "动作与提示词"; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true }
            DankActionButton {
                iconName: "add"
                tooltipText: "新增动作"
                enabled: !root.promptDirty
                onClicked: {
                    root.selectedAction = "";
                    root.loadPrompt();
                    actionId.forceActiveFocus();
                }
            }
        }
        DankDropdown {
            width: parent.width
            text: "动作"
            dropdownWidth: Math.min(220, root.width * 0.52)
            enabled: !root.promptDirty
            options: root.actions.map(function (row) { return row.id; })
            currentValue: root.selectedAction
            onValueChanged: value => {
                root.selectedAction = value;
                root.loadPrompt();
            }
        }
        DankTextField {
            id: actionId
            objectName: "ask-action-id"
            width: parent.width
            labelText: "动作名"
            maximumLength: 64
            Accessible.name: "动作名"
            onTextEdited: if (!root.loadingPrompt) root.promptDirty = true
        }
        DankTextEdit {
            id: promptText
            objectName: "ask-prompt"
            width: parent.width
            height: 150
            font.pixelSize: 14
            topPadding: 12
            bottomPadding: 12
            cornerRadius: 6
            backgroundColor: Theme.surfaceContainerHigh
            normalBorderColor: Theme.outline
            focusedBorderColor: Theme.primary
            textColor: Theme.surfaceText
            Accessible.name: "提示词"
            onTextEdited: if (getActiveFocus() && !root.loadingPrompt) root.promptDirty = true
        }
        RowLayout {
            width: parent.width
            StyledText {
                Layout.fillWidth: true
                text: root.promptDirty ? "有未保存的修改" : ""
                font.pixelSize: 12
                color: Theme.warning
            }
            DankActionButton {
                iconName: "undo"
                tooltipText: "放弃本次编辑"
                enabled: root.promptDirty
                onClicked: { root.promptDirty = false; root.loadPrompt(); }
            }
            DankActionButton {
                iconName: "restart_alt"
                tooltipText: "恢复内置提示词 / 删除自定义动作"
                enabled: !root.promptDirty && root.selectedAction.length > 0
                onClicked: root.source.execute(["cachyos-ai-settings", "prompt-reset", root.selectedAction])
            }
            DankActionButton {
                iconName: "save"
                tooltipText: "保存动作与提示词"
                enabled: root.promptDirty && actionId.text.trim().length > 0 && promptText.text.trim().length > 0
                onClicked: {
                    root.selectedAction = actionId.text.trim();
                    root.source.execute(["cachyos-ai-settings", "prompt-set", root.selectedAction, promptText.text.replace(/\r?\n/g, " ")]);
                }
            }
        }

        StyledText { text: "崩溃 / OOM 通知静音名单"; font.pixelSize: 14; font.weight: Font.DemiBold }
        Repeater {
            model: root.state.mutedPrograms || []
            delegate: RowLayout {
                required property string modelData
                width: parent.width
                StyledText { Layout.fillWidth: true; text: modelData; elide: Text.ElideRight }
                DankActionButton {
                    iconName: "volume_up"
                    tooltipText: "解除 " + modelData + " 的静音"
                    onClicked: root.source.execute(["cachyos-crash-mute", modelData, "off"])
                }
            }
        }
        RowLayout {
            width: parent.width
            DankTextField {
                id: muteProgram
                Layout.fillWidth: true
                labelText: "静音程序名"
                Accessible.name: "静音程序名"
            }
            DankActionButton {
                iconName: "volume_off"
                tooltipText: "将程序加入静音名单"
                enabled: muteProgram.text.trim().length > 0
                onClicked: root.source.execute(["cachyos-crash-mute", muteProgram.text.trim()])
            }
        }

        StyledText { text: "维护"; font.pixelSize: 14; font.weight: Font.DemiBold }
        Flow {
            width: parent.width
            spacing: 8
            DankButton {
                text: "同步主题"
                onClicked: root.source.execute(["cachyos-agent-theme-sync", "--quiet"])
            }
            DankButton {
                text: "链接系统技能"
                onClicked: root.source.execute(["cachyos-agent-skills", "--quiet"])
            }
            DankButton {
                text: "应用 CC Switch 的 Codex 配置"
                onClicked: root.source.execute(["cachyos-ai-config-sync", "sync"])
            }
        }
    }
}
