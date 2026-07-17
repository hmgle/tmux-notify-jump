#!/usr/bin/env bash
set -euo pipefail

# Kimi Code CLI hook integration for tmux-notify-jump. Reads JSON from stdin.
# Hook runners may provide a restricted PATH, especially under tmux on macOS.
# Under `set -u`, PATH may also be unset, so avoid expanding it unconditionally.
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
    [ "${KIMI_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local kimi_home="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
    local logfile="${KIMI_NOTIFY_DEBUG_LOG:-$kimi_home/logs/notify-kimi-code.log}"
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$logfile" 2>/dev/null || true
}

need() {
    if command -v "$1" >/dev/null 2>&1; then
        return 0
    fi
    log_debug "missing dependency: $1"
    exit 0
}

is_valid_ui() {
    local ui="${1:-}"
    [ "$ui" = "notification" ] || [ "$ui" = "dialog" ]
}

lookup_kv_map() {
    # Look up a key in a comma-separated key:value map.
    # Example: task.completed:notification,task.failed:dialog
    local key="${1:-}"
    local map="${2:-}"
    [ -n "$key" ] || return 1
    [ -n "$map" ] || return 1

    local entry=""
    local map_key=""
    local value=""
    local IFS=","
    for entry in $map; do
        entry="$(trim_ws "$entry")"
        case "$entry" in
            *:*)
                map_key="$(trim_ws "${entry%%:*}")"
                value="$(trim_ws "${entry#*:}")"
                ;;
            *)
                continue
                ;;
        esac
        if [ "$map_key" = "$key" ]; then
            printf '%s' "$value"
            return 0
        fi
    done
    return 1
}

need jq

if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
    log_debug "invalid JSON payload; ignoring"
    exit 0
fi

MAX_TITLE="$(normalize_int "${KIMI_NOTIFY_MAX_TITLE:-${TMUX_NOTIFY_MAX_TITLE:-80}}" 80)"
MAX_BODY="$(normalize_int "${KIMI_NOTIFY_MAX_BODY:-${TMUX_NOTIFY_MAX_BODY:-200}}" 200)"
TIMEOUT_MS_BASE="$(normalize_int "${KIMI_NOTIFY_TIMEOUT_MS:-${TMUX_NOTIFY_TIMEOUT:-0}}" 0)"

KIMI_EVENTS="${KIMI_NOTIFY_EVENTS:-}"
KIMI_EXCLUDE="${KIMI_NOTIFY_EXCLUDE_EVENTS:-}"
KIMI_DEFAULT_EVENTS="Stop,PermissionRequest,StopFailure,Notification"
KIMI_TYPES="${KIMI_NOTIFY_TYPES:-}"
KIMI_EXCLUDE_TYPES="${KIMI_NOTIFY_EXCLUDE_TYPES:-}"
KIMI_DEFAULT_TYPES="*"
KIMI_SHOW_TYPE="${KIMI_NOTIFY_SHOW_EVENT_TYPE:-1}"

EVENT_NAME="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null || true)"
EVENT_NAME="$(trim_ws "$EVENT_NAME")"
if ! is_event_enabled "$EVENT_NAME" "$KIMI_EVENTS" "$KIMI_EXCLUDE" "$KIMI_DEFAULT_EVENTS"; then
    log_debug "event not enabled: $EVENT_NAME"
    exit 0
fi

EVENT_LABEL="$EVENT_NAME"
TITLE_MSG=""
MESSAGE=""
NOTIF_TYPE=""

case "$EVENT_NAME" in
    Stop)
        TITLE_MSG="Response Complete"
        MESSAGE="Click to jump to tmux pane"
        ;;
    PermissionRequest)
        TOOL_NAME="$(jq -r '.tool_name // "Unknown tool"' <<<"$payload" 2>/dev/null || printf '%s' 'Unknown tool')"
        ACTION="$(jq -r '.action // empty' <<<"$payload" 2>/dev/null || true)"
        TITLE_MSG="Permission Needed"
        MESSAGE="${ACTION:-Awaiting approval for $TOOL_NAME}"
        ;;
    StopFailure)
        ERROR_TYPE="$(jq -r '.error_type // "Error"' <<<"$payload" 2>/dev/null || printf '%s' 'Error')"
        ERROR_MESSAGE="$(jq -r '.error_message // empty' <<<"$payload" 2>/dev/null || true)"
        TITLE_MSG="Turn Failed"
        MESSAGE="${ERROR_MESSAGE:-$ERROR_TYPE}"
        ;;
    Notification)
        NOTIF_TYPE="$(jq -r '.notification_type // empty' <<<"$payload" 2>/dev/null || true)"
        NOTIF_TYPE="$(trim_ws "$NOTIF_TYPE")"
        if ! is_event_enabled "$NOTIF_TYPE" "$KIMI_TYPES" "$KIMI_EXCLUDE_TYPES" "$KIMI_DEFAULT_TYPES"; then
            log_debug "notification type not enabled: $NOTIF_TYPE"
            exit 0
        fi
        EVENT_LABEL="${NOTIF_TYPE:-Notification}"
        TITLE_MSG="$(jq -r '.title // "Background Task Update"' <<<"$payload" 2>/dev/null || printf '%s' 'Background Task Update')"
        MESSAGE="$(jq -r '.body // .message // .notification_type // "Background task updated"' <<<"$payload" 2>/dev/null || printf '%s' 'Background task updated')"
        ;;
    *)
        TITLE_MSG="$EVENT_NAME"
        MESSAGE="$(jq -r 'tostring | .[:200]' <<<"$payload" 2>/dev/null || printf '%s' 'Event occurred')"
        ;;
