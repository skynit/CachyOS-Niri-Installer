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
# DMS 1.6.2 是随包插件的下限：Focus 要求 >=1.6.2，LocalTranslate/LocalLyrics 要求
# >=1.6.1。钉住版本时同时钉住官方安装器压缩包的 SHA256（来自该 release 的 .sha256 文件）。
readonly PINNED_DMS_VERSION="v1.6.2"
readonly PINNED_DMS_SHA256_AMD64="933d3d87ac462432f6e0265e47dc68171c7174592e2a8caba7b9b9710bda5e56"
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
    # 随包 DMS 插件的运行依赖：
    #   dgop         LocalStatus 的 CPU/内存/负载采样（DMS 的 DgopService 也用它）
    #   android-tools/adb、scrcpy、avahi  连接插件的手机配对、投屏与局域网发现
    #   freerdp、libsecret、gnome-keyring  电脑 RDP 与系统密钥环密码保存
    dgop
    android-tools
    scrcpy
    avahi
    freerdp
    libsecret
    gnome-keyring
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
    for helper in cachyos-ai-settings cachyos-usage-json \
                  translate-lookup lyrics-helper phone-connect focus-helper top-helper; do
        [[ -x "$SCRIPT_DIR/assets/go-bin/$helper" ]] || die "missing Go helper $helper; run tools/build-go-helpers.sh before installing"
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
    local detected_hardware hardware_stack full_update replace_configs dry_label
    if [[ "$SKIP_HARDWARE" == true ]]; then
        detected_hardware="已跳过（--skip-hardware）"
        hardware_stack="已跳过"
    else
        detected_hardware="$(cachyos_hardware_summary)"
        hardware_stack="自动选择"
    fi
    if [[ "$SKIP_UPDATE" == true ]]; then
        full_update="否（--skip-update）"
    else
        full_update="是"
    fi
    replace_configs="是（覆盖受管理的用户配置）"
    if [[ "$DRY_RUN" == true ]]; then
        dry_label="是（只打印，不执行）"
    else
        dry_label="否"
    fi

    # 字段左对齐到固定列宽。按**显示列宽**补齐（中文算两列），否则中英混排会参差不齐。
    _plan_field() {
        local label="$1" value="$2" pad
        pad=$((18 - $(tui_visible_length "$label")))
        ((pad < 1)) && pad=1
        printf '%s%s%s\n' "$label" "$(tui_repeat ' ' "$pad")" "$value"
    }

    # 计划用框展示：这是用户做决定前唯一要读的一屏，字段对齐比散落的裸文本好读得多。
    local -a plan=()
    plan+=("$(_plan_field 运行用户 "$(id -un)")")
    plan+=("$(_plan_field 终端 "$TERMINAL")")
    plan+=("$(_plan_field "DMS 版本" "$DMS_VERSION")")
    plan+=("$(_plan_field 系统升级 "$full_update")")
    plan+=("$(_plan_field 检测到的硬件 "$detected_hardware")")
    plan+=("$(_plan_field 硬件驱动栈 "$hardware_stack")")
    plan+=("$(_plan_field 覆盖配置 "$replace_configs")")
    plan+=("$(_plan_field "DMS 集成" "DankSearch、DankCalendar")")
    plan+=("$(_plan_field "应用分组" "daily、Chinese、office、development、media、VM、gaming、tools")")
    plan+=("$(_plan_field 显示管理器 "Ly")")
    plan+=("$(_plan_field 试运行 "$dry_label")")
    plan+=("$(_plan_field 不改动 "软件源与内核、引导器、NetworkManager 连接、")")
    plan+=("$(_plan_field "" "Secure Boot 配置、Windows 分区")")

    tui_banner "CachyOS + Niri + DMS 安装计划" "${plan[@]}"

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
    tui_ok "已安装必需硬件包（${#CACHYOS_HARDWARE_REQUIRED_PACKAGES[@]} 个）"
    install_available_packages optional false "${CACHYOS_HARDWARE_OPTIONAL_PACKAGES[@]}"
    if ((${#CACHYOS_HARDWARE_OPTIONAL_PACKAGES[@]} > 0)); then
        tui_ok "已安装可选硬件包（${#CACHYOS_HARDWARE_OPTIONAL_PACKAGES[@]} 个；缺失时仅警告）"
    fi

    if pacman -Q tuned-ppd >/dev/null 2>&1; then
        warn "preserving the installed tuned-ppd power-profile provider"
    else
        install_available_packages power-profile true power-profiles-daemon
        tui_ok "电源配置服务：power-profiles-daemon"
    fi
}

install_dms_features() {
    info "installing optional DMS integrations from signed system repositories"
    install_available_packages dms-feature false "${DMS_FEATURE_PACKAGES[@]}"

    # avahi 是上面这一批里的包，所以只能在装完后判断。PhoneConnect 用它的 mDNS 发现
    # 手机当前的配对/连接端口；服务没跑时插件只能手填地址。
    if pacman -Q avahi >/dev/null 2>&1; then
        run sudo systemctl enable --now avahi-daemon.service
    fi
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
        [[ "${helper##*/}" == cachyos-ai-settings ]] && continue
        run sudo install -m 0755 "$helper" "/usr/local/bin/${helper##*/}"
    done
    run bash "$SCRIPT_DIR/tools/install-go-helpers.sh"

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
        "$HOME/.config/wireplumber/wireplumber.conf.d" \
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
    # 麦克风源常开：否则 WirePlumber 挂起后需要 0.5–0.8 秒唤醒，听写开头被吞
    # （voxtype issue #817）。只影响 alsa_input.*，不碰蓝牙。
    run install -m 0644 "$SCRIPT_DIR/assets/wireplumber/51-keep-mic-ready.conf" \
        "$HOME/.config/wireplumber/wireplumber.conf.d/51-keep-mic-ready.conf"

    # manifest 只驱动 cachyos-config 的运行时刷新，安装期不读它；$HOME 下的文件必须在这里
    # 逐个显式安装，否则 verify.sh 的 manifest 循环会因为文件不存在而 FAIL。
    run install -m 0644 "$SCRIPT_DIR/assets/systemd/user/cachyos-crash-watch.service" \
        "$HOME/.config/systemd/user/cachyos-crash-watch.service"
    run install -m 0644 "$SCRIPT_DIR/assets/systemd/user/cachyos-oom-watch.service" \
        "$HOME/.config/systemd/user/cachyos-oom-watch.service"
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

    # cachyos-ask 的动作与提示词：给一份带内置默认值的起始文件，让用户知道这个文件存在、
    # 照着改就行。**只在不存在时落地**：这是用户自己的配置，重跑安装器绝不能覆盖他改过的
    # 提示词。也刻意不进 config-manifest.tsv——那不是受管文件。
    if [[ ! -e "$HOME/.config/cachyos-desktop/ask-actions.conf" ]]; then
        run install -D -m 0644 "$SCRIPT_DIR/assets/cachyos-desktop/ask-actions.conf" \
            "$HOME/.config/cachyos-desktop/ask-actions.conf"
    fi

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

# 随包的 DMS 插件：真源是 skynit/dms-plugins 仓库，这里放随包副本，因为本仓库的用途是
# "新电脑复刻"，安装过程要能离线、自包含。上游改动后需要把文件同步进 assets/dms-plugins/。
#
# 目录名是 DMS 的安装目录名，必须与上游大小写一致（localTranslate/localLyrics 小写开头）；
# 插件 ID 则来自各插件 plugin.json，用于启用与状态栏接线。
readonly -a DMS_PLUGIN_IDS=(
    cachyosAgents
    localStatus
    localTranslate
    localLyrics
    phoneConnect
    focus
    top
)

# Go helper 的二进制由 assets/go-bin/ 提供（tools/build-go-helpers.sh 构建）。它们刻意
# 不进 config-manifest.tsv：cachyos-config update 固定用 0644 安装，会丢掉可执行位。
install_dms_plugin_assets() {
    local source_name="$1"
    local target_name="$2"
    local source_dir="$SCRIPT_DIR/assets/dms-plugins/$source_name"
    local target_dir="$HOME/.config/DankMaterialShell/plugins/$target_name"
    local asset

    run install -d -m 0755 "$target_dir"
    for asset in "$source_dir"/*.qml "$source_dir"/*.js "$source_dir"/plugin.json "$source_dir"/README.md; do
        [[ -f "$asset" ]] || continue
        run install -m 0644 "$asset" "$target_dir/${asset##*/}"
    done
}

install_dms_plugin_tests() {
    local source_name="$1"
    local target_name="$2"
    local source_dir="$SCRIPT_DIR/assets/dms-plugins/$source_name/tests"
    local target_dir="$HOME/.config/DankMaterialShell/plugins/$target_name/tests"
    local test_file

    [[ -d "$source_dir" ]] || return 0
    for test_file in "$source_dir"/*.cjs; do
        [[ -f "$test_file" ]] || continue
        run install -D -m 0644 "$test_file" "$target_dir/${test_file##*/}"
    done
}

# 复制插件内的子目录（目前只有 LocalTranslate 的 data/：内置 CC-CEDICT 词典）。
# install -D 负责建父目录，这样新增数据文件时不用改安装器。
install_dms_plugin_subtree() {
    local source_name="$1"
    local target_name="$2"
    local subtree="$3"
    local source_dir="$SCRIPT_DIR/assets/dms-plugins/$source_name/$subtree"
    local target_dir="$HOME/.config/DankMaterialShell/plugins/$target_name"
    local file relative

    while IFS= read -r file; do
        relative="${file#"$source_dir/"}"
        run install -D -m 0644 "$file" "$target_dir/$subtree/$relative"
    done < <(find "$source_dir" -type f -print | sort)
}

# 启用一个插件，但只在用户还没有表达过意愿时写入：他之后在设置界面关掉了，
# 重装不该又给打开。
enable_dms_plugin() {
    local plugin="$1"
    local settings_file="$HOME/.config/DankMaterialShell/plugin_settings.json"
    local temporary_file

    if [[ "$DRY_RUN" == true ]]; then
        # 打印真实发生的两步（写临时文件 + install -m 0600），而不是简化成"就地 jq"。
        if [[ -s "$settings_file" ]]; then
            print_command jq --arg plugin "$plugin" -f "$SCRIPT_DIR/assets/dms/enable-dms-plugin.jq" \
                "$settings_file" '>' merged-plugin-settings.json
        else
            print_command jq --null-input --arg plugin "$plugin" \
                -f "$SCRIPT_DIR/assets/dms/enable-dms-plugin.jq" '{}' '>' merged-plugin-settings.json
        fi
        print_command install -m 0600 merged-plugin-settings.json "$settings_file"
        return 0
    fi

    temporary_file="$(mktemp)"
    if [[ -s "$settings_file" ]]; then
        if jq --arg plugin "$plugin" -f "$SCRIPT_DIR/assets/dms/enable-dms-plugin.jq" \
            "$settings_file" > "$temporary_file"; then
            install -m 0600 "$temporary_file" "$settings_file"
        else
            warn "could not enable the DMS plugin in plugin_settings.json: $plugin"
        fi
    else
        if printf '%s\n' '{}' | jq --arg plugin "$plugin" \
            -f "$SCRIPT_DIR/assets/dms/enable-dms-plugin.jq" > "$temporary_file"; then
            install -m 0600 "$temporary_file" "$settings_file"
        else
            warn "could not create plugin_settings.json for the DMS plugin: $plugin"
        fi
    fi
    rm -f -- "$temporary_file"
}

# 把插件控件接到状态栏。这个 jq 程序只增不覆盖且幂等——绝不能走 desktop-settings.json
# 的浅合并，那会把整个 barConfigs 数组替换掉，用户的布局就没了。
#
# 注意：**没有现成的 barConfigs 时它什么都不做**。DMS 读设置是整体赋值，凭空造一个只含
# 插件控件的栏会把用户的默认顶栏（启动器/时钟/系统托盘…）整个换掉。那种情况下控件不显示，
# 由用户在 设置 → 状态栏 里自己加，比毁掉布局好。
# 只有这些插件有状态栏控件；Top 是纯悬浮面板（daemon-only），不参与栏接线。
readonly -a DMS_BAR_WIDGET_IDS=(cachyosAgents localStatus localTranslate localLyrics phoneConnect focus)

DMS_BAR_WIDGETS='{"left":["localTranslate","phoneConnect","focus","localLyrics"],"right":["cachyosAgents","localStatus"]}'

wire_dms_plugin_bar() {
    local settings_file="$HOME/.config/DankMaterialShell/settings.json"
    local jq_program="$SCRIPT_DIR/assets/dms/add-dms-bar-widgets.jq"
    local temporary_file
    local plugin_id
    local -a missing=()

    [[ -s "$settings_file" ]] || return 0

    if [[ "$DRY_RUN" == true ]]; then
        print_command jq --argjson widgets "$DMS_BAR_WIDGETS" -f "$jq_program" \
            "$settings_file" '>' merged-desktop-settings.json
        print_command install -m 0600 merged-desktop-settings.json "$settings_file"
        return 0
    fi

    temporary_file="$(mktemp)"
    if jq --argjson widgets "$DMS_BAR_WIDGETS" -f "$jq_program" "$settings_file" > "$temporary_file"; then
        install -m 0600 "$temporary_file" "$settings_file"
        for plugin_id in "${DMS_BAR_WIDGET_IDS[@]}"; do
            if ! jq -e --arg id "$plugin_id" \
                '[.barConfigs[]? | (.leftWidgets? // [])[], (.centerWidgets? // [])[], (.rightWidgets? // [])[]
                 | if type == "object" then .id else . end] | index($id) != null' \
                "$settings_file" >/dev/null 2>&1; then
                missing+=("$plugin_id")
            fi
        done
        if ((${#missing[@]} > 0)); then
            warn "DMS plugin widgets not added to the DankBar (no custom bar configured yet): ${missing[*]}"
            warn "add them from DMS Settings > Bar, or rerun the installer after customising the bar"
        fi
    else
        warn "could not add the DMS plugin widgets to the DankBar configuration"
    fi
    rm -f -- "$temporary_file"
}

install_dms_plugins() {
    local plugin_root="$HOME/.config/DankMaterialShell/plugins"
    local helper
    local plugin_id

    # 运行副本：DMS 从 ~/.config 加载插件，缺一个文件插件就不会出现。
    install_dms_plugin_assets CachyosAgents CachyosAgents
    install_dms_plugin_tests CachyosAgents CachyosAgents

    install_dms_plugin_assets LocalStatus LocalStatus
    install_dms_plugin_tests LocalStatus LocalStatus

    install_dms_plugin_assets LocalTranslate localTranslate
    install_dms_plugin_subtree LocalTranslate localTranslate data

    install_dms_plugin_assets LocalLyrics localLyrics

    install_dms_plugin_assets PhoneConnect PhoneConnect

    install_dms_plugin_assets Focus Focus

    # Top 是 daemon-only 悬浮面板：只有后台组件，没有状态栏控件；components/ 是自绘界面。
    install_dms_plugin_assets Top Top
    install_dms_plugin_subtree Top Top components

    # helper 二进制由 install_desktop_assets → tools/install-go-helpers.sh 安装；这里只
    # 确认在位，避免"插件装了但一点就报错"。
    if [[ "$DRY_RUN" == false ]]; then
        for helper in CachyosAgents/ai-settings CachyosAgents/usage-json \
                      localTranslate/translate-lookup localLyrics/lyrics-helper \
                      PhoneConnect/phone-connect Focus/focus-helper Top/top-helper; do
            [[ -x "$plugin_root/$helper" ]] || warn "DMS plugin helper is missing: $plugin_root/$helper"
        done
    fi

    for plugin_id in "${DMS_PLUGIN_IDS[@]}"; do
        enable_dms_plugin "$plugin_id"
    done

    wire_dms_plugin_bar
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
        print_command systemctl --user enable cachyos-oom-watch.service
        print_command systemctl --user restart cachyos-oom-watch.service
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
    tui_ok "已重新加载 systemd 用户单元"
    if ! systemctl --user add-wants niri.service dms.service; then
        warn "could not bind dms.service to niri.service; run this after logging in:"
        warn "  systemctl --user add-wants niri.service dms.service"
    else
        tui_ok "DMS 已绑定至 Niri 会话"
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
        tui_ok "崩溃监听已启用并重启（亦可用 cachyos-agent-crash 诊断）"
    fi

    # OOM 监听同样与 niri 会话同生命周期（unit 里 WantedBy=niri.service）。这里也照旧分两步
    # 并用 restart 而不是 `enable --now`：对**已在运行**的单元 `--now` 不会重启它，于是更新后
    # 服务仍在执行被替换掉的旧脚本。
    if ! systemctl --user enable cachyos-oom-watch.service; then
        warn "could not enable cachyos-oom-watch.service; run this after logging in:"
        warn "  systemctl --user enable --now cachyos-oom-watch.service"
    fi
    if ! systemctl --user restart cachyos-oom-watch.service; then
        warn "could not start cachyos-oom-watch.service; run this after logging in:"
        warn "  systemctl --user restart cachyos-oom-watch.service"
    else
        tui_ok "OOM 监听已启用并重启（亦可用 cachyos-agent-oom --latest 诊断）"
    fi

    # DMS 只在启动时读 settings.json：用量面板插件与状态栏接线要重启一次才生效。
    if systemctl --user is-active --quiet dms.service; then
        if ! systemctl --user restart dms.service; then
            warn "could not restart dms.service; the usage widget appears after the next login"
        else
            tui_ok "已重启 DMS（用量面板与状态栏控件生效）"
        fi
    fi

    # 主题同步：先跑一次（把当前模式写进各 agent），再挂上 path 单元跟着配色文件走。
    # 用量面板需要周期性重算，否则只会停在安装那一刻的数字。
    if ! systemctl --user enable --now cachyos-agent-usage.timer; then
        warn "could not enable cachyos-agent-usage.timer; run this after logging in:"
        warn "  systemctl --user enable --now cachyos-agent-usage.timer"
    else
        tui_ok "用量刷新定时器已启用（登录后 2 分钟，此后每 15 分钟）"
    fi

    # 先算一次并忽略失败：新用户一登录就该在面板里看到数字，而不是空面板；
    # 但采集失败（没登录过 agent、没有凭据）绝不能把安装判为失败。
    if ! cachyos-agent-usage-update --force >/dev/null 2>&1; then
        warn "could not collect agent usage yet (run cachyos-agent-usage-update after using an agent)"
    else
        tui_ok "已完成一次用量采集"
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
                tui_ok "默认 AI 编程助手：${available_agents[0]}（仅检测到一个）"
            fi
        elif ((${#available_agents[@]} > 1)); then
            info "several AI agents found; press Super+grave and pick one (the choice is remembered)"
        else
            tui_skip "未检测到 AI 编程助手，暂不设置默认值"
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
        tui_ok "已将当前明暗主题同步至 AI 助手，此后随配色变化自动同步"
    fi
}

main() {
    parse_args "$@"
    # 界面要在任何输出之前初始化：它决定了本次跑是画框上色还是纯文本。
    tui_init
    TUI_PHASE_TOTAL=6

    tui_banner "CachyOS · Niri · DankMaterialShell" \
        "在已安装的 CachyOS 上部署 Niri 与 DankMaterialShell，并配置 AI 编程助手" \
        "以具备 sudo 权限的普通用户运行；需要网络连接" \
        "不改动软件源、引导器、网络连接与 Secure Boot"

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
        tui_skip "已按 --skip-update 跳过系统升级"
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

    tui_phase_start "桌面配置与 AI 组件"
    install_desktop_assets
    install_agent_skills
    configure_dms_settings
    install_dms_plugins
    sync_ai_configs
    tui_phase_done

    tui_phase_start "服务启用与收尾"
    post_install
    tui_phase_done

    tui_summary "安装完成（未自动重启系统）" \
        "1. 在方便时重启，并在 Ly 中选择 Niri 会话" \
        "2. 至少退出并重新登录一次，使 Fish、Fcitx5、libvirt 和 i2c 组权限生效" \
        "3. 首次进入 Niri 后将在后台初始化 Firefox、Code、Wine 与 AI 助手技能" \
        "4. 执行：./verify.sh" \
        "5. 在 Niri 中执行：dms doctor" \
        "6. 执行：cachyos-lock-doctor" \
        "DMS 安装器已替换受管理的 Niri 和 Kitty 配置，并创建了自己的备份" \
        "首次登录初始化日志：~/.local/state/cachyos-desktop/post-login.log" \
        "指纹和安全密钥解锁会保持禁用，直到对应注册命令成功完成"
}

main "$@"
