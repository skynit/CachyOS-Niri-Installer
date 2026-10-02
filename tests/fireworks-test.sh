#!/usr/bin/env bash

# Fireworks 采集器的回归测试。
#
# 用本地 stub 服务器模拟 Fireworks 的 REST API，因此**不需要真实账号**也能验证整条链路：
# 账号发现、billingUsage 翻页、按天/模型聚合、余额估算、以及凭据缺失时的降级。
#
# 这些正是"看起来对、实际不生效"的高发区：不跑一遍真实 HTTP 往返，就只是在读代码。

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR

PASS_COUNT=0
WORK_DIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

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

PORT_FILE="$WORK_DIR/port"
cat > "$WORK_DIR/stub.py" <<'PY'
"""Fireworks API 的极简替身：两个账号端点 + 两页 billingUsage + usageCosts。"""
import datetime as dt, http.server, json, socketserver, sys, urllib.parse

today = dt.datetime.now().astimezone().date().isoformat()
yesterday = (dt.datetime.now().astimezone().date() - dt.timedelta(days=1)).isoformat()

PAGE_ONE = [{"startTime": f"{today}T10:00:00", "group": {"model_name": "m-one"},
             "promptTokens": 1000, "cachedPromptTokens": 200, "completionTokens": 50,
             "modelName": "m-one"}]
PAGE_TWO = [{"startTime": f"{today}T11:00:00", "group": {"model_name": "m-two"},
             "promptTokens": 300, "cachedPromptTokens": 0, "completionTokens": 20,
             "modelName": "m-two"},
            {"startTime": f"{yesterday}T11:00:00", "group": {"model_name": "m-one"},
             "promptTokens": 7, "cachedPromptTokens": 0, "completionTokens": 3,
             "modelName": "m-one"}]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == "/v1/accounts":
            return self._send({"accounts": [{"name": "accounts/test-acct"}]})
        if parsed.path == "/v1/accounts/test-acct/billingUsage":
            if query.get("pageToken"):
                return self._send({"serverlessCosts": PAGE_TWO})
            return self._send({"serverlessCosts": PAGE_ONE, "nextPageToken": "page-2"})
        return self._send({"error": "not found"}, 404)

    def do_POST(self):
        if self.path.startswith("/v1/accounts/test-acct/usageCosts:query"):
            return self._send({"totalCost": {"units": "3", "nanos": 500000000}})
        return self._send({"error": "not found"}, 404)

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    with open(sys.argv[1], "w") as handle:
        handle.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
python3 "$WORK_DIR/stub.py" "$PORT_FILE" &
SERVER_PID=$!
for _ in $(seq 1 40); do
    [[ -s $PORT_FILE ]] && break
    sleep 0.1
done
[[ -s $PORT_FILE ]] || fail "stub 服务器没起来"
PORT="$(cat "$PORT_FILE")"

mkdir -p "$WORK_DIR/home"
run_collector() {
    HOME="$WORK_DIR/home" \
        XDG_CONFIG_HOME="$WORK_DIR/home/.config" \
        XDG_CACHE_HOME="$WORK_DIR/home/.cache" \
        CACHYOS_DESKTOP_CONFIG_DIR="$WORK_DIR/home/.config/cachyos-desktop" \
        CACHYOS_DESKTOP_SHARE_DIR="$WORK_DIR/no-share" \
        FIREWORKS_API_KEY="test-key" \
        FIREWORKS_API_BASE="http://127.0.0.1:$PORT" \
        CC_SWITCH_DB="$WORK_DIR/no-db" \
        "$PROJECT_DIR/bin/cachyos-agent-usage-fireworks" "$@" 2>/dev/null
}
field() { jq -r "$1" <<<"$2"; }

record="$(run_collector)"
[[ -n $record ]] || fail "采集器没有输出（stub 服务器路径失败）"

assert_equal 'fireworks' "$(field '.id' "$record")" '记录 id 正确'
assert_equal 'true' "$(field '.ready' "$record")" '有数据时 ready=true'
assert_equal 'inclusive' "$(field '.inputTokenSemantics' "$record")" 'token 语义标为 inclusive'

# 今天 = (1000+50) + (300+20) = 1370；昨天的 10 不应混进来
assert_equal '1370' "$(field '.stats.todayTotalTokens' "$record")" \
    '今天用量正确（promptTokens 已含缓存，不再单独加）'
# 翻页：第二页的两行必须被算进来
assert_equal '1380' "$(field '[.stats.modelUsage[].totalTokens] | add' "$record")" \
    '两页数据都被聚合（不是只读了第一页）'
assert_equal '1060' "$(field '.stats.modelUsage["m-one"].totalTokens' "$record")" \
    '模型归属正确（m-one = 1050 + 10）'
assert_equal '320' "$(field '.stats.modelUsage["m-two"].totalTokens' "$record")" \
    '模型归属正确（m-two = 320）'
assert_equal '10' "$(field '[.stats.recentDays[] | select(.date != "" and .totalTokens == 10)][0].totalTokens' "$record")" \
    '昨天的用量归到昨天'

# 没有配置额度时不该编一个余额出来
assert_equal '' "$(field '.tierLabel' "$record")" '未配置额度时不编造余额'

# 配置额度后应给出估算余额：5 - 3.5 = 1.5
mkdir -p "$WORK_DIR/home/.config/cachyos-desktop/agents"
printf '%s\n' '{"credits": 5}' > "$WORK_DIR/home/.config/cachyos-desktop/agents/fireworks.json"
record2="$(run_collector)"
assert_equal '约 $1.50 可用' "$(field '.tierLabel' "$record2")" '余额 = 配置额度 - 已花费（3.5）'

# 没有凭据时必须降级而不是崩：退出码 0，明确说明，不编造数字
noauth="$(HOME="$WORK_DIR/home" XDG_CONFIG_HOME="$WORK_DIR/home/.config" \
    CACHYOS_DESKTOP_CONFIG_DIR="$WORK_DIR/home/.config/cachyos-desktop" \
    CACHYOS_DESKTOP_SHARE_DIR="$WORK_DIR/no-share" \
    "$PROJECT_DIR/bin/cachyos-agent-usage-fireworks" 2>/dev/null)"
assert_equal 'false' "$(field '.ready' "$noauth")" '无凭据时 ready=false（不编造用量）'
[[ $(field '.usageStatusText' "$noauth") == *FIREWORKS_API_KEY* ]] \
    && pass '无凭据时给出可执行的下一步' || fail '无凭据时没有说明怎么办'

# API 报错（401）也要降级成说明，而不是崩溃
badkey="$(HOME="$WORK_DIR/home" CACHYOS_DESKTOP_CONFIG_DIR="$WORK_DIR/home/.config/cachyos-desktop" \
    CACHYOS_DESKTOP_SHARE_DIR="$WORK_DIR/no-share" FIREWORKS_API_KEY=x \
    FIREWORKS_API_BASE="http://127.0.0.1:1" \
    "$PROJECT_DIR/bin/cachyos-agent-usage-fireworks" 2>/dev/null)"
[[ -n $badkey ]] && pass 'API 不可达时仍有合法输出（降级而非崩溃）' || fail 'API 不可达时没有输出'

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
