#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
# 当前用户名。不直接用 $USER：env -i、cron、`su -` 这类上下文里它可能不存在，
# 而 set -u 会让安装在此处直接崩掉（实测 env -i 下就是 USER: unbound variable）。
TARGET_USER="${USER:-}"
[[ -n $TARGET_USER ]] || TARGET_USER="$(id -un)"
readonly TARGET_USER
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PINNED_DMS_VERSION="v1.5.3"
readonly PINNED_DMS_SHA256_AMD64="c84da05e4afd84a737faaac4fa3bc65fa78fcd783c5ec930aec24f31f4e84716"
readonly PINNED_NIRI_SIDEBAR_VERSION="v0.4.0"
readonly PINNED_NIRI_SIDEBAR_SHA256_AMD64="8264fa0a82657a21b781588877adec67e29c51d4b4ca1cb35a2415c8520be5d1"

# shellcheck source=packages.sh
source "$SCRIPT_DIR/packages.sh"

# agent 表（id → 二进制名 / 技能目录 / 启动参数）：安装器要用它判断"哪些 agent 可用"，
# 再决定是否设置默认 agent。放在这里是为了不在安装器里复制一份映射。
# shellcheck source=assets/lib/agent.sh
source "$SCRIPT_DIR/assets/lib/agent.sh"

# 终端界面：零依赖（不引入 gum/dialog），在真终端里画框、上色、显示进度；
# 只要输出不是终端（管道、重定向到日志、CI）就自动退化成纯文本——verify.sh 与 tests/
# 都在抓这些日志，界面不能污染它们。
# shellcheck source=assets/lib/tui.sh
source "$SCRIPT_DIR/assets/lib/tui.sh"
# shellcheck source=hardware.sh
source "$SCRIPT_DIR/hardware.sh"

DMS_VERSION="$PINNED_DMS_VERSION"
TERMINAL="kitty"
DRY_RUN=false
ASSUME_YES=false
SKIP_UPDATE=false
SKIP_HARDWARE=false
TEMP_DIR=""
DANKINSTALL_PATH=""

readonly -a DMS_FEATURE_PACKAGES=(
    networkmanager
    cava
    i2c-tools
    matugen
    qt6-multimedia
    wtype
    cups-pk-helper
)

# 下面三个仍然保留 [INFO]/[WARN]/[ERROR] 前缀：日志、verify.sh 与 tests/ 都在认这些标记，
# 界面只负责给标记上色、并顺带统计条数。
info() {
    tui_info "$*"
}

warn() {
    tui_warn "$*"
}

