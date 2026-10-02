#!/usr/bin/env bash

set -uo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=packages.sh
source "$SCRIPT_DIR/packages.sh"
# shellcheck source=hardware.sh
source "$SCRIPT_DIR/hardware.sh"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '[PASS] %s\n' "$*"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf '[WARN] %s\n' "$*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '[FAIL] %s\n' "$*"
}

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "command available: $1"
    else
        fail "command missing: $1"
    fi
}

check_package() {
    if pacman -Q "$1" >/dev/null 2>&1; then
        pass "package installed: $1"
    else
        fail "package missing: $1"
    fi
}

check_file() {
    if [[ -s "$1" ]]; then
        pass "file exists: $1"
    else
        fail "file is missing or empty: $1"
    fi
}

render_project_niri_config() {
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "${line//@HOME@/$HOME}"
    done < "$SCRIPT_DIR/assets/niri/config.kdl"
}

check_system_service() {
    local service_name="$1"
    if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        pass "system service enabled: $service_name"
    else
        warn "system service is not enabled: $service_name"
    fi
}

check_power_profile_service() {
    if systemctl is-enabled --quiet power-profiles-daemon.service 2>/dev/null; then
        pass "power-profile service enabled: power-profiles-daemon.service"
    elif pacman -Q tuned-ppd >/dev/null 2>&1; then
        pass "power-profile provider installed: tuned-ppd"
    else
        warn "no supported power-profile service is enabled"
    fi
}

check_os() {
    if [[ ! -r /etc/os-release ]]; then
        fail "/etc/os-release is unavailable"
        return
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    local os_id="${ID:-}"
    if [[ "${os_id,,}" == "cachyos" ]]; then
        pass "operating system: ${PRETTY_NAME:-CachyOS}"
    else
        fail "expected CachyOS, detected: ${PRETTY_NAME:-unknown}"
    fi
}

check_niri_config() {
    local config="$HOME/.config/niri/config.kdl"
    local include_path
    if [[ -s "$config" ]]; then
        pass "Niri config exists: $config"
    else
        fail "Niri config is missing or empty: $config"
        return
    fi

    for include_path in colors layout alttab binds outputs cursor; do
        if grep -Eq "^[[:space:]]*include[[:space:]]+(optional=true[[:space:]]+)?\"dms/$include_path\\.kdl\"([[:space:]]|$)" "$config"; then
            pass "Niri config includes dms/$include_path.kdl"
        else
            fail "Niri config does not include dms/$include_path.kdl"
        fi
    done

    if grep -Fqx 'include "cachyos-extras.kdl"' "$config"; then
        pass "Niri config includes cachyos-extras.kdl"
    else
        fail "Niri config does not include cachyos-extras.kdl"
    fi

    if command -v niri >/dev/null 2>&1 && niri --help 2>&1 | grep -q 'validate'; then
        if niri validate -c "$config" >/dev/null 2>&1; then
            pass "Niri configuration validates"
        else
            fail "Niri configuration validation failed; run: niri validate -c $config"
        fi
    fi
}

check_dms_binding() {
    local wants
    wants="$(systemctl --user show niri.service --property=Wants --value 2>/dev/null || true)"
    if tr ' ' '\n' <<< "$wants" | grep -qx 'dms.service'; then
        pass "DMS is bound to the Niri user service"
    else
        warn "DMS is not bound to niri.service"
        warn "run: systemctl --user add-wants niri.service dms.service"
    fi
}

