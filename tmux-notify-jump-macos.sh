#!/usr/bin/env bash
set -euo pipefail

# Notification click callbacks may run with a restricted GUI PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-notify-jump-lib.sh
. "$SCRIPT_DIR/tmux-notify-jump-lib.sh"

load_user_config

DEFAULT_TITLE="Task complete"
DEFAULT_TIMEOUT="${TMUX_NOTIFY_TIMEOUT:-10000}"
DEFAULT_MAX_TITLE="${TMUX_NOTIFY_MAX_TITLE:-80}"
DEFAULT_MAX_BODY="${TMUX_NOTIFY_MAX_BODY:-200}"
ACTION_GOTO_LABEL="${TMUX_NOTIFY_ACTION_GOTO_LABEL:-Jump}"
ACTION_DISMISS_LABEL="${TMUX_NOTIFY_ACTION_DISMISS_LABEL:-Dismiss}"
DEFAULT_UI="${TMUX_NOTIFY_UI:-notification}"
BUILTIN_DEFAULT_BUNDLE_ID="com.github.wez.wezterm"
BUILTIN_DEFAULT_BUNDLE_ID_LIST="com.github.wez.wezterm,com.googlecode.iterm2,com.apple.Terminal"
DEFAULT_BUNDLE_ID="${TMUX_NOTIFY_BUNDLE_ID:-$BUILTIN_DEFAULT_BUNDLE_ID}"
if [ -n "${TMUX_NOTIFY_BUNDLE_IDS:-}" ]; then
    DEFAULT_BUNDLE_ID_LIST="$TMUX_NOTIFY_BUNDLE_IDS"
elif [ -n "${TMUX_NOTIFY_BUNDLE_ID:-}" ]; then
    DEFAULT_BUNDLE_ID_LIST="$TMUX_NOTIFY_BUNDLE_ID"
else
    DEFAULT_BUNDLE_ID_LIST="$BUILTIN_DEFAULT_BUNDLE_ID_LIST"
fi

TARGET=""
TITLE=""
BODY=""
BUNDLE_ID="$DEFAULT_BUNDLE_ID"
BUNDLE_ID_LIST="$DEFAULT_BUNDLE_ID_LIST"
NO_ACTIVATE=0
LIST_ONLY=0
DRY_RUN=0
QUIET=0
TIMEOUT="$DEFAULT_TIMEOUT"
MAX_TITLE="$DEFAULT_MAX_TITLE"
MAX_BODY="$DEFAULT_MAX_BODY"
UI="$DEFAULT_UI"
DETACH=0
SENDER_CLIENT_PID=""
SENDER_CLIENT_TTY=""
ACTION_CALLBACK=0
ACTION_CALLBACK_ARG=""
TMUX_SOCKET=""

# Callback-specific variables (passed via --cb-* args from -execute)
CB_TARGET=""
CB_SENDER_TTY=""
CB_NO_ACTIVATE=""
CB_TMUX_SOCKET=""
CB_BUNDLE_IDS=""

