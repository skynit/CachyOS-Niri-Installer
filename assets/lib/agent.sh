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

# cachyos_agent_command 的输出协议版本：1 = 按行分隔，2 = NUL 分隔。
# bin/cachyos-agent 会校验它：库和命令一旦错配（例如只更新了其中一个），
# 按行分隔的库配上按 NUL 收集的调用方会把整段 argv 当成一个命令名，
# 报出 "exec: ...: 未找到" 这种难以定位的错误。
# shellcheck disable=SC2034
CACHYOS_AGENT_LIB_PROTOCOL=2

# 支持的 agent id，每行一个。
cachyos_agent_supported() {
    printf '%s\n' codex claude opencode dsh
}

# 人类可读名。未知 id 返回 1 且不输出。
cachyos_agent_name() {
    case "${1:-}" in
        codex) printf '%s\n' 'Codex' ;;
        claude) printf '%s\n' 'Claude Code' ;;
        opencode) printf '%s\n' 'OpenCode' ;;
        dsh) printf '%s\n' 'DSH' ;;
        *) return 1 ;;
    esac
}

# 该 agent 读取技能的 $HOME 相对目录，每行一个。未知 id 返回 1。
#
# opencode 没有已知的技能目录，因此回落到通用位置：该目录不存在时链接什么也不会
# 发生，用户自己创建它则说明其 harness 会读——链接过去是无害的最佳努力。
# 该 agent 的可执行文件名（三个 CLI 与 id 同名）。单独成函数是为了让"怎么判断某 agent
# 是否可用"只有一处定义——安装器、验收、诊断都从这里取。
cachyos_agent_binary() {
    case "${1:-}" in
        codex) printf '%s\n' codex ;;
        claude) printf '%s\n' claude ;;
        opencode) printf '%s\n' opencode ;;
        dsh) printf '%s\n' dsh ;;
        *) return 1 ;;
    esac
}

cachyos_agent_skill_relpaths() {
    case "${1:-}" in
        codex) printf '%s\n' '.codex/skills' ;;
        claude) printf '%s\n' '.claude/skills' ;;
        opencode) printf '%s\n' '.agents/skills' ;;
        dsh) printf '%s\n' '.dsh/skills' ;;
        *) return 1 ;;
    esac
}

# 生成 argv，**NUL 分隔**，调用方用
#   mapfile -d '' -t argv < <(cachyos_agent_command ...)
# 收集。
#
# 分隔符必须是 NUL 而不是换行：prompt 天然可以含换行（崩溃诊断的 prompt 就是多行
# heredoc），按行分隔会把它拆成多个参数，agent 会收到一堆多余的位置参数而报错。
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
        dsh)
            # dsh 不是普通 agent CLI，而是按 profile 启动的 harness：
            #   无 prompt → 进入交互 profile（默认 web，可用 CACHYOS_DSH_PROFILE 换）
            #   有 prompt → headless 一次性模式：答完打印结果就退出
            # 它没有"无人值守"旗标——审批策略由 profile 决定，命令这一层不掺和。
            if [[ -n $prompt ]]; then
                command=(dsh headless)
            else
                command=(dsh "${CACHYOS_DSH_PROFILE:-web}")
            fi
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

    # dsh headless 把答案打到 stdout 就退出：窗口若立刻关闭，用户根本读不到结果。
    # 由 cachyos-agent-console 的 --hold 负责留住窗口，这里只声明"谁需要"。
    if [[ $agent == dsh && -n $prompt ]]; then
        :
    fi

    printf '%s\0' "${command[@]}"
}

# 续接既有会话的 argv，NUL 分隔（同 cachyos_agent_command）。第三个参数是可选的新 prompt：
# "带着这个问题继续那个会话" 是 cachyos-ask 每天复用同一会话的关键。
# 四个工具的语法各不相同，所以只在这一处定义：
#   claude    --resume <session-id> [-- <prompt>]
#   codex     resume <SESSION_ID> [PROMPT]（无人值守旗标是全局的，放子命令之前）
#   opencode  --session <id> [--prompt <prompt>]
#   dsh       web profile 不能续接，但 **headless 可以**：--session-id <id> <prompt>
#             （采用既有会话、答完就退出）。因此 dsh 只有在给出 prompt 时才有续接命令。
# 任何拼不出来的情况都返回 1（并且不输出），由调用方决定退回新会话还是报错。
cachyos_agent_resume_command() {
    local agent="${1:-}"
    local session_id="${2:-}"
    local prompt="${3:-}"
    local -a command

    [[ -n $session_id ]] || return 1

    case "$agent" in
        claude)
            command=(claude --permission-mode auto --resume "$session_id")
            [[ -n $prompt ]] && command+=(-- "$prompt")
            ;;
        codex)
            command=(codex --approve-for-me resume "$session_id")
            [[ -n $prompt ]] && command+=("$prompt")
            ;;
        opencode)
            command=(opencode --auto --session "$session_id")
            [[ -n $prompt ]] && command+=(--prompt "$prompt")
            ;;
        dsh)
            [[ -n $prompt ]] || return 1
            command=(dsh headless --session-id "$session_id" "$prompt")
            ;;
        *)
            return 1
            ;;
    esac

    printf '%s\0' "${command[@]}"
}

# 该 agent 是否支持"交互式"命令行续接（选择器用这个判据）。
# dsh 的 web profile 没有 --resume，只有给出 prompt 时才能走 headless 采用既有会话，
# 所以选择器里它仍然标注为"打开 Web UI"，而 cachyos-ask 会用到 headless 那条路径。
cachyos_agent_can_resume() {
    case "${1:-}" in
        claude | codex | opencode) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

# 需要"跑完留住窗口"的 agent：一次性模式会把答案打到 stdout 就退出，
# 不 hold 的话窗口一闪而过。其余 agent 是交互式，退出即用户主动结束，不必 hold。
cachyos_agent_hold_window() {
    case "${1:-}" in
        dsh) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
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