esac

TITLE="$(format_notify_title "Kimi" "$EVENT_LABEL" "$TITLE_MSG" "$KIMI_SHOW_TYPE")"
ALLOW_FOCUS_FALLBACK="${KIMI_NOTIFY_FOCUS_ONLY_FALLBACK:-${TMUX_NOTIFY_FOCUS_ONLY_FALLBACK:-1}}"
ALLOW_FALLBACK="${KIMI_NOTIFY_FALLBACK_TARGET:-${TMUX_NOTIFY_FALLBACK_TARGET:-0}}"

TIMEOUT_MS="$TIMEOUT_MS_BASE"
TIMEOUT_MS_SOURCE="default"
if [ "$EVENT_NAME" = "Notification" ] && [ -n "$NOTIF_TYPE" ]; then
    candidate="$(lookup_kv_map "$NOTIF_TYPE" "${KIMI_NOTIFY_TIMEOUT_MS_BY_TYPE:-}" 2>/dev/null || true)"
    if [ -n "$candidate" ]; then
        if is_integer "$candidate"; then
            TIMEOUT_MS="$candidate"
            TIMEOUT_MS_SOURCE="type:$NOTIF_TYPE"
        else
            log_debug "invalid timeout for type '$NOTIF_TYPE': '$candidate'"
        fi
    fi
fi
if [ "$TIMEOUT_MS_SOURCE" = "default" ]; then
    candidate="$(lookup_kv_map "$EVENT_NAME" "${KIMI_NOTIFY_TIMEOUT_MS_BY_EVENT:-}" 2>/dev/null || true)"
    if [ -n "$candidate" ]; then
        if is_integer "$candidate"; then
            TIMEOUT_MS="$candidate"
            TIMEOUT_MS_SOURCE="event:$EVENT_NAME"
        else
            log_debug "invalid timeout for event '$EVENT_NAME': '$candidate'"
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

args=(
    --title "$TITLE"
    --body "$MESSAGE"
    --detach
    --timeout "$TIMEOUT_MS"
    --max-title "$MAX_TITLE"
    --max-body "$MAX_BODY"
)

UI_OVERRIDE=""
UI_OVERRIDE_SOURCE="none"
if [ "$EVENT_NAME" = "Notification" ] && [ -n "$NOTIF_TYPE" ]; then
    candidate="$(lookup_kv_map "$NOTIF_TYPE" "${KIMI_NOTIFY_UI_BY_TYPE:-}" 2>/dev/null || true)"
    if [ -n "$candidate" ]; then
        if is_valid_ui "$candidate"; then
            UI_OVERRIDE="$candidate"
            UI_OVERRIDE_SOURCE="type:$NOTIF_TYPE"
        else
            log_debug "invalid ui for type '$NOTIF_TYPE': '$candidate'"
        fi
    fi
fi
if [ -z "$UI_OVERRIDE" ]; then
    candidate="$(lookup_kv_map "$EVENT_NAME" "${KIMI_NOTIFY_UI_BY_EVENT:-}" 2>/dev/null || true)"
    if [ -n "$candidate" ]; then
        if is_valid_ui "$candidate"; then
            UI_OVERRIDE="$candidate"
            UI_OVERRIDE_SOURCE="event:$EVENT_NAME"
        else
            log_debug "invalid ui for event '$EVENT_NAME': '$candidate'"
        fi
    fi
fi
if [ -z "$UI_OVERRIDE" ] && [ -n "${KIMI_NOTIFY_UI:-}" ]; then
    if is_valid_ui "$KIMI_NOTIFY_UI"; then
        UI_OVERRIDE="$KIMI_NOTIFY_UI"
        UI_OVERRIDE_SOURCE="default"
    else
        log_debug "invalid KIMI_NOTIFY_UI: '$KIMI_NOTIFY_UI'"
    fi
fi

if [ -n "$TARGET" ]; then
    args=(--target "$TARGET" "${args[@]}")
elif is_truthy "$ALLOW_FOCUS_FALLBACK"; then
    if [ "$MESSAGE" = "Click to jump to tmux pane" ]; then
        MESSAGE="Click to focus terminal"
        args=(
            --title "$TITLE"
            --body "$MESSAGE"
            --detach
            --timeout "$TIMEOUT_MS"
            --max-title "$MAX_TITLE"
            --max-body "$MAX_BODY"
        )
    fi
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
if [ "${KIMI_NOTIFY_QUIET:-1}" = "1" ] && [ "${KIMI_NOTIFY_DEBUG:-0}" != "1" ]; then
    args+=(--quiet)
fi

if [ "${KIMI_NOTIFY_DEBUG:-0}" = "1" ]; then
    log_debug "jump_sh=$JUMP_SH"
    log_debug "event=$EVENT_NAME label=$EVENT_LABEL target=${TARGET:-} timeout=$TIMEOUT_MS timeout_source=$TIMEOUT_MS_SOURCE"
    log_debug "ui_override=${UI_OVERRIDE:-} ui_source=$UI_OVERRIDE_SOURCE"
    "$JUMP_SH" "${args[@]}" || log_debug "jump script exited non-zero"
else
    "$JUMP_SH" "${args[@]}" >/dev/null 2>&1 || true
fi
