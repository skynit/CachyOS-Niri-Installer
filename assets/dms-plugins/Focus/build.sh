#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

target_arch="${GOARCH:-$(go env GOARCH)}"
if [[ "$target_arch" == amd64 ]]; then
    CGO_ENABLED=0 GOAMD64=v1 go build -trimpath -o focus-helper .
else
    CGO_ENABLED=0 go build -trimpath -o focus-helper .
fi
