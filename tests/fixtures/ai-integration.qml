import QtQuick
import QtQuick.Window
import Quickshell
import QtTest
import qs.Common
import qs.DankCommon.Common as CommonStyle
import "@PLUGIN_DIR@" as Plugin

Window {
    id: win
    width: 560
    height: 800
    visible: true
    Component.onCompleted: CommonStyle.Style.theme = Theme
    Rectangle { anchors.fill: parent; color: Theme.surfaceContainer }
    TestEvent { id: input }

    QtObject {
        id: integration
        property bool busy: false
        property int refreshCount: 0
        property bool loaded: true
        property string error: ""
        property string message: ""
        property var state: ({
            defaultAgent: "codex", notifyMode: "auto",
            agents: [{id: "codex", installed: true}, {id: "claude", installed: false}],
            services: [{key: "oom", label: "OOM 捕获", enabled: true, active: true}],
            mutedPrograms: ["test-program"],
            actions: [{id: "explain", prompt: "解释这段内容", builtin: true}, {id: "custom", prompt: "自定义内容", builtin: false}],
            groups: [{title: "问一问", fields: [
                {key: "CACHYOS_ASK_SESSION", label: "提问会话", kind: "choice", value: "day", options: ["day", "new"]},
                {key: "CACHYOS_ASK_MAX_CHARS", label: "文本上限", kind: "number", value: "12000", options: [1, 1000000]},
                {key: "CACHYOS_OOM_PSI_ENABLED", label: "PSI 提前预警", kind: "toggle", value: "1", options: []},
                {key: "CACHYOS_CRASH_IGNORE", label: "忽略的程序", kind: "text", value: "", options: []}
            ]}]
        })
        signal operationSucceeded(string action)
        function refresh() { refreshCount++; }
        function execute(args) {}
        function setValue(key, value) {}
    }
    QtObject {
        id: usage
        property int agentStateRefreshCount: 0
        property var records: ["claude", "codex"].map(function (id) {
            return {id: id, hasLocalStats: true, stats: {
                recentDays: [{date: Qt.formatDateTime(new Date(), "yyyy-MM-dd"), totalTokens: 1000, costUsd: 1.25}],
                modelUsage: {"long-model-name-for-testing-layout": {totalTokens: 1000, costUsd: 1.25, priced: true}},
                totalSessions: 1, totalPrompts: 2, costUsd: 1.25
            }};
        })
        property var settings: ({})
        property string lastError: ""
        property double updatedAt: Date.now()
        property int refreshSeconds: 900
        property string defaultAgent: "codex"
        property var installedAgents: ({codex: true, claude: true})
        property string selectedDefault: ""
        function refresh(update) {}
        function refreshAgentState() { agentStateRefreshCount++; }
        function setDefaultAgent(id) { selectedDefault = id; }
    }
    Plugin.IntegrationDetails {
        id: details
        width: parent.width
        maximumHeight: win.height
        source: usage
        integration: integration
    }

    function childNamed(item, name) {
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const result = childNamed(item.children[i], name);
            if (result)
                return result;
        }
        return null;
    }
    function editorInside(item) {
        if (item.cursorRectangle !== undefined)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const editor = editorInside(item.children[i]);
            if (editor)
                return editor;
        }
        return null;
    }
    function check(condition, label) {
        if (!condition) {
            console.error("INTEGRATION_FAIL " + label);
            Qt.exit(1);
            throw new Error(label);
        }
        console.log("INTEGRATION_PASS " + label);
    }
    Timer {
        id: promptCheck
        interval: 50
        onTriggered: {
            const prompt = win.childNamed(details, "ask-prompt");
            const editor = win.editorInside(prompt);
            const viewport = editor.parent.parent;
            const origin = viewport.mapToItem(prompt, 0, 0);
            const cursor = editor.mapToItem(viewport, editor.cursorRectangle.x, editor.cursorRectangle.y);
            win.check(origin.y >= 8 && origin.y + viewport.height <= prompt.height - 8, "prompt viewport stays within vertical padding");
            win.check(viewport.clip, "prompt scroll content is clipped inside border");
            win.check(cursor.y >= -1 && cursor.y + editor.cursorRectangle.height <= viewport.height + 1, "long prompt keeps end cursor visible");
            const form = win.childNamed(details, "ai-settings-form");
            win.check(form.promptDirty, "typing in native prompt editor marks dirty");
            win.childNamed(details, "ai-settings-toggle").clicked();
            win.check(!details.showingSettings && !win.childNamed(details, "ai-settings-scroller").visible, "settings icon returns to usage");
            win.check(win.childNamed(details, "ai-usage-view").visible && usage.agentStateRefreshCount === 1, "return refreshes usage agent state");
            win.check(win.childNamed(details, "ai-detail-codex").active, "settings round trip preserves expanded module");
            console.log("INTEGRATION_COMPLETE");
            Qt.quit();
        }
    }
    Timer {
        id: usageCheck
        interval: 100
        onTriggered: {
            const view = win.childNamed(details, "ai-usage-view");
            const codex = win.childNamed(details, "ai-row-codex");
            const claude = win.childNamed(details, "ai-row-claude");
            const loader = win.childNamed(details, "ai-detail-codex");
            win.check(loader.active && loader.item && win.childNamed(details, "ai-chart-codex"), "click creates weekly detail and chart");
            win.check(!win.childNamed(details, "ai-detail-claude").active, "expanding one module leaves other module collapsed");
            win.check(codex.Accessible.expanded, "expanded state is accessible");
            codex.forceActiveFocus();
            input.keyClick(Qt.Key_Space, Qt.NoModifier, 0);
            win.check(!view.expandedRows.codex, "Space collapses the focused summary");
            input.keyClick(Qt.Key_Return, Qt.NoModifier, 0);
            win.check(view.expandedRows.codex, "Enter expands the focused summary");
            input.keyClick(Qt.Key_Left, Qt.NoModifier, 0);
            win.check(!view.expandedRows.codex, "Left arrow collapses summary");
            input.keyClick(Qt.Key_Right, Qt.NoModifier, 0);
            win.check(view.expandedRows.codex, "Right arrow expands summary");
            input.keyClick(Qt.Key_Tab, Qt.NoModifier, 0);
            win.check(!codex.activeFocus, "Tab leaves summary without a keyboard trap");
            claude.clicked();
            win.childNamed(details, "ai-default-claude").clicked();
            win.check(usage.selectedDefault === "claude" && view.expandedRows.claude, "default action calls source without collapsing summary");
            claude.clicked();
            usage.records = JSON.parse(JSON.stringify(usage.records));
            win.check(win.childNamed(details, "ai-detail-codex").active, "sampling refresh preserves expansion by module id");
            const refreshed = win.childNamed(details, "ai-row-codex");
            input.mouseClick(refreshed, refreshed.width / 2, refreshed.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
            const collapsed = win.childNamed(details, "ai-detail-codex");
            win.check(!collapsed.active && !collapsed.item, "second click unloads detail and chart");
            win.childNamed(details, "ai-row-codex").clicked();
            win.width = 360;
            win.height = 640;
            narrowUsageCheck.start();
        }
    }
    Timer {
        id: narrowUsageCheck
        interval: 100
        onTriggered: {
            win.check(details.height <= win.height, "expanded weekly detail stays within short window");
            const scroller = win.childNamed(details, "ai-usage-scroller");
            win.check(scroller.contentWidth <= scroller.width, "weekly detail has no horizontal scroll");
            const row = win.childNamed(details, "ai-row-codex");
            win.check(row.width <= win.childNamed(details, "ai-usage-view").width && row.contentItem.implicitWidth <= row.width, "summary columns fit narrow width");
            win.width = 560;
            win.height = 800;
            settingsCheck.start();
        }
    }
    Timer {
        id: settingsCheck
        interval: 600
        onTriggered: {
            const toggle = win.childNamed(details, "ai-settings-toggle");
            win.check(toggle && !details.showingSettings, "usage view opens without a tab bar");
            toggle.clicked();
            win.check(details.showingSettings && win.childNamed(details, "ai-settings-scroller").visible, "settings icon opens settings in popout");
            win.check(integration.refreshCount === 1, "opening settings refreshes settings data");
            const form = win.childNamed(details, "ai-settings-form");
            const idField = win.childNamed(details, "ask-action-id");
            const prompt = win.childNamed(details, "ask-prompt");
            win.check(form && idField && prompt, "prompt controls exist");
            win.check(!form.promptDirty && idField.text === "explain", "initial load stays clean");
            console.log("PROMPT_INSETS top=" + prompt.topPadding + " bottom=" + prompt.bottomPadding);
            win.check(prompt.topPadding >= 8 && prompt.bottomPadding >= 8, "prompt text stays inside vertical borders");
            form.selectedAction = "custom";
            form.loadPrompt();
            win.check(!form.promptDirty && prompt.text === "自定义内容", "selection stays clean");
            idField.text = "draft";
            win.check(form.promptDirty, "editing marks dirty");
            integration.state = JSON.parse(JSON.stringify(integration.state));
            win.check(form.promptDirty && idField.text === "draft", "refresh preserves draft");
            form.promptDirty = false;
            form.loadPrompt();
            win.check(!form.promptDirty && idField.text === "custom", "undo restores clean selection");
            win.check(details.height <= win.height, "desktop height stays bounded");
            win.width = 360;
            narrowSettingsCheck.start();
        }
    }
    Timer {
        id: narrowSettingsCheck
        interval: 100
        onTriggered: {
            win.check(details.width === 360 && details.height <= win.height, "narrow layout stays bounded");
            const scroller = win.childNamed(details, "ai-settings-scroller");
            win.check(scroller.contentWidth <= scroller.width, "no horizontal overflow");
            const prompt = win.childNamed(details, "ask-prompt");
            prompt.forceActiveFocus();
            prompt.text = "解释下面这段内容：它在做什么、关键点是什么、有没有坑。先给结论再展开。".repeat(30);
            prompt.cursorPosition = prompt.text.length;
            promptCheck.start();
        }
    }
    Timer {
        interval: 600
        running: true
        onTriggered: {
            win.requestActivate();
            win.check(win.childNamed(details, "ai-row-claude") && win.childNamed(details, "ai-row-codex"), "each collected module has a summary row");
            win.check(!win.childNamed(details, "ai-detail-claude").active && !win.childNamed(details, "ai-detail-codex").active, "all modules start collapsed");
            win.check(!win.childNamed(details, "ai-chart-codex"), "collapsed modules do not create charts");
            win.check(win.childNamed(details, "ai-today-codex").text === "$1.25", "summary shows today cost");
            win.check(details.height < 240, "collapsed popout is compact");
            win.childNamed(details, "ai-row-codex").clicked();
            usageCheck.start();
        }
    }
}
