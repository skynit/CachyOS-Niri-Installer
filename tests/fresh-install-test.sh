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

# 只验证下载入口和随包缓存，不执行整套安装彩排。
if [[ ${1:-} == --downloads-only ]]; then
    python3 - "$PROJECT_DIR" "$WORK_DIR" <<'PY'
import gzip
import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

project, work = map(Path, sys.argv[1:])
site = work / 'site'
site.mkdir()
commands = work / 'bin'
commands.mkdir()
scratch = work / 'tmp'
scratch.mkdir()
marker = work / 'started'
calls = work / 'calls'
archive_name = f'source-{"a" * 40}.tar.gz'
archive = site / archive_name
with tarfile.open(archive, 'w:gz') as package:
    content = b'#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$PROBE_MARKER"\nread -r reply\nprintf "%s\\n" "$reply" >> "$PROBE_MARKER"\nexit "${PROBE_INSTALL_EXIT:-0}"\n'
    item = tarfile.TarInfo('project/install.sh')
    item.size = len(content)
    package.addfile(item, io.BytesIO(content))
original_archive = archive.read_bytes()
manifest = f'{hashlib.sha256(original_archive).hexdigest()}  {archive_name}\n'
(site / 'SHA256SUMS').write_text(manifest)
curl = commands / 'curl'
curl.write_text(f'#!{sys.executable}\n' + '''import os, pathlib, shutil, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith('http'))
with open(os.environ['PROBE_CALLS'], 'a') as log:
    log.write(url + '\\n')
if os.environ.get('PROBE_CURL_FAIL'):
    sys.exit(22)
shutil.copyfile(pathlib.Path(os.environ['PROBE_SITE']) / url.rsplit('/', 1)[-1], args[args.index('--output') + 1])
''')
curl.chmod(0o755)
env = dict(os.environ, PATH=f'{commands}:{os.environ["PATH"]}', TMPDIR=str(scratch),
           CACHYOS_DOWNLOAD_BASE='http://fixture.invalid/niri/', PROBE_SITE=str(site),
           PROBE_MARKER=str(marker), PROBE_CALLS=str(calls))
checks = 0

def check(condition, label):
    global checks
    assert condition, label
    checks += 1
    print(f'ok - {label}', flush=True)

def launch(**overrides):
    marker.unlink(missing_ok=True)
    result = subprocess.run(['bash', str(project / 'setup.sh'), '--terminal', 'one two'],
                            input='confirm\n', capture_output=True, text=True,
                            env=dict(env, **overrides), timeout=10)
    check(not list(scratch.glob('cachyos-niri-setup.*')), '入口退出后清理临时目录')
    return result

r = launch()
check(r.returncode == 0 and '正在连接' in r.stdout and '正在启动' in r.stdout, '入口显示进度并启动安装器')
check(marker.read_text() == '--terminal\none two\nconfirm\n', '保留参数边界和交互式标准输入')
check(calls.read_text().splitlines() == ['http://fixture.invalid/niri/SHA256SUMS', f'http://fixture.invalid/niri/{archive_name}'], '仅访问指定下载站')
r = launch(PROBE_INSTALL_EXIT='19')
check(r.returncode == 19, '保留安装器失败退出码')
r = launch(PROBE_CURL_FAIL='1')
check(r.returncode != 0 and not marker.exists(), '下载失败时不启动安装器')
for invalid in ('', '<html>not found</html>', f'{"0" * 64}  ../../bad.tar.gz\n'):
    (site / 'SHA256SUMS').write_text(invalid)
    r = launch()
    check(r.returncode != 0 and '下载清单无效' in r.stderr and not marker.exists(), '拒绝空清单、HTML 或越界文件名')
(site / 'SHA256SUMS').write_text(manifest)
archive.write_bytes(original_archive + b'corrupt')
r = launch()
check(r.returncode != 0 and '安装包校验失败' in r.stderr and not marker.exists(), '校验失败时停止解压和启动')

fixture = work / 'bundle'
dms = fixture / 'assets/downloads/dms/v1.6.2/dankinstall-amd64.gz'
sidebar = fixture / 'assets/downloads/niri-sidebar/v0.4.0/niri-sidebar-linux-x86_64'
dms.parent.mkdir(parents=True)
sidebar.parent.mkdir(parents=True)
dms.write_bytes(gzip.compress(b'#!/usr/bin/env bash\nexit 0\n'))
sidebar.write_bytes(b'fixture sidebar')
dms_sha = hashlib.sha256(dms.read_bytes()).hexdigest()
sidebar_sha = hashlib.sha256(sidebar.read_bytes()).hexdigest()
Path(f'{dms}.sha256').write_text(f'{dms_sha}  dankinstall-amd64.gz\n')
source = (project / 'install.sh').read_text()
functions = '\n'.join(re.search(rf'^{name}\(\) \{{\n.*?^\}}', source, re.M | re.S)[0]
                      for name in ('record_optional_failure', 'install_niri_sidebar', 'download_dankinstall'))
