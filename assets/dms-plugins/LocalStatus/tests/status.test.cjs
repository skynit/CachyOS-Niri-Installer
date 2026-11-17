const assert = require('node:assert/strict');
const { readFileSync, existsSync, readdirSync, mkdtempSync, mkdirSync, symlinkSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const status = vm.createContext({});
vm.runInContext(readFileSync(path.join(__dirname, '..', 'Status.js'), 'utf8'), status);

function input() {
    return {
        interfaces: [
            { ifname: 'wlan0', operstate: 'UP', flags: ['UP'], addr_info: [{ family: 'inet', scope: 'global', local: '192.0.2.10' }] },
            { ifname: 'enp1s0', operstate: 'DOWN', flags: ['NO-CARRIER'], addr_info: [] },
            { ifname: 'Mihomo', operstate: 'UNKNOWN', flags: [], addr_info: [{ family: 'inet', scope: 'global', local: '198.18.0.1' }] }
        ],
        wifiInterface: 'wlan0', lanInterface: 'enp1s0', networkError: null, speedError: null, statsError: null,
        stats: { cpu: 0, cpuSamples: 2, cpuCores: 8, memoryUsed: 1048576, memoryTotal: 2097152, swapUsed: 0, swapTotal: 0, load: '0.00 1.00 2.00', mounts: [{ mount: '/', avail: '512.0G', size: '1.0T', percent: '50%' }] },
        speed: { rxRate: 1048576, txRate: 524288, interfaceName: 'wlan0', sampledAt: 100000 }
    };
}

test('zero CPU and zero Swap are facts, not missing samples', () => {
    const result = status.readings(input(), {});
    assert.equal(result.cpu.value, '0.0%');
    assert.equal(result.swap.value, '0.0 GiB');
    assert.equal(result.swap.detail, '未配置 Swap');
    assert.equal(result.ram.percent, 50);
    assert.equal(result.disk.value, '512.0 GiB');
    assert.equal(result.load.value, '0.00');
});

test('first CPU reading waits for a delta; partial memory is reported', () => {
    const data = input();
    data.stats.cpuSamples = 1;
    data.stats.memoryTotal = 0;
    data.stats.load = '';
    const result = status.readings(data, {});
    assert.equal(result.cpu.reason, 'waiting_for_cpu_delta');
    assert.equal(result.ram.reason, 'memory_missing');
    assert.equal(result.load.reason, 'load_missing');
    assert.equal(result.disk.state, 'healthy');
});

test('freshness handles clock tick precision and clock rollback', () => {
    assert.equal(status.freshness(true, 100700, 100000, 15000), null);
    assert.equal(status.freshness(true, 100000, 100001, 15000), null);
    assert.equal(status.freshness(true, 100000, 120000, 15000).reason, 'sample_stale');
    assert.equal(status.freshness(true, 100000, 90000, 15000).reason, 'sample_stale');
    assert.equal(status.freshness(true, 0, 100000, 15000).reason, 'waiting_for_sample');
    assert.equal(status.freshness(false, 100000, 100001, 15000).reason, 'dgop_unavailable');
});

test('stale resources are hidden while independent network and speed stay readable', () => {
    const data = input();
    data.statsError = status.freshness(true, 100000, 120000, 15000);
    const result = status.readings(data, {});
    for (const id of ['cpu', 'ram', 'swap', 'load', 'disk']) {
        assert.equal(result[id].value, '--');
        assert.equal(result[id].reason, 'sample_stale');
    }
    assert.equal(result.ip.value, '192.0.2.10');
    assert.equal(result.netspeed.value, '↓ 1.0 MB/s');
    assert.match(result.netspeed.detail, /wlan0 · ↓ 1\.0 MB\/s · ↑ 512\.0 KB\/s/);
});

test('network failures hide cached addresses and link states', () => {
    const data = input();
    data.networkError = status.missing('unreachable', 'network_command_failed', '网卡采样失败');
    const result = status.readings(data, {});
    for (const id of ['ip', 'lan', 'wifi']) {
        assert.equal(result[id].value, '--');
        assert.equal(result[id].state, 'unreachable');
    }
    assert.equal(result.cpu.value, '0.0%');
});

test('physical IP selection ignores tunnels and honors explicit disconnected or missing devices', () => {
    const data = input();
    assert.equal(status.readings(data, {}).ip.value, '192.0.2.10');
    assert.equal(status.readings(data, {}).lan.reason, 'no_carrier');
    assert.equal(status.readings(data, { ipSource: 'lan' }).ip.reason, 'ipv4_unavailable');
    assert.equal(status.readings(data, { wifiInterface: 'missing' }).wifi.reason, 'device_not_found');
    data.interfaces[0].operstate = 'UNKNOWN';
    assert.equal(status.readings(data, {}).wifi.reason, 'link_state_unknown');
    assert.equal(status.readings(data, {}).ip.value, '--');
});

test('binary disk units and missing mounts do not turn into invented zero usage', () => {
    assert.equal(status.capacity('1.0T'), 1099511627776);
    assert.equal(status.capacity('512M'), 536870912);
    assert.equal(status.capacity('0'), 0);
    assert.equal(status.capacity('not available'), null);
    assert.equal(status.readings(input(), { mount: '/not-mounted' }).disk.reason, 'mount_not_found');
    const data = input();
    data.stats.mounts[0].avail = '?';
    assert.equal(status.readings(data, {}).disk.reason, 'disk_missing');
});

test('network counters parse the selected interface and format real rates', () => {
    const text = [
        'Inter-|   Receive                                                |  Transmit',
        ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed',
        '    lo: 100 1 0 0 0 0 0 0 200 2 0 0 0 0 0 0',
        ' wlan0: 4096 10 0 0 0 0 0 0 8192 20 0 0 0 0 0 0'
    ].join('\n');
    const counters = status.parseNetDev(text, 'wlan0');
    assert.equal(counters.rxBytes, 4096);
    assert.equal(counters.txBytes, 8192);
    assert.equal(status.parseNetDev(text, 'missing'), null);
    assert.equal(status.parseNetDev('bad data', 'wlan0'), null);
    assert.equal(status.speedText(0), '0 B/s');
    assert.equal(status.speedText(1536), '1.5 KB/s');
    assert.equal(status.speedText(1048576), '1.0 MB/s');
    assert.equal(status.fields.some(field => field.id === 'time'), false);
    assert.equal(status.fields.find(field => field.id === 'netspeed').defaultEnabled, false);
});

test('详情字段使用原始采样，磁盘可用与已用比例保持独立', () => {
    const data = input();
    data.stats.cpuModel = 'Test CPU';
    const values = status.readings(data, {});
    assert.equal(values.cpu.details[0].value, 'Test CPU');
    assert.equal(values.cpu.details[1].value, '8');
    assert.equal(values.ram.details[0].value, '2.0 GiB');
    assert.equal(values.ram.details[1].value, '1.0 GiB');
    assert.equal(values.disk.details[0].value, '/');
    assert.equal(values.disk.details[2].value, '512.0 GiB');
    assert.equal(values.disk.percent, 50);
    assert.equal(values.netspeed.summary, '↓ 1.0 MB/s  ↑ 512.0 KB/s');
    assert.equal(values.netspeed.value, '↓ 1.0 MB/s', '状态栏原有摘要保持不变');
    assert.equal(values.load.details[2].value, '2.00');
    assert.equal(values.lan.details[0].value, 'enp1s0');
    assert.equal(values.lan.reason, 'no_carrier');
});

test('过期和失败时不泄漏缓存明细，也不改写共享错误对象', () => {
    const data = input();
    const stale = status.missing('unreachable', 'sample_stale', '采样已过期');
    data.statsError = stale;
    data.networkError = status.missing('unreachable', 'network_command_failed', '网卡采样失败');
    const values = status.readings(data, {});
    assert.equal(stale.details, undefined);
    for (const id of Object.keys(values)) {
        assert.equal(values[id].details.length, 0, id);
        assert.equal(values[id].value, '--', id);
    }
    assert.notEqual(values.cpu, values.ram);
    assert.equal(values.netspeed.summary, undefined);
});

test('真实 DMS 控件：摘要展开、键盘、刷新、错误与窄宽度', { timeout: 25000 }, t => {
    const runtimeDir = `/run/user/${process.getuid()}/danklinux-shell`;
    const roots = existsSync(runtimeDir) ? readdirSync(runtimeDir).map(name => path.join(runtimeDir, name)) : [];
    const dmsRoot = roots.find(root => existsSync(path.join(root, 'DankCommon')));
    if (!dmsRoot || spawnSync('qs', ['--version']).status !== 0) {
        t.skip('需要本机 DMS 和 Quickshell 运行时');
        return;
    }
    const work = mkdtempSync(path.join(tmpdir(), 'local-status-qml-'));
    try {
        for (const name of ['Common', 'Widgets', 'Services', 'Modules', 'DankCommon', 'Modals', 'Assets']) {
            if (existsSync(path.join(dmsRoot, name))) symlinkSync(path.join(dmsRoot, name), path.join(work, name));
        }
        symlinkSync(path.resolve(__dirname, '..'), path.join(work, 'Plugin'));
        for (const name of ['home', 'config', 'cache']) mkdirSync(path.join(work, name));
        const data = input();
        data.stats.cpuModel = 'Test CPU ' + 'long-name-'.repeat(30);
        writeFileSync(path.join(work, 'probe.qml'), `
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import qs.Common
import qs.DankCommon.Common as CommonStyle
import "Plugin" as Plugin
import "Plugin/Status.js" as Status
Window {
    id: win
    width: 560; height: 640; visible: true
    Component.onCompleted: CommonStyle.Style.theme = Theme
    TestEvent { id: input }
    QtObject {
        id: source
        property var data: ${JSON.stringify(data)}
        property var values: Status.readings(data, {})
        property int refreshCount: 0
        function refresh() { refreshCount++; }
    }
    Plugin.StatusDetails { id: details; width: win.width; maximumHeight: win.height; source: source }
    property int stripActivations: 0
    property real stripWidthBefore: 0
    property real stripCellWidthBefore: 0
    QtObject {
        id: settingsService
        property var saved: ({ maxWidth: 354 })
        signal pluginDataChanged(string pluginId)
        function getPluginVariants(pluginId) { return []; }
        function loadPluginData(pluginId, key, fallback) { return saved[key] ?? fallback; }
        function savePluginData(pluginId, key, value) {
            const next = Object.assign({}, saved);
            next[key] = value;
            saved = next;
            pluginDataChanged(pluginId);
        }
    }
    Plugin.LocalStatusSettings {
        id: settings
        width: 500
        visible: false
        pluginService: settingsService
    }
    Plugin.StatusStrip {
        id: strip
        visible: false
        width: implicitWidth; height: 30
        barWidth: settingsService.saved.maxWidth; textSize: 13; moduleSpacing: 0
        doubleRow: true
        fields: Status.fields.filter(function (field) { return ["ip", "cpu", "load", "ram", "swap", "disk"].indexOf(field.id) >= 0; })
        values: source.values
        onActivated: win.stripActivations++
    }
    function find(item, name) {
        if (item.objectName === name) return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = find(item.children[i], name);
            if (found) return found;
        }
        return null;
    }
    function check(condition, label) {
        if (!condition) { console.error("STATUS_FAIL " + label); Qt.exit(1); throw new Error(label); }
        console.log("STATUS_PASS " + label);
    }
    function row(id) { return find(details, "status-row-" + id); }
    function loader(id) { return find(details, "status-detail-" + id); }
    function inBounds(item) {
        for (let i = 0; i < item.children.length; i++) {
            const child = item.children[i];
            if (!child.visible || child.width <= 0 || child.height <= 0) continue;
            if (child.x < -1 || child.x + child.width > item.width + 1)
                check(false, "horizontal bounds " + child.toString());
            inBounds(child);
        }
    }
    Timer {
        interval: 400; running: true
        onTriggered: {
            win.requestActivate();
            Status.fields.forEach(function (field) {
                win.check(win.row(field.id) && !win.loader(field.id).active && !win.loader(field.id).item, "initially collapsed " + field.id);
            });
            win.check(details.height <= 520, "compact summary height");
            win.check(!win.find(details, "status-meter-load").visible && !win.find(details, "status-meter-netspeed").visible, "no meaningless progress bars");
            win.check(win.find(details, "status-value-lan").text === "无载波", "network warning visible without expansion");
            win.row("lan").clicked(); win.row("ram").clicked();
            win.check(win.loader("lan").item && win.loader("ram").item && !win.loader("cpu").active, "independent expansion");
            win.check(win.row("ram").Accessible.expanded, "accessible expansion state");
            win.row("ram").forceActiveFocus();
            input.keyClick(Qt.Key_Space, Qt.NoModifier, 0);
            win.check(!win.loader("ram").active, "Space collapses");
            input.keyClick(Qt.Key_Return, Qt.NoModifier, 0);
            win.check(win.loader("ram").active, "Enter expands");
            input.keyClick(Qt.Key_Left, Qt.NoModifier, 0);
            win.check(!win.loader("ram").active, "Left collapses");
            input.keyClick(Qt.Key_Right, Qt.NoModifier, 0);
            win.check(win.loader("ram").active, "Right expands");
            input.keyClick(Qt.Key_Tab, Qt.NoModifier, 0);
            win.check(!win.row("ram").activeFocus, "Tab leaves the summary");
            source.data = JSON.parse(JSON.stringify(source.data));
            win.check(win.loader("lan").active && win.loader("ram").active, "refresh keeps expansion");
            const row = win.row("ram");
            input.mouseClick(row, row.width / 2, row.height / 2, Qt.LeftButton, Qt.NoModifier, 0);
            win.check(!win.loader("ram").active && !win.loader("ram").item, "mouse collapse unloads details");
            Status.fields.forEach(function (field) { if (!details.expandedRows[field.id]) details.toggleRow(field.id); });
            win.width = 360;
            narrowCheck.start();
        }
    }
    Timer {
        id: narrowCheck; interval: 100
        onTriggered: {
            const scroller = win.find(details, "status-scroller");
            win.check(details.height <= 640 && scroller.contentWidth <= scroller.width, "bounded narrow window");
            win.inBounds(details);
            win.check(true, "all narrow layout children stay in horizontal bounds");
            const changed = JSON.parse(JSON.stringify(source.data));
            changed.statsError = Status.missing("unreachable", "sample_stale", "采样已过期");
            changed.networkError = Status.missing("unreachable", "network_command_failed", "网卡采样失败");
            source.data = changed;
            errorCheck.start();
        }
    }
    Timer {
        id: errorCheck; interval: 100
        onTriggered: {
            win.check(win.find(details, "status-value-ram").text === "采样已过期", "stale reason replaces cached value");
            win.check(win.find(details, "status-value-ip").text === "网卡采样失败", "network error replaces cached address");
            Status.fields.forEach(function (field) {
                win.check(!win.find(details, "status-meter-" + field.id).visible, "no percent for error " + field.id);
            });
            win.inBounds(details);
            win.check(true, "error layout children stay in horizontal bounds");
            details.visible = false;
            source.data = ${JSON.stringify(input())};
            strip.visible = true;
            stripCheck.start();
        }
    }
    Timer {
        id: stripCheck; interval: 100
        onTriggered: {
            win.check(strip.width === 354 && strip.height === 30, "summary uses configured width even when content is shorter");
            const top = win.find(strip, "status-strip-field-ip");
            const bottom = win.find(strip, "status-strip-field-ram");
            win.check(top.x === bottom.x && top.width === bottom.width && top.y < bottom.y, "summary columns align across both rows");
            const cpu = win.find(strip, "status-strip-value-cpu");
            win.check(cpu.text === "0.0%" && cpu.horizontalAlignment === Text.AlignLeft, "summary preserves zero and left aligns values");
            win.check(win.find(strip, "status-strip-label-ip").visible && win.find(strip, "status-strip-label-ip").width > 0, "summary keeps IP label at configured width");
            const ipValue = win.find(strip, "status-strip-value-ip");
            const ramValue = win.find(strip, "status-strip-value-ram");
            win.check(ipValue.x === ramValue.x, "summary values share a left edge within each column");
            win.check(!win.find(strip, "status-strip-divider-ip").visible
                && win.find(strip, "status-strip-divider-cpu").visible
                && !win.find(strip, "status-strip-divider-swap").visible, "summary dividers only appear between columns");
            win.check(cpu.font.features.tnum === 1, "summary uses tabular digits");
            win.check(cpu.color.toString() === Theme.surfaceText.toString(), "healthy summary uses neutral text");
            win.check(win.find(strip, "status-strip-icon-cpu").color.toString() === Theme.surfaceVariantText.toString(), "summary icons remain secondary");
            win.check(strip.Accessible.name.indexOf("内存（已用）") >= 0 && strip.Accessible.name.indexOf("磁盘（可用）") >= 0, "summary explains capacity semantics accessibly");
            win.inBounds(strip);
            strip.forceActiveFocus();
            input.keyClick(Qt.Key_Return, Qt.NoModifier, 0);
            input.keyClick(Qt.Key_Space, Qt.NoModifier, 0);
            win.check(win.stripActivations === 2, "summary Enter and Space open details once each");
            win.stripWidthBefore = strip.width;
            win.stripCellWidthBefore = win.find(strip, "status-strip-field-cpu").width;
            const changed = JSON.parse(JSON.stringify(source.data));
            changed.stats.cpu = 100;
            changed.stats.memoryUsed = 0;
            source.data = changed;
            stripStable.start();
        }
    }
    Timer {
        id: stripStable; interval: 100
        onTriggered: {
            win.check(strip.width === win.stripWidthBefore, "changing number length does not resize summary");
            win.check(win.find(strip, "status-strip-value-cpu").text === "100.0%", "summary updates real reading");
            win.check(win.find(strip, "status-strip-value-cpu").color.toString() === Theme.error.toString(), "high usage remains distinct");
            settings.content.find(function (item) { return item.settingKey === "maxWidth"; }).value = 512;
            stripGrow.start();
        }
    }
    Timer {
        id: stripGrow; interval: 100
        onTriggered: {
            win.check(settingsService.saved.maxWidth === 512 && strip.width === 512, "width setting grows visible summary without reload");
            win.check(win.find(strip, "status-strip-field-cpu").width > win.stripCellWidthBefore, "growing summary distributes width to columns");
            win.check(win.find(strip, "status-strip-value-cpu").horizontalAlignment === Text.AlignLeft, "growing width keeps values left aligned");
            win.inBounds(strip);
            settings.content.find(function (item) { return item.settingKey === "maxWidth"; }).value = 160;
            stripNarrow.start();
        }
    }
    Timer {
        id: stripNarrow; interval: 100
        onTriggered: {
            win.check(settingsService.saved.maxWidth === 160 && strip.width === 160, "width setting shrinks visible summary without reload");
            win.inBounds(strip);
            win.check(win.find(strip, "status-strip-label-cpu").visible, "narrow summary does not hide labels");
            const changed = JSON.parse(JSON.stringify(source.data));
            changed.statsError = Status.missing("unreachable", "sample_stale", "采样已过期");
            source.data = changed;
            stripError.start();
        }
    }
    Timer {
        id: stripError; interval: 100
        onTriggered: {
            win.check(win.find(strip, "status-strip-value-cpu").text === "已过期", "summary states stale data in words");
            win.check(strip.Accessible.name.indexOf("sample_stale") >= 0 && strip.description.indexOf("采样已过期") >= 0, "summary keeps readable reason and capability code");
            win.inBounds(strip);
            strip.fields = strip.fields.slice(0, 5);
            settings.content.find(function (item) { return item.settingKey === "maxWidth"; }).value = 354;
            stripOdd.start();
        }
    }
    Timer {
        id: stripOdd; interval: 100
        onTriggered: {
            win.check(!win.find(strip, "status-strip-field-disk"), "summary accepts an odd number of enabled fields");
            win.inBounds(strip);
            strip.doubleRow = false;
            stripSingle.start();
        }
    }
    Timer {
        id: stripSingle; interval: 100
        onTriggered: {
            win.check(win.find(strip, "status-strip-field-ip").y === win.find(strip, "status-strip-field-ram").y, "single row mode remains usable");
            win.inBounds(strip);
            strip.fields = Status.fields;
            settings.content.find(function (item) { return item.settingKey === "maxWidth"; }).value = 160;
            stripAll.start();
        }
    }
    Timer {
        id: stripAll; interval: 100
        onTriggered: {
            win.check(strip.width <= 160, "all summary fields respect minimum configured width");
            win.inBounds(strip);
            strip.fields = [];
            stripEmpty.start();
        }
    }
    Timer {
        id: stripEmpty; interval: 100
        onTriggered: {
            win.check(strip.width === 28 && strip.Accessible.name.indexOf("未选择显示项目") >= 0, "empty summary retains accessible details entry");
            console.log("STATUS_COMPLETE"); Qt.quit();
        }
    }
}
`);
        const result = spawnSync('qs', ['-p', path.join(work, 'probe.qml')], {
            encoding: 'utf8', timeout: 20000,
            env: { ...process.env, HOME: path.join(work, 'home'), XDG_CONFIG_HOME: path.join(work, 'config'), XDG_CACHE_HOME: path.join(work, 'cache'),
                WAYLAND_DISPLAY: '', NIRI_SOCKET: '', DMS_SOCKET: path.join(work, 'no-dms.sock'), DMS_DISABLE_MATUGEN: '1',
                DBUS_SESSION_BUS_ADDRESS: `unix:path=${work}/no-session-bus`, QT_QPA_PLATFORM: 'offscreen',
                QT_QPA_PLATFORMTHEME: 'generic', QT_QPA_PLATFORMTHEME_QT6: 'generic', QT_QUICK_BACKEND: 'software',
                QSG_USE_SIMPLE_ANIMATION_DRIVER: '0', QT_LOGGING_RULES: '*.debug=false;qml.debug=true' }
        });
        const log = result.stdout + result.stderr;
        assert.equal(result.status, 0, log);
        assert.match(log, /STATUS_COMPLETE/, log);
        const issues = log.split('\n').filter(line => /STATUS_FAIL|Binding loop|Unable to assign|ReferenceError|TypeError|is not a type|is unavailable/.test(line));
        assert.deepEqual(issues, []);
        t.diagnostic(`${(log.match(/STATUS_PASS/g) || []).length} 项实际控件与布局检查通过`);
    } finally {
        rmSync(work, { recursive: true, force: true });
    }
});
