#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TITLE="Task complete"
APP_NAME="tmux"
DEFAULT_TIMEOUT="${TMUX_NOTIFY_TIMEOUT:-10000}"
DEFAULT_MAX_TITLE="${TMUX_NOTIFY_MAX_TITLE:-80}"
DEFAULT_MAX_BODY="${TMUX_NOTIFY_MAX_BODY:-200}"
ACTION_GOTO_LABEL="${TMUX_NOTIFY_ACTION_GOTO_LABEL:-Jump}"
ACTION_DISMISS_LABEL="${TMUX_NOTIFY_ACTION_DISMISS_LABEL:-Dismiss}"
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
DETACH=0
SENDER_CLIENT_PID=""
SENDER_CLIENT_TTY=""
ACTION_CALLBACK=0
ACTION_LABEL=""

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

truncate_text() {
    local max="$1"
    local text="$2"

    if [ "$max" -le 0 ]; then
        printf '%s' "$text"
        return
    fi

    if command -v python3 >/dev/null 2>&1; then
        local out=""
        set +e
        out="$(printf '%s' "$text" | python3 -c 'import sys
max_len = int(sys.argv[1])
text = sys.stdin.read()
if len(text) > max_len:
    sys.stdout.write(text[:max_len] + "…")
else:
    sys.stdout.write(text)
' "$max")"
        local status=$?
        set -e
        if [ $status -eq 0 ]; then
            printf '%s' "$out"
            return
        fi
    fi

    if [ "${#text}" -gt "$max" ]; then
        printf '%s…' "${text:0:max}"
        return
    fi
    printf '%s' "$text"
}

trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

require_tool() {
    local tool="$1"
    command -v "$tool" >/dev/null 2>&1 || die "Missing dependency: $tool"
}

is_integer() {
    local s="${1:-}"
    [[ "$s" =~ ^[0-9]+$ ]]
}

get_current_tmux_session() {
    if [ -z "${TMUX:-}" ]; then
        return 1
    fi
    local session=""
    if [ -n "${TMUX_PANE:-}" ]; then
        session="$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)"
    fi
    if [ -z "$session" ]; then
        session="$(tmux display-message -p '#S' 2>/dev/null || true)"
    fi
    if [ -n "$session" ]; then
        printf '%s' "$session"
        return 0
    fi
    return 1
}

get_sender_tmux_client_pid() {
    if [ -z "${TMUX:-}" ]; then
        return 1
    fi

    local current_session=""
    current_session="$(get_current_tmux_session 2>/dev/null || true)"

    local best_pid=""
    local best_activity=0
    local output=""
    output="$(tmux list-clients -F "#{client_activity} #{client_pid} #{client_session}" 2>/dev/null || true)"
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local activity="${line%% *}"
        local rest="${line#* }"
        local pid="${rest%% *}"
        local session="${rest#* }"

        if ! is_integer "$activity"; then
            continue
        fi
        if ! is_integer "$pid"; then
            continue
        fi
        if [ -n "$current_session" ] && [ "$session" != "$current_session" ]; then
            continue
        fi

        if [ "$activity" -gt "$best_activity" ]; then
            best_activity="$activity"
            best_pid="$pid"
        fi
    done <<<"$output"

    if is_integer "$best_pid"; then
        printf '%s' "$best_pid"
        return 0
    fi
    return 1
}

