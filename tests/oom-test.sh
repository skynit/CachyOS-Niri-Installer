#!/usr/bin/env bash

# OOM 监听（cachyos-oom-watch）与诊断入口（cachyos-agent-oom）的回归测试。
#
# 不依赖真实 OOM：用 stub journalctl 喂合成条目、stub notify-send 只计数，因此任何机器
# 都能跑，也**绝不会**往真实桌面弹通知——动作式通知是 `-t 0`（一直等到用户处理），漏挂
# stub 就会在桌上堆出假提示并留下常驻等待进程。
#
# 这里盯的是几条真实踩过的坑：
#   1. 本机 systemd 262 上 `journalctl -f -n 0` 与任何过滤条件组合都**静默返回 0 行**，
#      所以 watcher 用 `-f -n 1` + 时间戳水位；stub 的时间戳必须晚于水位，否则被丢。
#   2. 内核一次 OOM 会发两条消息（`oom-kill:` 与 `Memory cgroup out of memory:`），只能
#      提醒一次，但后一条带的 anon-rss 要补进 last-oom。
#   3. oomd 的最终动作消息前缀是 "<unit>: "（还可能带尾空格），unit 必须剥干净再去查
#      cgroup——这是已修过的真实 bug。
#   4. cachyos-agent-oom 在没有记录时要给出可操作提示，而不是静默失败。

set -euo pipefail

# 打开 job control：每个后台 watcher 各自成为一个进程组长，收尾时用负 PID 一次杀掉整组
# （journalctl stub 及其 sleep、PSI 子进程都在这一组里），不留 600 秒的僵尸睡眠。
set -m

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR
WATCHER="$PROJECT_DIR/bin/cachyos-oom-watch"
readonly WATCHER
AGENT_OOM="$PROJECT_DIR/bin/cachyos-agent-oom"
readonly AGENT_OOM

PASS_COUNT=0
WORK_DIR="$(mktemp -d)"
CASE_DIR=""
CASE_WATCH_PID=""

