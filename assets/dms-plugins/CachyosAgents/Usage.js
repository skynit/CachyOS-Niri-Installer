// 用量摘要的纯逻辑：格式化、取值、汇总。
//
// 这里不引用任何 QML API，因此可以直接用 `node --test` 覆盖（见 tests/usage.test.cjs）。
// 数据来自 cachyos-agent-usage-update 写出的记录：
//   ~/.local/state/cachyos-desktop/agents/usage/<agent>.json
//
// 一条原则：**数据缺失就显示缺失**，绝不把"没采到"渲染成 0。

var agents = [
    { id: "claude", label: "Claude Code", short: "Claude", icon: "smart_toy" },
    { id: "codex", label: "Codex", short: "Codex", icon: "terminal" },
    { id: "opencode", label: "OpenCode", short: "OpenCode", icon: "code" }
];

var MODES = ["today", "week", "total", "bare"];

function isNumber(value) {
    return typeof value === "number" && isFinite(value);
}

// 把任意输入收敛成"数字或 null"，避免上游字段缺失时把 NaN 漏到界面上。
function num(value) {
    if (isNumber(value))
        return value;
    if (typeof value === "string" && value.trim() !== "" && isFinite(Number(value)))
        return Number(value);
    return null;
}

function formatTokens(value) {
    var n = num(value);
    if (n === null || n < 0)
        return "—";
    if (n >= 1e9)
        return (n / 1e9).toFixed(1) + "B";
    if (n >= 1e6)
        return (n / 1e6).toFixed(1) + "M";
    if (n >= 1e3)
        return (n / 1e3).toFixed(1) + "K";
    return String(Math.round(n));
}

function formatCost(value) {
    var n = num(value);
    if (n === null || n < 0)
        return "—";
    if (n === 0)
        return "$0";
    if (n < 1)
        return "$" + n.toFixed(3);
    if (n < 1000)
        return "$" + n.toFixed(2);
    return "$" + Math.round(n).toLocaleString("en-US");
}

// 两家对 input_tokens 是否含缓存的语义不同，必须显式展示，否则用户会以为统计有错。
function semanticsLabel(value) {
    if (value === "inclusive")
        return "输入含缓存";
    if (value === "exclusive")
        return "输入不含缓存";
    return "";
}

function recordFor(records, id) {
    if (!Array.isArray(records))
        return null;
    for (var i = 0; i < records.length; i++) {
        var record = records[i];
        if (record && record.id === id)
            return record;
    }
    return null;
}

function statsOf(record) {
    var stats = record && record.stats;
    return stats && typeof stats === "object" ? stats : {};
}

// 同时接受归一化后的 {tokens} 与记录原始格式的 {totalTokens}。
// 这两种形状在本文件里混用过，并且已经因此出过 bug（把"没读到"当成 0、或整段算成 0），
// 所以在入口处统一收敛，而不是要求每个调用方都记住该传哪种。
function dayTokens(day) {
    if (!day || typeof day !== "object")
        return 0;
    var value = num(day.tokens);
    if (value === null)
        value = num(day.totalTokens);
    if (value === null)
        return 0;
    // 负数在真实数据里不可能出现；但它会让 ratio 变负，把点画到画布外（Canvas 不报错，
    // 只是视觉上"线掉出去了"）。这里一律当 0，边界处的防御成本最低。
    return value < 0 ? 0 : value;
}

// QML 把 Repeater modelData 里的数组当作 V4Sequence 传进 JS：它有 length、能下标访问，
// 但 **Array.isArray() 返回 false**。拿 Array.isArray 当门禁会让折线图一个点都画不出来，
// 而且 Canvas 不报错、只是空白——极难发现。所有"来自记录/来自 QML"的数组都走这里。
function asArray(value) {
    if (Array.isArray(value))
        return value;
    // 字符串也有 length，但它不是"数组样"：把它当数组会得到 ['b','a','d'] 这种垃圾，
    // 让"字段畸形"悄悄变成"有 3 天数据"。函数同理。
    if (typeof value === "string" || typeof value === "function")
        return [];
    if (value && typeof value.length === "number")
        return Array.prototype.slice.call(value);
    return [];
}

function daysOf(record) {
    var days = asArray(statsOf(record).recentDays);
    return days.map(function (day) {
        return {
            date: day && typeof day.date === "string" ? day.date : "",
            tokens: num(day && day.totalTokens) || 0,
            cost: num(day && day.costUsd) || 0
        };
    });
}

// recentDays 的最后一项是今天；没有数据时返回 null，调用方据此显示"缺失"。
function todayOf(record) {
    var days = daysOf(record);
    if (days.length === 0)
        return null;
    var last = days[days.length - 1];
    return { date: last.date, tokens: last.tokens, cost: last.cost };
}

