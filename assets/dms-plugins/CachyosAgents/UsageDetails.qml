import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Services
import qs.Widgets
import "Usage.js" as Usage

Column {
    id: root

    required property var source
    property var closePopout: null
    property var parentPopout: null
    property real maximumHeight: 560
    padding: 16
    spacing: 12

    readonly property var rows: Usage.summarise(root.source.records, root.source.settings)
    readonly property var fresh: Usage.freshness(root.source.updatedAt, Date.now(), (root.source.refreshSeconds + 60) * 1000)

    RowLayout {
        id: header
        width: root.width - root.leftPadding - root.rightPadding
        spacing: 8

        DankIcon {
            name: "smart_toy"
            size: 20
            color: Theme.primary
        }
        StyledText {
            text: "AI agent 用量"
            font.pixelSize: 16
            font.weight: Font.DemiBold
            Layout.fillWidth: true
        }
        DankActionButton {
            iconName: "refresh"
            tooltipText: "重新采集"
            onClicked: root.source.refresh(true)
        }
        DankActionButton {
            iconName: "settings"
            tooltipText: "插件设置"
            onClicked: {
                if (root.closePopout)
                    root.closePopout();
                PopoutService.openSettingsWithTab("plugins");
            }
        }
        DankActionButton {
            iconName: "close"
            tooltipText: "关闭"
            onClicked: {
                if (root.closePopout)
                    root.closePopout();
            }
        }
    }

    StyledText {
        width: root.width - root.leftPadding - root.rightPadding
        visible: root.source.lastError.length > 0
        text: root.source.lastError
        color: Theme.warning
        font.pixelSize: 12
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: root.width - root.leftPadding - root.rightPadding
        visible: root.source.lastError.length === 0 && root.fresh.stale
        text: "数据可能已过期（更新于 " + root.fresh.text + "）"
        color: Theme.warning
        font.pixelSize: 12
    }

    DankFlickable {
        id: scroller
        width: root.width - root.leftPadding - root.rightPadding
        height: Math.min(contentHeight, Math.max(0, root.maximumHeight - header.height - root.spacing * 2 - root.topPadding - root.bottomPadding))
        contentHeight: body.implicitHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        activeFocusOnTab: true
        Accessible.role: Accessible.Pane
        Accessible.name: "AI agent 用量详情"

        Column {
            id: body
            width: parent.width
            spacing: 10

            Repeater {
                model: root.rows

                delegate: Rectangle {
                    id: card
                    required property var modelData
                    // 先把 agent 行捕获下来：嵌套 Repeater 里的 modelData 会被内层模型遮蔽。
                    readonly property var agent: modelData

                    width: body.width
                    height: layout.implicitHeight + 24
                    radius: 10
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: layout
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 12
                        spacing: 8

                        RowLayout {
                            width: parent.width
                            spacing: 8
                            DankIcon {
                                name: card.agent.icon
                                size: 16
                                color: Theme.primary
                            }
                            StyledText {
                                text: card.agent.label
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                                Layout.fillWidth: true
                            }
                            StyledText {
                                visible: card.agent.tierLabel.length > 0
                                text: card.agent.tierLabel
                                font.pixelSize: 11
                                color: Theme.surfaceVariantText
                            }
                            StyledText {
                                text: card.agent.state === "waiting" ? "未采集" : (card.agent.state === "missing" ? "无数据" : "")
                                visible: card.agent.state !== "ready"
                                font.pixelSize: 11
                                color: Theme.surfaceVariantText
                            }
                        }

                        StyledText {
                            width: parent.width
                            visible: card.agent.detail.length > 0
                            text: card.agent.detail
                            font.pixelSize: 11
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        GridLayout {
                            width: parent.width
                            columns: 4
                            columnSpacing: 12
                            rowSpacing: 2

                            StyledText { text: "今天"; font.pixelSize: 11; color: Theme.surfaceVariantText }
                            StyledText { text: Usage.formatTokens(card.agent.todayTokens); font.pixelSize: 13; color: Theme.surfaceText }
                            StyledText { text: "累计费用"; font.pixelSize: 11; color: Theme.surfaceVariantText }
                            StyledText { text: Usage.formatCost(card.agent.totalCost); font.pixelSize: 13; color: Theme.surfaceText }

                            StyledText { text: "今天费用"; font.pixelSize: 11; color: Theme.surfaceVariantText }
                            StyledText { text: Usage.formatCost(card.agent.todayCost); font.pixelSize: 13; color: Theme.surfaceText }
                            StyledText { text: "会话 / 提示"; font.pixelSize: 11; color: Theme.surfaceVariantText }
                            StyledText {
                                text: (card.agent.sessions === null ? "—" : card.agent.sessions) + " / " + (card.agent.prompts === null ? "—" : card.agent.prompts)
                                font.pixelSize: 13
                                color: Theme.surfaceText
                            }
                        }

                        Repeater {
                            model: card.agent.limits
                            delegate: Column {
                                required property var modelData
                                width: layout.width
                                spacing: 2
                                StyledText {
                                    text: modelData.label + " 额度 " + Math.round(modelData.percent) + "%"
                                    font.pixelSize: 11
                                    color: modelData.percent >= 90 ? Theme.error : Theme.surfaceVariantText
                                }
                                Rectangle {
                                    width: layout.width
                                    height: 4
                                    radius: 2
                                    color: Theme.surfaceContainerHighest
                                    Rectangle {
                                        width: parent.width * Math.max(0, Math.min(1, modelData.percent / 100))
                                        height: parent.height
                                        radius: 2
                                        color: modelData.percent >= 90 ? Theme.error : Theme.primary
                                    }
                                }
                            }
                        }

                        Repeater {
                            model: card.agent.models
                            delegate: RowLayout {
                                required property var modelData
                                width: layout.width
                                spacing: 8
                                StyledText {
                                    text: modelData.model + (modelData.priced ? "" : "（未定价）")
                                    font.pixelSize: 11
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideMiddle
                                    Layout.fillWidth: true
                                }
                                StyledText {
                                    text: Usage.formatTokens(modelData.tokens)
                                    font.pixelSize: 11
                                    color: Theme.surfaceText
                                }
                                StyledText {
                                    text: Usage.formatCost(modelData.cost)
                                    font.pixelSize: 11
                                    color: Theme.surfaceText
                                }
                            }
                        }

                        Row {
                            id: bars
                            width: parent.width
                            height: 24
                            spacing: 3
                            visible: card.agent.days.length > 0
                            readonly property var values: Usage.sparkline(card.agent.days)

                            Repeater {
                                model: bars.values
                                delegate: Rectangle {
                                    required property var modelData
                                    required property int index
                                    width: Math.max(4, (bars.width - bars.spacing * (bars.values.length - 1)) / Math.max(1, bars.values.length))
                                    height: Math.max(2, Math.round(bars.height * modelData))
                                    radius: 2
                                    color: index === bars.values.length - 1 ? Theme.primary : Theme.surfaceContainerHighest
                                    anchors.bottom: parent.bottom
                                }
                            }
                        }

                        StyledText {
                            visible: card.agent.semantics.length > 0
                            text: card.agent.semantics + " · 近 7 天"
                            font.pixelSize: 10
                            color: Theme.surfaceVariantText
                        }
                    }
                }
            }
        }
    }

    StyledText {
        width: root.width - root.leftPadding - root.rightPadding
        text: root.rows.length === 0
            ? "没有启用的 agent，可在设置里打开"
            : "更新于 " + root.fresh.text + " · 数据由 cachyos-agent-usage-update 在本机采集"
        font.pixelSize: 11
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
