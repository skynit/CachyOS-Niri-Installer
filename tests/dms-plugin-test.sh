#!/usr/bin/env bash

# DMS 插件接线的回归测试。
#
# 这两个 jq 程序是"改用户配置文件"的地方，出错不会报错、只会静默改坏布局或悄悄不生效：
#   1. 加控件必须**幂等**：重装不能在状态栏里堆出第二个同名控件
#   2. 加控件必须**只动 barConfigs[0]**：其他栏、其他设置一个字节都不能变
#   3. 加控件必须**只增不覆盖**：用户已有的对象（enabled:false）保持原位原设置
#   4. 启用插件必须**尊重用户意愿**：他关掉之后再重装，不能又给打开
#   5. 没有 barConfigs 时什么都不做，而不是凭空造栏
#
# 另外逐一核对 7 个随包插件的资产与 config-manifest.tsv 映射：插件文件在包里、但清单
# 漏登记（或登记错目录）时，`cachyos-config update` 会把用户运行副本刷坏却不报错。

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR
readonly WIDGET_JQ="$PROJECT_DIR/assets/dms/add-dms-bar-widgets.jq"
readonly ENABLE_JQ="$PROJECT_DIR/assets/dms/enable-dms-plugin.jq"
readonly MANIFEST="$PROJECT_DIR/assets/config-manifest.tsv"
readonly INSTALL_SH="$PROJECT_DIR/install.sh"
readonly PLUGINS_DIR="$PROJECT_DIR/assets/dms-plugins"

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

# 安装器实际传给 jq 的参数（与 install.sh 的 DMS_BAR_WIDGETS 一致）。
readonly INSTALLER_WIDGETS='{"left":["localTranslate","phoneConnect","focus","localLyrics"],"right":["cachyosAgents","localStatus"]}'

add_widgets() {
    local widgets="$1"
    local file="$2"
    jq --argjson widgets "$widgets" -f "$WIDGET_JQ" "$file"
}

# 语义指纹：jq -S 归一化后取 md5，只比较 JSON 语义、不比较排版。
semantic_hash() {
    jq -S . "$1" | md5sum
}

# 某个插件 id 在任意栏出现几次（字符串与对象两种写法都算）。
id_count() {
    local file="$1"
    local id="$2"
    jq --arg id "$id" '
        [.barConfigs[]?
         | (.leftWidgets? // [])[], (.centerWidgets? // [])[], (.rightWidgets? // [])[]
         | if type == "object" then .id else . end
         | select(. == $id)] | length' "$file"
}

# 第一个栏某一侧的控件 id 列表（保留顺序）。
side_ids() {
    local file="$1"
    local side="$2"
    jq -c --arg side "$side" '
        (.barConfigs[0][$side] // [])
        | map(if type == "object" then .id else . end)' "$file"
}

make_default_bar() {
    jq -n '{barConfigs: [{id: "default", position: 1,
            leftWidgets: ["launcherButton", "workspaceSwitcher", "focusedWindow"],
            centerWidgets: ["music", "clock", "weather"],
            rightWidgets: ["systemTray", "clipboard", "cpuUsage", "memUsage",
                           "notificationButton", "battery", "controlCenterButton"]}]}'
}

readonly DEFAULT_LEFT='["launcherButton","workspaceSwitcher","focusedWindow"]'
readonly DEFAULT_CENTER='["music","clock","weather"]'
readonly DEFAULT_RIGHT='["systemTray","clipboard","cpuUsage","memUsage","notificationButton","battery","controlCenterButton"]'

# ---- 没有 barConfigs 时：什么都不做（绝不凭空造一个栏）-------------------------
# DMS 读设置是整体赋值（`root[k] = raw`），它的默认状态栏只在"键不存在"时生效。
# 如果这里造一个只含本控件的栏，全新机器上用户会得到一个几乎是空的顶栏——
# 这比"控件没显示"严重得多。这条断言就是防止那个 bug 回归。
empty="$WORK_DIR/empty.json"
printf '%s\n' '{"currentThemeName":"x"}' > "$empty"
add_widgets "$INSTALLER_WIDGETS" "$empty" > "$WORK_DIR/empty-once.json"
assert_equal 'false' "$(jq 'has("barConfigs")' "$WORK_DIR/empty-once.json")" \
    '空配置：不创建 barConfigs（让 DMS 用它自己的默认栏）'
