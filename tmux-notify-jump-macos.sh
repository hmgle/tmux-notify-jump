#!/usr/bin/env bash
set -euo pipefail

# Notification click callbacks may run with a restricted GUI PATH.
# Under `set -u`, `$PATH` may be unset, so avoid expanding it directly.
if [ -n "${PATH:-}" ]; then
    export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
else
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-notify-jump-lib.sh
. "$SCRIPT_DIR/tmux-notify-jump-lib.sh"

load_user_config

DEFAULT_TITLE="Task complete"
DEFAULT_TIMEOUT="${TMUX_NOTIFY_TIMEOUT:-10000}"
DEFAULT_MAX_TITLE="${TMUX_NOTIFY_MAX_TITLE:-80}"
DEFAULT_MAX_BODY="${TMUX_NOTIFY_MAX_BODY:-200}"
DEFAULT_DEDUPE_MS="${TMUX_NOTIFY_DEDUPE_MS:-2000}"
ACTION_GOTO_LABEL="${TMUX_NOTIFY_ACTION_GOTO_LABEL:-Jump}"
ACTION_DISMISS_LABEL="${TMUX_NOTIFY_ACTION_DISMISS_LABEL:-Dismiss}"
DEFAULT_UI="${TMUX_NOTIFY_UI:-notification}"
BUILTIN_DEFAULT_BUNDLE_ID="com.github.wez.wezterm"
BUILTIN_DEFAULT_BUNDLE_ID_LIST="com.github.wez.wezterm,com.googlecode.iterm2,com.apple.Terminal"
BUNDLE_ID_EXPLICIT=0
if [ -n "${TMUX_NOTIFY_BUNDLE_IDS:-}" ] || [ -n "${TMUX_NOTIFY_BUNDLE_ID:-}" ]; then
    BUNDLE_ID_EXPLICIT=1
fi
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
FOCUS_ONLY=0
LIST_ONLY=0
DRY_RUN=0
QUIET=0
TIMEOUT="$DEFAULT_TIMEOUT"
MAX_TITLE="$DEFAULT_MAX_TITLE"
MAX_BODY="$DEFAULT_MAX_BODY"
DEDUPE_MS="$DEFAULT_DEDUPE_MS"
UI="$DEFAULT_UI"
DETACH=0
SENDER_PID=""
SENDER_CLIENT_PID=""
SENDER_CLIENT_TTY=""
ACTION_CALLBACK=0
ACTION_CALLBACK_ARG=""
TMUX_SOCKET=""
PANE_ID=""

# Callback-specific variables (passed via --cb-* args from -execute)
CB_TARGET=""
CB_SENDER_TTY=""
CB_SENDER_PID=""
CB_FOCUS_ONLY=""
CB_NO_ACTIVATE=""
CB_TMUX_SOCKET=""
CB_BUNDLE_IDS=""

print_usage() {
    cat <<EOF
Usage:
  $0 <session>:<window>.<pane> [title] [body]
  $0 --target <session:window.pane> [--title <title>] [--body <body>]
  $0 --target <pane_id> [--title <title>] [--body <body>]     (pane id like %1)
  $0 --focus-only [--title <title>] [--body <body>]

Options:
  --list               List available panes
  --focus-only         On click, only focus the terminal app/window (no tmux required)
  --no-activate        Do not focus the terminal window
  --bundle-id <ID>     Use a single terminal bundle id
  --bundle-ids <A,B>   Comma-separated bundle ids (default: $BUNDLE_ID_LIST)
  --sender-tty <TTY>   Prefer switching this tmux client (e.g. /dev/ttys001)
  --sender-pid <PID>   Prefer focusing terminal by this pid tree (default: \$PPID)
  --tmux-socket <PATH> Use a specific tmux server socket (passed to tmux -S)
  --dry-run            Print what would happen and exit
  --quiet              Suppress non-error output
  --timeout <ms>       Notification timeout in ms (default 10000)
  --ui <notification|dialog>
                      notification: desktop notification (default)
                      dialog: always-wait modal prompt with buttons
  --max-title <n>      Max title length (0 = no truncation)
  --max-body <n>       Max body length (0 = no truncation)
  --dedupe-ms <ms>     Suppress duplicate notifications within this window (0 = disabled; default: $DEFAULT_DEDUPE_MS)
  --detach             Detach and return immediately (handles click in background)
  -h, --help           Show help

Examples:
  $0 "2:1.0" "Build finished" "Click to jump to the pane"
  $0 --target "work:0.1" --title "Task complete"
EOF
}

