#!/usr/bin/env bash

# AI 工作流的回归测试：cachyos-ask（收集上下文 → 组装 prompt）与
# cachyos-agent-console（跑完提醒、失败保留窗口）。
#
# 全程用 stub：不发真实通知、不打开真实窗口、不启动真实 agent。
# 盯的是这几件容易静默出错的事：
#   1. 文本来源的优先级（参数 > 主选区 > 剪贴板），以及 commit/review 的 git 回退
#   2. prompt 必须真的带上文本与来源说明，不能只剩模板
#   3. 超长文本要截断并注明，否则会把 agent 的上下文一次性冲爆
#   4. 通知策略：auto（长任务/失败才提醒）、always、off，以及退出码必须原样传回
#   5. 启动器必须走 console 包装，但包装器缺失时不能因此起不来

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
assert_contains() {
    if [[ "$1" == *"$2"* ]]; then
        pass "$3"
    else
        fail "$3" "应在其中找到 [$2]，实际：[$1]"
    fi
}

stub_dir="$WORK_DIR/bin"
mkdir -p "$stub_dir"
readonly STUB_LOG="$WORK_DIR/stub.log"
: > "$STUB_LOG"
export STUB_LOG

cat > "$stub_dir/stub-logger" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$stub_dir/stub-logger"
for name in dms notify-send kitty fzf; do
    ln -sf "$stub_dir/stub-logger" "$stub_dir/$name"
done

# wl-paste stub：主选区与剪贴板内容分别可控（默认都为空）
cat > "$stub_dir/wl-paste" <<'STUB'
#!/usr/bin/env bash
mode="clipboard"
for arg in "$@"; do
    [[ $arg == "--primary" ]] && mode="primary"
done
printf 'wl-paste %s\n' "$*" >> "$STUB_LOG"
if [[ $mode == primary ]]; then
    printf '%s' "${STUB_PRIMARY:-}"
else
    printf '%s' "${STUB_CLIPBOARD:-}"
fi
STUB
chmod +x "$stub_dir/wl-paste"

ask() { PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-ask" "$@"; }
ask_print() { STUB_PRIMARY="${STUB_PRIMARY:-}" STUB_CLIPBOARD="${STUB_CLIPBOARD:-}" ask --print "$@"; }

# ---- 1. 动作模板与文本 ---------------------------------------------------------
out="$(ask_print --action explain "这是一段待解释的文字")"
assert_contains "$out" "解释下面这段内容" 'explain：使用了解释模板'
assert_contains "$out" "这是一段待解释的文字" 'explain：文本进了 prompt'
assert_contains "$out" "命令行给出的文本" 'explain：注明了文本来源'

out="$(ask_print --action shell "列出当前目录最大的十个文件")"
assert_contains "$out" "bash 命令" 'shell：使用了转命令模板'

out="$(ask_print --action translate "hello world")"
assert_contains "$out" "翻译成自然的中文" 'translate：使用了翻译模板'

# ---- 2. 文本来源优先级 ---------------------------------------------------------
out="$(STUB_CLIPBOARD='剪贴板里的内容' ask --print --action summarize)"
assert_contains "$out" "剪贴板里的内容" '来源：选区为空时用剪贴板'
assert_contains "$out" "剪贴板内容" '来源：注明来自剪贴板'

out="$(STUB_PRIMARY='选中的内容' STUB_CLIPBOARD='剪贴板里的内容' ask --print --action summarize)"
assert_contains "$out" "选中的内容" '来源：主选区优先于剪贴板'

out="$(STUB_PRIMARY='选中的内容' ask --print --action summarize "参数里的内容")"
assert_contains "$out" "参数里的内容" '来源：命令行参数优先于选区'
if [[ $out == *"选中的内容"* ]]; then
    fail '来源：参数存在时不应再读选区'
else
    pass '来源：参数存在时不读选区'
fi

# ---- 3. 超长文本截断 ----------------------------------------------------------
long_text="$(printf 'x%.0s' {1..200})"
out="$(CACHYOS_ASK_MAX_CHARS=50 ask --print --action summarize "$long_text")"
assert_contains "$out" "已截断到前 50 个字符" '超长文本：会截断并注明'

# ---- 4. 没有文本时的报错 ------------------------------------------------------
set +e
empty_out="$(ask --print --action explain 2>&1)"
empty_status=$?
set -e
if ((empty_status != 0)); then
    pass "空输入：退出码非 0（$empty_status）"
else
    fail '空输入：应当失败'
fi
assert_contains "$empty_out" "没有拿到任何文本" '空输入：给出明确提示'

# ---- 5. 动作校验 --------------------------------------------------------------
set +e
ask --print --action 不存在的动作 "文本" >/dev/null 2>&1
bad_action_status=$?
ask --bogus >/dev/null 2>&1
bad_option_status=$?
set -e
assert_equal '2' "$bad_action_status" '未知动作：退出码 2'
assert_equal '2' "$bad_option_status" '未知选项：退出码 2'
assert_equal '7' "$(ask --list-actions | wc -l)" '动作列表：7 个动作'

# ---- 6. commit/review 的 git 回退 --------------------------------------------
repo="$WORK_DIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'hello\n' > "$repo/a.txt"
git -C "$repo" add a.txt
out="$(cd "$repo" && STUB_CLIPBOARD='' PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-ask" --print --action commit)"
assert_contains "$out" "git diff --cached" 'commit：无文本时回退到暂存改动'
assert_contains "$out" "+hello" 'commit：prompt 里带着真实 diff'