check_hardware() {
    local device vendor driver expected_driver
    cachyos_detect_hardware
    cachyos_select_hardware_packages

    pass "detected hardware: $(cachyos_hardware_summary)"
    for device in "${CACHYOS_GPU_DEVICES[@]}"; do
        vendor="${device%%:*}"
        driver="${device#*:}"
        case "$vendor" in
            intel) expected_driver='i915 or xe' ;;
            amd) expected_driver='amdgpu' ;;
            nvidia) expected_driver='nvidia or nouveau' ;;
            *) expected_driver='a supported kernel driver' ;;
        esac

        case "$vendor:$driver" in
            intel:i915|intel:xe|amd:amdgpu|nvidia:nvidia|nvidia:nouveau)
                pass "$vendor GPU uses $driver"
                ;;
            *)
                warn "$vendor GPU driver is ${driver:-unknown}; expected $expected_driver"
                ;;
        esac
    done
    if ((${#CACHYOS_GPU_DEVICES[@]} == 0)); then
        warn "no GPU was detected"
    fi

    if command -v vulkaninfo >/dev/null 2>&1; then
        if vulkaninfo --summary >/dev/null 2>&1; then
            pass "Vulkan initializes successfully"
        else
            warn "Vulkan initialization failed in the current session"
        fi
    else
        warn "vulkaninfo is unavailable"
    fi
}

check_applications() {
    local package_name
    local -a packages=(
        "${DAILY_APP_PACKAGES[@]}"
        "${CHINESE_PACKAGES[@]}"
        "${OFFICE_PACKAGES[@]}"
        "${DEVELOPMENT_PACKAGES[@]}"
        "${MEDIA_PACKAGES[@]}"
        "${VIRTUALIZATION_PACKAGES[@]}"
        "${GAMING_PACKAGES[@]}"
        "${SYSTEM_TOOL_PACKAGES[@]}"
        "${AUR_PACKAGES[@]}"
    )

    for package_name in "${packages[@]}"; do
        check_package "$package_name"
    done

    check_system_service libvirtd.service
    if id -nG | tr ' ' '\n' | grep -qx libvirt; then
        pass "current user belongs to the libvirt group"
    else
        warn "current user does not belong to the libvirt group"
    fi
}

check_desktop_extras() {
    local command_name
    for command_name in \
        kitty fish starship eza zoxide fastfetch codex claude waybar awww-daemon waypaper satty wf-recorder fuzzel cachyos-input-toggle cachyos-ai-config-sync \
        niri-sidebar niriusd nirius waycorner woomer ddcutil wlsunset; do
        check_command "$command_name"
    done

    local helper
    for helper in "$SCRIPT_DIR"/bin/*; do
        [[ -f "$helper" ]] || continue
        check_command "${helper##*/}"
    done
    for helper in cachyos-niri-pick cachyos-niri-force-kill-window cachyos-quick-rollback; do
        if [[ -x "$SCRIPT_DIR/bin/$helper" ]]; then
            pass "required keybinding helper exists in project: $helper"
        else
            fail "required keybinding helper is missing from project: $helper"
        fi
        if grep -Fq "spawn \"$helper\"" "$SCRIPT_DIR/assets/niri/binds.kdl"; then
            pass "Niri keybindings reference required helper: $helper"
        else
            fail "Niri keybindings do not reference required helper: $helper"
        fi
    done

    local force_kill_binding
    for force_kill_binding in Alt+4 Alt+F4; do
        if grep -Eq "^[[:space:]]*${force_kill_binding//+/\\+}[[:space:]].*spawn \"cachyos-niri-force-kill-window\";" "$SCRIPT_DIR/assets/niri/binds.kdl"; then
            pass "Niri keybindings provide force kill: $force_kill_binding"
        else
            fail "Niri keybindings are missing force kill: $force_kill_binding"
        fi
    done
    if grep -Eq '^[[:space:]]*Alt\+Shift\+F4[[:space:]].*spawn "cachyos-niri-force-kill-window" "-f";' "$SCRIPT_DIR/assets/niri/binds.kdl"; then
        pass "Niri keybindings provide force kill tree: Alt+Shift+F4"
    else
        fail "Niri keybindings are missing force kill tree: Alt+Shift+F4"
    fi

    local source_path target_path
    while IFS=$'\t' read -r source_path target_path; do
        [[ -n "$source_path" && -n "$target_path" ]] || continue
        check_file "$HOME/$target_path"
    done < "$SCRIPT_DIR/assets/config-manifest.tsv"

    local generated_asset
    for generated_asset in colors layout alttab outputs cursor wpblur; do
        if [[ -e "$HOME/.config/niri/dms/$generated_asset.kdl" ]]; then
            pass "DMS generated Niri asset exists: dms/$generated_asset.kdl"
        else
            fail "DMS generated Niri asset is missing: dms/$generated_asset.kdl"
        fi
    done
    if cmp -s "$SCRIPT_DIR/assets/niri/binds.kdl" "$HOME/.config/niri/dms/binds.kdl"; then
        pass "current-system Niri asset is installed: dms/binds.kdl"
    else
        fail "installed Niri asset differs from assets/niri/binds.kdl"
    fi
    if cmp -s "$SCRIPT_DIR/assets/niri/cachyos-extras.kdl" "$HOME/.config/niri/cachyos-extras.kdl"; then
        pass "current-system Niri asset is installed: cachyos-extras.kdl"
    else
        fail "installed Niri asset differs from assets/niri/cachyos-extras.kdl"
    fi
    if cmp -s <(render_project_niri_config) "$HOME/.config/niri/config.kdl"; then
        pass "rendered current-system Niri main config is installed"
    else
        fail "installed Niri main config differs from rendered assets/niri/config.kdl"
    fi

    check_file "$HOME/.config/waybar/style.css"
    check_file "$HOME/.config/kitty/cachyos-font.conf"
    if grep -Fqx 'include cachyos-font.conf' "$HOME/.config/kitty/kitty.conf" 2>/dev/null; then
        pass "Kitty includes the CachyOS font configuration"
    else
        fail "Kitty does not include cachyos-font.conf"
    fi
    check_file "$HOME/.config/waycorner/config.toml"
    check_file "$HOME/.config/niri-sidebar/config.toml"
    check_file /etc/firefox/policies/policies.json
    check_file /etc/modules-load.d/i2c-dev.conf
    check_file /etc/udev/rules.d/60-cachyos-ddcutil-i2c.rules
    check_file /usr/local/share/cachyos-desktop/config-manifest.tsv

    check_system_service ly@tty2.service
    if [[ "$(getent passwd "$(id -un)" | cut -d: -f7)" == /usr/bin/fish ]]; then
        pass "Fish is the current user's login shell"
    else
        warn "Fish is not the current user's login shell"
    fi

    if [[ "$(findmnt -no FSTYPE / 2>/dev/null || true)" == btrfs ]]; then
        if [[ -e /etc/snapper/configs/root ]]; then
            pass "Snapper root configuration exists"
        else
            fail "Snapper root configuration is missing"
        fi
    fi

    if getent group i2c >/dev/null 2>&1; then
        pass "i2c group exists"
    else
        fail "i2c group is missing"
    fi
    if id -nG | tr ' ' '\n' | grep -qx i2c; then
        pass "current user belongs to the i2c group"
    else
        warn "current user does not yet belong to the i2c group; log out once"
    fi
    if grep -qw i2c_dev /proc/modules 2>/dev/null; then
        pass "i2c-dev kernel module is loaded"
    else
        warn "i2c-dev kernel module is not currently loaded"
    fi

    if jq -e '.policies.ExtensionSettings["uBlock0@raymondhill.net"].installation_mode == "force_installed"' \
        /etc/firefox/policies/policies.json >/dev/null 2>&1; then
        pass "Firefox policy force-installs uBlock Origin"
    else
        fail "Firefox uBlock Origin policy is missing"
    fi

    local setup_marker
    for setup_marker in cachyos-firefox-setup-v1 cachyos-code-theme-v1 cachyos-wine-setup-v1 cachyos-agent-skills-v1; do
        if [[ -e "$HOME/.local/state/cachyos-desktop/$setup_marker" ]]; then
            pass "first-login initializer completed: $setup_marker"
        else
            warn "first-login initializer has not completed yet: $setup_marker"
        fi
    done

    if [[ -s "$HOME/.config/codex-desktop/cc-switch-sync.json" && -s "$HOME/.cc-switch/codex-desktop-sync.json" ]]; then
        if cmp -s "$HOME/.config/codex-desktop/cc-switch-sync.json" "$HOME/.cc-switch/codex-desktop-sync.json" &&
            [[ "$(stat -c '%a' "$HOME/.config/codex-desktop/cc-switch-sync.json" 2>/dev/null)" == 600 ]] &&
            jq -e '.schema_version == 1 and .source == "cc-switch" and (.cc_switch | type == "object")' "$HOME/.config/codex-desktop/cc-switch-sync.json" >/dev/null 2>&1; then
            pass "CC Switch and Codex Desktop non-sensitive mirrors are valid"
        else
            fail "CC Switch/Codex Desktop mirrors are invalid, mismatched, or insecure"
        fi
    else
        warn "CC Switch/Codex Desktop mirrors are not initialized; run cachyos-ai-config-sync sync"
    fi

    if pacman -Q codex-desktop-git >/dev/null 2>&1 && [[ -x /usr/bin/codex-desktop ]]; then
        if [[ -s /opt/codex-desktop/.codex-linux/build-info.json ]] &&
            jq -e '.source.provenance == "git" and (.source.commit | type == "string" and length > 0)' /opt/codex-desktop/.codex-linux/build-info.json >/dev/null 2>&1; then
            pass "Codex Desktop AUR package has Git build metadata"
        else
            warn "Codex Desktop Git build metadata is unavailable"
        fi
    fi
}

check_neutral_install() {
    local blocked_name='sho''rin'
    local matches=""

    matches="$(pacman -Qq | awk -v blocked="$blocked_name" 'index(tolower($0), blocked)' || true)"
    if [[ -n "$matches" ]]; then
        fail "legacy branded packages remain installed"
    else
        pass "no legacy branded packages remain installed"
    fi

    matches="$(
        for root in "$HOME/.config/niri" "$HOME/.local/bin" /usr/local/bin /usr/local/share; do
            [[ -d "$root" ]] || continue
            find "$root" -iname "*$blocked_name*" -print 2>/dev/null
        done
    )"
    if [[ -n "$matches" ]]; then
        fail "legacy branded paths remain on the system"
    else
        pass "no legacy branded paths remain in managed locations"
    fi

    if [[ -d "$HOME/.config/niri" ]] && grep -RIil "$blocked_name" "$HOME/.config/niri" >/dev/null 2>&1; then
        fail "legacy branded text remains in the Niri configuration"
    else
        pass "Niri configuration is brand-neutral"
    fi
}

