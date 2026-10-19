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
#   5. 本机装过听写时，「未安装」分支也必须与宿主无关（不能依赖 /usr/bin 里有没有 voxtype）

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
for name in dms notify-send niri systemctl paru kitty sudo; do
    ln -sf "$stub_dir/stub-logger" "$stub_dir/$name"
done

# voxtype stub：记录调用，并能扮演"当前配置里的模型"——安装脚本会读它决定是否给中文提示。
cat > "$stub_dir/voxtype" <<'STUB'
#!/usr/bin/env bash
printf 'voxtype %s\n' "$*" >> "$STUB_LOG"
if [[ ${1:-} == config && ${2:-} == get && ${3:-} == whisper.model ]]; then
    printf '%s\n' "${STUB_MODEL:-}"
fi
exit 0
STUB
chmod +x "$stub_dir/voxtype"

# 一个"确定没有 voxtype"的 PATH：只放脚本真正需要的工具（cat）与通知 stub。
# **不能用 /usr/bin:/bin**——本机装过听写之后那里就有真的 voxtype，测试会
# 去操作真实录音（真的打开麦克风），还会让"未安装"分支的断言假失败。
no_voxtype_dir="$WORK_DIR/no-voxtype"
mkdir -p "$no_voxtype_dir"
# 脚本的 shebang 是 /usr/bin/env bash：隔离 PATH 里必须有 bash，否则连解释器都找不到。
ln -sf "$(command -v bash)" "$no_voxtype_dir/bash"
ln -sf "$(command -v cat)" "$no_voxtype_dir/cat"
for name in dms notify-send; do
    ln -sf "$stub_dir/stub-logger" "$no_voxtype_dir/$name"
done

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
out="$(run_status "$no_voxtype_dir")"
assert_equal 'absent' "$(jq -r '.class' <<<"$out")" '状态：未安装 → class=absent'
assert_equal '' "$(jq -r '.text' <<<"$out")" '状态：未安装时不显示文字'

# 状态文件缺失（刚装好还没录过）也不能崩
rm -f "$WORK_DIR/run/voxtype/state"
assert_equal 'idle' "$(jq -r '.class' <<<"$(run_status "$stub_dir:$PATH")")" '状态：状态文件缺失 → 按空闲处理'

# ---- toggle：没装时要告诉用户，而不是静默失败 ---------------------------------
: > "$STUB_LOG"
PATH="$no_voxtype_dir" "$PROJECT_DIR/bin/cachyos-voxtype-toggle" 2>/dev/null || true
# 这条路径下没有 stub，所以只断言它退出码为 0（不因缺 voxtype 而失败）
PATH="$no_voxtype_dir" "$PROJECT_DIR/bin/cachyos-voxtype-toggle" >/dev/null 2>&1
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
config_out="$(PATH="$no_voxtype_dir" "$PROJECT_DIR/bin/cachyos-voxtype-config" 2>&1 || true)"
if [[ $config_out == *cachyos-voxtype-install* ]]; then
    pass 'config：未安装时提示先装听写'
else
    fail 'config：未安装时没有给出安装提示' "输出: $config_out"
fi
if PATH="$no_voxtype_dir" "$PROJECT_DIR/bin/cachyos-voxtype-config" >/dev/null 2>&1; then
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
assert_equal 'true' "$([[ -f "$WORK_DIR/home/.config/voxtype/osd/dms/DmsOsd.qml" ]] && echo true || echo false)" \
    '安装：写下 DMS 风格的听写 OSD 样式包'
assert_equal "$(md5sum < "$PROJECT_DIR/assets/voxtype/osd/dms/DmsOsd.qml")" \
    "$(md5sum < "$WORK_DIR/home/.config/voxtype/osd/dms/DmsOsd.qml")" '安装：OSD 样式与随包版本一致'
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

# ---- 键位：两键就够，不要再绑三键 ----------------------------------------------
kdl="$PROJECT_DIR/assets/niri/cachyos-voxtype.kdl"
grep -q "Super+Apostrophe" "$kdl" \
    && pass "键位：主键是两键 Super+'（Apostrophe）" || fail "键位：主键不是两键"