print_usage() {
    cat <<EOF
Usage:
  $0 <session>:<window>.<pane> [title] [body]
  $0 --target <session:window.pane> [--title <title>] [--body <body>]

Options:
  --list               List available panes
  --no-activate        Do not focus the terminal window
  --bundle-id <ID>     Use a single terminal bundle id
  --bundle-ids <A,B>   Comma-separated bundle ids (default: $BUNDLE_ID_LIST)
  --dry-run            Print what would happen and exit
  --quiet              Suppress non-error output
  --timeout <ms>       Notification timeout in ms (default 10000)
  --ui <notification|dialog>
                      notification: desktop notification (default)
                      dialog: always-wait modal prompt with buttons
  --max-title <n>      Max title length (0 = no truncation)
  --max-body <n>       Max body length (0 = no truncation)
  --detach             Detach and return immediately (handles click in background)
  -h, --help           Show help

Examples:
  $0 "2:1.0" "Build finished" "Click to jump to the pane"
  $0 --target "work:0.1" --title "Task complete"
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

warn() {
    if [ "$QUIET" -eq 1 ]; then
        return
    fi
    echo "Warning: $*" >&2
}

log() {
    if [ "$QUIET" -eq 1 ]; then
        return
    fi
    echo "$*"
}

log_debug() {
    [ "${TMUX_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local logfile="${TMUX_NOTIFY_DEBUG_LOG:-$HOME/.config/tmux-notify-jump/debug.log}"
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$logfile" 2>/dev/null || true
}

require_tools() {
    require_tool tmux
    if [ "$UI" = "dialog" ]; then
        require_tool osascript
        return
    fi
    require_tool terminal-notifier
    if [ "$NO_ACTIVATE" -eq 0 ]; then
        require_tool osascript
    fi
}

get_tmux_socket_from_env() {
    if [ -n "${TMUX:-}" ]; then
        printf '%s' "${TMUX%%,*}"
        return 0
    fi
    return 1
}

supports_wait() {
    terminal-notifier -help 2>&1 | grep -q -- '-wait'
}

timeout_seconds() {
    local ms="$1"
    if [ -z "$ms" ] || [ "$ms" -le 0 ]; then
        echo ""
        return
    fi
    echo $(( (ms + 999) / 1000 ))
}

send_notification_wait() {
    local seconds
    seconds="$(timeout_seconds "$TIMEOUT")"
    local goto_label="$ACTION_GOTO_LABEL"
    local dismiss_label="$ACTION_DISMISS_LABEL"
    if [[ "$goto_label" == *","* ]]; then
        goto_label="${goto_label//,/ }"
    fi
    if [[ "$dismiss_label" == *","* ]]; then
        dismiss_label="${dismiss_label//,/ }"
    fi
    local args=(
        -title "$TITLE"
        -message "$BODY"
        -actions "${goto_label},${dismiss_label}"
        -json
        -wait
    )
    if [ -n "$seconds" ]; then
        args+=(-timeout "$seconds")
    fi

    local output=""
    set +e
    output="$(terminal-notifier "${args[@]}" 2>/dev/null || true)"
    set -e

    if command -v python3 >/dev/null 2>&1; then
        local parsed=""
        set +e
        parsed="$(python3 - "$goto_label" "$dismiss_label" "$output" <<'PY'
import json
import sys

goto_label = sys.argv[1]
dismiss_label = sys.argv[2]
raw = sys.argv[3]

if not raw:
    print("none")
    raise SystemExit(0)

try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(1)

activation_type = str(data.get("activationType") or "")
activation_value = str(data.get("activationValue") or "")

if activation_value == goto_label:
    print("goto")
elif activation_value == dismiss_label:
    print("dismiss")
elif activation_type.lower() == "contentsclicked":
    print("goto")
else:
    print("none")
PY
)"
        local status=$?
        set -e
        if [ $status -eq 0 ] && [ -n "$parsed" ]; then
            echo "$parsed"
            return
        fi
    fi

    if printf '%s' "$output" | grep -Fq "\"activationValue\":\"$goto_label\""; then
        echo "goto"
        return
    fi
    if printf '%s' "$output" | grep -Fq "\"activationValue\":\"$dismiss_label\""; then
        echo "dismiss"
        return
    fi
    if printf '%s' "$output" | grep -Fiq "\"activationType\":\"contentsClicked\""; then
        echo "goto"
        return
    fi
    echo "none"
}

send_notification_execute() {
    local seconds
    seconds="$(timeout_seconds "$TIMEOUT")"
    local self_path
    self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    local exec_cmd
    exec_cmd="$(printf '%q' "$self_path") --action-callback"
    exec_cmd+=" --cb-target $(printf '%q' "$TARGET")"
    exec_cmd+=" --cb-sender-tty $(printf '%q' "${SENDER_CLIENT_TTY:-}")"
    exec_cmd+=" --cb-no-activate $(printf '%q' "$NO_ACTIVATE")"
    exec_cmd+=" --cb-tmux-socket $(printf '%q' "${TMUX_SOCKET:-}")"
    exec_cmd+=" --cb-bundle-ids $(printf '%q' "$BUNDLE_ID_LIST")"

    local args=(
        -title "$TITLE"
        -message "$BODY"
        -execute "$exec_cmd"
    )
    if [ -n "$seconds" ]; then
        args+=(-timeout "$seconds")
    fi

    set +e
    terminal-notifier "${args[@]}" >/dev/null 2>&1
    local status=$?
    set -e
    if [ $status -ne 0 ]; then
        warn "Failed to send notification"
    fi
    echo "none"
}

send_dialog() {
    require_tool osascript
    local clicked=""
    set +e
    clicked="$(osascript - "$TITLE" "$BODY" "$ACTION_GOTO_LABEL" "$ACTION_DISMISS_LABEL" <<'APPLESCRIPT'
on run argv
	set theTitle to item 1 of argv
	set theBody to item 2 of argv
	set gotoLabel to item 3 of argv
	set dismissLabel to item 4 of argv
	set r to display dialog theBody with title theTitle buttons {dismissLabel, gotoLabel} default button gotoLabel
	return button returned of r
end run
APPLESCRIPT
)"
    local status=$?
    set -e
    if [ $status -ne 0 ]; then
        echo "dismiss"
        return
    fi
    if [ "$clicked" = "$ACTION_GOTO_LABEL" ]; then
        echo "goto"
        return
    fi
    echo "dismiss"
}

