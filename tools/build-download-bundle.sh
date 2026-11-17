#!/usr/bin/env bash

# 从已提交版本生成下载站文件；不打包工作区中无关的未提交文件。
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:?Usage: tools/build-download-bundle.sh OUTPUT_DIR}"
mkdir -p -- "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

revision="$(git -C "$project_dir" rev-parse HEAD)"
timestamp="$(git -C "$project_dir" show -s --format=%ct "$revision")"
git -C "$project_dir" archive --format=tar --prefix=CachyOS-Niri-Installer/ "$revision" |
    tar -xf - -C "$work_dir"
bundle_dir="$work_dir/CachyOS-Niri-Installer"

setting() {
    sed -nE "s/^readonly $1=\"([^\"]+)\"$/\1/p" "$bundle_dir/install.sh"
}

dms_version="$(setting PINNED_DMS_VERSION)"
dms_sha="$(setting PINNED_DMS_SHA256_AMD64)"
sidebar_version="$(setting PINNED_NIRI_SIDEBAR_VERSION)"
sidebar_sha="$(setting PINNED_NIRI_SIDEBAR_SHA256_AMD64)"
[[ $dms_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $dms_sha =~ ^[0-9a-f]{64}$ ]]
[[ $sidebar_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $sidebar_sha =~ ^[0-9a-f]{64}$ ]]

fetch() {
    local url="$1" expected_sha="$2" destination="$3"
    local cache="${CACHYOS_DOWNLOAD_CACHE:-}/$(basename -- "$destination")"
    mkdir -p -- "$(dirname -- "$destination")"
    if [[ -n ${CACHYOS_DOWNLOAD_CACHE:-} && -s "$cache" ]]; then
        cp -- "$cache" "$destination"
    else
        curl --fail --location --retry 3 --connect-timeout 10 \
            --speed-limit 1024 --speed-time 30 "$url" --output "$destination"
    fi
    printf '%s  %s\n' "$expected_sha" "$destination" | sha256sum --check --status
    chmod 0644 "$destination"
}

dms_archive="$bundle_dir/assets/downloads/dms/$dms_version/dankinstall-amd64.gz"
fetch "https://github.com/AvengeMedia/DankMaterialShell/releases/download/$dms_version/dankinstall-amd64.gz" \
    "$dms_sha" "$dms_archive"
printf '%s  dankinstall-amd64.gz\n' "$dms_sha" > "$dms_archive.sha256"
fetch "https://github.com/Vigintillionn/niri-sidebar/releases/download/$sidebar_version/niri-sidebar-linux-x86_64" \
    "$sidebar_sha" "$bundle_dir/assets/downloads/niri-sidebar/$sidebar_version/niri-sidebar-linux-x86_64"

archive_name="source-$revision.tar.gz"
tar --sort=name --mtime="@$timestamp" --owner=0 --group=0 --numeric-owner \
    -czf "$work_dir/$archive_name" -C "$work_dir" CachyOS-Niri-Installer
install -m 0644 "$work_dir/$archive_name" "$output_dir/$archive_name"
install -m 0644 "$bundle_dir/setup.sh" "$output_dir/setup.sh"
(cd -- "$output_dir" && sha256sum "$archive_name") > "$output_dir/SHA256SUMS"
printf '下载站文件已生成：%s\n版本：%s\n' "$output_dir" "$revision"
