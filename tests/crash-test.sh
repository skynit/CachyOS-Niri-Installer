#!/usr/bin/env bash

# 崩溃记录解析与静音的回归测试。
#
# 不依赖真实崩溃：用 stub journalctl 喂合成条目，因此可以在任何机器上跑。
# 这里盯的是两条真实踩过的坑：
#   1. 分隔符用制表符时，缺失字段会被 read 折叠，后面的列整体错位
#   2. 内核把 comm 截到 15 字节，静音名单不跟着截断就永远匹配不上

set -euo pipefail

# 打开 job control：每个后台 watcher 各自成为一个进程组长，收尾时用负 PID 一次杀掉整组
# （stub journalctl 及其 `sleep 600` 都在这一组里），不留 600 秒的孤儿睡眠。
set -m

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR

PASS_COUNT=0
WORK_DIR="$(mktemp -d)"
CASE_WATCH_PID=""
CASE_DIR=""

# 结束当前用例的 watcher。负号 = 整个进程组：只杀主进程的话，它 spawn 的 journalctl
# stub 与 stub 里的 `sleep 600` 会变成孤儿，每跑一次测试就多留几个 10 分钟进程。
stop_case_watcher() {
    if [[ -n ${CASE_WATCH_PID:-} ]]; then
        kill -TERM -"$CASE_WATCH_PID" 2>/dev/null \
            || kill -TERM "$CASE_WATCH_PID" 2>/dev/null \
            || true
        wait "$CASE_WATCH_PID" 2>/dev/null || true
        CASE_WATCH_PID=""
    fi
}

