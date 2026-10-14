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

# 所有调用都隔离 HOME：默认动作配置在 $HOME/.config/cachyos-desktop/ask-actions.conf，
# 不隔离的话，跑测试的机器上一旦自定义过提示词，断言就会随环境飘。
# 所有调用都隔离 HOME：默认动作配置在 $HOME/.config/cachyos-desktop/ask-actions.conf，
# 不隔离的话，跑测试的机器上一旦自定义过提示词（或环境里设了 CACHYOS_ASK_ACTIONS），
# 断言就会随环境飘。ASK_TEST_HOME 是唯一开关，下面的自定义提示词用例会往里写配置。
unset CACHYOS_ASK_ACTIONS CACHYOS_ASK_SESSION 2>/dev/null || true
ask() {
    HOME="${ASK_TEST_HOME:-$HOME}" PATH="$stub_dir:$PATH" "$PROJECT_DIR/bin/cachyos-ask" "$@"
}
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

# 从这里开始所有调用都落到一个可控的假 HOME 上（先建空的，确保基线仍是 7 条内置动作）。
ask_home="$WORK_DIR/ask-home"
mkdir -p "$ask_home"
ASK_TEST_HOME="$ask_home"

assert_equal '7' "$(ask --list-actions | wc -l)" '动作列表：7 个动作'

# ---- 5b. 提示词可自定义（~/.config/cachyos-desktop/ask-actions.conf）------------
#
# 覆盖内置动作不能让它出现两次（这是实现里踩过的坑：用被配置填充过的表判断"是否内置"），
# 自己的配置写坏了也不能让整个命令用不了。
mkdir -p "$ask_home/.config/cachyos-desktop"
ask_conf="$ask_home/.config/cachyos-desktop/ask-actions.conf"

# 默认路径生效：不设 CACHYOS_ASK_ACTIONS，靠 HOME 指向的默认位置。
cat > "$ask_conf" <<'CONF'
# 覆盖内置动作的提示词
explain	用三句话讲清这段内容，再列出三个最容易踩的坑。
# 新增自定义动作
security	审查下面的代码有没有安全漏洞，按可利用性排序。
CONF

out="$(ask --print --action explain "一段文本")"
assert_contains "$out" "用三句话讲清" '自定义：内置动作的提示词被覆盖'
if [[ $out == *"先给结论再展开"* ]]; then
    fail '自定义：覆盖后不应再出现内置提示词'
else
    pass '自定义：覆盖后不再使用内置提示词'
fi

out="$(ask --print --action security "一段代码")"
assert_contains "$out" "有没有安全漏洞" '自定义：新增的动作可用'

assert_equal '8' "$(ask --list-actions | wc -l)" '自定义：列表 = 7 内置 + 1 新增'
assert_equal '1' "$(ask --list-actions | cut -f1 | grep -cx explain)" \
    '自定义：覆盖内置动作不会让它在列表里出现两次'
# 用 sed -n '1p' 而不是 head -1：head 提前关管道会让 cachyos-ask 的 printf 收到 SIGPIPE，
# 在 set -e 下把噪声变成失败。
assert_equal 'explain' "$(ask --list-actions | sed -n '1p' | cut -f1)" \
    '自定义：覆盖不改变内置动作的位置'

# 未覆盖的动作仍走内置模板。
out="$(ask --print --action fix "报错")"
assert_contains "$out" "下面这段输出出错了" '自定义：未覆盖的动作仍用内置提示词'

# 配置写坏：非法行要跳过并报行号，合法行照常生效（否则一处笔误就让整个命令不可用）。
cat > "$ask_conf" <<'CONF'
fix	改过的修复提示词。
这行没有分隔符
bad id!	非法 id
CONF
set +e
conf_stderr="$(ask --list-actions 2>&1 >/dev/null)"
conf_status=$?
set -e
assert_equal '0' "$conf_status" '配置损坏：命令仍正常退出'
assert_contains "$conf_stderr" '第 2 3 行' '配置损坏：报出被跳过的行号'
assert_contains "$(ask --print --action fix "报错")" "改过的修复提示词" \
    '配置损坏：合法行仍然生效'

