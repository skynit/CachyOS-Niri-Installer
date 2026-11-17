#!/usr/bin/env bash

set -Eeuo pipefail

for command_name in curl tar; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '缺少命令：%s\n' "$command_name" >&2
        exit 1
    }
done

setup_dir="$(mktemp -d "${TMPDIR:-/tmp}/cachyos-niri-setup.XXXXXX")"
trap 'rm -rf -- "$setup_dir"' EXIT

printf '正在下载 CachyOS 桌面安装包…\n'
curl --fail --location --retry 3 \
    https://github.com/skynit/CachyOS-Niri-Installer/archive/refs/heads/main.tar.gz \
    --output "$setup_dir/source.tar.gz"
tar -xzf "$setup_dir/source.tar.gz" --strip-components=1 -C "$setup_dir"

bash "$setup_dir/install.sh" "$@"
