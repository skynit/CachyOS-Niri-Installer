#!/usr/bin/env bash

# 终端界面（TUI）小库：给安装流程画出好看的框、阶段标题、进度条与状态行。
#
# 为什么不用 gum / dialog / whiptail：本项目的用途是"新电脑复刻"，安装发生在**刚装好的
# CachyOS 基础系统**上，任何额外依赖都可能是"还没装上"的状态；而 whiptail 只能做对话框，
# 画不出持续的过程输出。纯 bash + ANSI 零依赖，且能随终端能力退化。
#
# **关键约束**：只要输出不是终端（管道、`> log`、CI、测试抓日志），或者 TERM=dumb、
# 设置了 NO_COLOR、locale 不是 UTF-8，就退化成纯文本——不带 ANSI、不带 \r 覆盖、
# 不用制表符画框。verify.sh 与 tests/ 都在抓这些输出，界面不能污染它们。

[[ -n ${CACHYOS_TUI_LOADED:-} ]] && return 0
readonly CACHYOS_TUI_LOADED=1

# 颜色（为空字符串时表示不上色）
TUI_RESET=""
TUI_BOLD=""
TUI_DIM=""
TUI_ACCENT=""
TUI_OK=""
TUI_WARN=""
TUI_ERR=""
TUI_MUTED=""

TUI_TTY=false
TUI_COLOR=false
TUI_UNICODE=false
TUI_WIDTH=0
TUI_TOP_LEFT=""
TUI_TOP_RIGHT=""
TUI_BOTTOM_LEFT=""
TUI_BOTTOM_RIGHT=""
TUI_HORIZONTAL=""
TUI_VERTICAL=""

# 阶段计时与统计，供收尾汇总用
TUI_PHASE_INDEX=0
TUI_PHASE_TOTAL=0
TUI_PHASE_STARTED=0
TUI_PHASE_TITLE=""
TUI_STEPS_OK=0
TUI_STEPS_WARN=0
TUI_STEPS_SKIP=0
TUI_STARTED_AT=0

tui_init() {
    TUI_TTY=false
    TUI_COLOR=false
    TUI_UNICODE=false

    if [[ -t 1 ]]; then
        TUI_TTY=true
        TUI_COLOR=true
        # TERM=dumb 表示终端没有光标控制能力；NO_COLOR 是通用约定；
        # CACHYOS_TUI=plain 给我们自己一个显式开关（例如接进 CI 日志）。
        [[ ${TERM:-dumb} == dumb ]] && TUI_COLOR=false
        [[ -n ${NO_COLOR:-} ]] && TUI_COLOR=false
        [[ ${CACHYOS_TUI:-} == plain ]] && TUI_COLOR=false
    fi

    # 制表符画框要求 UTF-8 locale；否则退回 ASCII，避免在 C locale 下输出乱码。
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8* | *utf8* | *UTF8*) TUI_UNICODE=true ;;
    esac

    if [[ $TUI_COLOR == true ]]; then
        TUI_RESET=$'\033[0m'
        TUI_BOLD=$'\033[1m'
        TUI_DIM=$'\033[2m'
        TUI_ACCENT=$'\033[38;5;44m'
        TUI_OK=$'\033[32m'
        TUI_WARN=$'\033[33m'
        TUI_ERR=$'\033[31m'
        TUI_MUTED=$'\033[38;5;245m'
    fi

    # 框线字符：UTF-8 locale 用圆角，否则退回 ASCII，避免乱码。
    if [[ $TUI_UNICODE == true ]]; then
        TUI_TOP_LEFT="╭"; TUI_TOP_RIGHT="╮"; TUI_BOTTOM_LEFT="╰"; TUI_BOTTOM_RIGHT="╯"
        TUI_HORIZONTAL="─"; TUI_VERTICAL="│"
    else
        TUI_TOP_LEFT="+"; TUI_TOP_RIGHT="+"; TUI_BOTTOM_LEFT="+"; TUI_BOTTOM_RIGHT="+"
        TUI_HORIZONTAL="-"; TUI_VERTICAL="|"
    fi

    TUI_WIDTH="$(tui_detect_width)"
    TUI_STARTED_AT="$(date +%s)"
    TUI_PHASE_INDEX=0
    TUI_PHASE_TOTAL=0
    TUI_STEPS_OK=0
    TUI_STEPS_WARN=0
    TUI_STEPS_SKIP=0
}