definitions = '''
set -Eeuo pipefail
SCRIPT_DIR="$1"
TEMP_DIR="$2"
DRY_RUN=false
OPTIONAL_FAILURES=()
TUI_TTY=false
DMS_VERSION=v1.6.2
PINNED_DMS_VERSION=v1.6.2
PINNED_NIRI_SIDEBAR_VERSION=v0.4.0
PINNED_DMS_SHA256_AMD64="$3"
PINNED_NIRI_SIDEBAR_SHA256_AMD64="$4"
ensure_temp_dir() { mkdir -p "$TEMP_DIR"; }
info() { :; }
warn() { printf '%s\\n' "$*" >&2; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
tui_spin_start() { :; }
tui_spin_stop() { :; }
sudo() { :; }
curl() { printf 'unexpected network request\\n' >&2; return 99; }
'''
def cached(action):
    return subprocess.run(['bash', '-c', definitions + functions + '\n' + action, '_',
                           str(fixture), str(work / 'download'), dms_sha, sidebar_sha],
                          capture_output=True, text=True, timeout=10)

r = cached('install_niri_sidebar; download_dankinstall; test -x "$DANKINSTALL_PATH"')
check(r.returncode == 0, '随包 sidebar 与 DMS 安装器完成校验解压，全程不请求网络')
sidebar.write_bytes(b'bad sidebar')
r = cached('install_niri_sidebar')
check(r.returncode == 0 and 'checksum mismatch' in r.stderr, '跳过损坏的可选 sidebar 缓存并继续')
dms.write_bytes(b'bad DMS')
r = cached('download_dankinstall')
check(r.returncode != 0 and 'checksum mismatch' in r.stderr, '拒绝损坏的 DMS 缓存')
print(f'\n{checks} 项下载检查通过。')
PY
    exit 0
fi

OPTIONAL_FAILURE_TEST=false
if [[ ${1:-} == --optional-failures-only ]]; then
    OPTIONAL_FAILURE_TEST=true
fi

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
    mkdir|chmod|chown|pacman) exec "\${rewritten[@]}" ;;
esac
exit 0
EOF

# 只记录 + 对查询返回成功
for name in claude codex opencode \
            pacman paru yay usermod groupadd modprobe udevadm snapper systemctl niri dms \
            notify-send kitty ghostty alacritty ly hyprctl mkinitcpio grub-mkconfig dbus-send \
            gsettings xdg-settings npm mise systemd-analyze fc-cache wineboot winetricks flatpak fish; do
    cat > "$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >> "${CACHYOS_TEST_LOG:?}"
case "$name" in
    dms) [[ "\$1" == "--version" ]] && echo "1.6.2" ;;
    niri) [[ "\$1" == "--version" ]] && echo "niri 26.04" ;;
esac
if [[ "$name" == pacman && "\$1" == -S ]]; then
    if [[ \${CACHYOS_TEST_CORE_FAIL:-false} == true && " \$* " == *' git jq python kitty ly '* ]]; then
        exit 1
    fi
    if [[ \${CACHYOS_TEST_OPTIONAL_FAILURES:-false} == true && " \$* " == *' gamescope '* ]]; then
        exit 1
    fi
fi
if [[ \${CACHYOS_TEST_OPTIONAL_FAILURES:-false} == true ]]; then
    case "$name" in
        paru) [[ "\${!#}" == upscaler || "\${!#}" == rime-ice-git ]] && exit 28 ;;
        flatpak) exit 22 ;;
    esac
fi
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
    if [[ ${CACHYOS_TEST_OPTIONAL_FAILURES:-false} == true && $destination == *niri-sidebar* ]]; then
        exit 28
    fi
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
cat <<'INSTALLER'
#!/usr/bin/env bash
printf 'dankinstall %s\n' "$*" >> "${CACHYOS_TEST_LOG:?}"
if [[ ${CACHYOS_TEST_DMS_FAIL:-false} == true ]]; then exit 23; fi
INSTALLER
exit 0
EOF

# 只替换两个下载资源的校验；插件运行目录仍需要真实哈希，并消费管道输入。
SHA256SUM_COMMAND="$(command -v sha256sum)"
cat > "$STUB_BIN/sha256sum" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    *niri-sidebar*) echo "$SIDEBAR_SHA  \$1" ;;
    *dankinstall-amd64.gz) echo "$DMS_SHA  \$1" ;;
    *) exec "$SHA256SUM_COMMAND" "\$@" ;;
