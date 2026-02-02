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
DEFAULT_DEDUPE_MS="${TMUX_NOTIFY_DEDUPE_MS:-2000}"
DEFAULT_UI="${TMUX_NOTIFY_UI:-notification}"
ACTION_GOTO_LABEL="${TMUX_NOTIFY_ACTION_GOTO_LABEL:-Jump}"
ACTION_DISMISS_LABEL="${TMUX_NOTIFY_ACTION_DISMISS_LABEL:-Dismiss}"
FOCUS_WINDOW_ID="${TMUX_NOTIFY_WINDOW_ID:-}"

TARGET=""
TITLE=""
BODY=""
WINDOW_CLASS="$DEFAULT_CLASS"
WINDOW_CLASS_LIST="$DEFAULT_CLASS_LIST"
NO_ACTIVATE=0
FOCUS_ONLY=0
LIST_ONLY=0
DRY_RUN=0
QUIET=0
TIMEOUT="$DEFAULT_TIMEOUT"
MAX_TITLE="$DEFAULT_MAX_TITLE"
MAX_BODY="$DEFAULT_MAX_BODY"
WRAP_COLS="$DEFAULT_WRAP_COLS"
DEDUPE_MS="$DEFAULT_DEDUPE_MS"
DETACH=0
UI="$DEFAULT_UI"
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
  --focus-only         On click, only focus the terminal window (no tmux required)
  --no-activate        Do not focus the terminal window
  --class <CLASS>      Use a single terminal window class
  --classes <A,B>      Comma-separated terminal window classes (default: $DEFAULT_CLASS_LIST)
  --sender-tty <TTY>   Prefer switching this tmux client (e.g. /dev/ttys001)
  --sender-pid <PID>   Prefer focusing terminal by this pid
  --tmux-socket <PATH> Use a specific tmux server socket (passed to tmux -S)
  --dry-run            Print what would happen and exit
  --quiet              Suppress non-error output
  --timeout <ms>       Notification timeout in ms (default 10000; 0 may mean "sticky" depending on daemon)
  --ui <notification|dialog>
                      notification: desktop notification via notify-send (default)
                      dialog: modal prompt with buttons (requires zenity/kdialog/yad)
  --max-title <n>      Max title length (0 = no truncation)
  --max-body <n>       Max body length (0 = no truncation)
  --wrap-cols <n>      Wrap body text to <n> columns (default: $DEFAULT_WRAP_COLS; 0 = no wrapping)
  --dedupe-ms <ms>     Suppress duplicate notifications within this window (0 = disabled; default: $DEFAULT_DEDUPE_MS)
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

pick_dialog_backend() {
    if command -v zenity >/dev/null 2>&1; then
        printf '%s' "zenity"
        return 0
    fi
    if command -v kdialog >/dev/null 2>&1; then
        printf '%s' "kdialog"
        return 0
    fi
    if command -v yad >/dev/null 2>&1; then
        printf '%s' "yad"
        return 0
    fi
    return 1
}

dialog_stderr_indicates_failure() {
    local err="${1:-}"
    if [ -z "$err" ]; then
        return 1
    fi

    # Keep this conservative: only treat as "backend failure" (not user dismiss)
    # when stderr strongly indicates a missing/unusable GUI session (DISPLAY/DBus).
    local err_lc=""
    err_lc="${err,,}"
    case "$err_lc" in
        *"cannot open display"*|*"could not connect to display"*|*"cannot connect to x server"*|*"no protocol specified"*|*"authorization required"*|*"no x11"*|*"x11 connection rejected"*)
            return 0
            ;;
        *"failed to connect to bus"*|*"unable to connect to dbus"*|*"unable to autolaunch a dbus-daemon"*|*"org.freedesktop.dbus"*|*"qdbusconnection:"*"could not connect"*|*"qdbusconnection:"*"failed to connect"*)
            return 0
            ;;
    esac

    return 1
}

