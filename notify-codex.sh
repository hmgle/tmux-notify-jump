#!/usr/bin/env bash
set -euo pipefail

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
need tmux

MAX_TITLE="$(normalize_int "${CODEX_NOTIFY_MAX_TITLE:-${TMUX_NOTIFY_MAX_TITLE:-80}}" 80)"
MAX_BODY="$(normalize_int "${CODEX_NOTIFY_MAX_BODY:-${TMUX_NOTIFY_MAX_BODY:-200}}" 200)"
TIMEOUT_MS="$(normalize_int "${CODEX_NOTIFY_TIMEOUT_MS:-${TMUX_NOTIFY_TIMEOUT:-0}}" 0)"

EVENT_TYPE="$(jq -r '.type // empty' <<<"$payload" 2>/dev/null || true)"
[ "$EVENT_TYPE" = "agent-turn-complete" ] || exit 0

TITLE="$(jq -r '."last-assistant-message" // "Turn Complete" | tostring' <<<"$payload" 2>/dev/null || printf '%s' 'Turn Complete')"
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

if ! tmux_cmd list-sessions >/dev/null 2>&1; then
    log_debug "tmux server not running"
    exit 0
fi

TARGET=""
if [ -n "${TMUX_PANE:-}" ]; then
    TARGET="$TMUX_PANE"
    if [ -n "$TARGET" ] && ! [[ "$TARGET" =~ ^%[0-9]+$ ]]; then
        TARGET=""
    fi
elif [ -n "${TMUX:-}" ]; then
    TARGET="$(tmux_cmd display-message -p '#{pane_id}' 2>/dev/null || true)"
    if [ -n "$TARGET" ] && ! [[ "$TARGET" =~ ^%[0-9]+$ ]]; then
        TARGET=""
    fi
    if [ -z "$TARGET" ]; then
        TARGET="$(tmux_cmd display-message -p '#S:#I.#P' 2>/dev/null || true)"
    fi
fi

if [ -z "$TARGET" ]; then
    log_debug "no TMUX_PANE/TMUX context; cannot determine target"
    exit 0
fi

resolve_jump_cmd() {
    if [ -n "${TMUX_NOTIFY_JUMP_SH:-}" ]; then
        printf '%s' "$TMUX_NOTIFY_JUMP_SH"
        return
    fi
    if command -v tmux-notify-jump >/dev/null 2>&1; then
        printf '%s' "tmux-notify-jump"
        return
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "$script_dir/tmux-notify-jump" ]; then
        printf '%s' "$script_dir/tmux-notify-jump"
        return
    fi
    printf '%s' "$script_dir/tmux-notify-jump"
}

is_executable_cmd() {
    local cmd="$1"
    if [[ "$cmd" == */* ]]; then
        [ -x "$cmd" ]
        return
    fi
    command -v "$cmd" >/dev/null 2>&1
}

JUMP_SH="$(resolve_jump_cmd)"
if ! is_executable_cmd "$JUMP_SH"; then
    log_debug "jump command not found/executable: $JUMP_SH"
    exit 0
fi

args=(
    --target "$TARGET"
    --title "Codex: $TITLE"
    --body "$MESSAGE"
    --detach
    --timeout "$TIMEOUT_MS"
    --max-title "$MAX_TITLE"
    --max-body "$MAX_BODY"
)

if [ "${CODEX_NOTIFY_QUIET:-1}" = "1" ]; then
    args+=(--quiet)
fi

if [ "${CODEX_NOTIFY_DEBUG:-0}" = "1" ]; then
    log_debug "target=$TARGET timeout=$TIMEOUT_MS max_title=$MAX_TITLE max_body=$MAX_BODY"
    "$JUMP_SH" "${args[@]}" || log_debug "jump script exited non-zero"
else
    "$JUMP_SH" "${args[@]}" >/dev/null 2>&1 || true
fi