check_ai_agent_stack() {
    local share_dir="${CACHYOS_DESKTOP_SHARE_DIR:-/usr/local/share/cachyos-desktop}"
    local skill_root="$share_dir/assets/agent-skills"
    local skill
    local harness_dir
    local link

    check_file "$share_dir/assets/lib/agent.sh"
    check_file "$share_dir/assets/lib/agent_usage.py"
    check_file "$share_dir/assets/lib/agent_theme.py"
    check_file "$share_dir/assets/lib/tui.sh"
    for skill in cachyos diagnose-crash; do
        check_file "$skill_root/$skill/SKILL.md"
    done

    # 三条快捷键必须逐条走 cachyos-agent，否则无人值守旗标和统一窗口 class 会失效。
    # 只 grep 一次"存在"是不够的：删掉其中两条、只留一条也会通过。
    # 格式为「显示名|正则」；正则里 Mod+ 的加号必须转义，grep -E 下它是量词。
    local -a agent_bindings=(
        'Mod+Alt+O|Mod\+Alt\+O[[:space:]].*spawn "cachyos-agent" "opencode"'
        'Mod+Alt+C|Mod\+Alt\+C[[:space:]].*spawn "cachyos-agent" "claude"'
        'Mod+grave|Mod\+grave[[:space:]].*spawn "cachyos-agent"'
    )
    local binding key pattern
    for binding in "${agent_bindings[@]}"; do
        key="${binding%%|*}"
        pattern="${binding#*|}"
        if grep -Eq "^[[:space:]]*$pattern" "$SCRIPT_DIR/assets/niri/binds.kdl"; then
            pass "Niri keybinding launches an agent through cachyos-agent: $key"
        else
            fail "Niri keybinding is missing or bypasses cachyos-agent: $key"
        fi
    done

    # 技能软链只在对应 harness 目录存在时才有意义；目录不存在是正常的，不算失败。
    for harness_dir in .claude/skills .codex/skills; do
        [[ -d "$HOME/$harness_dir" ]] || continue
        for skill in cachyos diagnose-crash; do
            link="$HOME/$harness_dir/$skill"
            if [[ -L "$link" && "$(readlink -f "$link")" == "$skill_root/$skill" ]]; then
                pass "agent skill symlink is current: $harness_dir/$skill"
            else
                fail "agent skill symlink is missing or stale: $harness_dir/$skill (run cachyos-agent-skills)"
            fi
        done
    done

    # 崩溃监听跟随 niri 会话；安装时用户管理器可能不可达，所以只警告。
    # 关闭标记必须被单元读取，否则"关闭崩溃捕获"只在本次会话有效。
    if grep -q 'ConditionPathExists=!.*crash-capture-off' \
        "$SCRIPT_DIR/assets/systemd/user/cachyos-crash-watch.service"; then
        pass "crash watch honours the disable flag across logins"
    else
        fail "crash watch does not read the crash-capture-off flag"
    fi

    # 用量记录靠定时器周期性重算；定时器没起来，面板就会一直显示安装那一刻的数字。
    if systemctl --user is-enabled --quiet cachyos-agent-usage.timer 2>/dev/null; then
        pass "agent usage refresh timer is enabled"
    else
        fail "cachyos-agent-usage.timer is not enabled (rerun the installer)"
    fi
    if systemctl --user is-active --quiet cachyos-agent-usage.timer 2>/dev/null; then
        pass "agent usage refresh timer is active"
    else
        fail "cachyos-agent-usage.timer is not active"
    fi

    if systemctl --user is-enabled --quiet cachyos-crash-watch.service 2>/dev/null; then
        pass "cachyos-crash-watch.service is enabled"
    else
        warn "cachyos-crash-watch.service is not enabled (run: systemctl --user enable --now cachyos-crash-watch.service)"
    fi
}

