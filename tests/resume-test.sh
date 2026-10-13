#!/usr/bin/env bash

# 跨工具会话续接（cachyos-agent-resume / cachyos-agent --resume）的回归测试。
#
# 全程用假 HOME 造出四个工具各自的会话存储，不碰真实会话、不打开窗口、不启动 agent。
# 盯的是这几件容易静默出错的事：
#   1. 四个工具的存储格式各不相同（claude 转录 / codex 索引 / opencode sqlite / dsh 缓存），
#      任何一处解析错都只会表现为"少了几行"，不会报错
#   2. 提示数必须排除工具结果行（claude 的 type=user 里混着 toolUseResult）
#   3. dsh 的时间要取"最后一条消息时间"，不能取缓存文件 mtime（DSH 启动会统一刷新它）
#   4. 空字段必须被填成占位符：按 TAB 读列时，IFS 空白会折叠空字段导致整行错位，
#      那会让"选中的会话"与"实际续接的 id"不一致
#   5. 续接语法逐 agent 校验（dsh 没有命令行续接，必须如实报错而不是拼出错误命令）

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

home="$WORK_DIR/home"
stub_dir="$WORK_DIR/bin"
mkdir -p "$stub_dir"
readonly STUB_LOG="$WORK_DIR/stub.log"
: > "$STUB_LOG"
export STUB_LOG

cat > "$stub_dir/stub-logger" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$stub_dir/stub-logger"
for name in kitty fzf dms notify-send; do
    ln -sf "$stub_dir/stub-logger" "$stub_dir/$name"
done

resume() { PATH="$stub_dir:$PATH" HOME="$home" "$PROJECT_DIR/bin/cachyos-agent-resume" "$@"; }

# 每行：agent <TAB> epoch <TAB> 目录 <TAB> 提示数 <TAB> 标题 <TAB> id
row_of() {
    local agent="$1" id="$2"
    resume --list 2>/dev/null | awk -F'\t' -v a="$agent" -v i="$id" '$1 == a && $6 == i { print; exit }'
}
col() { cut -f"$2" <<<"$1"; }

# ---- 造数据：claude（转录，含 toolUseResult 干扰行）---------------------------
mkdir -p "$home/.claude/projects/-home-u-proj"
cat > "$home/.claude/projects/-home-u-proj/claude-sess-1.jsonl" <<'JSONL'
{"type":"summary","leafUuid":"x","sessionId":"claude-sess-1"}
{"type":"user","cwd":"/home/u/proj","sessionId":"claude-sess-1","message":{"role":"user"}}
{"type":"user","cwd":"/home/u/proj","sessionId":"claude-sess-1","toolUseResult":{"ok":true}}
JSONL
touch -d '2026-10-13 10:00' "$home/.claude/projects/-home-u-proj/claude-sess-1.jsonl"

# ---- 造数据：codex（索引 + rollout 首行 + history 数提示）--------------------
mkdir -p "$home/.codex/sessions/2026/10/12"
codex_id="11111111-2222-3333-4444-555555555555"
printf '%s\n' '{"id":"'"$codex_id"'","thread_name":"排查虚拟机中文显示","updated_at":"2026-10-12T09:00:00.000000000Z"}' \
    > "$home/.codex/session_index.jsonl"
printf '%s\n' '{"timestamp":"2026-10-12T09:00:00Z","type":"session_meta","payload":{"id":"'"$codex_id"'","cwd":"/home/u/codexproj"}}' \
    > "$home/.codex/sessions/2026/10/12/rollout-2026-10-12T09-00-00-$codex_id.jsonl"
{
    printf '{"session_id":"%s","ts":1,"text":"第一条"}\n' "$codex_id"
    printf '{"session_id":"%s","ts":2,"text":"第二条"}\n' "$codex_id"
    printf '{"session_id":"%s","ts":3,"text":"第三条"}\n' "$codex_id"
    printf '{"session_id":"other-id","ts":4,"text":"别的会话"}\n'
} > "$home/.codex/history.jsonl"

# ---- 造数据：opencode（sqlite；role 在 message.data 的 JSON 里）--------------
mkdir -p "$home/.local/share/opencode"
if command -v sqlite3 >/dev/null 2>&1; then
    db="$home/.local/share/opencode/opencode.db"
    sqlite3 "$db" <<SQL
create table session (id text primary key, project_id text, workspace_id text, parent_id text,
                      slug text, directory text, path text, title text, version text,
                      time_created integer, time_updated integer);
