#!/usr/bin/env bash
set -euo pipefail

# OpenCode plugin integration for tmux-notify-jump
# Reads JSON from stdin (piped by the opencode-plugin/tmux-notify-jump.ts bridge)

# OpenCode hooks may run with a restricted environment (common under tmux / hook runners).
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
    [ "${OPENCODE_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local logfile="${OPENCODE_NOTIFY_DEBUG_LOG:-$HOME/.config/opencode/log/notify-opencode.log}"
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
    #   lookup_kv_map "session.idle" "session.idle:notification,permission.asked:dialog"
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

MAX_TITLE="$(normalize_int "${OPENCODE_NOTIFY_MAX_TITLE:-${TMUX_NOTIFY_MAX_TITLE:-80}}" 80)"
MAX_BODY="$(normalize_int "${OPENCODE_NOTIFY_MAX_BODY:-${TMUX_NOTIFY_MAX_BODY:-200}}" 200)"
TIMEOUT_MS_BASE="$(normalize_int "${OPENCODE_NOTIFY_TIMEOUT_MS:-${TMUX_NOTIFY_TIMEOUT:-0}}" 0)"

# Event filtering configuration
OPENCODE_EVENTS="${OPENCODE_NOTIFY_EVENTS:-}"          # whitelist (empty=default, *=all)
OPENCODE_EXCLUDE="${OPENCODE_NOTIFY_EXCLUDE_EVENTS:-}" # blacklist
OPENCODE_DEFAULT_EVENTS="session.idle,permission.asked"  # default enabled events
OPENCODE_SHOW_TYPE="${OPENCODE_NOTIFY_SHOW_EVENT_TYPE:-1}"  # show event type in title

# Parse event type
EVENT_TYPE="$(jq -r '.event_type // empty' <<<"$payload" 2>/dev/null || true)"
EVENT_TYPE="$(trim_ws "$EVENT_TYPE")"

# Check if event is enabled
if ! is_event_enabled "$EVENT_TYPE" "$OPENCODE_EVENTS" "$OPENCODE_EXCLUDE" "$OPENCODE_DEFAULT_EVENTS"; then
    log_debug "event not enabled: $EVENT_TYPE"
    exit 0
fi

# Process event and determine title/message
TITLE_MSG=""
MESSAGE=""

case "$EVENT_TYPE" in
    session.idle)
        TITLE_MSG="Session Idle"
        MESSAGE="$(jq -r '.message // empty' <<<"$payload" 2>/dev/null || true)"
        MESSAGE="${MESSAGE:-Waiting for input}"
        ;;
    permission.asked)
        TITLE_MSG="Permission Needed"
        MESSAGE="$(jq -r '.message // empty' <<<"$payload" 2>/dev/null || true)"
        MESSAGE="${MESSAGE:-Awaiting permission}"
        ;;
    session.error)
        TITLE_MSG="Session Error"
        MESSAGE="$(jq -r '.message // empty' <<<"$payload" 2>/dev/null || true)"
        MESSAGE="${MESSAGE:-An error occurred}"
        ;;
    session.created)
        TITLE_MSG="Session Started"
        SESSION_ID="$(jq -r '.properties.sessionID // empty' <<<"$payload" 2>/dev/null || true)"
        MESSAGE="${SESSION_ID:-New session started}"
        ;;
    session.deleted)
        TITLE_MSG="Session Ended"
        SESSION_ID="$(jq -r '.properties.sessionID // empty' <<<"$payload" 2>/dev/null || true)"
        MESSAGE="${SESSION_ID:-Session terminated}"
        ;;
    permission.replied)
        TITLE_MSG="Permission Replied"
        MESSAGE="Permission response sent"
        ;;
    tool.execute.after)
        TOOL_NAME="$(jq -r '.properties.name // "Unknown"' <<<"$payload" 2>/dev/null || printf '%s' 'Unknown')"
        TITLE_MSG="Tool Complete: $TOOL_NAME"
        MESSAGE="Tool execution finished"
        ;;
    *)
        # Generic handling for other events
        TITLE_MSG="$EVENT_TYPE"
        MESSAGE="$(jq -r 'tostring' <<<"$payload" 2>/dev/null | head -c 200 || printf '%s' 'Event occurred')"
        ;;
esac

