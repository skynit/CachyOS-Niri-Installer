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
    property real availableHeight: 560
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

    implicitHeight: Math.min(560, Math.max(360, availableHeight))
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

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            DankIcon {
                name: "translate"
                size: 24
                color: Theme.primary
            }

            StyledText {
                text: "离线翻译"
                font.pixelSize: 20
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }

            DankButton {
                visible: root.closePopout !== null
                text: "关闭"
                buttonHeight: 32
                horizontalPadding: 12
                backgroundColor: "transparent"
                textColor: Theme.surfaceVariantText
                Accessible.role: Accessible.Button
                Accessible.name: "关闭离线翻译"
                onClicked: root.closePopout()
            }

        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Repeater {
                model: [{
                    "label": "自动",
                    "value": "auto"
                }, {
                    "label": "中 → 英",
                    "value": "zh"
                }, {
                    "label": "英 → 中",
                    "value": "en"
                }]

                delegate: DankButton {
                    required property var modelData

                    text: modelData.label
                    buttonHeight: 32
                    horizontalPadding: 12
                    backgroundColor: root.direction === modelData.value ? Theme.primary : Theme.surfaceContainerHigh
                    textColor: root.direction === modelData.value ? Theme.primaryText : Theme.surfaceText
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: modelData.label
                    Accessible.checked: root.direction === modelData.value
                    onClicked: root.direction = modelData.value
                }

            }

            Item {
                Layout.fillWidth: true
            }

        }

        Basic.TextField {
            id: input

            objectName: "queryInput"
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            placeholderText: "输入中文或英文词条、短语"
            maximumLength: 200
            font.family: Theme.fontFamily
            font.pixelSize: 15
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
                radius: 8
                color: Theme.surfaceContainerHigh
                border.width: input.activeFocus ? 2 : 1
                border.color: input.activeFocus ? Theme.primary : Theme.outlineMedium
            }

        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            DankButton {
                text: root.status === "error" ? "重试" : "查询"
                iconName: "search"
                buttonHeight: 32
                horizontalPadding: 12
                enabled: input.text.trim().length > 0 && !input.inputMethodComposing
                Accessible.role: Accessible.Button
                Accessible.name: text
                onClicked: root.submit()
            }

            DankButton {
                text: "粘贴"
                buttonHeight: 32
                horizontalPadding: 12
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                Accessible.role: Accessible.Button
                Accessible.name: "从剪贴板粘贴"
                onClicked: {
                    input.forceActiveFocus();
                    input.paste();
                }
            }

            DankButton {
                text: "清空"
                buttonHeight: 32
                horizontalPadding: 12
                enabled: input.text.length > 0
                backgroundColor: "transparent"
                textColor: Theme.surfaceVariantText
                Accessible.role: Accessible.Button
                Accessible.name: "清空输入和结果"
                onClicked: {
                    input.clear();
                    input.forceActiveFocus();
                }
            }

            Item {
                Layout.fillWidth: true
            }

            StyledText {
                text: input.text.length + " / 200"
                font.pixelSize: 12
                color: Theme.surfaceVariantText
            }

        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Theme.outlineMedium
        }

        DankFlickable {
            id: scroll

            objectName: "resultScroll"
            Layout.fillWidth: true
            Layout.fillHeight: true
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

                width: scroll.width - 12
                spacing: 12

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
                        spacing: 6

                        RowLayout {
                            width: parent.width
                            spacing: 8

                            StyledText {
                                Layout.fillWidth: true
                                text: modelData.simplified
                                wrapMode: Text.Wrap
                                font.pixelSize: 18
                                font.weight: Font.DemiBold
                            }

                            DankButton {
                                text: "复制"
                                buttonHeight: 28
                                horizontalPadding: 8
                                backgroundColor: "transparent"
                                textColor: Theme.primary
                                Accessible.role: Accessible.Button
                                Accessible.name: "复制“" + modelData.simplified + "”的译文"
                                onActiveFocusChanged: {
                                    if (activeFocus)
                                        root.reveal(this);

                                }
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
                            radius: 6
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
