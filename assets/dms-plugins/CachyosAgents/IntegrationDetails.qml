import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Column {
    id: root
    required property var source
    required property var integration
    property var closePopout: null
    property var parentPopout: null
    property real maximumHeight: 640
    property bool showingSettings: false
    padding: 16
    spacing: 8
    readonly property real innerWidth: width - leftPadding - rightPadding
    readonly property real availableHeight: Math.max(100, maximumHeight - topPadding - bottomPadding - heading.height - (feedback.visible ? feedback.height : 0) - spacing * 2)

    function showSettings() {
        if (showingSettings)
            return;
        showingSettings = true;
        integration.refresh();
    }

    function showUsage() {
        if (!showingSettings)
            return;
        showingSettings = false;
        source.refreshAgentState();
    }

    RowLayout {
        id: heading
        width: root.innerWidth
        height: 36
        DankIcon { name: "smart_toy"; size: 22; color: Theme.primary }
        StyledText { text: root.showingSettings ? "AI 集成设置" : "AI 集成"; font.pixelSize: 16; font.weight: Font.DemiBold; Layout.fillWidth: true }
        DankActionButton {
            iconName: "refresh"
            tooltipText: root.showingSettings ? "刷新设置" : "重新采集用量"
            enabled: !root.integration.busy
            onClicked: {
                if (root.showingSettings)
                    root.integration.refresh();
                else
                    root.source.refresh(true);
            }
        }
        DankActionButton {
            objectName: "ai-settings-toggle"
            iconName: root.showingSettings ? "arrow_back" : "tune"
            tooltipText: root.showingSettings ? "返回用量" : "AI 集成设置"
            onClicked: if (root.showingSettings) root.showUsage(); else root.showSettings()
        }
        DankActionButton {
            iconName: "close"
            tooltipText: "关闭"
            onClicked: if (root.closePopout) root.closePopout()
        }
    }
    StyledText {
        id: feedback
        width: root.innerWidth
        visible: text.length > 0
        text: root.integration.error || (root.integration.busy ? "正在处理…" : root.integration.message)
        color: root.integration.error ? Theme.warning : Theme.surfaceVariantText
        font.pixelSize: 12
        wrapMode: Text.WordWrap
    }
    UsageDetails {
        objectName: "ai-usage-view"
        width: root.innerWidth
        visible: !root.showingSettings
        height: visible ? implicitHeight : 0
        source: root.source
        embedded: true
        maximumHeight: root.availableHeight
    }
    DankFlickable {
        objectName: "ai-settings-scroller"
        width: root.innerWidth
        visible: root.showingSettings
        height: visible ? Math.min(contentHeight, root.availableHeight) : 0
        contentHeight: settingsBody.implicitHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        IntegrationSettings {
            id: settingsBody
            width: parent.width
            source: root.integration
        }
    }
}