esac
EOF

chmod +x "$STUB_BIN"/*

# ---- 真跑安装器 -------------------------------------------------------------
launch_installer() {
    env -i \
    HOME="$SANDBOX_HOME" \
    PATH="$FAKE_ROOT/usr/local/bin:$STUB_BIN:/usr/bin:/bin" \
    TERM=dumb \
    CACHYOS_SETUP_OS_RELEASE="$WORK_DIR/os-release" \
    CACHYOS_DESKTOP_SHARE_DIR="$FAKE_ROOT/usr/local/share/cachyos-desktop" \
    CACHYOS_TEST_FAKE_ROOT="$FAKE_ROOT" \
    CACHYOS_TEST_DMS_SHA="$DMS_SHA" \
    CACHYOS_TEST_LOG="$LOG" \
    CACHYOS_TEST_OPTIONAL_FAILURES="$OPTIONAL_FAILURE_TEST" \
    CACHYOS_TEST_CORE_FAIL="${CACHYOS_TEST_CORE_FAIL:-false}" \
    CACHYOS_TEST_DMS_FAIL="${CACHYOS_TEST_DMS_FAIL:-false}" \
    bash "$PROJECT_DIR/install.sh" --skip-update --skip-hardware -y --terminal kitty \
    < /dev/null > "$WORK_DIR/install.log" 2>&1
}
set +e
launch_installer
install_status=$?
set -e

if ((install_status != 0)); then
    printf 'not ok - 安装器未成功退出（exit=%s）\n' "$install_status" >&2
    tail -25 "$WORK_DIR/install.log" >&2
    exit 1
fi
pass '安装器在干净 HOME 上成功退出'

if [[ "$OPTIONAL_FAILURE_TEST" == true ]]; then
    assert_file "$SANDBOX_HOME/.config/niri/config.kdl" '可选下载失败后仍写入 Niri 配置'
    assert_file "$SANDBOX_HOME/.config/DankMaterialShell/settings.json" '可选下载失败后仍写入 DMS 配置'
    assert_file "$SANDBOX_HOME/.config/DankMaterialShell/plugins/Focus/plugin.json" '可选下载失败后仍部署 DMS 插件'
    if [[ ! -e "$FAKE_ROOT/usr/local/bin/niri-sidebar" ]]; then
        pass '侧栏下载失败时不安装不完整文件'
    else
        fail '侧栏下载失败后仍安装了文件'
    fi
    for item in 游戏应用 'AUR: upscaler' 'AUR: rime-ice-git' niri-sidebar Flathub; do
        if grep -qF "$item:" "$WORK_DIR/install.log"; then
            pass "记录可选项目失败：$item"
        else
            fail "漏记可选项目失败：$item"
        fi
    done
    if grep -qF '部分可选项目未完成' "$WORK_DIR/install.log" &&
       grep -qF 'cachyos-agent-usage.timer' "$LOG"; then
        pass '失败后仍执行服务收尾，并明确提示部分项目未完成'
    else
        fail '失败后没有完成收尾或遗漏失败摘要'
    fi
    python3 - "$PROJECT_DIR" "$LOG" <<'PY'
from pathlib import Path
import re
import sys
project, log = map(Path, sys.argv[1:])
calls = log.read_text().splitlines()
packages = re.search(r'AUR_PACKAGES=\((.*?)\)', (project / 'packages.sh').read_text(), re.S)[1].split()
attempts = [line.rsplit(' ', 1)[-1] for line in calls if line.startswith('paru -S ')]
assert attempts == packages, (attempts, packages)
assert next(i for i, line in enumerate(calls) if line.startswith('dankinstall ')) < next(i for i, line in enumerate(calls) if line.startswith('paru -S '))
print('ok - 社区软件失败后仍逐项尝试后续软件，且 DMS 优先安装')
PY
    # 同一沙箱还要验证失败边界：基础工具和 DMS 本体失败必须停止。
    SANDBOX_HOME="$WORK_DIR/core-home"
    LOG="$WORK_DIR/core-calls.log"
    mkdir -p "$SANDBOX_HOME"
    set +e
    CACHYOS_TEST_CORE_FAIL=true launch_installer
    core_status=$?
    set -e
    assert_equal 1 "$core_status" '核心工具安装失败时停止'
    [[ ! -e "$SANDBOX_HOME/.config/niri/config.kdl" ]] || fail '核心工具失败后仍写入桌面配置'
    LOG="$WORK_DIR/dms-calls.log"
    set +e
    CACHYOS_TEST_DMS_FAIL=true launch_installer
    dms_status=$?
    set -e
    assert_equal 23 "$dms_status" 'DMS 本体失败时保留错误码并停止'
    [[ ! -e "$SANDBOX_HOME/.config/niri/config.kdl" ]] || fail 'DMS 失败后仍写入桌面配置'
    python3 - "$PROJECT_DIR" <<'PY'
from pathlib import Path
import re
import subprocess
import sys
source = (Path(sys.argv[1]) / 'install.sh').read_text()
functions = '\n'.join(re.search(rf'^{name}\(\) \{{\n.*?^\}}', source, re.M | re.S)[0]
                      for name in ('run', 'record_optional_failure', 'run_optional'))
for status in (130, 143):
    probe = 'set -Eeuo pipefail\nDRY_RUN=false\nOPTIONAL_FAILURES=()\n' + functions
    probe += f'\nrun_optional cancel bash -c "exit {status}"\nprintf unexpected'
    result = subprocess.run(['bash', '-c', probe], capture_output=True, text=True, timeout=5)
    assert result.returncode == status and 'unexpected' not in result.stdout, result
    print(f'ok - 主动取消退出码 {status} 不会被当成可选失败吞掉')
PY
    printf '\n可选下载失败后的安装流程检查通过。\n'
    exit 0
fi

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
                    cachyos-agent-usage-claude cachyos-agent-usage-codex cachyos-agent-usage-dsh \
                    cachyos-agent-usage-update cachyos-agent-theme-sync cachyos-crash-watch \
                    cachyos-crash-mute cachyos-toggle-crash-capture cachyos-voxtype-install \
                    cachyos-oom-watch cachyos-agent-oom cachyos-toggle-oom-capture cachyos-ai-settings; do
    assert_file "$FAKE_ROOT/usr/local/bin/$command_name" "装出命令 $command_name"
done

# 2) 随包资产（技能、库、插件、模板）
for asset in assets/lib/agent.sh assets/lib/ai-settings.sh assets/lib/agent_usage.py assets/lib/agent_theme.py \
             assets/agent-skills/cachyos/SKILL.md assets/agent-skills/diagnose-crash/SKILL.md \
             assets/agent-skills/diagnose-oom/SKILL.md \
             assets/dms/add-dms-bar-widgets.jq assets/dms/enable-dms-plugin.jq \
             assets/dms-plugins/CachyosAgents/plugin.json assets/dms-plugins/CachyosAgents/Usage.js \
             assets/dms-plugins/CachyosAgents/IntegrationSource.qml \
             assets/dms-plugins/CachyosAgents/IntegrationDetails.qml \
             assets/dms-plugins/CachyosAgents/IntegrationSettings.qml \
             assets/dms-plugins/LocalStatus/plugin.json assets/dms-plugins/LocalStatus/LocalStatus.qml \
             assets/dms-plugins/LocalStatus/StatusSource.qml assets/dms-plugins/LocalStatus/Status.js \
             assets/dms-plugins/LocalTranslate/plugin.json assets/dms-plugins/LocalTranslate/LocalTranslate.qml \
             assets/dms-plugins/LocalTranslate/data/dictionary.sqlite3 \
             assets/dms-plugins/LocalLyrics/plugin.json assets/dms-plugins/LocalLyrics/LocalLyrics.qml \
             assets/dms-plugins/LocalLyrics/Timeline.js \
             assets/dms-plugins/PhoneConnect/plugin.json assets/dms-plugins/PhoneConnect/PhoneConnect.qml \
             assets/dms-plugins/Focus/plugin.json assets/dms-plugins/Focus/Focus.qml \
             assets/go-bin/translate-lookup assets/go-bin/lyrics-helper \
             assets/go-bin/phone-connect assets/go-bin/focus-helper \
             assets/voxtype/config.toml assets/niri/cachyos-voxtype.kdl; do
    assert_file "$FAKE_ROOT/usr/local/share/cachyos-desktop/$asset" "装出资产 $asset"
done

# 旧 jq 已删除：包里若还残留，重装仍可能误用旧语义。
if [[ ! -e "$FAKE_ROOT/usr/local/share/cachyos-desktop/assets/dms/add-agents-bar-widget.jq" ]]; then
    pass '旧 jq 不再出现在共享资产里'
else
    fail '旧 jq 仍被安装进共享资产'
fi

# 3) systemd 用户单元（含用量定时器与 OOM 监听）
for unit in cachyos-crash-watch.service cachyos-agent-theme.service cachyos-agent-theme.path \
            cachyos-agent-usage.service cachyos-agent-usage.timer cachyos-oom-watch.service; do
    assert_file "$SANDBOX_HOME/.config/systemd/user/$unit" "装出单元 $unit"
done

# 3b) cachyos-ask 的提示词起始配置：只在新装时给一份，且不能覆盖用户改过的内容
ask_conf="$SANDBOX_HOME/.config/cachyos-desktop/ask-actions.conf"
assert_file "$ask_conf" '装出 cachyos-ask 提示词起始配置'
if grep -qE "^explain	" "$ask_conf" 2>/dev/null; then
    pass '起始配置带内置 explain 提示词（用户照着改即可）'
else
    fail '起始配置里没有内置 prompt'
fi

# 4) 面板插件与启用状态：9 个插件都要装进运行目录并被启用
# 目录名是 DMS 的安装目录名，插件 ID 来自各自 plugin.json。
plugin_root="$SANDBOX_HOME/.config/DankMaterialShell/plugins"
plugin_settings="$SANDBOX_HOME/.config/DankMaterialShell/plugin_settings.json"
plugin_dirs=(CachyosAgents LocalStatus localTranslate localLyrics PhoneConnect Focus Top DesktopSettings TodoCalendar)
plugin_ids=(cachyosAgents localStatus localTranslate localLyrics phoneConnect focus top desktopSettings todoCalendar)

for index in "${!plugin_dirs[@]}"; do
    plugin_dir="$plugin_root/${plugin_dirs[$index]}"
    plugin_id="${plugin_ids[$index]}"
    assert_file "$plugin_dir/plugin.json" "面板插件 ${plugin_dirs[$index]} 已安装"
    assert_equal "$plugin_id" "$(jq -r '.id' "$plugin_dir/plugin.json" 2>/dev/null || true)" \
        "面板插件 ${plugin_dirs[$index]} 的 id 是 $plugin_id"

    # plugin.json 声明的主 QML 必须真的装进运行目录，否则 DMS 加载插件时是空壳。
    entries="$(jq -r '[.component, (.components // {} | .[])] | .[] | select(type == "string") | ltrimstr("./")' "$plugin_dir/plugin.json")"
    [[ -n $entries ]] || fail "面板插件 ${plugin_dirs[$index]} 没有声明入口"
    while IFS= read -r main_qml; do
        assert_file "$plugin_dir/$main_qml" "面板插件 ${plugin_dirs[$index]} 的入口 $main_qml 已安装"
    done <<< "$entries"

    assert_equal 'true' "$(jq -r --arg id "$plugin_id" '.[$id].enabled // false' "$plugin_settings" 2>/dev/null || echo false)" \
        "面板插件 $plugin_id 被启用"
done

# LocalTranslate 的词典是运行时数据：装了插件但漏了 data/，翻译面板点开就是空的。
assert_file "$plugin_root/localTranslate/data/dictionary.sqlite3" 'LocalTranslate 装了词典数据'

# plugin_settings.json 里 9 个插件都必须是 enabled:true（安装器逐个启用，漏一个就静默少功能）。
assert_equal '9' \
    "$(jq '[to_entries[] | select(.value.enabled == true) | .key
           | select(. as $id | ["cachyosAgents","localStatus","localTranslate","localLyrics","phoneConnect","focus","top","desktopSettings","todoCalendar"] | index($id))] | length' \
        "$plugin_settings" 2>/dev/null || echo 0)" \
    'plugin_settings.json 里 9 个插件都被启用'

# 全新 HOME 的 settings.json 没有 barConfigs：安装器绝不能凭空造栏。
# （DMS 的默认状态栏只在"键不存在"时生效；造一个只含插件控件的栏会毁掉默认顶栏。）
dms_settings="$SANDBOX_HOME/.config/DankMaterialShell/settings.json"
assert_file "$dms_settings" '装出 DMS settings.json'
assert_equal 'false' "$(jq 'has("barConfigs")' "$dms_settings" 2>/dev/null || echo true)" \
    '全新 HOME：settings.json 没有 barConfigs（安装器不凭空造栏）'

# helper 二进制由 tools/install-go-helpers.sh 装进插件目录（QML 用 Qt.resolvedUrl 找它）。
for helper in localTranslate/translate-lookup localLyrics/lyrics-helper \
              PhoneConnect/phone-connect Focus/focus-helper Top/top-helper \
              DesktopSettings/desktop-settings-helper TodoCalendar/todo-calendar-helper; do
    if [[ -x "$plugin_root/$helper" ]]; then
        pass "插件 helper 可执行：$helper"
    else
        fail "插件 helper 缺失或不可执行：$helper"
    fi
done

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
