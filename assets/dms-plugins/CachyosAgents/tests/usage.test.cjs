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
    // 期望值从 agents 表演绎，而不是写死一份名单：否则每加一个 agent 这条测试就"坏"一次。
    const rows = usage.summarise([record()], { show_claude: false });
    const expected = usage.agents.map(agent => agent.id).filter(id => id !== 'claude');
    assert.deepEqual(arr(rows.map(row => row.id)), arr(expected));
    assert.ok(!rows.some(row => row.id === 'claude'), '被隐藏的 agent 不应出现');
});

test('状态栏默认只显示数字：不带日期、不带价格', () => {
    const text = usage.barText([record()], {});
    assert.equal(text, '500');
    assert.ok(!text.includes('$'), '状态栏文字里不应出现金额');
});

test('今天为 0 时回落到最近有数据的一天（today 模式仍会标日期）', () => {
    const stale = record({
        stats: Object.assign(record().stats, {
            recentDays: days([['2026-09-22', 12_000_000, 73.5], ['2026-09-23', 0, 0]])
        })
    });
    // 默认（bare）：只给数字，但数字必须来自回落后那一天
    assert.equal(usage.barText([stale], {}), '12.0M');
    // 显式选 today：保留日期前缀
    assert.equal(usage.barText([stale], { displayMode: 'today' }), '09-22 12.0M');
});

test('没有数据时状态条是占位符，全部隐藏时才为空', () => {
    assert.equal(usage.barText([record({ hasLocalStats: false, stats: {} })], {}), '—');
    // 采集器从未跑过：显示占位符而不是空，否则控件会隐形、用户根本点不到。
    assert.equal(usage.barText([], {}), '—');
    // 全部隐藏：这时才应该什么都不显示（同样从 agents 表演绎，不写死名单）。
    const noneShown = {};
    usage.agents.forEach(agent => {
        noneShown['show_' + agent.id] = false;
    });
    assert.equal(usage.barText([], noneShown), '');
});