assert_equal "$(semantic_hash "$empty")" "$(semantic_hash "$WORK_DIR/empty-once.json")" \
    '空配置：语义完全不变（jq 只会重排格式）'
assert_equal 'null' "$(jq -c '.barConfigs' "$WORK_DIR/empty-once.json")" \
    '空配置：barConfigs 仍为 null'

# 用户显式给了空 widgets 对象时同理：没有栏就没有可接的地方。
add_widgets '{}' "$empty" > "$WORK_DIR/empty-nowidgets.json"
assert_equal "$(semantic_hash "$empty")" "$(semantic_hash "$WORK_DIR/empty-nowidgets.json")" \
    '空配置 + 空 widgets：语义完全不变'

# barConfigs 是空数组时同样不碰
printf '%s\n' '{"barConfigs":[]}' > "$WORK_DIR/empty-array.json"
add_widgets "$INSTALLER_WIDGETS" "$WORK_DIR/empty-array.json" > "$WORK_DIR/empty-array-out.json"
assert_equal '0' "$(jq '.barConfigs | length' "$WORK_DIR/empty-array-out.json")" \
    '空的 barConfigs 数组：仍然不创建内容'
assert_equal "$(semantic_hash "$WORK_DIR/empty-array.json")" "$(semantic_hash "$WORK_DIR/empty-array-out.json")" \
    '空的 barConfigs 数组：语义完全不变'

# ---- DMS 默认栏形状：所有默认控件都要保留，6 个插件按参数顺序落位 --------------
# 这是全新机器最可能出现的形状。曾经的真 bug：非空分支没问题，但空分支会毁掉默认栏。
default_bar="$WORK_DIR/default-bar.json"
make_default_bar > "$default_bar"
add_widgets "$INSTALLER_WIDGETS" "$default_bar" > "$WORK_DIR/default-bar-out.json"
assert_equal "$DEFAULT_LEFT" \
    "$(jq -c '.barConfigs[0].leftWidgets | map(if type == "object" then .id else . end) | .[0:3]' "$WORK_DIR/default-bar-out.json")" \
    '默认栏：左侧原有控件一个不少（顺序不变）'
assert_equal '["launcherButton","workspaceSwitcher","focusedWindow","localTranslate","phoneConnect","focus","localLyrics"]' \
    "$(jq -c '.barConfigs[0].leftWidgets | map(if type == "object" then .id else . end)' "$WORK_DIR/default-bar-out.json")" \
    '默认栏：左侧按参数顺序追加 localTranslate→phoneConnect→focus→localLyrics'
assert_equal "$DEFAULT_CENTER" "$(side_ids "$WORK_DIR/default-bar-out.json" centerWidgets)" \
    '默认栏：中间控件一个不少'
assert_equal "$DEFAULT_RIGHT" \
    "$(jq -c '.barConfigs[0].rightWidgets | map(if type == "object" then .id else . end) | .[0:7]' "$WORK_DIR/default-bar-out.json")" \
    '默认栏：右侧原有控件全在（顺序不变）'
assert_equal '["systemTray","clipboard","cpuUsage","memUsage","notificationButton","battery","controlCenterButton","cachyosAgents","localStatus"]' \
    "$(jq -c '.barConfigs[0].rightWidgets | map(if type == "object" then .id else . end)' "$WORK_DIR/default-bar-out.json")" \
    '默认栏：右侧按参数顺序追加 cachyosAgents→localStatus'
assert_equal 'true' \
    "$(jq -e '.barConfigs[0].leftWidgets[3:] == [{"id":"localTranslate","enabled":true},{"id":"phoneConnect","enabled":true},{"id":"focus","enabled":true},{"id":"localLyrics","enabled":true}]' "$WORK_DIR/default-bar-out.json")" \
    '默认栏：新控件写成 {id, enabled:true} 对象'
