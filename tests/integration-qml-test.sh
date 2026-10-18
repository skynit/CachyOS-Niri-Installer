#!/usr/bin/env bash

# Optional real-DMS control regression; no compositor input or real user services.
set -euo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname -- "$TEST_DIR")"
DMS_ROOT="${CACHYOS_TEST_DMS_ROOT:-}"
if [[ -z $DMS_ROOT ]]; then
    for entry in /run/user/"$(id -u)"/danklinux-shell/*/shell.qml; do
        [[ -f $entry ]] && DMS_ROOT="${entry%/shell.qml}"
    done
fi
if ! command -v qs >/dev/null || [[ ! -d $DMS_ROOT/DankCommon ]]; then
    printf 'ok - skipped: real DMS QML imports or Quickshell unavailable\n'
    exit 0
fi
WORK_DIR="$(mktemp -d /tmp/cachyos-ai-qml.XXXXXX)"
cleanup() {
    [[ $WORK_DIR == /tmp/cachyos-ai-qml.* && -d $WORK_DIR ]] || return 0
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
mkdir -p "$WORK_DIR/home" "$WORK_DIR/config" "$WORK_DIR/cache"
for name in Common Widgets Services Modules DankCommon Modals Assets; do
    [[ ! -e $DMS_ROOT/$name ]] || ln -s "$DMS_ROOT/$name" "$WORK_DIR/$name"
done
ln -s "$PROJECT_DIR/assets/dms-plugins/CachyosAgents" "$WORK_DIR/Plugin"
sed 's|@PLUGIN_DIR@|Plugin|' \
    "$TEST_DIR/fixtures/ai-integration.qml" > "$WORK_DIR/probe.qml"
if ! env -u WAYLAND_DISPLAY -u NIRI_SOCKET \
    HOME="$WORK_DIR/home" XDG_CONFIG_HOME="$WORK_DIR/config" XDG_CACHE_HOME="$WORK_DIR/cache" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$WORK_DIR/no-session-bus" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    timeout 20 qs -p "$WORK_DIR/probe.qml" > "$WORK_DIR/output.log" 2>&1; then
    tail -60 "$WORK_DIR/output.log"
    exit 1
fi
if grep -Eq 'INTEGRATION_FAIL|Binding loop|Unable to assign|ReferenceError|TypeError|is not a type|is unavailable' "$WORK_DIR/output.log"; then
    tail -60 "$WORK_DIR/output.log"
    exit 1
fi
if ! grep -q 'INTEGRATION_COMPLETE' "$WORK_DIR/output.log"; then
    tail -60 "$WORK_DIR/output.log"
    exit 1
fi
grep 'INTEGRATION_PASS' "$WORK_DIR/output.log"
printf 'ok - real DMS controls: clean loading, draft preservation, bounded layouts\n'
