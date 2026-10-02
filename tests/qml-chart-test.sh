#!/usr/bin/env bash

# 折线图在 QML 里的回归测试。
#
# 为什么必须有这一条：node 测试只能喂真数组，而 QML 把 Repeater delegate 里的数组交给 JS 时
# 用的是 **V4Sequence**（有 length、能下标，但 Array.isArray() 为 false）。这个差异只在 QML
# 里出现，曾导致折线图一个点都画不出来而且**不报错**。所以这里用离屏 QML 真跑一遍绘制。
#
# 没有 qml6（Qt6 的 qml 运行时）时跳过：目标机器不一定装 Qt 开发工具。

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR
readonly USAGE_JS="$PROJECT_DIR/assets/dms-plugins/CachyosAgents/Usage.js"

PASS_COUNT=0
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'ok - %s\n' "$1"; }
fail() {
    printf 'not ok - %s\n' "$1" >&2
    (($# >= 2)) && printf '  %s\n' "$2" >&2
    exit 1
}

if ! command -v qml6 >/dev/null 2>&1; then
    pass '没有 qml6，跳过 QML 渲染回归（需要 Qt6 运行时）'
    printf '\n%s 项检查通过。\n' "$PASS_COUNT"
    exit 0
fi

cp "$USAGE_JS" "$WORK_DIR/Usage.js"
cat > "$WORK_DIR/probe.qml" <<'QML'
import QtQuick
import QtQuick.Window
import "Usage.js" as Usage

Window {
    id: win
    width: 300; height: 120
    visible: true
    property var records: [
        { id: "claude", hasLocalStats: true,
          stats: { recentDays: [
              { date: "2026-09-30", totalTokens: 0, costUsd: 0 },
              { date: "2026-10-01", totalTokens: 12029395, costUsd: 0.37 },
              { date: "2026-10-02", totalTokens: 0, costUsd: 0 }
          ], modelUsage: { m: { totalTokens: 12029395, costUsd: 0.37, priced: true } } } }
    ]
    property int painted: 0

    Repeater {
        model: Usage.summarise(win.records, {})
        delegate: Item {
            required property var modelData
            readonly property var agent: modelData
            // 关键断言：QML 交给 JS 的 days 不是真数组，但仍必须能算出坐标。
            Component.onCompleted: {
                console.log("PROBE daysIsArray=" + Array.isArray(agent.days) +
                            " points=" + Usage.chartPoints(agent.days, 300, 56, 6).length +
                            " max=" + Usage.chartMax(agent.days));
            }
            Canvas {
                width: 300; height: 56
                onPaint: {
                    const points = Usage.chartPoints(agent.days, width, height, 6);
                    win.painted += points.length;
                }
            }
        }
    }

    Timer {
        interval: 500; running: true
        onTriggered: {
            console.log("PROBE_TOTAL painted=" + win.painted);
            Qt.quit();
        }
    }
}
QML

output="$(timeout 60 env QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 \
    qml6 "$WORK_DIR/probe.qml" 2>&1 || true)"

# 断言 1：delegate 里的 days 确实不是真数组（前提成立，否则这条测试就没意义了）
if [[ $output == *"daysIsArray=false"* ]]; then
    pass 'QML 传给 JS 的 days 确实不是真数组（前提成立）'
else
    fail '没有复现出"数组样"形状——这条回归测试的前提变了，需要重新确认' "$output"
fi

# 断言 2：仍然算得出坐标（正是曾经为 0 的地方）
if [[ $output == *"points=3"* && $output == *"max=12029395"* ]]; then
    pass '数组样的 days 仍能算出 3 个坐标点与峰值'
else
    fail '数组样的 days 算不出坐标——折线图会空白' "$output"
fi

# 断言 3：Canvas 真的画到了点
if [[ $output == *"PROBE_TOTAL painted=3"* ]]; then
    pass 'Canvas 实际绘制了 3 个点'
else
    fail 'Canvas 没有绘制任何点' "$output"
fi

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
