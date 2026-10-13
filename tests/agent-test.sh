#!/usr/bin/env bash

# agent 表的纯函数单测：不依赖已安装的 CachyOS 环境，也不需要 compositor。
#
# 注意：下面的 shellcheck source 路径相对仓库根目录，从仓库根运行 shellcheck 才能
# 跟随到 agent.sh 并获得跨文件分析。

set -euo pipefail

# 先赋值再 readonly：readonly 会掩盖命令替换的失败。
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR

# shellcheck source=assets/lib/agent.sh
source "$PROJECT_DIR/assets/lib/agent.sh"

PASS_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok - %s\n' "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    if (($# >= 2)); then
        printf '  %s\n' "$2" >&2
    fi
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    if [[ "$expected" == "$actual" ]]; then
        pass "$description"
    else
        fail "$description" "expected: [$expected] actual: [$actual]"
    fi
}

# 读 NUL 分隔的 argv，用 | 连接各元素。元素内部的换行原样保留，因此能看出
# "prompt 被拆成多个参数"这类回归。
argv_of() {
    local -a argv=()
    mapfile -d '' -t argv < <(cachyos_agent_command "$1" "${2-}")
    local IFS='|'
    printf '%s' "${argv[*]}"
}

# 参数个数。元素本身含 | 时上面的字符串连接会有歧义，因此个数单独断言。
argv_count() {
    local -a argv=()
    mapfile -d '' -t argv < <(cachyos_agent_command "$1" "${2-}")
    printf '%s' "${#argv[@]}"
}

assert_equal 'codex claude opencode dsh' "$(cachyos_agent_supported | paste -sd' ')" \
    '支持的 agent 清单固定为 codex/claude/opencode/dsh'

assert_equal 'Codex' "$(cachyos_agent_name codex)" 'codex 的显示名'
assert_equal 'Claude Code' "$(cachyos_agent_name claude)" 'claude 的显示名'
assert_equal 'OpenCode' "$(cachyos_agent_name opencode)" 'opencode 的显示名'
assert_equal 'DSH' "$(cachyos_agent_name dsh)" 'dsh 的显示名'
assert_equal 'dsh' "$(cachyos_agent_binary dsh)" 'dsh 的二进制名'
assert_equal '.dsh/skills' "$(cachyos_agent_skill_relpaths dsh)" 'dsh 的技能目录'

# dsh 是按 profile 启动的 harness：无 prompt 进交互 profile，有 prompt 走 headless 一次性模式。
# 它没有"无人值守"旗标（审批策略在 profile 里），所以这里不该凭空加旗标。
assert_equal 'dsh|web' "$(argv_of dsh)" 'dsh 无 prompt 时进默认交互 profile'
assert_equal 'dsh|headless|--|审查这个改动' "$(argv_of dsh '审查这个改动')" \
    'dsh 带 prompt 时走 headless 一次性模式'
assert_equal 'dsh|tui' "$(CACHYOS_DSH_PROFILE=tui argv_of dsh)" \
    'dsh 的交互 profile 可用 CACHYOS_DSH_PROFILE 指定'
assert_equal 'true' "$(cachyos_agent_hold_window dsh)" 'dsh 需要跑完留住窗口（否则读不到答案）'
assert_equal 'false' "$(cachyos_agent_hold_window claude)" '交互式 agent 不需要留住窗口'

assert_equal 'opencode|--auto' "$(argv_of opencode)" \
    'opencode 无 prompt 时使用 --auto'
assert_equal 'opencode|--auto|--prompt|审查这个改动' "$(argv_of opencode '审查这个改动')" \
    'opencode 的 prompt 走 --prompt'

assert_equal 'claude|--permission-mode|auto' "$(argv_of claude)" \
    'claude 无 prompt 时使用 --permission-mode auto'
assert_equal 'claude|--permission-mode|auto|--|-p' "$(argv_of claude '-p')" \
    'claude 在 prompt 前插入 --，避免以横线开头的 prompt 被当成选项'

assert_equal 'codex|--approve-for-me' "$(argv_of codex)" \
    'codex 无 prompt 时使用 --approve-for-me'
assert_equal 'codex|--approve-for-me|--|--help' "$(argv_of codex '--help')" \
    'codex 在 prompt 前插入 --'

# 回归：argv 曾经按换行分隔，含换行的 prompt 会被拆成多个参数，agent 因此收到
# 多余的位置参数而报错。崩溃诊断的 prompt 就是多行 heredoc，所以这条必须有。
# 注意 argv 的第一个元素是程序名本身，所以个数比"旗标+prompt"多一个。
multi_line_prompt="$(printf '第一行\n\n第三行')"
assert_equal '4' "$(argv_count codex "$multi_line_prompt")" \
    'codex：prompt 含换行时参数个数不变（不会被拆开）'
assert_equal "$(printf 'codex|--approve-for-me|--|第一行\n\n第三行')" \
    "$(argv_of codex "$multi_line_prompt")" 'codex：prompt 含换行时仍是单个参数'
assert_equal '4' "$(argv_count opencode "$multi_line_prompt")" \
    'opencode：prompt 含换行时参数个数不变'
assert_equal '5' "$(argv_count claude "$multi_line_prompt")" \
    'claude：prompt 含换行时参数个数不变'
assert_equal '4' "$(argv_count codex 'a|b')" \
    'prompt 含竖线时参数个数不变（连接表示法有歧义，故按个数断言）'
assert_equal '4' "$(argv_count codex '含 制表	符')" \
    'prompt 含制表符时参数个数不变'