stop_case_watcher() {
    if [[ -n ${CASE_WATCH_PID:-} ]]; then
        # Keep process-group cleanup as a fallback for failing lifecycle tests
        # and synthetic helpers, even when the main watcher has already exited.
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

# ---- 合成条目与时间戳 ---------------------------------------------------------

# watcher 用「启动时刻」的 `date +%s%6N`（微秒）做水位，只有严格大于水位的条目才会被
# 消费。所以时间戳必须现算，不能写死（写死的历史值永远过不了水位，测试会一直失败）。
# 这里取「测试开始 + 1 小时」再逐条 +1：既保证大于 watcher 启动水位，又保证同一次运行里
# 多条条目严格递增——水位是数值比较，相等的第二条同样会被丢掉。
TS_CURSOR=$(( $(date +%s%6N) + 3600 * 1000000 ))
next_ts() { TS_CURSOR=$((TS_CURSOR + 1)); }

new_case() {
    local case_name="$1"

    CASE_DIR="$(mktemp -d "$WORK_DIR/$case_name.XXXXXX")"
    mkdir -p "$CASE_DIR/home" "$CASE_DIR/bin"
    : > "$CASE_DIR/kernel.jsonl"
    : > "$CASE_DIR/oomd.jsonl"
    : > "$CASE_DIR/notify-calls"
    : > "$CASE_DIR/journalctl-calls"

    # stub journalctl：按 watcher 的两种调用形态分流。
    # watcher 只会这样调：`journalctl -f -n 1 -o json -k` 与 `... -u systemd-oomd`。
    # 输出合成条目后 sleep 挂住，模拟真实 `-f` 的「跟随中」。
    cat > "$CASE_DIR/bin/journalctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE_DIR/journalctl-calls"
if [[ " \$* " == *" -u systemd-oomd "* ]]; then
    cat "$CASE_DIR/oomd.jsonl"
elif [[ " \$* " == *" -k "* ]]; then
    cat "$CASE_DIR/kernel.jsonl"
fi
exec sleep 600
STUB

    # notify-send：只计数，绝不真的发通知。故意不回显 action —— watcher 的
    # `action="$(notify-send ...)"` 拿到空串就不会走「点击诊断」分支，也不会再发第二条
    # 纯提示式通知，调用次数才等于「提醒次数」。
    cat > "$CASE_DIR/bin/notify-send" <<STUB
#!/usr/bin/env bash
printf 'notify-send\n' >> "$CASE_DIR/notify-calls"
exit 0
STUB

    # systemctl 假成功 → wait_for_notifier 立即返回，不用真等 dms.service 最多 5 秒；
    # dms / cachyos-agent / cachyos-agent-oom 兜底，保证不会真弹通知或真起 agent。
    for stub_name in dms systemctl cachyos-agent cachyos-agent-oom systemd-cgtop; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_DIR/bin/$stub_name"
    done
    chmod +x "$CASE_DIR"/bin/*
}

# 每条 journal 条目都是合法 JSON，且带 watcher 解析所需的字段。
add_kernel_entry() {
    local message="$1"
    local comm="${2:-unknown}"
    local pid="${3:-0}"

    next_ts
    jq -cn --arg ts "$TS_CURSOR" --arg message "$message" --arg comm "$comm" --arg pid "$pid" \
        '{__REALTIME_TIMESTAMP:$ts, MESSAGE:$message, _COMM:$comm, _PID:$pid, _TRANSPORT:"kernel"}' \
        >> "$CASE_DIR/kernel.jsonl"
}

add_oomd_entry() {
    local message="$1"

    next_ts
    jq -cn --arg ts "$TS_CURSOR" --arg message "$message" \
        '{__REALTIME_TIMESTAMP:$ts, MESSAGE:$message, _COMM:"systemd-oomd", _PID:"1", _TRANSPORT:"stdout"}' \
        >> "$CASE_DIR/oomd.jsonl"
}

# 后台跑一次 watcher，给它 3 秒消费合成条目（与 crash-test.sh 同样的节奏），然后整组杀掉。
# 额外环境变量以 NAME=VALUE 形式传入。PSI 默认是开的；非 PSI 用例必须显式
# CACHYOS_OOM_PSI_ENABLED=0，否则真机的内存压力可能顺带写出一条 psi 记录，污染断言。
start_case_watcher() {
    env HOME="$CASE_DIR/home" XDG_CONFIG_HOME="$CASE_DIR/home/.config" \
        CACHYOS_DESKTOP_SHARE_DIR="$PROJECT_DIR" PATH="$CASE_DIR/bin:$PATH" "$@" \
        bash "$WATCHER" > "$CASE_DIR/watch.log" 2>&1 &
    CASE_WATCH_PID=$!
    sleep 3
}

case_home() { printf '%s' "$CASE_DIR/home"; }
case_agents_dir() { printf '%s' "$CASE_DIR/home/.local/state/cachyos-desktop/agents"; }

last_oom_file() { printf '%s/last-oom' "$(case_agents_dir)"; }

last_oom_field() {
    sed -n "s/^$1=//p" "$(last_oom_file)" 2>/dev/null | head -1
}

last_oom_exists() {
    [[ -f "$(last_oom_file)" ]]
}

notify_count() {
    wc -l < "$CASE_DIR/notify-calls" | tr -d '[:space:]'
}

# /proc also distinguishes exited, unreaped children from live helpers.
process_is_running() {
    local pid="$1"
    local stat

    [[ -r /proc/$pid/stat ]] || return 1
    read -r stat 2>/dev/null < "/proc/$pid/stat" || return 1
    [[ ${stat##*) } != Z\ * ]]
}

descendant_pids() {
    local pid="$1"
    local children="" child

    [[ -r /proc/$pid/task/$pid/children ]] || return 0
    read -r children 2>/dev/null < "/proc/$pid/task/$pid/children" || true
    for child in $children; do
        printf '%s\n' "$child"
        descendant_pids "$child"
    done
}

assert_processes_stopped() {
    local description="$1"
    shift
    local attempt pid
    local live=()

    for ((attempt = 0; attempt < 50; attempt++)); do
        live=()
        for pid in "$@"; do
            process_is_running "$pid" && live+=("$pid")
        done
        if ((${#live[@]} == 0)); then
            pass "$description"
            return 0
        fi
        sleep 0.1
    done
    fail "$description" "still running PIDs: ${live[*]}"
}

# KillMode=process sends TERM only to the main PID, not the test's process group.
# Keep group cleanup as a fallback, including when this regression fails.
new_case main-term
printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$CASE_DIR/pressure-memory"
start_case_watcher \
    CACHYOS_OOM_PSI_ENABLED=1 \
    CACHYOS_OOM_PSI_FILE="$CASE_DIR/pressure-memory" \
    CACHYOS_OOM_PSI_INTERVAL_SECONDS=1 \
    CACHYOS_OOM_DEDUPE_SECONDS=1
psi_pid_file="$CASE_DIR/home/.local/state/cachyos-desktop/.oom-watch-psi.pid"
[[ -s $psi_pid_file ]] || fail 'main TERM: PSI sampler started'
psi_pid="$(<"$psi_pid_file")"
mapfile -t helper_pids < <(descendant_pids "$CASE_WATCH_PID")
((${#helper_pids[@]} >= 6)) || fail 'main TERM: sampler, stream wrappers and children started'
assert_equal '2' "$(wc -l < "$CASE_DIR/journalctl-calls" | tr -d '[:space:]')" \
    'main TERM: both journal streams started'
kill -TERM "$CASE_WATCH_PID"
assert_processes_stopped 'main TERM: main process exits promptly' "$CASE_WATCH_PID"
wait "$CASE_WATCH_PID" 2>/dev/null || true
assert_processes_stopped 'main TERM: PSI sampler and all stream/sleep helpers exit' \
    "$psi_pid" "${helper_pids[@]}"
# Do not group-kill here: the disabled restart must expose any escaped sampler.
CASE_WATCH_PID=""

# Reuse HOME and pressure file, as a settings-triggered service restart does.
printf 'full avg10=42.50 avg60=42.50 avg300=42.50 total=1\n' > "$CASE_DIR/pressure-memory"
start_case_watcher \
    CACHYOS_OOM_PSI_ENABLED=0 \
    CACHYOS_OOM_PSI_FILE="$CASE_DIR/pressure-memory" \
    CACHYOS_OOM_PSI_INTERVAL_SECONDS=1 \
    CACHYOS_OOM_DEDUPE_SECONDS=1
assert_equal '0' "$(notify_count)" 'disabled restart: no notifications from an old PSI sampler'
if last_oom_exists; then
    fail 'disabled restart: no PSI record should be written'
fi
pass 'disabled restart: no PSI record'
mapfile -t helper_pids < <(descendant_pids "$CASE_WATCH_PID")
kill -TERM "$CASE_WATCH_PID"
assert_processes_stopped 'disabled restart: main and stream helpers exit' \
    "$CASE_WATCH_PID" "${helper_pids[@]}"
stop_case_watcher

# Both reconnect delays and a long PSI interval must be interruptible, too.
new_case reconnect-term
printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_DIR/bin/journalctl"
printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$CASE_DIR/pressure-memory"
start_case_watcher \
    CACHYOS_OOM_PSI_ENABLED=1 \
    CACHYOS_OOM_PSI_FILE="$CASE_DIR/pressure-memory" \
    CACHYOS_OOM_PSI_INTERVAL_SECONDS=600
mapfile -t helper_pids < <(descendant_pids "$CASE_WATCH_PID")
((${#helper_pids[@]} >= 6)) || fail 'reconnect TERM: wrapper and sampler sleepers started'
kill -TERM "$CASE_WATCH_PID"
assert_processes_stopped 'main TERM: long PSI sleep and journal reconnect sleeps exit' \
    "$CASE_WATCH_PID" "${helper_pids[@]}"
stop_case_watcher

# ---- 1. 内核 memcg OOM：字段要落全 -------------------------------------------
# 这是本机真实日志（09:28 连发三次同款）。anon-rss 是判定「谁吃光了内存」的关键字段，
# 解析丢了就没法诊断。

new_case kernel-memcg
add_kernel_entry 'Memory cgroup out of memory: Killed process 24158 (node-MainThread) total-vm:4536816kB, anon-rss:3138276kB, file-rss:30744kB, shmem-rss:0kB, UID:1000 pgtables:6784kB oom_score_adj:200' \
    node-MainThread 24158
start_case_watcher CACHYOS_OOM_PSI_ENABLED=0
stop_case_watcher

assert_equal '24158' "$(last_oom_field victim_pid)" '内核 memcg OOM：victim_pid 解析正确'
assert_equal 'node-MainThread' "$(last_oom_field victim_comm)" '内核 memcg OOM：victim_comm 解析正确'
assert_equal '3138276' "$(last_oom_field victim_rss_kb)" '内核 memcg OOM：anon-rss 落进 victim_rss_kb'
assert_equal 'kernel-memcg' "$(last_oom_field layer)" '内核 memcg OOM：layer=kernel-memcg'

# ---- 2. 结构化 oom-kill 行：constraint / oom_memcg / task / pid ---------------
# CONSTRAINT_NONE 表示整机内存真的耗尽，必须与受限 cgroup 的 OOM 区分开——两者该查的
# 方向完全不同（一个是撞限额，一个是整机不够）。

new_case kernel-oomkill-memcg
add_kernel_entry 'oom-kill:constraint=CONSTRAINT_MEMCG,nodemark=1,oom_memcg=/user.slice/user-1000.slice/user@1000.service/app.slice/run-p24156-i31266.scope,task=node-MainThread,pid=24158,uid=1000' \
    node-MainThread 24158
start_case_watcher CACHYOS_OOM_PSI_ENABLED=0
stop_case_watcher

assert_equal '24158' "$(last_oom_field victim_pid)" 'oom-kill 行：pid 解析正确'
assert_equal 'node-MainThread' "$(last_oom_field victim_comm)" 'oom-kill 行：task 当作 victim_comm'
assert_equal '/user.slice/user-1000.slice/user@1000.service/app.slice/run-p24156-i31266.scope' \
    "$(last_oom_field memcg)" 'oom-kill 行：oom_memcg 解析正确'
assert_equal 'CONSTRAINT_MEMCG' "$(last_oom_field constraint)" 'oom-kill 行：constraint 解析正确'
assert_equal 'kernel-memcg' "$(last_oom_field layer)" 'oom-kill 行：CONSTRAINT_MEMCG → layer=kernel-memcg'

new_case kernel-oomkill-global
add_kernel_entry 'oom-kill:constraint=CONSTRAINT_NONE,nodemark=0,oom_memcg=/user.slice/user-1000.slice/user@1000.service/app.slice/run-p24156-i31266.scope,task=node-MainThread,pid=24159,uid=1000' \
    node-MainThread 24159
start_case_watcher CACHYOS_OOM_PSI_ENABLED=0
stop_case_watcher

assert_equal 'CONSTRAINT_NONE' "$(last_oom_field constraint)" '全局 OOM：constraint 解析正确'
assert_equal 'kernel-global' "$(last_oom_field layer)" 'CONSTRAINT_NONE → layer=kernel-global'

# ---- 3. 同一次 OOM 的两条内核消息：只提醒一次，rss 由第二条补 ------------------
# 内核先发 `oom-kill:`（无 rss），再发 `Memory cgroup out of memory:`（有 rss）。
# 两条的 (layer,pid,comm) 相同，去重键相同，所以只能有一条通知；但第二条更完整，
# 必须把 rss 补写进 last-oom，否则诊断拿不到「被杀时占了多少内存」。

new_case kernel-two-messages
add_kernel_entry 'oom-kill:constraint=CONSTRAINT_MEMCG,nodemark=1,oom_memcg=/user.slice/user-1000.slice/user@1000.service/app.slice/run-p24156-i31266.scope,task=node-MainThread,pid=24158,uid=1000' \
    node-MainThread 24158
add_kernel_entry 'Memory cgroup out of memory: Killed process 24158 (node-MainThread) total-vm:4536816kB, anon-rss:3138276kB, file-rss:30744kB, shmem-rss:0kB, UID:1000 pgtables:6784kB oom_score_adj:200' \
    node-MainThread 24158
start_case_watcher CACHYOS_OOM_PSI_ENABLED=0
stop_case_watcher

assert_equal '1' "$(notify_count)" '同一次 OOM 的两条内核消息只提醒一次'
assert_equal '3138276' "$(last_oom_field victim_rss_kb)" '第二条把 anon-rss 补进 last-oom'
# 两条消息分工：oom-kill 行带 constraint/oom_memcg，Memory cgroup 行带 anon-rss。补写 rss
# 时若整表覆写，会把前者的权威字段擦成空值——这里回归 record_oom 的「已有值优先」合并。
assert_equal '/user.slice/user-1000.slice/user@1000.service/app.slice/run-p24156-i31266.scope' \
    "$(last_oom_field memcg)" '第二条补写 rss 时不擦掉第一条的 memcg'
assert_equal 'CONSTRAINT_MEMCG' "$(last_oom_field constraint)" '第二条补写 rss 时不擦掉第一条的 constraint'

# ---- 4. systemd-oomd 预警 "Marked ... for killing"：提醒但不写 last-oom -------
# 这时还没有受害者，记下来的会是仍正常运行的 unit，反而误导诊断——所以只提醒。

new_case oomd-marked
add_oomd_entry 'Marked /user.slice/user-1000.slice/user@1000.service/app.slice/app-org.kde.konsole-1234.scope/kitty-5467-1.scope for killing due to memory used (31602503680) / total (32751992832) and swap used (60472098816) / total (67110952960) being more than 90.00%'
start_case_watcher CACHYOS_OOM_PSI_ENABLED=0
stop_case_watcher

assert_equal '1' "$(notify_count)" 'oomd 预警（Marked）会发提醒'
if last_oom_exists; then
    fail 'oomd 预警阶段不该写 last-oom（还没有受害者）' "$(cat "$(last_oom_file)")"
else
    pass 'oomd 预警阶段不写 last-oom'
fi

# ---- 5. systemd-oomd 最终动作：unit 必须剥掉 ": " 与尾空格 ---------------------
# 曾经的 bug：用 `${cg%%:}` 只去掉一个冒号，留下 "kitty-5467-1.scope: "（带尾空格），
# 拿它去拼 /sys/fs/cgroup 路径必然查不到。extglob 的 +([[:space:]:]) 才是对的。

new_case oomd-killed
add_oomd_entry 'kitty-5467-1.scope: systemd-oomd killed 11 process(es) in this unit.'
start_case_watcher CACHYOS_OOM_PSI_ENABLED=0
stop_case_watcher

assert_equal 'oomd' "$(last_oom_field layer)" 'oomd 最终动作：layer=oomd'
assert_equal 'kitty-5467-1.scope' "$(last_oom_field unit)" 'oomd 最终动作：unit 无 ": "、无尾空格'
assert_equal 'kitty-5467-1.scope' "$(last_oom_field marked_cg)" 'oomd 最终动作：marked_cg 同样干净'
assert_equal '1' "$(notify_count)" 'oomd 最终动作会发一条提醒'

# ---- 6. PSI 提前预警：full avg60 超阈值就落 psi 记录 ---------------------------
# 用 CACHYOS_OOM_PSI_FILE 指向合成文件，间隔压到 1 秒。full avg60=42.5 > 阈值 10。

new_case psi
printf 'some avg10=0.00 avg60=0.04 avg300=0.81 total=101305079\nfull avg10=8.00 avg60=42.5 avg300=20.00 total=97015271\n' \
    > "$CASE_DIR/pressure-memory"
start_case_watcher \
    CACHYOS_OOM_PSI_ENABLED=1 \
    CACHYOS_OOM_PSI_FILE="$CASE_DIR/pressure-memory" \
    CACHYOS_OOM_PSI_FULL_AVG60=10 \
    CACHYOS_OOM_PSI_INTERVAL_SECONDS=1
stop_case_watcher

assert_equal 'psi' "$(last_oom_field layer)" 'PSI full avg60 超阈值：layer=psi'
assert_equal '42.5' "$(last_oom_field psi_full_avg60)" 'PSI：psi_full_avg60 落盘为 42.5'
assert_equal '1' "$(notify_count)" 'PSI 超阈值发一条提醒'

# ---- 7. 静音名单复用崩溃链路的 crash-muted.txt -------------------------------
# OOM 与崩溃共用一份名单（cachyos-crash-mute 维护），一致才不用维护两个开关。

new_case muted
mkdir -p "$(case_agents_dir)"
printf 'node-MainThread\n' > "$(case_agents_dir)/crash-muted.txt"
add_kernel_entry 'Memory cgroup out of memory: Killed process 24158 (node-MainThread) total-vm:4536816kB, anon-rss:3138276kB, file-rss:30744kB, shmem-rss:0kB, UID:1000 pgtables:6784kB oom_score_adj:200' \
    node-MainThread 24158
start_case_watcher CACHYOS_OOM_PSI_ENABLED=0
stop_case_watcher

assert_equal '0' "$(notify_count)" '静音名单里的程序不再提醒'
if last_oom_exists; then
    fail '静音的程序不该写 last-oom' "$(cat "$(last_oom_file)")"
else
    pass '静音的程序不写 last-oom'
fi

# ---- 8. 去重窗口：同一 victim 的重复消息只提醒一次 ---------------------------
# 去重键是 (layer,pid,comm)：同一次事件被内核重复打印（或 watcher 重连带出旧行）时，
# 300 秒窗口内只提醒一次，避免 OOM 风暴刷屏。
# 注意键里含 pid（bin/cachyos-oom-watch 的 dedupe_key 调用）。实测「同 comm、pid 不同」的
# 两条消息会提醒两次；任务第 8 条若原意是「pid 不同也只提醒一次」，则与实现不符——属于
# 契约分歧，已如实报给 lead，不在这里把实现或断言改绿。本用例只断言无歧义的那半：
# 完全相同的重复消息（同 pid）在窗口内只提醒一次。

new_case dedupe
repeat_message='Memory cgroup out of memory: Killed process 24160 (node-MainThread) total-vm:4536816kB, anon-rss:3138276kB, file-rss:30744kB, shmem-rss:0kB, UID:1000 pgtables:6784kB oom_score_adj:200'
add_kernel_entry "$repeat_message" node-MainThread 24160
add_kernel_entry "$repeat_message" node-MainThread 24160
start_case_watcher CACHYOS_OOM_PSI_ENABLED=0 CACHYOS_OOM_DEDUPE_SECONDS=300
stop_case_watcher

assert_equal '1' "$(notify_count)" '300 秒去重窗口内同一 victim 只提醒一次'

# ---- 9. journalctl 调用形态：不允许 -n 0 -------------------------------------
# 本机 systemd 262 实测：`-f -n 0` 与任何过滤条件组合都静默返回 0 行。watcher 必须用
# `-f -n 1` + 时间戳水位。注意源码注释里**故意写着** "-f -n 0" 来解释这个坑，所以要先
# 剥掉注释行再断言，否则会被自己的注释绊倒。

code_only="$(grep -vE '^[[:space:]]*#' "$WATCHER")"
if grep -q -- '-n 0' <<<"$code_only"; then
    fail 'watcher 的代码里出现 -n 0（systemd 262 上会静默收不到任何日志）'
else
    pass 'watcher 代码里没有 -n 0'
fi
if grep -q -- '-f -n 1' <<<"$code_only"; then
    pass 'watcher 用 -f -n 1 跟随'
else
    fail 'watcher 没有用 -f -n 1 跟随'
fi

# ---- 10. cachyos-agent-oom：无记录要可操作，有记录要把事实拼进 prompt ---------

agent_case="$WORK_DIR/agent-case"
mkdir -p "$agent_case/bin" "$agent_case/nohome"
cat > "$agent_case/bin/cachyos-agent" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$agent_case/agent-calls"
exit 0
STUB
for stub_name in systemctl systemd-cgtop cachyos-agent-oom; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$agent_case/bin/$stub_name"
done
chmod +x "$agent_case/bin"/*

# 10a) 没有 last-oom：必须非 0 退出，并说清「怎么查 watcher」。
set +e
no_record_out="$(HOME="$agent_case/nohome" \
    CACHYOS_DESKTOP_SHARE_DIR="$agent_case/no-share" \
    PATH="$agent_case/bin:$PATH" \
    bash "$AGENT_OOM" --latest 2>&1)"
no_record_status=$?
set -e

if ((no_record_status != 0)); then
    pass '没有 last-oom 时 cachyos-agent-oom 退出非 0'
else
    fail '没有 last-oom 时不该返回成功' "output: $no_record_out"
fi
if [[ $no_record_out == *cachyos-oom-watch* ]]; then
    pass '无记录时提示怎么检查 watcher 是否在跑'
else
    fail '无记录时缺少可操作提示' "output: $no_record_out"
fi

# 10b) 有 last-oom：事实（layer / victim_comm）与 diagnose-oom skill 路径都要进 prompt。
mkdir -p "$agent_case/home/.local/state/cachyos-desktop/agents"
cat > "$agent_case/home/.local/state/cachyos-desktop/agents/last-oom" <<'RECORD'
time=2026-10-14 09:28:00
layer=kernel-memcg
victim_pid=24158
victim_comm=node-MainThread
victim_rss_kb=3138276
memcg=/user.slice/user-1000.slice/user@1000.service/app.slice/run-p24156-i31266.scope
unit=
constraint=CONSTRAINT_MEMCG
marked_cg=
psi_full_avg60=
RECORD
: > "$agent_case/agent-calls"

HOME="$agent_case/home" \
    CACHYOS_DESKTOP_SHARE_DIR="$agent_case/no-share" \
    PATH="$agent_case/bin:$PATH" \
    bash "$AGENT_OOM" --latest > "$agent_case/agent-oom.log" 2>&1

agent_prompt="$(cat "$agent_case/agent-calls")"
if grep -q -- '--prompt' "$agent_case/agent-calls"; then
    pass '有记录时通过 cachyos-agent --prompt 交给 agent'
else
    fail '没有把 prompt 交给 cachyos-agent' "log: $(cat "$agent_case/agent-oom.log")"
fi
if [[ $agent_prompt == *'layer=kernel-memcg'* || $agent_prompt == *'kernel-memcg'* ]]; then
    pass 'prompt 里带触发来源 layer'
else
    fail 'prompt 里没有 layer' "prompt: $agent_prompt"
fi
if [[ $agent_prompt == *node-MainThread* ]]; then
    pass 'prompt 里带受害者 victim_comm'
else
    fail 'prompt 里没有 victim_comm' "prompt: $agent_prompt"
fi
if [[ $agent_prompt == *'assets/agent-skills/diagnose-oom/SKILL.md'* ]]; then
    pass 'prompt 里带 diagnose-oom skill 路径'
else
    fail 'prompt 里没有 diagnose-oom skill 路径' "prompt: $agent_prompt"
fi

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
