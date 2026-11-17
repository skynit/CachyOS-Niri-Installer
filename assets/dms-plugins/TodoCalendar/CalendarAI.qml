import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common

ColumnLayout {
    id: root
    required property var journal
    required property var editor
    readonly property var collection: journal.entry ? journal.entry.collection : null
    readonly property var summary: journal.entry ? journal.entry.summary : null
    property string appendMessage: ""
    property bool showSessions: false
    onSummaryChanged: appendMessage = ""
    function explain(reason) {
        const descriptions = {
            session_source_ready: "来源已读取",
            journal_prompt_limit_reached: "完整输入超限，已裁剪较早内容并保留最近更正",
            session_source_partial: "部分会话无法读取",
            session_corpus_limited: "会话内容超限，已保留最近内容",
            cc_switch_session_source_not_configured: "cc-switch 未配置此来源",
            cc_switch_session_source_not_tracked: "cc-switch 未跟踪此来源的当天会话",
            cc_switch_usage_ready: "用量已读取",
            cc_switch_no_usage_observed: "当天未观察到用量",
            cc_switch_session_sync_stale: "会话同步已过期",
            cc_switch_input_token_semantics_mixed: "输入 Token 的统计口径混合",
            cc_switch_usage_semantics_unknown: "用量统计口径未知",
            cc_switch_usage_query_failed: "用量读取失败",
            cc_switch_sync_query_failed: "同步时间读取失败"
        };
        return (descriptions[reason] ? descriptions[reason] + "\n" : "") + reason;
    }
    spacing: 8
    CalendarText { Layout.fillWidth: true; text: "当天 AI 会话"; font.pixelSize: 16; font.weight: Font.DemiBold }
    CalendarText { Layout.fillWidth: true; text: "从 cc-switch 本地索引采集；总结使用本机 Codex 的模型和登录配置。"; font.pixelSize: 12; color: Theme.surfaceVariantText }
    Flow {
        Layout.fillWidth: true
        spacing: 8
        CalendarButton { text: "采集当天会话"; enabled: !root.journal.busy; onClicked: root.journal.request("journal_collect") }
        CalendarButton { text: root.summary ? "重新生成" : "生成总结"; enabled: !root.journal.busy && root.collection && root.collection.sessions.some(s => s.eligibility.state === "included"); onClicked: root.journal.request("journal_summarize") }
        CalendarButton { text: "取消"; visible: root.journal.busy; enabled: !root.journal.cancelling; onClicked: root.journal.cancel() }
    }
    CalendarText { Layout.fillWidth: true; text: root.journal.statusText; font.pixelSize: 12; Accessible.role: Accessible.StaticText }
    CalendarText { Layout.fillWidth: true; text: root.journal.stateText; font.pixelSize: 12; color: Theme.surfaceVariantText }
    CalendarText { Layout.fillWidth: true; visible: root.journal.busy && root.journal.taskDate !== root.journal.date; text: root.journal.taskDate + " 的 AI 任务仍在运行，结果会保留在原日期。"; font.pixelSize: 12; color: Theme.warning }
    ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        contentWidth: availableWidth
        ColumnLayout {
            width: parent.width
            spacing: 8
            CalendarText { Layout.fillWidth: true; visible: root.collection !== null; text: root.collection ? root.collection.timezone + " · 缓存 " + new Date(root.journal.entry.updated_at_ms).toLocaleString() : ""; font.pixelSize: 12; color: Theme.surfaceVariantText }
            Repeater {
                model: root.collection ? root.collection.source_coverage : []
                CalendarText {
                    required property var modelData
                    Layout.fillWidth: true
                    text: modelData.source + " · " + modelData.state + "\n" + root.explain(modelData.reason) + (modelData.included_sessions === null ? "" : "\n纳入 " + modelData.included_sessions + " · 短会话 " + modelData.ignored_short_sessions)
                    font.pixelSize: 12
                }
            }
            CalendarText {
                Layout.fillWidth: true
                visible: root.collection !== null
                font.pixelSize: 12
                text: {
                    if (!root.collection) return "";
                    const u = root.collection.token_usage;
                    const number = n => n === null || n === undefined ? "未知" : String(n);
                    return "Token 用量 · " + u.state + "\n" + root.explain(u.reason) + "\n输入 " + number(u.input_tokens) + " · 输出 " + number(u.output_tokens) + "\n缓存读取 " + number(u.cache_read_tokens) + " · 创建 " + number(u.cache_creation_tokens) + "\n统计口径 " + u.total_method + "\n最近同步 " + (u.last_synced_at_ms ? new Date(u.last_synced_at_ms).toLocaleString() : "未知");
                }
            }
            CalendarButton { text: root.showSessions ? "收起会话详情" : "查看会话详情"; visible: root.collection !== null; onClicked: root.showSessions = !root.showSessions }
            Repeater {
                model: root.collection && root.showSessions ? root.collection.sessions : []
                CalendarText {
                    required property var modelData
                    Layout.fillWidth: true
                    text: modelData.source + " · " + modelData.title + "\n" + (modelData.eligibility.state === "included" ? "纳入总结" : "忽略短会话")
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                }
            }
            CalendarText { Layout.fillWidth: true; text: "AI 总结预览"; font.pixelSize: 16; font.weight: Font.DemiBold }
            CalendarText { Layout.fillWidth: true; visible: root.summary !== null; text: root.summary ? "总结生成于 " + new Date(root.journal.entry.summary_updated_at_ms).toLocaleString() + (root.journal.entry.updated_at_ms > root.journal.entry.summary_updated_at_ms ? " · 重新采集后保留的上次结果" : "") : ""; font.pixelSize: 12; color: Theme.surfaceVariantText }
            TextArea {
                Layout.fillWidth: true
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                text: root.summary ? root.summary.markdown_body : "生成后在此检查工作、知识和待办。结果按日期缓存。"
                color: Theme.surfaceText
                font.family: Theme.fontFamily
                font.pixelSize: 13
                background: null
                Accessible.name: "AI 总结 Markdown 预览"
            }
            CalendarText { Layout.fillWidth: true; visible: root.collection && root.collection.warnings.length > 0; text: root.collection ? root.collection.warnings.map(w => root.explain(w)).join("\n") : ""; font.pixelSize: 12; color: Theme.warning }
            CalendarText { Layout.fillWidth: true; visible: root.summary && root.summary.warnings.length > 0; text: root.summary ? root.summary.warnings.join("\n") : ""; font.pixelSize: 12; color: Theme.warning }
        }
    }
    CalendarButton {
        text: "追加到当天日志"
        enabled: root.summary !== null && !root.editor.source.busy && root.editor.source.loaded && !root.editor.source.stale && !root.editor.conflict && (root.editor.draft !== null || root.editor.dayNotes.length === 0)
        onClicked: root.appendMessage = root.editor.appendSummary(root.summary) ? "总结已追加到正文草稿，请检查后保存。" : "未追加：请先打开当天记录，核对日期与状态。"
    }
    CalendarText { Layout.fillWidth: true; text: root.appendMessage || "追加后仍需手动保存；不会自动写入知识库。"; font.pixelSize: 12; color: Theme.surfaceVariantText }
}
