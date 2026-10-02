#!/usr/bin/env bash

# 主题同步的回归测试。
#
# 全程用临时 HOME 与伪造的 dms-colors.json，不碰用户的真实配置。
# 盯的是：模式映射正确、只改一个键、幂等、缺数据时明确失败而不是静默当作成功。

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR
readonly SYNC="$PROJECT_DIR/bin/cachyos-agent-theme-sync"

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

home="$WORK_DIR/home"
mkdir -p "$home/.claude"
colors="$WORK_DIR/dms-colors.json"

write_colors() {
    printf '{"mode": "%s", "dank16": {}}\n' "$1" > "$colors"
}

run_sync() {
    HOME="$home" CACHYOS_DMS_COLORS_FILE="$colors" "$SYNC" "$@"
}

# 已有的 settings.json 里放一个无关键，用来验证"只改一个键"。
printf '%s\n' '{"model": "opus", "env": {"FOO": "bar"}}' > "$home/.claude/settings.json"

# ---- dark → theme=dark --------------------------------------------------------
write_colors dark
run_sync --quiet >/dev/null 2>&1
# 现在 settings.json 指向**自定义主题**；明暗由主题文件里的 base 决定。
assert_equal 'cachyos' "$(jq -r '.theme' "$home/.claude/settings.json")" 'dark 模式：settings 指向自定义主题'
assert_equal 'dark' "$(jq -r '.base' "$home/.claude/themes/cachyos.json" 2>/dev/null || echo 缺失)" \
    'dark 模式：主题文件的 base=dark'
assert_equal 'opus' "$(jq -r '.model' "$home/.claude/settings.json")" 'dark 模式：无关键 model 未被动过'
assert_equal 'bar' "$(jq -r '.env.FOO' "$home/.claude/settings.json")" 'dark 模式：嵌套对象未被动过'

# ---- 幂等：再跑一次文件逐字节不变 ---------------------------------------------
before="$(md5sum < "$home/.claude/settings.json")"
run_sync --quiet >/dev/null 2>&1
assert_equal "$before" "$(md5sum < "$home/.claude/settings.json")" '幂等：重复执行不改变文件'

# ---- light → theme=light ------------------------------------------------------
write_colors light
run_sync --quiet >/dev/null 2>&1
assert_equal 'light' "$(jq -r '.base' "$home/.claude/themes/cachyos.json" 2>/dev/null || echo 缺失)" \
    'light 模式：主题文件的 base=light（切换靠重写主题文件）'

# ---- --dry-run 不写文件 -------------------------------------------------------
write_colors dark
before="$(md5sum < "$home/.claude/settings.json")"
run_sync --dry-run >/dev/null 2>&1
assert_equal "$before" "$(md5sum < "$home/.claude/settings.json")" '--dry-run：不修改任何文件'

# ---- 缺配色文件：明确失败，不当成成功 -----------------------------------------
rm -f "$colors"
if run_sync --quiet >/dev/null 2>&1; then
    fail '缺配色文件时不该返回成功'
else
    pass '缺配色文件：退出码非 0（不静默成功）'
fi

# ---- 未知模式：明确失败 -------------------------------------------------------
write_colors "purple"
if run_sync --quiet >/dev/null 2>&1; then
    fail '未知模式不该返回成功'
else
    pass '未知模式：退出码非 0'
fi

# ---- 没装 Claude Code：跳过而不是创建配置 -------------------------------------
write_colors dark
rm -rf "$home/.claude"
run_sync --quiet >/dev/null 2>&1
assert_equal 'false' "$([[ -e "$home/.claude/settings.json" ]] && echo true || echo false)" \
    '未安装 Claude Code：不创建配置文件'

# ---- 装了但还没有 settings.json：也不替它创建 ---------------------------------
mkdir -p "$home/.claude"
run_sync --quiet >/dev/null 2>&1
assert_equal 'false' "$([[ -e "$home/.claude/settings.json" ]] && echo true || echo false)" \
    '有目录但无 settings.json：不创建骨架配置'

# ---- --status 不写文件 --------------------------------------------------------
printf '%s\n' '{"model": "opus"}' > "$home/.claude/settings.json"
before="$(md5sum < "$home/.claude/settings.json")"
run_sync --status >/dev/null 2>&1
assert_equal "$before" "$(md5sum < "$home/.claude/settings.json")" '--status：不修改文件'

# ---- 主题文件：自定义主题 + Hermes skin ---------------------------------------
# 键集与校验都来自 agent_theme.py；这里验证它真的被写出来、格式合法、且幂等。
write_colors dark
rm -rf "$home/.claude/themes"
mkdir -p "$home/.hermes"          # 假装装了 Hermes，验证 skin 路径
run_sync --quiet >/dev/null 2>&1
theme_file="$home/.claude/themes/cachyos.json"
assert_equal 'true' "$([[ -f $theme_file ]] && echo true || echo false)" '生成了 Claude 自定义主题文件'
assert_equal 'true' "$(jq -e '.name == "CachyOS" and .base == "dark" and (.overrides | length) >= 37' "$theme_file" >/dev/null 2>&1 && echo true || echo false)" \
    '主题文件结构正确（name/base/overrides 键数）'
assert_equal 'cachyos' "$(jq -r '.theme' "$home/.claude/settings.json")" \
    'settings.json 指向自定义主题而不是内建 dark/light'

skin="$home/.hermes/skins/cachyos.yaml"
assert_equal 'true' "$([[ -f $skin ]] && echo true || echo false)" '装了 Hermes 时生成 skin'
assert_equal '44' "$(grep -cE '^  [a-z_]+: "#[0-9a-f]{6}"$' "$skin")" 'skin 有 44 个合法颜色行'
assert_equal 'cachyos' "$(head -1 "$skin" | awk '{print $2}')" 'skin 首行是 name: cachyos'

# 幂等：内容不变就不重写（避免每次主题同步都触发 agent 重载）
before_theme="$(md5sum < "$theme_file")"
before_skin="$(md5sum < "$skin")"
run_sync --quiet >/dev/null 2>&1
assert_equal "$before_theme" "$(md5sum < "$theme_file")" '主题文件幂等'
assert_equal "$before_skin" "$(md5sum < "$skin")" 'skin 幂等'

# --dry-run 不得写文件
rm -f "$theme_file" "$skin"
run_sync --dry-run >/dev/null 2>&1
assert_equal 'false' "$([[ -e $theme_file || -e $skin ]] && echo true || echo false)" '--dry-run 不生成主题文件'

# 调色板缺失时**什么都不动**：命令以非 0 退出，既不写 settings.json，也不删已有的主题文件。
# 这比"回落到 dark/light"更安全——算不出新主题时保持现状，而不是把一个可能可用的主题踢掉。
write_colors dark
run_sync --quiet >/dev/null 2>&1          # 先重新生成主题文件，才有东西可"保留"
rm -f "$colors"
theme_before="$(jq -r '.theme' "$home/.claude/settings.json")"
if run_sync --quiet >/dev/null 2>&1; then
    fail '没有调色板时不该返回成功'
else
    pass '没有调色板时命令失败（不假装同步成功）'
fi
assert_equal "$theme_before" "$(jq -r '.theme' "$home/.claude/settings.json")" \
    '没有调色板时不改动 settings.json'
assert_equal 'true' "$([[ -e $home/.claude/themes/cachyos.json ]] && echo true || echo false)" \
    '没有调色板时不删除已有的主题文件'


printf '\n%s 项检查通过。\n' "$PASS_COUNT"
