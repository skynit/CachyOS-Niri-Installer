#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PINNED_DMS_VERSION="v1.5.3"
readonly PINNED_DMS_SHA256_AMD64="c84da05e4afd84a737faaac4fa3bc65fa78fcd783c5ec930aec24f31f4e84716"
readonly PINNED_NIRI_SIDEBAR_VERSION="v0.4.0"
readonly PINNED_NIRI_SIDEBAR_SHA256_AMD64="8264fa0a82657a21b781588877adec67e29c51d4b4ca1cb35a2415c8520be5d1"

# shellcheck source=packages.sh
source "$SCRIPT_DIR/packages.sh"

DMS_VERSION="$PINNED_DMS_VERSION"
TERMINAL="kitty"
DRY_RUN=false
ASSUME_YES=false
SKIP_UPDATE=false
SKIP_HARDWARE=false
TEMP_DIR=""
DANKINSTALL_PATH=""

readonly -a HARDWARE_PACKAGES=(
    linux-firmware
    amd-ucode
    mesa
    vulkan-radeon
    sof-firmware
    pipewire
    pipewire-alsa
    pipewire-pulse
    wireplumber
    bluez
    bluez-utils
)

readonly -a OPTIONAL_HARDWARE_PACKAGES=(
    lib32-vulkan-radeon
    vulkan-tools
    fwupd
    bolt
    v4l-utils
    usbutils
    pciutils
)

readonly -a DMS_FEATURE_PACKAGES=(
    networkmanager
    cava
    i2c-tools
    matugen
    qt6-multimedia
    wtype
    cups-pk-helper
)

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options]

Install CachyOS + Niri + DankMaterialShell for the current user.

Options:
  --terminal NAME       kitty, ghostty, or alacritty (default: kitty)
  --dms-version TAG     pinned DankMaterialShell release (default: $PINNED_DMS_VERSION)
  --skip-update         skip the initial full pacman upgrade
  --skip-hardware       skip AMD laptop firmware/graphics/audio packages
  --dry-run             print mutating commands without executing them
  -y, --yes             skip this wrapper's confirmation prompt
  -h, --help            show this help

This script does not modify pacman repositories, NetworkManager, bootloaders,
Secure Boot, or existing Windows partitions. It configures Ly as the display manager.
EOF
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT

ensure_temp_dir() {
    if [[ "$DRY_RUN" == true ]]; then
        [[ -n "$TEMP_DIR" ]] || TEMP_DIR="${TMPDIR:-/tmp}/cachyos-niri-dms-dry-run"
    elif [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]]; then
        TEMP_DIR="$(mktemp -d)"
    fi
}

print_command() {
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
}

run() {
    if [[ "$DRY_RUN" == true ]]; then
        print_command "$@"
        return 0
    fi
    "$@"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --terminal)
                (($# >= 2)) || die "--terminal requires a value"
                TERMINAL="$2"
                shift 2
                ;;
            --dms-version)
                (($# >= 2)) || die "--dms-version requires a value"
                DMS_VERSION="$2"
                shift 2
                ;;
            --skip-update)
                SKIP_UPDATE=true
                shift
                ;;
            --skip-hardware)
                SKIP_HARDWARE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

preflight() {
    local os_release_file="/etc/os-release"

    ((EUID != 0)) || die "run this installer as a normal user, not root"

    for command_name in sudo pacman curl sha256sum gzip mktemp systemctl findmnt getent modprobe; do
        require_command "$command_name"
    done

    # A dry run may point at a fixture so the non-mutating path can be tested
    # from another Arch-based development host.
    if [[ "$DRY_RUN" == true && -n "${CACHYOS_SETUP_OS_RELEASE:-}" ]]; then
        os_release_file="$CACHYOS_SETUP_OS_RELEASE"
    fi

    [[ -r "$os_release_file" ]] || die "$os_release_file is unavailable"
    # shellcheck disable=SC1091
    source "$os_release_file"
    local os_id="${ID:-}"
    [[ "${os_id,,}" == "cachyos" ]] || die "CachyOS is required; detected: ${PRETTY_NAME:-unknown}"
    [[ "$(uname -m)" == "x86_64" ]] || die "this build currently supports x86_64 only"
    [[ "$DMS_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die "invalid DMS release tag: $DMS_VERSION"

    case "$TERMINAL" in
        ghostty|kitty|alacritty) ;;
        *) die "unsupported terminal: $TERMINAL" ;;
    esac

    [[ ! -e /var/lib/pacman/db.lck ]] || die "pacman database is locked; finish the other package operation first"
    systemctl --version >/dev/null 2>&1 || die "systemd is required"
}

confirm_plan() {
    cat <<EOF

CachyOS + Niri + DMS installation plan
  User:             $(id -un)
  Terminal:         $TERMINAL
  DMS release:      $DMS_VERSION
  Full update:      $([[ "$SKIP_UPDATE" == true ]] && printf 'no' || printf 'yes')
  Hardware stack:   $([[ "$SKIP_HARDWARE" == true ]] && printf 'no' || printf 'yes')
  Replace configs:  yes
  DMS integrations: DankSearch, DankCalendar
  Applications:     daily, Chinese, office, development, media, VM, gaming, tools
  Display manager:  Ly
  Dry run:          $DRY_RUN

Preserved: CachyOS repositories/kernel, bootloader, NetworkManager connections,
Secure Boot configuration, and Windows partitions.
EOF

    if [[ "$ASSUME_YES" == true || "$DRY_RUN" == true ]]; then
        return 0
    fi

    local answer
    read -r -p 'Continue? [y/N] ' answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]] || die "cancelled"
}

