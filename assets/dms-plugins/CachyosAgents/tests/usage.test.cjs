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

test('状态栏只显示 token，不显示价格', () => {
    const text = usage.barText([record()], {});
    assert.equal(text, '今天 500');
    assert.ok(!text.includes('$'), '状态栏文字里不应出现金额');
});

test('今天为 0 时回落到最近有数据的一天，并标出日期', () => {
    const stale = record({
        stats: Object.assign(record().stats, {
            recentDays: days([['2026-09-22', 12_000_000, 73.5], ['2026-09-23', 0, 0]])
        })
    });
    const text = usage.barText([stale], {});
    assert.equal(text, '09-22 12.0M');
});

test('没有数据时状态条是占位符，全部隐藏时才为空', () => {
    assert.equal(usage.barText([record({ hasLocalStats: false, stats: {} })], {}), '—');
    // 采集器从未跑过：显示占位符而不是空，否则控件会隐形、用户根本点不到。
    assert.equal(usage.barText([], {}), '—');
    // 三个 agent 全被隐藏：这时才应该什么都不显示。
    assert.equal(usage.barText([], { show_claude: false, show_codex: false, show_opencode: false }), '');
});

test('week / total / bare 三种模式', () => {
    assert.equal(usage.barText([record()], { displayMode: 'week' }), '近 7 天 1.0K');
    // total 取 modelUsage 之和：1000 + 2000 + 500
    assert.equal(usage.barText([record()], { displayMode: 'total' }), '累计 3.5K');
    // bare：只留数字，连"今天/日期"前缀都不要
    assert.equal(usage.barText([record()], { displayMode: 'bare' }), '500');
    assert.equal(usage.barText([], { displayMode: 'bare' }), '—');
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

test('折线图坐标：首尾贴边、峰值到顶、零值到底', () => {
    const points = usage.chartPoints(days([['a', 0, 0], ['b', 50, 0], ['c', 100, 0]]), 100, 40, 0);
    assert.equal(points.length, 3);
    assert.equal(points[0].x, 0);
    assert.equal(points[2].x, 100);
    assert.equal(points[1].x, 50);
    // 峰值 y 最小（贴顶），零值 y 最大（贴底）
    assert.equal(points[2].y, 0);
    assert.equal(points[0].y, 40);
    assert.equal(points[1].ratio, 0.5);
});

test('折线图坐标：留白与单点', () => {
    const padded = usage.chartPoints([{ tokens: 10 }], 100, 40, 5);
    assert.equal(padded.length, 1);
    // 只有一个点就画在中间，否则会贴着左边看起来像 bug
    assert.equal(padded[0].x, 50);
    assert.equal(padded[0].y, 5);

    const empty = usage.chartPoints([], 100, 40, 0);
    assert.deepEqual(arr(empty), []);
});

test('折线图坐标：全零时不除零', () => {
    const points = usage.chartPoints(days([['a', 0, 0], ['b', 0, 0]]), 90, 30, 0);
    assert.equal(points[0].ratio, 0);
    assert.equal(points[1].ratio, 0);
    assert.equal(points[0].y, 30);
});

test('折线图最大值：全零返回 null', () => {
    assert.equal(usage.chartMax(days([['a', 100, 0], ['b', 40, 0]])), 100);
    assert.equal(usage.chartMax(days([['a', 0, 0]])), null);
    assert.equal(usage.chartMax([]), null);
    assert.equal(usage.chartMax(null), null);
});

test('折线图坐标：畸形输入不抛异常', () => {
    assert.doesNotThrow(() => usage.chartPoints(null, 100, 40, 0));
    assert.doesNotThrow(() => usage.chartPoints([{ tokens: 'x' }], 0, 0, undefined));
    assert.doesNotThrow(() => usage.chartPoints([null, 5, 'x'], 100, 40, 2));
});

test('折线图与迷你条：两种数据形状都接受', () => {
    // 记录原始格式（totalTokens）
    assert.equal(usage.chartMax(days([['a', 100, 0], ['b', 40, 0]])), 100);
    // 归一化格式（tokens）
    assert.equal(usage.chartMax([{ tokens: 100 }, { tokens: 40 }]), 100);
    assert.equal(usage.chartPoints([{ totalTokens: 80 }], 100, 40, 0)[0].ratio, 1);
    assert.deepEqual(arr(usage.sparkline([{ totalTokens: 0 }, { totalTokens: 50 }])), [0, 1]);
});
