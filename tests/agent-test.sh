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

assert_equal 'codex claude opencode' "$(cachyos_agent_supported | paste -sd' ')" \
    '支持的 agent 清单固定为 codex/claude/opencode'

assert_equal 'Codex' "$(cachyos_agent_name codex)" 'codex 的显示名'
assert_equal 'Claude Code' "$(cachyos_agent_name claude)" 'claude 的显示名'
assert_equal 'OpenCode' "$(cachyos_agent_name opencode)" 'opencode 的显示名'

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

assert_equal '.codex/skills' "$(cachyos_agent_skill_relpaths codex)" 'codex 的技能目录'
assert_equal '.claude/skills' "$(cachyos_agent_skill_relpaths claude)" 'claude 的技能目录'
assert_equal '.agents/skills' "$(cachyos_agent_skill_relpaths opencode)" \
    'opencode 回落到通用技能目录'

assert_equal 'cachyos-agent' "$CACHYOS_AGENT_WINDOW_CLASS" \
    '所有 agent 共用一个窗口 class'

assert_equal "$(printf 'codex\tCodex\nclaude\tClaude Code\nopencode\tOpenCode')" \
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

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
