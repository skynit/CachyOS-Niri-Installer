# shellcheck shell=bash
# Read data without sourcing it: prompts and regular expressions are never executable code.
cachyos_load_ai_settings() {
    local file="${XDG_CONFIG_HOME:-$HOME/.config}/cachyos-desktop/ai-settings.conf"
    local key value
    [[ -r $file ]] || return 0
    while IFS='=' read -r key value || [[ -n $key ]]; do
        case "$key" in
            CACHYOS_DSH_PROFILE | CACHYOS_AGENT_NOTIFY_MIN_SECONDS | \
            CACHYOS_ASK_SESSION | CACHYOS_ASK_MAX_CHARS | \
            CACHYOS_CRASH_ACTION | CACHYOS_CRASH_DEDUPE_SECONDS | CACHYOS_CRASH_IGNORE | \
            CACHYOS_OOM_ACTION | CACHYOS_OOM_DEDUPE_SECONDS | CACHYOS_OOM_PSI_ENABLED | \
            CACHYOS_OOM_PSI_FULL_AVG60 | CACHYOS_OOM_PSI_INTERVAL_SECONDS)
                # Explicit process environment always takes precedence over saved preferences.
                if [[ ! -v $key ]]; then
                    export "$key=$value"
                fi
                ;;
        esac
    done < "$file"
}
cachyos_load_ai_settings