assert_equal 'default' "$(jq -r '.barConfigs[0].id' "$WORK_DIR/default-bar-out.json")" '默认栏：栏自身的 id 未被动过'
assert_equal '1' "$(jq -r '.barConfigs[0].position' "$WORK_DIR/default-bar-out.json")" '默认栏：栏的 position 未被动过'

# ---- 幂等：同一输入应用两次，输出逐字节相同 -----------------------------------
add_widgets "$INSTALLER_WIDGETS" "$WORK_DIR/default-bar-out.json" > "$WORK_DIR/default-bar-twice.json"
assert_equal '6' \
    "$(jq '[.barConfigs[0].leftWidgets[], .barConfigs[0].rightWidgets[]
           | if type == "object" then .id else . end
           | select(. as $id | ["localTranslate","phoneConnect","focus","localLyrics","cachyosAgents","localStatus"] | index($id))] | length' \
        "$WORK_DIR/default-bar-twice.json")" \
    '幂等：6 个插件控件各只出现一次'
assert_equal "$(md5sum < "$WORK_DIR/default-bar-out.json")" "$(md5sum < "$WORK_DIR/default-bar-twice.json")" \
    '幂等：第二次执行输出与第一次逐字节相同'

# ---- 已有布局：只增不覆盖，已有对象保持原位与原设置 ---------------------------
# 覆盖多种"用户已经自己加过"的形态：
#   - leftWidgets 里的字符串（localTranslate）
#   - leftWidgets 里 enabled:false 的对象（focus）——重装绝不能把它打开或移动
#   - centerWidgets 里的对象（phoneConnect）——不能因为不在目标栏就重复添加
#   - rightWidgets 里 enabled:false 的对象（cachyosAgents）
existing="$WORK_DIR/existing.json"
jq -n '{currentThemeName: "keep-me", cursorSettings: {size: 42},
        barConfigs: [{leftWidgets: ["localTranslate", {id: "focus", enabled: false}],
                      centerWidgets: [{id: "phoneConnect", enabled: false}],
                      rightWidgets: [{id: "cachyosAgents", enabled: false}]}]}' > "$existing"
add_widgets "$INSTALLER_WIDGETS" "$existing" > "$WORK_DIR/existing-once.json"
for id in localTranslate phoneConnect focus localLyrics cachyosAgents localStatus; do
    assert_equal '1' "$(id_count "$WORK_DIR/existing-once.json" "$id")" "已有布局：$id 只出现一次"
done
assert_equal '["localTranslate",{"id":"focus","enabled":false},{"id":"localLyrics","enabled":true}]' \
    "$(jq -c '.barConfigs[0].leftWidgets' "$WORK_DIR/existing-once.json")" \
    '已有布局：左侧字符串与对象都保持原位，只追加缺失的 localLyrics'
assert_equal '[{"id":"phoneConnect","enabled":false}]' \
    "$(jq -c '.barConfigs[0].centerWidgets' "$WORK_DIR/existing-once.json")" \
    '已有布局：别的栏里的控件不被移动'
assert_equal '[{"id":"cachyosAgents","enabled":false},{"id":"localStatus","enabled":true}]' \
    "$(jq -c '.barConfigs[0].rightWidgets' "$WORK_DIR/existing-once.json")" \
    '已有布局：右侧原有对象保持 false，只追加缺失的 localStatus'
assert_equal 'keep-me' "$(jq -r '.currentThemeName' "$WORK_DIR/existing-once.json")" '已有布局：无关的顶层键未被动过'
assert_equal '42' "$(jq -r '.cursorSettings.size' "$WORK_DIR/existing-once.json")" '已有布局：嵌套对象未被动过'
assert_equal "$(jq -S 'del(.barConfigs)' "$existing" | md5sum)" \
    "$(jq -S 'del(.barConfigs)' "$WORK_DIR/existing-once.json" | md5sum)" \
    '已有布局：除 barConfigs 外语义完全一致'

# 已有布局下也必须幂等（第二轮不能把 localLyrics/localStatus 再加一次）。
add_widgets "$INSTALLER_WIDGETS" "$WORK_DIR/existing-once.json" > "$WORK_DIR/existing-twice.json"
assert_equal "$(md5sum < "$WORK_DIR/existing-once.json")" "$(md5sum < "$WORK_DIR/existing-twice.json")" \
    '已有布局：重复执行逐字节相同'