get_sender_tmux_client_tty() {
    if [ -z "${TMUX:-}" ]; then
        return 1
    fi

    if [ -n "${TMUX_PANE:-}" ]; then
        local clients_by_pane=""
        clients_by_pane="$(tmux list-clients -F "#{client_tty} #{client_pane}" 2>/dev/null || true)"
        local line=""
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            local tty="${line%% *}"
            local pane="${line#* }"
            if [ "$pane" = "$TMUX_PANE" ] && [ -n "$tty" ]; then
                printf '%s' "$tty"
                return 0
            fi
        done <<<"$clients_by_pane"
    fi

    local tty=""
    tty="$(tmux display-message -p '#{client_tty}' 2>/dev/null || true)"
    if [ -n "$tty" ]; then
        printf '%s' "$tty"
        return 0
    fi

    local current_session=""
    current_session="$(get_current_tmux_session 2>/dev/null || true)"

    local best_tty=""
    local best_activity=0
    local clients_by_activity=""
    clients_by_activity="$(tmux list-clients -F "#{client_activity} #{client_tty} #{client_session}" 2>/dev/null || true)"
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local activity="${line%% *}"
        local rest="${line#* }"
        local tty="${rest%% *}"
        local session="${rest#* }"

        if ! is_integer "$activity"; then
            continue
        fi
        if [ -n "$current_session" ] && [ "$session" != "$current_session" ]; then
            continue
        fi

        if [ "$activity" -gt "$best_activity" ] && [ -n "$tty" ]; then
            best_activity="$activity"
            best_tty="$tty"
        fi
    done <<<"$clients_by_activity"

    if [ -n "$best_tty" ]; then
        printf '%s' "$best_tty"
        return 0
    fi
    return 1
}

get_tmux_client_pid_by_tty() {
    local tty="${1:-}"
    [ -n "$tty" ] || return 1
    if [ -z "${TMUX:-}" ]; then
        return 1
    fi

    local output=""
    output="$(tmux list-clients -F "#{client_tty} #{client_pid}" 2>/dev/null || true)"
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local client_tty="${line%% *}"
        local pid="${line#* }"
        if [ "$client_tty" = "$tty" ] && is_integer "$pid"; then
            printf '%s' "$pid"
            return 0
        fi
    done <<<"$output"
    return 1
}

require_tools() {
    require_tool tmux
    require_tool terminal-notifier
    if [ "$NO_ACTIVATE" -eq 0 ]; then
        require_tool osascript
    fi
}

check_tmux_server() {
    tmux list-sessions >/dev/null 2>&1 || die "tmux server is not running"
}

list_panes() {
    require_tool tmux
    if ! tmux list-sessions >/dev/null 2>&1; then
        die "tmux server is not running; cannot list panes"
    fi
    tmux list-panes -a -F "  #{?pane_active,*, } #{session_name}:#{window_index}.#{pane_index} - #{pane_title}"
}

parse_target() {
    local target="$1"
    if [[ "$target" != *:*.* ]]; then
        die "Target must be in the form session:window.pane"
    fi
    SESSION="${target%%:*}"
    local window_pane="${target#*:}"
    WINDOW="${window_pane%%.*}"
    PANE="${window_pane#*.}"
    if [ -z "$SESSION" ] || [ -z "$WINDOW" ] || [ -z "$PANE" ]; then
        die "Target must be in the form session:window.pane"
    fi
}

