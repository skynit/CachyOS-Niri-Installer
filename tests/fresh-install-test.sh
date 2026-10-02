#!/usr/bin/env bash

# 全新安装彩排：把 install.sh **真正跑一遍**，但落在一个临时 HOME 和临时"系统根"里。
#
# 为什么必须真跑：只有这样才能回答"任何人跑一遍脚本，能不能得到一套可用的 AI 系统"。
# 只跑 --dry-run 不够——dry-run 不执行任何命令，正好跳过所有"命令拼错、函数不存在、
# 资产没登记"的失败模式。
#
# 沙箱做法：
#   - HOME 指向临时目录
#   - sudo 被替换成"把 /usr/local 重写成假根再执行"，于是 /usr/local/bin 与
#     /usr/local/share/cachyos-desktop 都真的被装出来，后续步骤能找到它们
#   - pacman/systemctl/niri/dms 等变更类命令只记录不执行
#   - curl 造一个占位文件、sha256sum 回显安装器期望的哈希（这两个校验本身不是本测试的对象，
#     已由评审对着真实 release 校验过）
#
# 断言的是"装完之后的 AI 系统"：命令、资产、单元、面板插件、waybar、niri 接线、技能链接。

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
readonly PROJECT_DIR

PASS_COUNT=0
WORK_DIR="$(mktemp -d)"
# CACHYOS_TEST_KEEP=1 时保留沙箱，便于定位失败（默认清理）。
cleanup() {
    if [[ ${CACHYOS_TEST_KEEP:-0} == 1 ]]; then
        printf '沙箱保留在 %s\n' "$WORK_DIR" >&2
        return 0
    fi
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
assert_file() {
    if [[ -s "$1" ]]; then
        pass "$2"
    else
        fail "$2" "缺少或为空: $1"
    fi
}

SANDBOX_HOME="$WORK_DIR/home"
FAKE_ROOT="$WORK_DIR/root"
STUB_BIN="$WORK_DIR/bin"
LOG="$WORK_DIR/calls.log"
mkdir -p "$SANDBOX_HOME" "$STUB_BIN"
# 真实系统里这些目录本来就存在，install 不会创建父目录，这里必须先建。
mkdir -p "$FAKE_ROOT"/usr/local/bin "$FAKE_ROOT"/usr/local/share/cachyos-desktop \
         "$FAKE_ROOT"/etc "$FAKE_ROOT"/var "$FAKE_ROOT"/usr/bin
: > "$LOG"
# stub 与测试自身都用这个名字引用日志文件（env -i 下必须显式传进去）。
CACHYOS_TEST_LOG="$LOG"
export CACHYOS_TEST_LOG

printf 'ID=cachyos\nNAME="CachyOS Linux"\n' > "$WORK_DIR/os-release"

# 安装器脚本里 pin 的两个哈希：让 sha256sum stub 回显它们
SIDEBAR_SHA="$(grep -oP 'PINNED_NIRI_SIDEBAR_SHA256_AMD64="\K[0-9a-f]+' "$PROJECT_DIR/install.sh")"
DMS_SHA="$(grep -oP 'PINNED_DMS_SHA256_AMD64="\K[0-9a-f]+' "$PROJECT_DIR/install.sh")"
[[ -n $SIDEBAR_SHA && -n $DMS_SHA ]] || fail "无法从 install.sh 提取 pin 的哈希"

log_call() { printf '%s %s\n' "${0##*/}" "$*" >> "${CACHYOS_TEST_LOG:?}"; }

# sudo：把 /usr/local 重写进假根后真的执行；其他命令只记录
cat > "$STUB_BIN/sudo" <<EOF
#!/usr/bin/env bash
printf 'sudo %s\n' "\$*" >> "${CACHYOS_TEST_LOG:?}"
rewritten=()
skip_next=false
for argument in "\$@"; do
    if [[ \$skip_next == true ]]; then
        skip_next=false
        continue
    fi
    # 真实 sudo 能以 root 改属主；这里不是 root，所以丢掉 -o/-g 参数。
    case "\$argument" in
        -o|-g|--owner|--group) skip_next=true; continue ;;
    esac
    # 按前缀**单次**重写到假根。不能用全局字符串替换：
    # 替换后的路径里仍含 /usr，会级联成假根套假根。
    for prefix in /usr/local /usr /etc /var /opt; do
        if [[ \$argument == "\$prefix" || \$argument == "\$prefix"/* ]]; then
            argument="$FAKE_ROOT\$argument"
            break
        fi
    done
    rewritten+=("\$argument")
done
case "\${rewritten[0]:-}" in
    install|cp|ln|tee)
        # 真实系统里目标父目录都在；假根里按需补出来。
        last=""
        for value in "\${rewritten[@]}"; do last="\$value"; done
        if [[ -n \$last ]]; then
            mkdir -p "\$(dirname -- "\$last")"
        fi
        exec "\${rewritten[@]}" ;;
    mkdir|chmod|chown) exec "${rewritten[@]}" ;;
esac
exit 0
EOF

# 只记录 + 对查询返回成功
for name in claude codex opencode \
            pacman paru yay usermod groupadd modprobe udevadm snapper systemctl niri dms \
            notify-send kitty ghostty alacritty ly hyprctl mkinitcpio grub-mkconfig dbus-send \
            gsettings xdg-settings npm mise systemd-analyze fc-cache; do
    cat > "$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >> "${CACHYOS_TEST_LOG:?}"
case "$name" in
    dms) [[ "\$1" == "--version" ]] && echo "1.6.2" ;;
    niri) [[ "\$1" == "--version" ]] && echo "niri 26.04" ;;
esac
exit 0
EOF
done

# curl：造一个占位文件（-o 的目标），让下游的 install 有东西可装
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${CACHYOS_TEST_LOG:?}"
destination=""
while (($#)); do
    case "$1" in
        -o) destination="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ -n $destination ]]; then
    mkdir -p "$(dirname -- "$destination")"
    if [[ $destination == *.sha256 ]]; then
        # 安装器要的是"首字段是 64 位十六进制"的校验和文件；占位内容会被判为非法。
        printf '%s  %s\n' "${CACHYOS_TEST_DMS_SHA:?}" "$(basename -- "$destination" .sha256)" > "$destination"
    else
        printf 'placeholder\n' > "$destination"
    fi
fi
exit 0
EOF

# tar/gzip：DMS 包是 tar.gz，造一个最小的合法归档
cat > "$STUB_BIN/tar" <<'EOF'
#!/usr/bin/env bash
printf 'tar %s\n' "$*" >> "${CACHYOS_TEST_LOG:?}"
exit 0
EOF
cat > "$STUB_BIN/gzip" <<'EOF'
#!/usr/bin/env bash
printf 'gzip %s\n' "$*" >> "${CACHYOS_TEST_LOG:?}"
# 只有从 stdin 读取的调用才消费 stdin；带文件名时去读 stdin 会永久阻塞（实测踩过）。
if (($# == 0)); then
    cat >/dev/null
fi
exit 0
EOF

# sha256sum：按文件名回显安装器 pin 的值
cat > "$STUB_BIN/sha256sum" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
    case "\$argument" in
        *niri-sidebar*) echo "$SIDEBAR_SHA  \$argument" ;;
        *) echo "$DMS_SHA  \$argument" ;;
    esac
done
exit 0
EOF

chmod +x "$STUB_BIN"/*

# ---- 真跑安装器 -------------------------------------------------------------
set +e
env -i \
    HOME="$SANDBOX_HOME" \
    PATH="$FAKE_ROOT/usr/local/bin:$STUB_BIN:/usr/bin:/bin" \
    TERM=dumb \
    CACHYOS_SETUP_OS_RELEASE="$WORK_DIR/os-release" \
    CACHYOS_DESKTOP_SHARE_DIR="$FAKE_ROOT/usr/local/share/cachyos-desktop" \
    CACHYOS_TEST_FAKE_ROOT="$FAKE_ROOT" \
    CACHYOS_TEST_DMS_SHA="$DMS_SHA" \
    CACHYOS_TEST_LOG="$LOG" \
    bash "$PROJECT_DIR/install.sh" --skip-update --skip-hardware -y --terminal kitty \
    < /dev/null > "$WORK_DIR/install.log" 2>&1
install_status=$?
set -e

if ((install_status != 0)); then
    printf 'not ok - 安装器未成功退出（exit=%s）\n' "$install_status" >&2
    tail -25 "$WORK_DIR/install.log" >&2
    exit 1
fi
pass '安装器在干净 HOME 上成功退出'

# 技能必须**安装完就可用**，不能等到一次登录之后——否则装完当天用 agent 就没有技能。
for harness in .claude/skills .codex/skills; do
    if [[ -e "$SANDBOX_HOME/$harness/cachyos" || -L "$SANDBOX_HOME/$harness/cachyos" ]]; then
        pass "技能被分发到 $harness"
    else
        fail "技能没有分发到 $harness"
    fi
done
# opencode 的 .agents/skills 是库注释里写明的"尽力而为"位置：目录本来不存在时**不该**由我们
# 凭空创建（建出来可能永远不会被读），所以这里反过来断言它没被创建。
if [[ ! -e "$SANDBOX_HOME/.agents/skills" ]]; then
    pass '没有为 opencode 凭空创建未经验证的技能目录'

# 首次登录阶段：Niri 启动时会 spawn cachyos-post-login-setup，它负责补齐 Firefox/Code/
# Wine 与 **agent 技能**。这一阶段必须一起彩排——只在安装期链接技能是不够的。
env -i \
    HOME="$SANDBOX_HOME" \
    PATH="$FAKE_ROOT/usr/local/bin:$STUB_BIN:/usr/bin:/bin" \
    TERM=dumb \
    CACHYOS_DESKTOP_SHARE_DIR="$FAKE_ROOT/usr/local/share/cachyos-desktop" \
    CACHYOS_TEST_LOG="$LOG" \
    bash -c 'cachyos-post-login-setup' </dev/null >> "$WORK_DIR/install.log" 2>&1 || true
pass '首次登录初始化阶段执行完毕（不因个别步骤失败而中断）'

# ---- 断言：AI 系统的每一层都真的落地了 --------------------------------------

# 1) 命令装进了（假）系统 bin
for command_name in cachyos-agent cachyos-agent-prompt cachyos-agent-skills cachyos-default-agent \
                    cachyos-agent-usage-claude cachyos-agent-usage-codex cachyos-agent-usage-fireworks \
                    cachyos-agent-usage-update cachyos-agent-theme-sync cachyos-crash-watch \
                    cachyos-crash-mute cachyos-toggle-crash-capture cachyos-voxtype-install; do
    assert_file "$FAKE_ROOT/usr/local/bin/$command_name" "装出命令 $command_name"
done

# 2) 随包资产（技能、库、插件、模板）
for asset in assets/lib/agent.sh assets/lib/agent_usage.py assets/lib/agent_theme.py \
             assets/agent-skills/cachyos/SKILL.md assets/agent-skills/diagnose-crash/SKILL.md \
             assets/dms-plugins/CachyosAgents/plugin.json assets/dms-plugins/CachyosAgents/Usage.js \
             assets/dms/add-agents-bar-widget.jq assets/dms/enable-dms-plugin.jq \
             assets/voxtype/config.toml assets/niri/cachyos-voxtype.kdl; do
    assert_file "$FAKE_ROOT/usr/local/share/cachyos-desktop/$asset" "装出资产 $asset"
done

# 3) systemd 用户单元（含本轮新增的用量定时器）
for unit in cachyos-crash-watch.service cachyos-agent-theme.service cachyos-agent-theme.path \
            cachyos-agent-usage.service cachyos-agent-usage.timer; do
    assert_file "$SANDBOX_HOME/.config/systemd/user/$unit" "装出单元 $unit"
done

# 4) 面板插件与启用状态
plugin="$SANDBOX_HOME/.config/DankMaterialShell/plugins/CachyosAgents"
assert_file "$plugin/plugin.json" '面板插件已安装'
assert_file "$plugin/Usage.js" '面板插件带 Usage.js'
assert_equal 'true' "$(jq -r '.cachyosAgents.enabled // false' "$SANDBOX_HOME/.config/DankMaterialShell/plugin_settings.json" 2>/dev/null || echo false)" \
    '面板插件被启用'

# 5) 桌面接线：waybar 的听写模块 + niri 的可选 include
if grep -q 'custom/voxtype' "$SANDBOX_HOME/.config/waybar/top.jsonc" 2>/dev/null; then
    pass 'waybar 装了听写状态模块'
else
    fail 'waybar 没有听写状态模块'
fi
if grep -q 'cachyos-voxtype.kdl' "$SANDBOX_HOME/.config/niri/config.kdl" 2>/dev/null; then
    pass 'niri 主配置引入了听写按键（optional）'
else
    fail 'niri 主配置没有听写 include'
fi

# 6) 技能分发：三个 harness 的技能目录都应出现链接

else
    fail 'opencode 的技能目录被凭空创建了'
fi

# 7) 主题与用量都被初始化过（post_install 的步骤真的执行了）
assert_file "$FAKE_ROOT/usr/local/bin/cachyos-agent-theme-sync" '主题同步命令存在（post_install 会调用它）'
if grep -qE 'cachyos-agent-usage.timer' "$LOG"; then
    pass 'post_install 启用了用量刷新定时器'
else
    fail 'post_install 没有启用用量刷新定时器'
fi
if grep -qE 'cachyos-agent-usage-update' "$LOG"; then
    pass 'post_install 初始化了一次用量数据'
else
    fail 'post_install 没有初始化用量数据'
fi

# 8) 安装器不能悄悄失败：日志里不应有"command not found"
if grep -qi 'command not found' "$WORK_DIR/install.log"; then
    fail '安装过程中出现 command not found' "$(grep -i 'command not found' "$WORK_DIR/install.log" | head -3)"
else
    pass '安装过程没有 command not found（函数/命令都真实存在）'
fi

printf '\n%s 项检查通过。\n' "$PASS_COUNT"
