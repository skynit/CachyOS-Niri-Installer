#!/usr/bin/env bash

# 用量采集的回归测试。
#
# 全部基于合成 fixture（临时 HOME），不读用户真实转录，也不联网：
#   1. 总 token 必须是"四项之和"，且按事件时间戳归属到本地日期
#   2. Codex 必须用 last_token_usage（单轮增量），不能用 total_token_usage（会话累计）
#   3. Codex 的 session_meta 在**行顶层** type 上，漏看会让会话数与模型全错
#   4. 首次运行与命中缓存必须给出**完全相同**的结果（曾因只在缓存分支合并模型而分叉）

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
YESTERDAY="$(date -d yesterday +%F 2>/dev/null || date -v-1d +%F)"
TODAY_TS="${TODAY}T10:00:05+08:00"
YESTERDAY_TS="${YESTERDAY}T10:00:05+08:00"

HOME_DIR="$WORK_DIR/home"
mkdir -p "$HOME_DIR/.claude/projects/demo" "$HOME_DIR/.codex/sessions/2026/01/01"

# ---- Claude fixture：两条 assistant（今天/昨天）+ 一条 user prompt --------------
cat > "$HOME_DIR/.claude/projects/demo/session.jsonl" <<JSONL
{"type":"user","sessionId":"S1","timestamp":"${TODAY}T10:00:00+08:00","message":{"role":"user","content":"你好"}}
{"type":"assistant","sessionId":"S1","timestamp":"${TODAY_TS}","message":{"model":"model-one","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":1}}}
{"type":"assistant","sessionId":"S1","timestamp":"${YESTERDAY_TS}","message":{"model":"model-two","usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JSONL

# ---- Codex fixture：session_meta 在行顶层；total 远大于增量之和 ------------------
cat > "$HOME_DIR/.codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-demo.jsonl" <<JSONL
{"timestamp":"${TODAY}T11:00:00+08:00","ordinal":0,"type":"session_meta","payload":{"session_id":"C1","cwd":"/tmp","model":"gpt-test"}}
{"timestamp":"${TODAY}T11:00:01+08:00","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
{"timestamp":"${TODAY_TS}","ordinal":2,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999999,"output_tokens":888888},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":50,"cache_write_input_tokens":0}}}}
{"timestamp":"${YESTERDAY_TS}","ordinal":3,"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":3,"cache_write_input_tokens":0}}}}
JSONL

run_collector() {
    local name="$1"
    shift
    HOME="$HOME_DIR" \
        XDG_CACHE_HOME="$HOME_DIR/.cache" \
        CACHYOS_DESKTOP_SHARE_DIR="$WORK_DIR/no-share" \
        "$PROJECT_DIR/bin/$name" "$@" 2>/dev/null
}

field() { jq -r "$1" <<<"$2"; }

# ---- Claude ---------------------------------------------------------------
claude="$(run_collector cachyos-agent-usage-claude --force)"
assert_equal 'claude' "$(field '.id' "$claude")" 'claude：记录 id 正确'
assert_equal '116' "$(field '.stats.todayTotalTokens' "$claude")" 'claude：今天的总 token = 四项之和'
assert_equal '116' "$(field '.stats.todayTokensByModel["model-one"]' "$claude")" 'claude：按模型归属今天用量'
assert_equal '336' "$(field '.stats.totalPrompts, (.stats.modelUsage | to_entries | map(.value.totalTokens) | add)' "$claude" | tail -1)" \
    'claude：模型总计 = 116 + 220'
assert_equal '1' "$(field '.stats.totalSessions' "$claude")" 'claude：会话数按 sessionId 去重'
assert_equal '1' "$(field '.stats.totalPrompts' "$claude")" 'claude：user 消息计为 1 个 prompt'

claude_cached="$(run_collector cachyos-agent-usage-claude)"
assert_equal "$(field '.stats' "$claude")" "$(field '.stats' "$claude_cached")" \
    'claude：首次运行与命中缓存结果一致'

# ---- Codex ----------------------------------------------------------------
codex="$(run_collector cachyos-agent-usage-codex --force)"
assert_equal 'codex' "$(field '.id' "$codex")" 'codex：记录 id 正确'
assert_equal '1150' "$(field '.stats.todayTotalTokens' "$codex")" \
    'codex：今天用量取自 last_token_usage（1000+100+50），不是 total_token_usage'
assert_equal '1' "$(field '.stats.totalSessions' "$codex")" 'codex：session_meta 在行顶层也能被识别'
assert_equal 'gpt-test' "$(field '.stats.modelUsage | keys[0]' "$codex")" 'codex：模型取自 session_meta'
assert_equal '1' "$(field '.stats.totalPrompts' "$codex")" 'codex：task_started 计为 1 个 prompt'
# recentDays 是"从旧到新、最后一项是今天"；按日期查找而不是按下标，不依赖顺序细节。
# jq 程序放进变量，避免 shellcheck 把 jq 里的 $d 当成未展开的 shell 变量。
# shellcheck disable=SC2016  # 这里的 $d 是 jq 的变量，由 --arg 注入，不是 shell 变量
day_tokens_query='[.stats.recentDays[] | select(.date==$d)][0].totalTokens'
assert_equal '10' "$(jq -r --arg d "$YESTERDAY" "$day_tokens_query" <<<"$codex")" 'codex：昨天用量归属到昨天'
assert_equal '1150' "$(jq -r --arg d "$TODAY" "$day_tokens_query" <<<"$codex")" 'codex：今天用量归属到今天'
assert_equal "$TODAY" "$(field '.stats.recentDays[-1].date' "$codex")" 'codex：recentDays 最后一项是今天'
assert_equal '7' "$(field '.stats.recentDays | length' "$codex")" 'codex：recentDays 固定为 7 天'

codex_cached="$(run_collector cachyos-agent-usage-codex)"
assert_equal "$(field '.stats' "$codex")" "$(field '.stats' "$codex_cached")" \
    'codex：首次运行与命中缓存结果一致'

# ---- 编排器 ----------------------------------------------------------------
if HOME="$HOME_DIR" XDG_CACHE_HOME="$HOME_DIR/.cache" PATH="$PROJECT_DIR/bin:$PATH" \
    "$PROJECT_DIR/bin/cachyos-agent-usage-update" >/dev/null 2>&1; then
    pass '编排器：两个采集器都成功'
else
    fail '编排器执行失败'
fi
for agent in claude codex; do
    record="$HOME_DIR/.local/state/cachyos-desktop/agents/usage/$agent.json"
    if [[ -s $record ]] && jq -e '.schemaVersion == 1 and (.stats|type=="object")' "$record" >/dev/null 2>&1; then
        pass "编排器：$agent 记录已原子落盘且 JSON 合法"
    else
        fail "编排器：$agent 记录缺失或非法"
    fi
done

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