function modelsOf(record, settings) {
    var usage = statsOf(record).modelUsage;
    var list = [];
    if (usage && typeof usage === "object") {
        Object.keys(usage).forEach(function (model) {
            var entry = usage[model] || {};
            list.push({
                model: model,
                tokens: num(entry.totalTokens) || 0,
                cost: num(entry.costUsd) || 0,
                priced: entry.priced === true
            });
        });
    }
    list.sort(function (a, b) {
        return b.cost - a.cost || b.tokens - a.tokens || a.model.localeCompare(b.model);
    });
    var limit = num(settings && settings.maxModels);
    if (limit !== null && limit >= 0)
        list = list.slice(0, Math.round(limit));
    return list;
}

function summarise(records, settings) {
    settings = settings || {};
    return agents
        .filter(function (agent) {
            return settings["show_" + agent.id] !== false;
        })
        .map(function (agent) {
            var record = recordFor(records, agent.id);
            var base = {
                id: agent.id,
                label: agent.label,
                short: agent.short,
                icon: agent.icon
            };
            if (!record) {
                // hasRecord 区分"还没有记录"与"有记录但没数据"：前者是根本没装对应采集器，
                // 弹窗据此不显示空卡片（否则 opencode 这类没有采集器的 agent 会永远挂着）。
                return Object.assign(base, {
                    state: "waiting",
                    hasRecord: false,
                    detail: "还没有采集过",
                    todayTokens: null,
                    todayCost: null,
                    totalTokens: null,
                    totalCost: null,
                    sessions: null,
                    prompts: null,
                    limits: [],
                    models: [],
                    days: [],
                    semantics: ""
                });
            }

            var stats = statsOf(record);
            var today = todayOf(record);
            var hasLocal = record.hasLocalStats === true;
            var limits = asArray(record.limits).filter(function (limit) {
                return limit && typeof limit.label === "string";
            });
            return Object.assign(base, {
                state: hasLocal || limits.length > 0 ? "ready" : "missing",
                hasRecord: true,
                detail: typeof record.usageStatusText === "string" ? record.usageStatusText : "",
                todayTokens: today ? today.tokens : null,
                todayCost: today ? today.cost : null,
                totalTokens: num(stats.totalTokens) !== null ? num(stats.totalTokens) : sumModelTokens(record),
                totalCost: num(stats.costUsd),
                sessions: num(stats.totalSessions),
                prompts: num(stats.totalPrompts),
                tierLabel: typeof record.tierLabel === "string" ? record.tierLabel : "",
                limits: limits,
                models: modelsOf(record, settings),
                days: daysOf(record),
                semantics: semanticsLabel(record.inputTokenSemantics)
            });
        });
}

function sumModelTokens(record) {
    var total = 0;
    var usage = statsOf(record).modelUsage;
    if (!usage || typeof usage !== "object")
        return null;
    Object.keys(usage).forEach(function (model) {
        total += num((usage[model] || {}).totalTokens) || 0;
    });
    return total;
}

// 把某段时间的用量聚成 {tokens, cost, caption}；today 无数据时回落到最近有数据的一天。
function rangeFor(rows, mode) {
    if (mode === "total") {
        var totalTokens = 0;
        var totalCost = 0;
        var totalHasData = false;
        rows.forEach(function (row) {
            // hasData 看"这条记录到底有没有统计数据"，而不是"数字是不是 0"：采集器对从没
            // 用过的 agent 也会产出 7 天全 0 的记录，那种 0 是伪造的，必须显示为缺失。
            if (row.state === "ready")
                totalHasData = true;
            totalTokens += num(row.totalTokens) || 0;
            totalCost += num(row.totalCost) || 0;
        });
        return { tokens: totalTokens, cost: totalCost, caption: "累计", hasData: totalHasData };
    }

    if (mode === "week") {
        // rows[].days 已经是 daysOf 归一化过的 {date, tokens, cost}，直接累加即可。
        var weekTokens = 0;
        var weekCost = 0;
        var weekHasData = false;
        rows.forEach(function (row) {
            if (row.state === "ready")
                weekHasData = true;
            row.days.forEach(function (day) {
                weekTokens += num(day.tokens) || 0;
                weekCost += num(day.cost) || 0;
            });
        });
        return { tokens: weekTokens, cost: weekCost, caption: "近 7 天", hasData: weekHasData };
    }

    var tokens = 0;
    var cost = 0;
    var anyToday = false;
    var lastDate = "";
    var lastTokens = 0;
    var lastCost = 0;
    rows.forEach(function (row) {
        if (row.todayTokens !== null) {
            if (row.todayTokens > 0) {
                anyToday = true;
                tokens += row.todayTokens;
                cost += num(row.todayCost) || 0;
            }
        }
        var days = row.days;
        for (var i = days.length - 1; i >= 0; i--) {
            if (days[i].tokens > 0 && days[i].date > lastDate) {
                lastDate = days[i].date;
                lastTokens = days[i].tokens;
                lastCost = days[i].cost;
                break;
            }
        }
    });

    if (anyToday)
        return { tokens: tokens, cost: cost, caption: "今天", hasData: true };
    if (lastDate)
        return { tokens: lastTokens, cost: lastCost, caption: lastDate.slice(5), hasData: true };

    // 到这里今天与最近 7 天都没有非零值，还要再分两种：
    //   - 记录是真的（agent 用过，只是这几天确实是 0）→ 显示 0，这是事实；
    //   - 记录是采集器给从没用过的 agent 产出的空壳（hasLocalStats=false）→ 显示缺失。
    var anyReady = rows.some(function (row) {
        return row.state === "ready";
    });
    if (anyReady)
        return { tokens: 0, cost: 0, caption: "今天", hasData: true };
    return { tokens: 0, cost: 0, caption: "", hasData: false };
}