timeout_ms_to_seconds() {
    local ms="${1:-}"
    if [ -z "$ms" ] || ! is_integer "$ms"; then
        return 1
    fi
    if [ "$ms" -le 0 ]; then
        return 1
    fi
    # Round up so we don't cut time short.
    printf '%s' "$(( (ms + 999) / 1000 ))"
}

require_tools() {
    if [ "$UI" = "dialog" ]; then
        if ! pick_dialog_backend >/dev/null 2>&1; then
            warn "Dialog mode requested but no dialog backend found (zenity/kdialog/yad); falling back to notification"
            UI="notification"
        fi
    fi

    if [ "$UI" = "notification" ]; then
        require_tool notify-send
    fi
    if [ "$FOCUS_ONLY" -eq 0 ]; then
        require_tool tmux
    fi
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

send_dialog() {
    local backend=""
    backend="$(pick_dialog_backend 2>/dev/null || true)"
    if [ -z "$backend" ]; then
        return 1
    fi

    local timeout_sec=""
    timeout_sec="$(timeout_ms_to_seconds "$TIMEOUT" 2>/dev/null || true)"

    set +e
    case "$backend" in
        zenity)
            local args=(--question --title="$TITLE" --text="$BODY" --ok-label="$ACTION_GOTO_LABEL" --cancel-label="$ACTION_DISMISS_LABEL")
            if [ -n "$timeout_sec" ]; then
                args+=(--timeout="$timeout_sec")
            fi
            local err=""
            err="$(zenity "${args[@]}" 2>&1 1>/dev/null)"
            local status=$?
            set -e
            if [ $status -eq 0 ]; then
                echo "goto"
                return 0
            fi
            if [ $status -eq 1 ]; then
                # Cancel/close/timeout.
                if dialog_stderr_indicates_failure "$err"; then
                    err="${err//$'\n'/; }"
                    warn "zenity failed: ${err:-exit=$status}"
                    return 1
                fi
                echo "dismiss"
                return 0
            fi
            err="${err//$'\n'/; }"
            warn "zenity failed: ${err:-exit=$status}"
            return 1
            ;;
        kdialog)
            local args=(--title "$TITLE" --yesno "$BODY" --yes-label "$ACTION_GOTO_LABEL" --no-label "$ACTION_DISMISS_LABEL")
            if [ -n "$timeout_sec" ]; then
                if kdialog --help 2>/dev/null | grep -q -- "--timeout"; then
                    args+=(--timeout "$timeout_sec")
                else
                    warn "kdialog does not support --timeout; ignoring timeout in dialog mode"
                fi
            fi
            local err=""
            err="$(kdialog "${args[@]}" 2>&1 1>/dev/null)"
            local status=$?
            set -e
            if [ $status -eq 0 ]; then
                echo "goto"
                return 0
            fi
            if [ $status -eq 1 ] || [ $status -eq 255 ]; then
                if dialog_stderr_indicates_failure "$err"; then
                    err="${err//$'\n'/; }"
                    warn "kdialog failed: ${err:-exit=$status}"
                    return 1
                fi
                echo "dismiss"
                return 0
            fi
            err="${err//$'\n'/; }"
            warn "kdialog failed: ${err:-exit=$status}"
            return 1
            ;;
        yad)
            local args=(--question --title="$TITLE" --text="$BODY" --button="$ACTION_GOTO_LABEL:0" --button="$ACTION_DISMISS_LABEL:1")
            if [ -n "$timeout_sec" ]; then
                args+=(--timeout="$timeout_sec")
            fi
            local err=""
            err="$(yad "${args[@]}" 2>&1 1>/dev/null)"
            local status=$?
            set -e
            if [ $status -eq 0 ]; then
                echo "goto"
                return 0
            fi
            if [ $status -eq 1 ] || [ $status -eq 252 ] || [ $status -eq 255 ]; then
                if dialog_stderr_indicates_failure "$err"; then
                    err="${err//$'\n'/; }"
                    warn "yad failed: ${err:-exit=$status}"
                    return 1
                fi
                echo "dismiss"
                return 0
            fi
            err="${err//$'\n'/; }"
            warn "yad failed: ${err:-exit=$status}"
            return 1
            ;;
        *)
            set -e
            return 1
            ;;
    esac
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

    local old_trap_exit=""
    local old_trap_int=""
    local old_trap_term=""
    local old_trap_hup=""
    old_trap_exit="$(trap -p EXIT 2>/dev/null || true)"
    old_trap_int="$(trap -p INT 2>/dev/null || true)"
    old_trap_term="$(trap -p TERM 2>/dev/null || true)"
    old_trap_hup="$(trap -p HUP 2>/dev/null || true)"

    trap '[ -n "${errfile:-}" ] && rm -f "$errfile" 2>/dev/null || true' EXIT
    trap '[ -n "${errfile:-}" ] && rm -f "$errfile" 2>/dev/null || true; exit 130' INT
    trap '[ -n "${errfile:-}" ] && rm -f "$errfile" 2>/dev/null || true; exit 143' TERM
    trap '[ -n "${errfile:-}" ] && rm -f "$errfile" 2>/dev/null || true; exit 129' HUP

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

    if [ -n "$old_trap_exit" ]; then eval "$old_trap_exit"; else trap - EXIT; fi
    if [ -n "$old_trap_int" ]; then eval "$old_trap_int"; else trap - INT; fi
    if [ -n "$old_trap_term" ]; then eval "$old_trap_term"; else trap - TERM; fi
    if [ -n "$old_trap_hup" ]; then eval "$old_trap_hup"; else trap - HUP; fi

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
    if dedupe_should_suppress "$DEDUPE_MS" "target=$TARGET"$'\n'"title=$TITLE"$'\n'"body=$BODY"$'\n'; then
        log "Duplicate notification suppressed"
        return
    fi

    if [ "$FOCUS_ONLY" -eq 0 ]; then
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
    else
        if [ -z "$SENDER_CLIENT_PID" ] && is_integer "${PPID:-}"; then
            SENDER_CLIENT_PID="$PPID"
        fi
    fi

    local action
    if [ "$UI" = "dialog" ]; then
        local dialog_status=0
        set +e
        action="$(send_dialog)"
        dialog_status=$?
        set -e
        if [ $dialog_status -ne 0 ] || [ -z "$action" ]; then
            if command -v notify-send >/dev/null 2>&1; then
                action="$(send_notification)"
            else
                warn "Dialog failed but notify-send is unavailable; cannot fall back to notification"
                action="none"
            fi
        fi
    else
        action="$(send_notification)"
    fi

    if [ "$action" = "goto" ]; then
        activate_terminal
        if [ "$FOCUS_ONLY" -eq 0 ]; then
            jump_to_pane
        else
            log "Focused terminal"
        fi
    elif [ "$action" = "dismiss" ]; then
        log "Dismissed"
    else
        log "Notification sent"
    fi
}

