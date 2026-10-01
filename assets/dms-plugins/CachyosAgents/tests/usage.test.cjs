const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const usage = vm.createContext({});
vm.runInContext(readFileSync(path.join(__dirname, '..', 'Usage.js'), 'utf8'), usage);

// vm 上下文里创建的数组与测试 realm 的数组原型不同，deepStrictEqual 会判定不等，
// 因此比较前先复制到测试 realm。
function arr(value) {
    return Array.from(value);
}

function days(values) {
    // values: [[date, tokens, cost], ...]
    return values.map(([date, tokens, cost]) => ({ date, totalTokens: tokens, costUsd: cost }));
}

function record(overrides) {
    return Object.assign({
        id: 'claude',
        name: 'Claude Code',
        hasLocalStats: true,
        inputTokenSemantics: 'exclusive',
        usageStatusText: '',
        stats: {
            todayTotalTokens: 500,
            todayTokensByModel: {},
            todayPrompts: 1,
            todaySessions: 1,
            recentDays: days([['2026-09-30', 100, 0.1], ['2026-10-01', 400, 0.4], ['2026-10-02', 500, 0.5]]),
            totalPrompts: 3,
            totalSessions: 2,
            costUsd: 1.0,
            modelUsage: {
                'model-a': { totalTokens: 1000, costUsd: 0.75, priced: true },
                'model-b': { totalTokens: 2000, costUsd: 0.25, priced: true },
                'model-c': { totalTokens: 500, costUsd: 0, priced: false }
            }
        }
    }, overrides || {});
}

test('格式化为缺失，而不是零', () => {
    assert.equal(usage.formatTokens(null), '—');
    assert.equal(usage.formatTokens(undefined), '—');
    assert.equal(usage.formatTokens(-5), '—');
    assert.equal(usage.formatTokens('abc'), '—');
    assert.equal(usage.formatCost(null), '—');
    assert.equal(usage.formatCost(0), '$0');
});

test('token 与费用按数量级缩写', () => {
    assert.equal(usage.formatTokens(999), '999');
    assert.equal(usage.formatTokens(1500), '1.5K');
    assert.equal(usage.formatTokens(2_400_000), '2.4M');
    assert.equal(usage.formatTokens(3_100_000_000), '3.1B');
    // 用二进制可精确表示的值，避免 toFixed 在十进制"中点"上的舍入歧义。
    assert.equal(usage.formatCost(0.125), '$0.125');
    assert.equal(usage.formatCost(7.4), '$7.40');
    assert.equal(usage.formatCost(7402.49), '$7,402');
});

test('没有记录时是 waiting，不当成 0', () => {
    const rows = usage.summarise([], {});
    const claude = rows.find(row => row.id === 'claude');
    assert.equal(claude.state, 'waiting');
    assert.equal(claude.todayTokens, null);
    assert.equal(claude.todayCost, null);
    assert.equal(claude.totalCost, null);
});

test('hasLocalStats 为假且没有限额时标记 missing', () => {
    const rows = usage.summarise([record({ hasLocalStats: false })], {});
    assert.equal(rows.find(row => row.id === 'claude').state, 'missing');
});

test('有限额但没有本地统计时仍算 ready', () => {
    const rows = usage.summarise([record({ hasLocalStats: false, limits: [{ label: '5 小时', percent: 42 }] })], {});
    assert.equal(rows.find(row => row.id === 'claude').state, 'ready');
});

test('按设置隐藏 agent', () => {
    const rows = usage.summarise([record()], { show_claude: false, show_codex: false });
    assert.deepEqual(arr(rows.map(row => row.id)), ['opencode']);
});

test('今天有数据时状态条显示今天', () => {
    const text = usage.barText([record()], {});
    assert.equal(text, '今天 500 · $0.500');
});

test('今天为 0 时回落到最近有数据的一天，并标出日期', () => {
    const stale = record({
        stats: Object.assign(record().stats, {
            recentDays: days([['2026-09-22', 12_000_000, 73.5], ['2026-09-23', 0, 0]])
        })
    });
    const text = usage.barText([stale], {});
    assert.equal(text, '09-22 12.0M · $73.50');
});

test('没有数据时状态条是占位符，全部隐藏时才为空', () => {
    assert.equal(usage.barText([record({ hasLocalStats: false, stats: {} })], {}), '—');
    // 采集器从未跑过：显示占位符而不是空，否则控件会隐形、用户根本点不到。
    assert.equal(usage.barText([], {}), '—');
    // 三个 agent 全被隐藏：这时才应该什么都不显示。
    assert.equal(usage.barText([], { show_claude: false, show_codex: false, show_opencode: false }), '');
});

test('week 与 total 模式分别聚合', () => {
    assert.equal(usage.barText([record()], { displayMode: 'week' }), '近 7 天 1.0K · $1.00');
    assert.equal(usage.barText([record()], { displayMode: 'total' }), '累计 $1.00');
});

test('模型按费用降序、可限量、标出是否计价', () => {
    const all = usage.summarise([record()], {}).find(row => row.id === 'claude').models;
    assert.deepEqual(arr(all.map(item => item.model)), ['model-a', 'model-b', 'model-c']);
    assert.equal(all[2].priced, false);
    const limited = usage.summarise([record()], { maxModels: 1 }).find(row => row.id === 'claude').models;
    assert.equal(limited.length, 1);
});

test('sparkline 归一化，全零时全零', () => {
    // sparkline 消费的是 daysOf 归一化后的 {tokens} 结构，这里两种入口都验证。
    assert.deepEqual(arr(usage.sparkline([{ tokens: 0 }, { tokens: 50 }, { tokens: 100 }])), [0, 0.5, 1]);
    assert.deepEqual(arr(usage.sparkline([{ tokens: 0 }])), [0]);
    assert.deepEqual(arr(usage.sparkline(null)), []);
    const normalized = usage.summarise([record()], {}).find(row => row.id === 'claude').days;
    assert.deepEqual(arr(usage.sparkline(normalized)), [0.2, 0.8, 1]);
});

test('新鲜度按阈值判定过期', () => {
    assert.equal(usage.freshness(0, 1000, 60000).stale, true);
    assert.equal(usage.freshness(1000, 61_000, 60_000).stale, true);
    assert.equal(usage.freshness(1000, 31_000, 60_000).stale, false);
    assert.equal(usage.freshness(1000, 31_000, 60_000).text, '刚刚');
});

test('输入语义有可读说明', () => {
    assert.equal(usage.semanticsLabel('inclusive'), '输入含缓存');
    assert.equal(usage.semanticsLabel('exclusive'), '输入不含缓存');
    assert.equal(usage.semanticsLabel(''), '');
});

test('畸形数据不抛异常', () => {
    assert.doesNotThrow(() => usage.summarise(null, null));
    assert.doesNotThrow(() => usage.summarise([null, 42, 'x'], {}));
    assert.doesNotThrow(() => usage.summarise([{ id: 'claude', stats: 'nope', limits: 'x' }], {}));
    assert.doesNotThrow(() => usage.barText([{ id: 'claude' }], { displayMode: 'nonsense' }));
    assert.doesNotThrow(() => usage.sparkline([{ tokens: 'x' }]));
    const rows = usage.summarise([{ id: 'claude', stats: { recentDays: 'bad', modelUsage: [] } }], {});
    assert.equal(rows[0].days.length, 0);
    assert.equal(rows[0].models.length, 0);
});