test('状态栏可以只统计某一个 agent', () => {
    // 注意 overrides 只在顶层生效，所以要改 stats 里的东西必须整块替换（第一次就踩了）。
    function withToday(id, today) {
        const base = record();
        return Object.assign({}, base, {
            id,
            stats: Object.assign({}, base.stats, {
                todayTotalTokens: today,
                recentDays: days([['2026-10-01', today, 0], ['2026-10-02', today, 0]])
            })
        });
    }
    const both = [withToday('claude', 1000), withToday('dsh', 777)];

    // 默认（auto）把有数据的 agent 合计起来
    assert.equal(usage.barText(both, { displayMode: 'bare', barAgent: 'auto' }), '1.8K');
    // 钉在 DSH 上时只算 DSH——合计时单个 agent 的份额是看不出来的
    assert.equal(usage.barText(both, { displayMode: 'bare', barAgent: 'dsh' }), '777');
    assert.equal(usage.barText(both, { displayMode: 'bare', barAgent: 'claude' }), '1.0K');
    // 钉到一个没有数据的 agent：占位符，不能显示 0
    assert.equal(usage.barText(both, { displayMode: 'bare', barAgent: 'opencode' }), '—');
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
    assert.doesNotThrow(() => usage.chartPoints([{ tokens: 'x' }], 10, 10, 0));
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

test('折线图：两种数据形状都接受', () => {
    // 记录原始格式（totalTokens）
    assert.equal(usage.chartMax(days([['a', 100, 0], ['b', 40, 0]])), 100);
    // 归一化格式（tokens）
    assert.equal(usage.chartMax([{ tokens: 100 }, { tokens: 40 }]), 100);
    assert.equal(usage.chartPoints([{ totalTokens: 80 }], 100, 40, 0)[0].ratio, 1);
});

test('折线图坐标：任何现实输入都不产生 NaN 或越界点', () => {
    // 坐标一旦是 NaN/Infinity，Canvas 会静默什么都不画——所以这里逐个输入检查不变量。
    const cases = [
        [],
        days([['2026-10-02', 0, 0]]),
        days([['2026-10-01', 5, 0], ['2026-10-02', 0, 0]]),
        days([['a', 1, 0], ['b', 2, 0], ['c', 3, 0], ['d', 4, 0], ['e', 5, 0], ['f', 6, 0], ['g', 7, 0]]),
        days([['a', 0, 0], ['b', 0, 0], ['c', 0, 0]]),
        days([['a', 1, 0], ['b', 999999999999, 0]]),   // 极端离群值
        [{ tokens: 0 }, { totalTokens: 100 }, {}],      // 混合形状 + 缺字段
        [{ tokens: 'x' }, { tokens: null }, { tokens: -5 }],  // 全是垃圾
        // 正负混合：max 为正时负值会把 ratio 拉成负数，点会被画到画布下方
        days([['a', 100, 0], ['b', -5, 0]])
    ];

    for (const input of cases) {
        const points = usage.chartPoints(input, 300, 60, 6);
        for (const point of points) {
            assert.ok(Number.isFinite(point.x), `x 必须是有限值: ${point.x}`);
            assert.ok(Number.isFinite(point.y), `y 必须是有限值: ${point.y}`);
            assert.ok(point.x >= 0 && point.x <= 300, `x 越界: ${point.x}`);
            assert.ok(point.y >= 0 && point.y <= 60, `y 越界: ${point.y}`);
            assert.ok(point.ratio >= 0 && point.ratio <= 1, `ratio 越界: ${point.ratio}`);
        }
    }
});

test('折线图坐标：负数与垃圾值当 0 处理，不产生负坐标', () => {
    const points = usage.chartPoints([{ tokens: -5 }, { tokens: 'x' }], 100, 40, 0);
    assert.equal(points[0].tokens, 0);
    assert.equal(points[0].y, 40);
});

test('hasRecord 区分"没记录"与"有记录但无数据"', () => {
    const withRecord = usage.summarise([record({ hasLocalStats: false })], {}).find(r => r.id === 'claude');
    assert.equal(withRecord.hasRecord, true, '有记录但无本地统计时仍算有记录');
    assert.equal(withRecord.state, 'missing');

    const withoutRecord = usage.summarise([record()], {}).find(r => r.id === 'opencode');
    assert.equal(withoutRecord.hasRecord, false, '没有记录的 agent 不应被弹窗列出');
    assert.equal(withoutRecord.state, 'waiting');
});

test('已删除的旧 displayMode 值会安全回落到 bare', () => {
    // 升级路径：老版本的设置里可能存着 "icon"（只显示图标）。它已不再是合法模式，
    // 但绝不能因此让状态栏空掉或显示异常内容。
    assert.equal(usage.barText([record()], { displayMode: 'icon' }), '500');
    assert.equal(usage.barText([record()], { displayMode: '' }), '500');
    assert.equal(usage.barText([record()], {}), '500');
});

test('折线图接受 QML 传来的"数组样"对象（V4Sequence）', () => {
    // QML 把 Repeater modelData 里的数组交给 JS 时不是真数组：Array.isArray() 为 false，
    // 但有 length、能下标访问。曾经因为用 Array.isArray 当门禁，折线图一个点都画不出来。
    const sequence = { length: 3, 0: { tokens: 0 }, 1: { tokens: 50 }, 2: { tokens: 100 } };
    assert.equal(Array.isArray(sequence), false, '前提：它确实不是真数组');
    const points = usage.chartPoints(sequence, 100, 40, 0);
    assert.equal(points.length, 3);
    assert.equal(points[2].y, 0);
    assert.equal(usage.chartMax(sequence), 100);
});

test('summarise 也接受数组样的 recentDays / limits', () => {
    const recordWithSequence = {
        id: 'claude',
        hasLocalStats: true,
        limits: { length: 1, 0: { label: '5 小时', percent: 42 } },
        stats: { recentDays: { length: 2, 0: { date: '2026-10-01', totalTokens: 10 }, 1: { date: '2026-10-02', totalTokens: 20 } } }
    };
    const row = usage.summarise([recordWithSequence], {}).find(r => r.id === 'claude');
    assert.equal(row.days.length, 2, '数组样的 recentDays 要被读出来');
    assert.equal(row.limits.length, 1, '数组样的 limits 要被读出来');
    assert.equal(row.days[1].tokens, 20);
});

test('没有真实数据时 week/total/bare 都必须显示占位符，不能是 0', () => {
    // 采集器对从没用过的 agent 也会产出 7 天全 0、hasLocalStats=false 的记录。
    // 那时把 0 显示出来就是伪造数据——这条断言正是针对这个缺陷。
    const useless = [{
        id: 'claude',
        hasLocalStats: false,
        stats: {
            recentDays: days([['2026-09-26', 0, 0], ['2026-09-27', 0, 0]]),
            modelUsage: {}
        }
    }];
    for (const mode of ['today', 'week', 'total', 'bare']) {
        assert.equal(usage.barText(useless, { displayMode: mode }), '—', `${mode} 模式不能显示 0`);
    }
    assert.equal(usage.barText([{ id: 'claude' }], { displayMode: 'total' }), '—');
    assert.equal(usage.barText([{ id: 'claude' }], { displayMode: 'week' }), '—');
    assert.equal(usage.compactLabel(useless, {}), '—');
});

test('真的有记录且用量为零时，显示 0 是对的（不是缺失）', () => {
    const zeroButReal = [{
        id: 'claude',
        hasLocalStats: true,
        stats: { recentDays: days([['2026-10-01', 0, 0], ['2026-10-02', 0, 0]]), modelUsage: {}, totalTokens: 0 }
    }];
    assert.equal(usage.barText(zeroButReal, { displayMode: 'today' }), '今天 0');
    assert.equal(usage.barText(zeroButReal, { displayMode: 'week' }), '近 7 天 0');
    assert.equal(usage.barText(zeroButReal, { displayMode: 'bare' }), '0');
});

test('compactLabel 只给数字，供竖排状态栏使用', () => {
    assert.equal(usage.compactLabel([record()], {}), '500');
    assert.equal(usage.compactLabel([], {}), '');
    assert.equal(usage.compactLabel([{ id: 'claude' }], {}), '—');
});
