#!/usr/bin/env bash

# Shared hardware detection and package selection for the installer and verifier.

CACHYOS_CPU_VENDOR="unknown"
declare -ag CACHYOS_GPU_DEVICES=()
declare -ag CACHYOS_HARDWARE_REQUIRED_PACKAGES=()
declare -ag CACHYOS_HARDWARE_OPTIONAL_PACKAGES=()
declare -ag CACHYOS_HARDWARE_NOTES=()

cachyos_append_unique() {
    local array_name="$1"
    local value="$2"
    local existing
    local -n target_array="$array_name"

    for existing in "${target_array[@]}"; do
        [[ "$existing" == "$value" ]] && return 0
    done
    target_array+=("$value")
}

cachyos_pci_vendor_name() {
    case "${1,,}" in
        0x8086|8086) printf '%s\n' intel ;;
        0x1002|1002) printf '%s\n' amd ;;
        0x10de|10de) printf '%s\n' nvidia ;;
        *) printf '%s\n' unknown ;;
    esac
}

cachyos_detect_cpu_vendor() {
    local cpuinfo_file="${1:-/proc/cpuinfo}"
    local vendor_id=""

    if [[ -r "$cpuinfo_file" ]]; then
        vendor_id="$(awk -F: '/^[[:space:]]*vendor_id[[:space:]]*:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$cpuinfo_file")"
    fi

    case "$vendor_id" in
        GenuineIntel) CACHYOS_CPU_VENDOR="intel" ;;
        AuthenticAMD) CACHYOS_CPU_VENDOR="amd" ;;
        *) CACHYOS_CPU_VENDOR="unknown" ;;
    esac
}

cachyos_add_gpu_device() {
    local vendor="$1"
    local driver="${2:-unknown}"
    cachyos_append_unique CACHYOS_GPU_DEVICES "$vendor:$driver"
}