create table message (id text primary key, session_id text, time_created integer,
                      time_updated integer, data text);
insert into session values ('ses_test_1','global',null,null,'slug','/home/u/ocproj',null,
                            'OpenCode 会话','1.0',1000,1788000000000);
insert into message values ('m1','ses_test_1',1,1,'{"role":"user"}');
insert into message values ('m2','ses_test_1',1,1,'{"role":"assistant"}');
insert into message values ('m3','ses_test_1',1,1,'{"role":"user"}');
SQL
fi

# ---- 造数据：dsh（缓存记录给目录/标题/最后消息时间；会话文件数提示）----------
dsh_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
mkdir -p "$home/.dsh/storages/session_projcache/sessions" "$home/.dsh/sessions/--home-u-dshproj--/$dsh_id"
# "最后消息时间"取一个明确晚于 claude 那条的值（按日期算，避免手写时间戳算错）
dsh_last_ms=$(( $(date -d '2026-10-14 09:00' +%s) * 1000 ))
python3 - "$home/.dsh/storages/session_projcache/sessions/$dsh_id.json" "$dsh_last_ms" <<'PY'
import json, sys
record = {
    "version": 7,
    "record": {
        "identity": {"formatVersion": 4, "createdAt": 1000, "cwd": "/home/u/dshproj"},
        "rows": {
            "title": {"ver": 1, "seq": 9, "val": "跨工具会话续接"},
            "timeContext": {"ver": 2, "seq": 9, "val": {"lastMessageTime": int(sys.argv[2])}},
        },
    },
}
json.dump(record, open(sys.argv[1], "w"), ensure_ascii=False)
PY
# 缓存文件的 mtime 故意设成"很久以前"，用来验证时间取自 lastMessageTime 而不是 mtime
touch -d '2020-01-01 00:00' "$home/.dsh/storages/session_projcache/sessions/$dsh_id.json"
if command -v zstd >/dev/null 2>&1; then
    printf '%s\n%s\n%s\n' '{"kind":"assistant"}' '{"kind":"user"}' '{"kind":"user"}' \
        | zstd -q -o "$home/.dsh/sessions/--home-u-dshproj--/$dsh_id/session.v4.jsonl.zstd"
fi

# ---- 1. 四个工具都能列出来 ----------------------------------------------------
rows="$(resume --list 2>/dev/null)"
for agent in claude codex opencode dsh; do
    if grep -q "^$agent" <<<"$rows"; then
        pass "列出：$agent 的会话出现在表里"
    else
        fail "列出：$agent 没有出现" "$rows"
    fi
done

# ---- 2. 字段解析 --------------------------------------------------------------
claude_row="$(row_of claude claude-sess-1)"
assert_equal '1' "$(col "$claude_row" 4)" 'claude：提示数排除工具结果行（1 而不是 2）'
assert_equal '/home/u/proj' "$(col "$claude_row" 3)" 'claude：目录来自转录里的 cwd'
assert_equal '-' "$(col "$claude_row" 5)" 'claude：没有标题时填占位符（空字段会破坏按列读取）'

codex_row="$(row_of codex "$codex_id")"
assert_equal '3' "$(col "$codex_row" 4)" 'codex：提示数来自 history.jsonl（只数本会话）'
assert_equal '/home/u/codexproj' "$(col "$codex_row" 3)" 'codex：目录来自 rollout 首行的 cwd'
assert_equal '排查虚拟机中文显示' "$(col "$codex_row" 5)" 'codex：标题来自 session_index 的 thread_name'

if command -v sqlite3 >/dev/null 2>&1; then
    opencode_row="$(row_of opencode ses_test_1)"
    assert_equal '2' "$(col "$opencode_row" 4)" 'opencode：提示数从 message.data 的 role 数出来'
    assert_equal '/home/u/ocproj' "$(col "$opencode_row" 3)" 'opencode：目录来自 session 表'
fi

if command -v zstd >/dev/null 2>&1; then
    dsh_row="$(row_of dsh "$dsh_id")"
    assert_equal '2' "$(col "$dsh_row" 4)" 'dsh：提示数来自会话文件的 kind=user 事件'
    assert_equal '/home/u/dshproj' "$(col "$dsh_row" 3)" 'dsh：目录来自缓存记录'
    assert_equal '跨工具会话续接' "$(col "$dsh_row" 5)" 'dsh：标题来自缓存记录'
    # 2026-10-14（lastMessageTime）而不是 2020 年（缓存文件 mtime）
    year="$(date -d "@$(col "$dsh_row" 2)" +%Y 2>/dev/null || printf '?')"
    assert_equal '2026' "$year" 'dsh：时间取最后消息时间，不取会被启动刷新的缓存 mtime'