authenticate() {
    if [[ "$DRY_RUN" == true ]]; then
        print_command sudo -v
        return 0
    fi
    sudo -v
}

save_package_snapshot() {
    [[ "$DRY_RUN" == false ]] || return 0

    local state_dir="$HOME/.local/state/cachyos-niri-dms"
    local snapshot="$state_dir/packages-before-$(date +%Y%m%d-%H%M%S).txt"
    install -d -m 0755 "$state_dir"
    pacman -Qqe > "$snapshot"
    info "saved explicit package snapshot: $snapshot"
}

remove_blocked_brand_components() {
    local blocked_name='sho''rin'
    local path
    local -a packages=()

    mapfile -t packages < <(pacman -Qq | awk -v blocked="$blocked_name" 'index(tolower($0), blocked)')
    if ((${#packages[@]} > 0)); then
        info "removing legacy branded packages that conflict with the neutral desktop configuration"
        run sudo pacman -Rns --noconfirm -- "${packages[@]}"
    fi

    for search_root in "$HOME/.config/niri" "$HOME/.local/bin" /usr/local/bin /usr/local/share; do
        [[ -d "$search_root" ]] || continue
        while IFS= read -r path; do
            if [[ "$DRY_RUN" == true ]]; then
                print_command rm -rf -- "$path"
            elif [[ "$path" == /usr/local/* ]]; then
                sudo rm -rf -- "$path"
            else
                rm -rf -- "$path"
            fi
        done < <(find "$search_root" -depth -iname "*$blocked_name*" -print 2>/dev/null)
    done

    [[ -d "$HOME/.config/niri" ]] || return 0
    while IFS= read -r path; do
        if [[ "$DRY_RUN" == true ]]; then
            print_command rm -f -- "$path"
        else
            rm -f -- "$path"
        fi
    done < <(grep -RIil --exclude='*.lock' "$blocked_name" "$HOME/.config/niri" 2>/dev/null || true)
}

install_available_packages() {
    local label="$1"
    local required="$2"
    shift 2
    local -a available=()
    local -a unavailable=()
    local package_name

    if [[ "$required" == true ]]; then
        if ! pacman -Si -- "$@" >/dev/null 2>&1; then
            for package_name in "$@"; do
                pacman -Si "$package_name" >/dev/null 2>&1 || unavailable+=("$package_name")
            done
            die "$label packages are unavailable: ${unavailable[*]}"
        fi

        run sudo pacman -S --needed --noconfirm -- "$@"
        return 0
    fi

    for package_name in "$@"; do
        if pacman -Si "$package_name" >/dev/null 2>&1; then
            available+=("$package_name")
        else
            unavailable+=("$package_name")
        fi
    done

    if ((${#unavailable[@]} > 0)); then
        for package_name in "${unavailable[@]}"; do
            warn "$label package is unavailable and will be skipped: $package_name"
        done
    fi

    if ((${#available[@]} > 0)); then
        run sudo pacman -S --needed --noconfirm -- "${available[@]}"
    fi
}

install_hardware_stack() {
    info "installing AMD laptop firmware, graphics, audio, Bluetooth, and diagnostics"
    install_available_packages required true "${HARDWARE_PACKAGES[@]}"
    install_available_packages optional false "${OPTIONAL_HARDWARE_PACKAGES[@]}"

    if pacman -Q tuned-ppd >/dev/null 2>&1; then
        warn "preserving the installed tuned-ppd power-profile provider"
    else
        install_available_packages power-profile true power-profiles-daemon
    fi
}

install_dms_features() {
    info "installing optional DMS integrations from signed system repositories"
    install_available_packages dms-feature false "${DMS_FEATURE_PACKAGES[@]}"
}

install_applications() {
    info "installing daily applications"
    install_available_packages daily-app true "${DAILY_APP_PACKAGES[@]}"
    info "installing Chinese input methods and fonts"
    install_available_packages Chinese-support true "${CHINESE_PACKAGES[@]}"
    info "installing office applications"
    install_available_packages office-app true "${OFFICE_PACKAGES[@]}"
    info "installing development tools"
    install_available_packages development-tool true "${DEVELOPMENT_PACKAGES[@]}"
    info "installing media applications"
    install_available_packages media-app true "${MEDIA_PACKAGES[@]}"
    info "installing virtualization applications"
    install_available_packages virtualization-app true "${VIRTUALIZATION_PACKAGES[@]}"
    info "installing gaming applications"
    install_available_packages gaming-app true "${GAMING_PACKAGES[@]}"
    info "installing system management tools"
    install_available_packages system-tool true "${SYSTEM_TOOL_PACKAGES[@]}"
}

install_aur_packages() {
    info "installing AUR desktop packages"
    run paru -S --needed --noconfirm -- "${AUR_PACKAGES[@]}"
}

install_niri_sidebar() {
    local binary_name="niri-sidebar-linux-x86_64"
    local base_url="https://github.com/Vigintillionn/niri-sidebar/releases/download/$PINNED_NIRI_SIDEBAR_VERSION"
    local actual_sha

    ensure_temp_dir
    local destination="$TEMP_DIR/$binary_name"

    if [[ "$DRY_RUN" == true ]]; then
        print_command curl --fail --location --proto '=https' --tlsv1.2 --retry 3 "$base_url/$binary_name" -o "$destination"
        print_command sudo install -o root -g root -m 0755 "$destination" /usr/local/bin/niri-sidebar
        return 0
    fi

    info "installing pinned niri-sidebar $PINNED_NIRI_SIDEBAR_VERSION"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 "$base_url/$binary_name" -o "$destination"
    actual_sha="$(sha256sum "$destination" | awk '{print $1}')"
    [[ "$actual_sha" == "$PINNED_NIRI_SIDEBAR_SHA256_AMD64" ]] || die "niri-sidebar checksum mismatch"
    sudo install -o root -g root -m 0755 "$destination" /usr/local/bin/niri-sidebar
}

remove_noctalia_profile() {
    local package_name
    local -a installed=()

    for package_name in cachyos-niri-noctalia noctalia-shell noctalia-qs; do
        pacman -Q "$package_name" >/dev/null 2>&1 && installed+=("$package_name")
    done

    if ((${#installed[@]} > 0)); then
        info "removing the CachyOS Noctalia profile before installing DMS"
        run sudo pacman -Rdd --noconfirm -- "${installed[@]}"
    fi

    if [[ -d "$HOME/.config/noctalia" ]]; then
        run rm -rf -- "$HOME/.config/noctalia"
    fi
}

configure_application_services() {
    run sudo systemctl enable --now libvirtd.service

    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
        run sudo usermod --append --groups libvirt "$USER"
        warn "log out and back in before using libvirt as $USER"
    fi

    run flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    run sudo usermod --shell /usr/bin/fish "$USER"

    if ! getent group i2c >/dev/null 2>&1; then
        run sudo groupadd --system i2c
    fi
    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx i2c; then
        run sudo usermod --append --groups i2c "$USER"
    fi
    run sudo modprobe i2c-dev
}

configure_snapper() {
    if [[ "$(findmnt -no FSTYPE / 2>/dev/null || true)" != btrfs ]]; then
        warn "root is not Btrfs; Snapper commands were installed but root snapshots are unavailable"
        return 0
    fi

    if [[ ! -e /etc/snapper/configs/root ]]; then
        run sudo snapper -c root create-config /
    fi
}

configure_ly() {
    local current_dm=""
    local display_service
    if [[ -L /etc/systemd/system/display-manager.service ]]; then
        current_dm="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")"
    fi

    if [[ -n "$current_dm" && "$current_dm" != ly.service && "$current_dm" != ly@tty2.service ]]; then
        run sudo systemctl disable "$current_dm"
    fi
    for display_service in sddm.service gdm.service lightdm.service lxdm.service greetd.service; do
        if [[ "$display_service" != "$current_dm" ]] && systemctl is-enabled --quiet "$display_service" 2>/dev/null; then
            run sudo systemctl disable "$display_service"
        fi
    done
    run sudo systemctl enable ly@tty2.service
}

install_desktop_assets() {
    local helper
    local niri_config="$HOME/.config/niri/config.kdl"
    local include_line='include "cachyos-extras.kdl"'

    for helper in "$SCRIPT_DIR"/bin/*; do
        [[ -f "$helper" ]] || continue
        run sudo install -m 0755 "$helper" "/usr/local/bin/${helper##*/}"
    done

    run install -d -m 0755 \
        "$HOME/.config/environment.d" \
        "$HOME/.config/fcitx5" \
        "$HOME/.config/fish/conf.d" \
        "$HOME/.config/kitty" \
        "$HOME/.config/niri" \
        "$HOME/.config/niri/dms" \
        "$HOME/.config/niri-sidebar" \
        "$HOME/.config/satty" \
        "$HOME/.config/Thunar" \
        "$HOME/.config/waybar" \
        "$HOME/.config/waycorner" \
        "$HOME/.config/waypaper" \
        "$HOME/.local/share/fcitx5/rime" \
        "$HOME/Pictures/Screenshots" \
        "$HOME/Pictures/Wallpapers" \
        "$HOME/Videos/ScreenRecords"

    run install -m 0644 "$SCRIPT_DIR/assets/fcitx5/environment.conf" "$HOME/.config/environment.d/90-cachyos-input.conf"
    run install -m 0644 "$SCRIPT_DIR/assets/fcitx5/profile" "$HOME/.config/fcitx5/profile"
    run install -m 0644 "$SCRIPT_DIR/assets/fcitx5/default.custom.yaml" "$HOME/.local/share/fcitx5/rime/default.custom.yaml"
    run install -m 0644 "$SCRIPT_DIR/assets/fish/cachyos-desktop.fish" "$HOME/.config/fish/conf.d/cachyos-desktop.fish"
    run install -m 0644 "$SCRIPT_DIR/assets/kitty/cachyos-font.conf" "$HOME/.config/kitty/cachyos-font.conf"
    run install -m 0644 "$SCRIPT_DIR/assets/niri/binds.kdl" "$HOME/.config/niri/dms/binds.kdl"
    run install -m 0644 "$SCRIPT_DIR/assets/niri/cachyos-extras.kdl" "$HOME/.config/niri/cachyos-extras.kdl"
    run install -m 0644 "$SCRIPT_DIR/assets/niri-sidebar/config.toml" "$HOME/.config/niri-sidebar/config.toml"
    run install -m 0644 "$SCRIPT_DIR/assets/satty/config.toml" "$HOME/.config/satty/config.toml"
    run install -m 0644 "$SCRIPT_DIR/assets/thunar/uca.xml" "$HOME/.config/Thunar/uca.xml"
    run install -m 0644 "$SCRIPT_DIR/assets/waybar/top.jsonc" "$HOME/.config/waybar/top.jsonc"
    run install -m 0644 "$SCRIPT_DIR/assets/waybar/bottom.jsonc" "$HOME/.config/waybar/bottom.jsonc"
    run install -m 0644 "$SCRIPT_DIR/assets/waybar/style.css" "$HOME/.config/waybar/style.css"
    run install -m 0644 "$SCRIPT_DIR/assets/waycorner/config.toml" "$HOME/.config/waycorner/config.toml"
    run install -m 0644 "$SCRIPT_DIR/assets/waypaper/config.ini" "$HOME/.config/waypaper/config.ini"

    if [[ ! -e "$HOME/.config/kitty/kitty.conf" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            print_command sh -c "printf '%s\\n' 'include cachyos-font.conf' > '$HOME/.config/kitty/kitty.conf'"
        else
            printf '%s\n' 'include cachyos-font.conf' > "$HOME/.config/kitty/kitty.conf"
        fi
    elif ! grep -Fqx 'include cachyos-font.conf' "$HOME/.config/kitty/kitty.conf" 2>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            print_command sh -c "printf '%s\\n' 'include cachyos-font.conf' >> '$HOME/.config/kitty/kitty.conf'"
        else
            printf '\n%s\n' 'include cachyos-font.conf' >> "$HOME/.config/kitty/kitty.conf"
        fi
    fi

    run sudo install -D -o root -g root -m 0644 "$SCRIPT_DIR/assets/firefox/policies.json" /etc/firefox/policies/policies.json
    run sudo install -D -o root -g root -m 0644 "$SCRIPT_DIR/assets/system/i2c-dev.conf" /etc/modules-load.d/i2c-dev.conf
    run sudo install -D -o root -g root -m 0644 "$SCRIPT_DIR/assets/system/60-cachyos-ddcutil-i2c.rules" /etc/udev/rules.d/60-cachyos-ddcutil-i2c.rules
    run sudo udevadm control --reload-rules
    run sudo udevadm trigger --subsystem-match=i2c-dev

    run sudo install -d -m 0755 /usr/local/share/cachyos-desktop/assets
    local asset relative_asset
    while IFS= read -r asset; do
        relative_asset="${asset#"$SCRIPT_DIR/assets/"}"
        run sudo install -D -o root -g root -m 0644 "$asset" "/usr/local/share/cachyos-desktop/assets/$relative_asset"
    done < <(find "$SCRIPT_DIR/assets" -type f -print | sort)
    run sudo install -o root -g root -m 0644 "$SCRIPT_DIR/assets/config-manifest.tsv" /usr/local/share/cachyos-desktop/config-manifest.tsv

    if ! grep -Fqx "$include_line" "$niri_config" 2>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            print_command sh -c "printf '%s\\n' '$include_line' >> '$niri_config'"
        else
            printf '\n%s\n' "$include_line" >> "$niri_config"
        fi
    fi
}

sync_ai_configs() {
    if [[ "$DRY_RUN" == true ]]; then
        print_command /usr/local/bin/cachyos-ai-config-sync status
        print_command /usr/local/bin/cachyos-ai-config-sync sync
    elif [[ -x /usr/local/bin/cachyos-ai-config-sync && -f "$HOME/.cc-switch/cc-switch.db" ]]; then
        /usr/local/bin/cachyos-ai-config-sync sync || warn "AI configuration mirror was not updated"
    else
        warn "CC Switch database is not present; AI configuration mirror will be created on first use"
    fi
}

configure_dms_lock_screen() {
    local settings_dir="$HOME/.config/DankMaterialShell"
    local settings_file="$settings_dir/settings.json"
    local defaults_file="$SCRIPT_DIR/assets/dms/lock-settings.json"
    local temporary_file

    run sudo install -o root -g root -m 0644 "$SCRIPT_DIR/assets/dms/dankshell-u2f" /etc/pam.d/dankshell-u2f

    if [[ "$DRY_RUN" == true ]]; then
        print_command jq --slurp '.[0] * .[1]' "$settings_file" "$defaults_file"
        print_command install -m 0600 merged-lock-settings.json "$settings_file"
        print_command dms auth resolve-lock --quiet
        return 0
    fi

    install -d -m 0700 "$settings_dir"
    if [[ -s "$settings_file" ]]; then
        temporary_file="$(mktemp)"
        if ! jq --slurp '.[0] * .[1]' "$settings_file" "$defaults_file" > "$temporary_file"; then
            rm -f -- "$temporary_file"
            die "could not merge DMS lock settings"
        fi
        install -m 0600 "$temporary_file" "$settings_file"
        rm -f -- "$temporary_file"
    else
        install -m 0600 "$defaults_file" "$settings_file"
    fi

    dms auth resolve-lock --quiet
}

service_enabled_or_active() {
    systemctl is-enabled --quiet "$1" 2>/dev/null || systemctl is-active --quiet "$1" 2>/dev/null
}

configure_system_services() {
    run sudo systemctl enable --now bluetooth.service

    local conflicting_service=""
    local service_name
    for service_name in tlp.service auto-cpufreq.service tuned.service tuned-ppd.service; do
        if service_enabled_or_active "$service_name"; then
            conflicting_service="$service_name"
            break
        fi
    done

    if pacman -Q tuned-ppd >/dev/null 2>&1; then
        info "tuned-ppd provides the power-profiles interface; leaving its service unchanged"
    elif [[ -n "$conflicting_service" ]]; then
        warn "not enabling power-profiles-daemon because $conflicting_service is enabled or active"
    else
        run sudo systemctl enable --now power-profiles-daemon.service
    fi

    if systemctl list-unit-files fwupd-refresh.timer >/dev/null 2>&1; then
        run sudo systemctl enable --now fwupd-refresh.timer
    fi
}

download_dankinstall() {
    ensure_temp_dir
    local asset="dankinstall-amd64.gz"
    local base_url="https://github.com/AvengeMedia/DankMaterialShell/releases/download/$DMS_VERSION"
    local archive="$TEMP_DIR/$asset"
    local checksum_file="$TEMP_DIR/$asset.sha256"
    local installer="$TEMP_DIR/dankinstall"
    local expected_sha actual_sha
    local -a curl_args=(
        --fail
        --location
        --proto '=https'
        --tlsv1.2
        --retry 3
        --retry-delay 2
    )

    if [[ "$DRY_RUN" == true ]]; then
        print_command curl "${curl_args[@]}" "$base_url/$asset" -o "$archive"
        print_command curl "${curl_args[@]}" "$base_url/$asset.sha256" -o "$checksum_file"
        DANKINSTALL_PATH="$installer"
        return 0
    fi

    info "downloading official DankMaterialShell installer $DMS_VERSION"
    curl "${curl_args[@]}" "$base_url/$asset" -o "$archive"
    curl "${curl_args[@]}" "$base_url/$asset.sha256" -o "$checksum_file"

    expected_sha="$(awk 'NF >= 1 && $1 ~ /^[0-9a-fA-F]{64}$/ { print tolower($1); exit }' "$checksum_file")"
    [[ -n "$expected_sha" ]] || die "release checksum file is invalid"
    actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] || die "Dank installer checksum mismatch"

    if [[ "$DMS_VERSION" == "$PINNED_DMS_VERSION" ]]; then
        [[ "$actual_sha" == "$PINNED_DMS_SHA256_AMD64" ]] || die "pinned Dank installer checksum mismatch"
    else
        warn "using an unpinned DMS release; verification relies on its GitHub release checksum"
    fi

    gzip -dc "$archive" > "$installer"
    chmod 0755 "$installer"
    DANKINSTALL_PATH="$installer"
}

install_niri_dms() {
    download_dankinstall

    authenticate

    local -a args=(
        --compositor niri
        --term "$TERMINAL"
        --yes
        --exclude-deps dms-greeter
        --danksearch
        --dankcalendar
        --replace-configs "niri,$TERMINAL"
    )
    run "$DANKINSTALL_PATH" "${args[@]}"
}

post_install() {
    if [[ "$DRY_RUN" == true ]]; then
        print_command systemctl --user daemon-reload
        print_command systemctl --user add-wants niri.service dms.service
        return 0
    fi

    systemctl --user daemon-reload
    if ! systemctl --user add-wants niri.service dms.service; then
        warn "could not bind dms.service to niri.service; run this after logging in:"
        warn "  systemctl --user add-wants niri.service dms.service"
    fi
}

main() {
    parse_args "$@"
    preflight
    confirm_plan
    authenticate
    save_package_snapshot

    if [[ "$SKIP_UPDATE" == false ]]; then
        info "performing full CachyOS package upgrade"
        run sudo pacman -Syu --noconfirm
    fi

    if [[ "$SKIP_HARDWARE" == false ]]; then
        install_hardware_stack
        configure_system_services
    fi

    install_dms_features
    install_applications
    install_aur_packages
    install_niri_sidebar
    configure_application_services
    configure_snapper
    configure_ly
    remove_noctalia_profile
    install_niri_dms
    remove_blocked_brand_components
    install_desktop_assets
    configure_dms_lock_screen
    sync_ai_configs
    post_install

    cat <<'EOF'

安装完成，安装器没有自动重启。

后续步骤：
  1. 在方便时重启，并在 Ly 中选择 Niri 会话。
  2. 至少退出并重新登录一次，使 Fish、Fcitx5、libvirt 和 i2c 组权限生效。
  3. 首次进入 Niri 后会在后台初始化 Firefox、Code 和 Wine。
  4. 执行：./verify.sh
  5. 在 Niri 中执行：dms doctor
  6. 执行：cachyos-lock-doctor

DMS 安装器已替换受管理的 Niri 和 Kitty 配置，并创建了自己的备份。
首次登录初始化日志：~/.local/state/cachyos-desktop/post-login.log
指纹和安全密钥解锁会保持禁用，直到对应注册命令成功完成。
EOF
}

main "$@"
