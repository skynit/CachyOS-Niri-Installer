#!/usr/bin/env bash

# 日历用不同的组件 URL 避开 QML 缓存；比较受管清单时还原源码里的入口。
calendar_manifest() {
    jq -S '.components |= with_entries(.value = ("./" + (.value
        | sub("^\\./"; "") | sub("^\\.runtime-[0-9a-f]{16}/"; ""))))' "$1"
}

# 先准备完整运行目录，最后原子替换清单。旧目录保留给尚未重载的组件。
# 读取安装目录中的文件，因此 cachyos-config protect 保留的内容也会进入运行副本。
refresh_calendar_runtime() (
    set -e
    local target_dir="$1"
    local source_manifest="${2:-$1/plugin.json}"
    local stage digest runtime file
    local -a files

    [[ -f "$source_manifest" && -f "$target_dir/Calendar.js" && -x "$target_dir/todo-calendar-helper" ]] || return 0
    stage="$(mktemp -d "$target_dir/.runtime-stage.XXXXXX")"
    trap 'rm -rf -- "$stage"' EXIT
    calendar_manifest "$source_manifest" > "$stage/plugin.json"
    files=(Calendar.js todo-calendar-helper)
    for file in "$target_dir"/*.qml; do
        [[ -f "$file" ]] || continue
        files+=("${file##*/}")
    done
    digest="$( { cat "$stage/plugin.json"; (cd -- "$target_dir" && sha256sum -- "${files[@]}"); } | sha256sum)"
    runtime=".runtime-${digest:0:16}"
    mkdir "$stage/runtime"
    for file in "${files[@]}"; do
        install -m 0644 "$target_dir/$file" "$stage/runtime/$file"
    done
    chmod 0755 "$stage/runtime/todo-calendar-helper"
    if [[ -d "$target_dir/$runtime" ]]; then
        # 同一版本的运行文件被意外改坏时也能修复；正常重装不改时间戳。
        for file in "${files[@]}"; do
            if ! cmp -s "$stage/runtime/$file" "$target_dir/$runtime/$file"; then
                install -m 0644 "$stage/runtime/$file" "$target_dir/$runtime/$file"
            fi
        done
        chmod 0755 "$target_dir/$runtime/todo-calendar-helper"
    else
        mv -- "$stage/runtime" "$target_dir/$runtime"
    fi
    jq --arg runtime "$runtime" '.components |= with_entries(.value = ($runtime + "/" + (.value | ltrimstr("./"))))' \
        "$stage/plugin.json" > "$stage/active.json"
    chmod 0644 "$stage/active.json"
    mv -f -- "$stage/active.json" "$target_dir/plugin.json"
    # 与上游独立安装脚本的校验清单兼容，方便后续定向更新。
    (cd -- "$target_dir" && sha256sum -- plugin.json "${files[@]}" "${files[@]/#/$runtime/}") > "$stage/checksums"
    chmod 0644 "$stage/checksums"
    mv -f -- "$stage/checksums" "$target_dir/.installed-files.sha256"
)
