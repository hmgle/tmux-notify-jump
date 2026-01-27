#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TITLE="Task complete"
BUILTIN_DEFAULT_CLASS="org.wezfurlong.wezterm"
BUILTIN_DEFAULT_CLASS_LIST="org.wezfurlong.wezterm,Alacritty"
DEFAULT_CLASS="${TMUX_NOTIFY_CLASS:-$BUILTIN_DEFAULT_CLASS}"
if [ -n "${TMUX_NOTIFY_CLASSES:-}" ]; then
    DEFAULT_CLASS_LIST="$TMUX_NOTIFY_CLASSES"
elif [ -n "${TMUX_NOTIFY_CLASS:-}" ]; then
    DEFAULT_CLASS_LIST="$TMUX_NOTIFY_CLASS"
else
    DEFAULT_CLASS_LIST="$BUILTIN_DEFAULT_CLASS_LIST"
fi
APP_NAME="tmux"
URGENCY="normal"
DEFAULT_TIMEOUT="${TMUX_NOTIFY_TIMEOUT:-10000}"
DEFAULT_MAX_TITLE="${TMUX_NOTIFY_MAX_TITLE:-80}"
DEFAULT_MAX_BODY="${TMUX_NOTIFY_MAX_BODY:-200}"
ACTION_GOTO_LABEL="${TMUX_NOTIFY_ACTION_GOTO_LABEL:-Jump}"
ACTION_DISMISS_LABEL="${TMUX_NOTIFY_ACTION_DISMISS_LABEL:-Dismiss}"

TARGET=""
TITLE=""
BODY=""
WINDOW_CLASS="$DEFAULT_CLASS"
WINDOW_CLASS_LIST="$DEFAULT_CLASS_LIST"
NO_ACTIVATE=0
LIST_ONLY=0
DRY_RUN=0
QUIET=0
TIMEOUT="$DEFAULT_TIMEOUT"
MAX_TITLE="$DEFAULT_MAX_TITLE"
MAX_BODY="$DEFAULT_MAX_BODY"
DETACH=0

print_usage() {
    cat <<EOF
Usage:
  $0 <session>:<window>.<pane> [title] [body]
  $0 --target <session:window.pane> [--title <title>] [--body <body>]

Options:
  --list               List available panes
  --no-activate        Do not focus the terminal window
  --class <CLASS>      Use a single terminal window class
  --classes <A,B>      Comma-separated terminal window classes (default: $DEFAULT_CLASS_LIST)
  --dry-run            Print what would happen and exit
  --quiet              Suppress non-error output
  --timeout <ms>       Notification timeout in ms (default 10000; 0 may mean "sticky" depending on daemon)
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

is_wayland_session() {
    if [ -n "${XDG_SESSION_TYPE:-}" ]; then
        [ "$XDG_SESSION_TYPE" = "wayland" ]
        return
    fi
    [ -n "${WAYLAND_DISPLAY:-}" ]
}

require_tools() {
    require_tool tmux
    require_tool notify-send
    if [ "$NO_ACTIVATE" -eq 0 ]; then
        if is_wayland_session; then
            warn "Wayland session detected; terminal focusing is disabled"
            NO_ACTIVATE=1
            return
        fi
        if ! command -v xdotool >/dev/null 2>&1; then
            warn "Missing xdotool; terminal focusing is disabled"
            NO_ACTIVATE=1
        fi
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

send_notification() {
    local action=""
    local timeout_args=()
    if [ -n "${TIMEOUT:-}" ]; then
        timeout_args=(-t "$TIMEOUT")
    fi

    local errfile=""
    if command -v mktemp >/dev/null 2>&1; then
        errfile="$(mktemp "${TMPDIR:-/tmp}/tmux-notify-jump.XXXXXX" 2>/dev/null || true)"
    fi
    if [ -z "$errfile" ]; then
        errfile="/tmp/tmux-notify-jump.$$.$RANDOM.err"
        : >"$errfile" 2>/dev/null || errfile=""
    fi

    set +e
    local stderr_redirect="/dev/null"
    if [ -n "$errfile" ]; then
        stderr_redirect="$errfile"
    fi

    action=$(notify-send \
        -A "goto=$ACTION_GOTO_LABEL" \
        -A "dismiss=$ACTION_DISMISS_LABEL" \
        -u "$URGENCY" \
        -a "$APP_NAME" \
        "${timeout_args[@]}" \
        --wait \
        "$TITLE" \
        "$BODY" \
        2>"$stderr_redirect")
    local status=$?
    local err=""
    if [ -n "$errfile" ]; then
        err="$(cat "$errfile" 2>/dev/null || true)"
        rm -f "$errfile" 2>/dev/null || true
    fi
    set -e

    if [ -n "$action" ]; then
        echo "$action"
        return
    fi

    if [ $status -eq 0 ]; then
        echo "none"
        return
    fi

    if [ -z "${err//$'\n'/}" ]; then
        echo "none"
        return
    fi

    err="${err//$'\n'/; }"
    warn "notify-send failed: $err"
    warn "Notification actions unavailable; falling back to plain notification"
    set +e
    notify-send -u "$URGENCY" -a "$APP_NAME" "${timeout_args[@]}" "$TITLE" "$BODY" 2>/dev/null
    local fallback_status=$?
    set -e
    if [ $fallback_status -ne 0 ]; then
        warn "Failed to send notification"
    fi
    echo "none"
}

handle_action() {
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
    local wid
    local class_list="${WINDOW_CLASS_LIST:-$WINDOW_CLASS}"
    local class_item
    IFS=',' read -r -a class_array <<< "$class_list"
    for class_item in "${class_array[@]}"; do
        class_item="$(trim_ws "$class_item")"
        [ -n "$class_item" ] || continue
        local ids=""
        ids="$(xdotool search --class "$class_item" 2>/dev/null || true)"
        if IFS= read -r wid <<<"$ids"; then
            :
        else
            wid=""
        fi
        if [ -n "$wid" ]; then
            break
        fi
    done
    if [ -z "$wid" ]; then
        warn "No terminal window found for class(es): $class_list"
        return
    fi
    xdotool windowactivate "$wid" 2>/dev/null || warn "Failed to activate terminal window"
}

jump_to_pane() {
    if ! tmux switch-client -t "$SESSION" 2>/dev/null; then
        warn "Failed to switch client; trying to select window directly"
    fi
    tmux select-window -t "$SESSION:$WINDOW" 2>/dev/null || die "Failed to select window"
    tmux select-pane -t "$SESSION:$WINDOW.$PANE" 2>/dev/null || die "Failed to select pane"
    log "Jumped to $SESSION:$WINDOW.$PANE"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
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
            --class)
                shift
                [ $# -gt 0 ] || die "--class requires an argument"
                WINDOW_CLASS="$1"
                WINDOW_CLASS_LIST="$1"
                ;;
            --classes)
                shift
                [ $# -gt 0 ] || die "--classes requires an argument"
                WINDOW_CLASS_LIST="$1"
                WINDOW_CLASS=""
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
    log "Window classes: ${WINDOW_CLASS_LIST:-$WINDOW_CLASS}"
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
