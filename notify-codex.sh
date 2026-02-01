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
[ -n "$payload_arg" ] || exit 0

if [ -f "$payload_arg" ]; then
    payload="$(cat "$payload_arg")"
else
    payload="$payload_arg"
fi

load_user_config
ensure_tmux_notify_socket_from_env

log_debug() {
    [ "${CODEX_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local logfile="${CODEX_NOTIFY_DEBUG_LOG:-$HOME/.codex/log/notify-codex.log}"
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

# Event filtering configuration
CODEX_EVENTS="${CODEX_NOTIFY_EVENTS:-}"          # whitelist (empty=default, *=all)
CODEX_EXCLUDE="${CODEX_NOTIFY_EXCLUDE_EVENTS:-}" # blacklist
CODEX_DEFAULT_EVENTS="agent-turn-complete"       # default enabled events
CODEX_SHOW_TYPE="${CODEX_NOTIFY_SHOW_EVENT_TYPE:-1}"  # show event type in title

EVENT_TYPE="$(jq -r '.type // empty' <<<"$payload" 2>/dev/null || true)"
EVENT_TYPE="$(trim_ws "$EVENT_TYPE")"

# Check if event is enabled
if ! is_event_enabled "$EVENT_TYPE" "$CODEX_EVENTS" "$CODEX_EXCLUDE" "$CODEX_DEFAULT_EVENTS"; then
    log_debug "event not enabled: $EVENT_TYPE"
    exit 0
fi

# Extract title and message based on event type
case "$EVENT_TYPE" in
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

# Format title with optional event type
TITLE="$(format_notify_title "Codex" "$EVENT_TYPE" "$TITLE_MSG" "$CODEX_SHOW_TYPE")"

ALLOW_FOCUS_FALLBACK="${CODEX_NOTIFY_FOCUS_ONLY_FALLBACK:-${TMUX_NOTIFY_FOCUS_ONLY_FALLBACK:-1}}"
ALLOW_FALLBACK="${CODEX_NOTIFY_FALLBACK_TARGET:-${TMUX_NOTIFY_FALLBACK_TARGET:-0}}"

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

if [ "${CODEX_NOTIFY_DEBUG:-0}" = "1" ]; then
    log_debug "jump_sh=$JUMP_SH"
    log_debug "target=${TARGET:-} focus_only=$([ -z "$TARGET" ] && echo "1" || echo "0") timeout=$TIMEOUT_MS max_title=$MAX_TITLE max_body=$MAX_BODY"
    "$JUMP_SH" "${args[@]}" || log_debug "jump script exited non-zero"
else
    "$JUMP_SH" "${args[@]}" >/dev/null 2>&1 || true
fi