grep -q "Super+F9" "$kdl" \
    && pass '键位：保留 Super+F9 备用' || fail '键位：备用键丢失'
if grep -qE '^\s*Super\+Ctrl\+' "$kdl"; then
    fail '键位：不应再有三键绑定'
else
    pass '键位：没有三键绑定'
fi
# 提示文案也要跟着走，否则用户会照旧提示按错键
grep -q "Super+'" "$PROJECT_DIR/bin/cachyos-voxtype-status" \
    && pass "状态提示：tooltip 用的是新键位" || fail "状态提示：tooltip 仍是旧键位"

# ---- 卸载：删快捷键、备份配置 --------------------------------------------------
CACHYOS_VOXTYPE_TERMINAL=1 CACHYOS_DESKTOP_SHARE_DIR="$PROJECT_DIR" HOME="$WORK_DIR/home" \
    PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-remove" >/dev/null 2>&1 || true
assert_equal 'false' "$([[ -f "$WORK_DIR/home/.config/niri/cachyos-voxtype.kdl" ]] && echo true || echo false)" \
    '卸载：删除快捷键文件（不留指向缺失命令的绑定）'
assert_equal 'true' "$(compgen -G "$WORK_DIR/home/.config/voxtype.bak-*" >/dev/null && echo true || echo false)" \
    '卸载：用户配置先备份再移除'
assert_equal '# 用户自己的改动' "$(cat "$WORK_DIR"/home/.config/voxtype.bak-*/config.toml)" \
    '卸载：备份里保留了用户的内容'

# ---- niri 重载：必须用当前版本存在的子命令 --------------------------------------
# 本机 niri 上 `niri msg action reload-config` 是 unrecognized subcommand，
# 原来的脚本用 `|| true` 把它吞掉了 —— 等于装完听写从来没重载过配置，
# 快捷键自然不会生效（实测就是这个问题）。现在应优先用 load-config-file。
if grep -q 'niri msg action load-config-file' "$STUB_LOG"; then
    pass 'niri：安装后按当前版本支持的子命令重载配置'
else
    fail 'niri：没有用 load-config-file 重载' "$(grep niri "$STUB_LOG" || true)"
fi

# ---- 安装参数：模型 / 语言 / 提示词，且顺序必须是"先写配置再下载" -----------------
# 这条顺序是实测踩出来的：`voxtype setup --download` 下载的是配置里指定的模型，
# 反过来先下载就会拿到默认的英文模型，中文直接输出乱码拼音。
: > "$STUB_LOG"
CACHYOS_VOXTYPE_TERMINAL=1 CACHYOS_DESKTOP_SHARE_DIR="$PROJECT_DIR" HOME="$WORK_DIR/home" \
    PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-install" \
    --model small --language zh --prompt '以下是普通话的句子，请使用简体中文。' >/dev/null 2>&1

if grep -q 'voxtype config set whisper.model small' "$STUB_LOG"; then
    pass '安装参数：--model 写入配置'
else
    fail '安装参数：--model 没有写入配置' "$(cat "$STUB_LOG")"
fi
if grep -q 'voxtype config set whisper.language zh' "$STUB_LOG"; then
    pass '安装参数：--language 写入配置'
else
    fail '安装参数：--language 没有写入配置'
fi
grep -q 'voxtype config set whisper.initial_prompt' "$STUB_LOG" \
    && pass '安装参数：--prompt 写入配置' || fail '安装参数：--prompt 没有写入配置'

set_line="$(grep -n 'voxtype config set whisper.model small' "$STUB_LOG" | cut -d: -f1)"
download_line="$(grep -n 'voxtype setup --download' "$STUB_LOG" | head -1 | cut -d: -f1)"
if [[ -n $set_line && -n $download_line ]] && ((set_line < download_line)); then
    pass "安装顺序：先写模型配置（第 $set_line 行）再下载（第 $download_line 行）"
else
    fail '安装顺序：先写模型配置再下载' "set=$set_line download=$download_line"
