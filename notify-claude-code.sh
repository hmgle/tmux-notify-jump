#!/usr/bin/env bash
set -euo pipefail

# Claude Code hook integration for tmux-notify-jump
# Reads JSON from stdin (unlike Codex which uses $1)

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
need tmux

MAX_TITLE="$(normalize_int "${CLAUDE_NOTIFY_MAX_TITLE:-${TMUX_NOTIFY_MAX_TITLE:-80}}" 80)"
MAX_BODY="$(normalize_int "${CLAUDE_NOTIFY_MAX_BODY:-${TMUX_NOTIFY_MAX_BODY:-200}}" 200)"
TIMEOUT_MS="$(normalize_int "${CLAUDE_NOTIFY_TIMEOUT_MS:-${TMUX_NOTIFY_TIMEOUT:-0}}" 0)"

# Parse event type
EVENT_NAME="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null || true)"

case "$EVENT_NAME" in
    Stop)
        TITLE="Claude: Response Complete"
        MESSAGE="Click to jump to tmux pane"
        ;;
    Notification)
        NOTIF_TYPE="$(jq -r '.notification_type // empty' <<<"$payload" 2>/dev/null || true)"
        NOTIF_MESSAGE="$(jq -r '.message // empty' <<<"$payload" 2>/dev/null || true)"
        case "$NOTIF_TYPE" in
            permission_prompt)
                TITLE="Claude: Permission Needed"
                MESSAGE="${NOTIF_MESSAGE:-Awaiting permission}"
                ;;
            idle_prompt)
                TITLE="Claude: Waiting for Input"
                MESSAGE="${NOTIF_MESSAGE:-Waiting for input}"
                ;;
            *)
                log_debug "unknown notification_type: $NOTIF_TYPE"
                exit 0
                ;;
        esac
        ;;
    *)
        log_debug "ignoring event: $EVENT_NAME"
        exit 0
        ;;
esac

if ! tmux_cmd list-sessions >/dev/null 2>&1; then
    log_debug "tmux server not running"
    exit 0
fi

ALLOW_FALLBACK="${CLAUDE_NOTIFY_FALLBACK_TARGET:-${TMUX_NOTIFY_FALLBACK_TARGET:-0}}"
TARGET="$(resolve_tmux_notify_target "$ALLOW_FALLBACK" 2>/dev/null || true)"

if [ -z "$TARGET" ]; then
    log_debug "no TMUX_PANE/TMUX context; cannot determine target"
    exit 0
fi

JUMP_SH="$(resolve_tmux_notify_jump_cmd "$SCRIPT_DIR")"
if ! is_executable_cmd "$JUMP_SH"; then
    log_debug "jump command not found/executable: $JUMP_SH"
    exit 0
fi

args=(
    --target "$TARGET"
    --title "$TITLE"
    --body "$MESSAGE"
    --detach
    --timeout "$TIMEOUT_MS"
    --max-title "$MAX_TITLE"
    --max-body "$MAX_BODY"
)

if [ "${CLAUDE_NOTIFY_QUIET:-1}" = "1" ]; then
    args+=(--quiet)
fi

if [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ]; then
    log_debug "event=$EVENT_NAME target=$TARGET timeout=$TIMEOUT_MS max_title=$MAX_TITLE max_body=$MAX_BODY"
    "$JUMP_SH" "${args[@]}" || log_debug "jump script exited non-zero"
else
    "$JUMP_SH" "${args[@]}" >/dev/null 2>&1 || true
fi
