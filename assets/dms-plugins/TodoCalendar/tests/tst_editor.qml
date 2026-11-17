import QtQuick
import QtTest
import ".."
import "../Calendar.js" as Calendar

Item {
    width: 400
    height: 640
    QtObject {
        id: backend
        property var notes: []
        property bool busy: false
        property bool loaded: true
        property bool stale: false
        property var sent: null
        signal completed(string action, var result, var request)
        function request(action, data) {
            if (busy) return false;
            sent = Object.assign({}, data, {action: action});
            busy = true;
            return true;
        }
    }
    CalendarEditor { id: editor; anchors.fill: parent; source: backend }
    TestCase {
        name: "CalendarEditor"
        when: windowShown
        function init() {
            backend.busy = false; backend.loaded = true; backend.stale = false; backend.notes = []; backend.sent = null;
            editor.cache = ({}); editor.draft = null; editor.original = null; editor.key = ""; editor.conflict = false;
            editor.date = "2026-10-29";
            editor.aiTab = false;
        }
        function test_newDraftAndDiscard() {
            editor.create();
            compare(editor.draft.diary_date, "2026-10-29");
            verify(editor.dirty);
            editor.update("body_markdown", "- [ ] 测试待办");
            compare(editor.items.length, 1);
            editor.discard();
            compare(editor.draft, null);
            compare(editor.draftCount, 0);
        }
        function test_switchDatesRestoresDraft() {
            editor.create();
            editor.update("body_markdown", "未保存的中文草稿");
            editor.showDay("2026-10-30");
            compare(editor.draft, null);
            editor.showDay("2026-10-29");
            compare(editor.draft.body_markdown, "未保存的中文草稿");
            verify(editor.dirty);
        }
        function test_savedRecordDoesNotBecomeDirtyOnLoad() {
            editor.openNote("record-a");
            backend.busy = false;
            const note = {id: "record-a", title: "记录", body_markdown: "原正文", diary_date: "2026-10-29", status: "active", pinned: false, tags: ["标签"], revision: 2, created_at_ms: 1, updated_at_ms: 2, deleted_at_ms: null};
            backend.completed("get", {ok: true, data: {note: note}}, {id: "record-a"});
            wait(0);
            verify(!editor.dirty);
            compare(editor.draft.body_markdown, "原正文");
            compare(editor.draft.tags[0], "标签");
        }
        function test_typingDuringSaveKeepsNewInputAndUpdatesRevision() {
            editor.create();
            editor.update("body_markdown", "第一版");
            editor.save();
            const request = Calendar.copy(backend.sent);
            editor.update("body_markdown", "保存期间继续输入的第二版");
            const saved = Object.assign({}, request.note, {id: "saved-a", revision: 1, created_at_ms: 1, updated_at_ms: 1});
            backend.busy = false;
            backend.completed("save", {ok: true, data: {note: saved}}, request);
            wait(0);
            compare(editor.draft.body_markdown, "保存期间继续输入的第二版");
            compare(editor.draft.revision, 1);
            compare(editor.draft.id, "saved-a");
            verify(editor.dirty);
            editor.save();
            compare(backend.sent.note.revision, 1);
        }
        function test_saveAcknowledgementIgnoresObjectKeyOrder() {
            editor.create();
            editor.update("body_markdown", "真实 JSON 往返会改变字段顺序");
            editor.save();
            const reordered = {};
            Object.keys(backend.sent.note).sort().forEach(key => reordered[key] = backend.sent.note[key]);
            const request = {note: reordered};
            const saved = Object.assign({}, reordered, {revision: 1, created_at_ms: 1, updated_at_ms: 1});
            backend.busy = false;
            backend.completed("save", {ok: true, data: {note: saved}}, request);
            verify(!editor.dirty);
            compare(editor.draft.body_markdown, "真实 JSON 往返会改变字段顺序");
        }
        function test_failedSaveKeepsDraftAndConflictBlocksOverwrite() {
            editor.create(); editor.update("title", "必须保留"); editor.save();
            const request = backend.sent;
            backend.busy = false;
            backend.completed("save", {ok: false, reason: "revision_conflict"}, request);
            compare(editor.draft.title, "必须保留");
            verify(editor.dirty);
            verify(editor.conflict);
            backend.sent = null;
            editor.save();
            compare(backend.sent, null);
        }
        function test_appendSummaryRetainsExistingInputAndDoesNotSave() {
            editor.create();
            editor.update("title", "自己的标题");
            editor.update("body_markdown", "已有草稿");
            verify(editor.appendSummary({local_date: "2026-10-29", title: "AI 标题", markdown_body: "AI 总结"}));
            compare(editor.draft.title, "自己的标题");
            compare(editor.draft.body_markdown, "已有草稿\n\n---\n\nAI 总结");
            compare(backend.sent, null);
            verify(editor.dirty);
            verify(!editor.appendSummary({local_date: "2026-10-30", title: "错误日期", markdown_body: "不应串入"}));
            compare(editor.draft.body_markdown, "已有草稿\n\n---\n\nAI 总结");
        }
        function test_appendCreatesDraftAndPreservesOtherDateDraft() {
            editor.create(); editor.update("body_markdown", "昨天的草稿");
            editor.showDay("2026-10-30");
            verify(editor.appendSummary({local_date: "2026-10-30", title: "工作日志", markdown_body: "当天总结"}));
            compare(editor.draft.title, "工作日志");
            compare(editor.draft.body_markdown, "当天总结");
            editor.showDay("2026-10-29");
            compare(editor.draft.body_markdown, "昨天的草稿");
        }
        function test_checklistChangesOnlyMarker() {
            editor.create();
            const body = "前言\r\n- [ ] 第一项\r\n";
            editor.update("body_markdown", body);
            editor.update("body_markdown", Calendar.toggle(editor.draft.body_markdown, 0, true));
            compare(editor.draft.body_markdown, "前言\r\n- [x] 第一项\r\n");
            compare(editor.items[0].checked, true);
        }
    }
}