require_tools() {
    if [ "$FOCUS_ONLY" -eq 0 ]; then
        require_tool tmux
    fi
    if [ "$UI" = "dialog" ]; then
        require_tool osascript
        return
    fi
    require_tool terminal-notifier
    if [ "$NO_ACTIVATE" -eq 0 ]; then
        require_tool osascript
    fi
}

bundle_id_from_process_name() {
    local name_lc="$1"
    case "$name_lc" in
        *kitty*)
            echo "net.kovidgoyal.kitty"
            return 0
            ;;
        wezterm*|*wezterm*)
            echo "com.github.wez.wezterm"
            return 0
            ;;
        iterm2*|*iterm2*)
            echo "com.googlecode.iterm2"
            return 0
            ;;
        terminal)
            echo "com.apple.Terminal"
            return 0
            ;;
        alacritty*|*alacritty*)
            echo "org.alacritty"
            return 0
            ;;
        ghostty*|*ghostty*)
            echo "com.mitchellh.ghostty"
            return 0
            ;;
    esac
    return 1
}

detect_bundle_id_from_pid_tree() {
    local pid="${1:-}"
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if ! command -v lsappinfo >/dev/null 2>&1; then
        return 1
    fi

    local steps=0
    while [ "$pid" -gt 1 ] && [ "$steps" -lt 40 ]; do
        local info=""
        info="$(lsappinfo info -only bundleid -pid "$pid" 2>/dev/null || true)"
        info="$(printf '%s' "$info" | tr '\n' ' ')"
        local bid=""
        bid="$(printf '%s' "$info" | sed -nE 's/.*[Bb]undleid=\"([^\"]+)\".*/\\1/p')"
        bid="$(trim_ws "$bid")"
        if [ -n "$bid" ]; then
            printf '%s' "$bid"
            return 0
        fi

        local ppid=""
        ppid="$(ps -p "$pid" -o ppid= 2>/dev/null || true)"
        ppid="$(trim_ws "$ppid")"
        if ! [[ "$ppid" =~ ^[0-9]+$ ]]; then
            break
        fi
        pid="$ppid"
        steps=$((steps + 1))
    done
    return 1
}

detect_terminal_bundle_id_from_pid() {
    local pid="${1:-}"
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    local steps=0
    while [ "$pid" -gt 1 ] && [ "$steps" -lt 30 ]; do
        local comm=""
        comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        comm="$(trim_ws "$comm")"
        if [ -n "$comm" ]; then
            local base=""
            base="$(basename "$comm" 2>/dev/null || printf '%s' "$comm")"
            local base_lc=""
            base_lc="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
            local bid=""
            bid="$(bundle_id_from_process_name "$base_lc" 2>/dev/null || true)"
            if [ -n "$bid" ]; then
                printf '%s' "$bid"
                return 0
            fi
        fi

        local ppid=""
        ppid="$(ps -p "$pid" -o ppid= 2>/dev/null || true)"
        ppid="$(trim_ws "$ppid")"
        if ! [[ "$ppid" =~ ^[0-9]+$ ]]; then
            break
        fi
        pid="$ppid"
        steps=$((steps + 1))
    done
    return 1
}

