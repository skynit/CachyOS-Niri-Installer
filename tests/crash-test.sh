#!/usr/bin/env bash

# 崩溃记录解析与静音的回归测试。
#
# 不依赖真实崩溃：用 stub journalctl 喂合成条目，因此可以在任何机器上跑。
# 这里盯的是两条真实踩过的坑：
#   1. 分隔符用制表符时，缺失字段会被 read 折叠，后面的列整体错位
#   2. 内核把 comm 截到 15 字节，静音名单不跟着截断就永远匹配不上

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR

PASS_COUNT=0
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

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

# 用一条合成 coredump 记录跑一次 watcher，回显它写下的 last-crash 内容。
crash_record_for() {
    local entry="$1"
    local case_dir
    case_dir="$(mktemp -d "$WORK_DIR/case.XXXXXX")"
    mkdir -p "$case_dir/home" "$case_dir/bin"

    printf '%s\n' "$entry" > "$case_dir/entries.jsonl"

    # stub journalctl：把合成条目吐出来一次，然后挂住（让 watcher 停在"跟随中"）。
    cat > "$case_dir/bin/journalctl" <<STUB
#!/usr/bin/env bash
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
    local watcher=$!
    sleep 3
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    cat "$case_dir/home/.local/state/cachyos-desktop/agents/last-crash" 2>/dev/null || true
}

# ---- 字段解析：缺失字段不能让后面的列错位 ------------------------------------

normal_record="$(crash_record_for '{"COREDUMP_PID":"900001","COREDUMP_COMM":"cwnA","COREDUMP_EXE":"/usr/bin/cwnA","COREDUMP_SIGNAL":"11"}')"
assert_equal '900001' "$(sed -n 's/^pid=//p' <<<"$normal_record")" '完整记录：pid 正确'
assert_equal 'cwnA' "$(sed -n 's/^comm=//p' <<<"$normal_record")" '完整记录：comm 正确'
assert_equal '/usr/bin/cwnA' "$(sed -n 's/^exe=//p' <<<"$normal_record")" '完整记录：exe 正确'
assert_equal '11' "$(sed -n 's/^signal=//p' <<<"$normal_record")" '完整记录：signal 正确'

# 缺 EXE：制表符 IFS 会把空字段折掉，signal 会顶到 exe 上。
missing_exe_record="$(crash_record_for '{"COREDUMP_PID":"900002","COREDUMP_COMM":"cwnB","COREDUMP_SIGNAL":"11"}')"
assert_equal '' "$(sed -n 's/^exe=//p' <<<"$missing_exe_record")" '缺 EXE 时 exe 为空，不吃掉 signal'
assert_equal '11' "$(sed -n 's/^signal=//p' <<<"$missing_exe_record")" '缺 EXE 时 signal 仍落在 signal 列'

# 缺 PID：错位会让 comm 顶到 pid 列，进而让"点击诊断"拿到非数字 PID 被拒。
missing_pid_record="$(crash_record_for '{"COREDUMP_COMM":"cwnC","COREDUMP_EXE":"/usr/bin/cwnC","COREDUMP_SIGNAL":"6"}')"
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

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
