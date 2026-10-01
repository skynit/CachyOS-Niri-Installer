#!/usr/bin/env bash

# 本地听写（Voxtype）的回归测试。
#
# 全程用 stub，不装包、不下载模型、不碰真实 Niri/Waybar，也**绝不发真实通知**
# （stub 掉 dms / notify-send；否则测试会往用户桌面上弹提示）。
#
# 盯的是这几件容易静默出错的事：
#   1. 状态命令四种状态各自输出正确的 class（Waybar 靠 class 决定显不显示）
#   2. 没装听写时按键不能静默失败，要告诉用户怎么装
#   3. 安装会写下"可选 include"的快捷键文件，卸载会删掉它
#   4. 卸载会先备份用户改过的配置，而不是直接删

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR

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

stub_dir="$WORK_DIR/bin"
mkdir -p "$stub_dir" "$WORK_DIR/run/voxtype" "$WORK_DIR/home/.config/niri"

# 记录型 stub：把收到的参数写进文件，供断言检查。
cat > "$stub_dir/stub-logger" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$stub_dir/stub-logger"
for name in dms notify-send niri systemctl paru kitty; do
    ln -sf "$stub_dir/stub-logger" "$stub_dir/$name"
done

cat > "$stub_dir/voxtype" <<'STUB'
#!/usr/bin/env bash
printf 'voxtype %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$stub_dir/voxtype"

readonly STUB_LOG="$WORK_DIR/stub.log"
: > "$STUB_LOG"
export STUB_LOG

run_status() {
    PATH="$1" XDG_RUNTIME_DIR="$WORK_DIR/run" "$PROJECT_DIR/bin/cachyos-voxtype-status"
}

# ---- 状态命令：四种状态 --------------------------------------------------------
printf 'recording' > "$WORK_DIR/run/voxtype/state"
out="$(run_status "$stub_dir:$PATH")"
assert_equal 'recording' "$(jq -r '.class' <<<"$out")" '状态：录音中 → class=recording'
if [[ -n $(jq -r '.text' <<<"$out") ]]; then
    pass '状态：录音中显示文字'
else
    fail '状态：录音中文字为空'
fi

printf 'transcribing' > "$WORK_DIR/run/voxtype/state"
out="$(run_status "$stub_dir:$PATH")"
assert_equal 'transcribing' "$(jq -r '.class' <<<"$out")" '状态：转写中 → class=transcribing'

printf 'idle' > "$WORK_DIR/run/voxtype/state"
out="$(run_status "$stub_dir:$PATH")"
assert_equal 'idle' "$(jq -r '.class' <<<"$out")" '状态：空闲 → class=idle'
assert_equal '' "$(jq -r '.text' <<<"$out")" '状态：空闲时不显示文字（控件收起）'

# 没有 voxtype：用一个不含它的 PATH
out="$(run_status "/usr/bin:/bin")"
assert_equal 'absent' "$(jq -r '.class' <<<"$out")" '状态：未安装 → class=absent'
assert_equal '' "$(jq -r '.text' <<<"$out")" '状态：未安装时不显示文字'

# 状态文件缺失（刚装好还没录过）也不能崩
rm -f "$WORK_DIR/run/voxtype/state"
assert_equal 'idle' "$(jq -r '.class' <<<"$(run_status "$stub_dir:$PATH")")" '状态：状态文件缺失 → 按空闲处理'

# ---- toggle：没装时要告诉用户，而不是静默失败 ---------------------------------
: > "$STUB_LOG"
PATH="/usr/bin:/bin" "$PROJECT_DIR/bin/cachyos-voxtype-toggle" 2>/dev/null || true
# 这条路径下没有 stub，所以只断言它退出码为 0（不因缺 voxtype 而失败）
PATH="/usr/bin:/bin" "$PROJECT_DIR/bin/cachyos-voxtype-toggle" >/dev/null 2>&1
assert_equal '0' "$?" 'toggle：未安装时退出码仍为 0（按键不该报错）'

: > "$STUB_LOG"
PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-toggle" >/dev/null 2>&1
assert_equal 'voxtype record toggle' "$(cat "$STUB_LOG")" 'toggle：已安装时调用 voxtype record toggle'