# ---- 只传 left / 只传 right：另一侧一个字节都不能变 ---------------------------
add_widgets '{"left":["focus"]}' "$default_bar" > "$WORK_DIR/left-only.json"
assert_equal "$DEFAULT_RIGHT" "$(side_ids "$WORK_DIR/left-only.json" rightWidgets)" \
    '只传 left：右侧原有控件不变（不会凭空多出插件）'
assert_equal '["launcherButton","workspaceSwitcher","focusedWindow","focus"]' \
    "$(side_ids "$WORK_DIR/left-only.json" leftWidgets)" \
    '只传 left：缺失控件追加到左侧'

add_widgets '{"right":["focus"]}' "$default_bar" > "$WORK_DIR/right-only.json"
assert_equal "$DEFAULT_LEFT" "$(side_ids "$WORK_DIR/right-only.json" leftWidgets)" \
    '只传 right：左侧原有控件不变'
assert_equal '["systemTray","clipboard","cpuUsage","memUsage","notificationButton","battery","controlCenterButton","focus"]' \
    "$(side_ids "$WORK_DIR/right-only.json" rightWidgets)" \
    '只传 right：缺失控件追加到右侧'

# 空 widgets 对象：两侧都不动。
add_widgets '{}' "$default_bar" > "$WORK_DIR/default-nowidgets.json"
assert_equal "$(semantic_hash "$default_bar")" "$(semantic_hash "$WORK_DIR/default-nowidgets.json")" \
    '默认栏 + 空 widgets：语义完全不变'

# ---- 只改 barConfigs[0]：第二栏原样 -------------------------------------------------
multi_bar="$WORK_DIR/multi-bar.json"
jq -n '{barConfigs: [{leftWidgets: ["a"], rightWidgets: []},
                      {id: "second", leftWidgets: ["b"], rightWidgets: ["c"]}]}' > "$multi_bar"
add_widgets "$INSTALLER_WIDGETS" "$multi_bar" > "$WORK_DIR/multi-bar-out.json"
assert_equal '2' "$(jq '.barConfigs | length' "$WORK_DIR/multi-bar-out.json")" \
    '只改第一栏：没有多造/少造栏'
assert_equal "$(jq -c '.barConfigs[1]' "$multi_bar")" "$(jq -c '.barConfigs[1]' "$WORK_DIR/multi-bar-out.json")" \
    '只改第一栏：第二栏原样（控件与设置都不动）'

# ---- 插件启用：每个插件首次安装写入 enabled=true，但不覆盖用户已有设置 -------------
all_plugin_ids=(cachyosAgents localStatus localTranslate localLyrics phoneConnect focus top)
for plugin_id in "${all_plugin_ids[@]}"; do
    printf '%s\n' '{}' > "$WORK_DIR/ps-fresh.json"
    jq --arg plugin "$plugin_id" -f "$ENABLE_JQ" "$WORK_DIR/ps-fresh.json" > "$WORK_DIR/ps-fresh-out.json"
    assert_equal 'true' "$(jq -r --arg plugin "$plugin_id" '.[$plugin].enabled' "$WORK_DIR/ps-fresh-out.json")" \
        "插件设置：首次安装会启用 $plugin_id"
done

disabled="$WORK_DIR/ps-disabled.json"
printf '%s\n' '{"localStatus": {"enabled": false, "displayMode": "compact"}, "focus": {"enabled": true, "mode": "pomodoro"}, "theme": "dark"}' > "$disabled"
jq --arg plugin localStatus -f "$ENABLE_JQ" "$disabled" > "$WORK_DIR/ps-disabled-out.json"
assert_equal 'false' "$(jq -r '.localStatus.enabled' "$WORK_DIR/ps-disabled-out.json")" \
    '插件设置：用户关掉过就不会被重装打开'
assert_equal 'compact' "$(jq -r '.localStatus.displayMode' "$WORK_DIR/ps-disabled-out.json")" \
    '插件设置：用户的视图选择被保留'