die() {
    tui_error "$*"
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
  --skip-hardware       skip auto-detected firmware/graphics/audio packages
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
    printf '%s[DRY-RUN]%s' "$TUI_MUTED" "$TUI_RESET"
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
            --)
                # 选项终止符：本脚本不吃位置参数，接受它并停止解析，别把它当未知选项。
                shift
                break
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
    local detected_hardware hardware_stack
    if [[ "$SKIP_HARDWARE" == true ]]; then
        detected_hardware="skipped"
        hardware_stack="skipped"
    else
        detected_hardware="$(cachyos_hardware_summary)"
        hardware_stack="auto-selected"
    fi

    # 计划用框展示：这是用户做决定前唯一要读的一屏，字号对齐比散落的裸文本好读得多。
    tui_banner "CachyOS + Niri + DMS 安装计划" \
        "User              $(id -un)" \
        "Terminal          $TERMINAL" \
        "DMS release       $DMS_VERSION" \
        "Full update       $([[ "$SKIP_UPDATE" == true ]] && printf 'no' || printf 'yes')" \
        "Detected hardware $detected_hardware" \
        "Hardware stack    $hardware_stack" \
        "Replace configs   yes" \
        "DMS integrations  DankSearch, DankCalendar" \
        "Applications      daily, Chinese, office, development, media, VM, gaming, tools" \
        "Display manager   Ly" \
        "Dry run           $DRY_RUN" \
        "Preserved         CachyOS repositories/kernel, bootloader, NetworkManager" \
        "                  connections, Secure Boot configuration, Windows partitions"

    if [[ "$ASSUME_YES" == true || "$DRY_RUN" == true ]]; then
        return 0
    fi

    local answer
    # 非交互调用（stdin 是空/EOF）时 read 返回非 0，set -e 会在打印任何解释之前中止。
    # 这里把 EOF 当成"没有确认"，交给下面的分支正常报错退出。
    read -r -p 'Continue? [y/N] ' answer || answer="" 
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
    local note
    info "installing auto-selected firmware, graphics, audio, Bluetooth, and diagnostics"
    info "detected hardware: $(cachyos_hardware_summary)"
    for note in "${CACHYOS_HARDWARE_NOTES[@]}"; do
        warn "$note"
    done
    install_available_packages required true "${CACHYOS_HARDWARE_REQUIRED_PACKAGES[@]}"
    tui_ok "必需硬件包（${#CACHYOS_HARDWARE_REQUIRED_PACKAGES[@]} 个）"
    install_available_packages optional false "${CACHYOS_HARDWARE_OPTIONAL_PACKAGES[@]}"
    if ((${#CACHYOS_HARDWARE_OPTIONAL_PACKAGES[@]} > 0)); then
        tui_ok "可选硬件包（${#CACHYOS_HARDWARE_OPTIONAL_PACKAGES[@]} 个，缺了只警告）"
    fi

    if pacman -Q tuned-ppd >/dev/null 2>&1; then
        warn "preserving the installed tuned-ppd power-profile provider"
    else
        install_available_packages power-profile true power-profiles-daemon
        tui_ok "电源配置服务 power-profiles-daemon"
    fi
}

install_dms_features() {
    info "installing optional DMS integrations from signed system repositories"
    install_available_packages dms-feature false "${DMS_FEATURE_PACKAGES[@]}"
}

install_applications() {
    # 八组应用按顺序装，每组前打一条进度条：这是整次安装里最长的一段，
    # 用户需要知道"现在到哪儿了、还剩几组"，而不是看着滚动的 pacman 输出猜。
    local total=8 index name label
    local -a labels=(每日应用 中文输入法与字体 办公应用 开发工具 影音应用 虚拟机工具 游戏应用 系统管理工具)
    local -a groups=(DAILY_APP_PACKAGES CHINESE_PACKAGES OFFICE_PACKAGES DEVELOPMENT_PACKAGES
                     MEDIA_PACKAGES VIRTUALIZATION_PACKAGES GAMING_PACKAGES SYSTEM_TOOL_PACKAGES)

    for ((index = 0; index < total; index++)); do
        name="${groups[index]}"
        label="${labels[index]}"
        # nameref 指向数组；shellcheck 看不到指向关系，会误报成"当字符串用"。
        # shellcheck disable=SC2178
        local -n packages="$name"
        tui_progress $((index + 1)) "$total" "$label（${#packages[@]} 个包）"
        install_available_packages "$label" true "${packages[@]}"
        tui_ok "$label"
        unset -n packages
    done
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

    # 真终端里让 curl 闭嘴、由我们自己的转圈负责这一行：否则 curl 的进度条会和转圈
    # 抢同一行，看起来是乱码。非终端（日志）保持 curl 原样，方便排查下载失败。
    local -a curl_args=(--fail --location --proto '=https' --tlsv1.2 --retry 3)
    [[ $TUI_TTY == true ]] && curl_args+=(--silent --show-error)

    info "installing pinned niri-sidebar $PINNED_NIRI_SIDEBAR_VERSION"
    tui_spin_start "下载 niri-sidebar $PINNED_NIRI_SIDEBAR_VERSION"
    curl "${curl_args[@]}" "$base_url/$binary_name" -o "$destination"
    actual_sha="$(sha256sum "$destination" | awk '{print $1}')"
    if [[ "$actual_sha" != "$PINNED_NIRI_SIDEBAR_SHA256_AMD64" ]]; then
        tui_spin_stop warn "niri-sidebar 校验失败"
        die "niri-sidebar checksum mismatch"
    fi
    sudo install -o root -g root -m 0755 "$destination" /usr/local/bin/niri-sidebar
    tui_spin_stop ok "niri-sidebar $PINNED_NIRI_SIDEBAR_VERSION（已校验 SHA256）"
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

    if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx libvirt; then
        run sudo usermod --append --groups libvirt "$TARGET_USER"
        warn "log out and back in before using libvirt as $USER"
    fi

    run flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    run sudo usermod --shell /usr/bin/fish "$TARGET_USER"

    if ! getent group i2c >/dev/null 2>&1; then
        run sudo groupadd --system i2c
    fi
    if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx i2c; then
        run sudo usermod --append --groups i2c "$TARGET_USER"
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
    local rendered_niri_config
    local line

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
        "$HOME/.config/systemd/user" \
        "$HOME/.config/Thunar" \
        "$HOME/.config/waybar" \
        "$HOME/.config/waycorner" \
        "$HOME/.config/waypaper" \
        "$HOME/.local/share/fcitx5/rime" \
        "$HOME/Pictures/Screenshots" \
        "$HOME/Pictures/Wallpapers" \
        "$HOME/Videos/ScreenRecords"

    ensure_temp_dir
    rendered_niri_config="$TEMP_DIR/niri-config.kdl"
    if [[ "$DRY_RUN" == true ]]; then
        print_command render-niri-config "$SCRIPT_DIR/assets/niri/config.kdl" "$rendered_niri_config"
    else
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "${line//@HOME@/$HOME}"
        done < "$SCRIPT_DIR/assets/niri/config.kdl" > "$rendered_niri_config"
    fi

    run install -m 0644 "$SCRIPT_DIR/assets/fcitx5/environment.conf" "$HOME/.config/environment.d/90-cachyos-input.conf"
    run install -m 0644 "$SCRIPT_DIR/assets/fcitx5/profile" "$HOME/.config/fcitx5/profile"
    run install -m 0644 "$SCRIPT_DIR/assets/fcitx5/default.custom.yaml" "$HOME/.local/share/fcitx5/rime/default.custom.yaml"
    run install -m 0644 "$SCRIPT_DIR/assets/fish/cachyos-desktop.fish" "$HOME/.config/fish/conf.d/cachyos-desktop.fish"
    run install -m 0644 "$SCRIPT_DIR/assets/kitty/cachyos-font.conf" "$HOME/.config/kitty/cachyos-font.conf"
    run install -m 0644 "$rendered_niri_config" "$HOME/.config/niri/config.kdl"
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

    # manifest 只驱动 cachyos-config 的运行时刷新，安装期不读它；$HOME 下的文件必须在这里
    # 逐个显式安装，否则 verify.sh 的 manifest 循环会因为文件不存在而 FAIL。
    run install -m 0644 "$SCRIPT_DIR/assets/systemd/user/cachyos-crash-watch.service" \
        "$HOME/.config/systemd/user/cachyos-crash-watch.service"
    # 主题变化时把明暗模式同步给 agent：用 path 单元盯着 DMS 生成的配色文件。
    run install -m 0644 "$SCRIPT_DIR/assets/systemd/user/cachyos-agent-theme.service" \
        "$HOME/.config/systemd/user/cachyos-agent-theme.service"
    run install -m 0644 "$SCRIPT_DIR/assets/systemd/user/cachyos-agent-theme.path" \
        "$HOME/.config/systemd/user/cachyos-agent-theme.path"
    # 用量记录需要周期性重算：没有定时器的话面板只会停在安装那一刻的数字。
    run install -m 0644 "$SCRIPT_DIR/assets/systemd/user/cachyos-agent-usage.service" \
        "$HOME/.config/systemd/user/cachyos-agent-usage.service"
    run install -m 0644 "$SCRIPT_DIR/assets/systemd/user/cachyos-agent-usage.timer" \
        "$HOME/.config/systemd/user/cachyos-agent-usage.timer"

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
    local asset relative_asset source_asset
    while IFS= read -r asset; do
        relative_asset="${asset#"$SCRIPT_DIR/assets/"}"
        source_asset="$asset"
        if [[ "$relative_asset" == "niri/config.kdl" ]]; then
            source_asset="$rendered_niri_config"
        fi
        run sudo install -D -o root -g root -m 0644 "$source_asset" "/usr/local/share/cachyos-desktop/assets/$relative_asset"
    done < <(find "$SCRIPT_DIR/assets" -type f -print | sort)
    run sudo install -o root -g root -m 0644 "$SCRIPT_DIR/assets/config-manifest.tsv" /usr/local/share/cachyos-desktop/config-manifest.tsv
}

install_agent_skills() {
    # 技能软链是用户态操作，不需要 sudo。安装时大多数 harness 目录还不存在（要等对应
    # CLI 首次运行才会出现），所以这里只是尽力而为；cachyos-agent 启动前还会按 harness
    # 再同步一次，那才是真正可靠的时机。
    if [[ "$DRY_RUN" == true ]]; then
        print_command cachyos-agent-skills --create-supported
        return 0
    fi

    # 按命令名调用而不是写死 /usr/local/bin：与安装器调用其它本项目命令的方式一致，
    # 也让"刚装出来的那份"被真正执行（写死绝对路径会在测试沙箱里跑到别处去）。
    if ! command -v cachyos-agent-skills >/dev/null 2>&1; then
        warn "cachyos-agent-skills 未安装；跳过 agent 技能软链"
        return 0
    fi

    if ! cachyos-agent-skills --create-supported; then
        warn "agent 技能软链未完全建立；稍后可手动运行 cachyos-agent-skills"
    fi
}

sync_ai_configs() {
    if [[ "$DRY_RUN" == true ]]; then
        print_command cachyos-ai-config-sync status
        print_command cachyos-ai-config-sync sync
    elif command -v cachyos-ai-config-sync >/dev/null 2>&1 && [[ -f "$HOME/.cc-switch/cc-switch.db" ]]; then
        cachyos-ai-config-sync sync || warn "AI configuration mirror was not updated"
    else
        warn "CC Switch database is not present; AI configuration mirror will be created on first use"
    fi
}

configure_dms_settings() {
    local settings_dir="$HOME/.config/DankMaterialShell"
    local settings_file="$settings_dir/settings.json"
    local defaults_file="$SCRIPT_DIR/assets/dms/desktop-settings.json"
    local temporary_file

    run sudo install -o root -g root -m 0644 "$SCRIPT_DIR/assets/dms/dankshell-u2f" /etc/pam.d/dankshell-u2f

    if [[ "$DRY_RUN" == true ]]; then
        print_command jq --slurp '.[0] * .[1]' "$settings_file" "$defaults_file"
        print_command install -m 0600 merged-desktop-settings.json "$settings_file"
        print_command dms auth resolve-lock --quiet
        return 0
    fi

    install -d -m 0700 "$settings_dir"
    if [[ -s "$settings_file" ]]; then
        temporary_file="$(mktemp)"
        if ! jq --slurp '.[0] * .[1]' "$settings_file" "$defaults_file" > "$temporary_file"; then
            rm -f -- "$temporary_file"
            die "could not merge DMS desktop settings"
        fi
        install -m 0600 "$temporary_file" "$settings_file"
        rm -f -- "$temporary_file"
    else
        install -m 0600 "$defaults_file" "$settings_file"
    fi

    dms auth resolve-lock --quiet
}

# 安装 DMS 用量面板插件（agents 的 token 与费用统计）。
#
# 插件源码的真源是 skynit/dms-plugins 仓库；这里放的是随包副本，因为本仓库的用途是
# "新电脑复刻"，安装过程要能离线、自包含。上游改动后需要把文件同步进 assets/dms-plugins/。
install_dms_plugins() {
    local settings_dir="$HOME/.config/DankMaterialShell"
    local plugin_dir="$settings_dir/plugins/CachyosAgents"
    local source_dir="$SCRIPT_DIR/assets/dms-plugins/CachyosAgents"
    local settings_file="$settings_dir/settings.json"
    local plugin_settings="$settings_dir/plugin_settings.json"
    local asset
    local temporary_file

    run install -d -m 0755 "$plugin_dir" "$plugin_dir/tests"

    for asset in "$source_dir"/*.qml "$source_dir"/*.js "$source_dir"/plugin.json "$source_dir"/README.md; do
        [[ -f "$asset" ]] || continue
        run install -m 0644 "$asset" "$plugin_dir/${asset##*/}"
    done
    run install -m 0644 "$source_dir/tests/usage.test.cjs" "$plugin_dir/tests/usage.test.cjs"

    if [[ "$DRY_RUN" == true ]]; then
        # 打印真实发生的两步（写临时文件 + install -m 0600），而不是简化成"就地 jq"。
        print_command jq --arg plugin cachyosAgents -f "$SCRIPT_DIR/assets/dms/enable-dms-plugin.jq" \
            "$plugin_settings" '>' merged-plugin-settings.json
        print_command install -m 0600 merged-plugin-settings.json "$plugin_settings"
        print_command jq -f "$SCRIPT_DIR/assets/dms/add-agents-bar-widget.jq" \
            "$settings_file" '>' merged-desktop-settings.json
        print_command install -m 0600 merged-desktop-settings.json "$settings_file"
        return 0
    fi

    # 启用插件。只在用户还没有表达过意愿时写入：他之后在设置界面关掉了，重装不该又给打开。
    temporary_file="$(mktemp)"
    if [[ -s "$plugin_settings" ]]; then
        if jq --arg plugin cachyosAgents -f "$SCRIPT_DIR/assets/dms/enable-dms-plugin.jq" \
            "$plugin_settings" > "$temporary_file"; then
            install -m 0600 "$temporary_file" "$plugin_settings"
        else
            warn "could not enable the usage plugin in plugin_settings.json"
        fi
    else
        if printf '%s\n' '{}' | jq --arg plugin cachyosAgents \
            -f "$SCRIPT_DIR/assets/dms/enable-dms-plugin.jq" > "$temporary_file"; then
            install -m 0600 "$temporary_file" "$plugin_settings"
        else
            warn "could not create plugin_settings.json for the usage plugin"
        fi
    fi
    rm -f -- "$temporary_file"

    # 接线到状态栏。这个 jq 程序只增不覆盖且幂等——绝不能走 desktop-settings.json 的浅合并，
    # 那会把整个 barConfigs 数组替换掉，用户的布局就没了。
    #
    # 注意：**没有现成的 barConfigs 时它什么都不做**。DMS 读设置是整体赋值，凭空造一个只含
    # 本控件的栏会把用户的默认顶栏（启动器/时钟/系统托盘…）整个换掉。那种情况下控件不显示，
    # 由用户在 设置 → 状态栏 里自己加，比毁掉布局好。
    if [[ -s "$settings_file" ]]; then
        temporary_file="$(mktemp)"
        if jq -f "$SCRIPT_DIR/assets/dms/add-agents-bar-widget.jq" "$settings_file" > "$temporary_file"; then
            install -m 0600 "$temporary_file" "$settings_file"
            if ! jq -e '[.barConfigs[]? | (.leftWidgets? // [])[], (.centerWidgets? // [])[], (.rightWidgets? // [])[]
                    | if type == "object" then .id else . end] | index("cachyosAgents") != null' \
                "$settings_file" >/dev/null 2>&1; then
                warn "usage widget not added to the DankBar (no custom bar configured yet);"
                warn "add it from DMS Settings > Bar, or rerun the installer after customising the bar"
            fi
        else
            warn "could not add the usage widget to the DankBar configuration"
        fi
        rm -f -- "$temporary_file"
    fi
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
    # 同 niri-sidebar：真终端里让 curl 闭嘴、交给转圈，避免两条进度抢同一行。
    local -a fetch_args=("${curl_args[@]}")
    [[ $TUI_TTY == true ]] && fetch_args+=(--silent --show-error)
    tui_spin_start "下载官方 DMS 安装器 $DMS_VERSION"
    curl "${fetch_args[@]}" "$base_url/$asset" -o "$archive"
    curl "${fetch_args[@]}" "$base_url/$asset.sha256" -o "$checksum_file"

    expected_sha="$(awk 'NF >= 1 && $1 ~ /^[0-9a-fA-F]{64}$/ { print tolower($1); exit }' "$checksum_file")"
    if [[ -z "$expected_sha" ]]; then
        tui_spin_stop warn "DMS 校验文件不可用"
        die "release checksum file is invalid"
    fi
    actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        tui_spin_stop warn "DMS 安装器校验失败"
        die "Dank installer checksum mismatch"
    fi

    if [[ "$DMS_VERSION" == "$PINNED_DMS_VERSION" ]]; then
        if [[ "$actual_sha" != "$PINNED_DMS_SHA256_AMD64" ]]; then
            tui_spin_stop warn "与钉住的 SHA256 不符"
            die "pinned Dank installer checksum mismatch"
        fi
    else
        warn "using an unpinned DMS release; verification relies on its GitHub release checksum"
    fi
    tui_spin_stop ok "官方 DMS 安装器 $DMS_VERSION（已校验 SHA256）"

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
        print_command systemctl --user enable cachyos-crash-watch.service
        print_command systemctl --user restart cachyos-crash-watch.service
        print_command systemctl --user restart dms.service
        print_command systemctl --user enable cachyos-agent-theme.path
        print_command systemctl --user start cachyos-agent-theme.path
        print_command cachyos-agent-theme-sync --quiet
        print_command systemctl --user enable --now cachyos-agent-usage.timer
        print_command cachyos-agent-usage-update --force
        print_command cachyos-default-agent '<detected-agent>'
        return 0
    fi

    systemctl --user daemon-reload
    tui_ok "systemd 用户单元已重新加载"
    if ! systemctl --user add-wants niri.service dms.service; then
        warn "could not bind dms.service to niri.service; run this after logging in:"
        warn "  systemctl --user add-wants niri.service dms.service"
    else
        tui_ok "DMS 已绑定到 Niri 会话"
    fi

    # 崩溃监听与 niri 会话同生命周期（unit 里 WantedBy=niri.service，与上面的 dms 一致）。
    # 分两步且用 restart 而不是 `enable --now`：对**已在运行**的单元 `--now` 不会重启它，
    # 于是更新后服务仍在执行被替换掉的旧脚本。
    if ! systemctl --user enable cachyos-crash-watch.service; then
        warn "could not enable cachyos-crash-watch.service; run this after logging in:"
        warn "  systemctl --user enable --now cachyos-crash-watch.service"
    fi
    if ! systemctl --user restart cachyos-crash-watch.service; then
        warn "could not start cachyos-crash-watch.service; run this after logging in:"
        warn "  systemctl --user restart cachyos-crash-watch.service"
    else
        tui_ok "崩溃监听已启用并重启（Super+\` 之外还能用 cachyos-agent-crash 诊断）"
    fi

    # DMS 只在启动时读 settings.json：用量面板插件与状态栏接线要重启一次才生效。
    if systemctl --user is-active --quiet dms.service; then
        if ! systemctl --user restart dms.service; then
            warn "could not restart dms.service; the usage widget appears after the next login"
        else
            tui_ok "已重启 DMS（用量面板与状态栏接线生效）"
        fi
    fi

    # 主题同步：先跑一次（把当前模式写进各 agent），再挂上 path 单元跟着配色文件走。
    # 用量面板需要周期性重算，否则只会停在安装那一刻的数字。
    if ! systemctl --user enable --now cachyos-agent-usage.timer; then
        warn "could not enable cachyos-agent-usage.timer; run this after logging in:"
        warn "  systemctl --user enable --now cachyos-agent-usage.timer"
    else
        tui_ok "用量刷新定时器已启用（登录后 2 分钟 + 每 15 分钟）"
    fi

    # 先算一次并忽略失败：新用户一登录就该在面板里看到数字，而不是空面板；
    # 但采集失败（没登录过 agent、没有凭据）绝不能把安装判为失败。
    if ! cachyos-agent-usage-update --force >/dev/null 2>&1; then
        warn "could not collect agent usage yet (run cachyos-agent-usage-update after using an agent)"
    else
        tui_ok "已采集一次用量数据"
    fi

    # 只有一个 agent 可用时直接设为默认：新用户按下 Super+grave 就能用，而不是先面对选择器。
    # 装了多个则不猜——留空让选择器出现，用户选一次就会被记住。
    if [[ ! -e "$HOME/.config/cachyos-desktop/agent" ]]; then
        local -a available_agents=()
        local candidate
        local binary
        while read -r candidate; do
            [[ -n $candidate ]] || continue
            binary="$(cachyos_agent_binary "$candidate" 2>/dev/null || true)"
            if [[ -n $binary ]] && command -v "$binary" >/dev/null 2>&1; then
                available_agents+=("$candidate")
            fi
        done < <(cachyos_agent_supported 2>/dev/null || true)
        if ((${#available_agents[@]} == 1)); then
            if cachyos-default-agent "${available_agents[0]}" >/dev/null 2>&1; then
                tui_ok "默认 AI 编程助手：${available_agents[0]}（只探测到这一个）"
            fi
        elif ((${#available_agents[@]} > 1)); then
            info "several AI agents found; press Super+grave and pick one (the choice is remembered)"
        else
            tui_skip "没有装 AI 编程助手，先不设默认值"
        fi
    fi

    if ! systemctl --user enable cachyos-agent-theme.path; then
        warn "could not enable cachyos-agent-theme.path; run this after logging in:"
        warn "  systemctl --user enable --now cachyos-agent-theme.path"
    fi
    if ! systemctl --user start cachyos-agent-theme.path; then
        warn "could not start cachyos-agent-theme.path"
    fi
    if ! cachyos-agent-theme-sync --quiet; then
        warn "could not sync the light/dark mode to the AI agents (see cachyos-agent-theme-sync --status)"
    else
        tui_ok "已把当前明暗主题同步给 AI 助手，之后跟随配色变化"
    fi
}

main() {
    parse_args "$@"
    # 界面要在任何输出之前初始化：它决定了本次跑是画框上色还是纯文本。
    tui_init
    TUI_PHASE_TOTAL=6

    tui_banner "CachyOS · Niri · DankMaterialShell" \
        "帮你把 CachyOS 装成 Niri 桌面（DMS 顶栏），AI 编程助手也一起配好" \
        "别用 root 跑；要联网；软件源、引导器、网络连接、Secure Boot 都不会动"

    tui_phase_start "检查环境"
    preflight
    cachyos_detect_hardware
    cachyos_select_hardware_packages
    confirm_plan
    authenticate
    save_package_snapshot
    tui_phase_done

    tui_phase_start "系统更新"
    if [[ "$SKIP_UPDATE" == false ]]; then
        info "performing full CachyOS package upgrade"
        run sudo pacman -Syu --noconfirm
    else
        tui_skip "已按 --skip-update 跳过全系统升级"
    fi
    tui_phase_done

    tui_phase_start "硬件与系统服务"
    if [[ "$SKIP_HARDWARE" == false ]]; then
        install_hardware_stack
        configure_system_services
    else
        tui_skip "已按 --skip-hardware 跳过驱动与硬件相关服务"
    fi
    tui_phase_done

    tui_phase_start "应用与桌面"
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
    tui_phase_done

    tui_phase_start "桌面配置与 AI 助手"
    install_desktop_assets
    install_agent_skills
    configure_dms_settings
    install_dms_plugins
    sync_ai_configs
    tui_phase_done

    tui_phase_start "收尾"
    post_install
    tui_phase_done

    tui_summary "安装完成（安装器不会自动重启）" \
        "1. 在方便时重启，并在 Ly 中选择 Niri 会话" \
        "2. 至少退出并重新登录一次，使 Fish、Fcitx5、libvirt 和 i2c 组权限生效" \
        "3. 首次进入 Niri 后会在后台初始化 Firefox、Code、Wine 和 agent 技能" \
        "4. 执行：./verify.sh" \
        "5. 在 Niri 中执行：dms doctor" \
        "6. 执行：cachyos-lock-doctor" \
        "DMS 安装器已替换受管理的 Niri 和 Kitty 配置，并创建了自己的备份" \
        "首次登录初始化日志：~/.local/state/cachyos-desktop/post-login.log" \
        "指纹和安全密钥解锁会保持禁用，直到对应注册命令成功完成"
}

main "$@"