cleanup() {
    stop_case_watcher
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

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

# 在**顶层**启动 watcher 并挂上合成条目。
#
# 为什么必须单独成函数、且必须在顶层调用：watcher 要成为独立进程组长，收尾时才能用负
# PID 一次杀掉它 spawn 的 journalctl stub 与 stub 里的 `sleep 600`。而 bash 在命令替换
# `$(...)` 的子 shell 里**关闭 job control**，那样启动的 watcher 拿不到自己的进程组，
# 负 PID 直接指向不存在的组、失败还会被 `|| true` 吞掉——实测每跑一轮漏 5 个 10 分钟孤儿。
# 所以启动动作不能放在 `$(crash_record_for ...)` 里面。
start_crash_watcher() {
    local entry="$1"
    local timestamp="${2:-$(( ($(date +%s) + 3600) * 1000000 ))}"
    local case_dir
    case_dir="$(mktemp -d "$WORK_DIR/case.XXXXXX")"
    mkdir -p "$case_dir/home" "$case_dir/bin"
    CASE_DIR="$case_dir"

    jq -c --arg ts "$timestamp" '. + {__REALTIME_TIMESTAMP: $ts}' <<<"$entry" \
        > "$case_dir/entries.jsonl" 2>/dev/null || fail '合成条目不是合法 JSON'

    # stub journalctl：先吐一条**空行**模拟 `-f -n 1` 带出的那条历史记录（watermark 会
    # 用它的时间戳挡住后续更早的条目），再吐合成条目，然后挂住（让 watcher 停在"跟随中"）。
    cat > "$case_dir/bin/journalctl" <<STUB
#!/usr/bin/env bash
printf '\n'
sleep 0.3
cat "$case_dir/entries.jsonl"
sleep 600
STUB
    chmod +x "$case_dir/bin/journalctl"

    # stub notify-send / dms：这条测试绝不能往真实桌面发通知。动作式通知会等到用户
    # 处理为止（-t 0），一旦漏挂就会在你桌上堆出假的崩溃提示，并留下常驻等待进程。
    cat > "$case_dir/bin/notify-send" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    cat > "$case_dir/bin/dms" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$case_dir/bin/notify-send" "$case_dir/bin/dms"

    HOME="$case_dir/home" \
        CACHYOS_CRASH_DEDUPE_SECONDS=0 \
        CACHYOS_DESKTOP_SHARE_DIR="$case_dir/no-share" \
        PATH="$case_dir/bin:$PATH" \
        "$PROJECT_DIR/bin/cachyos-crash-watch" > "$case_dir/watch.log" 2>&1 &
    CASE_WATCH_PID=$!
    sleep 3
}

# 回显当前用例里 watcher 写下的 last-crash 内容。只读结果，不再管理进程生命周期。
crash_record_for() {
    cat "$CASE_DIR/home/.local/state/cachyos-desktop/agents/last-crash" 2>/dev/null || true
}

# ---- 字段解析：缺失字段不能让后面的列错位 ------------------------------------

start_crash_watcher '{"COREDUMP_PID":"900001","COREDUMP_COMM":"cwnA","COREDUMP_EXE":"/usr/bin/cwnA","COREDUMP_SIGNAL":"11"}'
normal_record="$(crash_record_for)"
stop_case_watcher
assert_equal '900001' "$(sed -n 's/^pid=//p' <<<"$normal_record")" '完整记录：pid 正确'
assert_equal 'cwnA' "$(sed -n 's/^comm=//p' <<<"$normal_record")" '完整记录：comm 正确'
assert_equal '/usr/bin/cwnA' "$(sed -n 's/^exe=//p' <<<"$normal_record")" '完整记录：exe 正确'
assert_equal '11' "$(sed -n 's/^signal=//p' <<<"$normal_record")" '完整记录：signal 正确'

# 缺 EXE：制表符 IFS 会把空字段折掉，signal 会顶到 exe 上。
start_crash_watcher '{"COREDUMP_PID":"900002","COREDUMP_COMM":"cwnB","COREDUMP_SIGNAL":"11"}'
missing_exe_record="$(crash_record_for)"
stop_case_watcher
assert_equal '' "$(sed -n 's/^exe=//p' <<<"$missing_exe_record")" '缺 EXE 时 exe 为空，不吃掉 signal'
assert_equal '11' "$(sed -n 's/^signal=//p' <<<"$missing_exe_record")" '缺 EXE 时 signal 仍落在 signal 列'

# 缺 PID：错位会让 comm 顶到 pid 列，进而让"点击诊断"拿到非数字 PID 被拒。
start_crash_watcher '{"COREDUMP_COMM":"cwnC","COREDUMP_EXE":"/usr/bin/cwnC","COREDUMP_SIGNAL":"6"}'
missing_pid_record="$(crash_record_for)"
stop_case_watcher
assert_equal '' "$(sed -n 's/^pid=//p' <<<"$missing_pid_record")" '缺 PID 时 pid 为空'
assert_equal 'cwnC' "$(sed -n 's/^comm=//p' <<<"$missing_pid_record")" '缺 PID 时 comm 仍在 comm 列'
assert_equal '6' "$(sed -n 's/^signal=//p' <<<"$missing_pid_record")" '缺 PID 时 signal 仍在 signal 列'

# ---- 静音名单：名字必须按内核的 15 字节上限截断 -------------------------------

mute_home="$WORK_DIR/mute-home"
mkdir -p "$mute_home"
mute_out="$(HOME="$mute_home" "$PROJECT_DIR/bin/cachyos-crash-mute" verylongprocessname12345 2>&1)"
mute_file="$mute_home/.local/state/cachyos-desktop/agents/crash-muted.txt"
assert_equal 'verylongprocess' "$(cat "$mute_file")" '超过 15 字节的程序名按内核上限截断后再静音'
if [[ $mute_out == *"15 字节"* ]]; then
    pass '对截断给出了提示'
else
    fail '没有提示名字被截断' "输出: $mute_out"
fi

# 短名字不受影响；路径形式仍按 basename 归一。
HOME="$mute_home" "$PROJECT_DIR/bin/cachyos-crash-mute" /usr/bin/short >/dev/null
HOME="$mute_home" "$PROJECT_DIR/bin/cachyos-crash-mute" short off >/dev/null
assert_equal 'verylongprocess' "$(cat "$mute_file")" '短名字增删不影响已截断项'

# ---- 崩溃捕获开关（cachyos-toggle-crash-capture）-------------------------------
# 关掉要"两层"生效：标记文件（下次登录也不启动）+ 立刻停掉当前服务。
toggle_home="$WORK_DIR/toggle-home"
mkdir -p "$toggle_home" "$WORK_DIR/toggle-bin"
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >> "%s"\n' "$WORK_DIR/toggle-calls" > "$WORK_DIR/toggle-bin/systemctl"
chmod +x "$WORK_DIR/toggle-bin/systemctl"
for name in dms notify-send; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK_DIR/toggle-bin/$name"
    chmod +x "$WORK_DIR/toggle-bin/$name"
done
flag="$toggle_home/.local/state/cachyos-desktop/toggles/crash-capture-off"

: > "$WORK_DIR/toggle-calls"
HOME="$toggle_home" PATH="$WORK_DIR/toggle-bin:$PATH" "$PROJECT_DIR/bin/cachyos-toggle-crash-capture" off >/dev/null 2>&1
assert_equal 'true' "$([[ -e $flag ]] && echo true || echo false)" '关闭后写下标记文件（下次登录也不启动）'
grep -q 'stop cachyos-crash-watch.service' "$WORK_DIR/toggle-calls" \
    && pass '关闭时立即停掉本次会话的服务' || fail '关闭时没有停服务'

: > "$WORK_DIR/toggle-calls"
HOME="$toggle_home" PATH="$WORK_DIR/toggle-bin:$PATH" "$PROJECT_DIR/bin/cachyos-toggle-crash-capture" toggle >/dev/null 2>&1
assert_equal 'false' "$([[ -e $flag ]] && echo true || echo false)" 'toggle 把关闭状态切回开启'
grep -q 'start cachyos-crash-watch.service' "$WORK_DIR/toggle-calls" \
    && pass '开启时启动服务' || fail '开启时没有启动服务'

if HOME="$toggle_home" PATH="$WORK_DIR/toggle-bin:$PATH" "$PROJECT_DIR/bin/cachyos-toggle-crash-capture" --bogus >/dev/null 2>&1; then
    fail '未知选项不该返回成功'
else
    pass '未知选项返回非 0'
fi

# 单元必须真的读这个标记，否则"关闭"只在本次会话有效
if grep -q 'ConditionPathExists=!.*crash-capture-off' "$PROJECT_DIR/assets/systemd/user/cachyos-crash-watch.service"; then
    pass '单元用 ConditionPathExists=! 读标记（关闭能跨登录保持）'
else
    fail '单元没有读标记文件，关闭无法跨登录保持'
fi


# ---- 启动水位：`-f -n 1` 带出的那条历史记录不能被当成新崩溃 --------------------
#
# 真机上这里是"服务一重启就补发一条几小时前的崩溃通知"的来源，所以必须挡住。

# 显式喂一条 1 小时前的记录：应被水位丢弃，last-crash 不该被写。
old_ts="$(( ($(date +%s) - 3600) * 1000000 ))"
start_crash_watcher '{"COREDUMP_PID":"900010","COREDUMP_COMM":"cwnOld","COREDUMP_EXE":"/usr/bin/cwnOld","COREDUMP_SIGNAL":"11"}' "$old_ts"
old_out="$(crash_record_for)"
stop_case_watcher
assert_equal '' "$old_out" '水位：早于启动时刻的历史记录不写 last-crash'

# 同一条记录改用"1 小时后"：应正常处理。两相对照排除了"根本没读到日志"的可能。
start_crash_watcher '{"COREDUMP_PID":"900011","COREDUMP_COMM":"cwnNew","COREDUMP_EXE":"/usr/bin/cwnNew","COREDUMP_SIGNAL":"11"}'
new_out="$(crash_record_for)"
stop_case_watcher
assert_equal '900011' "$(sed -n 's/^pid=//p' <<<"$new_out")" '水位：新记录照常处理（对照历史记录）'

# 源码层面回归：修之前这里正是 `-f -n 0` —— 实测 systemd 262 上与 MESSAGE_ID 组合会
# 静默返回 0 行（服务 active 却永远收不到崩溃）。注释里会提到这个坑，所以先剥掉注释行。
watch_source="$(sed 's/#.*//' "$PROJECT_DIR/bin/cachyos-crash-watch")"
if grep -q -- '-f -n 1' <<<"$watch_source"; then
    pass '订阅用 -f -n 1（-n 0 在 systemd 262 上收不到任何事件）'
else
    fail '订阅没有用 -f -n 1' "$(grep -n 'journalctl' <<<"$watch_source")"
fi
if grep -q -- '-n 0' <<<"$watch_source"; then
    fail '代码行里仍有 -n 0（会静默收不到事件）'
else
    pass '代码行里没有 -n 0'
fi


printf '\n%s 项检查通过。\n' "$PASS_COUNT"
