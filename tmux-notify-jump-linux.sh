#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-notify-jump-lib.sh
. "$SCRIPT_DIR/tmux-notify-jump-lib.sh"

load_user_config

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
DEFAULT_WRAP_COLS="${TMUX_NOTIFY_WRAP_COLS:-80}"
ACTION_GOTO_LABEL="${TMUX_NOTIFY_ACTION_GOTO_LABEL:-Jump}"
ACTION_DISMISS_LABEL="${TMUX_NOTIFY_ACTION_DISMISS_LABEL:-Dismiss}"
FOCUS_WINDOW_ID="${TMUX_NOTIFY_WINDOW_ID:-}"

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
WRAP_COLS="$DEFAULT_WRAP_COLS"
DETACH=0
SENDER_CLIENT_PID=""
SENDER_CLIENT_TTY=""
TMUX_SOCKET=""
PANE_ID=""

print_usage() {
    cat <<EOF
Usage:
  $0 <session>:<window>.<pane> [title] [body]
  $0 --target <session:window.pane> [--title <title>] [--body <body>]
  $0 --target <pane_id> [--title <title>] [--body <body>]     (pane id like %1)

Options:
  --list               List available panes
  --no-activate        Do not focus the terminal window
  --class <CLASS>      Use a single terminal window class
  --classes <A,B>      Comma-separated terminal window classes (default: $DEFAULT_CLASS_LIST)
  --sender-tty <TTY>   Prefer switching this tmux client (e.g. /dev/ttys001)
  --sender-pid <PID>   Prefer focusing terminal by this pid
  --tmux-socket <PATH> Use a specific tmux server socket (passed to tmux -S)
  --dry-run            Print what would happen and exit
  --quiet              Suppress non-error output
  --timeout <ms>       Notification timeout in ms (default 10000; 0 may mean "sticky" depending on daemon)
  --max-title <n>      Max title length (0 = no truncation)
  --max-body <n>       Max body length (0 = no truncation)
  --wrap-cols <n>      Wrap body text to <n> columns (default: $DEFAULT_WRAP_COLS; 0 = no wrapping)
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

wrap_text() {
    local cols="$1"
    local text="$2"

    if [ "$cols" -le 0 ]; then
        printf '%s' "$text"
        return
    fi

    if command -v python3 >/dev/null 2>&1; then
        local out=""
        set +e
        out="$(printf '%s' "$text" | python3 -c 'import sys, unicodedata
cols = int(sys.argv[1])
text = sys.stdin.read()

def ch_width(ch: str) -> int:
    if not ch:
        return 0
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1

def wrap_line(line: str):
    if cols <= 0:
        return [line]
    if line == "":
        return [""]
    res = []
    i = 0
    n = len(line)
    while i < n:
        w = 0
        last_space = -1
        j = i
        while j < n:
            ch = line[j]
            if ch.isspace():
                last_space = j
            w += ch_width(ch)
            if w > cols:
                break
            j += 1

        if j >= n:
            res.append(line[i:n].rstrip())
            break

        if last_space >= i and last_space < j:
            res.append(line[i:last_space].rstrip())
            i = last_space
            while i < n and line[i].isspace():
                i += 1
        else:
            if j == i:
                j = i + 1
            res.append(line[i:j].rstrip())
            i = j

    return res

out_lines = []
for line in text.split("\\n"):
    out_lines.extend(wrap_line(line))
sys.stdout.write("\\n".join(out_lines))
' "$cols")"
        local status=$?
        set -e
        if [ $status -eq 0 ]; then
            printf '%s' "$out"
            return
        fi
    fi

    if command -v fold >/dev/null 2>&1; then
        printf '%s' "$text" | fold -s -w "$cols"
        return
    fi

    printf '%s' "$text"
}

is_wayland_session() {
    if [ -n "${XDG_SESSION_TYPE:-}" ]; then
        [ "$XDG_SESSION_TYPE" = "wayland" ]
        return
    fi
    [ -n "${WAYLAND_DISPLAY:-}" ]
}

find_window_id_by_pid_tree() {
    local pid="${1:-}"
    if ! is_integer "$pid"; then
        return 1
    fi

    local current_pid="$pid"
    local depth=0
    while is_integer "$current_pid" && [ "$current_pid" -gt 1 ] && [ "$depth" -lt 50 ]; do
        local ids=""
        ids="$(xdotool search --onlyvisible --pid "$current_pid" 2>/dev/null || true)"
        local wid=""
        if IFS= read -r wid <<<"$ids"; then
            if is_integer "$wid"; then
                printf '%s' "$wid"
                return 0
            fi
        fi

        current_pid="$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d ' ' || true)"
        depth=$((depth + 1))
    done
    return 1
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

    local wid
    wid=""

    if is_integer "$FOCUS_WINDOW_ID"; then
        wid="$FOCUS_WINDOW_ID"
    fi

    if [ -z "$wid" ]; then
        if is_integer "$SENDER_CLIENT_PID"; then
            wid="$(find_window_id_by_pid_tree "$SENDER_CLIENT_PID" 2>/dev/null || true)"
        fi
    fi

    if [ -z "$wid" ] && is_integer "${WINDOWID:-}"; then
        wid="$WINDOWID"
    fi

    if [ -z "$wid" ]; then
        local class_list="${WINDOW_CLASS_LIST:-$WINDOW_CLASS}"
        local class_item
        IFS=',' read -r -a class_array <<< "$class_list"
        for class_item in "${class_array[@]}"; do
            class_item="$(trim_ws "$class_item")"
            [ -n "$class_item" ] || continue
            local ids=""
            ids="$(xdotool search --onlyvisible --class "$class_item" 2>/dev/null || true)"
            if IFS= read -r wid <<<"$ids"; then
                :
            else
                wid=""
            fi
            if [ -n "$wid" ]; then
                break
            fi
        done
    fi

    if [ -z "$wid" ]; then
        warn "No terminal window found to focus (try TMUX_NOTIFY_WINDOW_ID, --class/--classes, or --no-activate)"
        return
    fi
    xdotool windowactivate "$wid" 2>/dev/null || warn "Failed to activate terminal window"
}

jump_to_pane() {
    ensure_target_resolved
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
            --sender-tty)
                shift
                [ $# -gt 0 ] || die "--sender-tty requires an argument"
                SENDER_CLIENT_TTY="$1"
                ;;
            --sender-pid)
                shift
                [ $# -gt 0 ] || die "--sender-pid requires an argument"
                SENDER_CLIENT_PID="$1"
                ;;
            --tmux-socket)
                shift
                [ $# -gt 0 ] || die "--tmux-socket requires an argument"
                TMUX_SOCKET="$1"
                TMUX_NOTIFY_TMUX_SOCKET="$1"
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
            --wrap-cols)
                shift
                [ $# -gt 0 ] || die "--wrap-cols requires an argument"
                WRAP_COLS="$1"
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
if ! [[ "$WRAP_COLS" =~ ^[0-9]+$ ]]; then
    die "--wrap-cols must be a non-negative integer"
fi

TITLE="$(truncate_text "$MAX_TITLE" "$TITLE")"
BODY="$(truncate_text "$MAX_BODY" "$BODY")"
BODY="$(wrap_text "$WRAP_COLS" "$BODY")"

if [ "$DRY_RUN" -eq 1 ]; then
    parse_target "$TARGET"
    if [ -n "${PANE_ID:-}" ]; then
        log "Target: $PANE_ID"
        if tmux_cmd list-sessions >/dev/null 2>&1; then
            ensure_target_resolved
            log "Resolved target: $SESSION:$WINDOW.$PANE"
        else
            log "Resolved target: (tmux server not running)"
        fi
    else
        log "Target: $SESSION:$WINDOW.$PANE"
    fi
    log "Title: $TITLE"
    log "Body: $BODY"
    log "Window classes: ${WINDOW_CLASS_LIST:-$WINDOW_CLASS}"
    if is_integer "$FOCUS_WINDOW_ID"; then
        log "Focus window id: $FOCUS_WINDOW_ID"
    fi
    if is_integer "$SENDER_CLIENT_PID"; then
        log "Sender tmux client pid: $SENDER_CLIENT_PID"
    fi
    if [ -n "${SENDER_CLIENT_TTY:-}" ]; then
        log "Sender tmux client tty: $SENDER_CLIENT_TTY"
    fi
    if [ -n "${TMUX_SOCKET:-}" ]; then
        log "tmux socket: $TMUX_SOCKET"
    fi
    log "Focus terminal: $([ "$NO_ACTIVATE" -eq 1 ] && echo "no" || echo "yes")"
    log "Timeout: ${TIMEOUT:-default}"
    log "Max title length: $MAX_TITLE"
    log "Max body length: $MAX_BODY"
    log "Wrap columns: $WRAP_COLS"
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