// 状态栏只显示 token 用量：不带图标、不带价格（金额在弹窗里看）。
function barText(records, settings) {
    settings = settings || {};
    var rows = summarise(records, settings);
    var withData = rows.filter(function (row) {
        return row.state !== "waiting";
    });
    if (withData.length === 0)
        return rows.length > 0 ? "—" : "";

    var mode = MODES.indexOf(settings.displayMode) >= 0 ? settings.displayMode : "today";
    var range = rangeFor(withData, mode === "bare" ? "today" : mode);

    // 没有任何真实数据就显示占位符：绝不出现"累计 0"这种伪造出来的数字。
    if (!range.hasData)
        return "—";
    if (mode === "bare")
        return formatTokens(range.tokens);
    return range.caption + " " + formatTokens(range.tokens);
}

// 把最近几天的用量算成折线图坐标。放在这里而不是 QML 里，是为了能直接跑 node 测试。
// width/height 是画布尺寸，inset 是四周留白；返回 [] 表示没有数据可画。
function chartPoints(days, width, height, inset) {
    var values = asArray(days).map(dayTokens);
    if (values.length === 0)
        return [];

    var pad = num(inset);
    pad = pad === null ? 0 : pad;
    var canvasWidth = num(width) || 0;
    var canvasHeight = num(height) || 0;
    var usableWidth = Math.max(1, canvasWidth - pad * 2);
    var usableHeight = Math.max(1, canvasHeight - pad * 2);
    var max = values.reduce(function (best, value) {
        return value > best ? value : best;
    }, 0);
    var step = values.length > 1 ? usableWidth / (values.length - 1) : 0;

    return values.map(function (value, index) {
        var ratio = max > 0 ? value / max : 0;
        return {
            index: index,
            x: pad + (values.length > 1 ? step * index : usableWidth / 2),
            y: pad + usableHeight * (1 - ratio),
            ratio: ratio,
            tokens: value,
            date: days[index] && typeof days[index].date === "string" ? days[index].date : ""
        };
    });
}

// 竖排状态栏（左/右栏）用：只给数字，不带"今天/日期"前缀，窄条里才放得下。
function compactLabel(records, settings) {
    var rows = summarise(records, settings);
    var withData = rows.filter(function (row) {
        return row.state !== "waiting";
    });
    if (withData.length === 0)
        return "";
    var range = rangeFor(withData, "today");
    return range.hasData ? formatTokens(range.tokens) : "—";
}

// 折线图上要标注的最大值（用于纵轴说明）。全为 0 时返回 null。
function chartMax(days) {
    var list = asArray(days);
    if (list.length === 0)
        return null;
    var max = list.reduce(function (best, day) {
        var value = dayTokens(day);
        return value > best ? value : best;
    }, 0);
    return max > 0 ? max : null;
}

// 数据新鲜度：超过 maxAgeMs 视为过期（面板据此提示"数据可能过期"）。
function freshness(updatedAt, now, maxAgeMs) {
    var at = num(updatedAt);
    var current = num(now);
    if (at === null || current === null || at <= 0)
        return { stale: true, ageMs: null, text: "未知" };
    var age = Math.max(0, current - at);
    var minutes = Math.floor(age / 60000);
    var text = minutes < 1 ? "刚刚" : (minutes < 60 ? minutes + " 分钟前" : Math.floor(minutes / 60) + " 小时前");
    // 用 >= ：刚好达到阈值就算过期，避免"差一毫秒仍然显示新鲜"这种边界抖动。
    return { stale: age >= (num(maxAgeMs) || 0), ageMs: age, text: text };
}
