#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/assets/go-bin"
for helper in cachyos-ai-settings cachyos-usage-json \
              translate-lookup lyrics-helper phone-connect focus-helper top-helper; do
    [[ -x "$bin/$helper" ]] || { printf 'Missing %s; run tools/build-go-helpers.sh first\n' "$bin/$helper" >&2; exit 1; }
done

backup="${XDG_STATE_HOME:-$HOME/.local/state}/cachyos-desktop/backups/go-helpers-$(date +%Y%m%d-%H%M%S)"
mkdir -p -m 0700 "$backup"
for helper in cachyos-ai-settings cachyos-agent-usage-update cachyos-usage-json; do
    if [[ -f "/usr/local/bin/$helper" ]]; then
        cp -p "/usr/local/bin/$helper" "$backup/$helper"
    fi
done

sudo install -m 0755 "$bin/cachyos-ai-settings" /usr/local/bin/cachyos-ai-settings
sudo install -m 0755 "$bin/cachyos-usage-json" /usr/local/bin/cachyos-usage-json
sudo install -m 0755 "$root/bin/cachyos-agent-usage-update" /usr/local/bin/cachyos-agent-usage-update

# 插件目录名是 DMS 的安装目录名（大小写必须与上游一致）；插件 QML 用 Qt.resolvedUrl
# 在自身目录里找 helper，所以二进制必须和 QML 放在一起。
plugin_root="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins"
install -d -m 0755 \
    "$plugin_root/CachyosAgents" \
    "$plugin_root/localTranslate" \
    "$plugin_root/localLyrics" \
    "$plugin_root/PhoneConnect" \
    "$plugin_root/Focus" \
    "$plugin_root/Top"
install -m 0755 "$bin/cachyos-ai-settings" "$plugin_root/CachyosAgents/ai-settings"
install -m 0755 "$bin/cachyos-usage-json" "$plugin_root/CachyosAgents/usage-json"
install -m 0755 "$bin/translate-lookup" "$plugin_root/localTranslate/translate-lookup"
install -m 0755 "$bin/lyrics-helper" "$plugin_root/localLyrics/lyrics-helper"
install -m 0755 "$bin/phone-connect" "$plugin_root/PhoneConnect/phone-connect"
install -m 0755 "$bin/focus-helper" "$plugin_root/Focus/focus-helper"
install -m 0755 "$bin/top-helper" "$plugin_root/Top/top-helper"
printf 'Go helpers installed; previous system commands saved in %s\n' "$backup"
