#!/usr/bin/env bash
set -euo pipefail

# Claude Code hook integration for tmux-notify-jump
# Reads JSON from stdin (unlike Codex which uses $1)

# Claude hooks may run with a restricted environment (common under tmux / hook runners).
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
    [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local logfile="${CLAUDE_NOTIFY_DEBUG_LOG:-$HOME/.claude/log/notify-claude-code.log}"
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

need jq

if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
    log_debug "invalid JSON payload; ignoring"
    exit 0
fi

MAX_TITLE="$(normalize_int "${CLAUDE_NOTIFY_MAX_TITLE:-${TMUX_NOTIFY_MAX_TITLE:-80}}" 80)"
MAX_BODY="$(normalize_int "${CLAUDE_NOTIFY_MAX_BODY:-${TMUX_NOTIFY_MAX_BODY:-200}}" 200)"
TIMEOUT_MS="$(normalize_int "${CLAUDE_NOTIFY_TIMEOUT_MS:-${TMUX_NOTIFY_TIMEOUT:-0}}" 0)"

# Event filtering configuration
CLAUDE_EVENTS="${CLAUDE_NOTIFY_EVENTS:-}"          # whitelist (empty=default, *=all)
CLAUDE_EXCLUDE="${CLAUDE_NOTIFY_EXCLUDE_EVENTS:-}" # blacklist
CLAUDE_DEFAULT_EVENTS="Stop,Notification,PostToolUseFailure"  # default enabled events
CLAUDE_SHOW_TYPE="${CLAUDE_NOTIFY_SHOW_EVENT_TYPE:-1}"  # show event type in title

# Notification subtype filtering
CLAUDE_TYPES="${CLAUDE_NOTIFY_TYPES:-}"            # notification subtype whitelist
CLAUDE_EXCLUDE_TYPES="${CLAUDE_NOTIFY_EXCLUDE_TYPES:-}" # notification subtype blacklist
CLAUDE_DEFAULT_TYPES="permission_prompt,idle_prompt"  # default notification types

# Parse event type
EVENT_NAME="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null || true)"
EVENT_NAME="$(trim_ws "$EVENT_NAME")"

# Check if event is enabled
if ! is_event_enabled "$EVENT_NAME" "$CLAUDE_EVENTS" "$CLAUDE_EXCLUDE" "$CLAUDE_DEFAULT_EVENTS"; then
    log_debug "event not enabled: $EVENT_NAME"
    exit 0
fi

# Process event and determine title/message
TITLE_MSG=""
MESSAGE=""
EVENT_LABEL=""  # Label for the event type in title

case "$EVENT_NAME" in
    Stop)
        EVENT_LABEL="Stop"
        TITLE_MSG="Response Complete"
        MESSAGE="Click to jump to tmux pane"
        ;;
    Notification)
        NOTIF_TYPE="$(jq -r '.notification_type // empty' <<<"$payload" 2>/dev/null || true)"
        NOTIF_MESSAGE="$(jq -r '.message // empty' <<<"$payload" 2>/dev/null || true)"
        NOTIF_TYPE="$(trim_ws "$NOTIF_TYPE")"

        # Check if notification subtype is enabled
        if ! is_event_enabled "$NOTIF_TYPE" "$CLAUDE_TYPES" "$CLAUDE_EXCLUDE_TYPES" "$CLAUDE_DEFAULT_TYPES"; then
            log_debug "notification type not enabled: $NOTIF_TYPE"
            exit 0
        fi

        EVENT_LABEL="${NOTIF_TYPE:-Notification}"
        case "$NOTIF_TYPE" in
            permission_prompt)
                TITLE_MSG="Permission Needed"
                MESSAGE="${NOTIF_MESSAGE:-Awaiting permission}"
                ;;
            idle_prompt)
                TITLE_MSG="Waiting for Input"
                MESSAGE="${NOTIF_MESSAGE:-Waiting for input}"
                ;;
            auth_success)
                TITLE_MSG="Authentication Successful"
                MESSAGE="${NOTIF_MESSAGE:-Authentication completed}"
                ;;
            elicitation_dialog)
                TITLE_MSG="Dialog Prompt"
                MESSAGE="${NOTIF_MESSAGE:-Awaiting dialog response}"
                ;;
            *)
                TITLE_MSG="Notification"
                MESSAGE="${NOTIF_MESSAGE:-$NOTIF_TYPE}"
                ;;
        esac
        ;;
    PostToolUseFailure)
        EVENT_LABEL="PostToolUseFailure"
        TOOL_NAME="$(jq -r '.tool_name // "Unknown"' <<<"$payload" 2>/dev/null || printf '%s' 'Unknown')"
        ERROR_MSG="$(jq -r '.error // "Tool execution failed"' <<<"$payload" 2>/dev/null || printf '%s' 'Tool execution failed')"
        TITLE_MSG="$TOOL_NAME failed"
        MESSAGE="$ERROR_MSG"
        ;;
    SessionStart)
        EVENT_LABEL="SessionStart"
        SESSION_ID="$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)"
        TITLE_MSG="Session Started"
        MESSAGE="${SESSION_ID:-New session started}"
        ;;
    SessionEnd)
        EVENT_LABEL="SessionEnd"
        SESSION_ID="$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)"
        TITLE_MSG="Session Ended"
        MESSAGE="${SESSION_ID:-Session terminated}"
        ;;
    *)
        # Generic handling for other events
        EVENT_LABEL="$EVENT_NAME"
        TITLE_MSG="$EVENT_NAME"
        MESSAGE="$(jq -r 'tostring' <<<"$payload" 2>/dev/null | head -c 200 || printf '%s' 'Event occurred')"
        ;;
esac

# Format title with optional event type
TITLE="$(format_notify_title "Claude" "$EVENT_LABEL" "$TITLE_MSG" "$CLAUDE_SHOW_TYPE")"

ALLOW_FOCUS_FALLBACK="${CLAUDE_NOTIFY_FOCUS_ONLY_FALLBACK:-${TMUX_NOTIFY_FOCUS_ONLY_FALLBACK:-1}}"
ALLOW_FALLBACK="${CLAUDE_NOTIFY_FALLBACK_TARGET:-${TMUX_NOTIFY_FALLBACK_TARGET:-0}}"

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

if is_integer "${PPID:-}"; then
    args+=(--sender-pid "$PPID")
fi

if [ "${CLAUDE_NOTIFY_QUIET:-1}" = "1" ] && [ "${CLAUDE_NOTIFY_DEBUG:-0}" != "1" ]; then
    args+=(--quiet)
fi

if [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ]; then
    log_debug "jump_sh=$JUMP_SH"
    log_debug "event=$EVENT_NAME label=$EVENT_LABEL target=${TARGET:-} focus_only=$([ -z "$TARGET" ] && echo "1" || echo "0") timeout=$TIMEOUT_MS max_title=$MAX_TITLE max_body=$MAX_BODY"
    "$JUMP_SH" "${args[@]}" || log_debug "jump script exited non-zero"
else
    "$JUMP_SH" "${args[@]}" >/dev/null 2>&1 || true
fi