bundle_id_list_contains() {
    local list="${1:-}"
    local needle="${2:-}"
    [ -n "$list" ] || return 1
    [ -n "$needle" ] || return 1

    local item=""
    IFS=',' read -r -a items <<<"$list"
    for item in "${items[@]}"; do
        item="$(trim_ws "$item")"
        [ -n "$item" ] || continue
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

autodetect_sender_terminal_bundle_ids() {
    if [ "$NO_ACTIVATE" -eq 1 ]; then
        return
    fi
    if [ "$BUNDLE_ID_EXPLICIT" -eq 1 ]; then
        return
    fi
    local sender_pid="${SENDER_CLIENT_PID:-}"
    if [ -n "${SENDER_PID:-}" ] && [[ "$SENDER_PID" =~ ^[0-9]+$ ]]; then
        sender_pid="$SENDER_PID"
    fi
    if [ -z "${sender_pid:-}" ]; then
        return
    fi

    local detected=""
    detected="$(detect_bundle_id_from_pid_tree "$sender_pid" 2>/dev/null || true)"
    if [ -z "$detected" ]; then
        detected="$(detect_terminal_bundle_id_from_pid "$sender_pid" 2>/dev/null || true)"
    fi
    [ -n "$detected" ] || return

    local current="${BUNDLE_ID_LIST:-$BUNDLE_ID}"
    current="$(trim_ws "$current")"

    if [ -z "$current" ]; then
        BUNDLE_ID_LIST="$detected"
    elif bundle_id_list_contains "$current" "$detected"; then
        BUNDLE_ID_LIST="$current"
    else
        BUNDLE_ID_LIST="$detected,$current"
    fi
    BUNDLE_ID=""
    log_debug "auto-detected terminal bundle id: $detected (sender pid=$sender_pid)"
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
    local ms="${1:-}"
    if ! is_integer "$ms" || [ "$ms" -le 0 ]; then
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
    output="$(terminal-notifier "${args[@]}" 2>/dev/null)"
    local status=$?
    set -e

    if [ "$status" -ne 0 ]; then
        if [ -z "$output" ]; then
            # True startup/exec failure (no callback payload at all).
            log_debug "terminal-notifier -wait failed (status=$status)"
            warn "Failed to send notification"
            return 1
        fi
        # Non-zero with payload can still mean the notification was shown
        # (e.g. timeout/close); keep parsing instead of re-sending.
        log_debug "terminal-notifier -wait exited non-zero with payload (status=$status); parsing output"
    fi

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
    exec_cmd+=" --cb-sender-pid $(printf '%q' "${SENDER_PID:-}")"
    exec_cmd+=" --cb-focus-only $(printf '%q' "$FOCUS_ONLY")"
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
        log_debug "terminal-notifier failed (status=$status)"
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

spawn_detached_self() {
    local self_path
    self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    if [ ! -x "$self_path" ]; then
        log_debug "detach: self path not executable: $self_path"
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        log_debug "detach: spawning detached session via python3 setsid"
        # Fork + setsid so the child isn't in the hook runner's process group.
        # Use a pipe to detect early failures (e.g., setsid/exec errors) before reporting success.
        if python3 - "$self_path" "$@" >/dev/null 2>&1 <<'PY'
import fcntl
import os
import select
import sys
import time

self_path = sys.argv[1]
args = sys.argv[1:]  # argv[0] must be the executable path

read_fd, write_fd = os.pipe()

# Close write end on successful exec; parent will see EOF.
flags = fcntl.fcntl(write_fd, fcntl.F_GETFD)
fcntl.fcntl(write_fd, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)

pid = os.fork()
if pid != 0:
    os.close(write_fd)

    # Wait briefly for the child to either exec (EOF) or report an error.
    deadline = time.time() + 0.5
    data = b""
    while True:
        timeout = deadline - time.time()
        if timeout <= 0:
            break
        readable, _, _ = select.select([read_fd], [], [], timeout)
        if not readable:
            break
        chunk = os.read(read_fd, 4096)
        if not chunk:
            os.close(read_fd)
            raise SystemExit(0)
        data += chunk
        # Any data implies a failure; no need to keep waiting.
        break

    os.close(read_fd)
    raise SystemExit(1 if data else 0)

os.close(read_fd)

try:
    os.setsid()
    os.environ["TMUX_NOTIFY_ALREADY_DETACHED"] = "1"
    os.execv(self_path, args)
except BaseException as e:
    try:
        os.write(write_fd, (f"{e}\\n").encode("utf-8", "replace"))
    finally:
        os._exit(1)
PY
        then
            return 0
        fi
        log_debug "detach: python3 setsid spawn failed"
        return 1
    fi

    # Fallback: best-effort background; may still be killed by some hook runners.
    log_debug "detach: python3 not found; using nohup fallback"
    if command -v nohup >/dev/null 2>&1; then
        TMUX_NOTIFY_ALREADY_DETACHED=1 nohup "$self_path" "$@" >/dev/null 2>&1 &
        return 0
    fi
    return 1
}

send_notification() {
    if [ "$UI" = "dialog" ]; then
        send_dialog
        return
    fi
    if [ "$DETACH" -eq 0 ] && supports_wait; then
        local action=""
        local wait_status=0
        set +e
        action="$(send_notification_wait)"
        wait_status=$?
        set -e
        if [ "$wait_status" -eq 0 ] && [ -n "$action" ]; then
            echo "$action"
            return
        fi
        log_debug "wait-mode notification unavailable; falling back to -execute"
        send_notification_execute
        return
    fi
    send_notification_execute
}

handle_action_callback() {
    TARGET="${CB_TARGET:-}"
    SENDER_CLIENT_TTY="${CB_SENDER_TTY:-}"
    SENDER_PID="${CB_SENDER_PID:-}"
    FOCUS_ONLY="${CB_FOCUS_ONLY:-0}"
    NO_ACTIVATE="${CB_NO_ACTIVATE:-0}"
    TMUX_SOCKET="${CB_TMUX_SOCKET:-}"
    BUNDLE_ID_LIST="${CB_BUNDLE_IDS:-$BUNDLE_ID_LIST}"
    TMUX_NOTIFY_TMUX_SOCKET="${TMUX_SOCKET:-}"

    log_debug "action-callback: focus_only=$FOCUS_ONLY target=$TARGET sender_tty=$SENDER_CLIENT_TTY sender_pid=$SENDER_PID no_activate=$NO_ACTIVATE tmux_socket=$TMUX_SOCKET"

    if [ "$FOCUS_ONLY" -eq 1 ]; then
        if [ -n "${SENDER_PID:-}" ] && [[ "$SENDER_PID" =~ ^[0-9]+$ ]]; then
            SENDER_CLIENT_PID="$SENDER_PID"
        fi
        autodetect_sender_terminal_bundle_ids
        activate_terminal
        exit 0
    fi

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
        if [ -z "$TMUX_SOCKET" ]; then
            TMUX_SOCKET="$(get_tmux_socket_from_env 2>/dev/null || true)"
        fi
        SENDER_PID="${SENDER_PID:-$SENDER_CLIENT_PID}"
        autodetect_sender_terminal_bundle_ids
    else
        if [ -z "$SENDER_PID" ]; then
            if [[ "${PPID:-}" =~ ^[0-9]+$ ]]; then
                SENDER_PID="$PPID"
            else
                SENDER_PID="$$"
            fi
        fi
        if [[ "${SENDER_PID:-}" =~ ^[0-9]+$ ]]; then
            SENDER_CLIENT_PID="$SENDER_PID"
        fi
        autodetect_sender_terminal_bundle_ids
    fi

    local action
    action="$(send_notification)"

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
        # First try macOS-specific options
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
            --bundle-id)
                shift
                [ $# -gt 0 ] || die "--bundle-id requires an argument"
                BUNDLE_ID="$1"
                BUNDLE_ID_LIST="$1"
                BUNDLE_ID_EXPLICIT=1
                shift
                continue
                ;;
            --bundle-ids)
                shift
                [ $# -gt 0 ] || die "--bundle-ids requires an argument"
                BUNDLE_ID_LIST="$1"
                BUNDLE_ID=""
                BUNDLE_ID_EXPLICIT=1
                shift
                continue
                ;;
            --sender-pid)
                shift
                [ $# -gt 0 ] || die "--sender-pid requires an argument"
                SENDER_PID="$1"
                shift
                continue
                ;;
            # Callback-specific arguments (used internally by -execute)
            --cb-target)
                shift
                [ $# -gt 0 ] || die "--cb-target requires an argument"
                CB_TARGET="$1"
                shift
                continue
                ;;
            --cb-sender-tty)
                shift
                [ $# -gt 0 ] || die "--cb-sender-tty requires an argument"
                CB_SENDER_TTY="$1"
                shift
                continue
                ;;
            --cb-sender-pid)
                shift
                [ $# -gt 0 ] || die "--cb-sender-pid requires an argument"
                CB_SENDER_PID="$1"
                shift
                continue
                ;;
            --cb-focus-only)
                shift
                [ $# -gt 0 ] || die "--cb-focus-only requires an argument"
                CB_FOCUS_ONLY="$1"
                shift
                continue
                ;;
            --cb-no-activate)
                shift
                [ $# -gt 0 ] || die "--cb-no-activate requires an argument"
                CB_NO_ACTIVATE="$1"
                shift
                continue
                ;;
            --cb-tmux-socket)
                shift
                [ $# -gt 0 ] || die "--cb-tmux-socket requires an argument"
                CB_TMUX_SOCKET="$1"
                shift
                continue
                ;;
            --cb-bundle-ids)
                shift
                [ $# -gt 0 ] || die "--cb-bundle-ids requires an argument"
                CB_BUNDLE_IDS="$1"
                shift
                continue
                ;;
            -*)
                # Try common options (sets _PARSE_CONSUMED)
                if parse_common_opt "$@"; then
                    case "$_PARSE_CONSUMED" in
                        help)
                            print_usage
                            exit 0
                            ;;
                        end)
                            shift
                            break
                            ;;
                        *)
                            shift "$_PARSE_CONSUMED"
                            continue
                            ;;
                    esac
                fi
                die "Unknown option: $1"
                ;;
            *)
                handle_positional_arg "$1"
                ;;
        esac
        shift
    done
}

