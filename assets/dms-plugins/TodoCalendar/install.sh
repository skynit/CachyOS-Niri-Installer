#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
plugin_target="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/TodoCalendar"
runtime_files=(plugin.json Calendar.js ./*.qml todo-calendar-helper)
[[ -x todo-calendar-helper ]] || { echo '请先运行 bash build.sh。' >&2; exit 1; }
for plugin_file in "${runtime_files[@]}"; do
    [[ -f "$plugin_file" && -r "$plugin_file" && ! -L "$plugin_file" ]] || { echo "来源文件不可读或不是普通文件：$plugin_file" >&2; exit 1; }
done
[[ ! -L "$plugin_target" ]] || { echo '安装目录为符号链接，未覆盖。' >&2; exit 1; }
if [[ -d "$plugin_target" ]]; then
    [[ -f "$plugin_target/.installed-files.sha256" && ! -L "$plugin_target/.installed-files.sha256" ]] || { echo '安装目录的校验清单缺失或为符号链接，未覆盖。' >&2; exit 1; }
    (cd -- "$plugin_target" && sha256sum --check --quiet .installed-files.sha256) || { echo '已安装副本存在本地修改，未覆盖。' >&2; exit 1; }
    for plugin_file in "${runtime_files[@]}"; do
        [[ ! -L "$plugin_target/$plugin_file" ]] || { echo "目标文件为符号链接：$plugin_file" >&2; exit 1; }
        if [[ -e "$plugin_target/$plugin_file" ]] && ! rg -Fq -- "  $plugin_file" "$plugin_target/.installed-files.sha256"; then
            echo "目标内已有未登记文件 $plugin_file，未覆盖。" >&2
            exit 1
        fi
    done
fi
plugin_parent="$(dirname -- "$plugin_target")"
plugin_staging="$(dirname -- "$plugin_parent")/.plugin-staging"
mkdir -p -- "$plugin_parent" "$plugin_staging"
plugin_stage=$(mktemp -d "$plugin_staging/TodoCalendar.XXXXXX")
plugin_backup="${plugin_stage}.previous"
cleanup() {
    if [[ ! -e "$plugin_target" && -d "$plugin_backup" ]]; then mv -- "$plugin_backup" "$plugin_target"; fi
    if [[ -d "$plugin_stage" ]]; then rm -rf -- "$plugin_stage"; fi
}
trap cleanup EXIT
if [[ -d "$plugin_target" ]]; then cp -a -- "$plugin_target/." "$plugin_stage/"; fi
for plugin_file in "${runtime_files[@]}"; do
    install -D -m 0644 -- "$plugin_file" "$plugin_stage/$plugin_file"
done
chmod 0755 -- "$plugin_stage/todo-calendar-helper"
# A new directory changes every nested QML URL, avoiding engine component
# caches without restarting DMS or other plugins' long-running processes.
plugin_hash=$(sha256sum -- "${runtime_files[@]}" | sha256sum)
plugin_runtime=".runtime-${plugin_hash:0:16}"
plugin_runtime_files=()
for plugin_file in Calendar.js ./*.qml todo-calendar-helper; do
    install -D -m 0644 -- "$plugin_file" "$plugin_stage/$plugin_runtime/$plugin_file"
    plugin_runtime_files+=("$plugin_runtime/$plugin_file")
done
chmod 0755 -- "$plugin_stage/$plugin_runtime/todo-calendar-helper"
jq --arg runtime "$plugin_runtime" '.components |= with_entries(.value = ($runtime + "/" + (.value | ltrimstr("./"))))' plugin.json > "$plugin_stage/plugin.json"
plugin_manifest=$(mktemp "$plugin_stage/.checksums.XXXXXX")
(cd -- "$plugin_stage" && sha256sum -- "${runtime_files[@]}" "${plugin_runtime_files[@]}" > "$plugin_manifest")
mv -T -- "$plugin_manifest" "$plugin_stage/.installed-files.sha256"
if [[ -d "$plugin_target" ]]; then mv -- "$plugin_target" "$plugin_backup"; fi
mv -- "$plugin_stage" "$plugin_target"
if [[ -d "$plugin_backup" ]]; then echo "上次安装备份：$plugin_backup"; fi
echo "已安装：$plugin_target"
echo '首次扫描：dms ipc call plugin-scan scan'
echo '启用插件：dms ipc call plugins enable todoCalendar'
echo '添加入口：dms ipc call todoCalendar addToBar'
echo '打开日历：dms ipc call todoCalendar open'
