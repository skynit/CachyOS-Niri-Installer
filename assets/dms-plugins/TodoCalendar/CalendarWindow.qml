import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Templates as T
import Quickshell
import qs.Common
import qs.Widgets
import "Calendar.js" as Calendar

FloatingWindow {
    id: root
    required property var source
    property string today: Calendar.dateKey(new Date())
    property string selectedDate: today
    property bool listMode: false
    readonly property var days: Calendar.days(source.month, today)
    readonly property int drafts: editor.draftCount
    title: "待办日历"
    implicitWidth: 1280
    implicitHeight: 800
    minimumSize: Qt.size(960, 640)
    color: Theme.surfaceContainer
    visible: false

    function open() {
        today = Calendar.dateKey(new Date());
        visible = true;
        minimized = false;
        if (!source.busy) source.refresh();
    }
    function openAI() { editor.aiTab = true; journal.load(); }
    function aiStatus() { return JSON.stringify({date: selectedDate, busy: journal.busy, task_date: journal.taskDate, state: journal.stateText, message: journal.statusText, has_summary: journal.entry !== null && journal.entry.summary !== null}); }
    function closeCalendar() { editor.stash(); visible = false; }
    onClosed: editor.stash()
    function selectDay(day) {
        if (source.busy) return;
        selectedDate = day;
        editor.showDay(day);
    }
    function changeMonth(amount) {
        if (source.busy) return;
        const next = Calendar.addMonth(source.month, amount);
        if (Number(next.slice(0, 4)) < 1 || Number(next.slice(0, 4)) > 9998) return;
        source.month = next;
        selectDay(next === today.slice(0, 7) ? today : next + "-01");
        if (!source.busy) source.refresh();
    }
    function goToday() {
        if (source.busy) return;
        today = Calendar.dateKey(new Date());
        source.month = today.slice(0, 7);
        selectDay(today);
        if (!source.busy) source.refresh();
    }
    function navigate(key) {
        const amount = key === Qt.Key_Left ? -1 : key === Qt.Key_Right ? 1 : key === Qt.Key_Up ? -7 : key === Qt.Key_Down ? 7 : 0;
        if (!amount || source.busy) return false;
        const date = Calendar.addDays(selectedDate, amount);
        if (date < days[0].date || date > days[41].date) {
            source.month = date.slice(0, 7);
            selectDay(date);
            if (!source.busy) source.refresh();
        } else selectDay(date);
        Qt.callLater(() => {
            const index = root.days.findIndex(d => d.date === root.selectedDate);
            if (index >= 0) cells.itemAt(index).forceActiveFocus();
        });
        return true;
    }
    CalendarJournal { id: journal; date: root.selectedDate }
    FileDialog {
        id: importer
        title: "导入原应用记录（仅读取源文件）"
        fileMode: FileDialog.OpenFile
        nameFilters: ["记录文件 (*.json *.sqlite3 *.sqlite *.db)", "所有文件 (*)"]
        currentFolder: StandardPaths.writableLocation(StandardPaths.HomeLocation)
        onAccepted: {
            const path = selectedFile.toString();
            if (path.startsWith("file://")) root.source.request("import", {path: decodeURIComponent(path.slice(7))});
        }
    }
    Timer {
        interval: 30000
        running: root.visible
        repeat: true
        onTriggered: root.today = Calendar.dateKey(new Date())
    }
    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: event => {
            if (!Qt.inputMethod.visible) { root.closeCalendar(); event.accepted = true; }
        }
        Shortcut { sequence: "Ctrl+S"; enabled: root.visible; onActivated: editor.save() }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: root.width < 1100 ? 16 : 24
            spacing: 12
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                DankIcon { name: "calendar_month"; size: 24; color: Theme.primary }
                CalendarText { text: "待办日历"; font.pixelSize: 20; font.weight: Font.Bold }
                Item { Layout.fillWidth: true }
                CalendarButton { text: "导入旧记录"; iconName: "file_download"; enabled: !root.source.busy; help: "导入原应用 JSON 或 notes.sqlite3；源文件只读"; onClicked: importer.open() }
                CalendarButton { iconName: "close"; help: "关闭日历，保留未保存草稿"; onClicked: root.closeCalendar() }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                CalendarText { text: Number(root.source.month.slice(0, 4)) + "年" + Number(root.source.month.slice(5, 7)) + "月"; font.pixelSize: 20; font.weight: Font.DemiBold; Layout.minimumWidth: 144 }
                CalendarButton { text: "今天"; enabled: !root.source.busy; onClicked: root.goToday() }
                CalendarButton { iconName: "chevron_left"; help: "上个月"; enabled: !root.source.busy; onClicked: root.changeMonth(-1) }
                CalendarButton { iconName: "chevron_right"; help: "下个月"; enabled: !root.source.busy; onClicked: root.changeMonth(1) }
                CalendarButton { iconName: "refresh"; help: "刷新本地记录"; enabled: !root.source.busy; onClicked: root.source.refresh() }
                Item { Layout.fillWidth: true }
                CalendarButton { text: "日历"; iconName: "calendar_month"; selected: !root.listMode; onClicked: root.listMode = false }
                CalendarButton { text: "列表"; iconName: "format_list_bulleted"; selected: root.listMode; onClicked: root.listMode = true }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                DankIcon { name: root.source.busy ? "hourglass_empty" : root.source.capabilityState === "healthy" ? "check_circle" : "warning"; size: 16; color: root.source.capabilityState === "healthy" ? Theme.success : Theme.warning }
                CalendarText { Layout.fillWidth: true; text: (root.source.busy ? "正在处理本地记录" : root.source.message) + (root.source.stale ? " · 上次读取的内容可能已过期" : ""); font.pixelSize: 12; color: root.source.capabilityState === "healthy" ? Theme.surfaceVariantText : Theme.warning; Accessible.role: Accessible.StaticText }
                CalendarText { Layout.maximumWidth: 256; text: root.source.capabilityState + " / " + root.source.reason; font.pixelSize: 12; color: Theme.surfaceVariantText; wrapMode: Text.WrapAnywhere }
                CalendarButton { text: "重试"; visible: root.source.capabilityState !== "healthy" && !root.source.busy; onClicked: root.source.refresh() }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 16
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    ColumnLayout {
                        anchors.fill: parent
                        visible: !root.listMode
                        spacing: 8
                        Row {
                            Layout.fillWidth: true
                            Repeater {
                                model: ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
                                CalendarText { required property string modelData; width: parent.width / 7; leftPadding: 8; text: modelData; font.pixelSize: 12; color: Theme.surfaceVariantText }
                            }
                        }
                        Grid {
                            id: calendarGrid
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            columns: 7
                            Repeater {
                                id: cells
                                model: root.days
                                T.Button {
                                    id: cell
                                    required property var modelData
                                    required property int index
                                    readonly property var records: root.source.notes.filter(n => n.diary_date === modelData.date)
                                    width: calendarGrid.width / 7
                                    height: calendarGrid.height / 6
                                    enabled: !root.source.busy
                                    activeFocusOnTab: modelData.date === root.selectedDate
                                    hoverEnabled: true
                                    Accessible.name: modelData.date + (modelData.today ? "，今天" : "") + (root.source.loaded ? "，" + records.length + " 条记录" : "，记录尚未读取")
                                    Accessible.role: Accessible.Button
                                    onClicked: root.selectDay(modelData.date)
                                    onDoubleClicked: { root.selectDay(modelData.date); if (!records.length) editor.create(); }
                                    Keys.onPressed: event => {
                                        if (root.navigate(event.key)) event.accepted = true;
                                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { root.selectDay(modelData.date); if (!records.length) editor.create(); event.accepted = true; }
                                    }
                                    background: Rectangle {
                                        color: cell.modelData.date === root.selectedDate || cell.hovered ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                                        border.width: cell.activeFocus ? 2 : 1
                                        border.color: cell.activeFocus || cell.modelData.date === root.selectedDate ? Theme.primary : Theme.outlineVariant
                                    }
                                    contentItem: Item {
                                        clip: true
                                        Column {
                                            x: 8; y: 8; width: parent.width - 16
                                            spacing: 4
                                            RowLayout {
                                                width: parent.width
                                                CalendarText { text: cell.modelData.number; font.pixelSize: 13; font.weight: Font.Medium; color: cell.modelData.today ? Theme.primary : cell.modelData.adjacent ? Theme.surfaceVariantText : Theme.surfaceText }
                                                Item { Layout.fillWidth: true }
                                                CalendarText { visible: cell.modelData.today; text: "今天"; font.pixelSize: 12; color: Theme.primary }
                                            }
                                            Repeater {
                                                model: cell.records.slice(0, cell.height >= 96 ? 2 : 1)
                                                CalendarText {
                                                    required property var modelData
                                                    width: parent.width
                                                    text: (modelData.status === "completed" ? "✓ " : "· ") + (modelData.title || modelData.preview || "无标题")
                                                    font.pixelSize: 12
                                                    font.strikeout: modelData.status === "completed"
                                                    color: modelData.status === "completed" ? Theme.success : Theme.surfaceText
                                                    wrapMode: Text.NoWrap
                                                    elide: Text.ElideRight
                                                }
                                            }
                                            CalendarText { visible: cell.records.length > (cell.height >= 96 ? 2 : 1); text: "+" + (cell.records.length - (cell.height >= 96 ? 2 : 1)) + " 条"; font.pixelSize: 12; color: Theme.surfaceVariantText }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    ColumnLayout {
                        anchors.fill: parent
                        visible: root.listMode
                        spacing: 8
                        CalendarText { Layout.fillWidth: true; text: "当前日历范围及无日期记录 · 按置顶和更新时间排列"; font.pixelSize: 12; color: Theme.surfaceVariantText }
                        ListView {
                            id: recordList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            model: root.source.notes
                            ScrollBar.vertical: ScrollBar {}
                            delegate: ItemDelegate {
                                id: row
                                required property var modelData
                                width: recordList.width
                                height: 64
                                enabled: !root.source.busy
                                Accessible.name: (modelData.title || "无标题") + "，" + Calendar.statusLabel(modelData.status)
                                onClicked: { root.selectedDate = modelData.diary_date || root.today; editor.date = root.selectedDate; editor.openNote(modelData.id); }
                                background: Rectangle { color: row.hovered || row.activeFocus ? Theme.surfaceContainerHigh : Theme.surfaceContainer; border.width: row.activeFocus ? 2 : 0; border.color: Theme.primary }
                                contentItem: RowLayout {
                                    spacing: 12
                                    CalendarText { Layout.preferredWidth: 56; text: Calendar.statusLabel(row.modelData.status); font.pixelSize: 12; color: row.modelData.status === "completed" ? Theme.success : Theme.surfaceVariantText }
                                    CalendarText { Layout.preferredWidth: 88; text: row.modelData.diary_date || "无日期"; font.pixelSize: 12; color: Theme.surfaceVariantText }
                                    Column {
                                        Layout.fillWidth: true
                                        CalendarText { width: parent.width; text: row.modelData.title || "无标题"; wrapMode: Text.NoWrap; elide: Text.ElideRight; font.pixelSize: 13 }
                                        CalendarText { width: parent.width; text: row.modelData.preview || "无正文"; wrapMode: Text.NoWrap; elide: Text.ElideRight; font.pixelSize: 12; color: Theme.surfaceVariantText }
                                    }
                                    CalendarText { visible: row.modelData.total > 0; text: row.modelData.done + "/" + row.modelData.total; font.pixelSize: 12; color: Theme.surfaceVariantText }
                                }
                            }
                        }
                        CalendarText { Layout.fillWidth: true; visible: root.source.loaded && root.source.notes.length === 0 && !root.source.stale; text: "当前范围暂无记录"; horizontalAlignment: Text.AlignHCenter; color: Theme.surfaceVariantText }
                    }
                }
                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.outlineVariant }
                CalendarEditor { id: editor; source: root.source; journal: journal; Layout.preferredWidth: root.width < 1100 ? 280 : 336; Layout.fillHeight: true }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
            RowLayout {
                Layout.fillWidth: true
                CalendarText { Layout.fillWidth: true; text: root.drafts ? root.drafts + " 份未保存草稿 · 关闭窗口后仍保留，退出 DMS 前请保存" : "方向键选择日期 · Enter 编辑 · Ctrl+S 保存 · Esc 关闭"; font.pixelSize: 12; color: root.drafts ? Theme.warning : Theme.surfaceVariantText }
                CalendarText { text: root.source.readAt ? "读取于 " + Qt.formatDateTime(new Date(root.source.readAt), "HH:mm:ss") : "尚未读取"; font.pixelSize: 12; color: Theme.surfaceVariantText }
            }
        }
    }
}