# Format title with optional event type
TITLE="$(format_notify_title "OpenCode" "$EVENT_TYPE" "$TITLE_MSG" "$OPENCODE_SHOW_TYPE")"

ALLOW_FOCUS_FALLBACK="${OPENCODE_NOTIFY_FOCUS_ONLY_FALLBACK:-${TMUX_NOTIFY_FOCUS_ONLY_FALLBACK:-1}}"
ALLOW_FALLBACK="${OPENCODE_NOTIFY_FALLBACK_TARGET:-${TMUX_NOTIFY_FALLBACK_TARGET:-0}}"

# Timeout routing (optional):
# - Allow per-event_type timeout override
TIMEOUT_MS="$TIMEOUT_MS_BASE"
TIMEOUT_MS_SOURCE="default"

if [ "$TIMEOUT_MS_SOURCE" = "default" ] && [ -n "$EVENT_TYPE" ] && [ -n "${OPENCODE_NOTIFY_TIMEOUT_MS_BY_EVENT:-}" ]; then
    TIMEOUT_MS_CANDIDATE="$(lookup_kv_map "$EVENT_TYPE" "${OPENCODE_NOTIFY_TIMEOUT_MS_BY_EVENT:-}" 2>/dev/null || true)"
    if [ -n "$TIMEOUT_MS_CANDIDATE" ]; then
        if is_integer "$TIMEOUT_MS_CANDIDATE"; then
            TIMEOUT_MS="$TIMEOUT_MS_CANDIDATE"
            TIMEOUT_MS_SOURCE="event:$EVENT_TYPE"
        else
            log_debug "invalid timeout for event '$EVENT_TYPE': '$TIMEOUT_MS_CANDIDATE' (expected non-negative integer ms)"
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

JUMP_SH="$(resolve_tmux_notify_jump_cmd "$SCRIPT_DIR")"
if ! is_executable_cmd "$JUMP_SH"; then
    log_debug "jump command not found/executable: $JUMP_SH"
    exit 0
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
# - Allow per-event_type UI override
# - Allow wrapper default UI override
UI_OVERRIDE=""
UI_OVERRIDE_SOURCE="none"

if [ -n "$EVENT_TYPE" ] && [ -n "${OPENCODE_NOTIFY_UI_BY_EVENT:-}" ]; then
    UI_OVERRIDE="$(lookup_kv_map "$EVENT_TYPE" "${OPENCODE_NOTIFY_UI_BY_EVENT:-}" 2>/dev/null || true)"
    if [ -n "$UI_OVERRIDE" ]; then
        if is_valid_ui "$UI_OVERRIDE"; then
            UI_OVERRIDE_SOURCE="event:$EVENT_TYPE"
        else
            log_debug "invalid ui for event '$EVENT_TYPE': '$UI_OVERRIDE' (expected notification|dialog)"
            UI_OVERRIDE=""
        fi
    fi
fi

if [ -z "$UI_OVERRIDE" ] && [ -n "${OPENCODE_NOTIFY_UI:-}" ]; then
    if is_valid_ui "${OPENCODE_NOTIFY_UI:-}"; then
        UI_OVERRIDE="${OPENCODE_NOTIFY_UI:-}"
        UI_OVERRIDE_SOURCE="default"
    else
        log_debug "invalid OPENCODE_NOTIFY_UI: '${OPENCODE_NOTIFY_UI:-}' (expected notification|dialog)"
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

if [ "${OPENCODE_NOTIFY_QUIET:-1}" = "1" ] && [ "${OPENCODE_NOTIFY_DEBUG:-0}" != "1" ]; then
    args+=(--quiet)
fi

if [ "${OPENCODE_NOTIFY_DEBUG:-0}" = "1" ]; then
    log_debug "jump_sh=$JUMP_SH"
    log_debug "event=$EVENT_TYPE target=${TARGET:-} focus_only=$([ -z "$TARGET" ] && echo "1" || echo "0") timeout=$TIMEOUT_MS max_title=$MAX_TITLE max_body=$MAX_BODY"
    log_debug "timeout_source=$TIMEOUT_MS_SOURCE"
    log_debug "ui_override=${UI_OVERRIDE:-} ui_source=$UI_OVERRIDE_SOURCE"
    "$JUMP_SH" "${args[@]}" || log_debug "jump script exited non-zero"
else
    "$JUMP_SH" "${args[@]}" >/dev/null 2>&1 || true
fi