cachyos_detect_gpu_devices() {
    local drm_root="${1:-/sys/class/drm}"
    local card_path card_name vendor_id vendor driver_path resolved_driver driver
    CACHYOS_GPU_DEVICES=()

    for card_path in "$drm_root"/card*; do
        [[ -e "$card_path" ]] || continue
        card_name="${card_path##*/}"
        [[ "$card_name" =~ ^card[0-9]+$ ]] || continue
        [[ -r "$card_path/device/vendor" ]] || continue

        read -r vendor_id < "$card_path/device/vendor"
        vendor="$(cachyos_pci_vendor_name "$vendor_id")"
        driver="unknown"
        driver_path="$card_path/device/driver"
        if [[ -L "$driver_path" ]]; then
            resolved_driver="$(readlink -f -- "$driver_path" 2>/dev/null || true)"
            [[ -z "$resolved_driver" ]] || driver="$(basename -- "$resolved_driver")"
        fi
        cachyos_add_gpu_device "$vendor" "$driver"
    done

    if ((${#CACHYOS_GPU_DEVICES[@]} == 0)) && command -v lspci >/dev/null 2>&1; then
        while IFS= read -r vendor_id; do
            [[ -n "$vendor_id" ]] || continue
            cachyos_add_gpu_device "$(cachyos_pci_vendor_name "$vendor_id")" unknown
        done < <(lspci -Dn 2>/dev/null | awk '$2 ~ /^(0300|0302|0380):$/ { split($3, id, ":"); print id[1] }')
    fi
}

cachyos_detect_hardware() {
    cachyos_detect_cpu_vendor "${1:-/proc/cpuinfo}"
    cachyos_detect_gpu_devices "${2:-/sys/class/drm}"
}

cachyos_select_hardware_packages() {
    # 每次选择都从零开始：这两个标记决定"要不要补软件回退提供者"，残留值会让函数在不同
    # 调用顺序下给出不同结果（测试里就先踩到：上一轮的 intel 让回退不触发）。
    CACHYOS_HARDWARE_VULKAN_PROVIDER=""
    CACHYOS_HARDWARE_VULKAN_PROVIDER_32=""
    local device vendor driver kernel_pkgbase_file kernel_pkgbase

    CACHYOS_HARDWARE_REQUIRED_PACKAGES=(
        linux-firmware
        mesa
        sof-firmware
        pipewire
        pipewire-alsa
        pipewire-pulse
        wireplumber
        bluez
        bluez-utils
    )
    CACHYOS_HARDWARE_OPTIONAL_PACKAGES=(
        vulkan-tools
        fwupd
        bolt
        v4l-utils
        usbutils
        pciutils
    )
    CACHYOS_HARDWARE_NOTES=()

    case "$CACHYOS_CPU_VENDOR" in
        intel) cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES intel-ucode ;;
        amd) cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES amd-ucode ;;
        *) CACHYOS_HARDWARE_NOTES+=("CPU vendor is unknown; no microcode package was selected") ;;
    esac

    for device in "${CACHYOS_GPU_DEVICES[@]}"; do
        vendor="${device%%:*}"
        driver="${device#*:}"
        case "$vendor" in
            intel)
                CACHYOS_HARDWARE_VULKAN_PROVIDER="vulkan-intel"
                CACHYOS_HARDWARE_VULKAN_PROVIDER_32="lib32-vulkan-intel"
                cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES vulkan-intel
                cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES lib32-vulkan-intel
                cachyos_append_unique CACHYOS_HARDWARE_OPTIONAL_PACKAGES lib32-vulkan-intel
                cachyos_append_unique CACHYOS_HARDWARE_OPTIONAL_PACKAGES intel-media-driver
                cachyos_append_unique CACHYOS_HARDWARE_OPTIONAL_PACKAGES libva-utils
                ;;
            amd)
                CACHYOS_HARDWARE_VULKAN_PROVIDER="vulkan-radeon"
                CACHYOS_HARDWARE_VULKAN_PROVIDER_32="lib32-vulkan-radeon"
                cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES vulkan-radeon
                cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES lib32-vulkan-radeon
                cachyos_append_unique CACHYOS_HARDWARE_OPTIONAL_PACKAGES lib32-vulkan-radeon
                ;;
            nvidia)
                if [[ "$driver" == "nouveau" ]]; then
                    CACHYOS_HARDWARE_VULKAN_PROVIDER="vulkan-nouveau"
                    CACHYOS_HARDWARE_VULKAN_PROVIDER_32="lib32-vulkan-nouveau"
                    cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES vulkan-nouveau
                    cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES lib32-vulkan-nouveau
                    cachyos_append_unique CACHYOS_HARDWARE_OPTIONAL_PACKAGES lib32-vulkan-nouveau
                else
                    # NVIDIA 的专有栈自己提供 vulkan 实现，也算"已指定提供者"。
                    CACHYOS_HARDWARE_VULKAN_PROVIDER="nvidia-utils"
                    CACHYOS_HARDWARE_VULKAN_PROVIDER_32="lib32-nvidia-utils"
                    cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES nvidia-utils
                    cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES lib32-nvidia-utils
                    cachyos_append_unique CACHYOS_HARDWARE_OPTIONAL_PACKAGES lib32-nvidia-utils
                    cachyos_append_unique CACHYOS_HARDWARE_OPTIONAL_PACKAGES nvidia-settings
                    if [[ "$driver" != "nvidia" ]]; then
                        cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES nvidia-open-dkms
                        kernel_pkgbase_file="/usr/lib/modules/$(uname -r)/pkgbase"
                        if [[ -r "$kernel_pkgbase_file" ]]; then
                            read -r kernel_pkgbase < "$kernel_pkgbase_file"
                            [[ -n "$kernel_pkgbase" ]] && cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES "${kernel_pkgbase}-headers"
                        else
                            CACHYOS_HARDWARE_NOTES+=("NVIDIA is unbound and the current kernel headers could not be inferred")
                        fi
                    fi
                fi
                ;;
            *) cachyos_append_unique CACHYOS_HARDWARE_NOTES "An unsupported GPU vendor was detected; only common graphics packages were selected" ;;
        esac
    done

    if ((${#CACHYOS_GPU_DEVICES[@]} == 0)); then
        CACHYOS_HARDWARE_NOTES+=("No GPU was detected; only common hardware packages were selected")
    fi

    # 必须保证 pacman 不需要**猜** vulkan 提供者。
    #
    # `steam` 依赖虚拟包 `vulkan-driver`。如果这次事务里没有任何具体的提供者，pacman 会在
    # 交互提示里列出 32 个候选，非交互（--noconfirm）时它取第一个 `mesa-git`——而 mesa-git 与
    # 基础系统里的 `mesa` **直接冲突**，于是 pacman 报 "unresolvable package conflicts detected"
    # 并让整个安装以退出码 1 中断。真机上实测过（虚拟机里没有可识别的 GPU 时必现）。
    #
    # 所以没有探测到具体 GPU 驱动时，显式加一个软件回退提供者：它依赖的是 `mesa` 而不是
    # `mesa-git`，满足虚拟依赖且不引入冲突。
    if [[ -z "${CACHYOS_HARDWARE_VULKAN_PROVIDER:-}" ]]; then
        cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES vulkan-swrast
        CACHYOS_HARDWARE_VULKAN_PROVIDER="vulkan-swrast"
    fi
    # 32 位的那个虚拟依赖同样必须被显式满足：`lib32-vulkan-*` 在上面的分支里只是"可选"包，
    # 默认不装；缺了它 pacman 仍然会去猜，照样选中 lib32-mesa-git 而冲突。
    if [[ -z "${CACHYOS_HARDWARE_VULKAN_PROVIDER_32:-}" ]]; then
        cachyos_append_unique CACHYOS_HARDWARE_REQUIRED_PACKAGES lib32-vulkan-swrast
        CACHYOS_HARDWARE_VULKAN_PROVIDER_32="lib32-vulkan-swrast"
    fi
}

cachyos_hardware_summary() {
    local device vendor driver label summary=""
    local cpu_label="Unknown CPU"

    case "$CACHYOS_CPU_VENDOR" in
        intel) cpu_label="Intel CPU" ;;
        amd) cpu_label="AMD CPU" ;;
    esac

    for device in "${CACHYOS_GPU_DEVICES[@]}"; do
        vendor="${device%%:*}"
        driver="${device#*:}"
        case "$vendor" in
            intel) label="Intel GPU" ;;
            amd) label="AMD GPU" ;;
            nvidia) label="NVIDIA GPU" ;;
            *) label="Unknown GPU" ;;
        esac
        [[ "$driver" == "unknown" ]] || label+=" ($driver)"
        [[ -z "$summary" ]] || summary+=", "
        summary+="$label"
    done

    [[ -n "$summary" ]] || summary="No GPU detected"
    printf '%s; %s\n' "$cpu_label" "$summary"
}
