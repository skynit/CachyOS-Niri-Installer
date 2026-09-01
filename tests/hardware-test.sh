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

printf '%s\n' 'hardware tests: ok'