check_dms_plugin_stack() {
    local collector agent
    local share_dir="${CACHYOS_DESKTOP_SHARE_DIR:-/usr/local/share/cachyos-desktop}"
    local plugin_dir="$HOME/.config/DankMaterialShell/plugins/CachyosAgents"
    local settings_file="$HOME/.config/DankMaterialShell/settings.json"
    local plugin_settings="$HOME/.config/DankMaterialShell/plugin_settings.json"
    local asset

    # 随包副本：用户目录里的插件被改坏时，重跑安装器就能修回来。
    for asset in plugin.json Usage.js UsageSource.qml CachyosAgents.qml UsageDetails.qml CachyosAgentsSettings.qml; do
        check_file "$share_dir/assets/dms-plugins/CachyosAgents/$asset"
    done
    check_file "$share_dir/assets/dms/add-agents-bar-widget.jq"
    check_file "$share_dir/assets/dms/enable-dms-plugin.jq"

    # 运行副本。
    for asset in plugin.json Usage.js UsageSource.qml CachyosAgents.qml UsageDetails.qml CachyosAgentsSettings.qml; do
        check_file "$plugin_dir/$asset"
    done

    # 下面两处决定"装了但看不见"：插件没启用、或没接到状态栏上。
    if [[ -f "$plugin_settings" ]] && jq -e '.cachyosAgents.enabled == true' "$plugin_settings" >/dev/null 2>&1; then
        pass "DMS usage plugin is enabled"
    else
        warn "DMS usage plugin is not enabled (Settings > Plugins, or rerun the installer)"
    fi

    # 插件已启用、却没有任何一条 barConfigs 含它 ⇒ 用户看不到任何东西，这是功能不成立，
    # 不是"提醒"。反过来若插件没启用，就不要强求接线（用户可能故意不开）。
    local plugin_enabled=false
    if [[ -f "$plugin_settings" ]] && jq -e '.cachyosAgents.enabled == true' "$plugin_settings" >/dev/null 2>&1; then
        plugin_enabled=true
    fi

    if [[ -f "$settings_file" ]] && jq -e '
            [.barConfigs[]? | (.leftWidgets? // [])[], (.centerWidgets? // [])[], (.rightWidgets? // [])[]
             | if type == "object" then .id else . end] | index("cachyosAgents") != null' \
            "$settings_file" >/dev/null 2>&1; then
        pass "DMS usage widget is placed on the DankBar"
    elif [[ $plugin_enabled == true ]]; then
        fail "DMS usage plugin is enabled but the widget is on no bar (Settings > Bar, or rerun the installer)"
    else
        warn "DMS usage widget is not placed on the DankBar (plugin disabled, so that is allowed)"
    fi

    # 面板没有记录可读时会显示占位符，所以这里也确认采集器至少跑成功过一次。
    # 每个采集器都必须在面板的 agents 表里登记：加了采集器却忘了登记，面板永远不会显示它
    # （README 提醒过、我自己也踩过一次）。
    for collector in "$SCRIPT_DIR"/bin/cachyos-agent-usage-*; do
        [[ -f $collector ]] || continue
        agent="${collector##*/cachyos-agent-usage-}"
        [[ $agent == update ]] && continue
        if grep -q "id: \"$agent\"" "$SCRIPT_DIR/assets/dms-plugins/CachyosAgents/Usage.js"; then
            pass "usage collector is registered in the panel: $agent"
        else
            fail "usage collector is missing from the panel agents table: $agent"
        fi
    done

    if compgen -G "$HOME/.local/state/cachyos-desktop/agents/usage/*.json" >/dev/null; then
        pass "agent usage records exist"
    else
        warn "no agent usage records yet (run cachyos-agent-usage-update)"
    fi
}

check_voxtype_stack() {
    local share_dir="${CACHYOS_DESKTOP_SHARE_DIR:-/usr/local/share/cachyos-desktop}"
    local waybar_file

    # voxtype 本身是可选软件（模型约 150MB），没装不算失败；这里只检查"随包资源与接线"
    # 是否就位——它们决定用户执行 cachyos-voxtype-install 时能不能一次成功。
    check_file "$share_dir/assets/voxtype/config.toml"
    check_file "$share_dir/assets/niri/cachyos-voxtype.kdl"

    # 快捷键走"可选 include"：Niri 没有条件绑定，这样没装听写的人不会白白失去这些键。
    if grep -Eq '^include optional=true "cachyos-voxtype.kdl"' "$SCRIPT_DIR/assets/niri/config.kdl"; then
        pass "Niri includes the dictation bindings optionally"
    else
        fail "Niri does not include cachyos-voxtype.kdl as an optional include"
    fi

    # 状态控件：两个栏都要有，否则切到另一个栏就看不到听写状态。
    for waybar_file in top.jsonc bottom.jsonc; do
        if jq -e '."custom/voxtype".exec == "cachyos-voxtype-status"' \
            "$SCRIPT_DIR/assets/waybar/$waybar_file" >/dev/null 2>&1 &&
            jq -e '."modules-right" | index("custom/voxtype")' \
                "$SCRIPT_DIR/assets/waybar/$waybar_file" >/dev/null 2>&1; then
            pass "Waybar ($waybar_file) has the dictation status module"
        else
            fail "Waybar ($waybar_file) is missing the dictation status module"
        fi
    done
}

check_agent_theme_sync() {
    local share_dir="${CACHYOS_DESKTOP_SHARE_DIR:-/usr/local/share/cachyos-desktop}"
    local unit_dir="$HOME/.config/systemd/user"
    local unit

    # 这条检查过去只会 pass/warn，从不说 fail——结果"单元指向不存在的可执行文件 + 同步脚本
    # 直接 exit 1"也能让 verify 全绿。下面几条是真正能失败的：
    for unit in cachyos-agent-theme.service cachyos-agent-theme.path; do
        if [[ -s "$unit_dir/$unit" ]] && cmp -s "$share_dir/assets/systemd/user/$unit" "$unit_dir/$unit"; then
            pass "installed theme unit matches the shipped one: $unit"
        else
            fail "installed theme unit differs from the shipped one (rerun the installer): $unit"
        fi
    done

    # ExecStart 指向的命令必须真的存在，否则 path 单元每次触发都是失败。
    if [[ -x /usr/local/bin/cachyos-agent-theme-sync ]]; then
        pass "theme sync binary is installed and executable"
    else
        fail "cachyos-agent-theme-sync is missing or not executable"
    fi

    if ! systemctl --user show-environment >/dev/null 2>&1; then
        # systemctl 本身不可用（例如不在用户会话里）：这里只能提醒，不算功能缺陷。
        warn "systemctl --user is unavailable; skipped the theme sync unit checks"
        return 0
    fi

    if systemctl --user is-enabled --quiet cachyos-agent-theme.path 2>/dev/null; then
        pass "theme sync path unit is enabled"
    else
        fail "cachyos-agent-theme.path is not enabled (rerun the installer)"
    fi

    if systemctl --user is-active --quiet cachyos-agent-theme.path 2>/dev/null; then
        pass "theme sync path unit is active"
    else
        fail "cachyos-agent-theme.path is not active"
    fi

    # 真正读一次配色文件并按模式算出目标值；失败说明配色文件缺失或不可读。
    if cachyos-agent-theme-sync --status --quiet >/dev/null 2>&1; then
        pass "theme sync can read the DMS colour palette"
    else
        fail "theme sync cannot read the DMS colour palette"
    fi
}

check_lock_screen() {
    local command_name
    local settings_file="$HOME/.config/DankMaterialShell/settings.json"
    local defaults_file="$SCRIPT_DIR/assets/dms/desktop-settings.json"

    for command_name in fprintd-enroll fprintd-list pamu2fcfg cachyos-dms-setting cachyos-enroll-fingerprint cachyos-register-security-key cachyos-lock-doctor; do
        check_command "$command_name"
    done

    if [[ -s "$settings_file" ]] && jq --exit-status --slurp \
        '((.[0] * .[1]) == .[0])' "$settings_file" "$defaults_file" >/dev/null 2>&1; then
        pass "managed DMS desktop settings are configured"
    else
        fail "managed DMS desktop settings are missing or incomplete"
    fi

    if dms auth validate --purpose u2f --path /etc/pam.d/dankshell-u2f >/dev/null 2>&1; then
        pass "DMS U2F PAM service validates"
    else
        fail "DMS U2F PAM service validation failed"
    fi

    if dms ipc call lock isLocked >/dev/null 2>&1; then
        pass "DMS lock IPC is available"
    else
        warn "DMS lock IPC is unavailable in the current session"
    fi

    if jq -e '.enableFprint == true' "$settings_file" >/dev/null 2>&1; then
        if fprintd-list "$(id -un)" >/dev/null 2>&1; then
            pass "fingerprint unlock is enabled with an enrolled print"
        else
            fail "fingerprint unlock is enabled without a usable enrollment"
        fi
    else
        warn "fingerprint unlock is ready but not enrolled/enabled"
    fi

    if jq -e '.enableU2f == true' "$settings_file" >/dev/null 2>&1; then
        if [[ -s /etc/u2f-mappings ]]; then
            pass "security-key unlock is enabled with a mapping"
        else
            fail "security-key unlock is enabled without a mapping"
        fi
    else
        warn "security-key unlock is ready but not registered/enabled"
    fi
}

main() {
    printf '%s\n' 'CachyOS + Niri + DMS verification'

    check_os

    local command_name
    for command_name in niri dms quickshell xwayland-satellite; do
        check_command "$command_name"
    done

    cachyos_detect_hardware
    cachyos_select_hardware_packages

    local package_name
    for package_name in niri dms-shell quickshell xwayland-satellite "${CACHYOS_HARDWARE_REQUIRED_PACKAGES[@]}"; do
        check_package "$package_name"
    done

    if [[ -e /usr/share/wayland-sessions/niri.desktop ]]; then
        pass "Niri display-manager session is installed"
    else
        warn "Niri session entry was not found under /usr/share/wayland-sessions"
    fi

    check_niri_config
    check_dms_binding
    check_system_service bluetooth.service
    check_power_profile_service
    check_hardware
    check_applications
    check_desktop_extras
    check_ai_agent_stack
    check_dms_plugin_stack
    check_voxtype_stack
    check_agent_theme_sync
    check_lock_screen
    check_neutral_install

    printf '\nSummary: %d passed, %d warnings, %d failed\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    ((FAIL_COUNT == 0))
}

main "$@"
