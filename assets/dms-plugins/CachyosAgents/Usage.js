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

var MODES = ["today", "week", "total"];

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

function daysOf(record) {
    var days = statsOf(record).recentDays;
    if (!Array.isArray(days))
        return [];
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
                return Object.assign(base, {
                    state: "waiting",
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
            var limits = Array.isArray(record.limits) ? record.limits.filter(function (limit) {
                return limit && typeof limit.label === "string";
            }) : [];
            return Object.assign(base, {
                state: hasLocal || limits.length > 0 ? "ready" : "missing",
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
        rows.forEach(function (row) {
            totalTokens += num(row.totalTokens) || 0;
            totalCost += num(row.totalCost) || 0;
        });
        return { tokens: totalTokens, cost: totalCost, caption: "累计" };
    }

    if (mode === "week") {
        // rows[].days 已经是 daysOf 归一化过的 {date, tokens, cost}，直接累加即可。
        var weekTokens = 0;
        var weekCost = 0;
        rows.forEach(function (row) {
            row.days.forEach(function (day) {
                weekTokens += num(day.tokens) || 0;
                weekCost += num(day.cost) || 0;
            });
        });
        return { tokens: weekTokens, cost: weekCost, caption: "近 7 天" };
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
        return { tokens: tokens, cost: cost, caption: "今天" };
    if (lastDate)
        return { tokens: lastTokens, cost: lastCost, caption: lastDate.slice(5) };
    return { tokens: 0, cost: 0, caption: "" };
}

function barText(records, settings) {
    settings = settings || {};
    var rows = summarise(records, settings);
    var withData = rows.filter(function (row) {
        return row.state !== "waiting";
    });
    if (withData.length === 0)
        return rows.length > 0 ? "—" : "";

    var range = rangeFor(withData, MODES.indexOf(settings.displayMode) >= 0 ? settings.displayMode : "today");
    if (!range.caption)
        return "—";
    if (settings.displayMode === "total")
        return range.caption + " " + formatCost(range.cost);
    return range.caption + " " + formatTokens(range.tokens) + " · " + formatCost(range.cost);
}

// 归一化成 0..1，供面板画迷你柱状图；全为 0 时返回全 0。
function sparkline(days) {
    var values = Array.isArray(days) ? days.map(function (day) {
        return num(day && day.tokens) || 0;
    }) : [];
    var max = values.reduce(function (best, value) {
        return value > best ? value : best;
    }, 0);
    if (max <= 0)
        return values.map(function () {
            return 0;
        });
    return values.map(function (value) {
        return value / max;
    });
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
