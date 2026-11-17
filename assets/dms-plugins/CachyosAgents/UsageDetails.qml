import QtQuick
import QtQuick.Controls
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
    property bool embedded: false
    property var expandedRows: ({})
    property date now: new Date()
    readonly property string today: Qt.formatDateTime(now, "yyyy-MM-dd")
    readonly property real innerWidth: width - leftPadding - rightPadding
    readonly property var rows: Usage.summarise(source.records, source.settings)
    readonly property var listedRows: rows.filter(function (row) { return row.hasRecord; })
    readonly property var fresh: Usage.freshness(source.updatedAt, now.getTime(), (source.refreshSeconds + 60) * 1000)
    readonly property string defaultAgent: source.defaultAgent || ""
    readonly property var installedAgents: source.installedAgents || ({})
    readonly property color divider: Theme.withAlpha(Theme.outline, 0.18)
    padding: embedded ? 0 : 16
    spacing: 8

    function toggleRow(id) {
        var next = Object.assign({}, expandedRows);
        next[id] = !next[id];
        expandedRows = next;
    }

    function showItem(item) {
        var top = item.mapToItem(body, 0, 0).y;
        if (top < scroller.contentY)
            scroller.contentY = top;
        else if (top + item.height > scroller.contentY + scroller.height)
            scroller.contentY = Math.max(0, top + item.height - scroller.height);
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }

    RowLayout {
        id: header
        visible: !root.embedded
        width: root.innerWidth
        height: visible ? implicitHeight : 0
        spacing: 8
        DankIcon { name: "auto_awesome"; size: 20; color: Theme.primary }
        StyledText {
            text: "AI 模块"
            font.pixelSize: 16
            font.weight: Font.DemiBold
            Layout.fillWidth: true
        }
        DankActionButton {
            iconName: "refresh"
            tooltipText: "重新采集"
            Accessible.name: tooltipText
            onClicked: root.source.refresh(true)
        }
        DankActionButton {
            iconName: "tune"
            tooltipText: "插件设置"
            Accessible.name: tooltipText
            onClicked: {
                if (root.closePopout)
                    root.closePopout();
                PopoutService.openSettingsWithTab("plugins");
            }
        }
        DankActionButton {
            iconName: "close"
            tooltipText: "关闭"
            Accessible.name: tooltipText
            onClicked: if (root.closePopout) root.closePopout()
        }
    }

    StyledText {
        id: errorLabel
        width: root.innerWidth
        visible: text.length > 0
        text: root.source.lastError || ""
        color: Theme.warning
        font.pixelSize: 12
        wrapMode: Text.Wrap
        Accessible.role: Accessible.AlertMessage
    }
    StyledText {
        id: staleLabel
        width: root.innerWidth
        visible: !errorLabel.visible && root.fresh.stale
        text: "数据可能已过期，请刷新重试"
        color: Theme.warning
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }
    StyledText {
        id: agentError
        width: root.innerWidth
        visible: text.length > 0
        text: root.source.agentStateError || ""
        font.pixelSize: 12
        color: Theme.error
        wrapMode: Text.Wrap
        Accessible.role: Accessible.AlertMessage
    }

    DankFlickable {
        id: scroller
        objectName: "ai-usage-scroller"
        width: root.innerWidth
        height: Math.min(contentHeight, Math.max(0, root.maximumHeight - root.topPadding - root.bottomPadding
            - (header.visible ? header.height + root.spacing : 0)
            - (errorLabel.visible ? errorLabel.height + root.spacing : 0)
            - (staleLabel.visible ? staleLabel.height + root.spacing : 0)
            - (agentError.visible ? agentError.height + root.spacing : 0)))
        contentHeight: body.implicitHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onContentHeightChanged: contentY = Math.min(contentY, Math.max(0, contentHeight - height))
        Accessible.role: Accessible.Pane
        Accessible.name: "AI 模块费用与一周详情"

        Column {
            id: body
            x: 2
            width: scroller.width - 4

            Repeater {
                model: root.listedRows
                delegate: Column {
                    id: module
                    required property var modelData
                    readonly property var agent: modelData
                    readonly property var week: Usage.weekFor(agent, root.today)
                    readonly property bool expanded: root.expandedRows[agent.id] === true
                    width: body.width

                    AbstractButton {
                        id: summary
                        objectName: "ai-row-" + module.agent.id
                        width: parent.width
                        implicitHeight: Math.max(48, contentItem.implicitHeight + 16)
                        text: module.agent.label
                        hoverEnabled: true
                        focusPolicy: Qt.StrongFocus
                        Accessible.role: Accessible.Button
                        Accessible.name: text + "，今天费用 " + Usage.formatCost(module.week.todayCost)
                        Accessible.description: module.expanded ? "收起一周详情" : "展开一周详情"
                        Accessible.expandable: true
                        Accessible.expanded: module.expanded
                        Accessible.onPressAction: clicked()
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        onClicked: root.toggleRow(module.agent.id)
                        Keys.onReturnPressed: clicked()
                        Keys.onEnterPressed: clicked()
                        Keys.onRightPressed: if (!module.expanded) clicked()
                        Keys.onLeftPressed: if (module.expanded) clicked()
                        onActiveFocusChanged: if (activeFocus) Qt.callLater(function () { root.showItem(summary); })
                        background: Rectangle {
                            radius: 4
                            color: summary.down || summary.hovered || module.expanded ? Theme.surfaceContainerHigh : "transparent"
                            border.width: summary.activeFocus ? 2 : 0
                            border.color: Theme.primary
                        }
                        contentItem: RowLayout {
                            spacing: 4
                            DankIcon {
                                name: module.agent.icon
                                size: 18
                                color: Theme.surfaceVariantText
                                Layout.leftMargin: 12
                            }
                            StyledText {
                                text: summary.text
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                            }
                            StyledText {
                                visible: root.defaultAgent === module.agent.id
                                text: "默认"
                                font.pixelSize: 12
                                color: Theme.surfaceVariantText
                            }
                            StyledText { text: "今天"; font.pixelSize: 12; color: Theme.surfaceVariantText }
                            StyledText {
                                objectName: "ai-today-" + module.agent.id
                                text: Usage.formatCost(module.week.todayCost)
                                font.pixelSize: 16
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignRight
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                Layout.preferredWidth: Math.max(80, implicitWidth)
                            }
                            DankIcon {
                                name: module.expanded ? "expand_more" : "chevron_right"
                                size: 18
                                color: module.expanded ? Theme.primary : Theme.surfaceVariantText
                                Layout.rightMargin: 12
                            }
                        }
                    }

                    // 只在展开时创建详情和 Canvas；展开状态按模块 id 保存在外层，刷新不会重置。
                    Loader {
                        id: detailLoader
                        objectName: "ai-detail-" + module.agent.id
                        width: parent.width
                        active: module.expanded
                        visible: active
                        height: item ? item.implicitHeight : 0
                        sourceComponent: Column {
                            width: detailLoader.width
                            padding: 12
                            spacing: 12
                            readonly property real contentWidth: width - leftPadding - rightPadding

                            RowLayout {
                                width: parent.contentWidth
                                spacing: 8
                                StyledText {
                                    text: "近 7 天费用"
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                    Layout.fillWidth: true
                                }
                                StyledText {
                                    text: module.week.days.length > 0
                                        ? module.week.days[0].date.slice(5) + " — " + module.week.days[module.week.days.length - 1].date.slice(5) : ""
                                    font.pixelSize: 12
                                    color: Theme.surfaceVariantText
                                }
                            }
                            RowLayout {
                                width: parent.contentWidth
                                StyledText {
                                    text: Usage.formatCost(module.week.cost)
                                    font.pixelSize: 20
                                    font.weight: Font.DemiBold
                                    Layout.fillWidth: true
                                }
                                StyledText {
                                    text: "用量 " + Usage.formatTokens(module.week.tokens)
                                    font.pixelSize: 12
                                    color: Theme.surfaceVariantText
                                }
                            }
                            StyledText {
                                width: parent.contentWidth
                                visible: module.week.days.length === 0
                                text: "暂无本周用量记录"
                                font.pixelSize: 12
                                color: Theme.surfaceVariantText
                            }
                            Canvas {
                                id: chart
                                objectName: "ai-chart-" + module.agent.id
                                width: parent.contentWidth
                                height: 56
                                visible: module.week.days.some(function (day) { return day.cost !== null && day.cost >= 0; })
                                Accessible.role: Accessible.Graphic
                                Accessible.name: "近 7 天费用趋势，下方表格列出每日金额"
                                onWidthChanged: requestPaint()
                                onVisibleChanged: if (visible) requestPaint()
                                Connections {
                                    target: module
                                    function onWeekChanged() { chart.requestPaint(); }
                                }
                                Connections {
                                    target: Theme
                                    function onPrimaryChanged() { chart.requestPaint(); }
                                    function onSurfaceVariantTextChanged() { chart.requestPaint(); }
                                    function onOutlineChanged() { chart.requestPaint(); }
                                }
                                onPaint: {
                                    const ctx = getContext("2d");
                                    ctx.reset();
                                    ctx.clearRect(0, 0, width, height);
                                    const days = module.week.days;
                                    const points = Usage.chartPoints(days.map(function (day) {
                                        return { date: day.date, tokens: day.cost };
                                    }), width, height, 6);
                                    ctx.strokeStyle = root.divider;
                                    ctx.lineWidth = 1;
                                    ctx.beginPath();
                                    ctx.moveTo(0, height - 6);
                                    ctx.lineTo(width, height - 6);
                                    ctx.stroke();
                                    ctx.strokeStyle = Theme.primary;
                                    ctx.lineWidth = 2;
                                    ctx.lineJoin = "round";
                                    ctx.beginPath();
                                    let connected = false;
                                    points.forEach(function (point, index) {
                                        if (days[index].cost === null || days[index].cost < 0) {
                                            connected = false;
                                            return;
                                        }
                                        if (connected) ctx.lineTo(point.x, point.y);
                                        else ctx.moveTo(point.x, point.y);
                                        connected = true;
                                    });
                                    ctx.stroke();
                                    points.forEach(function (point, index) {
                                        if (days[index].cost === null || days[index].cost < 0) return;
                                        ctx.beginPath();
                                        ctx.arc(point.x, point.y, index === points.length - 1 ? 3 : 2, 0, Math.PI * 2);
                                        ctx.fillStyle = index === points.length - 1 ? Theme.primary : Theme.surfaceVariantText;
                                        ctx.fill();
                                    });
                                }
                            }
                            Column {
                                width: parent.contentWidth
                                visible: module.week.days.length > 0
                                RowLayout {
                                    width: parent.width
                                    height: 24
                                    StyledText { text: "日期"; font.pixelSize: 12; color: Theme.surfaceVariantText; Layout.fillWidth: true }
                                    StyledText { text: "用量 / token"; font.pixelSize: 12; color: Theme.surfaceVariantText; Layout.preferredWidth: 100; horizontalAlignment: Text.AlignRight }
                                    StyledText { text: "费用 / USD"; font.pixelSize: 12; color: Theme.surfaceVariantText; Layout.preferredWidth: 100; horizontalAlignment: Text.AlignRight }
                                }
                                Repeater {
                                    model: module.week.days
                                    delegate: Rectangle {
                                        id: dayRow
                                        required property var modelData
                                        width: parent.width
                                        height: 28
                                        radius: 4
                                        color: modelData.date === root.today ? Theme.surfaceContainerHigh : "transparent"
                                        RowLayout {
                                            anchors.fill: parent
                                            spacing: 8
                                            StyledText {
                                                text: dayRow.modelData.date.slice(5) + (dayRow.modelData.date === root.today ? " · 今天" : "")
                                                font.pixelSize: 12
                                                Layout.fillWidth: true
                                            }
                                            StyledText {
                                                text: Usage.formatTokens(dayRow.modelData.tokens)
                                                font.pixelSize: 12
                                                color: Theme.surfaceVariantText
                                                Layout.preferredWidth: 100
                                                horizontalAlignment: Text.AlignRight
                                            }
                                            StyledText {
                                                text: Usage.formatCost(dayRow.modelData.cost)
                                                font.pixelSize: 12
                                                Layout.preferredWidth: 100
                                                horizontalAlignment: Text.AlignRight
                                            }
                                        }
                                    }
                                }
                            }
                            Rectangle { width: parent.contentWidth; height: 1; color: root.divider }
                            RowLayout {
                                width: parent.contentWidth
                                StyledText {
                                    text: "累计 " + Usage.formatCost(module.agent.totalCost)
                                    font.pixelSize: 12
                                    color: Theme.surfaceVariantText
                                    Layout.fillWidth: true
                                }
                                DankButton {
                                    objectName: "ai-default-" + module.agent.id
                                    visible: root.installedAgents[module.agent.id] === true && root.defaultAgent !== module.agent.id
                                    text: "设为默认"
                                    buttonHeight: 28
                                    horizontalPadding: 8
                                    radius: 4
                                    backgroundColor: "transparent"
                                    textColor: Theme.primary
                                    Accessible.name: "把 " + module.agent.label + " 设为默认 AI 模块"
                                    onClicked: if (root.source.setDefaultAgent) root.source.setDefaultAgent(module.agent.id)
                                }
                            }
                            StyledText {
                                width: parent.contentWidth
                                visible: module.agent.sessions !== null || module.agent.prompts !== null
                                text: "累计会话 / 提示  " + (module.agent.sessions === null ? "—" : module.agent.sessions)
                                    + " / " + (module.agent.prompts === null ? "—" : module.agent.prompts)
                                font.pixelSize: 12
                                color: Theme.surfaceVariantText
                            }
                            StyledText {
                                visible: module.agent.models.length > 0
                                text: "模型 · 累计费用"
                                font.pixelSize: 12
                                color: Theme.surfaceVariantText
                            }
                            Repeater {
                                model: module.agent.models
                                delegate: RowLayout {
                                    required property var modelData
                                    width: parent.contentWidth
                                    spacing: 8
                                    StyledText {
                                        text: modelData.model + (modelData.priced ? "" : "（未定价）")
                                        font.pixelSize: 12
                                        wrapMode: Text.NoWrap
                                        elide: Text.ElideMiddle
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        ToolTip.text: text
                                        ToolTip.visible: truncated && modelHover.hovered
                                        ToolTip.delay: 400
                                        HoverHandler { id: modelHover }
                                    }
                                    StyledText { text: Usage.formatTokens(modelData.tokens); font.pixelSize: 12; color: Theme.surfaceVariantText }
                                    StyledText {
                                        text: modelData.priced ? Usage.formatCost(modelData.cost) : "—"
                                        font.pixelSize: 12
                                        Layout.preferredWidth: 80
                                        horizontalAlignment: Text.AlignRight
                                    }
                                }
                            }
                            Repeater {
                                model: module.agent.limits
                                delegate: Column {
                                    required property var modelData
                                    width: parent.contentWidth
                                    spacing: 4
                                    StyledText {
                                        width: parent.width
                                        text: modelData.label + " 额度 " + Math.round(modelData.percent) + "%"
                                        font.pixelSize: 12
                                        wrapMode: Text.Wrap
                                        color: modelData.percent >= 90 ? Theme.error : Theme.surfaceVariantText
                                    }
                                    Rectangle {
                                        width: parent.width
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
                            StyledText {
                                width: parent.contentWidth
                                visible: (module.agent.tierLabel || "").length > 0 || module.agent.semantics.length > 0
                                text: [module.agent.tierLabel || "", module.agent.semantics].filter(function (value) { return value.length > 0; }).join(" · ")
                                font.pixelSize: 12
                                color: Theme.surfaceVariantText
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                    Rectangle { width: parent.width; height: 1; color: root.divider }
                }
            }
            StyledText {
                width: parent.width
                topPadding: 12
                bottomPadding: 12
                visible: root.listedRows.length === 0
                text: root.rows.length === 0 ? "没有启用的 AI 模块，可在设置里打开" : "还没有采集到用量，请点击刷新重试"
                font.pixelSize: 12
                color: Theme.surfaceVariantText
                wrapMode: Text.Wrap
            }
        }
    }
}
