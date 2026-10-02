#!/usr/bin/env bash

# DSH（DeepSeek Harness）采集器的回归测试。
#
# 会话是 zstd 压缩的事件流，本机同时存在 v4 / v2 / v0 三种格式。这里用 fixture 覆盖：
#   1. v4 的计数与 token 语义（input 不含缓存读，总额要单独加）
#   2. v0 的 reasoningTokens 不能重复计入（它已含在 outputTokens 里）
#   3. 只把 source.kind == "user" 的消息算成 prompt（合成条目要排除）
#   4. **命中缓存与全量重扫结果一致**——包括"有会话但没有任何用量事件"的文件
#      （这里曾经漏算会话，是真实 bug 的回归）
#   5. 半截/损坏的 zstd 文件不能被固化成结果
#   6. 模型名在 v0 里走回退路径也能取到

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

command -v zstd >/dev/null 2>&1 || { printf 'skipped: 需要 zstd\n'; exit 0; }

TODAY="$(date +%F)"
OFFSET="$(date +%:z)"
export XDG_CACHE_HOME="$WORK_DIR/cache"
# 每个用例一个独立 HOME：共用会让"加一个 fixture"悄悄改变别处断言的期望值（第一次就踩了）。
HOME_V4="$WORK_DIR/home-v4"
HOME_V0="$WORK_DIR/home-v0"
HOME_CACHE="$WORK_DIR/home-cache"
HOME_BROKEN="$WORK_DIR/home-broken"
HOME_EMPTY="$WORK_DIR/home-empty"

# 事件时间用 epoch 毫秒（DSH 的真实格式），由本机时区的今天 10:00 换算而来
today_ms() { date -d "${TODAY}T10:00:00${OFFSET}" +%s%3N 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "${TODAY}T10:00:00${OFFSET}" +%s000; }
TODAY_MS="$(today_ms)"
YESTERDAY_MS="$((TODAY_MS - 86400000))"

# 建一个会话：$1=HOME，$2=目录名，内容从 stdin 读
make_session() {
    local home="$1" dir="$2"
    mkdir -p "$home/sessions/ws/$dir"
    zstd -q -f -o "$home/sessions/ws/$dir/session.v4.jsonl.zstd" -
}

# 在指定 HOME 里跑采集器：$1=HOME，其余为参数
run_in() {
    local home="$1"
    shift
    DSH_HOME="$home" PATH="$PROJECT_DIR/bin:$PATH" \
        "$PROJECT_DIR/bin/cachyos-agent-usage-dsh" "$@" 2>/dev/null
}
field() { jq -r "$1" <<<"$2"; }