validate_target_exists() {
    check_tmux_server
    if ! tmux has-session -t "$SESSION" >/dev/null 2>&1; then
        die "Session does not exist: $SESSION"
    fi
    local panes
    if ! panes=$(tmux list-panes -t "$SESSION:$WINDOW" -F "#{pane_index}" 2>/dev/null); then
        die "Window does not exist: $SESSION:$WINDOW"
    fi
    if ! echo "$panes" | grep -qx "$PANE"; then
        die "Pane does not exist: $SESSION:$WINDOW.$PANE"
    fi
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
    local args=(
        -title "$TITLE"
        -message "$BODY"
        -actions "${ACTION_GOTO_LABEL},${ACTION_DISMISS_LABEL}"
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

    if printf '%s' "$output" | grep -q "\"activationValue\":\"$ACTION_GOTO_LABEL\""; then
        echo "goto"
        return
    fi
    if printf '%s' "$output" | grep -q "\"activationValue\":\"$ACTION_DISMISS_LABEL\""; then
        echo "dismiss"
        return
    fi
    if printf '%s' "$output" | grep -qi "\"activationType\":\"contentsClicked\""; then
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

    export TMUX_NOTIFY_CALLBACK_TARGET="$TARGET"
    export TMUX_NOTIFY_CALLBACK_TITLE="$TITLE"
    export TMUX_NOTIFY_CALLBACK_BODY="$BODY"
    export TMUX_NOTIFY_CALLBACK_SENDER_TTY="$SENDER_CLIENT_TTY"
    export TMUX_NOTIFY_CALLBACK_SENDER_PID="$SENDER_CLIENT_PID"
    export TMUX_NOTIFY_CALLBACK_NO_ACTIVATE="$NO_ACTIVATE"
    export TMUX_NOTIFY_CALLBACK_BUNDLE_IDS="$BUNDLE_ID_LIST"
    export TMUX_NOTIFY_CALLBACK_ACTION_GOTO_LABEL="$ACTION_GOTO_LABEL"
    export TMUX_NOTIFY_CALLBACK_ACTION_DISMISS_LABEL="$ACTION_DISMISS_LABEL"
    export TMUX_NOTIFY_CALLBACK_QUIET="$QUIET"

    local args=(
        -title "$TITLE"
        -message "$BODY"
        -actions "${ACTION_GOTO_LABEL},${ACTION_DISMISS_LABEL}"
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

send_notification() {
    if [ "$DETACH" -eq 0 ] && supports_wait; then
        send_notification_wait
        return
    fi
    send_notification_execute
}

handle_action_callback() {
    TARGET="${TMUX_NOTIFY_CALLBACK_TARGET:-}"
    TITLE="${TMUX_NOTIFY_CALLBACK_TITLE:-$DEFAULT_TITLE}"
    BODY="${TMUX_NOTIFY_CALLBACK_BODY:-}"
    SENDER_CLIENT_TTY="${TMUX_NOTIFY_CALLBACK_SENDER_TTY:-}"
    SENDER_CLIENT_PID="${TMUX_NOTIFY_CALLBACK_SENDER_PID:-}"
    NO_ACTIVATE="${TMUX_NOTIFY_CALLBACK_NO_ACTIVATE:-0}"
    BUNDLE_ID_LIST="${TMUX_NOTIFY_CALLBACK_BUNDLE_IDS:-$BUNDLE_ID_LIST}"
    ACTION_GOTO_LABEL="${TMUX_NOTIFY_CALLBACK_ACTION_GOTO_LABEL:-$ACTION_GOTO_LABEL}"
    ACTION_DISMISS_LABEL="${TMUX_NOTIFY_CALLBACK_ACTION_DISMISS_LABEL:-$ACTION_DISMISS_LABEL}"
    QUIET="${TMUX_NOTIFY_CALLBACK_QUIET:-$QUIET}"

    if [ -z "$TARGET" ]; then
        exit 0
    fi

    parse_target "$TARGET"
    if ! tmux list-sessions >/dev/null 2>&1; then
        exit 0
    fi

    if [ "$ACTION_LABEL" = "$ACTION_GOTO_LABEL" ] || [ "$ACTION_LABEL" = "Clicked" ] || [ "$ACTION_LABEL" = "contentsClicked" ]; then
        activate_terminal
        jump_to_pane
    elif [ "$ACTION_LABEL" = "$ACTION_DISMISS_LABEL" ]; then
        log "Dismissed"
    else
        log "Notification sent"
    fi
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

    if ! tmux switch-client "${switch_args[@]}" -t "$SESSION" ';' \
        select-window -t "$SESSION:$WINDOW" ';' \
        select-pane -t "$SESSION:$WINDOW.$PANE" 2>/dev/null; then
        warn "Failed to switch tmux client; selecting target window and pane only"
        tmux select-window -t "$SESSION:$WINDOW" 2>/dev/null || die "Failed to select window"
        tmux select-pane -t "$SESSION:$WINDOW.$PANE" 2>/dev/null || die "Failed to select pane"
    fi
    log "Jumped to $SESSION:$WINDOW.$PANE"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --action-callback)
                ACTION_CALLBACK=1
                ACTION_LABEL=""
                if [ $# -gt 1 ] && [[ "${2:-}" != -* ]]; then
                    ACTION_LABEL="$2"
                    shift 2
                else
                    shift 1
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