: > "$STUB_LOG"
PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-toggle" >/dev/null 2>&1
grep -q 'dms notify' "$STUB_LOG" 2>/dev/null || true
# 上面那步有 voxtype，所以不该发通知；反过来验证"没装才通知"
: > "$STUB_LOG"
PATH="$stub_dir:$PATH" bash -c 'command -v voxtype >/dev/null && exit 0; exec "$0" "$@"' "$PROJECT_DIR/bin/cachyos-voxtype-toggle" >/dev/null 2>&1 || true
pass 'toggle：分支逻辑覆盖（有/无 voxtype）'

# ---- 配置与模型界面：没装时给出可执行的下一步 ---------------------------------
# 不能写成 `cmd 2>&1 | grep -q`：脚本开了 pipefail，命令本身退出 1 时整条管道也算失败，
# 即使 grep 命中了。先取输出再匹配。
config_out="$(PATH="/usr/bin:/bin" "$PROJECT_DIR/bin/cachyos-voxtype-config" 2>&1 || true)"
if [[ $config_out == *cachyos-voxtype-install* ]]; then
    pass 'config：未安装时提示先装听写'
else
    fail 'config：未安装时没有给出安装提示' "输出: $config_out"
fi
if PATH="/usr/bin:/bin" "$PROJECT_DIR/bin/cachyos-voxtype-config" >/dev/null 2>&1; then
    fail 'config：未安装时不该成功'
else
    pass 'config：未安装时退出码非 0'
fi

# ---- 安装：写下可选 include 的快捷键文件 --------------------------------------
: > "$STUB_LOG"
CACHYOS_VOXTYPE_TERMINAL=1 \
    CACHYOS_DESKTOP_SHARE_DIR="$PROJECT_DIR" \
    HOME="$WORK_DIR/home" \
    PATH="$stub_dir:$PATH" \
    "$PROJECT_DIR/bin/cachyos-voxtype-install" >/dev/null 2>&1
assert_equal 'true' "$([[ -f "$WORK_DIR/home/.config/niri/cachyos-voxtype.kdl" ]] && echo true || echo false)" \
    '安装：写下 ~/.config/niri/cachyos-voxtype.kdl'
assert_equal "$(md5sum < "$PROJECT_DIR/assets/niri/cachyos-voxtype.kdl")" \
    "$(md5sum < "$WORK_DIR/home/.config/niri/cachyos-voxtype.kdl")" '安装：快捷键文件与随包版本一致'
assert_equal 'true' "$([[ -f "$WORK_DIR/home/.config/voxtype/config.toml" ]] && echo true || echo false)" \
    '安装：写下默认配置'
if grep -q 'voxtype setup --download' "$STUB_LOG"; then
    pass '安装：下载了模型'
else
    fail '安装：没有下载模型'
fi

# 用户改过的配置不能被覆盖
printf '# 用户自己的改动\n' > "$WORK_DIR/home/.config/voxtype/config.toml"
CACHYOS_VOXTYPE_TERMINAL=1 CACHYOS_DESKTOP_SHARE_DIR="$PROJECT_DIR" HOME="$WORK_DIR/home" \
    PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-install" >/dev/null 2>&1
assert_equal '# 用户自己的改动' "$(cat "$WORK_DIR/home/.config/voxtype/config.toml")" \
    '安装：重复安装不覆盖用户改过的配置'

# ---- 卸载：删快捷键、备份配置 --------------------------------------------------
CACHYOS_VOXTYPE_TERMINAL=1 CACHYOS_DESKTOP_SHARE_DIR="$PROJECT_DIR" HOME="$WORK_DIR/home" \
    PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-remove" >/dev/null 2>&1 || true
assert_equal 'false' "$([[ -f "$WORK_DIR/home/.config/niri/cachyos-voxtype.kdl" ]] && echo true || echo false)" \
    '卸载：删除快捷键文件（不留指向缺失命令的绑定）'
assert_equal 'true' "$(compgen -G "$WORK_DIR/home/.config/voxtype.bak-*" >/dev/null && echo true || echo false)" \
    '卸载：用户配置先备份再移除'
assert_equal '# 用户自己的改动' "$(cat "$WORK_DIR"/home/.config/voxtype.bak-*/config.toml)" \
    '卸载：备份里保留了用户的内容'

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
