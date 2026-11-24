#!/usr/bin/env bash
set -euo pipefail

# Copilot parses hook stdout as control output. Keep diagnostics in the log.
exec >/dev/null 2>&1
export PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-notify-jump-lib.sh
. "$SCRIPT_DIR/tmux-notify-jump-lib.sh"

EVENT_NAME="${1:-}"
payload="$(cat)" || exit 0
[ -n "$payload" ] || exit 0
load_user_config || exit 0

log_debug() {
    [ "${COPILOT_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local logfile="${COPILOT_NOTIFY_DEBUG_LOG:-}" copilot_home="${COPILOT_HOME:-}"
    if [ -z "$logfile" ]; then
        if [ -z "$copilot_home" ]; then
            [ -n "${HOME:-}" ] || return 0
            copilot_home="$HOME/.copilot"
        fi
        logfile="$copilot_home/logs/notify-copilot.log"
    fi
    mkdir -p "$(dirname "$logfile")" || return 0
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$logfile" || true
}

if ! command -v jq >/dev/null; then
    log_debug 'missing dependency: jq'
    exit 0
fi

if ! is_event_enabled "$EVENT_NAME" "${COPILOT_NOTIFY_EVENTS:-}" \
    "${COPILOT_NOTIFY_EXCLUDE_EVENTS:-}" 'agentStop,notification'; then
    log_debug "event not enabled: $EVENT_NAME"
    exit 0
fi

EVENT_LABEL="$EVENT_NAME"
NOTIF_TYPE=""
MESSAGE=""
case "$EVENT_NAME" in
    agentStop)
        # The camelCase payload has no event name. The hook command supplies it.
        if ! jq -es 'select(length == 1) | .[0] | objects |
            .stopReason == "end_turn" and .agentId == null' >/dev/null <<<"$payload"; then
            log_debug 'ignoring invalid or non-root end-of-turn payload'
            exit 0
        fi
        TITLE_MSG='Agent Turn Stopping'
        ;;
    notification)
        if ! fields="$(jq -ers 'select(length == 1) | .[0] | objects |
            select(.hook_event_name == "Notification") |
            select(.notification_type == "permission_prompt" or
                   .notification_type == "elicitation_dialog") |
            .notification_type, (.message | strings // "" | gsub("\u0000"; ""))' <<<"$payload")"; then
            log_debug 'ignoring invalid notification payload'
            exit 0
        fi
        NOTIF_TYPE="${fields%%$'\n'*}"
        if [[ "$fields" == *$'\n'* ]]; then
            MESSAGE="${fields#*$'\n'}"
        fi
        case "$NOTIF_TYPE" in
            permission_prompt) TITLE_MSG='Permission Needed' ;;
            elicitation_dialog) TITLE_MSG='Input Needed' ;;
            *)
                TITLE_MSG="$(jq -r '.title // empty' <<<"$payload")"
                TITLE_MSG="${TITLE_MSG:-Notification}"
                ;;
        esac
        EVENT_LABEL="$NOTIF_TYPE"
        ;;
    *) exit 0 ;;
esac

JUMP_SH="$(resolve_tmux_notify_jump_cmd "$SCRIPT_DIR")"
if ! is_executable_cmd "$JUMP_SH"; then
    log_debug "jump command not found/executable: $JUMP_SH"
    exit 0
fi

ensure_tmux_notify_socket_from_env
TARGET=""
if command -v tmux >/dev/null && tmux_cmd list-sessions; then
    TARGET="$(resolve_tmux_notify_target \
        "${COPILOT_NOTIFY_FALLBACK_TARGET:-${TMUX_NOTIFY_FALLBACK_TARGET:-0}}" \
        "${PPID:-}" 2>/dev/null || true)"
fi

if [ -n "$TARGET" ]; then
    args=(--target "$TARGET")
    MESSAGE="${MESSAGE:-Click to jump to tmux pane}"
elif is_truthy "${COPILOT_NOTIFY_FOCUS_ONLY_FALLBACK:-${TMUX_NOTIFY_FOCUS_ONLY_FALLBACK:-1}}"; then
    args=(--focus-only)
    MESSAGE="${MESSAGE:-Click to focus terminal}"
else
    log_debug 'no tmux target and focus-only fallback disabled'
    exit 0
fi

args+=(
    --title "$(format_notify_title 'Copilot' "$EVENT_LABEL" "$TITLE_MSG" "${COPILOT_NOTIFY_SHOW_EVENT_TYPE:-1}")"
    --body "$MESSAGE"
    --detach --quiet
    --timeout "$(normalize_int "${COPILOT_NOTIFY_TIMEOUT_MS:-${TMUX_NOTIFY_TIMEOUT:-0}}" 0)"
    --max-title "$(normalize_int "${COPILOT_NOTIFY_MAX_TITLE:-${TMUX_NOTIFY_MAX_TITLE:-80}}" 80)"
    --max-body "$(normalize_int "${COPILOT_NOTIFY_MAX_BODY:-${TMUX_NOTIFY_MAX_BODY:-200}}" 200)"
    --notify-kind "$(tmux_notify_event_kind copilot "$EVENT_NAME" "$NOTIF_TYPE")"
    --notify-source 'Copilot'
)

case "${COPILOT_NOTIFY_UI:-}" in
    notification|dialog) args+=(--ui "$COPILOT_NOTIFY_UI") ;;
    '') ;;
    *) log_debug 'ignoring invalid COPILOT_NOTIFY_UI' ;;
esac
if is_integer "${PPID:-}"; then
    args+=(--sender-pid "$PPID")
fi
bell_arg="$(tmux_notify_agent_bell_arg COPILOT)"
if [ -n "$bell_arg" ]; then
    args+=("$bell_arg")
fi
terminal_method="$(tmux_notify_agent_terminal_method COPILOT)"
if [ -n "$terminal_method" ]; then
    args+=(--terminal-method "$terminal_method")
fi

log_debug "event=$EVENT_NAME type=$NOTIF_TYPE target=$TARGET"
"$JUMP_SH" "${args[@]}" || log_debug 'jump script exited non-zero'