# --------------------------------------------------------------- 端到端（launcher）
#
# 只测 lib 是不够的：多行 prompt 被拆参那个缺陷正是在"全部通过"的情况下漏过去的，
# 因为收集端（bin/cachyos-agent 的 mapfile）从来没有被测过。

RUN_DIR="$(mktemp -d)"
trap 'rm -rf -- "$RUN_DIR"' EXIT
mkdir -p "$RUN_DIR/bin" "$RUN_DIR/home"

cat > "$RUN_DIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$AGENT_TEST_ARGV"
STUB

# 模拟 kitty：带 -c 时在"新窗口"里真的执行那段命令——真实 kitty 正是这么做的，
# 区别只是输出留在窗口的 pty 上、不会回传给调用者（这曾经让选择器永远拿到空值）。
cat > "$RUN_DIR/bin/kitty" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ $arg == "-c" ]]; then
        exec sh -c "${@: -1}"
    fi
done
if [[ -n ${AGENT_TEST_KITTY_ARGV:-} ]]; then
    printf '%s\0' "$@" > "$AGENT_TEST_KITTY_ARGV"
fi
STUB
chmod +x "$RUN_DIR/bin/codex" "$RUN_DIR/bin/kitty"

# 用仓库版 launcher 跑一次，回显 stub harness 收到的 argv（用 | 连接）。
# 注意 harness 的 argv 里不含程序名本身。
launcher_argv() {
    rm -f "$RUN_DIR/argv.bin"
    AGENT_TEST_ARGV="$RUN_DIR/argv.bin" \
        HOME="$RUN_DIR/home" \
        CACHYOS_DESKTOP_SHARE_DIR="$RUN_DIR/no-share" \
        PATH="$RUN_DIR/bin:$PROJECT_DIR/bin:$PATH" \
        "$PROJECT_DIR/bin/cachyos-agent" --inline "$@" >/dev/null 2>&1 || true

    local -a argv=()
    mapfile -d '' -t argv < "$RUN_DIR/argv.bin" 2>/dev/null
    local IFS='|'
    printf '%s' "${argv[*]}"
}

assert_equal '--approve-for-me|--|hello world' "$(launcher_argv --prompt 'hello world' codex)" \
    'launcher 往返：普通 prompt 逐字到达 harness'
assert_equal "$(printf -- '--approve-for-me|--|第一行\n\n第三行')" \
    "$(launcher_argv --prompt "$(printf '第一行\n\n第三行')" codex)" \
    'launcher 往返：多行 prompt 仍是单个参数（曾因按行收集被拆开）'

# 选择器：kitty 分支必须把结果回传（曾用 $( ) 捕获 kitty 的 stdout，永远为空）。
# PATH 里仓库 bin/ 优先，内层命令才会用同一个仓库版命令与库，测试才是自洽的。
rm -f "$RUN_DIR/home/.config/cachyos-desktop/agent"
FZF_DEFAULT_OPTS='--filter=codex' \
    HOME="$RUN_DIR/home" \
    CACHYOS_DESKTOP_SHARE_DIR="$RUN_DIR/no-share" \
    PATH="$RUN_DIR/bin:$PROJECT_DIR/bin:$PATH" \
    "$PROJECT_DIR/bin/cachyos-agent" --pick >/dev/null 2>&1 || true
assert_equal 'codex' "$(cat "$RUN_DIR/home/.config/cachyos-desktop/agent" 2>/dev/null)" \
    '选择器（kitty 分支）：选中的 agent 被写回默认值'

assert_equal '.codex/skills' "$(cachyos_agent_skill_relpaths codex)" 'codex 的技能目录'
assert_equal '.claude/skills' "$(cachyos_agent_skill_relpaths claude)" 'claude 的技能目录'
assert_equal '.agents/skills' "$(cachyos_agent_skill_relpaths opencode)" \
    'opencode 回落到通用技能目录'

assert_equal 'cachyos-agent' "$CACHYOS_AGENT_WINDOW_CLASS" \
    '所有 agent 共用一个窗口 class'

assert_equal "$(printf 'codex\tCodex\nclaude\tClaude Code\nopencode\tOpenCode\ndsh\tDSH')" \
    "$(cachyos_agent_list_display)" '显示清单的 id 与名称对齐'

# 未知 agent 必须既不输出 argv、也不静默成功。
unknown_output="$(cachyos_agent_command bogus || true)"
assert_equal '' "$unknown_output" '未知 agent 不输出 argv'
if cachyos_agent_command bogus >/dev/null; then
    fail '未知 agent 应返回非 0'
fi
pass '未知 agent 返回非 0'

if cachyos_agent_name bogus >/dev/null; then
    fail '未知 agent 的名称查询应返回非 0'
fi
pass '未知 agent 的名称查询返回非 0'

# ---- agent 表：id → 二进制名（安装器用它判断哪些 agent 可用）------------------
for pair in "codex codex" "claude claude" "opencode opencode"; do
    set -- $pair
    assert_equal "$2" "$(cachyos_agent_binary "$1")" "agent 表：$1 的二进制名是 $2"
done
if cachyos_agent_binary bogus >/dev/null 2>&1; then
    fail '未知 agent 不该返回成功'
else
    pass '未知 agent 返回非 0'
fi
# 表里每个 agent 都必须能取到二进制名，否则安装器会静默认为"没有可用 agent"
missing_binary=''
while read -r agent; do
    cachyos_agent_binary "$agent" >/dev/null 2>&1 || missing_binary="$missing_binary $agent"
done < <(cachyos_agent_supported)
assert_equal '' "$missing_binary" 'agent 表里每个 id 都有对应的二进制名'


printf '\n%s 项检查通过。\n' "$PASS_COUNT"