# 非 git 目录下不该硬塞 git 信息
out="$(cd "$WORK_DIR" && STUB_CLIPBOARD='剪贴板兜底' PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-ask" --print --action commit)"
assert_contains "$out" "剪贴板兜底" 'commit：非仓库时回退到剪贴板'

# ---- 7. console 包装：通知策略与退出码 ---------------------------------------
console() { PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-agent-console" "$@"; }

: > "$STUB_LOG"
CACHYOS_AGENT_NOTIFY_MODE=always console claude sh -c 'exit 0' </dev/null >/dev/null 2>&1
assert_contains "$(cat "$STUB_LOG")" "Claude Code 已完成" 'console：always 模式下成功也通知'

: > "$STUB_LOG"
CACHYOS_AGENT_NOTIFY_MODE=off console claude sh -c 'exit 0' </dev/null >/dev/null 2>&1
if grep -q 'dms notify' "$STUB_LOG"; then
    fail 'console：off 模式不应通知'
else
    pass 'console：off 模式不通知'
fi

: > "$STUB_LOG"
CACHYOS_AGENT_NOTIFY_MODE=auto console claude sh -c 'exit 0' </dev/null >/dev/null 2>&1
if grep -q 'dms notify' "$STUB_LOG"; then
    fail 'console：auto 模式下"秒完成的成功任务"不应打扰'
else
    pass 'console：auto 模式不打扰短任务'
fi

: > "$STUB_LOG"
# 注意：赋值的退出码会继承命令替换，而这里预期就是非 0——不吞掉它 set -e 会直接结束测试。
hold_out="$(CACHYOS_AGENT_NOTIFY_MODE=auto console codex sh -c 'exit 3' </dev/null 2>&1)" || true
assert_contains "$(cat "$STUB_LOG")" "Codex 失败：退出码 3" 'console：失败必通知并带退出码'
assert_contains "$hold_out" "窗口保留供查看" 'console：失败时保留窗口'

set +e
CACHYOS_AGENT_NOTIFY_MODE=off console dsh sh -c 'exit 7' </dev/null >/dev/null 2>&1
console_status=$?
set -e
assert_equal '7' "$console_status" 'console：退出码原样传回（否则窗口/脚本都判断错）'

: > "$STUB_LOG"
CACHYOS_AGENT_NOTIFY_MODE=auto CACHYOS_AGENT_NOTIFY_MIN_SECONDS=0 console opencode sh -c 'exit 0' </dev/null >/dev/null 2>&1
assert_contains "$(cat "$STUB_LOG")" "OpenCode 已完成" 'console：阈值可调（0 秒即通知）'

# ---- 8. 启动器走 console 包装 -------------------------------------------------
# 用受控的 HOME 指定默认 agent：直接读宿主的默认值会让断言随机器而变。
launcher_home="$WORK_DIR/home"
mkdir -p "$launcher_home/.config/cachyos-desktop"
printf 'claude\n' > "$launcher_home/.config/cachyos-desktop/agent"
: > "$STUB_LOG"
PATH="$stub_dir:$PATH" HOME="$launcher_home" "$PROJECT_DIR/bin/cachyos-agent" --prompt "测试" >/dev/null 2>&1 || true
kitty_line="$(grep '^kitty ' "$STUB_LOG" || true)"
assert_contains "$kitty_line" "cachyos-agent-console" '启动器：新窗口模式套了 console 包装'
assert_contains "$kitty_line" "cachyos-agent-console claude" '启动器：把 agent id 传给了包装器'
assert_contains "$kitty_line" "测试" '启动器：prompt 原样传下去'

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