send_notification() {
    if [ "$UI" = "dialog" ]; then
        send_dialog
        return
    fi
    if [ "$DETACH" -eq 0 ] && supports_wait; then
        send_notification_wait
        return
    fi
    send_notification_execute
}

handle_action_callback() {
    TARGET="${CB_TARGET:-}"
    SENDER_CLIENT_TTY="${CB_SENDER_TTY:-}"
    NO_ACTIVATE="${CB_NO_ACTIVATE:-0}"
    TMUX_SOCKET="${CB_TMUX_SOCKET:-}"
    BUNDLE_ID_LIST="${CB_BUNDLE_IDS:-$BUNDLE_ID_LIST}"
    TMUX_NOTIFY_TMUX_SOCKET="${TMUX_SOCKET:-}"

    if [ -z "$TARGET" ]; then
        exit 0
    fi

    parse_target "$TARGET"
    if ! tmux_cmd list-sessions >/dev/null 2>&1; then
        exit 0
    fi

    # `terminal-notifier -execute` runs only on click; treat any callback as "goto".
    activate_terminal
    jump_to_pane
}

handle_action() {
    if [ -z "$SENDER_CLIENT_TTY" ]; then
        SENDER_CLIENT_TTY="$(get_sender_tmux_client_tty 2>/dev/null || true)"
    fi
    if [ -z "$SENDER_CLIENT_PID" ]; then
        if [ -n "$SENDER_CLIENT_TTY" ]; then
            SENDER_CLIENT_PID="$(get_tmux_client_pid_by_tty "$SENDER_CLIENT_TTY" 2>/dev/null || true)"
        fi
    fi
    if [ -z "$SENDER_CLIENT_PID" ]; then
        SENDER_CLIENT_PID="$(get_sender_tmux_client_pid 2>/dev/null || true)"
    fi
    if [ -z "$TMUX_SOCKET" ]; then
        TMUX_SOCKET="$(get_tmux_socket_from_env 2>/dev/null || true)"
    fi

    local action
    action="$(send_notification)"

    if [ "$action" = "goto" ]; then
        activate_terminal
        jump_to_pane
    elif [ "$action" = "dismiss" ]; then
        log "Dismissed"
    else
        log "Notification sent"
    fi
}

activate_terminal() {
    if [ "$NO_ACTIVATE" -eq 1 ]; then
        return
    fi

    local id_list="${BUNDLE_ID_LIST:-$BUNDLE_ID}"
    local id_item
    IFS=',' read -r -a id_array <<< "$id_list"
    for id_item in "${id_array[@]}"; do
        id_item="$(trim_ws "$id_item")"
        [ -n "$id_item" ] || continue
        if osascript -e "tell application id \"$id_item\" to activate" >/dev/null 2>&1; then
            return
        fi
    done

    warn "Failed to activate terminal (set TMUX_NOTIFY_BUNDLE_ID(S) or use --no-activate)"
}

