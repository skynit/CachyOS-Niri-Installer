# shellcheck shell=bash
#
# AI agent 表：本项目所有 agent 相关命令的唯一事实来源。
#
# 纯函数库：不做 I/O、不修改 shell 选项，可被 bin/ 下的 helper 与 tests/ 下的
# 单测同时 source。安装后位于
# /usr/local/share/cachyos-desktop/assets/lib/agent.sh。

# 所有 agent 共用一个窗口 class：窗口规则与主题因此能一次命中全部 agent 窗口，
# 不必为每个 agent 各写一条规则。由 bin/cachyos-agent 使用，故此处看似未引用。
# shellcheck disable=SC2034
CACHYOS_AGENT_WINDOW_CLASS="cachyos-agent"

# 支持的 agent id，每行一个。
cachyos_agent_supported() {
    printf '%s\n' codex claude opencode
}

# 人类可读名。未知 id 返回 1 且不输出。
cachyos_agent_name() {
    case "${1:-}" in
        codex) printf '%s\n' 'Codex' ;;
        claude) printf '%s\n' 'Claude Code' ;;
        opencode) printf '%s\n' 'OpenCode' ;;
        *) return 1 ;;
    esac
}

# 该 agent 读取技能的 $HOME 相对目录，每行一个。未知 id 返回 1。
#
# opencode 没有已知的技能目录，因此回落到通用位置：该目录不存在时链接什么也不会
# 发生，用户自己创建它则说明其 harness 会读——链接过去是无害的最佳努力。
cachyos_agent_skill_relpaths() {
    case "${1:-}" in
        codex) printf '%s\n' '.codex/skills' ;;
        claude) printf '%s\n' '.claude/skills' ;;
        opencode) printf '%s\n' '.agents/skills' ;;
        *) return 1 ;;
    esac
}

# 生成 argv，每行一个参数，便于调用方用 mapfile 收集、也便于单测逐字断言。
#
# 三个 agent 的无人值守旗标各不相同，prompt 的传法也不同：opencode 只认
# --prompt，claude 与 codex 用位置参数，并且必须先放 --，否则以 - 开头的 prompt
# 会被当成选项。旗标随上游版本变化时，只改这一处。
cachyos_agent_command() {
    local agent="${1:-}"
    local prompt="${2:-}"
    local -a command

    case "$agent" in
        codex)
            command=(codex --approve-for-me)
            ;;
        claude)
            command=(claude --permission-mode auto)
            ;;
        opencode)
            command=(opencode --auto)
            ;;
        *)
            return 1
            ;;
    esac

    if [[ -n $prompt ]]; then
        case "$agent" in
            opencode) command+=(--prompt "$prompt") ;;
            *) command+=(-- "$prompt") ;;
        esac
    fi

    printf '%s\n' "${command[@]}"
}

# "id<TAB>名称" —— 给 fzf 选择器和 --list 用。
cachyos_agent_list_display() {
    local agent
    local name

    while IFS= read -r agent; do
        name="$(cachyos_agent_name "$agent")"
        printf '%s\t%s\n' "$agent" "$name"
    done < <(cachyos_agent_supported)
}
