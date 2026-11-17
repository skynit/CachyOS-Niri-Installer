import QtQuick
import QtQuick.Controls
import QtQuick.Templates as T
import QtQuick.Layouts
import Quickshell
import qs.Common

FloatingWindow {
    id: root
    required property var source
    property int page: 0
    property string search: ""
    property var preview: null
    property var failedPreview: null
    property int remaining: 0
    property bool details: false
    readonly property int sideWidth: width < 1100 ? 208 : 272
    readonly property var pages: [
        {id: "input", title: "鼠标与触摸板", icon: "mouse", tab: "mouse_touchpad"},
        {id: "displays", title: "显示与投屏", icon: "monitor", tab: "display_config"},
        {id: "keyboard", title: "键盘与快捷键", icon: "keyboard", tab: "keyboard"},
        {id: "windows", title: "窗口与工作区", icon: "panels-top-left", tab: "compositor_layout"},
        {id: "appearance", title: "DMS 外观", icon: "palette", tab: "theme"},
        {id: "power", title: "电源与会话", icon: "battery-charging", tab: "power_sleep"},
        {id: "cachyos", title: "CachyOS 集成", icon: "settings-2", tab: "about"},
        {id: "history", title: "修改记录", icon: "history", tab: "about"}
    ]
    readonly property bool displayDirty: displayLoader.item ? displayLoader.item.dirty : false
    readonly property bool displayConflict: displayDirty && displayLoader.item.revision !== source.snapshot.revision
    readonly property string pageId: pages[page].id
    readonly property bool pageDirty: page === 1 ? displayDirty : source.dirtyFor(pageId)
    readonly property bool pageConflict: page === 1 ? displayConflict : source.conflictFor(pageId)
    readonly property bool pageErrors: source.errorsFor(pageId)
    readonly property var sections: ({windows: [{id: "layout", title: "窗口布局"}, {id: "focus", title: "焦点与概览"}, {id: "workspace", title: "工作区显示"}], appearance: [{id: "appearance", title: "外观与动态效果"}, {id: "clock", title: "时钟与日历"}, {id: "notifications", title: "通知与提示音"}], power: [{id: "ac", title: "接通电源"}, {id: "battery", title: "使用电池"}, {id: "session", title: "锁屏与会话"}], cachyos: [{id: "protection", title: "配置更新保护"}]})
    readonly property var power: source.snapshot.power || {}

    signal nativeRequested(string tab)
    signal closeRequested()
    title: "桌面设置"
    implicitWidth: 1280
    implicitHeight: 800
    minimumSize: Qt.size(960, 640)
    color: SettingsTheme.background
    visible: false
    onPageChanged: flick.contentY = 0

    function matches(setting) { return !search || (setting.label + setting.description).toLowerCase().indexOf(search.toLowerCase()) >= 0; }
    function settingsFor(group) { return (source.snapshot.settings || []).filter(s => s.group === group && matches(s)); }
    function sectionSettings(section) { return source.settingsFor(pageId).filter(s => s.section === section && matches(s)); }
    function subtitle() {
        return {input: "niri 已保存配置 · 输入设备运行状态尚未检测", displays: "niri 当前输出 · 临时切换后确认保存", keyboard: "niri 已保存配置 · 启动配置与当前按键状态分别展示", windows: "niri 与 DMS · 修改后按配置归属保存", appearance: "DMS 设置接口 · 修改后点击应用", power: "DMS 空闲策略 · 接电与电池分别保存", cachyos: "配置更新保护与用户服务 · 当前用户，无需提权", history: "本插件的真实修改与备份记录"}[pageId];
    }
    function sleepCapability(value) { return {yes: "系统报告支持", no: "系统不允许", na: "系统未提供", challenge: "需要系统授权", unknown: "尚未读到能力"}[value] || "尚未读到能力"; }
    function powerDescription() {
        if (power.state === "unreachable" || power.enabled === undefined || power.enabled === null) return "无法读取 DMS 空闲运行状态，请重新读取或打开 DMS 电源设置。下方保存值不代表当前正在执行的策略。";
        const supply = power.onBattery ? "电池" : "接电";
        const causes = [];
        if (!power.enabled) causes.push("空闲监视已关闭");
        if (power.idleInhibited) causes.push("保持唤醒已开启");
        if (power.externalInhibit) causes.push("应用正在阻止空闲动作");
        return "当前使用" + supply + "策略" + (power.batteryPresent === false ? "（未检测到电池）" : "") + "。" + (causes.length ? causes.join("；") + "，普通自动息屏、锁屏和睡眠暂不执行。" : "空闲监视可用，各项计时仍受实际会话状态影响。") + (power.loginAvailable === false ? "登录管理器连接不可用。" : "");
    }
    function closeEditor() {
        if (preview) source.request("revert", {session: preview.id});
        visible = false;
        closeRequested();
    }
    onClosed: {
        if (preview) source.request("revert", {session: preview.id});
        closeRequested();
    }
    Connections {
        target: root.source
        function onCompleted(action, result) {
            if (action === "preview" && result.ok) { root.preview = result.data; countdown.triggered(); }
            if ((action === "confirm" || action === "revert") && result.ok) root.preview = null;
            if (action === "revert" && result.ok) root.failedPreview = null;
            if ((action === "confirm" || action === "revert") && result.reason === "restore_failed") { root.failedPreview = root.preview || root.failedPreview; root.preview = null; }
        }
    }
    Timer {
        id: countdown
        interval: 250
        repeat: true
        running: root.preview !== null
        onTriggered: {
            root.remaining = Math.max(0, Math.ceil((Date.parse(root.preview.deadline) - Date.now()) / 1000));
            if (root.remaining === 0 && !root.source.busy) root.source.request("revert", {session: root.preview.id});
        }
    }
    Item {
        anchors.fill: parent
        RowLayout {
            x: 16; y: 8; height: 32; width: parent.width - 32
            spacing: 12
            SettingsIcon { name: "panels-top-left" }
            SettingsText { text: "桌面设置"; font.pixelSize: 13 }
            Item { Layout.fillWidth: true }
            SettingsButton {
                objectName: "desktop-theme-toggle"
                iconName: SettingsTheme.dark ? "sun" : "moon"
                help: SettingsTheme.dark ? "切换桌面浅色模式" : "切换桌面深色模式"
                onClicked: Theme.setLightMode(SettingsTheme.dark)
            }
            SettingsButton { iconName: "minus"; help: "最小化桌面设置"; onClicked: root.minimized = true }
            SettingsButton { iconName: "x"; help: "关闭窗口，保留未应用草稿"; onClicked: root.closeEditor() }
        }
        ColumnLayout {
            x: 8; y: 64; width: root.sideWidth - 24; height: parent.height - 80
            spacing: 8
            SettingsText { Layout.leftMargin: 8; text: "桌面设置"; color: SettingsTheme.muted }
            SettingsField {
                Layout.fillWidth: true
                Layout.topMargin: 16
                Layout.bottomMargin: 8
                implicitHeight: 36
                placeholderText: "搜索设置…"
                text: root.search
                Accessible.name: "搜索当前分类中的设置"
                color: SettingsTheme.text
                placeholderTextColor: SettingsTheme.muted
                font.pixelSize: 13
                onTextChanged: root.search = text
                background: Rectangle { radius: 8; color: SettingsTheme.surface; border.color: parent.activeFocus ? SettingsTheme.focus : SettingsTheme.border; border.width: parent.activeFocus ? 2 : 1 }
            }
            Flickable {
                id: navigation
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: navigationItems.height
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                Column {
                    id: navigationItems
                    width: navigation.width
                    spacing: 8
                    SettingsText { x: 4; text: "设备"; font.pixelSize: 12; color: SettingsTheme.muted }
                    Repeater {
                        model: root.pages
                        Column {
                            required property var modelData
                            required property int index
                            width: navigationItems.width
                            spacing: 8
                            Item {
                                visible: index === 3
                                width: parent.width
                                height: 56
                                SettingsText { x: 4; anchors.bottom: parent.bottom; text: "桌面与系统"; font.pixelSize: 12; color: SettingsTheme.muted }
                            }
                            T.Button {
                                id: nav
                                width: parent.width
                                height: 32
                                padding: 0
                                hoverEnabled: true
                                activeFocusOnTab: true
                                Accessible.name: modelData.title
                                Accessible.role: Accessible.PageTab
                                Accessible.selected: root.page === index
                                onActiveFocusChanged: {
                                    if (!activeFocus) return;
                                    const top = mapToItem(navigation.contentItem, 0, 0).y;
                                    navigation.contentY = Math.max(0, Math.min(Math.max(0, navigation.contentHeight - navigation.height), top < navigation.contentY ? top : top + height > navigation.contentY + navigation.height ? top + height - navigation.height : navigation.contentY));
                                }
                                onClicked: { root.page = index; root.search = ""; }
                                background: Rectangle { radius: 4; color: root.page === index ? SettingsTheme.selected : nav.hovered ? SettingsTheme.raised : "transparent"; border.width: nav.activeFocus ? 2 : 0; border.color: SettingsTheme.focus }
                                contentItem: Item {
                                    SettingsIcon { x: 8; anchors.verticalCenter: parent.verticalCenter; name: modelData.icon; color: root.page === index ? SettingsTheme.text : SettingsTheme.icon }
                                    SettingsText {
                                        x: 36
                                        width: parent.width - x - 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.title
                                        font.pixelSize: 13
                                        maximumLineCount: 1
                                        wrapMode: Text.NoWrap
                                        elide: Text.ElideRight
                                        color: root.page === index ? SettingsTheme.text : SettingsTheme.muted
                                    }
                                }
                            }
                        }
                    }
                }
            }
            SettingsText { Layout.leftMargin: 8; Layout.fillWidth: true; text: root.source.snapshot.dmsVersion || "DMS 版本待读取"; font.pixelSize: 12; color: SettingsTheme.muted }
            SettingsText { Layout.leftMargin: 8; text: "当前用户配置 · 无需提权"; font.pixelSize: 12; color: SettingsTheme.muted }
        }
        Rectangle {
            x: root.sideWidth; y: 50; width: parent.width - x + 8; height: parent.height - y + 8
            radius: 8; color: SettingsTheme.surface; border.color: SettingsTheme.border
            ColumnLayout {
                anchors.fill: parent
                anchors.rightMargin: 8
                anchors.bottomMargin: 8
                spacing: 0
                Flickable {
                    id: flick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: content.implicitHeight + 80
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}
                    ColumnLayout {
                        id: content
                        y: 48
                        width: Math.min(832, flick.width - (root.width < 1100 ? 48 : 96))
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 24
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 24
                            Layout.rightMargin: 24
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                SettingsText { Layout.fillWidth: true; text: root.pages[root.page].title; font.pixelSize: 20 }
                                SettingsText { Layout.fillWidth: true; text: root.subtitle(); color: SettingsTheme.muted; font.pixelSize: 12 }
                            }
                            SettingsButton { text: "重新读取"; enabled: !root.source.busy && !root.preview; onClicked: root.source.request("snapshot", {}) }
                        }
                        ColumnLayout {
                            visible: root.source.busy || root.source.state !== "healthy" || root.source.stale || root.details || root.pageConflict || !root.source.loaded
                            Layout.fillWidth: true
                            Layout.leftMargin: 24
                            Layout.rightMargin: 24
                            spacing: 8
                            SettingsText { Layout.fillWidth: true; text: root.source.message; font.pixelSize: 13; color: root.source.state === "unreachable" ? SettingsTheme.danger : SettingsTheme.muted }
                            SettingsText { visible: root.source.stale; Layout.fillWidth: true; text: "显示的是上次读取结果。请重新读取后再应用；未完成草稿仍保留。"; font.pixelSize: 12; color: SettingsTheme.warning }
                            SettingsText { Layout.fillWidth: true; text: root.source.state + " / " + root.source.reason; font.pixelSize: 12; color: SettingsTheme.muted }
                            SettingsText { visible: root.pageConflict; Layout.fillWidth: true; text: "读取到的新配置与草稿基准不同。请核对各项待应用值后继续，或放弃草稿。"; color: SettingsTheme.warning; font.pixelSize: 12 }
                            SettingsButton { visible: root.pageConflict; text: "已核对，保留草稿继续编辑"; onClicked: { root.source.rebase(root.pageId); if (root.page === 1 && displayLoader.item) displayLoader.item.revision = root.source.snapshot.revision; } }
                            SettingsButton { visible: root.failedPreview !== null; text: "重试恢复显示"; enabled: !root.source.busy; onClicked: root.source.request("revert", {session: root.failedPreview.id}) }
                            Repeater { model: root.source.snapshot.warnings || []; SettingsText { required property string modelData; Layout.fillWidth: true; text: modelData; font.pixelSize: 12; color: SettingsTheme.warning } }
                        }
                        ColumnLayout {
                            visible: root.preview !== null
                            Layout.fillWidth: true
                            spacing: 12
                            SettingsText { Layout.fillWidth: true; text: "保留这次显示更改？剩余 " + root.remaining + " 秒。超时由后台恢复任务还原。"; color: SettingsTheme.warning }
                            RowLayout {
                                SettingsButton { text: "确认并保存"; primary: true; enabled: !root.source.busy && root.remaining > 0; onClicked: root.source.request("confirm", {session: root.preview.id}) }
                                SettingsButton { text: "立即恢复"; enabled: !root.source.busy; onClicked: root.source.request("revert", {session: root.preview.id}) }
                            }
                        }
                        ColumnLayout {
                            visible: root.page === 0 && root.source.loaded
                            Layout.fillWidth: true
                            spacing: 32
                            SettingsGroup { Layout.fillWidth: true; title: "触摸板"; settings: root.settingsFor("touchpad"); source: root.source; expandable: true; expanded: root.search.length > 0 }
                            SettingsGroup { Layout.fillWidth: true; title: "鼠标"; settings: root.settingsFor("mouse"); source: root.source; expandable: true; expanded: root.search.length > 0 }
                            SettingsText { visible: root.settingsFor("touchpad").length + root.settingsFor("mouse").length === 0; Layout.fillWidth: true; text: "没有匹配的设置，请尝试其他关键词。"; color: SettingsTheme.muted }
                        }
                        Loader {
                            id: displayLoader
                            Layout.fillWidth: true
                            active: root.source.loaded
                            visible: root.page === 1
                            sourceComponent: DisplayPage { source: root.source; onNativeRequested: root.nativeRequested("display_config") }
                        }
                        SettingsGroup { visible: root.page === 2 && root.source.loaded; Layout.fillWidth: true; title: "键盘输入"; settings: root.settingsFor("keyboard"); source: root.source }
                        SettingsButton { visible: root.page === 2; text: "打开 DMS 键盘与快捷键设置"; onClicked: root.nativeRequested("keyboard") }
                        ColumnLayout {
                            visible: root.page === 5 && root.source.loaded
                            Layout.fillWidth: true
                            Layout.leftMargin: 24
                            Layout.rightMargin: 24
                            spacing: 8
                            SettingsText { Layout.fillWidth: true; text: root.powerDescription(); font.pixelSize: 13; color: root.power.state === "healthy" ? SettingsTheme.text : SettingsTheme.warning }
                            SettingsText { Layout.fillWidth: true; text: (root.power.state || "unreachable") + " / " + (root.power.reason || "runtime_unavailable"); font.pixelSize: 12; color: SettingsTheme.muted }
                            SettingsText { Layout.fillWidth: true; text: "挂起：" + root.sleepCapability(root.power.canSuspend) + " · 休眠：" + root.sleepCapability(root.power.canHibernate) + " · 先挂起再休眠：" + root.sleepCapability(root.power.canSuspendThenHibernate); font.pixelSize: 12; color: SettingsTheme.muted }
                            SettingsText { Layout.fillWidth: true; text: "保存计时不会立即锁屏或睡眠。渐暗等待发生在空闲阈值之后；休眠恢复能力尚未实测。"; font.pixelSize: 12; color: SettingsTheme.muted }
                        }
                        SettingsText {
                            visible: root.page === 6 && root.source.loaded
                            Layout.fillWidth: true
                            Layout.leftMargin: 24
                            Layout.rightMargin: 24
                            text: "开启保护后，CachyOS 的配置更新会跳过该文件。关闭保护只允许后续更新覆盖，不会立即重置文件。" + ((root.source.snapshot.system || {}).state !== "healthy" ? "\n保护清单不可用：" + ((root.source.snapshot.system || {}).state || "unreachable") + " / " + ((root.source.snapshot.system || {}).reason || "system_unavailable") : "")
                            font.pixelSize: 12
                            color: SettingsTheme.muted
                        }
                        Repeater {
                            model: root.source.loaded ? (root.sections[root.pageId] || []) : []
                            ColumnLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                visible: root.sectionSettings(modelData.id).length > 0
                                spacing: 8
                                SettingsText { visible: root.pageId === "windows" && modelData.id === "workspace"; Layout.fillWidth: true; Layout.leftMargin: 24; Layout.rightMargin: 24; text: "以下选项用于 DMS 状态栏工作区组件；添加该组件后才能看到对应显示效果。"; font.pixelSize: 12; color: SettingsTheme.muted }
                                SettingsGroup { Layout.fillWidth: true; title: modelData.title; settings: root.sectionSettings(modelData.id); source: root.source }
                            }
                        }
                        SettingsText { visible: [3, 4, 5, 6].indexOf(root.page) >= 0 && root.source.loaded && root.source.settingsFor(root.pageId).filter(s => root.matches(s)).length === 0; Layout.fillWidth: true; Layout.leftMargin: 24; text: "没有匹配的设置，请尝试其他关键词。"; color: SettingsTheme.muted }
                        ColumnLayout {
                            visible: root.page === 6 && root.source.loaded
                            Layout.fillWidth: true
                            spacing: 12
                            SettingsText { Layout.leftMargin: 24; text: "用户服务"; color: SettingsTheme.muted }
                            Repeater {
                                model: ((root.source.snapshot.system || {}).services || []).filter(s => !root.search || (s.label + s.id).toLowerCase().indexOf(root.search.toLowerCase()) >= 0)
                                ColumnLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 24
                                    Layout.rightMargin: 24
                                    spacing: 4
                                    RowLayout {
                                        Layout.fillWidth: true
                                        SettingsText { Layout.fillWidth: true; text: modelData.label; font.pixelSize: 13 }
                                        SettingsText { text: modelData.state === "healthy" ? "运行中" : modelData.state === "unsupported" ? "未安装" : modelData.active === "failed" ? "运行失败" : modelData.state === "degraded" ? "未运行" : "读取失败"; font.pixelSize: 12; color: modelData.state === "healthy" ? SettingsTheme.success : SettingsTheme.warning }
                                    }
                                    SettingsText { Layout.fillWidth: true; text: modelData.id + " · " + (modelData.active || "unknown") + " · " + (modelData.enabled || "unknown"); font.pixelSize: 12; color: SettingsTheme.muted }
                                    SettingsText { Layout.fillWidth: true; text: root.source.readableReason(modelData.reason) + " · " + modelData.state + " / " + modelData.reason; font.pixelSize: 12; color: SettingsTheme.muted }
                                    Rectangle { Layout.fillWidth: true; height: 1; color: SettingsTheme.subtle }
                                }
                            }
                            SettingsText { Layout.fillWidth: true; Layout.leftMargin: 24; Layout.rightMargin: 24; text: "服务状态为只读。系统更新与内核管理：unsupported / not_implemented。"; font.pixelSize: 12; color: SettingsTheme.muted }
                        }
                        SettingsButton { visible: [3, 4, 5].indexOf(root.page) >= 0; text: "打开 DMS「" + root.pages[root.page].title + "」"; onClicked: root.nativeRequested(root.pages[root.page].tab) }
                        ColumnLayout {
                            visible: root.page === 7
                            Layout.fillWidth: true
                            spacing: 16
                            SettingsText { visible: !(root.source.snapshot.history || []).length; Layout.fillWidth: true; text: "尚无本插件的修改记录。读取设置不会产生修改记录。"; color: SettingsTheme.muted }
                            Repeater {
                                model: root.source.snapshot.history || []
                                ColumnLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: 4
                                    SettingsText { Layout.fillWidth: true; text: modelData.at + " · " + modelData.action; font.pixelSize: 12; color: SettingsTheme.muted }
                                    SettingsText { Layout.fillWidth: true; text: modelData.message; font.pixelSize: 13 }
                                    SettingsText { visible: !!modelData.backup; Layout.fillWidth: true; text: "备份：" + (modelData.backup || ""); font.pixelSize: 12; color: SettingsTheme.muted }
                                    Rectangle { Layout.fillWidth: true; height: 1; color: SettingsTheme.subtle }
                                }
                            }
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: SettingsTheme.subtle }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 64
                    Layout.leftMargin: root.width < 1100 ? 24 : 48
                    Layout.rightMargin: root.width < 1100 ? 24 : 48
                    spacing: 12
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        SettingsText { Layout.fillWidth: true; text: root.source.busy ? "正在处理…" : root.pageErrors ? "请检查当前分类的输入" : root.pageDirty ? "当前分类有待应用修改" : "当前分类尚未修改"; font.pixelSize: 12; color: SettingsTheme.muted }
                        SettingsText { Layout.fillWidth: true; text: root.source.snapshot.readAt ? "读取于 " + new Date(root.source.snapshot.readAt).toLocaleTimeString(Qt.locale("zh_CN"), "HH:mm:ss") : "尚无配置数据"; font.pixelSize: 12; color: SettingsTheme.muted }
                    }
                    SettingsButton { iconName: "info"; help: "查看状态与能力原因"; onClicked: root.details = !root.details }
                    SettingsButton {
                        text: "放弃修改"
                        enabled: !root.source.busy && !root.preview && (root.pageDirty || root.pageErrors)
                        onClicked: { root.source.discard(root.pageId); if (root.page === 1 && displayLoader.item) displayLoader.item.reset(); }
                    }
                    SettingsButton {
                        text: root.page === 1 ? "临时切换" : "应用修改"
                        primary: true
                        enabled: root.pageDirty && !root.source.busy && !root.preview && !root.pageConflict && !root.source.stale && !root.pageErrors && (root.page !== 1 || root.source.snapshot.displayWritable)
                        onClicked: {
                            if (root.page === 1) displayLoader.item.submit();
                            else root.source.apply(root.pageId);
                        }
                    }
                }
            }
        }
    }
}
