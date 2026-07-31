#!/usr/bin/env bash
set -euo pipefail

# Pi coding agent integration for tmux-notify-jump
# Reads JSON from stdin (piped by the pi-extension/tmux-notify-jump.ts bridge)

# Extension-spawned processes may run with a restricted environment (common
# under tmux / hook runners).
# Under `set -u`, `$PATH` may be unset, so avoid expanding it directly.
if [ -n "${PATH:-}" ]; then
    export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
else
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-notify-jump-lib.sh
. "$SCRIPT_DIR/tmux-notify-jump-lib.sh"

payload="$(cat)"
[ -n "$payload" ] || exit 0

load_user_config
ensure_tmux_notify_socket_from_env

log_debug() {
    [ "${PI_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local logfile="${PI_NOTIFY_DEBUG_LOG:-$HOME/.pi/agent/logs/notify-pi.log}"
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$logfile" 2>/dev/null || true
}

is_valid_ui() {
    local ui="${1:-}"
    [ "$ui" = "notification" ] || [ "$ui" = "dialog" ]
}

lookup_kv_map() {
    # Lookup key in a comma-separated key:value map string.
    #
    # Example:
    #   lookup_kv_map "agent_settled" "agent_settled:notification,agent_end:dialog"
    #
    # Prints value to stdout if found, otherwise prints nothing.
    local key="${1:-}"
    local map="${2:-}"
    [ -n "$key" ] || return 1
    [ -n "$map" ] || return 1

    local entry=""
    local k=""
    local v=""
    local IFS=","
    for entry in $map; do
        entry="$(trim_ws "$entry")"
        [ -n "$entry" ] || continue
        case "$entry" in
            *:*)
                k="${entry%%:*}"
                v="${entry#*:}"
                ;;
            *)
                continue
                ;;
        esac
        k="$(trim_ws "$k")"
        v="$(trim_ws "$v")"
        if [ "$k" = "$key" ]; then
            printf '%s' "$v"
            return 0
        fi
    done
    return 1
}

need() {
    if command -v "$1" >/dev/null 2>&1; then
        return 0
    fi
    log_debug "missing dependency: $1"
    exit 0
}

need jq

if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
    log_debug "invalid JSON payload; ignoring"
    exit 0
fi

MAX_TITLE="$(normalize_int "${PI_NOTIFY_MAX_TITLE:-${TMUX_NOTIFY_MAX_TITLE:-80}}" 80)"
MAX_BODY="$(normalize_int "${PI_NOTIFY_MAX_BODY:-${TMUX_NOTIFY_MAX_BODY:-200}}" 200)"
TIMEOUT_MS_BASE="$(normalize_int "${PI_NOTIFY_TIMEOUT_MS:-${TMUX_NOTIFY_TIMEOUT:-0}}" 0)"

# Event filtering configuration
PI_EVENTS="${PI_NOTIFY_EVENTS:-}"          # whitelist (empty=default, *=all)
PI_EXCLUDE="${PI_NOTIFY_EXCLUDE_EVENTS:-}" # blacklist
PI_DEFAULT_EVENTS="agent_settled"          # default enabled events
PI_SHOW_TYPE="${PI_NOTIFY_SHOW_EVENT_TYPE:-1}" # show event type in title

# Parse event type
EVENT_NAME="$(jq -r '.event // empty' <<<"$payload" 2>/dev/null || true)"
EVENT_NAME="$(trim_ws "$EVENT_NAME")"

# Check if event is enabled
if ! is_event_enabled "$EVENT_NAME" "$PI_EVENTS" "$PI_EXCLUDE" "$PI_DEFAULT_EVENTS"; then
    log_debug "event not enabled: $EVENT_NAME"
    exit 0
fi

# Process event and determine title/message
TITLE_MSG=""
MESSAGE=""

case "$EVENT_NAME" in
    agent_settled)
        # Pi is fully idle: no auto-retry, compaction, or queued follow-up left.
        TITLE_MSG="Response Complete"
        MESSAGE="Click to jump to tmux pane"
        ;;
    agent_end)
        TITLE_MSG="Agent Run Ended"
        MESSAGE="Click to jump to tmux pane"
        ;;
    turn_end)
        TITLE_MSG="Turn Ended"
        MESSAGE="Click to jump to tmux pane"
        ;;
    *)
        # Generic handling for other events
        TITLE_MSG="$EVENT_NAME"
        MESSAGE="$(jq -r 'tostring' <<<"$payload" 2>/dev/null | head -c 200 || printf '%s' 'Event occurred')"
        ;;
esac

# Format title with optional event type
TITLE="$(format_notify_title "Pi" "$EVENT_NAME" "$TITLE_MSG" "$PI_SHOW_TYPE")"

ALLOW_FOCUS_FALLBACK="${PI_NOTIFY_FOCUS_ONLY_FALLBACK:-${TMUX_NOTIFY_FOCUS_ONLY_FALLBACK:-1}}"
ALLOW_FALLBACK="${PI_NOTIFY_FALLBACK_TARGET:-${TMUX_NOTIFY_FALLBACK_TARGET:-0}}"