assert_equal '{"enabled":true,"mode":"pomodoro"}' "$(jq -c '.focus' "$WORK_DIR/ps-disabled-out.json")" \
    '插件设置：其他插件设置一个字节都不动'
assert_equal 'dark' "$(jq -r '.theme' "$WORK_DIR/ps-disabled-out.json")" \
    '插件设置：无关的顶层键被保留'

# ---- 随包副本的完整性：7 个插件逐一核对 ---------------------------------------
# 目录名是 DMS 的安装目录名（大小写必须与上游一致），插件 ID 来自 plugin.json。
plugin_sources=(CachyosAgents LocalStatus LocalTranslate LocalLyrics PhoneConnect Focus Top)
plugin_targets=(CachyosAgents LocalStatus localTranslate localLyrics PhoneConnect Focus Top)
plugin_ids=(cachyosAgents localStatus localTranslate localLyrics phoneConnect focus top)
plugin_types=(widget widget widget widget widget widget daemon)

# 运行副本 = 安装器会复制进 ~/.config/DankMaterialShell/plugins/<目录>/ 的文本资产：
# QML、JS、plugin.json、README、tests/*.cjs 与 data/*。Go 源码与构建脚本不安装。
runtime_files() {
    find "$1" -maxdepth 3 -type f \
        \( -name '*.qml' -o -name '*.js' -o -name 'plugin.json' -o -name 'README.md' \
           -o -path '*/tests/*' -o -path '*/data/*' \) \
        -printf '%P\n' | sort
}

