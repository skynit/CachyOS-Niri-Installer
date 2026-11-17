import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import "Calendar.js" as Calendar

Item {
    id: root
    required property var source
    property string date: Calendar.dateKey(new Date())
    property var draft: null
    property var original: null
    property var cache: ({})
    property string key: ""
    property bool bodyTab: false
    property bool aiTab: false
    property var journal: null
    property bool confirmDelete: false
    property bool conflict: false
    readonly property bool dirty: draft !== null && !Calendar.equal(draft, original)
    readonly property int draftCount: Object.keys(cache).length + (dirty && !cache[key] ? 1 : 0)
    readonly property var dayNotes: source.notes.filter(n => n.diary_date === date)
    readonly property var items: Calendar.checklist(draft ? draft.body_markdown : "")

    function stash() {
        if (!key) return;
        const next = Object.assign({}, cache);
        if (dirty) next[key] = {draft: Calendar.copy(draft), original: Calendar.copy(original), conflict: conflict};
        else delete next[key];
        cache = next;
    }
    function restore(nextKey) {
        stash();
        key = nextKey;
        confirmDelete = false;
        conflict = false;
        if (cache[key]) {
            draft = Calendar.copy(cache[key].draft);
            original = Calendar.copy(cache[key].original);
            conflict = cache[key].conflict;
            return true;
        }
        draft = null;
        original = null;
        return false;
    }
    function showDay(day) {
        stash();
        date = day;
        const newKey = "new:" + day;
        if (cache[newKey]) { restore(newKey); return; }
        if (dayNotes.length) openNote(dayNotes[0].id);
        else restore(newKey);
    }
    function openNote(id) {
        if (source.busy) return;
        if (!restore(id)) source.request("get", {id: id});
    }
    function create() {
        if (!source.loaded || source.busy || source.stale) return;
        const newKey = "new:" + date;
        if (restore(newKey)) return;
        original = null;
        draft = {id: Calendar.newID(), title: date + " 记录", body_markdown: "", diary_date: date, tags: [], status: "active", pinned: false, created_at_ms: 0, updated_at_ms: 0, deleted_at_ms: null, revision: 0};
        bodyTab = true;
        Qt.callLater(() => titleInput.forceActiveFocus());
    }
    function update(field, value) {
        if (!draft || Calendar.equal(draft[field], value)) return;
        const next = Calendar.copy(draft);
        next[field] = value;
        draft = next;
        confirmDelete = false;
    }
    function appendSummary(summary) {
        if (!summary || summary.local_date !== date || source.busy || !source.loaded || source.stale || conflict) return false;
        if (!draft) {
            if (dayNotes.length) return false;
            create();
        }
        if (!draft || draft.diary_date !== summary.local_date) return false;
        const body = draft.body_markdown;
        update("body_markdown", body.trim() ? body + "\n\n---\n\n" + summary.markdown_body : summary.markdown_body);
        if (!draft.title.trim() || draft.title === date + " 记录") update("title", summary.title);
        bodyTab = true; aiTab = false;
        return true;
    }
    function save() {
        if (!draft || !dirty || source.busy || conflict) return;
        source.request("save", {note: Calendar.copy(draft)});
    }
    function reload() {
        if (!draft || !draft.id || source.busy) return;
        const id = draft.id;
        const next = Object.assign({}, cache);
        delete next[key]; cache = next;
        original = Calendar.copy(draft);
        conflict = false;
        source.request("get", {id: id});
    }
    function discard() {
        if (source.busy) return;
        const id = draft && (draft.revision > 0 || conflict) ? draft.id : "";
        const next = Object.assign({}, cache);
        delete next[key]; cache = next;
        draft = null; original = null; conflict = false;
        if (id) source.request("get", {id: id});
    }
    Connections {
        target: root.source
        function onCompleted(action, result, request) {
            if (action === "get" && result.ok) {
                root.original = Calendar.copy(result.data.note);
                root.draft = Calendar.copy(result.data.note);
                root.conflict = false;
            } else if (action === "save" && result.ok) {
                const saved = result.data.note;
                const unchanged = Calendar.equal(root.draft, request.note);
                const nextCache = Object.assign({}, root.cache);
                delete nextCache[root.key]; root.cache = nextCache;
                root.key = saved.id;
                root.original = Calendar.copy(saved);
                if (unchanged) root.draft = Calendar.copy(saved);
                else root.draft = Object.assign({}, root.draft, {id: saved.id, revision: saved.revision, created_at_ms: saved.created_at_ms, updated_at_ms: saved.updated_at_ms});
            } else if (action === "save" && (result.reason === "revision_conflict" || result.reason === "durability_unconfirmed")) root.conflict = true;
            else if (action === "delete" && result.ok) {
                const nextCache = Object.assign({}, root.cache);
                delete nextCache[root.key]; root.cache = nextCache;
                root.draft = null; root.original = null; root.key = "";
                root.confirmDelete = false;
                root.showDay(root.date);
            } else if ((action === "snapshot" || action === "import") && result.ok && !root.draft && root.dayNotes.length) root.openNote(root.dayNotes[0].id);
        }
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            CalendarText { Layout.fillWidth: true; text: root.date; font.pixelSize: 16; font.weight: Font.DemiBold }
            CalendarButton { iconName: "add"; help: "新增当天记录"; enabled: root.source.loaded && !root.source.busy && !root.source.stale && !(root.draft && root.draft.revision === 0); onClicked: root.create() }
        }
        ComboBox {
            id: picker
            Layout.fillWidth: true
            visible: root.dayNotes.length > 1
            enabled: !root.source.busy
            model: root.dayNotes
            textRole: "title"
            valueRole: "id"
            currentIndex: root.dayNotes.findIndex(n => root.draft && n.id === root.draft.id)
            Accessible.name: "选择当天记录"
            onActivated: root.openNote(currentValue)
        }
        RowLayout {
            Layout.fillWidth: true
            CalendarButton { text: "待办"; selected: !root.bodyTab && !root.aiTab; onClicked: { root.bodyTab = false; root.aiTab = false; } }
            CalendarButton { text: "正文"; selected: root.bodyTab && !root.aiTab; onClicked: { root.bodyTab = true; root.aiTab = false; } }
            CalendarButton { text: "AI 总结"; visible: root.journal !== null; selected: root.aiTab; onClicked: { root.aiTab = true; root.journal.load(); } }
            Item { Layout.fillWidth: true }
        }
        CalendarText {
            Layout.fillWidth: true
            visible: root.draft !== null
            text: root.source.busy ? "正在处理" : root.conflict ? "版本冲突" : root.dirty ? "未保存" : "已保存"
            font.pixelSize: 12
            color: root.dirty || root.conflict ? Theme.warning : Theme.surfaceVariantText
            Accessible.role: Accessible.StaticText
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.outlineVariant }
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.aiTab && root.journal !== null
            active: visible
            sourceComponent: CalendarAI { journal: root.journal; editor: root }
        }
        ColumnLayout {
            visible: root.draft !== null && !root.aiTab
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8
            CalendarField {
                id: titleInput
                Layout.fillWidth: true
                text: root.draft ? root.draft.title : ""
                placeholderText: "记录标题"
                maximumLength: 512
                Accessible.name: "记录标题"
                onTextEdited: root.update("title", text)
            }
            RowLayout {
                Layout.fillWidth: true
                ComboBox {
                    id: statusInput
                    Layout.fillWidth: true
                    model: ["草稿", "记录中", "已完成", "已归档"]
                    currentIndex: root.draft ? ["draft", "active", "completed", "archived"].indexOf(root.draft.status) : 1
                    Accessible.name: "记录状态"
                    onActivated: root.update("status", ["draft", "active", "completed", "archived"][currentIndex])
                }
                CheckBox {
                    text: "置顶"
                    checked: root.draft ? root.draft.pinned : false
                    Accessible.name: "置顶记录"
                    onToggled: root.update("pinned", checked)
                    palette.windowText: Theme.surfaceText
                }
            }
            ScrollView {
                id: bodyScroll
                visible: root.bodyTab
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                TextArea {
                    id: bodyInput
                    property bool syncingText: false
                    property string sourceText: root.draft ? root.draft.body_markdown : ""
                    onSourceTextChanged: {
                        syncingText = true;
                        text = sourceText;
                        syncingText = false;
                    }
                    onTextChanged: if (!syncingText && root.draft && text !== root.draft.body_markdown) root.update("body_markdown", text)
                    placeholderText: "输入正文；使用 - [ ] 待办事项 添加清单"
                    color: Theme.surfaceText
                    placeholderTextColor: Theme.surfaceVariantText
                    selectionColor: Theme.primary
                    selectedTextColor: Theme.primaryText
                    font.family: Theme.fontFamily
                    font.pixelSize: 14
                    font.letterSpacing: 0
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.PlainText
                    selectByMouse: true
                    activeFocusOnTab: true
                    Accessible.name: "记录 Markdown 正文"
                    background: Rectangle { color: Theme.surfaceContainerLow; radius: 4; border.width: bodyInput.activeFocus ? 2 : 1; border.color: bodyInput.activeFocus ? Theme.primary : Theme.outlineVariant }
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Tab && !inputMethodComposing) { nextItemInFocusChain(true).forceActiveFocus(); event.accepted = true; }
                    }
                }
            }
            ScrollView {
                visible: !root.bodyTab
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth
                Column {
                    width: parent.width
                    spacing: 8
                    CalendarText { visible: root.items.length === 0; width: parent.width; text: "暂无待办。可在正文中添加 Markdown 清单。"; font.pixelSize: 13; color: Theme.surfaceVariantText }
                    Repeater {
                        model: root.items
                        CheckBox {
                            id: itemCheck
                            required property var modelData
                            width: parent.width
                            checked: modelData.checked
                            text: modelData.text || "未命名待办"
                            Accessible.name: text
                            onToggled: root.update("body_markdown", Calendar.toggle(root.draft.body_markdown, modelData.index, checked))
                            contentItem: CalendarText {
                                leftPadding: 32
                                text: itemCheck.text
                                font.pixelSize: 13
                                font.strikeout: itemCheck.checked
                                color: itemCheck.checked ? Theme.surfaceVariantText : Theme.surfaceText
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }
            }
            CalendarText { visible: root.conflict; Layout.fillWidth: true; text: "当前草稿已保留。请先复制需要的内容，再放弃草稿并重新读取最新版本。"; color: Theme.warning; font.pixelSize: 12 }
            RowLayout {
                Layout.fillWidth: true
                CalendarButton { text: "保存"; iconName: "save"; primary: true; enabled: root.dirty && !root.source.busy && !root.conflict; onClicked: root.save() }
                CalendarButton { text: "放弃草稿"; visible: root.dirty || root.conflict; enabled: !root.source.busy; help: "放弃当前草稿并重新读取"; onClicked: root.discard() }
                Item { Layout.fillWidth: true }
                CalendarButton { iconName: "delete"; help: "删除当前记录"; danger: true; visible: root.draft && root.draft.revision > 0; enabled: !root.source.busy; onClicked: root.confirmDelete = !root.confirmDelete }
            }
            ColumnLayout {
                visible: root.confirmDelete
                Layout.fillWidth: true
                CalendarText { Layout.fillWidth: true; text: "删除此记录？未保存的修改也会放弃。"; font.pixelSize: 12; color: Theme.warning }
                RowLayout {
                    CalendarButton { text: "确认删除"; danger: true; enabled: !root.source.busy; onClicked: root.source.request("delete", {id: root.draft.id, expected_revision: root.draft.revision}) }
                    CalendarButton { text: "取消"; onClicked: root.confirmDelete = false }
                }
            }
        }
        Item {
            visible: root.draft === null && !root.aiTab
            Layout.fillWidth: true
            Layout.fillHeight: true
            Column {
                anchors.centerIn: parent
                width: parent.width
                spacing: 12
                CalendarText { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.source.busy ? "正在读取记录" : !root.source.loaded || root.source.stale ? "记录尚未确认" : "当天暂无记录"; font.weight: Font.Medium }
                CalendarText { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.source.busy ? "请稍候" : root.source.stale || !root.source.loaded ? "请刷新后重试" : "新增记录，开始记录当天待办"; color: Theme.surfaceVariantText; font.pixelSize: 12 }
            }
        }
        CalendarButton { Layout.fillWidth: true; text: "新增记录"; iconName: "add"; visible: !root.draft && !root.aiTab; enabled: root.source.loaded && !root.source.busy && !root.source.stale; onClicked: root.create() }
    }
}