# 终端宽度：优先 COLUMNS，其次 tput，最后 100；夹在 40..120 之间，太窄画不下、太宽难看。
tui_detect_width() {
    local width="${COLUMNS:-}"
    if [[ ! $width =~ ^[0-9]+$ && -t 1 ]] && command -v tput >/dev/null 2>&1; then
        width="$(tput cols 2>/dev/null || true)"
    fi
    [[ $width =~ ^[0-9]+$ ]] || width=100
    ((width < 40)) && width=40
    ((width > 120)) && width=120
    # 留一列边距：整行宽度正好等于终端宽度时，很多终端会"待换行"，下一行输出就错位了。
    ((width > 40)) && width=$((width - 1))
    printf '%s' "$width"
}

# 去掉 ANSI 转义。
tui_strip_ansi() {
    printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

# 可见**列数**：不能数 bash 的字符数，中文/全角字符占两列，否则框的右边线会错位。
# 逐字节看 UTF-8 首字节：>=224 是三字节（含 CJK，算 2 列），192..223 是两字节（算 1 列）。
tui_visible_length() {
    local text
    text="$(tui_strip_ansi "$1")"
    local LC_ALL=C
    local width=0 index=0 length=${#text} first code
    while ((index < length)); do
        first="${text:index:1}"
        printf -v code '%d' "'$first" 2>/dev/null || code=63
        if ((code >= 224)); then
            # 制表符/框线（U+2500..U+257F）的东亚宽度是"模糊"：绝大多数终端按 1 列渲染，
            # 所以这里单独排除，否则重复画框线时会算成两倍宽。
            local second
            second="${text:index+1:1}"
            local second_code
            printf -v second_code '%d' "'$second" 2>/dev/null || second_code=0
            if ((code == 226 && second_code >= 148 && second_code <= 149)); then
                width=$((width + 1))
            else
                width=$((width + 2))
            fi
            index=$((index + 3))
        elif ((code >= 192)); then
            width=$((width + 1))
            index=$((index + 2))
        else
            width=$((width + 1))
            index=$((index + 1))
        fi
    done
    printf '%s' "$width"
}

# 重复一个字符串 N 次。**不能用 tr**：tr 按字节工作，会把 `─` 拆成非法 UTF-8。
tui_repeat() {
    local char="$1" count="$2" result="" index
    for ((index = 0; index < count; index++)); do
        result+="$char"
    done
    printf '%s' "$result"
}

# 按列宽补齐/截断（截断加省略号）。ANSI 只允许出现在整段之外，避免被切开。
tui_fit() {
    local text="$1" width="$2"
    local visible
    visible="$(tui_visible_length "$text")"
    if ((visible > width)); then
        local LC_ALL=C
        local out="" index=0 length=${#text} first code used=0 limit=$((width - 1))
        while ((index < length && used < limit)); do
            first="${text:index:1}"
            printf -v code '%d' "'$first" 2>/dev/null || code=63
            local step=1 char_width=1
            if ((code >= 224)); then
                step=3
                char_width=2
            elif ((code >= 192)); then
                step=2
            fi
            ((used + char_width > limit)) && break
            out+="${text:index:step}"
            used=$((used + char_width))
            index=$((index + step))
        done
        printf '%s…' "$out"
        return 0
    fi
    printf '%s' "$text"
    local pad=$((width - visible))
    ((pad > 0)) && printf '%s' "$(tui_repeat ' ' "$pad")"
}

# 画一条横线。$1=字符（默认 ─ / -）
tui_rule() {
    ((TUI_WIDTH > 0)) || tui_init
    local char="${1:-}"
    if [[ -z $char ]]; then
        [[ $TUI_UNICODE == true ]] && char="─" || char="-"
    fi
    printf '%s%s%s\n' "$TUI_MUTED" "$(tui_repeat "$char" "$TUI_WIDTH")" "$TUI_RESET"
}

# 画一行框内内容：│ 文本 │ 。单独成函数是为了不再手写 printf 格式串——
# 之前正文行就是格式符比参数多一个，结果每行尾部多出一个空格。
tui_box_line() {
    local content
    content="$(tui_fit "$1" "$2")"
    printf '%s%s%s %s %s%s%s\n' "$TUI_MUTED" "$TUI_VERTICAL" "$TUI_RESET" "$content" "$TUI_RESET" "$TUI_MUTED$TUI_VERTICAL$TUI_RESET"
}

# 顶部横幅：项目名 + 关键参数，画成圆角框。
# 用法：tui_banner "标题" "第一行副标题" "第二行…"
tui_banner() {
    ((TUI_WIDTH > 0)) || tui_init
    local title="$1"
    shift
    local inner=$((TUI_WIDTH - 4))
    local border
    border="$(tui_repeat "$TUI_HORIZONTAL" "$((TUI_WIDTH - 2))")"

    printf '%s%s%s%s%s\n' "$TUI_MUTED" "$TUI_TOP_LEFT" "$border" "$TUI_TOP_RIGHT" "$TUI_RESET"
    tui_box_line "${TUI_BOLD}${TUI_ACCENT}${title}${TUI_RESET}" "$inner"
    local line
    for line in "$@"; do
        tui_box_line "$line" "$inner"
    done
    printf '%s%s%s%s%s\n' "$TUI_MUTED" "$TUI_BOTTOM_LEFT" "$border" "$TUI_BOTTOM_RIGHT" "$TUI_RESET"
}

# 阶段标题：── 阶段 2/6 · 应用与 DMS ─────────
tui_phase_start() {
    ((TUI_WIDTH > 0)) || tui_init
    local title="$1"
    TUI_PHASE_TITLE="$title"
    TUI_PHASE_INDEX=$((TUI_PHASE_INDEX + 1))
    TUI_PHASE_STARTED="$(date +%s)"

    local label="阶段 ${TUI_PHASE_INDEX}"
    ((TUI_PHASE_TOTAL > 0)) && label+="/${TUI_PHASE_TOTAL}"
    label+=" · $title"

    local used
    used="$(tui_visible_length "$label")"
    local rest=$((TUI_WIDTH - used - 4))
    ((rest < 0)) && rest=0

    local rule
    rule="$(tui_repeat '-' "$rest")"
    if [[ $TUI_TTY == true ]]; then
        printf '\n%s%s%s %s%s%s\n' "$TUI_BOLD$TUI_ACCENT" "$label" "$TUI_RESET" "$TUI_MUTED" "$rule" "$TUI_RESET"
    else
        printf '\n== %s %s\n' "$label" "$rule"
    fi
}

tui_phase_done() {
    # 默认用阶段名收尾：只打一个 "✔ 3s" 会让人不知道刚完成的是什么。
    local note="${1:-${TUI_PHASE_TITLE:-}}"
    local elapsed=$(( $(date +%s) - TUI_PHASE_STARTED ))
    local suffix="完成"
    [[ -n $note ]] && suffix="$note"
    if [[ $TUI_TTY == true ]]; then
        printf '%s✔%s %s %s· %ss%s\n' "$TUI_OK" "$TUI_RESET" "$suffix" "$TUI_MUTED" "$elapsed" "$TUI_RESET"
    else
        printf '  [ DONE ] %s（%ds）\n' "${note:-完成}" "$elapsed"
    fi
    TUI_STEPS_OK=$((TUI_STEPS_OK + 1))
}

# 步骤/状态行。前缀保留 [INFO]/[WARN]/[ERROR]，因为日志与测试都在认这些标记。
tui_info() { printf '%s[INFO]%s %s\n' "$TUI_ACCENT" "$TUI_RESET" "$*"; }
tui_warn() { printf '%s[WARN]%s %s\n' "$TUI_WARN" "$TUI_RESET" "$*" >&2; TUI_STEPS_WARN=$((TUI_STEPS_WARN + 1)); }
tui_error() { printf '%s[ERROR]%s %s\n' "$TUI_ERR" "$TUI_RESET" "$*" >&2; }

# 一条不带标记的步骤（缩进 + 小箭头），用于罗列"接下来做什么"。
tui_step() {
    if [[ $TUI_TTY == true ]]; then
        printf '  %s▸%s %s\n' "$TUI_MUTED" "$TUI_RESET" "$*"
    else
        printf '  - %s\n' "$*"
    fi
}

# 成功/跳过/提醒三态，供阶段内的子步骤打勾用。
tui_ok() {
    TUI_STEPS_OK=$((TUI_STEPS_OK + 1))
    if [[ $TUI_TTY == true ]]; then
        printf '  %s✔%s %s\n' "$TUI_OK" "$TUI_RESET" "$*"
    else
        printf '  [ OK ] %s\n' "$*"
    fi
}

tui_skip() {
    TUI_STEPS_SKIP=$((TUI_STEPS_SKIP + 1))
    if [[ $TUI_TTY == true ]]; then
        printf '  %s−%s %s\n' "$TUI_MUTED" "$TUI_RESET" "$*"
    else
        printf '  [SKIP] %s\n' "$*"
    fi
}

tui_note() {
    TUI_STEPS_WARN=$((TUI_STEPS_WARN + 1))
    if [[ $TUI_TTY == true ]]; then
        printf '  %s!%s %s\n' "$TUI_WARN" "$TUI_RESET" "$*"
    else
        printf '  [WARN] %s\n' "$*"
    fi
}

# 进度条：tui_progress <已完成> <总数> [说明]
tui_progress() {
    local done="$1" total="$2" label="${3:-}"
    ((total <= 0)) && return 0
    local width=24
    local filled=$((done * width / total))
    ((filled > width)) && filled=$width
    local bar=""
    local i
    for ((i = 0; i < width; i++)); do
        if ((i < filled)); then
            [[ $TUI_UNICODE == true ]] && bar+="█" || bar+="#"
        else
            [[ $TUI_UNICODE == true ]] && bar+="░" || bar+="."
        fi
    done
    if [[ $TUI_TTY == true ]]; then
        printf '  %s%s%s %s%d/%d%s' "$TUI_ACCENT" "$bar" "$TUI_RESET" "$TUI_MUTED" "$done" "$total" "$TUI_RESET"
        [[ -n $label ]] && printf '  %s' "$label"
        printf '\n'
    else
        printf '  [%d/%d] %s\n' "$done" "$total" "$label"
    fi
}

# 转圈：只在真终端用，且只包住"自己会静默执行"的命令（pacman 自己会输出，别套它，否则串行错乱）。
TUI_SPIN_PID=""
tui_spin_start() {
    local label="$1"
    if [[ $TUI_TTY != true ]]; then
        printf '  - %s\n' "$label"
        return 0
    fi
    printf '  %s%s%s ' "$TUI_MUTED" "$label" "$TUI_RESET"
    (
        local frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" i=0
        while :; do
            printf '\r  %s%s%s %s' "$TUI_MUTED" "$label" "$TUI_RESET" "${frames:i%10:1}"
            i=$((i + 1))
            sleep 0.1
        done
    ) &
    TUI_SPIN_PID=$!
}

tui_spin_stop() {
    local state="${1:-ok}" note="${2:-}"
    if [[ -n $TUI_SPIN_PID ]]; then
        kill "$TUI_SPIN_PID" 2>/dev/null || true
        wait "$TUI_SPIN_PID" 2>/dev/null || true
        TUI_SPIN_PID=""
        printf '\r\033[K'
    fi
    case "$state" in
        ok) tui_ok "$note" ;;
        skip) tui_skip "$note" ;;
        *) tui_note "$note" ;;
    esac
}

