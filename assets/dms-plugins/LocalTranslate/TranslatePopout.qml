import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Controls.Basic as Basic
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Item {
    id: root

    property var settings: ({
    })
    property var parentPopout: null
    property var closePopout: null
    property real availableHeight: 420
    readonly property real maximumHeight: Math.max(0, Math.min(420, availableHeight))
    property string direction: settings.direction ?? "auto"
    property alias query: input.text
    readonly property alias lookup: lookup
    property string copied: ""
    readonly property string status: lookup.result.status
    readonly property var entries: lookup.result.entries ?? []
    readonly property var suggestions: lookup.result.suggestions ?? []
    readonly property bool autoSearch: settings.autoSearch ?? true

    function submit() {
        if (input.inputMethodComposing)
            return ;

        delay.stop();
        copied = "";
        lookup.search(input.text, direction);
    }

    function edited() {
        delay.stop();
        copied = "";
        lookup.clear();
        if (autoSearch && !input.inputMethodComposing && input.text.trim())
            delay.restart();

    }

    function copyEntry(text) {
        copyBuffer.text = text;
        copyBuffer.selectAll();
        copyBuffer.copy();
        copyBuffer.clear();
        copied = "已复制译文";
        copiedTimer.restart();
    }

    function reveal(item) {
        const top = item.mapToItem(scroll.contentItem, 0, 0).y;
        if (top < scroll.contentY)
            scroll.contentY = top;
        else if (top + item.height > scroll.contentY + scroll.height)
            scroll.contentY = top + item.height - scroll.height;
    }

    implicitHeight: Math.min(maximumHeight, layout.implicitHeight + 24)
    onDirectionChanged: edited()
    onAutoSearchChanged: edited()
    Component.onCompleted: focusTimer.start()

    Connections {
        function onShouldBeVisibleChanged() {
            if (root.parentPopout.shouldBeVisible)
                focusTimer.restart();

        }

        target: root.parentPopout
    }

    Timer {
        id: focusTimer

        interval: 60
        onTriggered: input.forceActiveFocus()
    }

    Timer {
        id: delay

        interval: 300
        onTriggered: root.submit()
    }

    Timer {
        id: copiedTimer

        interval: 2000
        onTriggered: root.copied = ""
    }

    Lookup {
        id: lookup
    }

    TextEdit {
        id: copyBuffer

        visible: false
    }

    component ActionButton: Basic.Button {
        id: button
        property string iconName: ""
        property bool primary: false
        readonly property color textColor: primary && enabled ? Theme.primaryText : Theme.surfaceText
        implicitWidth: Math.max(44, contentItem.implicitWidth + 16)
        implicitHeight: 28
        leftPadding: 8
        rightPadding: 8
        topPadding: 4
        bottomPadding: 4
        hoverEnabled: true
        focusPolicy: Qt.StrongFocus
        Accessible.role: Accessible.Button
        Accessible.name: text
        Keys.onReturnPressed: if (enabled) clicked()
        Keys.onEnterPressed: if (enabled) clicked()
        HoverHandler { cursorShape: button.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor }
        contentItem: RowLayout {
            spacing: 4
            opacity: button.enabled ? 1 : 0.6
            DankIcon {
                visible: button.iconName.length > 0
                name: button.iconName
                size: 16
                color: button.textColor
            }
            StyledText {
                text: button.text
                font.pixelSize: 12
                color: button.textColor
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.NoWrap
                Layout.fillWidth: true
            }
        }
        background: Rectangle {
            radius: 4
            color: button.primary && button.enabled ? Theme.primary
                : (button.highlighted || button.hovered || button.down ? Theme.surfaceContainerHigh : "transparent")
            border.width: button.activeFocus ? 2 : 0
            border.color: Theme.primary
        }
    }

    ColumnLayout {
        id: layout
        x: 12
        y: 12
        width: root.width - 24
        spacing: 8

        RowLayout {
            id: heading
            objectName: "translate-heading"
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            spacing: 8
            DankIcon {
                name: "translate"
                size: 18
                color: Theme.primary
            }
            StyledText {
                text: "离线翻译"
                font.pixelSize: 14
                font.weight: Font.DemiBold
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.minimumWidth: 0
            }
            Rectangle {
                implicitWidth: directions.implicitWidth + 8
                implicitHeight: 28
                radius: 4
                color: Theme.surfaceContainerLow
                border.width: 1
                border.color: Theme.withAlpha(Theme.outline, 0.18)
                Row {
                    id: directions
                    anchors.centerIn: parent
                    Repeater {
                        model: [
                            {label: "自动", value: "auto"},
                            {label: "中 → 英", value: "zh"},
                            {label: "英 → 中", value: "en"}
                        ]
                        delegate: ActionButton {
                            required property var modelData
                            objectName: "translate-direction-" + modelData.value
                            text: modelData.label
                            width: modelData.value === "auto" ? 48 : 64
                            height: 24
                            highlighted: root.direction === modelData.value
                            Accessible.role: Accessible.RadioButton
                            Accessible.checked: highlighted
                            onClicked: root.direction = modelData.value
                        }
                    }
                }
            }
            DankActionButton {
                objectName: "translate-close"
                visible: root.closePopout !== null
                iconName: "close"
                iconSize: 16
                buttonSize: 28
                radius: 4
                tooltipText: "关闭离线翻译"
                Accessible.role: Accessible.Button
                Accessible.name: tooltipText
                onClicked: root.closePopout()
            }
        }

        Basic.TextField {
            id: input

            objectName: "queryInput"
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            placeholderText: "输入中文或英文词条、短语"
            maximumLength: 200
            font.family: Theme.fontFamily
            font.pixelSize: 14
            color: Theme.surfaceText
            placeholderTextColor: Theme.surfaceVariantText
            selectionColor: Theme.primary
            selectedTextColor: Theme.primaryText
            leftPadding: 12
            rightPadding: 12
            selectByMouse: true
            Accessible.name: "要翻译的中文或英文词条"
            onTextChanged: root.edited()
            onInputMethodComposingChanged: root.edited()
            onAccepted: root.submit()

            background: Rectangle {
                radius: 4
                color: Theme.surfaceContainerHigh
                border.width: input.activeFocus ? 2 : 1
                border.color: input.activeFocus ? Theme.primary : Theme.withAlpha(Theme.outline, 0.4)
            }

        }

        RowLayout {
            id: actions
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            spacing: 8
            ActionButton {
                objectName: "translate-query"
                text: root.status === "error" ? "重试" : "查询"
                iconName: "search"
                primary: true
                enabled: input.text.trim().length > 0 && !input.inputMethodComposing
                onClicked: root.submit()
            }
            ActionButton {
                objectName: "translate-paste"
                text: "粘贴"
                iconName: "content_paste"
                Accessible.name: "从剪贴板粘贴"
                onClicked: {
                    input.forceActiveFocus();
                    input.paste();
                }
            }
            ActionButton {
                objectName: "translate-clear"
                text: "清空"
                enabled: input.text.length > 0
                Accessible.name: "清空输入和结果"
                onClicked: {
                    input.clear();
                    input.forceActiveFocus();
                }
            }
            Item { Layout.fillWidth: true }
            StyledText {
                text: input.text.length + " / 200"
                font.pixelSize: 12
                color: Theme.surfaceVariantText
            }
        }

        Rectangle {
            id: separator
            Layout.fillWidth: true
            implicitHeight: 1
            color: Theme.withAlpha(Theme.outline, 0.18)
        }

        DankFlickable {
            id: scroll

            objectName: "resultScroll"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(0, Math.min(contentHeight, root.maximumHeight
                - 24 - heading.height - input.height - actions.height - separator.height - layout.spacing * 4
                - (copiedLabel.visible ? copiedLabel.implicitHeight + layout.spacing : 0)))
            contentWidth: width
            contentHeight: resultsColumn.implicitHeight
            clip: true
            activeFocusOnTab: true
            Accessible.name: "翻译结果"
            Keys.onPressed: (event) => {
                let offset = 0;
                if (event.key === Qt.Key_Down)
                    offset = 40;
                else if (event.key === Qt.Key_Up)
                    offset = -40;
                else if (event.key === Qt.Key_PageDown)
                    offset = height;
                else if (event.key === Qt.Key_PageUp)
                    offset = -height;
                else
                    return ;
                contentY = Math.max(0, Math.min(Math.max(0, contentHeight - height), contentY + offset));
                event.accepted = true;
            }
            onContentHeightChanged: contentY = 0

            Column {
                id: resultsColumn

                x: 2
                width: scroll.width - 4
                topPadding: 4
                bottomPadding: 4
                spacing: 8

                StyledText {
                    width: parent.width
                    text: {
                        if (root.status === "loading")
                            return "正在查询…";

                        if (root.status === "ready")
                            return (lookup.result.direction === "zh" ? "中文 → 英文" : "英文 → 中文") + " · " + root.entries.length + " 个词条";

                        if (root.status === "idle")
                            return input.text.trim() ? "按 Enter 或点击“查询”。" : "输入中文或英文词条，离线查询。";

                        return lookup.result.message ?? "查询失败，请重试。";
                    }
                    wrapMode: Text.Wrap
                    font.pixelSize: 13
                    color: root.status === "error" ? Theme.error : Theme.surfaceVariantText
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }

                Repeater {
                    model: root.entries

                    delegate: Column {
                        required property var modelData
                        required property int index

                        width: resultsColumn.width
                        spacing: 4

                        RowLayout {
                            width: parent.width
                            spacing: 8

                            StyledText {
                                Layout.fillWidth: true
                                text: modelData.simplified
                                wrapMode: Text.Wrap
                                font.pixelSize: 16
                                font.weight: Font.DemiBold
                            }

                            DankActionButton {
                                objectName: "translate-copy-" + index
                                iconName: "content_copy"
                                iconSize: 16
                                buttonSize: 28
                                radius: 4
                                iconColor: Theme.primary
                                tooltipText: "复制译文"
                                Accessible.role: Accessible.Button
                                Accessible.name: "复制“" + modelData.simplified + "”的译文"
                                onActiveFocusChanged: if (activeFocus) root.reveal(this)
                                onClicked: root.copyEntry(modelData.translation)
                            }

                        }

                        StyledText {
                            visible: root.settings.showPinyin ?? true
                            width: parent.width
                            text: modelData.pinyin
                            font.pixelSize: 13
                            color: Theme.primary
                            wrapMode: Text.Wrap
                        }

                        StyledText {
                            width: parent.width
                            text: modelData.meanings.join("; ")
                            font.pixelSize: 14
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            visible: index < root.entries.length - 1
                            color: Theme.outlineMedium
                        }

                    }

                }

                StyledText {
                    visible: root.suggestions.length > 0
                    text: "可尝试以下词条"
                    color: Theme.surfaceVariantText
                    font.pixelSize: 13
                }

                Repeater {
                    model: root.suggestions

                    delegate: Controls.ItemDelegate {
                        required property string modelData

                        width: resultsColumn.width
                        text: modelData
                        Accessible.name: "查询建议词条“" + modelData + "”"
                        onActiveFocusChanged: {
                            if (activeFocus)
                                root.reveal(this);

                        }
                        onClicked: {
                            root.query = modelData;
                            root.submit();
                        }

                        contentItem: StyledText {
                            text: parent.text
                            color: Theme.primary
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                        }

                        background: Rectangle {
                            radius: 4
                            color: parent.hovered ? Theme.surfaceContainerHigh : "transparent"
                            border.width: parent.activeFocus ? 2 : 0
                            border.color: Theme.primary
                        }

                    }

                }

                StyledText {
                    visible: lookup.result.truncated ?? false
                    width: parent.width
                    text: "匹配较多，仅显示前 20 条。可输入更完整的词条或短语。"
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                    wrapMode: Text.Wrap
                }

            }

        }

        StyledText {
            id: copiedLabel
            Layout.fillWidth: true
            visible: root.copied.length > 0
            text: root.copied
            font.pixelSize: 12
            color: Theme.primary
            wrapMode: Text.Wrap
            Accessible.name: text
        }

    }

}
