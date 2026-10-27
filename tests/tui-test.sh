#!/usr/bin/env bash

# 终端界面（assets/lib/tui.sh）的回归测试。
#
# 这个库最容易坏在两件事上：
#   1. **污染非终端输出**——一旦 ANSI 或 \r 漏进管道，verify.sh 与其它测试抓到的日志就废了；
#   2. **宽度算错**——中文/全角占两列、框线占一列，算错的话框的右边线会错位，
#      而"好看"恰恰是这个库唯一的产出。
# 所以下面两条线都要测：能力退化（TTY / NO_COLOR / TERM=dumb）与显示列宽。

set -Eeuo pipefail

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

readonly TUI_LIB="$PROJECT_DIR/assets/lib/tui.sh"
readonly PROBE="$WORK_DIR/probe.sh"

cat > "$PROBE" <<'PROBE_EOF'
set -Eeuo pipefail
source "$TUI_LIB"
tui_init
tui_banner "标题 CachyOS · Niri" "用户：skynit · 终端：kitty"
TUI_PHASE_TOTAL=2
tui_phase_start "检查环境"
tui_info "正在安装每日应用"
tui_step "下载 niri-sidebar v0.4.0"
tui_ok "面板插件已安装"
tui_warn "某个可选包不可用"
tui_skip "Hermes（未安装）"
tui_progress 3 8 "中文输入法"
tui_phase_done
tui_phase_start "收尾"
tui_phase_done "收尾完成"
tui_summary "安装完成" "重启后在 Ly 中选择 Niri 会话"
PROBE_EOF

# 给 PROBE 注入 TUI_LIB（heredoc 用了引号，避免生成期展开）
sed -i "s|\$TUI_LIB|$TUI_LIB|" "$PROBE"

run_probe() { COLUMNS=100 bash "$PROBE"; }

# ---- 1. 非终端：必须是纯文本 --------------------------------------------------
run_probe > "$WORK_DIR/plain.out" 2>&1
assert_equal '0' "$(grep -c $'\033' "$WORK_DIR/plain.out" || true)" '非终端输出不含 ANSI 转义'
assert_equal '0' "$(grep -c $'\r' "$WORK_DIR/plain.out" || true)" '非终端输出不含回车覆盖（\r）'
# 日志与 verify 依赖这些标记，界面重构不能把它们弄丢
for token in '[INFO]' '[WARN]' '[ERROR]'; do
    if [[ $token == '[ERROR]' ]]; then continue; fi
    grep -qF "$token" "$WORK_DIR/plain.out" || fail "非终端输出缺少 $token 标记"
done
pass '非终端输出保留 [INFO]/[WARN] 标记（日志兼容）'
grep -qF '== 阶段 1/2 · 检查环境' "$WORK_DIR/plain.out" \
    && pass '非终端输出用纯文本阶段标题' || fail '非终端阶段标题不是纯文本'
grep -qF '[3/8] 中文输入法' "$WORK_DIR/plain.out" \
    && pass '非终端进度用 [n/N] 文本形式' || fail '非终端进度格式不对'

# ---- 2. 真终端：要有颜色 ------------------------------------------------------
if command -v script >/dev/null 2>&1; then
    tty_raw="$WORK_DIR/tty.raw"
    env -u NO_COLOR TERM=xterm-256color COLUMNS=100 \
        script -qec "env -u NO_COLOR TERM=xterm-256color COLUMNS=100 bash '$PROBE'" /dev/null > "$tty_raw" 2>&1
    if (($(grep -c $'\033\[' "$tty_raw") > 0)); then
        pass '真终端下输出带 ANSI 颜色'
    else
        fail '真终端下没有颜色'
    fi

    tty_plain="$WORK_DIR/tty-plain.txt"
    sed $'s/\033\[[0-9;]*m//g' "$tty_raw" > "$tty_plain"

    # 框的每一行必须等宽：不等宽就是右边线错位，也正是"宽度算错"的表现。
    # 只量框线本身的行；pty 会把换行变成 \r\n，先去掉 \r 再算宽度。
    widths="$(tr -d '\r' < "$tty_plain" | grep -E '^[╭│╰]' | while IFS= read -r line; do
        printf '%s\n' "$(bash -c 'source "$1"; tui_visible_length "$2"' _ "$TUI_LIB" "$line")"
    done | sort -u | tr '\n' ' ')"
    # 真正的不变量是"所有框线等宽"（写死具体列数会随 COLUMNS 变化而假失败）。
    unique_widths="$(printf '%s' "$widths" | wc -w)"
    assert_equal '1' "$unique_widths" "框的边框与内容行等宽（实测宽度：$widths）"

    # 框线行不得有尾随空格：手写 printf 格式串时非常容易多出一个参数（真踩过）。
    if tr -d '\r' < "$tty_plain" | grep -E '^[╭│╰].*[[:space:]]$' >/dev/null; then
        fail '框线行存在尾随空格' "$(tr -d '\r' < "$tty_plain" | grep -E '^[╭│╰].*[[:space:]]$' | head -2)"
    else
        pass '框线行没有尾随空格'
    fi

    # NO_COLOR 与 TERM=dumb 是通用约定，必须尊重
    for mode in "NO_COLOR=1" "TERM=dumb"; do
        out="$WORK_DIR/plain-$RANDOM.raw"
        env TERM=xterm-256color COLUMNS=100 \
            script -qec "env $mode TERM=xterm-256color COLUMNS=100 bash '$PROBE'" /dev/null > "$out" 2>&1
        assert_equal '0' "$(grep -c $'\033\[' "$out" || true)" "$mode 时不输出颜色"
    done

    out="$WORK_DIR/tui-off.raw"
    env -u NO_COLOR TERM=xterm-256color COLUMNS=100 \
        script -qec "env -u NO_COLOR CACHYOS_TUI=plain TERM=xterm-256color COLUMNS=100 bash '$PROBE'" /dev/null > "$out" 2>&1
    assert_equal '0' "$(grep -c $'\033\[' "$out" || true)" 'CACHYOS_TUI=plain 时不输出颜色'
