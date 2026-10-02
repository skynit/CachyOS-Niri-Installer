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

# ---- 没有 barConfigs 时：什么都不做（绝不凭空造一个栏）-------------------------
# DMS 读设置是整体赋值（`root[k] = raw`），它的默认状态栏只在"键不存在"时生效。
# 如果这里造一个只含本控件的栏，全新机器上用户会得到一个几乎是空的顶栏——
# 这比"控件没显示"严重得多。这条断言就是防止那个 bug 回归。
empty="$WORK_DIR/empty.json"
printf '%s\n' '{"currentThemeName":"x"}' > "$empty"
add_widget "$empty" > "$WORK_DIR/empty-once.json"
assert_equal 'false' "$(jq 'has("barConfigs")' "$WORK_DIR/empty-once.json")" \
    '空配置：不创建 barConfigs（让 DMS 用它自己的默认栏）'
assert_equal "$(jq -S . "$empty" | md5sum)" "$(jq -S . "$WORK_DIR/empty-once.json" | md5sum)" \
    '空配置：语义完全不变（jq 只会重排格式）'
assert_equal "$(jq -c '.barConfigs' "$empty" | head -c 4)" "$(jq -c '.barConfigs' "$WORK_DIR/empty-once.json" | head -c 4)" \
    '空配置：barConfigs 仍为 null'

# barConfigs 是空数组时同样不碰
printf '%s\n' '{"barConfigs":[]}' > "$WORK_DIR/empty-array.json"
add_widget "$WORK_DIR/empty-array.json" > "$WORK_DIR/empty-array-out.json"
assert_equal '0' "$(jq '.barConfigs | length' "$WORK_DIR/empty-array-out.json")" \
    '空的 barConfigs 数组：仍然不创建内容'

# ---- DMS 默认栏形状：所有默认控件都要保留 --------------------------------------
# 这是全新机器最可能出现的形状。曾经的真 bug：非空分支没问题，但空分支会毁掉默认栏。
default_bar="$WORK_DIR/default-bar.json"
jq -n '{barConfigs: [{id: "default", position: 1,
        leftWidgets: ["launcherButton", "workspaceSwitcher", "focusedWindow"],
        centerWidgets: ["music", "clock", "weather"],
        rightWidgets: ["systemTray", "clipboard", "cpuUsage", "memUsage", "notificationButton", "battery", "controlCenterButton"]}]}' \
    > "$default_bar"
add_widget "$default_bar" > "$WORK_DIR/default-bar-out.json"
assert_equal '["launcherButton","workspaceSwitcher","focusedWindow"]' \
    "$(jq -c '.barConfigs[0].leftWidgets' "$WORK_DIR/default-bar-out.json")" '默认栏：左侧控件一个不少'
assert_equal '["music","clock","weather"]' \
    "$(jq -c '.barConfigs[0].centerWidgets' "$WORK_DIR/default-bar-out.json")" '默认栏：中间控件一个不少'
assert_equal '["systemTray","clipboard","cpuUsage","memUsage","notificationButton","battery","controlCenterButton","cachyosAgents"]' \
    "$(jq -c '[.barConfigs[0].rightWidgets[] | if type == "object" then .id else . end]' "$WORK_DIR/default-bar-out.json")" \
    '默认栏：右侧原有控件全在，本控件追加在末尾'
assert_equal 'default' "$(jq -r '.barConfigs[0].id' "$WORK_DIR/default-bar-out.json")" '默认栏：栏自身的 id 未被动过'

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

# ---- 随包副本的完整性 ----------------------------------------------------------
# 副本是"新电脑复刻"时真正被安装的东西；改名或漏文件不会报错，只会让插件静默失效。
PLUGIN_SRC="$PROJECT_DIR/assets/dms-plugins/CachyosAgents"
manifest="$PLUGIN_SRC/plugin.json"

assert_equal 'cachyosAgents' "$(jq -r '.id' "$manifest")" '随包副本：plugin.json 的 id 与目录约定一致'
assert_equal 'widget' "$(jq -r '.type' "$manifest")" '随包副本：类型是 widget'
assert_equal 'true' "$(jq -e '.capabilities | index("dankbar-widget") != null' "$manifest")" \
    '随包副本：声明了 dankbar-widget 能力'

# plugin.json 里声明的组件与设置文件必须真的存在（改名最容易漏掉这里）。
for key in component settings; do
    declared="$(jq -r --arg key "$key" '.[$key]' "$manifest")"
    target="$PLUGIN_SRC/${declared#./}"
    assert_equal 'true' "$([[ -f $target ]] && echo true || echo false)" \
        "随包副本：plugin.json 声明的 $key 文件存在（$declared）"
done

# 安装器必须有安装插件资产的逻辑：文件在包里但没进 $HOME，就是"装了但看不见"。
if grep -q "dms-plugins/CachyosAgents" "$PROJECT_DIR/install.sh"; then
    pass '随包副本：install.sh 有安装插件资产的逻辑'
else
    fail '随包副本：install.sh 没有安装插件资产的逻辑'
fi

# 逐个确认运行文件都在包里（改名或漏文件不会报错，只会让插件静默失效）。
for asset in plugin.json Usage.js UsageSource.qml CachyosAgents.qml UsageDetails.qml CachyosAgentsSettings.qml; do
    assert_equal 'true' "$([[ -f "$PLUGIN_SRC/$asset" ]] && echo true || echo false)" "随包副本：包含 $asset"
done

# Usage.js 必须能通过语法检查（没有 node 就跳过，不让测试环境依赖 node）。
if command -v node >/dev/null 2>&1; then
    if node --check "$PLUGIN_SRC/Usage.js" >/dev/null 2>&1; then
        pass '随包副本：Usage.js 语法有效（node --check）'
    else
        fail '随包副本：Usage.js 语法无效'
    fi
else
    pass '随包副本：没有 node，跳过 Usage.js 语法检查'
fi

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
