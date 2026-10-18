#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v go >/dev/null || { printf 'Go is required to build helper binaries\n' >&2; exit 1; }
mkdir -p "$root/assets/go-bin"

GOOS=linux GOARCH=amd64 GOAMD64=v1 CGO_ENABLED=0 go -C "$root/go/ai-settings" build -trimpath -buildvcs=false \
    -o "$root/assets/go-bin/cachyos-ai-settings" .
GOOS=linux GOARCH=amd64 GOAMD64=v1 CGO_ENABLED=0 go -C "$root/go/usage-json" build -trimpath -buildvcs=false \
    -o "$root/assets/go-bin/cachyos-usage-json" .

# DMS 插件自带的 Go helper：插件 QML 用 Qt.resolvedUrl 在插件目录里找同名可执行文件，
# 所以构建产物由 tools/install-go-helpers.sh 装进 ~/.config/DankMaterialShell/plugins/<插件>/。
# 源码随插件资产一起放在 assets/dms-plugins/ 下（与上游仓库目录结构一致），
# 这样同步上游时只需复制目录，不用在两个地方维护 Go 源码。
GOOS=linux GOARCH=amd64 GOAMD64=v1 CGO_ENABLED=0 go -C "$root/assets/dms-plugins/LocalTranslate" build -trimpath -buildvcs=false \
    -o "$root/assets/go-bin/translate-lookup" .
GOOS=linux GOARCH=amd64 GOAMD64=v1 CGO_ENABLED=0 go -C "$root/assets/dms-plugins/LocalLyrics" build -trimpath -buildvcs=false \
    -o "$root/assets/go-bin/lyrics-helper" .
GOOS=linux GOARCH=amd64 GOAMD64=v1 CGO_ENABLED=0 go -C "$root/assets/dms-plugins/PhoneConnect" build -trimpath -buildvcs=false \
    -o "$root/assets/go-bin/phone-connect" .
GOOS=linux GOARCH=amd64 GOAMD64=v1 CGO_ENABLED=0 go -C "$root/assets/dms-plugins/Focus" build -trimpath -buildvcs=false \
    -o "$root/assets/go-bin/focus-helper" .
GOOS=linux GOARCH=amd64 GOAMD64=v1 CGO_ENABLED=0 go -C "$root/assets/dms-plugins/Top/helper" build -trimpath -buildvcs=false \
    -o "$root/assets/go-bin/top-helper" .
