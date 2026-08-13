#!/usr/bin/env bash
set -euo pipefail

# Grok Build hook integration for tmux-notify-jump. Reads JSON from stdin.
# Hook runners may provide a restricted PATH, especially under tmux on macOS.
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
    [ "${GROK_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local grok_home="${GROK_HOME:-$HOME/.grok}"
    local logfile="${GROK_NOTIFY_DEBUG_LOG:-$grok_home/logs/notify-grok.log}"
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

need jq

if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
    log_debug "invalid JSON payload; ignoring"
    exit 0
fi

MAX_TITLE="$(normalize_int "${GROK_NOTIFY_MAX_TITLE:-${TMUX_NOTIFY_MAX_TITLE:-80}}" 80)"
MAX_BODY="$(normalize_int "${GROK_NOTIFY_MAX_BODY:-${TMUX_NOTIFY_MAX_BODY:-200}}" 200)"
TIMEOUT_MS="$(normalize_int "${GROK_NOTIFY_TIMEOUT_MS:-${TMUX_NOTIFY_TIMEOUT:-0}}" 0)"

GROK_EVENTS="${GROK_NOTIFY_EVENTS:-}"
GROK_EXCLUDE="${GROK_NOTIFY_EXCLUDE_EVENTS:-}"
GROK_DEFAULT_EVENTS="stop,notification,post_tool_use_failure"
GROK_TYPES="${GROK_NOTIFY_TYPES:-}"
GROK_EXCLUDE_TYPES="${GROK_NOTIFY_EXCLUDE_TYPES:-}"
GROK_DEFAULT_TYPES="permission_prompt,idle_prompt"
GROK_SHOW_TYPE="${GROK_NOTIFY_SHOW_EVENT_TYPE:-1}"

EVENT_NAME="$(jq -r '.hookEventName // empty' <<<"$payload" 2>/dev/null || true)"
EVENT_NAME="$(trim_ws "$EVENT_NAME")"
if ! is_event_enabled "$EVENT_NAME" "$GROK_EVENTS" "$GROK_EXCLUDE" "$GROK_DEFAULT_EVENTS"; then
    log_debug "event not enabled: $EVENT_NAME"
    exit 0
fi

EVENT_LABEL="$EVENT_NAME"
TITLE_MSG=""
MESSAGE=""
NOTIF_TYPE=""

case "$EVENT_NAME" in
    stop)
        STOP_REASON="$(jq -r '.reason // empty' <<<"$payload" 2>/dev/null || true)"
        if [ "$STOP_REASON" != "end_turn" ]; then
            log_debug "ignoring non-turn stop: ${STOP_REASON:-missing reason}"
            exit 0
        fi
        TITLE_MSG="Response Complete"
        MESSAGE="Click to jump to tmux pane"
        ;;
    notification)
        NOTIF_TYPE="$(jq -r '.notificationType // empty' <<<"$payload" 2>/dev/null || true)"
        NOTIF_TYPE="$(trim_ws "$NOTIF_TYPE")"
        if ! is_event_enabled "$NOTIF_TYPE" "$GROK_TYPES" "$GROK_EXCLUDE_TYPES" "$GROK_DEFAULT_TYPES"; then
            log_debug "notification type not enabled: $NOTIF_TYPE"
            exit 0
        fi

        EVENT_LABEL="${NOTIF_TYPE:-notification}"
        NOTIF_MESSAGE="$(jq -r '.message // .body // empty' <<<"$payload" 2>/dev/null || true)"
        case "$NOTIF_TYPE" in
            permission_prompt)
                TITLE_MSG="Permission Needed"
                MESSAGE="${NOTIF_MESSAGE:-Awaiting permission}"
                ;;
            idle_prompt)
                TITLE_MSG="Waiting for Input"
                MESSAGE="${NOTIF_MESSAGE:-Waiting for input}"
                ;;
            *)
                TITLE_MSG="Notification"
                MESSAGE="${NOTIF_MESSAGE:-$NOTIF_TYPE}"
                ;;
        esac
        ;;
    post_tool_use_failure)
        TOOL_NAME="$(jq -r '.toolName // "Unknown"' <<<"$payload" 2>/dev/null || printf '%s' 'Unknown')"
        ERROR_MSG="$(jq -r '.error // .errorDetails // "Tool execution failed"' <<<"$payload" 2>/dev/null || printf '%s' 'Tool execution failed')"
        TITLE_MSG="$TOOL_NAME failed"
        MESSAGE="$ERROR_MSG"
        ;;
    *)
        TITLE_MSG="$EVENT_NAME"
        MESSAGE="$(jq -r 'tostring | .[:200]' <<<"$payload" 2>/dev/null || printf '%s' 'Event occurred')"
        ;;
esac

TITLE="$(format_notify_title "Grok" "$EVENT_LABEL" "$TITLE_MSG" "$GROK_SHOW_TYPE")"
ALLOW_FOCUS_FALLBACK="${GROK_NOTIFY_FOCUS_ONLY_FALLBACK:-${TMUX_NOTIFY_FOCUS_ONLY_FALLBACK:-1}}"
ALLOW_FALLBACK="${GROK_NOTIFY_FALLBACK_TARGET:-${TMUX_NOTIFY_FALLBACK_TARGET:-0}}"

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

if [ -n "${GROK_NOTIFY_UI:-}" ]; then
    if is_valid_ui "$GROK_NOTIFY_UI"; then
        args+=(--ui "$GROK_NOTIFY_UI")
    else
        log_debug "invalid GROK_NOTIFY_UI: '$GROK_NOTIFY_UI'"
    fi
fi
if is_integer "${PPID:-}"; then
    args+=(--sender-pid "$PPID")
fi
if [ "${GROK_NOTIFY_QUIET:-1}" = "1" ] && [ "${GROK_NOTIFY_DEBUG:-0}" != "1" ]; then
    args+=(--quiet)
fi

if [ "${GROK_NOTIFY_DEBUG:-0}" = "1" ]; then
    log_debug "jump_sh=$JUMP_SH"
    log_debug "event=$EVENT_NAME label=$EVENT_LABEL target=${TARGET:-} timeout=$TIMEOUT_MS"
    "$JUMP_SH" "${args[@]}" || log_debug "jump script exited non-zero"
else
    "$JUMP_SH" "${args[@]}" >/dev/null 2>&1 || true
fi
