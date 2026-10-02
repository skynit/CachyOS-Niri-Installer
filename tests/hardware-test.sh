#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=../hardware.sh
source "$PROJECT_DIR/hardware.sh"

assert_contains() {
    local array_name="$1"
    local expected="$2"
    local value
    local -n values="$array_name"

    for value in "${values[@]}"; do
        [[ "$value" == "$expected" ]] && return 0
    done
    printf 'expected %s to contain %s\n' "$array_name" "$expected" >&2
    exit 1
}

assert_not_contains() {
    local array_name="$1"
    local unexpected="$2"
    local value
    local -n values="$array_name"

    for value in "${values[@]}"; do
        if [[ "$value" == "$unexpected" ]]; then
            printf 'expected %s not to contain %s\n' "$array_name" "$unexpected" >&2
            exit 1
        fi
    done
}

select_profile() {
    CACHYOS_CPU_VENDOR="$1"
    shift
    CACHYOS_GPU_DEVICES=("$@")
    cachyos_select_hardware_packages
}

[[ "$(cachyos_pci_vendor_name 0x8086)" == intel ]]
[[ "$(cachyos_pci_vendor_name 1002)" == amd ]]
[[ "$(cachyos_pci_vendor_name 10de)" == nvidia ]]

select_profile intel intel:i915
assert_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES intel-ucode
assert_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES vulkan-intel
assert_contains CACHYOS_HARDWARE_OPTIONAL_PACKAGES intel-media-driver
assert_not_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES amd-ucode

select_profile amd amd:amdgpu
assert_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES amd-ucode
assert_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES vulkan-radeon
assert_contains CACHYOS_HARDWARE_OPTIONAL_PACKAGES lib32-vulkan-radeon
assert_not_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES intel-ucode

select_profile intel intel:i915 nvidia:nvidia
assert_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES vulkan-intel
assert_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES nvidia-utils
assert_not_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES nvidia-open-dkms

select_profile intel nvidia:unknown
assert_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES nvidia-utils
assert_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES nvidia-open-dkms

select_profile amd nvidia:nouveau
assert_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES vulkan-nouveau
assert_not_contains CACHYOS_HARDWARE_REQUIRED_PACKAGES nvidia-utils

# ---- 虚拟包 vulkan-driver / lib32-vulkan-driver 必须被显式满足 -------------------
# steam 同时依赖这两个虚拟包。这次事务里若没有具体提供者，pacman 会在交互提示里列出一堆候选，
# 非交互（--noconfirm）时它取第一个 mesa-git / lib32-mesa-git——这两个和基础系统的
# mesa / lib32-mesa **直接冲突**，pacman 报 "unresolvable package conflicts detected"，
# 整个安装以退出码 1 中断。真机（KVM 虚拟机、无可识别 GPU）实测到过。
#
# 注意 assert_contains 失败时直接 exit，所以"任一候选满足"这种判断不能用它。
select_profile amd    # CPU 厂商合法、但没有任何 GPU 设备 → 走"没探测到 GPU"的分支
for pair in "64:vulkan-swrast vulkan-radeon vulkan-intel vulkan-nouveau nvidia-utils" \
            "32:lib32-vulkan-swrast lib32-vulkan-radeon lib32-vulkan-intel lib32-vulkan-nouveau lib32-nvidia-utils"; do
    label="${pair%%:*}"
    candidates="${pair#*:}"
    found=""
    for candidate in $candidates; do
        for value in "${CACHYOS_HARDWARE_REQUIRED_PACKAGES[@]}"; do
            [[ "$value" == "$candidate" ]] && found="$candidate"
        done
    done
    if [[ -z $found ]]; then
        printf '没有 %s 位 vulkan 提供者：pacman 会自己猜，可能选中 mesa-git 而冲突\n' "$label" >&2
        printf '已选包：%s\n' "${CACHYOS_HARDWARE_REQUIRED_PACKAGES[*]}" >&2
        exit 1
    fi
done
printf 'vulkan-provider test: ok\n'

printf '%s\n' 'hardware tests: ok'