# 配置文件不存在 = 没有自定义，绝不能因此失败。
assert_equal '7' "$(ASK_TEST_HOME="$WORK_DIR/no-such-home" ask --list-actions | wc -l)" \
    '配置缺失：回退到 7 个内置动作'

# 收尾：清掉故意写坏的配置，否则后面的用例会一直读到它（污染断言与输出）。
rm -f "$ask_conf"

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

# ---- 7.5 同一天复用会话（问一问的默认行为）-----------------------------------
# 造一个"今天"的 claude 会话，并把默认 agent 设成 claude：--show 里应出现 --resume。
ask_home="$WORK_DIR/ask-home"
mkdir -p "$ask_home/.claude/projects/-home-u-proj" "$ask_home/.config/cachyos-desktop"
printf 'claude\n' > "$ask_home/.config/cachyos-desktop/agent"
session_file="$ask_home/.claude/projects/-home-u-proj/sess-today.jsonl"
cat > "$session_file" <<'JSONL'
{"type":"summary","sessionId":"sess-today"}
{"type":"user","cwd":"/home/u/proj","sessionId":"sess-today","message":{"role":"user"}}
JSONL
touch "$session_file"

show_ask() {
    ask --show "$@"
}
today_cmd="$(show_ask --action explain "接着问一句")"
if [[ $today_cmd == *"--resume sess-today"* ]]; then
    pass '复用：当天有会话时带着 prompt 续接它'
else
    fail '复用：当天有会话却没续接' "$today_cmd"
fi

touch -d '3 days ago' "$session_file"
old_cmd="$(show_ask --action explain "新的一天")"
if [[ $old_cmd != *"--resume"* ]]; then
    pass '复用：最近会话是过去的日子时开新会话'
else
    fail '复用：跨天了还去续接' "$old_cmd"
fi

touch "$session_file"
new_cmd="$(show_ask --new --action explain "我要新会话")"
if [[ $new_cmd != *"--resume"* ]]; then
    pass '复用：--new 强制开新会话'
else
    fail '复用：--new 没有生效' "$new_cmd"
fi

env_cmd="$(CACHYOS_ASK_SESSION=new show_ask --action explain "环境变量控制")"
if [[ $env_cmd != *"--resume"* ]]; then
    pass '复用：CACHYOS_ASK_SESSION=new 也能强制新会话'
else
    fail '复用：环境变量没有生效' "$env_cmd"
fi

# dsh 当天有会话时走 headless --session-id（它没有交互式续接，但能采纳既有会话）
dsh_home="$WORK_DIR/dsh-home"
mkdir -p "$dsh_home/.dsh/storages/session_projcache/sessions" "$dsh_home/.config/cachyos-desktop"
printf 'dsh\n' > "$dsh_home/.config/cachyos-desktop/agent"
dsh_sid="session-deadbeef-0000-1111-2222-333344445555"
python3 - "$dsh_home/.dsh/storages/session_projcache/sessions/$dsh_sid.json" "$(date +%s)000" <<'EOF_INNER'
import json, sys
json.dump({"version": 1, "record": {
    "identity": {"cwd": "/home/u/dsh"},
    "rows": {"title": {"val": "dsh 会话"},
             "timeContext": {"val": {"lastMessageTime": int(sys.argv[2])}}},
}}, open(sys.argv[1], "w"))
EOF_INNER
dsh_cmd="$(PATH="$stub_dir:$PATH" HOME="$dsh_home" "$PROJECT_DIR/bin/cachyos-ask" --show --action explain "继续问")"
if [[ $dsh_cmd == *"--resume $dsh_sid"* ]]; then
    pass '复用：dsh 当天会话也会被续接（headless --session-id）'
else
    fail '复用：dsh 没走续接' "$dsh_cmd"
fi

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
