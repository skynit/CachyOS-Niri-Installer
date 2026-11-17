#!/usr/bin/env bash

set -Eeuo pipefail

printf '正在连接 CachyOS 桌面安装资源下载站…\n'

for command_name in curl tar sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '缺少命令：%s\n' "$command_name" >&2
        exit 1
    }
done

setup_dir="$(mktemp -d "${TMPDIR:-/tmp}/cachyos-niri-setup.XXXXXX")"
trap 'rm -rf -- "$setup_dir"' EXIT

download_base="${CACHYOS_DOWNLOAD_BASE:-http://47.119.120.17/cachyos}"
download_base="${download_base%/}"
curl_args=(--fail --location --retry 2 --connect-timeout 10 --speed-limit 1024 --speed-time 30)

curl "${curl_args[@]}" "$download_base/SHA256SUMS" --output "$setup_dir/SHA256SUMS"
manifest="$(cat "$setup_dir/SHA256SUMS")"
if [[ ! $manifest =~ ^([0-9a-f]{64})[[:blank:]]{2}(source-[0-9a-f]{40}\.tar\.gz)$ ]]; then
    printf '下载清单无效，请检查下载站是否可用。\n' >&2
    exit 1
fi
archive_sha="${BASH_REMATCH[1]}"
archive_name="${BASH_REMATCH[2]}"

printf '正在下载 CachyOS 桌面安装包…\n'
curl "${curl_args[@]}" "$download_base/$archive_name" --output "$setup_dir/$archive_name"
if ! printf '%s  %s\n' "$archive_sha" "$setup_dir/$archive_name" | sha256sum --check --status; then
    printf '安装包校验失败，已停止；请重新下载。\n' >&2
    exit 1
fi

printf '校验通过，正在解压安装包…\n'
tar -xzf "$setup_dir/$archive_name" --strip-components=1 -C "$setup_dir"
[[ -s "$setup_dir/install.sh" ]] || {
    printf '安装包缺少 install.sh，已停止。\n' >&2
    exit 1
}

printf '正在启动安装器…\n'
bash "$setup_dir/install.sh" "$@"
