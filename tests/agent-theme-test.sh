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
assert_equal 'dark' "$(jq -r '.theme' "$home/.claude/settings.json")" 'dark 模式：写入 theme=dark'
assert_equal 'opus' "$(jq -r '.model' "$home/.claude/settings.json")" 'dark 模式：无关键 model 未被动过'
assert_equal 'bar' "$(jq -r '.env.FOO' "$home/.claude/settings.json")" 'dark 模式：嵌套对象未被动过'

# ---- 幂等：再跑一次文件逐字节不变 ---------------------------------------------
before="$(md5sum < "$home/.claude/settings.json")"
run_sync --quiet >/dev/null 2>&1
assert_equal "$before" "$(md5sum < "$home/.claude/settings.json")" '幂等：重复执行不改变文件'

# ---- light → theme=light ------------------------------------------------------
write_colors light
run_sync --quiet >/dev/null 2>&1
assert_equal 'light' "$(jq -r '.theme' "$home/.claude/settings.json")" 'light 模式：切换为 theme=light'

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

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
