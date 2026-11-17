#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
plugin_target="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/DesktopSettings"
runtime_files=(plugin.json qmldir desktop-settings-helper ./*.qml icons/*.svg icons/LICENSE)
[[ -x desktop-settings-helper ]] || { echo '请先运行 bash build.sh 构建辅助程序。' >&2; exit 1; }
[[ ! -L "$plugin_target" ]] || { echo '安装目录是符号链接，请先核对目标；未写入。' >&2; exit 1; }
if [[ -d "$plugin_target" ]]; then
    [[ -f "$plugin_target/.installed-files.sha256" ]] || { echo '安装目录已有未登记的副本，请先核对；未覆盖。' >&2; exit 1; }
    (cd -- "$plugin_target" && sha256sum --check --quiet .installed-files.sha256) || { echo '已安装副本存在本地改动，请先核对；未覆盖。' >&2; exit 1; }
    for plugin_file in "${runtime_files[@]}"; do
        if [[ -e "$plugin_target/$plugin_file" ]] && ! rg -Fq -- "  $plugin_file" "$plugin_target/.installed-files.sha256"; then
            echo "目标内已有未登记文件 $plugin_file；未覆盖。" >&2
            exit 1
        fi
    done
fi
for plugin_file in "${runtime_files[@]}"; do
    install -D -m 0644 -- "$plugin_file" "$plugin_target/$plugin_file"
done
chmod 0755 -- "$plugin_target/desktop-settings-helper"
(cd -- "$plugin_target" && sha256sum -- "${runtime_files[@]}" > .installed-files.sha256)
echo "已安装运行文件：$plugin_target"
echo '首次安装：dms ipc call plugin-scan scan；更新：dms ipc call plugin-scan rescan desktopSettings'