parse_args "$@"

# Sync _QUIET for shared logging functions
_QUIET="$QUIET"

if [ "$ACTION_CALLBACK" -eq 1 ]; then
    handle_action_callback
    exit 0
fi

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

validate_common_options

TITLE="$(truncate_text "$MAX_TITLE" "$TITLE")"
BODY="$(truncate_text "$MAX_BODY" "$BODY")"

if [ "$DRY_RUN" -eq 1 ]; then
    print_dry_run_target
    print_dry_run_common
    log "UI: $UI"
    log "Bundle ids: ${BUNDLE_ID_LIST:-$BUNDLE_ID}"
    exit 0
fi

require_tools
if [ "$FOCUS_ONLY" -eq 0 ]; then
    parse_target "$TARGET"
    validate_target_exists
fi

if [ "$DETACH" -eq 1 ]; then
    # Many hook runners kill the entire process group right after the hook exits.
    # Spawn a new session so the notification/dialog survives.
    if ! is_truthy "${TMUX_NOTIFY_ALREADY_DETACHED:-0}"; then
        child_args=()
        if [ "$FOCUS_ONLY" -eq 1 ]; then
            child_args+=(--focus-only)
        else
            child_args+=(--target "$TARGET")
        fi
        child_args+=(--title "$TITLE" --body "$BODY")
        child_args+=(--timeout "$TIMEOUT" --max-title "$MAX_TITLE" --max-body "$MAX_BODY" --dedupe-ms "$DEDUPE_MS")
        child_args+=(--ui "$UI" --detach)
        if [ "$NO_ACTIVATE" -eq 1 ]; then
            child_args+=(--no-activate)
        fi
        if [ -n "${BUNDLE_ID_LIST:-}" ]; then
            child_args+=(--bundle-ids "$BUNDLE_ID_LIST")
        fi
        if [ -n "${SENDER_CLIENT_TTY:-}" ]; then
            child_args+=(--sender-tty "$SENDER_CLIENT_TTY")
        fi
        if [ -n "${SENDER_PID:-}" ]; then
            child_args+=(--sender-pid "$SENDER_PID")
        fi
        if [ -n "${TMUX_SOCKET:-}" ]; then
            child_args+=(--tmux-socket "$TMUX_SOCKET")
        fi
        if [ "$QUIET" -eq 1 ]; then
            child_args+=(--quiet)
        fi

        if spawn_detached_self "${child_args[@]}"; then
            exit 0
        fi
        warn "Failed to detach; running in foreground"
    fi

    # Already detached: do the real work.
    handle_action
    exit 0
fi

handle_action