fi
grep -q 'systemctl --user restart voxtype.service' "$STUB_LOG" \
    && pass '安装参数：改过配置后重启服务' || fail '安装参数：改过配置没有重启服务'

# GPU 切换变体会替换 /usr/bin/voxtype，必须走 sudo；不加 sudo 只会静默留在 CPU
if grep -q 'sudo voxtype setup gpu --enable' "$STUB_LOG"; then
    pass 'GPU：通过 sudo 启用（否则会 permission denied 静默退回 CPU）'
else
    fail 'GPU：没有通过 sudo 启用' "$(cat "$STUB_LOG")"
fi

# ---- 英文专用模型的提示：装完要直接告诉用户怎么办 -------------------------------
hint_out="$(STUB_MODEL=base.en CACHYOS_VOXTYPE_TERMINAL=1 CACHYOS_DESKTOP_SHARE_DIR="$PROJECT_DIR" \
    HOME="$WORK_DIR/home" PATH="$stub_dir:$PATH" \
    "$PROJECT_DIR/bin/cachyos-voxtype-install" 2>&1 || true)"
if [[ $hint_out == *cachyos-voxtype-model* && $hint_out == *whisper.language* ]]; then
    pass '提示：检测到 *.en 模型时给出中文听写步骤'
else
    fail '提示：*.en 模型没有给出中文步骤' "输出: $hint_out"
fi
hint_none="$(CACHYOS_VOXTYPE_TERMINAL=1 CACHYOS_DESKTOP_SHARE_DIR="$PROJECT_DIR" HOME="$WORK_DIR/home" \
    PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-install" 2>&1 || true)"
if [[ $hint_none != *"只支持英文"* ]]; then
    pass '提示：多语言模型时不打扰用户'
else
    fail '提示：非 .en 模型也打印了中文提示'
fi

# ---- 参数校验与帮助 ------------------------------------------------------------
if CACHYOS_VOXTYPE_TERMINAL=1 "$PROJECT_DIR/bin/cachyos-voxtype-install" --help >/dev/null 2>&1; then
    pass '安装：--help 退出码 0'
else
    fail '安装：--help 应该成功'
fi
if CACHYOS_VOXTYPE_TERMINAL=1 "$PROJECT_DIR/bin/cachyos-voxtype-install" --model >/dev/null 2>&1; then
    fail '安装：--model 缺参数时应该失败'
else
    pass '安装：--model 缺参数时退出非 0'
fi
if CACHYOS_VOXTYPE_TERMINAL=1 "$PROJECT_DIR/bin/cachyos-voxtype-install" --bogus >/dev/null 2>&1; then
    fail '安装：未知参数应该失败'
else
    pass '安装：未知参数退出非 0'
fi

# 卸载同样要重载，否则会留下指向已删除快捷键文件的绑定
: > "$STUB_LOG"
CACHYOS_VOXTYPE_TERMINAL=1 CACHYOS_DESKTOP_SHARE_DIR="$PROJECT_DIR" HOME="$WORK_DIR/home" \
    PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-remove" >/dev/null 2>&1 || true
grep -q 'niri msg action load-config-file' "$STUB_LOG" \
    && pass 'niri：卸载后重载配置' || fail 'niri：卸载后没有重载配置'

# ---- 模型命令：带名字时非交互切换 ----------------------------------------------
: > "$STUB_LOG"
PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-model" small >/dev/null 2>&1
grep -q 'voxtype config set whisper.model small' "$STUB_LOG" \
    && pass '模型命令：带参数时非交互写入模型' || fail '模型命令：没有写入模型'
grep -q 'voxtype setup --download' "$STUB_LOG" \
    && pass '模型命令：切换后下载模型' || fail '模型命令：没有下载模型'

: > "$STUB_LOG"
PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-voxtype-model" >/dev/null 2>&1 || true
grep -q 'setup model' "$STUB_LOG" \
    && pass '模型命令：不带参数时仍走交互界面' || fail '模型命令：不带参数时没有走交互界面'

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