else
    printf 'skipped: 没有 script，跳过真终端用例\n'
fi

# ---- 3. 显示列宽：中文两列、框线一列（与 wcwidth 对齐）------------------------
width_case() {
    bash -c 'source "$1"; tui_visible_length "$2"' _ "$TUI_LIB" "$1"
}
assert_equal '4' "$(width_case '中文')" '中文按两列计'
assert_equal '3' "$(width_case 'abc')" 'ASCII 按一列计'
assert_equal '1' "$(width_case '─')" '框线按一列计（东亚宽度"模糊"）'
assert_equal '12' "$(width_case '用户：skynit')" '中英混排宽度正确'

# ---- 4. 截断不超宽 ------------------------------------------------------------
fitted="$(bash -c 'source "$1"; tui_fit "很长的中文标题需要被截断处理" 10' _ "$TUI_LIB")"
fitted_width="$(bash -c 'source "$1"; tui_visible_length "$2"' _ "$TUI_LIB" "$fitted")"
if ((fitted_width <= 10)); then
    pass "tui_fit 截断后不超过给定列宽（$fitted_width ≤ 10）"
else
    fail "tui_fit 截断后超宽（$fitted_width > 10）"
fi

# ---- 5. 退出语义 --------------------------------------------------------------
set +e
error_output="$(bash -c 'source "$1"; tui_init; tui_error "出错了"' _ "$TUI_LIB" 2>&1 >/dev/null)"
set -e
assert_equal '[ERROR] 出错了' "$error_output" 'tui_error 带 [ERROR] 标记'

# ---- 6. install.sh 集成 ------------------------------------------------------
fixture="$WORK_DIR/os-release"
printf 'ID=cachyos\nNAME="CachyOS Linux"\n' > "$fixture"
set +e
HOME="$WORK_DIR/home" CACHYOS_SETUP_OS_RELEASE="$fixture" \
    bash "$PROJECT_DIR/install.sh" --dry-run -y --skip-update --skip-hardware \
    > "$WORK_DIR/install.out" 2>&1
set -e
grep -qF 'CachyOS · Niri · DankMaterialShell' "$WORK_DIR/install.out" \
    && pass '安装器输出包含横幅' || fail '安装器输出缺少横幅'
grep -qF '阶段 1/6 · 检查环境' "$WORK_DIR/install.out" \
    && pass '安装器输出包含阶段标题' || fail '安装器输出缺少阶段标题'
assert_equal '0' "$(grep -c $'\033' "$WORK_DIR/install.out" || true)" '安装器在非终端下不输出 ANSI'
if grep -qF '[DRY-RUN]' "$WORK_DIR/install.out"; then
    pass 'dry-run 命令列表仍然带 [DRY-RUN] 标记'
else
    fail 'dry-run 标记丢失（会破坏既有测试与文档）'
fi
grep -qF '安装计划' "$WORK_DIR/install.out" \
    && pass '计划以框的形式输出' || fail '计划框丢失'
grep -qF '不改动' "$WORK_DIR/install.out" \
    && pass '计划里保留了「不改动」承诺' || fail '计划里「不改动」承诺丢失'

