#!/usr/bin/env bash

# DMS 用量面板接线的回归测试。
#
# 这两个 jq 程序是"改用户配置文件"的地方，出错不会报错、只会静默改坏布局或悄悄不生效：
#   1. 加控件必须**幂等**：重装不能在状态栏里堆出第二个同名控件
#   2. 加控件必须**只动 barConfigs**：其他设置一个字节都不能变
#   3. 启用插件必须**尊重用户意愿**：他关掉之后再重装，不能又给打开
#   4. 没有 barConfigs 时要从零建出合法结构，而不是报错

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR
readonly WIDGET_JQ="$PROJECT_DIR/assets/dms/add-agents-bar-widget.jq"
readonly ENABLE_JQ="$PROJECT_DIR/assets/dms/enable-dms-plugin.jq"

PASS_COUNT=0
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'ok - %s\n' "$1"; }
fail() {
    printf 'not ok - %s\n' "$1" >&2
    (($# >= 2)) && printf '  %s\n' "$2" >&2
    exit 1
}
assert_equal() {
    if [[ "$1" == "$2" ]]; then
        pass "$3"
    else
        fail "$3" "expected: [$1] actual: [$2]"
    fi
}

widget_count() {
    jq '[.barConfigs[]? | (.leftWidgets? // [])[], (.centerWidgets? // [])[], (.rightWidgets? // [])[]
         | if type == "object" then .id else . end] | map(select(. == "cachyosAgents")) | length' "$1"
}

add_widget() { jq -f "$WIDGET_JQ" "$1"; }

# ---- 从零开始：没有 barConfigs 时要建出合法结构 --------------------------------
empty="$WORK_DIR/empty.json"
printf '%s\n' '{}' > "$empty"
add_widget "$empty" > "$WORK_DIR/empty-once.json"
assert_equal '1' "$(widget_count "$WORK_DIR/empty-once.json")" '空配置：控件被加了一次'
assert_equal '1' "$(jq '.barConfigs | length' "$WORK_DIR/empty-once.json")" '空配置：建出了一份 barConfigs'
assert_equal 'true' "$(jq -r '.barConfigs[0].rightWidgets[0].enabled' "$WORK_DIR/empty-once.json")" '空配置：控件是启用状态'

# ---- 已有布局：追加而不覆盖，且其他键一个字节都不能变 --------------------------
real="$WORK_DIR/real.json"
jq -n '{currentThemeName: "keep-me", cursorSettings: {size: 42},
        barConfigs: [{leftWidgets: ["localTranslate"], centerWidgets: [{id: "clock"}],
                      rightWidgets: [{id: "localStatus", enabled: true}]}]}' > "$real"
add_widget "$real" > "$WORK_DIR/real-once.json"
assert_equal '1' "$(widget_count "$WORK_DIR/real-once.json")" '已有布局：控件被加了一次'
# 逐项断言而不是总数：总数会把"新加的"和"原有的"混在一起，看不出有没有丢。
assert_equal '["localTranslate"]' "$(jq -c '.barConfigs[0].leftWidgets' "$WORK_DIR/real-once.json")" \
    '已有布局：左侧原有控件完好'
assert_equal '["clock"]' "$(jq -c '[.barConfigs[0].centerWidgets[].id]' "$WORK_DIR/real-once.json")" \
    '已有布局：中间原有控件完好'
assert_equal '["localStatus","cachyosAgents"]' "$(jq -c '[.barConfigs[0].rightWidgets[].id]' "$WORK_DIR/real-once.json")" \
    '已有布局：右侧是"原有控件 + 新控件"，追加而非替换'
assert_equal 'keep-me' "$(jq -r '.currentThemeName' "$WORK_DIR/real-once.json")" '已有布局：无关的顶层键未被动过'
assert_equal '42' "$(jq -r '.cursorSettings.size' "$WORK_DIR/real-once.json")" '已有布局：嵌套对象未被动过'
assert_equal "$(jq -S 'del(.barConfigs)' "$real" | md5sum)" "$(jq -S 'del(.barConfigs)' "$WORK_DIR/real-once.json" | md5sum)" \
    '已有布局：除 barConfigs 外语义完全一致'

# ---- 幂等：跑两次结果必须完全相同 ---------------------------------------------
add_widget "$WORK_DIR/real-once.json" > "$WORK_DIR/real-twice.json"
assert_equal '1' "$(widget_count "$WORK_DIR/real-twice.json")" '幂等：重复执行不会出现第二个控件'
assert_equal "$(md5sum < "$WORK_DIR/real-once.json")" "$(md5sum < "$WORK_DIR/real-twice.json")" \
    '幂等：第二次执行输出与第一次逐字节相同'

# ---- 控件出现在别的区时也要认出来 ---------------------------------------------
elsewhere="$WORK_DIR/elsewhere.json"
jq -n '{barConfigs: [{leftWidgets: [{id: "cachyosAgents"}], rightWidgets: []}]}' > "$elsewhere"
add_widget "$elsewhere" > "$WORK_DIR/elsewhere-out.json"
assert_equal '1' "$(widget_count "$WORK_DIR/elsewhere-out.json")" '控件已在左侧栏时：不重复添加'
assert_equal "$(md5sum < "$elsewhere")" "$(md5sum < "$WORK_DIR/elsewhere-out.json")" '控件已在左侧栏时：整份配置不变'

# ---- 插件启用：只在用户还没表达过意愿时写入 -----------------------------------
plugin_settings="$WORK_DIR/plugin_settings.json"
printf '%s\n' '{}' > "$plugin_settings"
jq --arg plugin cachyosAgents -f "$ENABLE_JQ" "$plugin_settings" > "$WORK_DIR/ps-fresh.json"
assert_equal 'true' "$(jq -r '.cachyosAgents.enabled' "$WORK_DIR/ps-fresh.json")" '插件设置：首次安装会启用'
assert_equal 'true' "$(jq -r '."localStatus".enabled // true' "$WORK_DIR/ps-fresh.json")" '插件设置：不影响其他插件'

disabled="$WORK_DIR/ps-disabled.json"
printf '%s\n' '{"cachyosAgents": {"enabled": false, "displayMode": "week"}}' > "$disabled"
jq --arg plugin cachyosAgents -f "$ENABLE_JQ" "$disabled" > "$WORK_DIR/ps-disabled-out.json"
assert_equal 'false' "$(jq -r '.cachyosAgents.enabled' "$WORK_DIR/ps-disabled-out.json")" \
    '插件设置：用户关掉过就不会被重装打开'
assert_equal 'week' "$(jq -r '.cachyosAgents.displayMode' "$WORK_DIR/ps-disabled-out.json")" \
    '插件设置：用户的视图选择被保留'

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