# Timeout routing (optional):
# - Allow per-event timeout override
TIMEOUT_MS="$TIMEOUT_MS_BASE"
TIMEOUT_MS_SOURCE="default"

if [ -n "$EVENT_NAME" ] && [ -n "${PI_NOTIFY_TIMEOUT_MS_BY_EVENT:-}" ]; then
    TIMEOUT_MS_CANDIDATE="$(lookup_kv_map "$EVENT_NAME" "${PI_NOTIFY_TIMEOUT_MS_BY_EVENT:-}" 2>/dev/null || true)"
    if [ -n "$TIMEOUT_MS_CANDIDATE" ]; then
        if is_integer "$TIMEOUT_MS_CANDIDATE"; then
            TIMEOUT_MS="$TIMEOUT_MS_CANDIDATE"
            TIMEOUT_MS_SOURCE="event:$EVENT_NAME"
        else
            log_debug "invalid timeout for event '$EVENT_NAME': '$TIMEOUT_MS_CANDIDATE' (expected non-negative integer ms)"
        fi
    fi
fi

TARGET=""
if command -v tmux >/dev/null 2>&1; then
    if tmux_cmd list-sessions >/dev/null 2>&1; then
        TARGET="$(resolve_tmux_notify_target "$ALLOW_FALLBACK" 2>/dev/null || true)"
    else
        log_debug "tmux server not running"
    fi
else
    log_debug "tmux not installed"
fi

if tmux_notify_should_suppress_remote_client; then
    log_debug "suppressing notification for remote ssh tmux client"
    exit 0
fi

JUMP_SH="$(resolve_tmux_notify_jump_cmd "$SCRIPT_DIR")"
if ! is_executable_cmd "$JUMP_SH"; then
    log_debug "jump command not found/executable: $JUMP_SH"
    exit 0
fi

if [ -z "$TARGET" ] && [ "$MESSAGE" = "Click to jump to tmux pane" ]; then
    MESSAGE="Click to focus terminal"
fi

args=(
    --title "$TITLE"
    --body "$MESSAGE"
    --detach
    --timeout "$TIMEOUT_MS"
    --max-title "$MAX_TITLE"
    --max-body "$MAX_BODY"
)

# UI routing (optional):
# - Allow per-event UI override
# - Allow wrapper default UI override
UI_OVERRIDE=""
UI_OVERRIDE_SOURCE="none"

if [ -n "$EVENT_NAME" ] && [ -n "${PI_NOTIFY_UI_BY_EVENT:-}" ]; then
    UI_OVERRIDE="$(lookup_kv_map "$EVENT_NAME" "${PI_NOTIFY_UI_BY_EVENT:-}" 2>/dev/null || true)"
    if [ -n "$UI_OVERRIDE" ]; then
        if is_valid_ui "$UI_OVERRIDE"; then
            UI_OVERRIDE_SOURCE="event:$EVENT_NAME"
        else
            log_debug "invalid ui for event '$EVENT_NAME': '$UI_OVERRIDE' (expected notification|dialog)"
            UI_OVERRIDE=""
        fi
    fi
fi

if [ -z "$UI_OVERRIDE" ] && [ -n "${PI_NOTIFY_UI:-}" ]; then
    if is_valid_ui "${PI_NOTIFY_UI:-}"; then
        UI_OVERRIDE="${PI_NOTIFY_UI:-}"
        UI_OVERRIDE_SOURCE="default"
    else
        log_debug "invalid PI_NOTIFY_UI: '${PI_NOTIFY_UI:-}' (expected notification|dialog)"
    fi
fi

if [ -n "$TARGET" ]; then
    args=(--target "$TARGET" "${args[@]}")
elif is_truthy "$ALLOW_FOCUS_FALLBACK"; then
    args=(--focus-only "${args[@]}")
else
    log_debug "no tmux target and focus-only fallback disabled"
    exit 0
fi

if [ -n "$UI_OVERRIDE" ]; then
    args+=(--ui "$UI_OVERRIDE")
fi

if is_integer "${PPID:-}"; then
    args+=(--sender-pid "$PPID")
fi

if [ "${PI_NOTIFY_QUIET:-1}" = "1" ] && [ "${PI_NOTIFY_DEBUG:-0}" != "1" ]; then
    args+=(--quiet)
fi

if [ "${PI_NOTIFY_DEBUG:-0}" = "1" ]; then
    log_debug "jump_sh=$JUMP_SH"
    log_debug "event=$EVENT_NAME target=${TARGET:-} focus_only=$([ -z "$TARGET" ] && echo "1" || echo "0") timeout=$TIMEOUT_MS max_title=$MAX_TITLE max_body=$MAX_BODY"
    log_debug "timeout_source=$TIMEOUT_MS_SOURCE"
    log_debug "ui_override=${UI_OVERRIDE:-} ui_source=$UI_OVERRIDE_SOURCE"
    "$JUMP_SH" "${args[@]}" || log_debug "jump script exited non-zero"
else
    "$JUMP_SH" "${args[@]}" >/dev/null 2>&1 || true
fi
