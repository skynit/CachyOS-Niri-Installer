const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
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
        wifiInterface: 'wlan0', lanInterface: 'enp1s0', networkError: null, statsError: null,
        stats: { cpu: 0, cpuSamples: 2, cpuCores: 8, memoryUsed: 1048576, memoryTotal: 2097152, swapUsed: 0, swapTotal: 0, load: '0.00 1.00 2.00', mounts: [{ mount: '/', avail: '512.0G', size: '1.0T', percent: '50%' }] },
        time: '12:00:00', date: '2026-09-08'
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

test('stale resources are hidden while independent network and time stay readable', () => {
    const data = input();
    data.statsError = status.freshness(true, 100000, 120000, 15000);
    const result = status.readings(data, {});
    for (const id of ['cpu', 'ram', 'swap', 'load', 'disk']) {
        assert.equal(result[id].value, '--');
        assert.equal(result[id].reason, 'sample_stale');
    }
    assert.equal(result.ip.value, '192.0.2.10');
    assert.equal(result.time.value, '12:00:00');
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