spawn_detached_self() {
    local self_path
    self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    if command -v setsid >/dev/null 2>&1; then
        TMUX_NOTIFY_ALREADY_DETACHED=1 setsid "$self_path" "$@" >/dev/null 2>&1 &
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        # Fork + setsid so the child isn't in the hook runner's process group.
        if python3 - "$self_path" "$@" >/dev/null 2>&1 <<'PY'
import os
import sys

self_path = sys.argv[1]
args = sys.argv[1:]

pid = os.fork()
if pid != 0:
    raise SystemExit(0)

os.setsid()
os.environ["TMUX_NOTIFY_ALREADY_DETACHED"] = "1"
os.execv(self_path, args)
PY
        then
            return 0
        fi
    fi

    if command -v nohup >/dev/null 2>&1; then
        TMUX_NOTIFY_ALREADY_DETACHED=1 nohup "$self_path" "$@" >/dev/null 2>&1 &
        return 0
    fi

    return 1
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
            --focus-only)
                FOCUS_ONLY=1
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
            --wrap-cols)
                shift
                [ $# -gt 0 ] || die "--wrap-cols requires an argument"
                WRAP_COLS="$1"
                ;;
            --dedupe-ms)
                shift
                [ $# -gt 0 ] || die "--dedupe-ms requires an argument"
                DEDUPE_MS="$1"
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

if [ -z "$TARGET" ] && [ "$FOCUS_ONLY" -eq 0 ]; then
    print_usage
    echo ""
    echo "Available tmux panes:"
    list_panes
    exit 1
fi

TITLE="${TITLE:-$DEFAULT_TITLE}"
if [ "$FOCUS_ONLY" -eq 1 ]; then
    BODY="${BODY:-Click to focus terminal}"
else
    BODY="${BODY:-Click to jump to $TARGET}"
fi

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
if ! [[ "$WRAP_COLS" =~ ^[0-9]+$ ]]; then
    die "--wrap-cols must be a non-negative integer"
fi
if ! [[ "$DEDUPE_MS" =~ ^[0-9]+$ ]]; then
    die "--dedupe-ms must be a non-negative integer (ms)"
fi

TITLE="$(truncate_text "$MAX_TITLE" "$TITLE")"
BODY="$(truncate_text "$MAX_BODY" "$BODY")"
BODY="$(wrap_text "$WRAP_COLS" "$BODY")"

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$FOCUS_ONLY" -eq 1 ]; then
        log "Mode: focus-only"
    else
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
    fi
    log "Title: $TITLE"
    log "Body: $BODY"
    log "UI: $UI"
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
    log "Dedupe window (ms): $DEDUPE_MS"
    exit 0
fi

require_tools
if [ "$FOCUS_ONLY" -eq 0 ]; then
    parse_target "$TARGET"
    validate_target_exists
fi

if [ "$DETACH" -eq 1 ]; then
    # Many hook runners kill the entire process group right after the hook exits.
    # `notify-send --wait` must stay alive to handle actions, so detach into a new
    # session when possible.
    if ! is_truthy "${TMUX_NOTIFY_ALREADY_DETACHED:-0}"; then
        child_args=()
        if [ "$FOCUS_ONLY" -eq 1 ]; then
            child_args+=(--focus-only)
        else
            child_args+=(--target "$TARGET")
        fi
        child_args+=(--title "$TITLE" --body "$BODY")
        child_args+=(--timeout "$TIMEOUT" --max-title "$MAX_TITLE" --max-body "$MAX_BODY")
        child_args+=(--wrap-cols "$WRAP_COLS" --dedupe-ms "$DEDUPE_MS")
        if [ "$NO_ACTIVATE" -eq 1 ]; then
            child_args+=(--no-activate)
        fi
        if [ -n "${WINDOW_CLASS_LIST:-$WINDOW_CLASS}" ]; then
            child_args+=(--classes "${WINDOW_CLASS_LIST:-$WINDOW_CLASS}")
        fi
        if [ -n "${SENDER_CLIENT_TTY:-}" ]; then
            child_args+=(--sender-tty "$SENDER_CLIENT_TTY")
        fi
        if is_integer "${SENDER_CLIENT_PID:-}"; then
            child_args+=(--sender-pid "$SENDER_CLIENT_PID")
        fi
        if [ -n "${TMUX_SOCKET:-}" ]; then
            child_args+=(--tmux-socket "$TMUX_SOCKET")
        fi
        if [ "$QUIET" -eq 1 ]; then
            child_args+=(--quiet)
        fi
        child_args+=(--ui "$UI")
        child_args+=(--detach)

        if spawn_detached_self "${child_args[@]}"; then
            exit 0
        fi

        # Fallback: best-effort background; may still be killed by some hook runners.
        (handle_action) >/dev/null 2>&1 &
        exit 0
    fi

    # Already detached: do the real work.
    handle_action
    exit 0
fi

handle_action