fi

# ---- 3. 排序与过滤 ------------------------------------------------------------
newest="$(col "$(head -1 <<<"$rows")" 1)"
assert_equal 'dsh' "$newest" '排序：最新的会话排在最前（dsh 的 lastMessageTime 最新）'

filtered="$(resume --list --agent codex 2>/dev/null)"
assert_equal '1' "$(grep -c . <<<"$filtered")" '过滤：--agent codex 只输出 codex'
assert_equal 'codex' "$(col "$(head -1 <<<"$filtered")" 1)" '过滤：只输出 codex 的行'

limited="$(resume --list --limit 1 2>/dev/null)"
assert_equal '4' "$(grep -c . <<<"$limited")" '限量：--limit 1 时每个 agent 各一条'

# ---- 4. 续接命令逐 agent ------------------------------------------------------
show() { resume --show "$1" ses-test 2>&1 | tail -1; }
assert_equal 'claude --permission-mode auto --resume ses-test' "$(show claude)" 'claude：--resume <id>'
assert_equal 'codex --approve-for-me resume ses-test' "$(show codex)" 'codex：resume 子命令 + 全局旗标在前'
assert_equal 'opencode --auto --session ses-test' "$(show opencode)" 'opencode：--session <id>'
if [[ $(show dsh) == *"不接受 --resume"* ]]; then
    pass 'dsh：如实说明没有命令行续接'
else
    fail 'dsh：应说明不支持续接' "$(show dsh)"
fi

# 未知 agent / 不支持的过滤值
set +e
resume --show bogus x >/dev/null 2>&1
bad_agent=$?
resume --list --agent bogus >/dev/null 2>&1
bad_filter=$?
set -e
assert_equal '2' "$bad_agent" '--show：不支持的 agent 退出码 2'
assert_equal '2' "$bad_filter" '--agent：不支持的过滤值退出码 2'

# ---- 5. 启动器接线：--resume 必须走续接 argv 并套 console 包装 -----------------
: > "$STUB_LOG"
PATH="$stub_dir:$PATH" HOME="$home" "$PROJECT_DIR/bin/cachyos-agent" claude --resume "$codex_id" >/dev/null 2>&1 || true
kitty_line="$(grep '^kitty ' "$STUB_LOG" || true)"
if [[ $kitty_line == *"cachyos-agent-console"* && $kitty_line == *"--resume $codex_id"* ]]; then
    pass '启动器：--resume 组装出续接 argv 并套了 console 包装'
else
    fail '启动器：--resume 接线不对' "$kitty_line"
fi

# dsh 续接必须失败并给出可执行的说明，而不是拼出错误命令
set +e
dsh_err="$(PATH="$stub_dir:$PATH" HOME="$home" "$PROJECT_DIR/bin/cachyos-agent" dsh --resume x 2>&1)"
dsh_status=$?
set -e
assert_equal '2' "$dsh_status" '启动器：dsh 续接退出码 2'
# dsh 的 web profile 不能续接，但 headless 可以用 --session-id 采纳会话；
# 报错文案必须说清这一点，而不是笼统地说"不支持"。
if [[ $dsh_err == *"没有可用的续接命令"* && $dsh_err == *"headless"* ]]; then
    pass '启动器：dsh 续接给出如实的说明（并指出 headless 那条路）'
else
    fail '启动器：dsh 续接的说明不对' "$dsh_err"
fi

# ---- 6. 没有任何会话时给提示而不是崩 -----------------------------------------
empty_home="$WORK_DIR/empty"
mkdir -p "$empty_home"
set +e
empty_out="$(PATH="$stub_dir:$PATH" HOME="$empty_home" "$PROJECT_DIR/bin/cachyos-agent-resume" --list 2>&1)"
empty_status=$?
set -e
if ((empty_status != 0)); then
    pass "空环境：退出码非 0（$empty_status）"
else
    fail '空环境：应当给出非 0 退出码'
fi
if [[ $empty_out == *"没有找到任何会话"* ]]; then
    pass '空环境：提示没有会话'
else
    fail '空环境：提示不对' "$empty_out"
fi

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
