#!/usr/bin/env bash
set -euo pipefail

# Codex notify hooks may run with a restricted environment (common under tmux / hook runners).
# Under `set -u`, `$PATH` may be unset, so avoid expanding it directly.
if [ -n "${PATH:-}" ]; then
    export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
else
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-notify-jump-lib.sh
. "$SCRIPT_DIR/tmux-notify-jump-lib.sh"

payload_arg="${1:-}"
if [ -z "$payload_arg" ]; then
    # Native lifecycle hooks send JSON on stdin; legacy notify uses argv.
    [ ! -t 0 ] || exit 0
    payload="$(cat)" || exit 0
elif [ -f "$payload_arg" ]; then
    payload="$(cat "$payload_arg")"
else
    payload="$payload_arg"
fi

load_user_config
ensure_tmux_notify_socket_from_env

log_debug() {
    [ "${CODEX_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local logfile="${CODEX_NOTIFY_DEBUG_LOG:-}"
    if [ -z "$logfile" ]; then
        local codex_home="${CODEX_HOME:-}"
        if [ -z "$codex_home" ] && [ -n "${HOME:-}" ]; then
            codex_home="$HOME/.codex"
        fi
        # Fail open: hooks may run without HOME; skip logging instead of crashing.
        [ -n "$codex_home" ] || return 0
        logfile="$codex_home/log/notify-codex.log"
    fi
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

MAX_TITLE="$(normalize_int "${CODEX_NOTIFY_MAX_TITLE:-${TMUX_NOTIFY_MAX_TITLE:-80}}" 80)"
MAX_BODY="$(normalize_int "${CODEX_NOTIFY_MAX_BODY:-${TMUX_NOTIFY_MAX_BODY:-200}}" 200)"
TIMEOUT_MS="$(normalize_int "${CODEX_NOTIFY_TIMEOUT_MS:-${TMUX_NOTIFY_TIMEOUT:-0}}" 0)"

# Event filtering is shared with diagnostics in the library.
CODEX_SHOW_TYPE="${CODEX_NOTIFY_SHOW_EVENT_TYPE:-1}"  # show event type in title

EVENT_TYPE="$(jq -r '(.hook_event_name // .type // empty) | select(type == "string")' <<<"$payload" 2>/dev/null || true)"
EVENT_TYPE="$(trim_ws "$EVENT_TYPE")"

# Check if event is enabled
if ! tmux_notify_codex_event_enabled "$EVENT_TYPE"; then
    log_debug "event not enabled: $EVENT_TYPE"
    exit 0
fi

# Extract title and message based on event type
case "$EVENT_TYPE" in
    PermissionRequest)
        # This event precedes automatic/user approval; it does not prove the
        # agent is blocked waiting for human input. Never return a decision.
        TITLE_MSG="$(jq -r '"Approval requested: " + ((.tool_name // "tool") | tostring)' <<<"$payload")"
        MESSAGE="$(jq -r '(.tool_input.command // .tool_input.description // .tool_input // "") | tostring' <<<"$payload" 2>/dev/null || true)"
        ;;
    Stop)
        TITLE_MSG="$(jq -r '.last_assistant_message // "Turn stopped" | tostring' <<<"$payload")"
        MESSAGE="$(jq -r '.cwd // "" | tostring' <<<"$payload")"
        ;;
    agent-turn-complete)
        TITLE_MSG="$(jq -r '."last-assistant-message" // "Turn Complete" | tostring' <<<"$payload" 2>/dev/null || printf '%s' 'Turn Complete')"
        MESSAGE="$(jq -r '
            (.["input-messages"] // []) as $m
            | if ($m|type)=="array" then
                $m
                | map(if type=="string" then . else (.content // .text // tostring) end)
                | join(" ")
              elif ($m|type)=="string" then
                $m
              else
                ($m|tostring)
              end
        ' <<<"$payload" 2>/dev/null || printf '%s' '')"
        ;;
    *)
        # Generic handling for unknown events
        TITLE_MSG="Event: $EVENT_TYPE"
        MESSAGE="$(jq -r 'tostring' <<<"$payload" 2>/dev/null | head -c 200 || printf '%s' '')"
        ;;
esac

NOTIFY_KIND="$(tmux_notify_event_kind codex "$EVENT_TYPE")"

# Format title with optional event type
TITLE="$(format_notify_title "Codex" "$EVENT_TYPE" "$TITLE_MSG" "$CODEX_SHOW_TYPE")"

ALLOW_FOCUS_FALLBACK="${CODEX_NOTIFY_FOCUS_ONLY_FALLBACK:-${TMUX_NOTIFY_FOCUS_ONLY_FALLBACK:-1}}"
ALLOW_FALLBACK="${CODEX_NOTIFY_FALLBACK_TARGET:-${TMUX_NOTIFY_FALLBACK_TARGET:-0}}"

TARGET=""
if command -v tmux >/dev/null 2>&1; then
    if tmux_cmd list-sessions >/dev/null 2>&1; then
        TARGET="$(resolve_tmux_notify_target "$ALLOW_FALLBACK" "${PPID:-}" 2>/dev/null || true)"
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
    --notify-kind "$NOTIFY_KIND"
    --notify-source "Codex"
)

if [ -n "$TARGET" ]; then
    args=(--target "$TARGET" "${args[@]}")
elif is_truthy "$ALLOW_FOCUS_FALLBACK"; then
    args=(--focus-only "${args[@]}")
else
    log_debug "no tmux target and focus-only fallback disabled"
    exit 0
fi

if is_integer "${PPID:-}"; then
    args+=(--sender-pid "$PPID")
fi

if [ "${CODEX_NOTIFY_QUIET:-1}" = "1" ] && [ "${CODEX_NOTIFY_DEBUG:-0}" != "1" ]; then
    args+=(--quiet)
fi

bell_arg="$(tmux_notify_agent_bell_arg CODEX)"
if [ -n "$bell_arg" ]; then
    args+=("$bell_arg")
fi

terminal_method="$(tmux_notify_agent_terminal_method CODEX)"
if [ -n "$terminal_method" ]; then
    args+=(--terminal-method "$terminal_method")
fi

if [ "${CODEX_NOTIFY_DEBUG:-0}" = "1" ]; then
    log_debug "jump_sh=$JUMP_SH"
    log_debug "target=${TARGET:-} focus_only=$([ -z "$TARGET" ] && echo "1" || echo "0") timeout=$TIMEOUT_MS max_title=$MAX_TITLE max_body=$MAX_BODY"
    # Hook stdout is reserved for Codex decisions/context, even in debug mode.
    "$JUMP_SH" "${args[@]}" >/dev/null || log_debug "jump script exited non-zero"
else
    "$JUMP_SH" "${args[@]}" >/dev/null 2>&1 || true
fi