for index in "${!plugin_sources[@]}"; do
    source_name="${plugin_sources[$index]}"
    target_name="${plugin_targets[$index]}"
    expected_id="${plugin_ids[$index]}"
    source_dir="$PLUGINS_DIR/$source_name"
    manifest_dir=".config/DankMaterialShell/plugins/$target_name"

    assert_equal 'true' "$([[ -d $source_dir ]] && echo true || echo false)" "随包副本：目录存在（$source_name）"
    assert_equal "$expected_id" "$(jq -r '.id' "$source_dir/plugin.json")" \
        "随包副本：$source_name/plugin.json 的 id 是 $expected_id"
    assert_equal "${plugin_types[$index]}" "$(jq -r '.type' "$source_dir/plugin.json")" \
        "随包副本：$source_name 的类型是 ${plugin_types[$index]}"

    # plugin.json 声明的组件与设置文件必须真的存在（改名最容易漏掉这里）。
    for key in component settings; do
        declared="$(jq -r --arg key "$key" '.[$key] // empty' "$source_dir/plugin.json")"
        [[ -z $declared ]] && continue
        assert_equal 'true' "$([[ -f "$source_dir/${declared#./}" ]] && echo true || echo false)" \
            "随包副本：$source_name 声明的 $key 文件存在（$declared）"
    done

    # 安装器必须真的会复制这个插件（文件在包里但没进 $HOME = 装了但看不见）。
    if grep -q "install_dms_plugin_assets $source_name $target_name" "$INSTALL_SH"; then
        pass "随包副本：install.sh 安装 $source_name → $target_name"
    else
        fail "随包副本：install.sh 没有安装 $source_name → $target_name"
    fi

    while IFS= read -r asset; do
        [[ -n $asset ]] || continue
        assert_equal 'true' "$([[ -s "$source_dir/$asset" ]] && echo true || echo false)" \
            "随包副本：$source_name/$asset 存在且非空"
        assert_equal "$manifest_dir/$asset" \
            "$(awk -F '\t' -v source="dms-plugins/$source_name/$asset" '$1 == source { print $2 }' "$MANIFEST")" \
            "配置更新清单：$source_name/$asset → $manifest_dir/$asset"
    done < <(runtime_files "$source_dir")

    # 有测试套件的插件，安装器还要把 tests/*.cjs 一并装进运行目录。
    if [[ -d "$source_dir/tests" ]]; then
        if grep -q "install_dms_plugin_tests $source_name $target_name" "$INSTALL_SH"; then
            pass "随包副本：install.sh 安装 $source_name 的插件测试"
        else
            fail "随包副本：install.sh 没有安装 $source_name 的插件测试"
        fi
    fi
done

# LocalTranslate 的内置词典必须随包（插件运行时直接读它，缺了翻译面板就是空的）。
for data_file in data/dictionary.sqlite3 data/cedict.txt.gz data/manifest.json data/NOTICE.md data/CC-BY-SA-4.0.txt; do
    assert_equal 'true' "$([[ -s "$PLUGINS_DIR/LocalTranslate/$data_file" ]] && echo true || echo false)" \
        "LocalTranslate：随包数据 $data_file 存在且非空"
done
if grep -q 'install_dms_plugin_subtree LocalTranslate localTranslate data' "$INSTALL_SH"; then
    pass '随包副本：install.sh 会安装 LocalTranslate 的 data/ 子树'
else
    fail '随包副本：install.sh 没有安装 LocalTranslate 的 data/ 子树'
fi
if grep -q 'install_dms_plugin_subtree Top Top components' "$INSTALL_SH"; then
    pass '随包副本：install.sh 会安装 Top 的 components/ 子树'
else
    fail '随包副本：install.sh 没有安装 Top 的 components/ 子树'
fi

# ---- CachyosAgents 旧断言保留（改名/改名后漏文件最容易静默失效）-----------------
PLUGIN_SRC="$PLUGINS_DIR/CachyosAgents"
manifest="$PLUGIN_SRC/plugin.json"

assert_equal 'AI 集成' "$(jq -r '.name' "$manifest")" 'CachyosAgents：插件名称为 AI 集成'
assert_equal 'true' "$(jq -e '.capabilities | index("dankbar-widget") != null' "$manifest")" \
    'CachyosAgents：声明了 dankbar-widget 能力'

# Usage.js 必须能通过语法检查（没有 node 就跳过，不让测试环境依赖 node）。
if command -v node >/dev/null 2>&1; then
    if node --check "$PLUGIN_SRC/Usage.js" >/dev/null 2>&1; then
        pass 'CachyosAgents：Usage.js 语法有效（node --check）'
    else
        fail 'CachyosAgents：Usage.js 语法无效'
    fi
else
    pass 'CachyosAgents：没有 node，跳过 Usage.js 语法检查'
fi

# "设为默认 agent"按钮：弹窗只做展示（点它 → source.setDefaultAgent），进程在数据源层。
if grep -q '设为默认' "$PLUGIN_SRC/UsageDetails.qml"; then
    pass 'CachyosAgents：弹窗里有「设为默认」按钮'
else
    fail 'CachyosAgents：弹窗里没有按钮'
fi
if grep -q 'installedAgents' "$PLUGIN_SRC/UsageDetails.qml" &&
    grep -q 'parseAgentState' "$PLUGIN_SRC/UsageSource.qml"; then
    pass 'CachyosAgents：状态来自数据源，解析走 Usage.js'
else
    fail 'CachyosAgents：弹窗与数据源的分工不对'
fi
if grep -q 'cachyos-default-agent' "$PLUGIN_SRC/UsageSource.qml"; then
    pass 'CachyosAgents：数据源调用 cachyos-default-agent'
else
    fail 'CachyosAgents：数据源没有调用 cachyos-default-agent'
fi
if grep -q 'Quickshell.Io' "$PLUGIN_SRC/UsageDetails.qml"; then
    fail 'CachyosAgents：弹窗不该依赖 Quickshell（那样无法单独校验）'
else
    pass 'CachyosAgents：弹窗保持纯展示（无 Quickshell 依赖）'
fi

# ---- Go helper：随包二进制存在、可执行、且刻意不进配置清单 ---------------------
# 二进制不进 config-manifest.tsv：cachyos-config update 固定用 0644 安装，会丢可执行位。
for helper in translate-lookup lyrics-helper phone-connect focus-helper top-helper; do
    assert_equal 'true' "$([[ -x "$PROJECT_DIR/assets/go-bin/$helper" ]] && echo true || echo false)" \
        "Go helper：assets/go-bin/$helper 存在且可执行"
    assert_equal '' \
        "$(awk -F '\t' -v source="go-bin/$helper" '$1 == source { print $2 }' "$MANIFEST")" \
        "Go helper：$helper 不登记在配置清单（否则会丢可执行位）"
done
assert_equal '' "$(awk -F '\t' '$1 ~ /go-bin\// { print $1 }' "$MANIFEST")" \
    'Go helper：配置清单里完全没有 go-bin 条目'

# ---- install.sh 的接线入口 ----------------------------------------------------
# 旧 jq 已删除：文件在、但安装器还引用它，重装时就会 jq 报错中断。
assert_equal 'false' "$([[ -e "$PROJECT_DIR/assets/dms/add-agents-bar-widget.jq" ]] && echo true || echo false)" \
    '旧 jq：add-agents-bar-widget.jq 已删除'
if grep -q 'add-dms-bar-widgets.jq' "$INSTALL_SH"; then
    pass 'install.sh：引用新的 add-dms-bar-widgets.jq'
else
    fail 'install.sh：没有引用新的 add-dms-bar-widgets.jq'
fi
if grep -q 'add-agents-bar-widget.jq' "$INSTALL_SH"; then
    fail 'install.sh：仍在引用已删除的旧 jq'
else
    pass 'install.sh：不再引用旧 jq'
fi
# shellcheck disable=SC2016  # 这里匹配的是 install.sh 源码里的字面量，不是 shell 变量展开
if grep -q 'jq --argjson widgets "$DMS_BAR_WIDGETS" -f "$jq_program"' "$INSTALL_SH"; then
    pass 'install.sh：以 --argjson widgets 调用新 jq'
else
    fail 'install.sh：没有以 --argjson widgets 调用新 jq'
fi

bar_widgets="$(awk -F"'" '/^DMS_BAR_WIDGETS=/{print $2}' "$INSTALL_SH")"
assert_equal "$INSTALLER_WIDGETS" "$bar_widgets" \
    'install.sh：DMS_BAR_WIDGETS 与测试的 left/right 顺序一致'

installer_ids="$(awk '/^readonly -a DMS_PLUGIN_IDS=\(/{flag=1; next} flag && /^\)/{exit} flag {print $1}' "$INSTALL_SH" | sort)"
assert_equal "$(printf '%s\n' "${all_plugin_ids[@]}" | sort)" "$installer_ids" \
    'install.sh：DMS_PLUGIN_IDS 正好是 7 个插件 ID'
# shellcheck disable=SC2016  # 同上：匹配 install.sh 里的数组展开写法
if grep -q 'for plugin_id in "${DMS_PLUGIN_IDS\[@\]}"; do' "$INSTALL_SH"; then
    pass 'install.sh：逐个启用 DMS_PLUGIN_IDS 里的插件'
else
    fail 'install.sh：没有逐个启用 DMS_PLUGIN_IDS 里的插件'
fi

# ---- 电脑连接：新安装时同时提供 RDP 客户端与密码存储 ---------------------------
feature_packages="$(awk '/^readonly -a DMS_FEATURE_PACKAGES=\(/{flag=1; next} flag && /^\)/{exit} flag && $1 !~ /^#/ {print $1}' "$INSTALL_SH")"
for dependency in freerdp libsecret gnome-keyring; do
    assert_equal "$dependency" "$(printf '%s\n' "$feature_packages" | grep -x "$dependency" || true)" \
        "电脑连接：安装依赖 $dependency"
done

# ---- DMS 版本钉住：升级/降级都必须同步改测试，不能悄悄漂 ------------------------
pinned_version="$(awk -F'"' '/^readonly PINNED_DMS_VERSION=/{print $2}' "$INSTALL_SH")"
pinned_sha="$(awk -F'"' '/^readonly PINNED_DMS_SHA256_AMD64=/{print $2}' "$INSTALL_SH")"
assert_equal 'v1.6.2' "$pinned_version" 'DMS 版本：钉住 v1.6.2'
assert_equal '933d3d87ac462432f6e0265e47dc68171c7174592e2a8caba7b9b9710bda5e56' "$pinned_sha" \
    'DMS 版本：钉住 v1.6.2 的 SHA256'

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
