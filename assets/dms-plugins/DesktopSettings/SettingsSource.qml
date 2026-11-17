import QtQuick
import Quickshell.Io

Item {
    id: root
    property string helperPath: decodeURIComponent(Qt.resolvedUrl("desktop-settings-helper").toString().replace(/^file:\/\//, ""))
    property var snapshot: ({settings: [], outputs: [], history: [], warnings: []})
    property var drafts: ({})
    property var errors: ({})
    property var revisions: ({})
    property var queue: []
    property bool applying: false
    property bool running: false
    readonly property bool busy: running || applying
    property bool loaded: false
    property bool stale: false
    property string state: "degraded"
    property string reason: "loading"
    property string message: "正在读取桌面配置…"
    property string action: ""
    property string input: ""
    readonly property int draftCount: Object.keys(drafts).length
    readonly property var protectionSettings: ((snapshot.system || {}).configs || []).map(c => ({id: c.id, page: "cachyos", section: "protection", group: "cachyos", label: c.label, icon: "settings-2", kind: "bool", value: c.protected, state: c.state, reason: c.reason, description: c.path + "\n" + root.configDescription(c)}))
    readonly property var allSettings: (snapshot.settings || []).concat(protectionSettings)
    signal completed(string action, var result)

    function readableReason(reason) {
        return {service_active: "服务已运行", service_inactive: "服务未运行", service_query_failed: "无法读取用户服务", unit_not_found: "系统中未安装此服务", manifest_unreadable: "无法读取托管清单", cachyos_not_installed: "未找到 CachyOS 桌面托管清单", ambiguous_manifest: "托管清单存在重复项", protection_unreadable: "保护清单不可读", unsafe_protection_path: "保护清单路径包含符号链接", config_not_managed: "文件未登记为托管配置", unsafe_config_path: "配置路径包含符号链接或无法访问", config_unreadable: "无法读取配置文件", unsafe_asset_path: "安装资源路径不安全", asset_unreadable: "无法读取安装资源", dms_settings_unavailable: "DMS 设置接口不可达", unsupported_value: "当前值不在支持的选项或范围内", config_parse_failed: "无法安全解析配置", ambiguous_config: "配置中出现重复或不明确的节点", input_owned_by_include: "输入配置由引用文件管理，请使用对应的 DMS 设置入口", window_owned_by_include: "窗口规则由引用文件管理，插件不会覆盖该文件"}[reason] || "请检查当前能力状态并重新读取";
    }
    function configDescription(config) {
        const status = {current: "与安装资源一致", modified: "文件已修改", missing: "文件不存在", unknown: "文件状态未知"}[config.status] || "文件状态未知";
        return status + " · " + (config.protected ? "已保护，配置更新会跳过" : "未保护，配置更新可能覆盖");
    }
    function owner(setting) { return setting.group === "dms" ? "dms" : setting.group === "cachyos" ? "cachyos" : "niri"; }
    function revisionFor(kind, data) { return kind === "dms" ? data.dmsRevision : kind === "cachyos" ? (data.system || {}).revision : data.revision; }
    function keyFor(setting) { return setting.page + ":" + owner(setting); }
    function settingsFor(page) { return allSettings.filter(s => s.page === page); }
    function dirtyFor(page) { return settingsFor(page).some(s => changed(s.id)); }
    function errorsFor(page) { return settingsFor(page).some(s => !!errors[s.id]); }
    function conflictFor(page) {
        return settingsFor(page).some(s => changed(s.id) && revisions[keyFor(s)] !== revisionFor(owner(s), snapshot));
    }
    function request(name, data) {
        if (busy) return;
        startRequest(name, data);
    }
    function startRequest(name, data) {
        action = name;
        input = JSON.stringify(data || {});
        running = true;
        message = name === "snapshot" ? "正在读取桌面配置…" : "正在校验并处理当前分类的更改…";
        worker.stdinEnabled = true;
        worker.command = [helperPath, name];
        worker.running = true;
    }
    function valueFor(setting) { return changed(setting.id) ? drafts[setting.id] : setting.value; }
    function changed(id) { return Object.prototype.hasOwnProperty.call(drafts, id); }
    function setDraft(setting, value) {
        if (busy || setting.state !== "healthy") return;
        const bases = Object.assign({}, revisions);
        if (!Object.prototype.hasOwnProperty.call(bases, keyFor(setting))) bases[keyFor(setting)] = revisionFor(owner(setting), snapshot);
        revisions = bases;
        const next = Object.assign({}, drafts);
        if (JSON.stringify(value) === JSON.stringify(setting.value)) delete next[setting.id];
        else next[setting.id] = value;
        drafts = next;
        setError(setting.id, "");
        cleanRevisions();
    }
    function setError(id, text) { const next = Object.assign({}, errors); if (text) next[id] = text; else delete next[id]; errors = next; }
    function cleanRevisions() {
        const bases = {};
        for (const s of allSettings) if (changed(s.id)) bases[keyFor(s)] = revisions[keyFor(s)];
        revisions = bases;
    }
    function discard(page) {
        const next = Object.assign({}, drafts), errs = Object.assign({}, errors);
        for (const s of settingsFor(page)) { delete next[s.id]; delete errs[s.id]; }
        drafts = next; errors = errs;
        cleanRevisions();
    }
    function rebase(page) {
        const bases = Object.assign({}, revisions);
        for (const s of settingsFor(page)) if (changed(s.id)) bases[keyFor(s)] = revisionFor(owner(s), snapshot);
        revisions = bases;
    }
    function apply(page) {
        if (busy || stale || conflictFor(page) || errorsFor(page)) return;
        const requests = [];
        for (const kind of ["niri", "dms", "cachyos"]) {
            const changes = {};
            for (const s of settingsFor(page)) if (owner(s) === kind && changed(s.id)) changes[s.id] = drafts[s.id];
            if (Object.keys(changes).length) requests.push({revision: revisions[page + ":" + kind], changes: changes});
        }
        if (!requests.length) return;
        queue = requests;
        applying = true;
        nextRequest();
    }
    function nextRequest() {
        if (!queue.length) { applying = false; return; }
        const pending = queue[0]; queue = queue.slice(1);
        startRequest("apply", pending);
    }
    function advanceDMS(before, after, applied) {
        if (!applied.some(id => id.indexOf("dms.") === 0)) return;
        const remaining = (before.settings || []).filter(s => s.group === "dms" && applied.indexOf(s.id) < 0);
        if (!remaining.every(old => (after.settings || []).some(s => s.id === old.id && s.state === old.state && JSON.stringify(s.value) === JSON.stringify(old.value)))) return;
        const bases = Object.assign({}, revisions);
        for (const key in bases) if (key.endsWith(":dms") && bases[key] === before.dmsRevision) bases[key] = after.dmsRevision;
        revisions = bases;
    }
    function ingest(result) {
        state = result.state || "unreachable";
        reason = result.reason || "unknown";
        message = result.message || "辅助程序未返回可读结果";
        if (result.data && result.data.settings) {
            advanceDMS(snapshot, result.data, result.applied || []);
            snapshot = result.data;
            loaded = true;
            stale = false;
        } else if (!result.ok) stale = loaded;
        if (result.applied) {
            const next = Object.assign({}, drafts);
            for (const id of result.applied) delete next[id];
            drafts = next;
            cleanRevisions();
        }
        const done = action;
        if (applying) {
            if (result.ok) nextRequest();
            else { queue = []; applying = false; }
        }
        completed(done, result);
    }
    Process {
        id: worker
        stdinEnabled: true
        onStarted: { write(root.input); stdinEnabled = false; }
        stdout: StdioCollector { id: output }
        stderr: StdioCollector { id: errorsOutput }
        onExited: (code) => {
            root.running = false;
            let result;
            try { result = JSON.parse(output.text); }
            catch (error) {
                result = {ok: false, state: "unreachable", reason: "helper_unavailable", message: "无法读取设置程序结果，请重新读取。草稿仍保留。" + (errorsOutput.text ? " " + errorsOutput.text.slice(0, 400) : "")};
            }
            root.ingest(result);
        }
    }
}