jump_to_pane() {
    local switch_args=()
    if [ -n "$SENDER_CLIENT_TTY" ]; then
        switch_args=(-c "$SENDER_CLIENT_TTY")
    fi

    if ! tmux_cmd switch-client "${switch_args[@]}" -t "$SESSION" ';' \
        select-window -t "$SESSION:$WINDOW" ';' \
        select-pane -t "$SESSION:$WINDOW.$PANE" 2>/dev/null; then
        warn "Failed to switch tmux client; selecting target window and pane only"
        tmux_cmd select-window -t "$SESSION:$WINDOW" 2>/dev/null || die "Failed to select window"
        tmux_cmd select-pane -t "$SESSION:$WINDOW.$PANE" 2>/dev/null || die "Failed to select pane"
    fi
    log "Jumped to $SESSION:$WINDOW.$PANE"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --action-callback)
                ACTION_CALLBACK=1
                shift
                if [ $# -gt 0 ] && [[ "${1:-}" != -* ]]; then
                    ACTION_CALLBACK_ARG="$1"
                    log_debug "action-callback extra arg: $ACTION_CALLBACK_ARG"
                    shift
                fi
                continue
                ;;
            --target)
                shift
                [ $# -gt 0 ] || die "--target requires an argument"
                TARGET="$1"
                ;;
            --title)
                shift
                [ $# -gt 0 ] || die "--title requires an argument"
                TITLE="$1"
                ;;
            --body)
                shift
                [ $# -gt 0 ] || die "--body requires an argument"
                BODY="$1"
                ;;
            --bundle-id)
                shift
                [ $# -gt 0 ] || die "--bundle-id requires an argument"
                BUNDLE_ID="$1"
                BUNDLE_ID_LIST="$1"
                ;;
            --bundle-ids)
                shift
                [ $# -gt 0 ] || die "--bundle-ids requires an argument"
                BUNDLE_ID_LIST="$1"
                BUNDLE_ID=""
                ;;
            --no-activate)
                NO_ACTIVATE=1
                ;;
            --list)
                LIST_ONLY=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --quiet)
                QUIET=1
                ;;
            --timeout)
                shift
                [ $# -gt 0 ] || die "--timeout requires an argument"
                TIMEOUT="$1"
                ;;
            --ui)
                shift
                [ $# -gt 0 ] || die "--ui requires an argument"
                UI="$1"
                ;;
            --max-title)
                shift
                [ $# -gt 0 ] || die "--max-title requires an argument"
                MAX_TITLE="$1"
                ;;
            --max-body)
                shift
                [ $# -gt 0 ] || die "--max-body requires an argument"
                MAX_BODY="$1"
                ;;
            --detach)
                DETACH=1
                ;;
            # Callback-specific arguments (used internally by -execute)
            --cb-target)
                shift
                [ $# -gt 0 ] || die "--cb-target requires an argument"
                CB_TARGET="$1"
                ;;
            --cb-sender-tty)
                shift
                [ $# -gt 0 ] || die "--cb-sender-tty requires an argument"
                CB_SENDER_TTY="$1"
                ;;
            --cb-no-activate)
                shift
                [ $# -gt 0 ] || die "--cb-no-activate requires an argument"
                CB_NO_ACTIVATE="$1"
                ;;
            --cb-tmux-socket)
                shift
                [ $# -gt 0 ] || die "--cb-tmux-socket requires an argument"
                CB_TMUX_SOCKET="$1"
                ;;
            --cb-bundle-ids)
                shift
                [ $# -gt 0 ] || die "--cb-bundle-ids requires an argument"
                CB_BUNDLE_IDS="$1"
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [ -z "$TARGET" ]; then
                    TARGET="$1"
                elif [ -z "$TITLE" ]; then
                    TITLE="$1"
                elif [ -z "$BODY" ]; then
                    BODY="$1"
                else
                    die "Too many arguments: $1"
                fi
                ;;
        esac
        shift
    done
}

parse_args "$@"

if [ "$ACTION_CALLBACK" -eq 1 ]; then
    handle_action_callback
    exit 0
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    list_panes
    exit 0
fi

if [ -z "$TARGET" ]; then
    print_usage
    echo ""
    echo "Available tmux panes:"
    list_panes
    exit 1
fi

TITLE="${TITLE:-$DEFAULT_TITLE}"
BODY="${BODY:-Click to jump to $TARGET}"

if [ -n "${TIMEOUT:-}" ] && ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    die "--timeout must be a non-negative integer (ms)"
fi

if [ "$UI" != "notification" ] && [ "$UI" != "dialog" ]; then
    die "--ui must be one of: notification, dialog"
fi

if ! [[ "$MAX_TITLE" =~ ^[0-9]+$ ]]; then
    die "--max-title must be a non-negative integer"
fi
if ! [[ "$MAX_BODY" =~ ^[0-9]+$ ]]; then
    die "--max-body must be a non-negative integer"
fi

TITLE="$(truncate_text "$MAX_TITLE" "$TITLE")"
BODY="$(truncate_text "$MAX_BODY" "$BODY")"

if [ "$DRY_RUN" -eq 1 ]; then
    parse_target "$TARGET"
    log "Target: $SESSION:$WINDOW.$PANE"
    log "Title: $TITLE"
    log "Body: $BODY"
    log "Bundle ids: ${BUNDLE_ID_LIST:-$BUNDLE_ID}"
    log "Focus terminal: $([ "$NO_ACTIVATE" -eq 1 ] && echo "no" || echo "yes")"
    log "Timeout: ${TIMEOUT:-default}"
    log "Max title length: $MAX_TITLE"
    log "Max body length: $MAX_BODY"
    exit 0
fi

require_tools
parse_target "$TARGET"
validate_target_exists

if [ "$DETACH" -eq 1 ]; then
    (handle_action) >/dev/null 2>&1 &
    exit 0
fi

handle_action