# ---- 7. 快捷键帮助：表头与中英文记录共享列宽 -------------------------------
mkdir -p "$WORK_DIR/keybind-bin"
cat > "$WORK_DIR/keybind-bin/kitty" <<'EOF'
#!/usr/bin/env bash
# 复用真实终端内命令，但不启动桌面窗口或让登录 shell 重置测试 PATH。
exec bash -c "${!#}"
EOF
cat > "$WORK_DIR/keybind-bin/dms" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"binds":{"Alt-Tab":[{"key":"Alt+Tab","action":"next-window"},{"key":"Alt+Shift+Tab","desc":"","action":"previous-window"}],"Execute":[{"key":"Mod+F1","desc":"切换输入法 Toggle input method","action":"spawn cachyos-input-toggle"},{"key":"Mod+XF86AudioRaiseVolume","desc":"录屏 Screen record","action":"spawn cachyos-record-menu"}]}}
JSON
EOF
cat > "$WORK_DIR/keybind-bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$KEYBIND_ARGS"
cat
EOF
chmod +x "$WORK_DIR/keybind-bin/"*
PATH="$WORK_DIR/keybind-bin:$PATH" KEYBIND_ARGS="$WORK_DIR/keybind-args" \
    bash "$PROJECT_DIR/bin/cachyos-keybind-help" > "$WORK_DIR/keybind-table"
python3 - "$WORK_DIR/keybind-table" <<'PY' || fail '快捷键帮助列未对齐'
import sys
import unicodedata

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
fields = [
    ("快捷键", "说明", "动作", "分组"),
    ("Alt+Tab", "切换到下一个最近窗口", "next-window", "Alt-Tab"),
    ("Alt+Shift+Tab", "切换到上一个最近窗口", "previous-window", "Alt-Tab"),
    ("Mod+F1", "切换输入法 Toggle input method", "spawn cachyos-input-toggle", "Execute"),
    ("Mod+XF86AudioRaiseVolume", "录屏 Screen record", "spawn cachyos-record-menu", "Execute"),
]

def width(text):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in text)

assert len(lines) == len(fields), lines
starts = []
for line, row in zip(lines, fields):
    assert "\t" not in line, repr(line)
    assert line.startswith(row[0]), line
    positions = []
    for column, field in enumerate(row[1:], start=1):
        if field:
            position = line.index(field)
            positions.append((column, width(line[:position])))
    starts.append(dict(positions))
for column in (1, 2, 3):
    assert len({row[column] for row in starts if column in row}) == 1, starts
PY
pass '快捷键帮助的表头、空说明、中英文及长快捷键列对齐，原始字段完整'
grep -qxF -- '--header-lines=1' "$WORK_DIR/keybind-args" \
    && pass '快捷键帮助表头不进入搜索条目' || fail '快捷键帮助缺少固定表头'
grep -qxF -- '--no-hscroll' "$WORK_DIR/keybind-args" \
    && pass '搜索长命令时保持列起点稳定' || fail '快捷键帮助仍允许整行自动横移'

# 同一动作可绑定多个键；说明跟随动作，已有的自定义说明优先。
cat > "$WORK_DIR/keybind-bin/dms" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"binds":{"Workspace":[{"key":"Mod+1","action":"focus-workspace 1"},{"key":"Mod+Ctrl+9","action":"move-column-to-workspace 9"}],"Window":[{"key":"Mod+Left","action":"focus-column-left"},{"key":"Mod+H","desc":"自定义切换说明","action":"focus-column-left"},{"key":"Mod+Comma","action":"consume-window-into-column"},{"key":"Mod+Period","action":"expel-window-from-column"}],"Execute":[{"key":"XF86AudioMute","action":"spawn dms ipc call audio mute"},{"key":"XF86MonBrightnessUp","action":"spawn dms ipc call brightness increment 5 \"\""},{"key":"Mod+F12","action":"spawn unknown-command"}]}}
JSON
EOF
PATH="$WORK_DIR/keybind-bin:$PATH" KEYBIND_ARGS="$WORK_DIR/keybind-args" \
    bash "$PROJECT_DIR/bin/cachyos-keybind-help" > "$WORK_DIR/keybind-descriptions"
for description in '切换到工作区 1' '将当前窗口列移到工作区 9' \
    '切换到左侧窗口列' '自定义切换说明' '将右侧窗口并入当前列' \
    '将列中最下方窗口拆为独立列' '切换系统静音' '提高屏幕亮度 5%' '未提供说明'; do
    grep -qF "$description" "$WORK_DIR/keybind-descriptions" \
        || fail "快捷键说明缺失：$description"
done
pass '空说明按真实动作补齐，保留自定义说明，未知动作明确标记'

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