# ---- 1. v4：两份会话，含缓存读与合成消息 --------------------------------------
make_session "$HOME_V4" session-aaaa <<JSONL
{"type":"session","version":4,"id":"session-aaaa","createdAt":${TODAY_MS},"cwd":"/home/user/proj"}
{"type":"user/message","seq":1,"time":${TODAY_MS},"data":{"role":"user","content":[{"type":"text","text":"真正的输入"}],"source":{"kind":"user"}}}
{"type":"user/message","seq":2,"time":${TODAY_MS},"data":{"role":"user","content":[{"type":"text","text":"<system-reminder>合成条目</system-reminder>"}],"source":{"kind":"system"}}}
{"type":"assistant/message","seq":3,"time":${TODAY_MS},"data":{"usage":{"inputTokens":1000,"outputTokens":100,"cacheReadTokens":5000,"cacheWriteTokens":0,"totalTokens":6100},"message":{"role":"assistant","source":{"model":"deepseek-v4-flash"}}}}
{"type":"assistant/message","seq":4,"time":${YESTERDAY_MS},"data":{"usage":{"inputTokens":7,"outputTokens":3,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":10},"message":{"role":"assistant","source":{"model":"deepseek-v4-flash"}}}}
JSONL

# 一个有会话、但**既没有用量事件也没有真实 prompt** 的会话。
# 这才是真实数据里那 6 个文件的形状（只有会话元数据和工具调用）——它们的 perDay 是空的，
# 所以"命中缓存时只从 perDay 取会话"会把它们丢掉（真实 bug，会话数 41 → 37）。
# 注意：如果这个会话里放一条 prompt，它就会产生 perDay 条目，反而绕过了那个 bug。
make_session "$HOME_V4" session-bbbb <<JSONL
{"type":"session","version":4,"id":"session-bbbb","createdAt":${TODAY_MS},"cwd":"/home/user/proj"}
{"type":"tool/call","seq":1,"time":${TODAY_MS},"data":{"name":"read"}}
{"type":"tool/result","seq":2,"time":${TODAY_MS},"data":{"ok":true}}
JSONL

record="$(run_in "$HOME_V4" --force)"
# 今天 = (1000+5000+100) = 6100；昨天的 10 不混进来
assert_equal '6100' "$(field '.stats.todayTotalTokens' "$record")" \
    'v4：input 不含缓存读，总额 = input + 缓存读 + output'
assert_equal 'exclusive' "$(field '.inputTokenSemantics' "$record")" 'v4：token 语义标为 exclusive'
assert_equal '1' "$(field '.stats.totalPrompts' "$record")" '只把 source.kind == "user" 的消息算成 prompt（合成条目不算）'
assert_equal '2' "$(field '.stats.totalSessions' "$record")" '两个会话都算上（哪怕其中一个没有用量事件）'

# ---- 2. v0：reasoningTokens 已含在 output 里，不能重复加 -----------------------
make_session "$HOME_V0" session-cccc <<JSONL
{"type":"session","version":0,"id":"session-cccc","createdAt":${TODAY_MS},"cwd":"/home/user/proj"}
{"type":"assistant/message","seq":1,"time":${TODAY_MS},"data":{"turn":1,"step":1,"usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":20,"reasoningTokens":40},"message":{"role":"assistant","content":[{"type":"text","text":"x"}]},"model":"deepseek-v4-pro"}}
JSONL
v0="$(run_in "$HOME_V0" --force)"
assert_equal '170' "$(field '.stats.todayTotalTokens' "$v0")" \
    'v0：reasoning 不重复计入（100 + 20 + 50 = 170）'
assert_equal 'true' "$(field '.stats.modelUsage | has("deepseek-v4-pro")' "$v0")" \
    'v0：模型名走回退路径也能取到'

# ---- 3. 命中缓存必须与全量重扫一致（含无用量会话的回归）------------------------
rm -rf "$XDG_CACHE_HOME"
cold="$(run_in "$HOME_V4")"
hit="$(run_in "$HOME_V4")"
assert_equal "$(field '.stats' "$cold")" "$(field '.stats' "$hit")" \
    '命中缓存与冷跑结果逐字节一致（含会话数）'
assert_equal '2' "$(field '.stats.totalSessions' "$hit")" '命中缓存后会话数没有丢'

# ---- 4. 半截 zstd 不能被固化成结果 --------------------------------------------
broken="$HOME_BROKEN/sessions/ws/session-dddd"
mkdir -p "$broken"
printf 'not a zstd stream at all' > "$broken/session.v4.jsonl.zstd"
after_broken="$(run_in "$HOME_BROKEN")"
assert_equal '0' "$(field '.stats.todayTotalTokens' "$after_broken")" \
    '坏文件不会被算进统计（也不该崩）'

# 修好之后（同样的 mtime 之外内容变了），下一次运行必须能读到它
make_session "$HOME_BROKEN" session-dddd <<JSONL
{"type":"session","version":4,"id":"session-dddd","createdAt":${TODAY_MS},"cwd":"/home/user/proj"}
{"type":"assistant/message","seq":1,"time":${TODAY_MS},"data":{"usage":{"inputTokens":50,"outputTokens":5,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":55},"message":{"role":"assistant","source":{"model":"deepseek-v4-flash"}}}}
JSONL
recovered="$(run_in "$HOME_BROKEN")"
assert_equal '55' "$(field '.stats.todayTotalTokens' "$recovered")" \
    '文件变好后立刻被重新读取（坏结果没有被固化）'

# ---- 4b. 半截文件：不能崩、不能固化，且能读到的部分要算上 ----------------------
# 小文件的截断点会落在唯一的数据块内部，zstd 一个字节都解不出来（0 是合理结果）。
# 为了**确定性地**验证"能读到的部分要算上"，这里拼两个 zstd 帧：第一帧完整、第二帧截断。
trunc_home="$WORK_DIR/home-trunc"
frame_a="$WORK_DIR/frame-a.jsonl"
frame_b="$WORK_DIR/frame-b.jsonl"
cat > "$frame_a" <<JSONL
{"type":"session","version":4,"id":"session-eeee","createdAt":${TODAY_MS},"cwd":"/home/user/proj"}
{"type":"assistant/message","seq":1,"time":${TODAY_MS},"data":{"usage":{"inputTokens":10,"outputTokens":5,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":15},"message":{"role":"assistant","source":{"model":"m"}}}}
{"type":"assistant/message","seq":2,"time":${TODAY_MS},"data":{"usage":{"inputTokens":20,"outputTokens":5,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":25},"message":{"role":"assistant","source":{"model":"m"}}}}
JSONL
cat > "$frame_b" <<JSONL
{"type":"assistant/message","seq":3,"time":${TODAY_MS},"data":{"usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":150},"message":{"role":"assistant","source":{"model":"m"}}}}
{"type":"assistant/message","seq":4,"time":${TODAY_MS},"data":{"usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":150},"message":{"role":"assistant","source":{"model":"m"}}}}
JSONL
mkdir -p "$trunc_home/sessions/ws/session-eeee"
zstd -q -f -o "$WORK_DIR/a.zst" "$frame_a"
zstd -q -f -o "$WORK_DIR/b.zst" "$frame_b"
cat "$WORK_DIR/a.zst" > "$trunc_home/sessions/ws/session-eeee/session.v4.jsonl.zstd"
head -c "$(( $(stat -c%s "$WORK_DIR/b.zst") / 2 ))" "$WORK_DIR/b.zst" \
    >> "$trunc_home/sessions/ws/session-eeee/session.v4.jsonl.zstd"

truncated="$(run_in "$trunc_home")"
assert_equal '40' "$(field '.stats.todayTotalTokens' "$truncated")" \
    '半截文件：完整帧的部分被计入（40），不是整份丢掉'

# 补齐之后必须拿到完整值 340（40 + 300）——说明残片没有被固化进缓存
cat "$WORK_DIR/a.zst" "$WORK_DIR/b.zst" > "$trunc_home/sessions/ws/session-eeee/session.v4.jsonl.zstd"
after_full="$(run_in "$trunc_home")"
assert_equal '340' "$(field '.stats.todayTotalTokens' "$after_full")" \
    '补齐后半截文件被完整重算（残片没有被固化）'

# ---- 5. 没有会话目录时也要给出说明而不是崩 ------------------------------------
mkdir -p "$HOME_EMPTY"
empty_record="$(run_in "$HOME_EMPTY" || true)"
assert_equal 'false' "$(field '.ready' "$empty_record")" '没有会话目录时 ready=false'
[[ -n $(field '.usageStatusText' "$empty_record") ]] \
    && pass '没有会话目录时给出说明' || fail '没有会话目录时没有说明'

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
