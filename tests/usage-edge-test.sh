#!/usr/bin/env bash

# 用量采集的边界回归。
#
# 这些场景都是独立评审在**真实数据**上发现的，而原来的测试全部漏掉了：
#   1. 同一条 API 消息被按 content block 写了多行（同 message.id）→ 只能算一次
#   2. Codex 重复发出的 token_count 快照（total 没前进）→ 必须跳过
#   3. 读不了的文件不能被缓存成"0 条"，否则错误会一直留着
#   4. 单个畸形的 token 字段不能让整次采集崩掉
#   5. 限额端点返回意外结构时不能拖垮本地统计

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

TODAY="$(date +%F)"
readonly OFFSET="$(date +%:z)"

run_collector() {
    local name="$1"
    shift
    HOME="$WORK_DIR/home" \
        XDG_CACHE_HOME="$WORK_DIR/cache" \
        CACHYOS_DESKTOP_SHARE_DIR="$WORK_DIR/no-share" \
        "$PROJECT_DIR/bin/$name" "$@" 2>/dev/null
}
field() { jq -r "$1" <<<"$2"; }

mkdir -p "$WORK_DIR/home/.claude/projects/demo" "$WORK_DIR/home/.codex/sessions/2026/01/01"

# ---- 1. 同一条消息按 content block 写多行 → 只算一次 ---------------------------
# 真实转录就是这样：thinking / text / tool_use 各一行，每行都带同一份完整 usage。
cat > "$WORK_DIR/home/.claude/projects/demo/dedup.jsonl" <<JSONL
{"type":"assistant","sessionId":"S1","timestamp":"${TODAY}T10:00:00${OFFSET}","message":{"id":"msg-1","content":[{"type":"thinking"}],"model":"m","usage":{"input_tokens":1000,"output_tokens":100}}}
{"type":"assistant","sessionId":"S1","timestamp":"${TODAY}T10:00:01${OFFSET}","message":{"id":"msg-1","content":[{"type":"text"}],"model":"m","usage":{"input_tokens":1000,"output_tokens":100}}}
{"type":"assistant","sessionId":"S1","timestamp":"${TODAY}T10:00:02${OFFSET}","message":{"id":"msg-2","content":[{"type":"text"}],"model":"m","usage":{"input_tokens":7,"output_tokens":3}}}
JSONL
claude="$(run_collector cachyos-agent-usage-claude --force)"
# 去重后 = 1100 + 10 = 1110；不去重会是 1100 + 1100 + 10 = 2210
assert_equal '1110' "$(field '.stats.todayTotalTokens' "$claude")" \
    'Claude：同 message.id 的多行只算一次（按 content block 重复的 usage 不算第二遍）'

# ---- 2. Codex 重复快照（total 没前进）→ 跳过 -----------------------------------
cat > "$WORK_DIR/home/.codex/sessions/2026/01/01/rollout-repeat.jsonl" <<JSONL
{"timestamp":"${TODAY}T11:00:00${OFFSET}","ordinal":0,"type":"session_meta","payload":{"session_id":"C1","model":"gpt-test"}}
{"timestamp":"${TODAY}T11:00:01${OFFSET}","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"output_tokens":500,"total_tokens":5500},"last_token_usage":{"input_tokens":1000,"output_tokens":100}}}}
{"timestamp":"${TODAY}T11:00:30${OFFSET}","ordinal":2,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"output_tokens":500,"total_tokens":5500},"last_token_usage":{"input_tokens":1000,"output_tokens":100}}}}
{"timestamp":"${TODAY}T11:01:00${OFFSET}","ordinal":3,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":6000,"output_tokens":600,"total_tokens":6600},"last_token_usage":{"input_tokens":900,"output_tokens":90}}}}
JSONL
codex="$(run_collector cachyos-agent-usage-codex --force)"
# 1100 + 990 = 2090；不跳过重复快照会是 1100 + 1100 + 990 = 3190
assert_equal '2090' "$(field '.stats.todayTotalTokens' "$codex")" \
    'Codex：total 没有前进的重复快照被跳过'

# ---- 3. 读不了的文件不能被缓存成 0 --------------------------------------------
rm -rf "$WORK_DIR/cache"
unreadable="$WORK_DIR/home/.claude/projects/demo/dedup.jsonl"
chmod 000 "$unreadable"
run_collector cachyos-agent-usage-claude >/dev/null 2>&1
chmod 644 "$unreadable"
cached_after_fix="$(run_collector cachyos-agent-usage-claude)"
assert_equal '1110' "$(field '.stats.todayTotalTokens' "$cached_after_fix")" \
    '读取失败的文件没有被缓存成 0（恢复权限后立刻读数正确）'

# ---- 4. 畸形的 token 字段不能让采集器崩 --------------------------------------
cat > "$WORK_DIR/home/.claude/projects/demo/broken.jsonl" <<JSONL
{"type":"assistant","sessionId":"S2","timestamp":"${TODAY}T12:00:00${OFFSET}","message":{"id":"bad-1","model":"m","usage":{"input_tokens":"not-a-number","output_tokens":5}}}
JSONL
if run_collector cachyos-agent-usage-claude --force >/dev/null 2>&1; then
    pass '畸形的 token 字段不会让采集器崩溃（退出码 0）'
else
    fail '畸形的 token 字段让采集器崩了'
fi

# ---- 5. 限额端点载荷健壮性（直接测解析函数）----------------------------------
if python3 - "$PROJECT_DIR" <<'PY'
import sys
from pathlib import Path
project = Path(sys.argv[1])
sys.path.insert(0, str(project / "assets" / "lib"))
ns = {"__name__": "probe", "__file__": str(project / "bin" / "cachyos-agent-usage-claude")}
exec(compile((project / "bin" / "cachyos-agent-usage-claude").read_text(encoding="utf-8"), "collector", "exec"), ns)
parse = ns["limits_from_payload"]
for payload in (["list"], "string", None, 42, {"five_hour": {"utilization": "abc"}},
                {"five_hour": {"utilization": {"x": 1}}}, {"plan": {"nested": True}}):
    parse(payload)  # 任何载荷都不该抛异常
limits, tier, _ = parse({"five_hour": {"utilization": 0.25}, "plan": "Max"})
assert limits and abs(limits[0]["percent"] - 25.0) < 0.001, limits
assert tier == "Max", tier
PY
then
    pass '限额端点返回任意结构都不抛异常，且正常载荷解析正确'
else
    fail '限额载荷解析不健壮'
fi

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
