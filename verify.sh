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
    for setup_marker in cachyos-firefox-setup-v1 cachyos-code-theme-v1 cachyos-wine-setup-v1; do
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
    check_lock_screen
    check_neutral_install

    printf '\nSummary: %d passed, %d warnings, %d failed\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    ((FAIL_COUNT == 0))
}

main "$@"
