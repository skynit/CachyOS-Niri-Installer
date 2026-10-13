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
    // 只列出真的有记录的 agent：没有任何采集器的 agent（例如还没实现的 opencode）
    // 会一直停在 "未采集"，给它留一张永远空的卡片只是噪音。
    readonly property var listedRows: root.rows.filter(function (row) {
        return row.hasRecord === true;
    })
    readonly property int hiddenRows: root.rows.length - root.listedRows.length
    readonly property var fresh: Usage.freshness(root.source.updatedAt, Date.now(), (root.source.refreshSeconds + 60) * 1000)

    // 默认 agent 的状态由 source 提供（UsageSource 负责跑进程）；弹窗保持纯展示，
    // 因此不依赖 Quickshell 运行时，能被单独渲染与校验。
    // 只有"装了"的 agent 才给按钮——设成默认之后 Super+` 起不来，那种按钮等于陷阱。
    readonly property string defaultAgent: root.source.defaultAgent || ""
    readonly property var installedAgents: root.source.installedAgents || ({})

    function setDefaultAgent(id) {
        if (root.source.setDefaultAgent)
            root.source.setDefaultAgent(id);
    }

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
                model: root.listedRows

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
                            // 当前默认：给个徽标而不是按钮，避免"点了没反应"的错觉。
                            StyledText {
                                visible: root.defaultAgent === card.agent.id
                                text: "默认"
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                color: Theme.primary
                            }
                            DankButton {
                                visible: root.installedAgents[card.agent.id] === true
                                    && root.defaultAgent !== card.agent.id
                                text: "设为默认"
                                buttonHeight: 26
                                horizontalPadding: 8
                                backgroundColor: "transparent"
                                textColor: Theme.primary
                                Accessible.role: Accessible.Button
                                Accessible.name: "把 " + card.agent.label + " 设为默认 AI agent"
                                onClicked: root.setDefaultAgent(card.agent.id)
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

                        // 近 7 天折线图。用 Canvas 画而不是拼一堆矩形：折线要连线、要画点、
                        // 要让最后一个点高亮，用布局元素拼会很别扭。坐标计算放在 Usage.js 里，
                        // 因此可以做 node 测试（QML 部分只能靠 qmllint 与肉眼验收）。
                        Column {
                            width: parent.width
                            spacing: 2
                            // ≥1 而不是 >1：只有一天数据时 chartPoints 会把点画在正中间，
                            // 藏掉整个区块反而像"坏掉了"。
                            visible: card.agent.days.length >= 1

                            RowLayout {
                                width: parent.width
                                StyledText {
                                    text: "近 7 天（峰值 " + Usage.formatTokens(Usage.chartMax(card.agent.days)) + "）"
                                    font.pixelSize: 10
                                    color: Theme.surfaceVariantText
                                    Layout.fillWidth: true
                                }
                                StyledText {
                                    text: card.agent.days.length > 0 ? card.agent.days[0].date.slice(5) + " → " + card.agent.days[card.agent.days.length - 1].date.slice(5) : ""
                                    font.pixelSize: 10
                                    color: Theme.surfaceVariantText
                                }
                            }

                            Canvas {
                                id: chart
                                width: parent.width
                                height: 56
                                onWidthChanged: requestPaint()
                                onHeightChanged: requestPaint()
                                // 数据换了要重画：agent 属性变化即意味着 days 变了。
                                Connections {
                                    target: card
                                    function onAgentChanged() {
                                        chart.requestPaint();
                                    }
                                }
                                onPaint: {
                                    const ctx = getContext("2d");
                                    const inset = 6;
                                    // 显式清屏，再 reset()：不依赖 reset() 是否顺带清空画布
                                    // （Qt 头文件里没写这一点），否则重绘会留下上一次的折线。
                                    ctx.clearRect(0, 0, width, height);
                                    ctx.reset();
                                    const points = Usage.chartPoints(card.agent.days, width, height, inset);
                                    if (points.length === 0)
                                        return;

                                    // 基线
                                    ctx.strokeStyle = Theme.surfaceContainerHighest;
                                    ctx.lineWidth = 1;
                                    ctx.beginPath();
                                    ctx.moveTo(0, height - inset);
                                    ctx.lineTo(width, height - inset);
                                    ctx.stroke();

                                    // 折线
                                    ctx.strokeStyle = Theme.primary;
                                    ctx.lineWidth = 2;
                                    ctx.lineJoin = "round";
                                    ctx.beginPath();
                                    points.forEach(function (point, index) {
                                        if (index === 0)
                                            ctx.moveTo(point.x, point.y);
                                        else
                                            ctx.lineTo(point.x, point.y);
                                    });
                                    ctx.stroke();

                                    // 数据点：最后一个高亮，其余弱化
                                    points.forEach(function (point, index) {
                                        ctx.beginPath();
                                        ctx.arc(point.x, point.y, index === points.length - 1 ? 3 : 2, 0, Math.PI * 2);
                                        ctx.fillStyle = index === points.length - 1 ? Theme.primary : Theme.surfaceVariantText;
                                        ctx.fill();
                                    });
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
        visible: (root.source.agentStateError || "").length > 0
        text: root.source.agentStateError || ""
        font.pixelSize: 11
        color: Theme.error
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: root.width - root.leftPadding - root.rightPadding
        text: root.listedRows.length === 0
            ? (root.rows.length === 0
                ? "没有启用的 agent，可在设置里打开"
                : "还没有采集到任何用量——先跑一次 cachyos-agent-usage-update")
            : "更新于 " + root.fresh.text + " · 数据由 cachyos-agent-usage-update 在本机采集"
                + (root.hiddenRows > 0 ? "（" + root.hiddenRows + " 个 agent 还没有采集器，未显示）" : "")
        font.pixelSize: 11
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: root.width - root.leftPadding - root.rightPadding
        text: root.defaultAgent.length > 0
            ? "默认 agent：" + root.defaultAgent + "（Super+` 直接启动它）"
            : "还没有默认 agent：按 Super+` 会先让你选一个"
        font.pixelSize: 11
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

}
