#!/usr/bin/env bash
set -euo pipefail

# Helper for tmux hooks (notify.c):
# - Designed to be called from `set-hook ... run-shell ...`.
# - Builds a reasonable title/body from a pane id (#{hook_pane}) and event name.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-notify-jump-lib.sh
. "$SCRIPT_DIR/tmux-notify-jump-lib.sh"

load_user_config

die() {
    echo "Error: $*" >&2
    exit 1
}

EVENT=""
HOOK_PANE_ID=""
FORWARD_ARGS=()

has_forward_arg() {
    local needle="$1"
    local item=""
    for item in "${FORWARD_ARGS[@]}"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

forward_ui_is_dialog() {
    local i=0
    while [ $i -lt ${#FORWARD_ARGS[@]} ]; do
        if [ "${FORWARD_ARGS[$i]}" = "--ui" ]; then
            local j=$((i + 1))
            if [ $j -lt ${#FORWARD_ARGS[@]} ] && [ "${FORWARD_ARGS[$j]}" = "dialog" ]; then
                return 0
            fi
        fi
        i=$((i + 1))
    done
    return 1
}

usage() {
    cat <<EOF
Usage:
  $0 --event <name> --pane-id <pane_id> [tmux-notify-jump options...]

Examples (tmux.conf):
  set-hook -g alert-activity "run-shell -b 'tmux-notify-jump-hook.sh --event alert-activity --pane-id \"#{hook_pane}\"'"
  set-hook -g alert-bell     "run-shell -b 'tmux-notify-jump-hook.sh --event alert-bell --pane-id \"#{hook_pane}\" --timeout 0'"

Notes:
  - Prefer pane ids (%1) via #{hook_pane}; tmux-notify-jump will resolve to session/window/pane at jump time.
  - If you run multiple tmux servers, pass --tmux-socket <path> to pin the correct one.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --event)
            shift
            [ $# -gt 0 ] || die "--event requires an argument"
            EVENT="$1"
            ;;
        --pane-id|--pane)
            shift
            [ $# -gt 0 ] || die "--pane-id requires an argument"
            HOOK_PANE_ID="$1"
            ;;
        --tmux-socket)
            shift
            [ $# -gt 0 ] || die "--tmux-socket requires an argument"
            TMUX_NOTIFY_TMUX_SOCKET="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            FORWARD_ARGS+=("$@")
            break
            ;;
        *)
            FORWARD_ARGS+=("$1")
            ;;
    esac
    shift
done

[ -n "$HOOK_PANE_ID" ] || die "--pane-id is required (use #{hook_pane})"
if ! is_pane_id "$HOOK_PANE_ID"; then
    die "--pane-id must be a pane id like %1; got: $HOOK_PANE_ID"
fi

if [ -n "${TMUX_NOTIFY_TMUX_SOCKET:-}" ] && ! has_forward_arg --tmux-socket; then
    FORWARD_ARGS+=(--tmux-socket "$TMUX_NOTIFY_TMUX_SOCKET")
fi

if ! tmux_cmd list-sessions >/dev/null 2>&1; then
    exit 0
fi

target_human="$(tmux_cmd display-message -p -t "$HOOK_PANE_ID" '#S:#I.#P' 2>/dev/null || true)"
window_name="$(tmux_cmd display-message -p -t "$HOOK_PANE_ID" '#W' 2>/dev/null || true)"
pane_title="$(tmux_cmd display-message -p -t "$HOOK_PANE_ID" '#{pane_title}' 2>/dev/null || true)"

if ! has_forward_arg --title; then
    if [ -n "$EVENT" ]; then
        FORWARD_ARGS+=(--title "tmux: $EVENT")
    else
        FORWARD_ARGS+=(--title "tmux")
    fi
fi

if ! has_forward_arg --body; then
    body="$target_human"
    if [ -n "$window_name" ]; then
        body="${body} — $window_name"
    fi
    if [ -n "$pane_title" ]; then
        body="${body} — $pane_title"
    fi
    FORWARD_ARGS+=(--body "$body")
fi

if ! has_forward_arg --detach && ! has_forward_arg --dry-run && ! forward_ui_is_dialog; then
    FORWARD_ARGS+=(--detach)
fi

exec "$SCRIPT_DIR/tmux-notify-jump" --target "$HOOK_PANE_ID" "${FORWARD_ARGS[@]}"