# 收尾汇总框：统计本次运行的结果与耗时。
tui_summary() {
    ((TUI_WIDTH > 0)) || tui_init
    local title="$1"
    shift
    local elapsed=$(( $(date +%s) - TUI_STARTED_AT ))
    local minutes=$((elapsed / 60)) seconds=$((elapsed % 60))
    local inner=$((TUI_WIDTH - 4))
    local border
    border="$(tui_repeat "$TUI_HORIZONTAL" "$((TUI_WIDTH - 2))")"

    printf '\n'
    printf '%s%s%s%s%s\n' "$TUI_MUTED" "$TUI_TOP_LEFT" "$border" "$TUI_TOP_RIGHT" "$TUI_RESET"
    tui_box_line "${TUI_BOLD}${TUI_ACCENT}${title}${TUI_RESET}" "$inner"
    tui_box_line "成功 ${TUI_STEPS_OK} 项 · 警告 ${TUI_STEPS_WARN} 项 · 跳过 ${TUI_STEPS_SKIP} 项 · 耗时 ${minutes} 分 ${seconds} 秒" "$inner"
    local line
    for line in "$@"; do
        tui_box_line "$line" "$inner"
    done
    printf '%s%s%s%s%s\n' "$TUI_MUTED" "$TUI_BOTTOM_LEFT" "$border" "$TUI_BOTTOM_RIGHT" "$TUI_RESET"
}
