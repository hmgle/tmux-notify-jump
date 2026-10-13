#!/usr/bin/env bash
# =============================================================================
# tmux-notify-jump-lib.sh - Shared Library Functions
# =============================================================================
#
# This library provides common functions shared between platform-specific
# notification scripts (macOS and Linux). Functions include:
#
# - Logging: die(), warn(), log(), log_debug()
# - Text processing: trim_ws(), truncate_text()
# - Validation: is_integer(), is_truthy(), is_pane_id()
# - tmux integration: tmux_cmd(), parse_target(), list_panes()
# - Deduplication: dedupe_should_suppress(), dedupe_gc_maybe()
# - Event filtering: is_event_enabled(), csv_list_contains()
# - Argument parsing: parse_common_opt(), handle_positional_arg()
#
# Global Variables:
#   _QUIET      - Set to 1 to suppress non-error output (log, warn)
#   TMUX_NOTIFY_DEBUG      - Set to 1 to enable debug logging
#   TMUX_NOTIFY_DEBUG_LOG  - Custom debug log file path
#   TMUX_NOTIFY_TMUX_SOCKET - Custom tmux server socket path
#
# =============================================================================

set -euo pipefail

# Jump state is shared between client preparation and the click handler.
JUMP_CLIENT_NAME=""
JUMP_TARGET_SESSION_ID=""
JUMP_TARGET_PANE_ID=""

# =============================================================================
# Shared Logging Functions
# =============================================================================
# These functions are used by both platform-specific scripts.
# The _QUIET variable can be set to suppress non-error output.

# Print error message and exit with status 1
#
# Arguments:
#   $@ - Error message parts (joined with spaces)
#
# Side effects:
#   - Prints to stderr
#   - Exits with code 1
die() {
    echo "Error: $*" >&2
    exit 1
}

# Print warning message to stderr (unless quiet mode)
#
# Arguments:
#   $@ - Warning message parts (joined with spaces)
#
# Side effects:
#   - Prints to stderr (unless _QUIET=1)
warn() {
    # Use string comparison to avoid "integer expression expected" under set -e.
    if [ "${_QUIET:-0}" = "1" ]; then
        return
    fi
    echo "Warning: $*" >&2
}

# Print log message to stdout (unless quiet mode)
#
# Arguments:
#   $@ - Log message parts (joined with spaces)
#
# Side effects:
#   - Prints to stdout (unless _QUIET=1)
log() {
    # Use string comparison to avoid "integer expression expected" under set -e.
    if [ "${_QUIET:-0}" = "1" ]; then
        return
    fi
    echo "$*"
}

# Print debug message to log file (when debug mode enabled)
#
# Arguments:
#   $@ - Debug message parts (joined with spaces)
#
# Side effects:
#   - Appends timestamped message to debug log file
#   - Creates log directory if needed
#
# Environment:
#   TMUX_NOTIFY_DEBUG     - Must be "1" to enable
#   TMUX_NOTIFY_DEBUG_LOG - Custom log file path (optional)
log_debug() {
    [ "${TMUX_NOTIFY_DEBUG:-0}" = "1" ] || return 0
    local logfile="${TMUX_NOTIFY_DEBUG_LOG:-}"
    if [ -z "$logfile" ]; then
        local root=""
        root="$(cache_root_dir)"
        logfile="$root/tmux-notify-jump/debug.log"
    fi
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$logfile" 2>/dev/null || true
}

# =============================================================================
# User Configuration
# =============================================================================

tmux_notify_config_path() {
    local path="" directory=""
    # An explicit empty value disables loading, including inside callbacks
    # whose server environment may supply a different HOME.
    if [ -n "${TMUX_NOTIFY_CONFIG+x}" ]; then
        path="$TMUX_NOTIFY_CONFIG"
    elif [ -n "${HOME:-}" ]; then
        path="$HOME/.config/tmux-notify-jump/env"
    fi
    case "$path" in
        ''|/*) ;;
        *)
            directory="$(pwd -P && printf '.')" || return 1
            directory="${directory%$'\n'.}"
            path="${directory%/}/$path"
            ;;
    esac
    printf '%s' "$path"
}

# Load user configuration from env file
#
# Loads environment variables from user's config file.
# Config file location: $TMUX_NOTIFY_CONFIG or ~/.config/tmux-notify-jump/env
#
# Side effects:
#   - Sources config file, setting exported variables
load_user_config() {
    local cfg=""
    cfg="$(tmux_notify_config_path && printf '.')" || return 1
    cfg="${cfg%.}"
    # Freeze the effective path before sourcing: config files and later
    # callbacks can change directory, and detached shells may change HOME.
    TMUX_NOTIFY_CONFIG="$cfg"
    export TMUX_NOTIFY_CONFIG
    [ -f "$cfg" ] || return 0

    set +u
    set -a
    # shellcheck disable=SC1090
    . "$cfg"
    set +a
    set -u
}

# =============================================================================
# Text Processing Functions
# =============================================================================

# Truncate text to a maximum length, adding ellipsis if truncated
#
# Arguments:
#   $1 - max: Maximum length (0 = no truncation)
#   $2 - text: Text to truncate
#
# Returns:
#   stdout: Truncated text (with "..." or "." suffix if truncated)
#
# Notes:
#   - Uses Python3 for proper Unicode character counting
#   - Falls back to bash substring if Python3 unavailable
#
# Example:
#   truncate_text 5 "hello world"  # outputs: he...
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
if max_len <= 0:
    sys.stdout.write(text)
elif len(text) > max_len:
    if max_len < 4:
        # Cannot fit "..." while keeping output <= max_len; use a single dot.
        sys.stdout.write(text[:max_len-1] + ".")
    else:
        sys.stdout.write(text[:max_len-3] + "...")
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
        if [ "$max" -lt 4 ]; then
            local prefix_len=$((max - 1))
            printf '%s.' "${text:0:$prefix_len}"
            return
        fi
        local prefix_len=$((max - 3))
        printf '%s...' "${text:0:$prefix_len}"
        return
    fi
    printf '%s' "$text"
}

# Truncate plain text using a conservative terminal-column budget, preserving
# complete UTF-8 characters. Count each non-ASCII codepoint as two columns:
# libc, utf8proc and tmux's width overrides can disagree, even for zero-width
# characters. A local width table cannot safely size another tmux server.
truncate_text_columns() {
    local max="$1" text="$2"
    [ "$max" -gt 0 ] || return 0

    # Work in bytes even under a C locale, but copy whole UTF-8 sequences.
    local LC_ALL=C byte bytes columns pos=0 used=0 prefix="" suffix='...'
    [ "$max" -ge 4 ] || suffix='.'
    local budget=$((max - ${#suffix}))
    while [ "$pos" -lt "${#text}" ]; do
        byte="${text:$pos:1}"
        bytes=1 columns=1
        case "$byte" in
            [$'\xc2'-$'\xdf']) bytes=2 columns=2 ;;
            [$'\xe0'-$'\xef']) bytes=3 columns=2 ;;
            [$'\xf0'-$'\xf4']) bytes=4 columns=2 ;;
        esac
        used=$((used + columns))
        if [ "$used" -le "$budget" ]; then prefix+="${text:$pos:$bytes}"; fi
        pos=$((pos + bytes))
    done
    if [ "$used" -le "$max" ]; then
        printf '%s' "$text"
    else
        printf '%s%s' "$prefix" "$suffix"
    fi
}

# Remove leading and trailing whitespace from string
#
# Arguments:
#   $1 - String to trim
#
# Returns:
#   stdout: Trimmed string
#
# Example:
#   trim_ws "  hello world  "  # outputs: hello world
trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Check if a command/tool exists
#
# Arguments:
#   $1 - Tool name or path
#
# Side effects:
#   - Calls die() if tool not found
require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_debug "Missing dependency: $tool"
        die "Missing dependency: $tool"
    fi
}

# =============================================================================
# Shared Argument Parsing Helpers
# =============================================================================
# These functions help parse common command-line options across platform scripts.

# Helper to require an argument value
# Usage: require_arg "option_name" "$#"
require_arg() {
    local opt="$1"
    local remaining="$2"
    [ "$remaining" -gt 0 ] || die "$opt requires an argument"
}

# Parse common options shared between macOS and Linux scripts
# Sets global variables and _PARSE_CONSUMED with number of args consumed
# Returns 0 if option was handled, 1 if not recognized
#
# Common options handled:
#   --target, --focus-only, --title, --body, --sender-tty, --tmux-socket
#   --no-activate, --list, --dry-run, --quiet, --timeout, --ui
#   --max-title, --max-body, --dedupe-ms, --bell, --no-bell, --detach, --notify-kind,
#   --notify-source, --inbox-pick, --doctor
#
# Special return values in _PARSE_CONSUMED:
#   "help" - caller should print_usage and exit 0
#   "end"  - end of options marker (--) was seen
#   "inbox-pick" - delegate remaining args to tmux_notify_inbox_pick()
#   "doctor" - delegate remaining args to tmux_notify_doctor_cli()
#
# Platform-specific options NOT handled (must be handled by caller):
#   macOS: --bundle-id, --bundle-ids, --sender-pid, --action-callback, --cb-*
#   Linux: --class, --classes, --sender-pid, --wrap-cols
parse_common_opt() {
    local opt="${1:-}"
    shift || true
    _PARSE_CONSUMED=0

    case "$opt" in
        --target)
            require_arg "$opt" "$#"
            TARGET="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --focus-only)
            FOCUS_ONLY=1
            _PARSE_CONSUMED=1
            return 0
            ;;
        --title)
            require_arg "$opt" "$#"
            TITLE="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --body)
            require_arg "$opt" "$#"
            BODY="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --sender-tty)
            require_arg "$opt" "$#"
            SENDER_CLIENT_TTY="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --tmux-socket)
            require_arg "$opt" "$#"
            TMUX_SOCKET="$1"
            TMUX_NOTIFY_TMUX_SOCKET="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --no-activate)
            NO_ACTIVATE=1
            _PARSE_CONSUMED=1
            return 0
            ;;
        --list)
            # shellcheck disable=SC2034 # consumed by caller scripts
            LIST_ONLY=1
            _PARSE_CONSUMED=1
            return 0
            ;;
        --inbox-pick)
            _PARSE_CONSUMED="inbox-pick"
            return 0
            ;;
        --doctor)
            _PARSE_CONSUMED="doctor"
            return 0
            ;;
        --dry-run)
            # shellcheck disable=SC2034 # consumed by caller scripts
            DRY_RUN=1
            _PARSE_CONSUMED=1
            return 0
            ;;
        --quiet)
            # shellcheck disable=SC2034 # consumed by caller scripts
            QUIET=1
            # Keep shared logging suppressed even if someone logs during parsing.
            _QUIET=1
            _PARSE_CONSUMED=1
            return 0
            ;;
        --bell|--no-bell)
            BELL=0
            [ "$opt" != "--bell" ] || BELL=1
            _PARSE_CONSUMED=1
            return 0
            ;;
        --timeout)
            require_arg "$opt" "$#"
            TIMEOUT="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --ui)
            require_arg "$opt" "$#"
            UI="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --max-title)
            require_arg "$opt" "$#"
            MAX_TITLE="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --max-body)
            require_arg "$opt" "$#"
            MAX_BODY="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --dedupe-ms)
            require_arg "$opt" "$#"
            DEDUPE_MS="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --notify-kind)
            require_arg "$opt" "$#"
            NOTIFY_KIND="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --notify-source)
            require_arg "$opt" "$#"
            # shellcheck disable=SC2034 # consumed by platform scripts
            NOTIFY_SOURCE="$1"
            _PARSE_CONSUMED=2
            return 0
            ;;
        --detach)
            # shellcheck disable=SC2034 # consumed by caller scripts
            DETACH=1
            _PARSE_CONSUMED=1
            return 0
            ;;
        -h|--help)
            # Caller must handle this to call their own print_usage
            _PARSE_CONSUMED="help"
            return 0
            ;;
        --)
            # End of options marker
            _PARSE_CONSUMED="end"
            return 0
            ;;
    esac

    # Option not recognized
    return 1
}

# Handle positional arguments (target, title, body)
# Returns 0 on success, 1 if too many arguments
handle_positional_arg() {
    local arg="$1"
    if [ -z "$TARGET" ]; then
        TARGET="$arg"
    elif [ -z "$TITLE" ]; then
        TITLE="$arg"
    elif [ -z "$BODY" ]; then
        BODY="$arg"
    else
        die "Too many arguments: $arg"
    fi
}

# =============================================================================
# Validation Functions
# =============================================================================

# Validate that a value is a non-negative integer
# Usage: validate_nonneg_int "$value" "option_name"
validate_nonneg_int() {
    local value="$1"
    local name="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        die "$name must be a non-negative integer"
    fi
}

# Validate timeout option (ms)
validate_timeout() {
    if [ -n "${TIMEOUT:-}" ] && ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
        die "--timeout must be a non-negative integer (ms)"
    fi
}

# Validate UI mode option
validate_ui_mode() {
    if [ "$UI" != "notification" ] && [ "$UI" != "dialog" ]; then
        die "--ui must be one of: notification, dialog"
    fi
}

validate_notify_kind() {
    case "${NOTIFY_KIND:-complete}" in
        attention|complete) ;;
        *) die "--notify-kind must be one of: attention, complete" ;;
    esac
}

# Validate common options shared by both platform scripts
# Call this after parse_args()
validate_common_options() {
    validate_timeout
    validate_ui_mode
    validate_notify_kind
    validate_nonneg_int "$MAX_TITLE" "--max-title"
    validate_nonneg_int "$MAX_BODY" "--max-body"
    validate_nonneg_int "$DEDUPE_MS" "--dedupe-ms"
}

# Print common dry-run information
# Each platform script adds its own platform-specific info
print_dry_run_target() {
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
}

# Print common dry-run options
print_dry_run_common() {
    log "Title: $TITLE"
    log "Body: $BODY"
    log "Notification kind: ${NOTIFY_KIND:-complete}"
    log "Notification source: ${NOTIFY_SOURCE:-tmux-notify-jump}"
    log "Terminal bell: $(is_truthy "${BELL:-0}" && echo "yes" || echo "no") (requires a tmux target)"
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
    log "Dedupe window (ms): $DEDUPE_MS"
}

# =============================================================================
# Type Checking Functions
# =============================================================================

# Check if string is a non-negative integer (digits only)
#
# Arguments:
#   $1 - String to check
#
# Returns:
#   0 if valid non-negative integer, 1 otherwise
#
# Example:
#   is_integer "123"  # returns 0
#   is_integer "-5"   # returns 1
#   is_integer "abc"  # returns 1
is_integer() {
    local s="${1:-}"
    [[ "$s" =~ ^[0-9]+$ ]]
}

# Normalize a value to an integer, with fallback
#
# Arguments:
#   $1 - Value to normalize
#   $2 - Fallback if value is not a valid integer
#
# Returns:
#   stdout: The value if valid integer, otherwise the fallback
normalize_int() {
    local value="$1"
    local fallback="$2"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
        return
    fi
    echo "$fallback"
}

# Execute tmux command with proper socket handling
#
# Uses TMUX_NOTIFY_TMUX_SOCKET for custom socket if set,
# otherwise uses the default tmux socket.
#
# Arguments:
#   $@ - tmux command and arguments
#
# Notes:
#   - When inside tmux and socket matches current server,
#     runs without -S to preserve client context
tmux_cmd() {
    if [ -n "${TMUX_NOTIFY_TMUX_SOCKET:-}" ]; then
        # If we're already inside tmux and the socket matches the current server,
        # avoid forcing `-S` so tmux can keep "current client" context.
        #
        # This matters for commands like:
        #   tmux display-message -p '#{pane_id}'
        # which require a current client unless `-t` is provided.
        if [ -n "${TMUX:-}" ]; then
            local current_sock="${TMUX%%,*}"
            current_sock="$(trim_ws "$current_sock")"
            if [ -n "$current_sock" ] && [ "$current_sock" = "$TMUX_NOTIFY_TMUX_SOCKET" ]; then
                tmux "$@"
                return
            fi
        fi
        tmux -S "$TMUX_NOTIFY_TMUX_SOCKET" "$@"
        return
    fi
    tmux "$@"
}

# Check if value represents a truthy boolean
#
# Arguments:
#   $1 - Value to check
#
# Returns:
#   0 if truthy (1, true, TRUE, yes, YES, on, ON)
#   1 otherwise
#
# Example:
#   is_truthy "yes"   # returns 0
#   is_truthy "false" # returns 1
is_truthy() {
    local v="${1:-}"
    case "$v" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
    esac
    return 1
}

# Check if a command is executable
#
# Arguments:
#   $1 - Command name or path
#
# Returns:
#   0 if executable, 1 otherwise
is_executable_cmd() {
    local cmd="${1:-}"
    [ -n "$cmd" ] || return 1
    if [[ "$cmd" == */* ]]; then
        [ -x "$cmd" ]
        return
    fi
    command -v "$cmd" >/dev/null 2>&1
}

resolve_tmux_notify_jump_cmd() {
    local script_dir="${1:-}"

    if [ -n "${TMUX_NOTIFY_JUMP_SH:-}" ]; then
        printf '%s' "$TMUX_NOTIFY_JUMP_SH"
        return 0
    fi
    if [ -n "$script_dir" ] && [ -x "$script_dir/tmux-notify-jump" ]; then
        printf '%s' "$script_dir/tmux-notify-jump"
        return 0
    fi
    # Prefer co-located install (e.g. ~/.local/bin) over whatever happens to be
    # first on PATH. This avoids surprises if the user has multiple versions
    # installed.
    if command -v tmux-notify-jump >/dev/null 2>&1; then
        printf '%s' "tmux-notify-jump"
        return 0
    fi
    if [ -n "$script_dir" ]; then
        printf '%s' "$script_dir/tmux-notify-jump"
        return 0
    fi
    printf '%s' "tmux-notify-jump"
    return 0
}

ensure_tmux_notify_socket_from_env() {
    if [ -n "${TMUX_NOTIFY_TMUX_SOCKET:-}" ]; then
        return 0
    fi
    if [ -z "${TMUX:-}" ]; then
        return 0
    fi
    local sock="${TMUX%%,*}"
    sock="$(trim_ws "$sock")"
    [ -n "$sock" ] || return 0
    TMUX_NOTIFY_TMUX_SOCKET="$sock"
    export TMUX_NOTIFY_TMUX_SOCKET
}

TMUX_TERMINAL_CLIENT_FORMAT='#{client_control_mode}|#{client_activity}|#{client_name}|#{client_tty}|#{client_pid}|#{session_id}|#{pane_id}|#{session_name}'

# Print only user-facing terminal clients. Control-mode clients are tmux
# protocol endpoints even when they happen to own a PTY, so tty presence alone
# is not a visibility test.
tmux_terminal_client_rows() {
    local output=""
    output="$(tmux_cmd list-clients -F "$TMUX_TERMINAL_CLIENT_FORMAT" 2>/dev/null || true)"
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local control=""
        local activity=""
        local name=""
        local tty=""
        local pid=""
        local session_id=""
        local pane_id=""
        local session_name=""
        IFS='|' read -r control activity name tty pid session_id pane_id session_name <<<"$line"
        case "$control" in
            1)
                continue
                ;;
            0)
                ;;
            "")
                # tmux before 2.1 does not expose client_control_mode. A TTY
                # is the only available visibility signal there; it still
                # excludes pipe-backed background control clients.
                [ -n "$tty" ] || continue
                ;;
            *)
                # Unknown non-empty values must not weaken control filtering.
                continue
                ;;
        esac
        # #{client_name} is newer than #{client_control_mode}. Releases that
        # lack it expand the field empty, so fall back to the tty: that is what
        # a terminal client is named on every tmux that accepts `-c <tty>`.
        [ -n "$name" ] || name="$tty"
        [ -n "$name" ] || continue
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$activity" "$name" "$tty" "$pid" "$session_id" "$pane_id" "$session_name"
    done <<<"$output"
}

# Keep client inventory consumers consistent about field order as tmux adds
# client metadata and older releases leave individual fields empty. These are
# process-global scratch variables: every call overwrites all CLIENT_* fields.
read_tmux_client_row() {
    IFS='|' read -r CLIENT_ACTIVITY CLIENT_NAME CLIENT_TTY CLIENT_PID \
        CLIENT_SESSION_ID CLIENT_PANE_ID CLIENT_SESSION_NAME <<<"${1:-}"
}

get_best_tmux_client_pane_id() {
    local output=""
    output="$(tmux_terminal_client_rows)"
    local best_activity=0
    local best_pane=""
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read_tmux_client_row "$line"
        if ! is_integer "$CLIENT_ACTIVITY"; then
            continue
        fi
        if [ -z "$CLIENT_PANE_ID" ] || ! is_pane_id "$CLIENT_PANE_ID"; then
            continue
        fi
        if [ "$CLIENT_ACTIVITY" -gt "$best_activity" ]; then
            best_activity="$CLIENT_ACTIVITY"
            best_pane="$CLIENT_PANE_ID"
        fi
    done <<<"$output"

    if [ -n "$best_pane" ]; then
        printf '%s' "$best_pane"
        return 0
    fi
    return 1
}

# Resolve only a pane whose root process is an ancestor of the reporter. Read
# both inventories once; walking through ps per ancestor is slow for hooks.
# ps is optional, and missing/dead roots or a broken ancestry are a no-match.
tmux_notify_target_from_ancestry() {
    local sender_pid="${1:-${PPID:-}}" panes="" processes=""
    is_integer "$sender_pid" && [ "$sender_pid" -gt 1 ] || return 1
    command -v ps >/dev/null 2>&1 || return 1
    panes="$(tmux_cmd list-panes -a -F '#{pane_id}|#{pane_pid}|#{pane_dead}' 2>/dev/null)" || return 1
    [ -n "$panes" ] || return 1
    processes="$(ps -A -o pid=,ppid= 2>/dev/null)" || return 1
    local pane=""
    pane="$(printf '%s\n' "$processes" | awk -v inventory="$panes" -v pid="$sender_pid" '
        BEGIN {
            n = split(inventory, rows, "\n")
            for (i = 1; i <= n; i++) {
                split(rows[i], fields, "|")
                if (fields[1] ~ /^%[0-9]+$/ && fields[2] ~ /^[0-9]+$/ && fields[3] != "1")
                    panes[fields[2]] = fields[1]
            }
        }
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { parents[$1] = $2 }
        END {
            for (depth = 0; depth < 64 && pid > 1 && !seen[pid]++; depth++) {
                if (pid in panes) { print panes[pid]; exit }
                if (!(pid in parents)) exit
                pid = parents[pid]
            }
        }
    ')"
    is_pane_id "$pane" || return 1
    printf '%s' "$pane"
}

resolve_tmux_notify_target() {
    local allow_fallback="${1:-0}" sender_pid="${2:-${PPID:-}}" pane=""

    if [ -n "${TMUX_PANE:-}" ] && is_pane_id "$TMUX_PANE"; then
        printf '%s' "$TMUX_PANE"
        return 0
    fi

    if is_truthy "${TMUX_NOTIFY_TARGET_ANCESTRY:-1}"; then
        pane="$(tmux_notify_target_from_ancestry "$sender_pid" || true)"
        if is_pane_id "$pane"; then
            printf '%s' "$pane"
            return 0
        fi
    fi

    # TMUX identifies a server, not the reporting pane. The ambient pane can
    # belong to an unrelated client, especially for service-run agent hooks.
    is_truthy "$allow_fallback" || return 1
    if [ -n "${TMUX:-}" ]; then
        pane="$(tmux_cmd display-message -p '#{pane_id}' 2>/dev/null || true)"
        if [ -n "$pane" ] && is_pane_id "$pane"; then
            printf '%s' "$pane"
            return 0
        fi
        local human=""
        human="$(tmux_cmd display-message -p '#S:#I.#P' 2>/dev/null || true)"
        if [ -n "$human" ]; then
            printf '%s' "$human"
            return 0
        fi
    fi

    get_best_tmux_client_pane_id
}

# =============================================================================
# tmux Integration Functions
# =============================================================================

# Check that tmux server is running
#
# Side effects:
#   - Calls die() if server not running
check_tmux_server() {
    tmux_cmd list-sessions >/dev/null 2>&1 || die "tmux server is not running"
}

# List all panes across all sessions
#
# Returns:
#   stdout: Formatted list of panes with active marker
#
# Side effects:
#   - Calls die() if tmux not available or server not running
list_panes() {
    require_tool tmux
    if ! tmux_cmd list-sessions >/dev/null 2>&1; then
        die "tmux server is not running; cannot list panes"
    fi
    tmux_cmd list-panes -a -F "  #{?pane_active,*, } #{session_name}:#{window_index}.#{pane_index} - #{pane_title}"
}

# Check if string is a valid tmux pane ID
#
# Arguments:
#   $1 - String to check
#
# Returns:
#   0 if valid pane ID (format: %<number>), 1 otherwise
#
# Example:
#   is_pane_id "%1"   # returns 0
#   is_pane_id "1"    # returns 1
is_pane_id() {
    local s="${1:-}"
    [[ "$s" =~ ^%[0-9]+$ ]]
}

# Parse a tmux target string into components
#
# Accepts either:
#   - Pane ID: %<number>
#   - Target string: session:window.pane
#
# Arguments:
#   $1 - Target string to parse
#
# Sets global variables:
#   SESSION - Session name (empty if pane ID)
#   WINDOW  - Window index (empty if pane ID)
#   PANE    - Pane index (empty if pane ID)
#   PANE_ID - Pane ID (empty if target string)
#
# Side effects:
#   - Calls die() if format invalid
#
# Example:
#   parse_target "%5"        # sets PANE_ID="%5"
#   parse_target "main:0.1"  # sets SESSION="main", WINDOW="0", PANE="1"
parse_target() {
    local target="$1"

    SESSION=""
    WINDOW=""
    PANE=""
    PANE_ID=""

    if is_pane_id "$target"; then
        PANE_ID="$target"
        return 0
    fi

    if [[ "$target" != *:*.* ]]; then
        die "Target must be in the form session:window.pane (or a pane id like %1)"
    fi
    SESSION="${target%%:*}"
    local window_pane="${target#*:}"
    WINDOW="${window_pane%%.*}"
    PANE="${window_pane#*.}"
    if [ -z "$SESSION" ] || [ -z "$WINDOW" ] || [ -z "$PANE" ]; then
        die "Target must be in the form session:window.pane (or a pane id like %1)"
    fi
}

# Resolve pane ID to session:window.pane format
#
# Requires PANE_ID to be set. Queries tmux to get full target info.
#
# Side effects:
#   - Sets SESSION, WINDOW, PANE global variables
#   - Calls die() if pane doesn't exist
resolve_target_from_pane_id() {
    [ -n "${PANE_ID:-}" ] || return 1
    check_tmux_server

    local pane_id="$PANE_ID"
    local resolved=""
    resolved="$(tmux_cmd display-message -p -t "$pane_id" '#S:#I.#P' 2>/dev/null || true)"
    [ -n "$resolved" ] || die "Pane does not exist: $pane_id"

    parse_target "$resolved"
    PANE_ID="$pane_id"
}

# Ensure target is fully resolved (resolve pane ID if needed)
#
# If PANE_ID is set but SESSION is empty, resolves the pane ID
# to get the full session:window.pane information.
ensure_target_resolved() {
    if [ -n "${PANE_ID:-}" ] && [ -z "${SESSION:-}" ]; then
        resolve_target_from_pane_id
    fi
}

# Validate that the target pane/session/window exists
#
# Checks that the target specified by SESSION/WINDOW/PANE or
# PANE_ID actually exists in tmux.
#
# Side effects:
#   - Calls die() if target doesn't exist
validate_target_exists() {
    check_tmux_server

    if [ -n "${PANE_ID:-}" ]; then
        if ! tmux_cmd list-panes -a -F "#{pane_id}" 2>/dev/null | grep -Fqx -- "$PANE_ID"; then
            die "Pane does not exist: $PANE_ID"
        fi
        return 0
    fi

    if ! tmux_cmd has-session -t "$SESSION" >/dev/null 2>&1; then
        die "Session does not exist: $SESSION"
    fi
    local panes
    if ! panes=$(tmux_cmd list-panes -t "$SESSION:$WINDOW" -F "#{pane_index}" 2>/dev/null); then
        die "Window does not exist: $SESSION:$WINDOW"
    fi
    if ! printf '%s\n' "$panes" | grep -Fqx -- "$PANE"; then
        die "Pane does not exist: $SESSION:$WINDOW.$PANE"
    fi
}

get_current_tmux_session_id() {
    if [ -z "${TMUX:-}" ]; then
        return 1
    fi
    local session_id=""
    if [ -n "${TMUX_PANE:-}" ]; then
        session_id="$(tmux_cmd display-message -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null || true)"
    fi
    if [ -z "$session_id" ]; then
        session_id="$(tmux_cmd display-message -p '#{session_id}' 2>/dev/null || true)"
    fi
    if [ -n "$session_id" ]; then
        printf '%s' "$session_id"
        return 0
    fi
    return 1
}

get_sender_tmux_client_pid() {
    if [ -z "${TMUX:-}" ]; then
        return 1
    fi

    local current_session_id=""
    current_session_id="$(get_current_tmux_session_id 2>/dev/null || true)"

    local best_pid=""
    local best_activity=0
    local output=""
    output="$(tmux_terminal_client_rows)"
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read_tmux_client_row "$line"

        if ! is_integer "$CLIENT_ACTIVITY"; then
            continue
        fi
        if ! is_integer "$CLIENT_PID"; then
            continue
        fi
        if [ -n "$current_session_id" ] && [ "$CLIENT_SESSION_ID" != "$current_session_id" ]; then
            continue
        fi

        if [ "$CLIENT_ACTIVITY" -gt "$best_activity" ]; then
            best_activity="$CLIENT_ACTIVITY"
            best_pid="$CLIENT_PID"
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

    local clients=""
    clients="$(tmux_terminal_client_rows)"

    if [ -n "${TMUX_PANE:-}" ]; then
        local line=""
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            read_tmux_client_row "$line"
            if [ "$CLIENT_PANE_ID" = "$TMUX_PANE" ] && [ -n "$CLIENT_TTY" ]; then
                printf '%s' "$CLIENT_TTY"
                return 0
            fi
        done <<<"$clients"
    fi

    local current_session_id=""
    current_session_id="$(get_current_tmux_session_id 2>/dev/null || true)"

    local best_tty=""
    local best_activity=0
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read_tmux_client_row "$line"

        if ! is_integer "$CLIENT_ACTIVITY"; then
            continue
        fi
        if [ -n "$current_session_id" ] && [ "$CLIENT_SESSION_ID" != "$current_session_id" ]; then
            continue
        fi

        if [ "$CLIENT_ACTIVITY" -gt "$best_activity" ] && [ -n "$CLIENT_TTY" ]; then
            best_activity="$CLIENT_ACTIVITY"
            best_tty="$CLIENT_TTY"
        fi
    done <<<"$clients"

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
    output="$(tmux_terminal_client_rows)"
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read_tmux_client_row "$line"
        if [ "$CLIENT_TTY" = "$tty" ] && is_integer "$CLIENT_PID"; then
            printf '%s' "$CLIENT_PID"
            return 0
        fi
    done <<<"$output"
    return 1
}

find_tmux_terminal_client_by_tty() {
    local rows="${1:-}"
    local tty="${2:-}"
    [ -n "$tty" ] || return 1
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read_tmux_client_row "$line"
        if [ "$CLIENT_TTY" = "$tty" ]; then
            printf '%s' "$line"
            return 0
        fi
    done <<<"$rows"
    return 1
}

best_tmux_terminal_client() {
    local rows="${1:-}"
    local required_session_id="${2:-}"
    local best_activity=-1
    local best_line=""
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read_tmux_client_row "$line"
        is_integer "$CLIENT_ACTIVITY" || continue
        if [ -n "$required_session_id" ] && [ "$CLIENT_SESSION_ID" != "$required_session_id" ]; then
            continue
        fi
        if [ "$CLIENT_ACTIVITY" -gt "$best_activity" ]; then
            best_activity="$CLIENT_ACTIVITY"
            best_line="$line"
        fi
    done <<<"$rows"
    [ -n "$best_line" ] || return 1
    printf '%s' "$best_line"
}

single_tmux_terminal_client() {
    local rows="${1:-}"
    local only=""
    local count=0
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        only="$line"
        count=$((count + 1))
        [ "$count" -le 1 ] || return 1
    done <<<"$rows"
    [ "$count" -eq 1 ] || return 1
    printf '%s' "$only"
}

# Resolve the policy for a target no ordinary client is viewing. Unknown
# values are reported rather than silently selecting the strict policy, which
# is the opposite of what an attempt to switch this on would intend.
tmux_unattached_fallback_policy() {
    local policy="${TMUX_NOTIFY_UNATTACHED_FALLBACK:-single}"
    case "$policy" in
        single | none)
            printf '%s' "$policy"
            ;;
        *)
            warn "Unknown TMUX_NOTIFY_UNATTACHED_FALLBACK value '$policy'; expected 'single' or 'none', using 'single'"
            printf 'single'
            ;;
    esac
}

prepare_tmux_jump_client() {
    ensure_target_resolved
    local target_spec="${PANE_ID:-$SESSION:$WINDOW.$PANE}"
    local target_info=""
    target_info="$(tmux_cmd display-message -p -t "$target_spec" '#{session_id}|#{pane_id}' 2>/dev/null || true)"
    [ -n "$target_info" ] || die "Target pane no longer exists: $target_spec"
    JUMP_TARGET_SESSION_ID="${target_info%%|*}"
    JUMP_TARGET_PANE_ID="${target_info#*|}"
    [ -n "$JUMP_TARGET_SESSION_ID" ] || die "Target pane no longer exists: $target_spec"

    local fallback_policy=""
    fallback_policy="$(tmux_unattached_fallback_policy)"

    local rows=""
    rows="$(tmux_terminal_client_rows)"
    local selected=""
    if [ -n "${SENDER_CLIENT_TTY:-}" ]; then
        selected="$(find_tmux_terminal_client_by_tty "$rows" "$SENDER_CLIENT_TTY" 2>/dev/null || true)"
    fi
    if [ -z "$selected" ]; then
        selected="$(best_tmux_terminal_client "$rows" "$JUMP_TARGET_SESSION_ID" 2>/dev/null || true)"
    fi
    if [ -z "$selected" ] && [ "$fallback_policy" = "single" ]; then
        selected="$(single_tmux_terminal_client "$rows" 2>/dev/null || true)"
    fi
    if [ -z "$selected" ]; then
        local visible=""
        visible="$(best_tmux_terminal_client "$rows" 2>/dev/null || true)"
        if [ -n "$visible" ]; then
            read_tmux_client_row "$visible"
            log_debug "visibility notice client=$CLIENT_NAME tty=$CLIENT_TTY pid=$CLIENT_PID session=$CLIENT_SESSION_NAME session_id=$CLIENT_SESSION_ID pane=$CLIENT_PANE_ID activity=$CLIENT_ACTIVITY"
            tmux_cmd display-message -c "$CLIENT_NAME" \
                "tmux-notify-jump: target session $SESSION is not visible (no ordinary terminal client)" \
                >/dev/null 2>&1 || true
        fi
        log_debug "target session $SESSION is not visible: no ordinary terminal client"
        die "Target session $SESSION is not visible (no ordinary terminal client)"
    fi

    read_tmux_client_row "$selected"
    local selected_activity="$CLIENT_ACTIVITY"
    local selected_tty="$CLIENT_TTY"
    local selected_session_id="$CLIENT_SESSION_ID"
    local selected_pane_id="$CLIENT_PANE_ID"
    local selected_session_name="$CLIENT_SESSION_NAME"
    JUMP_CLIENT_NAME="$CLIENT_NAME"
    SENDER_CLIENT_PID="$CLIENT_PID"
    # A tty-less selected row cannot improve activation, so retain the known
    # sender tty even though it may identify a different client.
    if [ -n "$selected_tty" ]; then
        SENDER_CLIENT_TTY="$selected_tty"
    fi
    log_debug "selected tmux client=$JUMP_CLIENT_NAME tty=$SENDER_CLIENT_TTY pid=$SENDER_CLIENT_PID session=$selected_session_name session_id=$selected_session_id pane=$selected_pane_id activity=$selected_activity"
}

# Verify the explicit ordinary client after navigation, before acknowledging.
# Pane context is absent on older tmux: retain the existing session-only check.
tmux_notify_verify_client_target() {
    local client="$1" session="$2" pane="${3:-}" window="${4:-}" actual_window=""
    local rows=""
    rows="$(tmux_terminal_client_rows)"
    local matched=0
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read_tmux_client_row "$line"
        if [ "$CLIENT_NAME" != "$client" ] \
            || [ "$CLIENT_SESSION_ID" != "$session" ]; then
            continue
        fi
        # Old tmux releases do not expand #{pane_id} in client context. Verify
        # the session only there instead of failing a jump that did happen.
        if [ -z "$CLIENT_PANE_ID" ]; then
            log_debug "client pane not reported; verified session only"
        elif [ -n "$pane" ] && [ "$CLIENT_PANE_ID" != "$pane" ]; then
            continue
        elif [ -n "$window" ]; then
            actual_window="$(tmux_cmd display-message -p -t "$CLIENT_PANE_ID" '#{window_id}' 2>/dev/null || true)"
            [ "$actual_window" = "$window" ] || continue
        fi
        matched=1
        break
    done <<<"$rows"
    if [ "$matched" -ne 1 ]; then
        log_debug "client switch postcondition failed: client=$client target_session=$session target_pane=$pane target_window=$window rows=$rows"
        return 1
    fi
}

jump_to_pane() {
    if [ -z "${JUMP_CLIENT_NAME:-}" ]; then
        prepare_tmux_jump_client
    fi
    if ! tmux_cmd switch-client -c "$JUMP_CLIENT_NAME" -t "$SESSION:$WINDOW" ';' \
        select-pane -t "$JUMP_TARGET_PANE_ID" 2>/dev/null; then
        die "Failed to switch terminal client $JUMP_CLIENT_NAME to $SESSION:$WINDOW.$PANE"
    fi
    if ! tmux_notify_verify_client_target "$JUMP_CLIENT_NAME" "$JUMP_TARGET_SESSION_ID" "$JUMP_TARGET_PANE_ID"; then
        die "tmux client switch did not make $SESSION:$WINDOW.$PANE visible"
    fi
    tmux_notify_inbox_ack_pane "$JUMP_TARGET_PANE_ID"
    log "Jumped to $SESSION:$WINDOW.$PANE via $JUMP_CLIENT_NAME"
}

process_env_has_ssh() {
    local pid="${1:-}"
    if ! is_integer "$pid"; then
        return 1
    fi

    local environ="/proc/$pid/environ"
    [ -r "$environ" ] || return 1

    if tr '\0' '\n' <"$environ" 2>/dev/null | grep -Eq '^(SSH_CONNECTION|SSH_CLIENT|SSH_TTY)='; then
        return 0
    fi
    return 1
}

process_tree_ssh_state() {
    local pid="${1:-}"
    if ! is_integer "$pid"; then
        printf '%s' "unknown"
        return 0
    fi

    local current_pid="$pid"
    local depth=0
    while is_integer "$current_pid" && [ "$current_pid" -gt 1 ] && [ "$depth" -lt 50 ]; do
        local comm=""
        comm="$(ps -p "$current_pid" -o comm= 2>/dev/null || true)"
        comm="$(trim_ws "$comm")"
        if [ -z "$comm" ]; then
            printf '%s' "unknown"
            return 0
        fi
        case "$comm" in
            sshd|sshd:*|*/sshd|*/sshd:*)
                printf '%s' "remote"
                return 0
                ;;
        esac

        local ppid=""
        ppid="$(ps -p "$current_pid" -o ppid= 2>/dev/null || true)"
        ppid="$(trim_ws "$ppid")"
        if ! is_integer "$ppid" || [ "$ppid" = "$current_pid" ]; then
            printf '%s' "unknown"
            return 0
        fi
        if [ "$ppid" -le 1 ]; then
            printf '%s' "local"
            return 0
        fi

        current_pid="$ppid"
        depth=$((depth + 1))
    done

    printf '%s' "unknown"
}

tmux_client_pid_ssh_state() {
    local pid="${1:-}"
    if ! is_integer "$pid"; then
        printf '%s' "unknown"
        return 0
    fi

    if process_env_has_ssh "$pid"; then
        printf '%s' "remote"
        return 0
    fi
    process_tree_ssh_state "$pid"
}

# =============================================================================
# tmux-native notification Inbox
# =============================================================================

tmux_notify_remote_mode() {
    local mode="${TMUX_NOTIFY_REMOTE_MODE:-}"
    if [ -z "$mode" ] && is_truthy "${TMUX_NOTIFY_REMOTE:-0}"; then
        mode="desktop"
    fi
    case "$mode" in
        tmux|desktop|both|suppress) printf '%s' "$mode" ;;
        *) printf '%s' "tmux" ;;
    esac
}

tmux_notify_process_is_remote_ssh() {
    [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]
}

tmux_notify_normalized_absolute_path() {
    local path="$1"
    [[ "$path" == /* ]] || return 1
    [ "$path" = "/" ] && return 0
    case "$path/" in
        *'/../'*|*'/./'*|*'//'*) return 1 ;;
    esac
}

tmux_notify_inbox_cache_root() {
    local root="" home="${HOME:-}"
    # Command substitutions strip trailing newlines. Keep a sentinel at the
    # end while capturing the path, then remove only that sentinel.
    root="$(cache_root_dir; printf '.')"
    root="${root%.}"
    while [ "$root" != "/" ] && [[ "$root" == */ ]]; do
        root="${root%/}"
    done
    if ! tmux_notify_normalized_absolute_path "$root"; then
        root="$home/.cache"
    fi
    if ! tmux_notify_normalized_absolute_path "$root"; then
        root="/tmp"
    fi
    printf '%s' "$root"
}

tmux_notify_inbox_default_root() {
    local requested_socket="${TMUX_NOTIFY_TMUX_SOCKET:-}"
    local socket="" server_id="" cache_root=""
    if [ -n "${TMUX:-}" ]; then
        local current_socket="${TMUX%%,*}" remainder="${TMUX#*,}" current_pid=""
        current_pid="${remainder%%,*}"
        if [ -z "$requested_socket" ] || [ "$current_socket" = "$requested_socket" ]; then
            socket="$current_socket"
            if is_integer "$current_pid"; then
                server_id="$current_pid"
            fi
        fi
    fi
    if [ -z "$socket" ]; then
        socket="$(tmux_cmd display-message -p '#{socket_path}' 2>/dev/null || true)"
    fi
    if [ -z "$server_id" ]; then
        server_id="$(tmux_cmd display-message -p '#{pid}' 2>/dev/null || true)"
    fi
    [ -n "$socket" ] || socket="${requested_socket:-default}"
    [ -n "$server_id" ] || server_id="default"
    local id=""
    id="$(printf '%s|%s' "$socket" "$server_id" | sha256_hex_stdin)"
    cache_root="$(tmux_notify_inbox_cache_root; printf '.')"
    cache_root="${cache_root%.}"
    printf '%s/tmux-notify-jump/inbox/%s' "${cache_root%/}" "$id"
}

tmux_notify_inbox_canonical_path() {
    local path="$1" current="$1" suffix="" part="" resolved=""
    while [ ! -e "$current" ]; do
        [ "$current" != "/" ] || break
        part="${current##*/}"
        [ -n "$part" ] || return 1
        suffix="/$part$suffix"
        current="${current%/*}"
        [ -n "$current" ] || current="/"
    done
    [ -d "$current" ] || return 1
    resolved="$(cd -P "$current" 2>/dev/null && pwd -P)" || return 1
    printf '%s%s' "${resolved%/}" "$suffix"
}

tmux_notify_inbox_id_is_valid() {
    local value="$1"
    [[ "$value" =~ ^[0-9a-f]{64}$ || "$value" =~ ^[0-9]{1,10}$ ]]
}

tmux_notify_inbox_root_is_valid() {
    local root="$1" canonical="" parent=""
    tmux_notify_normalized_absolute_path "$root" || return 1
    [ ! -L "$root" ] || return 1
    tmux_notify_inbox_id_is_valid "${root##*/}" || return 1
    canonical="$(tmux_notify_inbox_canonical_path "$root")" || return 1
    tmux_notify_inbox_id_is_valid "${canonical##*/}" || return 1
    parent="${canonical%/*}"
    [ "${parent##*/}" = "inbox" ] || return 1
    parent="${parent%/*}"
    [ "${parent##*/}" = "tmux-notify-jump" ]
}

tmux_notify_inbox_root() {
    local configured_root=""
    configured_root="$(
        tmux_cmd show-option -gqv @tmux-notify-jump-inbox-root 2>/dev/null || true
    )"
    if [ -n "$configured_root" ] \
        && tmux_notify_inbox_root_is_valid "$configured_root"; then
        printf '%s' "$configured_root"
        return 0
    fi
    tmux_notify_inbox_default_root
}

tmux_notify_compact_text() {
    local text="${1:-}"
    text="${text//$'\n'/ }"
    text="${text//$'\r'/ }"
    text="${text//$'\t'/ }"
    text="$(trim_ws "$text")"
    truncate_text 512 "$text"
}

# Read one Inbox field into the variable named by $3.
#
# Entry metadata is stored one field per file and read field by field on hot
# paths: the focus hooks acknowledge on every pane switch and every count sync
# walks the whole Inbox. A command substitution per field forks a subshell and
# dominates that cost, so use the read builtin and assign indirectly.
tmux_notify_inbox_read_field() {
    local dir="$1" name="$2" var="$3" value=""
    read -r value 2>/dev/null <"$dir/$name" || true
    printf -v "$var" '%s' "$value"
}

tmux_notify_inbox_entry_read() {
    local dir="$1"
    tmux_notify_inbox_read_field "$dir" kind INBOX_KIND
    tmux_notify_inbox_read_field "$dir" count INBOX_COUNT
    tmux_notify_inbox_read_field "$dir" first_ms INBOX_FIRST_MS
    tmux_notify_inbox_read_field "$dir" last_ms INBOX_LAST_MS
    tmux_notify_inbox_read_field "$dir" pane_id INBOX_PANE_ID
    tmux_notify_inbox_read_field "$dir" window_id INBOX_WINDOW_ID
    tmux_notify_inbox_read_field "$dir" session_id INBOX_SESSION_ID
    tmux_notify_inbox_read_field "$dir" session_name INBOX_SESSION_NAME
    tmux_notify_inbox_read_field "$dir" window_index INBOX_WINDOW_INDEX
    tmux_notify_inbox_read_field "$dir" source INBOX_SOURCE
    tmux_notify_inbox_read_field "$dir" title INBOX_TITLE
}

tmux_notify_inbox_secure_dir() {
    local dir="$1" create="${2:-0}"
    [ ! -L "$dir" ] || return 1
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then
        return 1
    fi
    if [ ! -d "$dir" ]; then
        [ "$create" -eq 1 ] || return 0
        mkdir -p "$dir" || return 1
    fi
    [ ! -L "$dir" ] || return 1
    chmod 700 "$dir" 2>/dev/null
}

tmux_notify_inbox_entry_dir_is_valid() {
    local dir="$1" name="${1##*/}"
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    tmux_notify_inbox_id_is_valid "$name" || return 1
    [ -f "$dir/kind" ]
}

tmux_notify_inbox_write_field() {
    local dir="$1" name="$2" value="$3"
    local tmp="$dir/$name.$$.$RANDOM"
    (umask 077; printf '%s\n' "$value" >"$tmp") 2>/dev/null || return 1
    if ! chmod 600 "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    mv -f "$tmp" "$dir/$name" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
}

tmux_notify_inbox_sync_counts() {
    local root=""
    root="$(tmux_notify_inbox_root)"
    tmux_notify_inbox_secure_dir "$root" || return 1
    local attention=0 complete=0 dir="" changed=0
    local current_attention="" current_complete=""
    for dir in "$root"/*; do
        tmux_notify_inbox_entry_dir_is_valid "$dir" || continue
        local kind="" count=""
        tmux_notify_inbox_read_field "$dir" kind kind
        tmux_notify_inbox_read_field "$dir" count count
        [[ "$count" =~ ^[0-9]+$ ]] || count=1
        if [ "$kind" = "attention" ]; then
            attention=$((attention + count))
        else
            complete=$((complete + count))
        fi
    done
    current_attention="$(
        tmux_cmd show-option -gqv @tmux-notify-jump-attention 2>/dev/null || true
    )"
    current_complete="$(
        tmux_cmd show-option -gqv @tmux-notify-jump-complete 2>/dev/null || true
    )"
    if [ "$current_attention" != "$attention" ]; then
        tmux_cmd set-option -gq @tmux-notify-jump-attention "$attention" 2>/dev/null || true
        changed=1
    fi
    if [ "$current_complete" != "$complete" ]; then
        tmux_cmd set-option -gq @tmux-notify-jump-complete "$complete" 2>/dev/null || true
        changed=1
    fi
    if [ "$changed" -eq 1 ]; then
        tmux_cmd refresh-client -S 2>/dev/null || true
    fi
    TMUX_NOTIFY_INBOX_ATTENTION="$attention"
    TMUX_NOTIFY_INBOX_COMPLETE="$complete"
    export TMUX_NOTIFY_INBOX_ATTENTION TMUX_NOTIFY_INBOX_COMPLETE
}

tmux_notify_inbox_gc() {
    local root="$1" now="$2"
    local ttl="${TMUX_NOTIFY_INBOX_TTL_MS:-604800000}"
    local max="${TMUX_NOTIFY_INBOX_MAX:-100}"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=604800000
    [[ "$max" =~ ^[0-9]+$ ]] || max=100
    local dir last
    for dir in "$root"/*; do
        tmux_notify_inbox_entry_dir_is_valid "$dir" || continue
        tmux_notify_inbox_read_field "$dir" last_ms last
        if [[ "$last" =~ ^[0-9]+$ ]] && [ "$ttl" -gt 0 ] && [ "$now" -gt "$last" ] && [ $((now - last)) -ge "$ttl" ]; then
            rm -rf "$dir" 2>/dev/null || true
        fi
    done
    if [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ]; then
        local count=0 list="" id=""
        for dir in "$root"/*; do
            tmux_notify_inbox_entry_dir_is_valid "$dir" || continue
            tmux_notify_inbox_read_field "$dir" last_ms last
            [ -n "$last" ] || last=0
            # Sort on the entry id, never the full path. A cache root may
            # legally contain a newline, which would split these records; the
            # id is always hex or digits, so the root's bytes cannot leak in.
            list+="$last|${dir##*/}"$'\n'
            count=$((count + 1))
        done
        if [ "$count" -gt "$max" ]; then
            printf '%s' "$list" | sort -n -t '|' -k1,1 | head -n $((count - max)) | cut -d '|' -f2- | while IFS= read -r id; do
                if [ -n "$id" ]; then rm -rf "${root:?}/$id" 2>/dev/null || true; fi
            done
        fi
    fi
}

tmux_notify_inbox_target_info() {
    local target="$1"
    # Keep the human label last: read's final field preserves embedded pipes.
    tmux_cmd display-message -p -t "$target" '#{session_id}|#{window_id}|#{pane_id}|#{window_index}|#{session_name}' 2>/dev/null || true
}

tmux_notify_inbox_acquire_lock() {
    local lock="$1" retries="${TMUX_NOTIFY_INBOX_LOCK_RETRIES:-20}" attempt=0
    [[ "$retries" =~ ^[0-9]+$ ]] || retries=20
    while [ "$attempt" -le "$retries" ]; do
        if acquire_lock "$lock"; then
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -le "$retries" ] || break
        sleep 0.01
    done
    return 1
}

tmux_notify_inbox_enqueue() {
    local target="$1" kind="$2" source="$3" title="$4"
    local info=""
    info="$(tmux_notify_inbox_target_info "$target")"
    [ -n "$info" ] || return 1
    local session_id window_id pane_id session_name window_index
    IFS='|' read -r session_id window_id pane_id window_index session_name <<<"$info"
    [ -n "$pane_id" ] || return 1
    local root="" now=""
    root="$(tmux_notify_inbox_root)"
    now="$(now_ms)"
    tmux_notify_inbox_secure_dir "$root" 1 || return 1
    tmux_notify_inbox_gc "$root" "$now"
    local key=""
    key="$(printf '%s|%s' "$pane_id" "$kind" | sha256_hex_stdin)"
    local dir="$root/$key" lock="$root/$key.lock"
    if ! tmux_notify_inbox_acquire_lock "$lock"; then
        log_debug "Inbox update skipped after lock contention: pane=$pane_id kind=$kind"
        return 0
    fi
    if ! tmux_notify_inbox_secure_dir "$dir" 1; then
        release_lock "$lock"
        return 1
    fi
    tmux_notify_inbox_entry_read "$dir"
    local count="${INBOX_COUNT:-0}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))
    local first="${INBOX_FIRST_MS:-$now}"
    tmux_notify_inbox_write_field "$dir" kind "$kind"
    tmux_notify_inbox_write_field "$dir" count "$count"
    tmux_notify_inbox_write_field "$dir" first_ms "$first"
    tmux_notify_inbox_write_field "$dir" last_ms "$now"
    tmux_notify_inbox_write_field "$dir" pane_id "$pane_id"
    tmux_notify_inbox_write_field "$dir" window_id "$window_id"
    tmux_notify_inbox_write_field "$dir" session_id "$session_id"
    tmux_notify_inbox_write_field "$dir" session_name "$session_name"
    tmux_notify_inbox_write_field "$dir" window_index "$window_index"
    tmux_notify_inbox_write_field "$dir" source "$(tmux_notify_compact_text "$source")"
    tmux_notify_inbox_write_field "$dir" title "$(tmux_notify_compact_text "$title")"
    release_lock "$lock"
    tmux_notify_inbox_gc "$root" "$now"
    tmux_notify_inbox_sync_counts
    return 0
}

tmux_notify_inbox_ack_pane() {
    local pane_id="$1" root="" kind="" key="" dir=""
    root="$(tmux_notify_inbox_root)"
    tmux_notify_inbox_secure_dir "$root" || return 1
    for kind in attention complete; do
        key="$(printf '%s|%s' "$pane_id" "$kind" | sha256_hex_stdin)"
        dir="$root/$key"
        [ -d "$dir" ] || continue
        rm -rf "$dir" 2>/dev/null || true
    done
    # Resynchronize even when nothing matched. The counts arm the tmux-side
    # hook guard, so entries lost outside this flow (a cleared cache, a moved
    # root) would otherwise keep stale counts armed and re-run this script on
    # every pane switch without ever converging.
    tmux_notify_inbox_sync_counts
}

tmux_notify_inbox_clear_all() {
    local root="" dir status=0
    TMUX_NOTIFY_INBOX_CLEARED=0
    TMUX_NOTIFY_INBOX_CLEAR_FAILURES=0
    root="$(tmux_notify_inbox_root)"
    tmux_notify_inbox_secure_dir "$root" || return 1
    for dir in "$root"/*; do
        tmux_notify_inbox_entry_dir_is_valid "$dir" || continue
        if rm -rf "$dir" 2>/dev/null; then
            TMUX_NOTIFY_INBOX_CLEARED=$((TMUX_NOTIFY_INBOX_CLEARED + 1))
        else
            TMUX_NOTIFY_INBOX_CLEAR_FAILURES=$((TMUX_NOTIFY_INBOX_CLEAR_FAILURES + 1))
            status=1
        fi
    done
    tmux_notify_inbox_sync_counts || status=1
    return "$status"
}

# Wrappers normalize their native event/subtype here, then report through the
# existing --notify-kind/--notify-source CLI contract. Keep payload extraction
# and event whitelists in the adapter: lifecycle names differ between agents.
tmux_notify_event_kind() {
    local agent="$1" event="$2" subtype="${3:-}" kind=complete
    case "$agent:$event:$subtype" in
        claude:PostToolUseFailure:*|claude:Notification:permission_prompt|claude:Notification:idle_prompt|claude:Notification:elicitation_dialog|\
        kimi:PermissionRequest:*|kimi:StopFailure:*|kimi:Notification:permission_prompt|kimi:Notification:idle_prompt|\
        grok:post_tool_use_failure:*|grok:notification:permission_prompt|grok:notification:idle_prompt|\
        opencode:permission.asked:*|opencode:session.error:*|step:ui_prompt_start:*)
            kind=attention
            ;;
    esac
    case "$agent" in
        codex|pi|omp|step)
            case "$event" in
                *permission*|*Permission*|*error*|*Error*|*failure*|*Failure*) kind=attention ;;
            esac
            ;;
    esac
    printf '%s' "$kind"
}

# Only a per-agent override becomes a CLI argument. Unset/empty values inherit
# the platform's global setting, including when a custom jump command is used.
tmux_notify_agent_bell_arg() {
    local variable="${1}_NOTIFY_BELL"
    local value="${!variable:-}"
    [ -n "$value" ] || return 0
    if is_truthy "$value"; then
        printf '%s' '--bell'
    else
        printf '%s' '--no-bell'
    fi
}

# Open only a terminal device supplied by the tmux client inventory. Use a
# subshell so the private descriptor never replaces a caller's descriptor.
# Writing the client TTY bypasses pane input/output and tmux's alert-bell hook.
tmux_notify_write_bell() (
    local tty="${1:-}"
    case "$tty" in
        /dev/*) ;;
        *) return 1 ;;
    esac
    [ -c "$tty" ] && [ -w "$tty" ] || return 1
    exec 3>"$tty" || return 1
    [ -t 3 ] || return 1
    printf '\007' >&3
)

tmux_notify_ring_bell() {
    local session_id="$1" rows="$2" row="" tty="" seen=$'\n'
    is_truthy "${BELL:-0}" || return 0
    [ -n "$session_id" ] || return 0
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        read_tmux_client_row "$row"
        [ "$CLIENT_SESSION_ID" = "$session_id" ] || continue
        tty="$CLIENT_TTY"
        [ -n "$tty" ] || continue
        case "$seen" in
            *$'\n'"$tty"$'\n'*) continue ;;
        esac
        seen+="$tty"$'\n'
        if ! tmux_notify_write_bell "$tty" 2>/dev/null; then
            log_debug "terminal bell skipped: cannot write to client tty=$tty"
        fi
    done <<<"$rows"
    return 0
}

tmux_notify_route_notification() {
    local target="$1" title="$2" body="$3" kind="${4:-complete}" source="${5:-tmux-notify-jump}"
    TMUX_NOTIFY_ROUTE_DESKTOP=0
    local mode="" rows="" info=""
    mode="$(tmux_notify_remote_mode)"
    rows="$(tmux_terminal_client_rows 2>/dev/null || true)"
    info="$(tmux_notify_inbox_target_info "$target")"
    local session_id="" window_id="" pane_id="" session_name="" window_index=""
    local target_info_available=0
    if [ -n "$info" ]; then
        IFS='|' read -r session_id window_id pane_id window_index session_name <<<"$info"
        if [ -n "$session_id" ] && is_pane_id "$pane_id"; then
            target_info_available=1
        fi
    fi
    local visible=0 local_client=0 remote_client=0 unknown_client=0
    if [ "$target_info_available" -eq 1 ]; then
        tmux_notify_ring_bell "$session_id" "$rows"
    fi
    local remote_target_client=0 unknown_target_client=0 row message client_state
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        read_tmux_client_row "$row"
        client_state="$(tmux_client_pid_ssh_state "${CLIENT_PID:-}")"
        case "$client_state" in
            remote) remote_client=1 ;;
            local) local_client=1 ;;
            *) unknown_client=1 ;;
        esac
        [ "$target_info_available" -eq 1 ] || continue
        [ "$CLIENT_SESSION_ID" = "$session_id" ] || continue
        if [ "$CLIENT_PANE_ID" = "$pane_id" ]; then visible=1; fi
        case "$client_state" in
            remote)
                remote_target_client=1
                if [ "$mode" = "tmux" ] || [ "$mode" = "both" ]; then
                    message="[$(tmux_notify_compact_text "$source")] $(tmux_notify_compact_text "$title")"
                    tmux_cmd display-message -c "$CLIENT_NAME" \
                        "${message}: $(tmux_notify_compact_text "$body")" >/dev/null 2>&1 || true
                fi
                ;;
            unknown)
                unknown_target_client=1
                ;;
        esac
    done <<<"$rows"
    if [ "$target_info_available" -eq 1 ] \
        && { [ "$mode" = "tmux" ] || [ "$mode" = "both" ]; }; then
        if [ "$visible" -eq 0 ]; then
            tmux_notify_inbox_enqueue "$target" "$kind" "$source" "$title" || true
        else
            tmux_notify_inbox_ack_pane "$pane_id"
        fi
    fi
    case "$mode" in
        desktop|both)
            TMUX_NOTIFY_ROUTE_DESKTOP=1
            ;;
        tmux)
            local remote_blocker="$remote_target_client" unknown_blocker="$unknown_target_client"
            if [ "$target_info_available" -eq 0 ]; then
                remote_blocker="$remote_client"
                unknown_blocker="$unknown_client"
            fi
            if [ "$remote_blocker" -eq 0 ] && [ "$unknown_blocker" -eq 0 ] \
                && { [ "$local_client" -eq 1 ] || ! tmux_notify_process_is_remote_ssh; }; then
                TMUX_NOTIFY_ROUTE_DESKTOP=1
            fi
            ;;
    esac
    log_debug "notification route mode=$mode target_info=$target_info_available local_client=$local_client remote_client=$remote_client unknown_client=$unknown_client remote_target=$remote_target_client unknown_target=$unknown_target_client desktop=$TMUX_NOTIFY_ROUTE_DESKTOP"
    export TMUX_NOTIFY_ROUTE_DESKTOP
}

tmux_notify_inbox_ack_client() {
    local client="$1" pane=""
    [ -n "$client" ] || return 0
    pane="$(tmux_cmd display-message -p -c "$client" '#{pane_id}' 2>/dev/null || true)"
    [ -n "$pane" ] && tmux_notify_inbox_ack_pane "$pane"
}

tmux_notify_inbox_next() {
    local sender_tty="${1:-}" root="" list="" dir row="" current_pane=""
    root="$(tmux_notify_inbox_root)"
    local now=""
    now="$(now_ms)"
    tmux_notify_inbox_secure_dir "$root" 1 || return 1
    tmux_notify_inbox_gc "$root" "$now"
    row="$(tmux_notify_inbox_client "$sender_tty" || true)"
    if [ -n "$row" ]; then
        read_tmux_client_row "$row"
        current_pane="$CLIENT_PANE_ID"
        sender_tty="${sender_tty:-$CLIENT_TTY}"
    fi
    for dir in "$root"/*; do
        tmux_notify_inbox_entry_dir_is_valid "$dir" || continue
        tmux_notify_inbox_entry_read "$dir"
        [ -z "$current_pane" ] || [ "$INBOX_PANE_ID" != "$current_pane" ] || continue
        local rank=1
        [ "${INBOX_KIND:-complete}" = "attention" ] && rank=0
        list+="$rank|${INBOX_FIRST_MS:-0}|${dir##*/}"$'\n'
    done
    local selected_id=""
    selected_id="$(printf '%s' "$list" | sort -n -t '|' -k1,1 -k2,2 | head -n 1 | cut -d '|' -f3- || true)"
    [ -n "$selected_id" ] || { tmux_notify_inbox_sync_counts; return 0; }
    tmux_notify_inbox_select "$selected_id" "$sender_tty"
}

tmux_notify_inbox_select() {
    local selected_id="$1" sender_tty="${2:-}" root="" selected=""
    tmux_notify_inbox_id_is_valid "$selected_id" || return 1
    root="$(tmux_notify_inbox_root)"
    selected="$root/$selected_id"
    tmux_notify_inbox_entry_dir_is_valid "$selected" || return 0
    tmux_notify_inbox_entry_read "$selected"
    is_pane_id "$INBOX_PANE_ID" || return 1
    # Missing IDs and failed queries are different: retire stale notices only
    # after a successful, complete snapshot. Every live session has a pane.
    # Identity-only rows also avoid delimiter issues with session/window names.
    local inventory="" sid wid pane extra client="" row="" target_pane="" target_window=""
    local pane_match="" window_match="" session_found=0
    inventory="$(tmux_cmd list-panes -a -F '#{session_id}|#{window_id}|#{pane_id}' 2>/dev/null)" || return 1
    [ -n "$inventory" ] || return 1
    while IFS='|' read -r sid wid pane extra; do
        # An unsupported format or truncated row is not evidence of absence.
        [[ "$sid" =~ ^\$[0-9]+$ && "$wid" =~ ^@[0-9]+$ ]] || return 1
        if ! is_pane_id "$pane" || [ -n "$extra" ]; then return 1; fi
        if [ "$sid" = "$INBOX_SESSION_ID" ]; then session_found=1; fi
        # A linked window may appear in several sessions. Prefer the recorded
        # session when still linked there; otherwise follow a live owner.
        if [ "$pane" = "$INBOX_PANE_ID" ] \
            && { [ -z "$pane_match" ] || [ "$sid" = "$INBOX_SESSION_ID" ]; }; then
            pane_match="$sid|$wid|$pane"
        fi
        if [ "$wid" = "$INBOX_WINDOW_ID" ] \
            && { [ -z "$window_match" ] || [ "$sid" = "$INBOX_SESSION_ID" ]; }; then
            window_match="$sid|$wid"
        fi
    done <<<"$inventory"
    if [ -n "$pane_match" ]; then
        IFS='|' read -r INBOX_SESSION_ID INBOX_WINDOW_ID target_pane <<<"$pane_match"
    elif [ -n "$window_match" ]; then
        IFS='|' read -r INBOX_SESSION_ID target_window <<<"$window_match"
        INBOX_WINDOW_ID="$target_window"
    elif [ "$session_found" -eq 0 ]; then
        tmux_notify_inbox_ack_pane "$INBOX_PANE_ID"
        return 1
    fi
    row="$(tmux_notify_inbox_client "$sender_tty" "$INBOX_SESSION_ID")" || return 1
    read_tmux_client_row "$row"
    client="$CLIENT_NAME"
    if [ -n "$target_pane" ]; then
        tmux_cmd switch-client -c "$client" -t "$INBOX_SESSION_ID" ';' \
            select-window -t "$INBOX_SESSION_ID:$INBOX_WINDOW_ID" ';' \
            select-pane -t "$INBOX_PANE_ID" >/dev/null 2>&1 || return 1
    elif [ -n "$target_window" ]; then
        tmux_cmd switch-client -c "$client" -t "$INBOX_SESSION_ID" ';' \
            select-window -t "$INBOX_SESSION_ID:$INBOX_WINDOW_ID" >/dev/null 2>&1 || return 1
    else
        tmux_cmd switch-client -c "$client" -t "$INBOX_SESSION_ID" >/dev/null 2>&1 || return 1
    fi
    tmux_notify_verify_client_target "$client" "$INBOX_SESSION_ID" "$target_pane" "$target_window" || return 1
    # Visiting a pane acknowledges both priorities even without focus hooks.
    # A verified window/session fallback also retires all notices for the dead pane.
    tmux_notify_inbox_ack_pane "$INBOX_PANE_ID"
}

tmux_notify_inbox_list() {
    local root="" dir
    root="$(tmux_notify_inbox_root)"
    tmux_notify_inbox_secure_dir "$root" || return 1
    for dir in "$root"/*; do
        tmux_notify_inbox_entry_dir_is_valid "$dir" || continue
        tmux_notify_inbox_entry_read "$dir"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${INBOX_KIND:-complete}" "${INBOX_COUNT:-1}" \
            "$INBOX_PANE_ID" "$INBOX_SOURCE" "$INBOX_TITLE"
    done
}

# Quote generated callbacks for the shell used by tmux and fzf. POSIX single
# quotes also work with /bin/sh and macOS's default Bash 3.2.
tmux_notify_shell_command() {
    local arg
    for arg in "$@"; do
        arg="${arg//\'/\'\\\'\'}"
        printf "'%s' " "$arg"
    done
}

# Carry the effective config, cache and socket into a popup/menu callback.
# run-shell inherits the server environment, which may differ from this caller.
# Callers also pass --tmux-socket so config loading cannot override the server.
tmux_notify_inbox_command() {
    local cache="" path="${TMUX_NOTIFY_ENTRYPOINT:-}" config=""
    cache="$(tmux_notify_inbox_cache_root; printf '.')"
    cache="${cache%.}"
    [ -n "$path" ] || path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tmux-notify-jump"
    config="$(tmux_notify_config_path && printf '.')" || return 1
    config="${config%.}"
    tmux_notify_shell_command env "TMUX_NOTIFY_CONFIG=$config" "XDG_CACHE_HOME=$cache" \
        "TMUX_NOTIFY_TMUX_SOCKET=${TMUX_NOTIFY_TMUX_SOCKET:-}" "$path" "$@"
}

# Return an ordinary client row. An explicitly supplied TTY must still exist;
# never move another terminal when the caller has detached in the meantime.
tmux_notify_inbox_client() {
    local sender_tty="${1:-}" session_id="${2:-}" rows="" row="" current=""
    rows="$(tmux_terminal_client_rows)"
    if [ -n "$sender_tty" ]; then
        find_tmux_terminal_client_by_tty "$rows" "$sender_tty"
        return $?
    fi
    if [ -n "$session_id" ]; then
        row="$(best_tmux_terminal_client "$rows" "$session_id" || true)"
        if [ -n "$row" ]; then printf '%s' "$row"; return 0; fi
    fi
    # Outside tmux, display-message returns an ambient client even when several
    # terminals are attached. That is not evidence of who invoked the picker.
    if [ -n "${TMUX:-}" ]; then
        current="$(tmux_cmd display-message -p '#{client_name}' 2>/dev/null || true)"
        while IFS= read -r row; do
            [ -n "$row" ] || continue
            read_tmux_client_row "$row"
            if [ "$CLIENT_NAME" = "$current" ]; then printf '%s' "$row"; return 0; fi
        done <<<"$rows"
    fi
    single_tmux_terminal_client "$rows"
}

# id, pane, kind, source, live location, age, count, title. One pane inventory
# serves the entire list; the final human label may contain the separator.
# Listing maintains private permissions, expiry and counts; only doctor is
# strictly read-only.
tmux_notify_inbox_picker_rows() {
    local kind="${1:-}" source="${2:-}" session="${3:-}" since="${4:-0}"
    local current_pane="${5:-}"
    local root="" inventory="" now="" dir rows="" rank age last
    root="$(tmux_notify_inbox_root)"
    tmux_notify_inbox_secure_dir "$root" || return 1
    now="$(now_ms)"
    tmux_notify_inbox_gc "$root" "$now"
    tmux_notify_inbox_sync_counts
    inventory="$(tmux_cmd list-panes -a -F '#{pane_id}|#{session_id}|#{window_id}|#{window_index}|#{pane_index}|#{session_name}' 2>/dev/null)" || return 1
    for dir in "$root"/*; do
        tmux_notify_inbox_entry_dir_is_valid "$dir" || continue
        tmux_notify_inbox_entry_read "$dir"
        case "$INBOX_KIND" in attention|complete) ;; *) continue ;; esac
        is_pane_id "$INBOX_PANE_ID" || continue
        [ -z "$kind" ] || [ "$kind" = "$INBOX_KIND" ] || continue
        [ -z "$source" ] || [ "$source" = "$INBOX_SOURCE" ] || continue
        local pane sid wid win index name match="" fallback="" location=""
        while IFS='|' read -r pane sid wid win index name; do
            [ "$pane" = "$INBOX_PANE_ID" ] || continue
            [ -n "$fallback" ] || fallback="$sid|$wid|$win|$index|$name"
            if [ "$sid" = "$INBOX_SESSION_ID" ]; then
                match="$sid|$wid|$win|$index|$name"
                break
            fi
        done <<<"$inventory"
        match="${match:-$fallback}"
        if [ -n "$match" ]; then
            IFS='|' read -r sid wid win index name <<<"$match"
            location="$name:$win.$index"
        else
            sid="$INBOX_SESSION_ID"
            name="$INBOX_SESSION_NAME"
            location="$name:${INBOX_WINDOW_INDEX:-?} [closed pane]"
        fi
        [ -z "$session" ] || [ "$session" = "$sid" ] || [ "$session" = "$name" ] || continue
        [ -z "$current_pane" ] || [ "$INBOX_PANE_ID" != "$current_pane" ] || location+=' [current]'
        last="${INBOX_LAST_MS:-0}"
        is_integer "$last" || last=0
        age=0
        [ "$now" -le "$last" ] || age=$(((now - last) / 1000))
        [ "$since" -eq 0 ] || [ "$age" -le "$since" ] || continue
        rank=1
        [ "$INBOX_KIND" != attention ] || rank=0
        # Strip terminal control bytes before rendering event text in a picker.
        location="$(tmux_notify_compact_text "$location" | LC_ALL=C tr '\000-\037\177' ' ')"
        local label="" agent=""
        label="$(tmux_notify_compact_text "${INBOX_TITLE:-(untitled)}" | LC_ALL=C tr '\000-\037\177' ' ')"
        agent="$(tmux_notify_compact_text "${INBOX_SOURCE:-tmux-notify-jump}" | LC_ALL=C tr '\000-\037\177' ' ')"
        rows+="$rank"$'\t'"${INBOX_FIRST_MS:-0}"$'\t'"${dir##*/}"$'\t'"$INBOX_PANE_ID"$'\t'"$INBOX_KIND"$'\t'"$agent"$'\t'"$location"$'\t'"${age}s"$'\t'"${INBOX_COUNT:-1}"$'\t'"$label"$'\n'
    done
    printf '%s' "$rows" | sort -t $'\t' -k1,1n -k2,2n | cut -f3-
}

tmux_notify_inbox_preview() {
    is_pane_id "${1:-}" || return 1
    # -S includes history plus the visible screen; tail bounds the total rows.
    tmux_cmd capture-pane -p -t "$1" -S -80 2>/dev/null | tail -n 80 || printf 'Pane is no longer available.\n'
}

# Probe the options used by the picker without opening a UI or running preview.
# Ignore personal defaults just as the actual picker does.
tmux_notify_fzf_supported() {
    command -v fzf >/dev/null 2>&1 || return 1
    local row=$'id\tprobe' selected=""
    selected="$(printf '%s\n' "$row" | env FZF_DEFAULT_OPTS= FZF_DEFAULT_OPTS_FILE= FZF_DEFAULT_COMMAND= SHELL=/bin/sh \
        fzf --filter=probe --delimiter=$'\t' --with-nth=2.. --no-sort --reverse --query='' \
            --prompt='Inbox> ' --header='probe' --preview=':' \
            --preview-window='down:40%:wrap' 2>/dev/null)" || return 1
    # Some fzf versions print the transformed --with-nth fields in filter mode.
    [ -n "$selected" ]
}

# auto: fzf popup on tmux >= 3.2, otherwise a paginated tmux >= 3.0 menu.
# --inline runs fzf in the current terminal, including on older tmux versions.
tmux_notify_inbox_pick() {
    local kind="" source="" session="" since=0 query="" menu=0 inline=0 page=0 offset=""
    local sender_tty="${TMUX_NOTIFY_SENDER_TTY:-}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --menu) menu=1 ;;
            --inline) inline=1 ;;
            --kind|--source|--session|--since|--query|--page|--offset|--sender-tty|--tmux-socket)
                local opt="$1"
                shift
                [ "$#" -gt 0 ] || die "$opt requires an argument"
                case "$opt" in
                    --kind) kind="$1" ;;
                    --source) source="$1" ;;
                    --session) session="$1" ;;
                    --since) since="$1" ;;
                    --query) query="$1" ;;
                    --page) page="$1" ;;
                    --offset) offset="$1" ;;
                    --sender-tty) sender_tty="$1" ;;
                    --tmux-socket) TMUX_NOTIFY_TMUX_SOCKET="$1" ;;
                esac
                ;;
            *) die "Unknown Inbox picker option: $1" ;;
        esac
        shift
    done
    case "$kind" in ''|attention|complete) ;; *) die '--kind must be attention or complete' ;; esac
    if ! is_integer "$since" || ! is_integer "$page"; then
        die '--since and --page require non-negative integers'
    fi
    since=$((10#$since))
    page=$((10#$page))
    if [ -n "$offset" ]; then
        is_integer "$offset" || die '--offset requires a non-negative integer'
        offset=$((10#$offset))
    fi
    ensure_tmux_notify_socket_from_env
    require_tool tmux
    local rows="" row="" client="" command=""
    row="$(tmux_notify_inbox_client "$sender_tty" || true)"
    local current_pane=""
    if [ -n "$row" ]; then
        read_tmux_client_row "$row"
        current_pane="$CLIENT_PANE_ID"
    fi
    rows="$(tmux_notify_inbox_picker_rows "$kind" "$source" "$session" "$since" "$current_pane")" || return 1
    if [ -z "$rows" ]; then printf 'Inbox has no matching items.\n'; return 0; fi
    [ -n "$row" ] || { warn 'Inbox picker needs an ordinary tmux client; pass --sender-tty'; return 1; }
    read_tmux_client_row "$row"
    client="$CLIENT_NAME"
    sender_tty="$CLIENT_TTY"
    local -a filters=(--source "$source" --session "$session" --since "$since" --query "$query" --sender-tty "$sender_tty" --tmux-socket "${TMUX_NOTIFY_TMUX_SOCKET:-}")
    [ -z "$kind" ] || filters+=(--kind "$kind")
    if [ "$menu" -eq 0 ] && tmux_notify_fzf_supported; then
        if [ "$inline" -eq 0 ] && tmux_notify_tmux_version_at_least 3 2; then
            command="$(tmux_notify_inbox_command --inbox-pick --inline "${filters[@]}")"
            local -a popup_args=(-c "$client" -E -w '85%' -h '75%')
            # Popups exist in 3.2, but their title option arrived in 3.3.
            if tmux_notify_tmux_version_at_least 3 3; then popup_args+=(-T 'Inbox'); fi
            if tmux_cmd display-popup "${popup_args[@]}" "$command"; then return 0; fi
            warn 'Inbox popup failed; falling back to the menu'
        elif [ "$inline" -eq 1 ]; then
            local selected="" result=0 preview=""
            preview="$(tmux_notify_inbox_command --inbox-preview) {2} $(tmux_notify_shell_command --tmux-socket "${TMUX_NOTIFY_TMUX_SOCKET:-}")"
            selected="$(printf '%s\n' "$rows" | env FZF_DEFAULT_OPTS= FZF_DEFAULT_OPTS_FILE= FZF_DEFAULT_COMMAND= SHELL=/bin/sh \
                fzf --delimiter=$'\t' --with-nth=2.. --no-sort --reverse --query="$query" \
                    --prompt='Inbox> ' --header='Enter: jump  Esc: cancel | pane kind agent location age count title' \
                    --preview="$preview" --preview-window='down:40%:wrap')" || result=$?
            case "$result" in 0) ;; 1|130) return 0 ;; *) return "$result" ;; esac
            [ -n "$selected" ] || return 0
            tmux_notify_inbox_select "${selected%%$'\t'*}" "$sender_tty"
            return $?
        fi
    fi
    if ! tmux_notify_tmux_version_at_least 3 0; then
        printf '%s\n' "$rows" | cut -f2-
        warn 'Interactive Inbox menus require tmux 3.0; use --inline with fzf or --inbox-next'
        return 0
    fi
    if [ -n "$query" ]; then
        rows="$(printf '%s\n' "$rows" | awk -v query="$query" 'index(tolower(substr($0, index($0, "\t") + 1)), tolower(query))')"
    fi
    [ -n "$rows" ] || { printf 'Inbox has no matching items.\n'; return 0; }
    local height="" width="" page_size=35 dimensions="" dimension_client dimension_tty dimension_height dimension_width
    # Older tmux cannot reliably parse display-message -c. Match a batch client
    # inventory instead, so another terminal's dimensions cannot size this menu.
    dimensions="$(tmux_cmd list-clients -F '#{client_name}|#{client_tty}|#{client_height}|#{client_width}' 2>/dev/null)" || dimensions=""
    while IFS='|' read -r dimension_client dimension_tty dimension_height dimension_width; do
        if [ "$dimension_client" = "$client" ] || [ "$dimension_tty" = "$client" ]; then
            height="$dimension_height"
            width="$dimension_width"
            break
        fi
    done <<<"$dimensions"
    if ! is_integer "$height" || [ "$height" -lt 5 ] || ! is_integer "$width" || [ "$width" -lt 9 ]; then
        printf '%s\n' "$rows" | cut -f2-
        warn 'Inbox menu needs a client at least 5 rows high and 9 columns wide; use --inline with fzf or --inbox-next'
        return 0
    fi
    # tmux silently omits a menu taller than the client. Reserve two border
    # rows and both navigation rows, including on the first and last pages.
    height=$((10#$height))
    width=$((10#$width))
    if [ "$height" -lt 39 ]; then page_size=$((height - 4)); fi
    # Older tmux also silently omits wide menus. Allow four columns for border
    # and padding, plus four for the space and single-character shortcut (x).
    local label_width=$((width - 8))
    [ "$label_width" -le 60 ] || label_width=60
    local -a items=() keys=(1 2 3 4 5 6 7 8 9 a b c d e f g h i j k l m n o p q r s t u v w x y z)
    local id pane agent location age count title label n=0 shown=0 start="${offset:-$((page * page_size))}" more=0
    while IFS=$'\t' read -r id pane kind agent location age count title; do
        [ -n "$id" ] || continue
        n=$((n + 1))
        [ "$n" -gt "$start" ] || continue
        if [ "$shown" -ge "$page_size" ]; then more=1; break; fi
        label="$kind $agent $location ($age, x$count) $title"
        label="$(truncate_text_columns "$label_width" "$label")"
        label="${label//#/##}"
        command="$(tmux_notify_inbox_command --inbox-select "$id" --sender-tty "$sender_tty" --tmux-socket "${TMUX_NOTIFY_TMUX_SOCKET:-}")"
        items+=("$label" "${keys[$shown]}" "run-shell -b $(tmux_notify_shell_command "$command")")
        shown=$((shown + 1))
    done <<<"$rows"
    # Offsets keep the next page contiguous if the terminal is resized between
    # callbacks; recomputing page * capacity could skip pending entries.
    if [ "$start" -gt 0 ]; then
        local previous=$((start - page_size))
        [ "$previous" -ge 0 ] || previous=0
        command="$(tmux_notify_inbox_command --inbox-pick --menu --offset "$previous" "${filters[@]}")"
        label="$(truncate_text_columns "$label_width" 'Previous page')"
        items+=("$label" '[' "run-shell -b $(tmux_notify_shell_command "$command")")
    fi
    if [ "$more" -eq 1 ]; then
        command="$(tmux_notify_inbox_command --inbox-pick --menu --offset "$((start + shown))" "${filters[@]}")"
        label="$(truncate_text_columns "$label_width" 'Next page')"
        items+=("$label" ']' "run-shell -b $(tmux_notify_shell_command "$command")")
    fi
    [ "${#items[@]}" -gt 0 ] || { printf 'Inbox has no matching items.\n'; return 0; }
    tmux_cmd display-menu -c "$client" -T 'Inbox' -x C -y C "${items[@]}"
}

tmux_notify_tmux_version_at_least() {
    local major="$1" minor="$2" version="" actual_major="" actual_minor=""
    version="$(tmux_cmd display-message -p '#{version}' 2>/dev/null || true)"
    [ -n "$version" ] || version="$(tmux_cmd -V 2>/dev/null || true)"
    version="${version#tmux }"
    if [[ "$version" =~ ([0-9]+)\.([0-9]+) ]]; then
        actual_major="${BASH_REMATCH[1]}"
        actual_minor="${BASH_REMATCH[2]}"
        [ "$actual_major" -gt "$major" ] || { [ "$actual_major" -eq "$major" ] && [ "$actual_minor" -ge "$minor" ]; }
        return $?
    fi
    return 1
}

# Diagnostics never create/chmod state or install hooks. Optional capabilities
# are warnings; broken server access or unsafe/unreadable state fails the check.
TMUX_NOTIFY_DOCTOR_AGENTS=(codex claude kimi grok opencode pi step omp)

tmux_notify_doctor_agent_config_index() {
    local spec="$1" agent="${1%%=*}" path="${1#*=}" i
    if [ "$spec" = "$path" ] || [ -z "$path" ]; then
        printf 'Error: --agent-config requires agent=path\n' >&2
        return 1
    fi
    for i in "${!TMUX_NOTIFY_DOCTOR_AGENTS[@]}"; do
        if [ "$agent" = "${TMUX_NOTIFY_DOCTOR_AGENTS[$i]}" ]; then
            printf '%s' "$i"
            return 0
        fi
    done
    printf 'Error: Unknown doctor agent: %s\n' "$agent" >&2
    return 1
}

tmux_notify_doctor_cli() {
    local -a agent_configs=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --tmux-socket)
                shift
                [ "$#" -gt 0 ] || die '--tmux-socket requires an argument'
                TMUX_NOTIFY_TMUX_SOCKET="$1"
                ;;
            --agent-config)
                shift
                if [ "$#" -eq 0 ]; then
                    printf 'Error: --agent-config requires agent=path\n' >&2
                    return 1
                fi
                tmux_notify_doctor_agent_config_index "$1" >/dev/null || return 1
                agent_configs+=("$1")
                ;;
            *) die "Unknown doctor option: $1" ;;
        esac
        shift
    done
    ensure_tmux_notify_socket_from_env
    # Bash 3.2 treats an empty array as unset under nounset.
    tmux_notify_doctor ${agent_configs[@]+"${agent_configs[@]}"}
}

tmux_notify_doctor_line() {
    local level="$1" label="$2" value="${3:-}" clean=""
    clean="$(tmux_notify_compact_text "$value" | LC_ALL=C tr '\000-\037\177' ' ')"
    printf '%-4s %-24s %s\n' "$level" "$label" "$clean"
}

tmux_notify_doctor_tool() {
    local tool="$1" purpose="$2" path=""
    path="$(command -v "$tool" 2>/dev/null || true)"
    if [ -n "$path" ]; then
        tmux_notify_doctor_line OK "$tool" "$path ($purpose)"
    else
        tmux_notify_doctor_line WARN "$tool" "unavailable ($purpose)"
    fi
}

tmux_notify_doctor_private_path() {
    local path="$1" expected="$2" mode=""
    [ ! -L "$path" ] && [ -O "$path" ] && [ -r "$path" ] && [ -w "$path" ] || return 1
    if [ -d "$path" ]; then
        [ "$expected" = 700 ] && [ -x "$path" ] || return 1
    else
        [ "$expected" = 600 ] && [ -f "$path" ] || return 1
    fi
    mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || true)"
    [ "$mode" = "$expected" ]
}

# These are user-level installation paths, not proof of runtime registration.
# Explicit agent=path inputs let diagnostics inspect profiles/project configs
# without copying every agent's evolving path or config precedence rules.
tmux_notify_doctor_agents() {
    local base="" home="${HOME:-}" i=0 spec="" agent="" path=""
    base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local -a wrappers=(notify-codex.sh notify-claude-code.sh notify-kimi-code.sh notify-grok.sh notify-opencode.sh notify-pi.sh notify-step.sh notify-omp.sh)
    local -a configs=(
        "${CODEX_CONFIG_PATH:-$home/.codex/config.toml}"
        "${CLAUDE_CONFIG_PATH:-$home/.claude/settings.json}"
        "${KIMI_CONFIG_PATH:-$home/.kimi-code/config.toml}"
        "${GROK_HOOKS_PATH:-${GROK_HOME:-$home/.grok}/hooks}/tmux-notify-jump.json"
        "${OPENCODE_PLUGIN_PATH:-$home/.config/opencode/plugins}/tmux-notify-jump.ts"
        "${PI_EXTENSION_PATH:-$home/.pi/agent/extensions}/tmux-notify-jump.ts"
        "${STEP_EXTENSION_PATH:-$home/.stepcode/agent/extensions}/tmux-notify-jump.ts"
        "${OMP_EXTENSION_PATH:-$home/.omp/agent/extensions}/tmux-notify-jump.ts"
    )
    for spec in "$@"; do
        i="$(tmux_notify_doctor_agent_config_index "$spec")" || return 1
        configs[i]="${spec#*=}"
    done
    for i in "${!TMUX_NOTIFY_DOCTOR_AGENTS[@]}"; do
        agent="${TMUX_NOTIFY_DOCTOR_AGENTS[$i]}"
        path="$base/${wrappers[$i]}"
        if [ -f "$path" ] && [ -x "$path" ]; then
            tmux_notify_doctor_line OK "Wrapper $agent" "$path (executable)"
        else
            tmux_notify_doctor_line WARN "Wrapper $agent" "$path (missing or not executable)"
        fi
        # TypeScript bridges invoke a command on PATH unless overridden.
        case "$agent" in
            opencode|pi|step|omp) tmux_notify_doctor_tool "${wrappers[$i]}" "$agent bridge default; *_NOTIFY_CMD may override" ;;
        esac
        path="${configs[$i]}"
        if [ ! -f "$path" ] || [ ! -r "$path" ]; then
            tmux_notify_doctor_line WARN "Config $agent" "$path (absent or unreadable; optional integration)"
        elif LC_ALL=C awk -v needle="${wrappers[$i]}" 'index($0, needle) { found=1 } END { exit !found }' "$path"; then
            tmux_notify_doctor_line OK "Config $agent" "$path (wrapper text reference found; registration unverified)"
        else
            tmux_notify_doctor_line WARN "Config $agent" "$path (no wrapper text reference; check hook/bridge configuration)"
        fi
    done
}

tmux_notify_doctor() {
    local spec
    for spec in "$@"; do
        tmux_notify_doctor_agent_config_index "$spec" >/dev/null || return 1
    done
    local config=""
    config="$(tmux_notify_config_path && printf '.')" || return 1
    config="${config%.}"
    local result=0 version="" server="" root="" pinned="" status="" hook_table=""
    printf 'tmux-notify-jump diagnostics\n'
    if [ -z "$config" ]; then
        tmux_notify_doctor_line OK 'Configuration' '(unset) using environment/defaults'
    elif [ -e "$config" ]; then
        if [ -f "$config" ] && [ -r "$config" ]; then
            tmux_notify_doctor_line OK 'Configuration' "$config"
        else
            tmux_notify_doctor_line FAIL 'Configuration' "$config (not a readable file)"
            result=1
        fi
    else
        tmux_notify_doctor_line WARN 'Configuration' "$config (absent; using environment/defaults)"
    fi
    tmux_notify_doctor_line OK 'Routing mode' "$(tmux_notify_remote_mode)"
    if ! command -v tmux >/dev/null 2>&1; then
        tmux_notify_doctor_line FAIL 'tmux' 'unavailable; Inbox and jump need tmux (focus-only remains available)'
        return 1
    fi
    version="$(tmux_cmd -V 2>/dev/null || true)"
    tmux_notify_doctor_line OK 'tmux executable' "$version"
    server="$(tmux_cmd display-message -p '#{pid}' 2>/dev/null || true)"
    if ! is_integer "$server"; then
        tmux_notify_doctor_line FAIL 'tmux server' "not reachable; socket=${TMUX_NOTIFY_TMUX_SOCKET:-default (or TMUX)}"
        return 1
    fi
    local socket=""
    socket="$(tmux_cmd display-message -p '#{socket_path}' 2>/dev/null || true)"
    version="$(tmux_cmd display-message -p '#{version}' 2>/dev/null || true)"
    tmux_notify_doctor_line OK 'tmux server' "$version pid=$server socket=$socket"
    if tmux_notify_fzf_supported; then
        tmux_notify_doctor_line OK fzf "$(command -v fzf) (picker options supported)"
    else
        tmux_notify_doctor_line WARN fzf 'missing or picker options unsupported; falling back to tmux menu'
    fi
    tmux_notify_doctor_tool jq 'agent wrappers; missing jq makes hooks no-op'
    tmux_notify_doctor_tool ps 'optional pane ancestry resolution'
    tmux_notify_doctor_agents "$@" || return 1
    case "$(uname -s 2>/dev/null || true)" in
        Darwin)
            tmux_notify_doctor_tool terminal-notifier 'desktop notifications'
            tmux_notify_doctor_tool osascript 'desktop terminal activation'
            ;;
        *)
            tmux_notify_doctor_tool notify-send 'desktop notifications'
            tmux_notify_doctor_tool xdotool 'optional X11 terminal activation'
            if [ -n "${DISPLAY:-}" ]; then
                tmux_notify_doctor_line OK 'X11 display' "$DISPLAY"
            else
                tmux_notify_doctor_line WARN 'X11 display' 'unset; desktop focus unavailable (tmux/SSH still works)'
            fi
            ;;
    esac
    if tmux_notify_tmux_version_at_least 3 2; then
        tmux_notify_doctor_line OK 'Inbox UI' 'popup and menu supported'
    elif tmux_notify_tmux_version_at_least 3 0; then
        tmux_notify_doctor_line WARN 'Inbox UI' 'menu supported; fzf popup needs tmux 3.2'
    else
        tmux_notify_doctor_line WARN 'Inbox UI' 'menus and acknowledgement hooks need tmux 3.0; use --inbox-next or --inline'
    fi
    root="$(tmux_notify_inbox_root)"
    pinned="$(tmux_cmd show-option -gqv @tmux-notify-jump-inbox-root 2>/dev/null || true)"
    if [ -z "$pinned" ]; then
        tmux_notify_doctor_line WARN 'Pinned Inbox path' 'not initialized; run --tmux-init or reload configured tmux file'
    elif ! tmux_notify_inbox_root_is_valid "$pinned"; then
        tmux_notify_doctor_line FAIL 'Pinned Inbox path' "$pinned (invalid; using default path)"
        result=1
    else
        tmux_notify_doctor_line OK 'Pinned Inbox path' "$pinned"
    fi
    if [ ! -e "$root" ] && [ ! -L "$root" ]; then
        tmux_notify_doctor_line OK 'Inbox permissions' "$root (not created yet)"
    elif ! tmux_notify_doctor_private_path "$root" 700; then
        tmux_notify_doctor_line FAIL 'Inbox permissions' "$root (need an owned, readable/writable directory with mode 700)"
        result=1
    else
        local entry file unsafe=0 entries=0
        for entry in "$root"/*; do
            tmux_notify_inbox_id_is_valid "${entry##*/}" || continue
            entries=$((entries + 1))
            if ! tmux_notify_doctor_private_path "$entry" 700; then unsafe=1; continue; fi
            for file in "$entry"/*; do
                [ -e "$file" ] || [ -L "$file" ] || continue
                if ! tmux_notify_doctor_private_path "$file" 600; then unsafe=1; fi
            done
        done
        if [ "$unsafe" -eq 1 ]; then
            tmux_notify_doctor_line FAIL 'Inbox permissions' "$root (unsafe entry ownership, permissions or symlinks)"
            result=1
        else
            tmux_notify_doctor_line OK 'Inbox permissions' "$root ($entries entries; directories 700, files 600)"
        fi
    fi
    status="$(tmux_cmd show-option -gqv status-right 2>/dev/null || true)"
    if ! is_truthy "${TMUX_NOTIFY_TMUX_STATUS:-1}"; then
        tmux_notify_doctor_line OK 'Status segment' 'disabled by TMUX_NOTIFY_TMUX_STATUS'
    elif [[ "$status" == *"$(tmux_notify_tmux_status_segment)"* ]]; then
        tmux_notify_doctor_line OK 'Status segment' 'installed in global status-right (session overrides may hide it)'
    else
        tmux_notify_doctor_line WARN 'Status segment' 'missing or customized; reload tmux config or run --tmux-init'
    fi
    hook_table="$(tmux_cmd show-hooks -g 2>/dev/null || true)"
    local hook command
    for hook in client-attached client-session-changed after-select-pane after-select-window client-focus-in; do
        command="$(tmux_notify_tmux_hook_command "$hook" "$hook_table")"
        if tmux_notify_tmux_is_ack_command "$command"; then
            tmux_notify_doctor_line OK "Hook $hook" 'acknowledgement installed at [900]'
        elif [ -n "$command" ]; then
            tmux_notify_doctor_line WARN "Hook $hook" 'slot [900] occupied by another command'
        else
            tmux_notify_doctor_line WARN "Hook $hook" 'acknowledgement missing; reload configured tmux file'
        fi
    done
    local key="" binding=""
    key="$(tmux_notify_tmux_effective_key)"
    binding="$(tmux_notify_tmux_prefix_binding "$key")"
    if [[ "$binding" == *--inbox-next* ]]; then
        tmux_notify_doctor_line OK 'Inbox binding' "prefix+$key jumps to next item"
    elif [ -n "$binding" ]; then
        tmux_notify_doctor_line WARN 'Inbox binding' "prefix+$key belongs to another command"
    else
        tmux_notify_doctor_line WARN 'Inbox binding' "prefix+$key missing; reload configured tmux file"
    fi
    return "$result"
}

tmux_notify_tmux_major_version() {
    local version=""
    version="$(tmux_cmd -V 2>/dev/null || true)"
    version="${version#tmux }"
    if [[ "$version" =~ ([0-9]+)\.[0-9]+ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

tmux_notify_tmux_status_segment() {
    printf '%s' ' #[fg=yellow]#{?@tmux-notify-jump-attention,?#{@tmux-notify-jump-attention} ,}#[fg=cyan]#{?@tmux-notify-jump-complete,!#{@tmux-notify-jump-complete} ,}'
}

tmux_notify_tmux_prefix_binding() {
    local key="$1"
    tmux_cmd list-keys -T prefix 2>/dev/null | awk -v key="$key" '
        {
            for (i = 1; i <= NF - 2; i++) {
                if ($i == "-T" && $(i + 1) == "prefix" && $(i + 2) == key) print
            }
        }
    ' || true
}

# Report whether a value can name the Inbox jump key.
#
# The accepted syntax is a single alphanumeric character: that is what the
# installer writes into @tmux-notify-jump-key and what a prefix-table lookup
# can match. The entry point, this library and the installer all validate
# through this predicate, so widening the syntax later is one change rather
# than three that drift apart.
tmux_notify_tmux_key_is_valid() {
    case "${1:-}" in
        [A-Za-z0-9]) return 0 ;;
    esac
    return 1
}

# Resolve the key the Inbox jump binding should use.
#
# An explicit --tmux-key (or TMUX_NOTIFY_TMUX_KEY) wins over TMUX_NOTIFY_KEY,
# which wins over the @tmux-notify-jump-key option, which falls back to N.
# Initialization and --doctor share this order so the doctor cannot report a key
# initialization would never bind.
#
# A value that is not a single alphanumeric character cannot name a tmux key, so
# it is reported instead of being quietly replaced. Silently falling back leaves
# the configuration reading one key while the fallback key stays bound: nothing
# jumps, and the taken key warning that would explain why never appears.
tmux_notify_tmux_effective_key() {
    local configured="" key=""
    configured="$(tmux_cmd show-option -gqv @tmux-notify-jump-key 2>/dev/null || true)"
    key="${TMUX_NOTIFY_TMUX_KEY:-${TMUX_NOTIFY_KEY:-${configured:-N}}}"
    if ! tmux_notify_tmux_key_is_valid "$key"; then
        warn "Inbox key '$key' is not one alphanumeric character; using N"
        key=N
    fi
    printf '%s' "$key"
}

# Print every prefix-table key bound to an Inbox jump command.
#
# The key and the install path are both user-configurable, so a binding this
# tool left behind is recognized by its command rather than by the key it sits
# on or the path it names. Looking only at the configured key would strand the
# previous binding whenever either setting changes.
tmux_notify_tmux_inbox_bindings() {
    tmux_cmd list-keys -T prefix 2>/dev/null | awk '
        index($0, "--inbox-next") == 0 { next }
        {
            for (i = 1; i <= NF - 2; i++) {
                if ($i == "-T" && $(i + 1) == "prefix") { print $(i + 2); next }
            }
        }
    ' || true
}

# Build the "<hook>[900]" acknowledgement command.
#
# The guard and the argument share one format, so a hook only spawns the script
# when the Inbox is non-empty and tmux can actually name what to acknowledge.
tmux_notify_tmux_ack_hook_command() {
    local quoted_path="$1" option="$2" format="$3" guard=""
    guard="#{&&:#{||:#{@tmux-notify-jump-attention},#{@tmux-notify-jump-complete}},$format}"
    printf '%s' "if-shell -F '$guard' { run-shell -b '$quoted_path $option \"$format\"' }"
}

# Report whether a hook command is one this tool installed.
tmux_notify_tmux_is_ack_command() {
    case "${1:-}" in
        *--inbox-ack-client*|*--inbox-ack-pane*) return 0 ;;
    esac
    return 1
}

# Print the command bound to "<hook>[900]" in a show-hooks table.
tmux_notify_tmux_hook_command() {
    local hook="$1" output="$2"
    printf '%s\n' "$output" | awk -v name="${hook}[900]" '
        $1 == name { sub(/^[^ ]+ /, ""); print; exit }
    ' || true
}

tmux_notify_tmux_init() {
    local path="${TMUX_NOTIFY_ENTRYPOINT:-tmux-notify-jump}" quoted_path="" key="" root=""
    printf -v quoted_path '%q' "$path"
    root="$(tmux_notify_inbox_default_root)"
    tmux_cmd set-option -gq @tmux-notify-jump-inbox-root "$root"
    key="$(tmux_notify_tmux_effective_key)"
    # An explicit --tmux-key is the one override worth recording. Without it the
    # binding, @tmux-notify-jump-key and --doctor disagree until something
    # re-reads the option, and a later --tmux-init silently migrates the binding
    # back to the configured key. An inherited TMUX_NOTIFY_TMUX_KEY stays
    # ephemeral on purpose: it may be a one-shot override for a single command.
    # The marker is private and set only by the entry point's own --tmux-key,
    # so an inherited key cannot be recorded by forging it in the environment.
    if [ "${_TMUX_NOTIFY_TMUX_KEY_EXPLICIT:-0}" = "1" ]; then
        tmux_cmd set-option -gq @tmux-notify-jump-key "$key"
    fi
    local status="" status_segment=""
    status="$(tmux_cmd show-option -gqv status-right 2>/dev/null || true)"
    status_segment="$(tmux_notify_tmux_status_segment)"
    if is_truthy "${TMUX_NOTIFY_TMUX_STATUS:-1}" \
        && [[ "$status" != *"$status_segment"* ]]; then
        status="${status}${status_segment}"
        tmux_cmd set-option -g status-right "$status"
    elif ! is_truthy "${TMUX_NOTIFY_TMUX_STATUS:-1}" \
        && [[ "$status" == *"$status_segment"* ]]; then
        status="${status%%"$status_segment"*}${status#*"$status_segment"}"
        tmux_cmd set-option -g status-right "$status"
    fi
    local hook major="" hook_failed=0 hook_command="" hook_table="" existing_hook=""
    # Acknowledgement needs a different tmux format per hook family. Client
    # hooks name the client that moved, but the after-select hooks expand
    # #{hook_client} empty, so guarding those on it would silently disable
    # acknowledgement for every ordinary pane and window switch. Those hooks do
    # expand #{pane_id} to the pane just selected, which is what to clear.
    major="$(tmux_notify_tmux_major_version)"
    if [ -n "$major" ] && [ "$major" -lt 3 ]; then
        warn "tmux 3.0 or newer is required for automatic Inbox acknowledgement hooks"
    else
        hook_table="$(tmux_cmd show-hooks -g 2>/dev/null || true)"
        for hook in client-attached client-session-changed after-select-pane after-select-window client-focus-in; do
            case "$hook" in
                after-select-*)
                    hook_command="$(tmux_notify_tmux_ack_hook_command \
                        "$quoted_path" --inbox-ack-pane '#{pane_id}')"
                    ;;
                *)
                    hook_command="$(tmux_notify_tmux_ack_hook_command \
                        "$quoted_path" --inbox-ack-client '#{hook_client}')"
                    ;;
            esac
            # Index 900 is only conventionally reserved, not private: tmux
            # writes "set-hook -g" to index 0 and appends "-ga" from there, so
            # nothing but a deliberate [900] can land here. Keep such a command
            # rather than overwriting it, the way the key binding below keeps a
            # slot this tool does not own. Uninit already refuses to remove
            # foreign hooks, which does not help once init has replaced one.
            existing_hook="$(tmux_notify_tmux_hook_command "$hook" "$hook_table")"
            if [ -n "$existing_hook" ] \
                && ! tmux_notify_tmux_is_ack_command "$existing_hook"; then
                warn "tmux hook ${hook}[900] is already set; leaving it unchanged"
                continue
            fi
            if ! tmux_cmd set-hook -g "${hook}[900]" \
                "$hook_command" 2>/dev/null; then
                hook_failed=1
            fi
        done
        if [ "$hook_failed" -eq 1 ]; then
            warn "Some automatic Inbox acknowledgement hooks could not be installed"
        fi
    fi
    local existing_binding="" serialized_quoted_path="" stale_key="" stale_count=0
    local binding_is_current=0
    serialized_quoted_path="${quoted_path//\\/\\\\}"
    existing_binding="$(tmux_notify_tmux_prefix_binding "$key")"
    if [[ "$existing_binding" == *"$quoted_path --inbox-next"* \
        || "$existing_binding" == *"$serialized_quoted_path --inbox-next"* ]]; then
        binding_is_current=1
    fi
    # An earlier init may have bound a different key, or this key against a
    # different install directory. Both keep firing, and the one naming the old
    # path breaks as soon as that install is removed, so retire them before
    # binding the current key. They are found by command: judging by path alone
    # would file this tool's own stale binding as a third-party conflict and
    # warn about one the user never created.
    while IFS= read -r stale_key; do
        [ -n "$stale_key" ] || continue
        if [ "$stale_key" = "$key" ]; then
            [ "$binding_is_current" -eq 0 ] || continue
            existing_binding=""
        fi
        tmux_cmd unbind-key -T prefix "$stale_key" 2>/dev/null || true
        stale_count=$((stale_count + 1))
    done < <(tmux_notify_tmux_inbox_bindings)
    if [ "$stale_count" -gt 0 ]; then
        log "Removed $stale_count tmux Inbox key binding(s) left by an earlier install"
    fi
    if [ "$binding_is_current" -eq 0 ]; then
        if [ -n "$existing_binding" ]; then
            warn "tmux prefix+$key is already bound; leaving it unchanged"
        else
            tmux_cmd bind-key "$key" \
                "run-shell -b 'TMUX_NOTIFY_SENDER_TTY=\"#{client_tty}\" $quoted_path --inbox-next'"
        fi
    fi
    tmux_notify_inbox_sync_counts
}

tmux_notify_tmux_uninit() {
    local server_pid="" socket_path="" configured_key="" status="" status_segment=""
    local inbox_bindings="" bound_key="" hook="" hook_command="" hook_table="" option=""
    local inbox_root="" counts="" cleared=0 clear_failures=0 clear_status=0
    server_pid="$(tmux_cmd display-message -p '#{pid}' 2>/dev/null || true)"
    [ -n "$server_pid" ] || return 0
    socket_path="$(tmux_cmd display-message -p '#{socket_path}' 2>/dev/null || true)"

    inbox_root="$(tmux_cmd show-option -gqv @tmux-notify-jump-inbox-root 2>/dev/null || true)"
    configured_key="$(tmux_cmd show-option -gqv @tmux-notify-jump-key 2>/dev/null || true)"
    counts="$(tmux_cmd show-option -gqv @tmux-notify-jump-attention 2>/dev/null || true)"
    counts+="$(tmux_cmd show-option -gqv @tmux-notify-jump-complete 2>/dev/null || true)"
    # Collect the bindings by command rather than by the configured key. The key
    # is configurable, so earlier inits may have left jump bindings on keys the
    # current option no longer names; keying off the option would leave those
    # bound to the binary this uninstall is about to delete.
    inbox_bindings="$(tmux_notify_tmux_inbox_bindings)"
    hook_table="$(tmux_cmd show-hooks -g 2>/dev/null || true)"
    status="$(tmux_cmd show-option -gqv status-right 2>/dev/null || true)"
    status_segment="$(tmux_notify_tmux_status_segment)"

    # Uninstall reaches whichever server the socket resolves to, which is not
    # always one this tool ever touched. Every individual removal below is
    # already guarded, but clearing the Inbox is not, and it cannot be undone.
    # Refuse servers that carry none of our marks instead. Servers that share a
    # tmux configuration all carry the same marks, so this cannot single out the
    # intended one; report what was cleared so a wrong socket is visible.
    if [ -z "$inbox_root" ] && [ -z "$configured_key" ] && [ -z "$counts" ] \
        && [ -z "$inbox_bindings" ] \
        && ! tmux_notify_tmux_is_ack_command "$hook_table" \
        && [[ "$status" != *"$status_segment"* ]]; then
        log "No tmux Inbox state on ${socket_path:-the default socket} (server pid $server_pid); left unchanged"
        return 0
    fi

    tmux_notify_inbox_clear_all >/dev/null 2>&1 || clear_status=$?
    cleared="${TMUX_NOTIFY_INBOX_CLEARED:-0}"
    clear_failures="${TMUX_NOTIFY_INBOX_CLEAR_FAILURES:-0}"

    while IFS= read -r bound_key; do
        [ -n "$bound_key" ] || continue
        tmux_cmd unbind-key -T prefix "$bound_key" 2>/dev/null || true
    done <<<"$inbox_bindings"

    for hook in client-attached client-session-changed after-select-pane after-select-window client-focus-in; do
        hook_command="$(tmux_notify_tmux_hook_command "$hook" "$hook_table")"
        if tmux_notify_tmux_is_ack_command "$hook_command"; then
            tmux_cmd set-hook -gu "${hook}[900]" 2>/dev/null || true
        fi
    done

    if [[ "$status" == *"$status_segment"* ]]; then
        status="${status%%"$status_segment"*}${status#*"$status_segment"}"
        tmux_cmd set-option -g status-right "$status" 2>/dev/null || true
    fi

    for option in @tmux-notify-jump-attention @tmux-notify-jump-complete \
        @tmux-notify-jump-inbox-root @tmux-notify-jump-key; do
        tmux_cmd set-option -gu "$option" 2>/dev/null || true
    done
    tmux_cmd refresh-client -S 2>/dev/null || true
    # Name the server that was changed: uninstall targets whichever server the
    # socket resolves to, which is not necessarily the one the user expects.
    if [ "$clear_status" -eq 0 ]; then
        log "Removed tmux Inbox state from ${socket_path:-the default socket} (server pid $server_pid, $cleared Inbox entries)"
        return 0
    fi
    warn "Inbox cleanup incomplete on ${socket_path:-the default socket} (server pid $server_pid, $cleared Inbox entries removed, $clear_failures removal failures)"
    return 1
}

cache_root_dir() {
    local home="${HOME:-}"
    if [ -n "${XDG_CACHE_HOME:-}" ]; then
        printf '%s' "$XDG_CACHE_HOME"
        return 0
    fi
    if [ -n "$home" ]; then
        printf '%s' "$home/.cache"
        return 0
    fi
    printf '%s' "${TMPDIR:-/tmp}"
}

now_ms() {
    if command -v python3 >/dev/null 2>&1; then
        local out=""
        set +e
        out="$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null)"
        local status=$?
        set -e
        out="$(printf '%s' "$out" | tr -d '\n')"
        if [ $status -eq 0 ] && [[ "$out" =~ ^[0-9]+$ ]]; then
            printf '%s' "$out"
            return 0
        fi
    fi
    local s=""
    s="$(date +%s 2>/dev/null || true)"
    if [[ "$s" =~ ^[0-9]+$ ]]; then
        printf '%s' "$((s * 1000))"
        return 0
    fi
    printf '%s' "0"
}

sha256_hex_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
        return 0
    fi
    cksum | awk '{print $1}'
}

# =============================================================================
# Deduplication Lock Helpers
# =============================================================================

# Read a timestamp from a file
# Returns the timestamp via stdout, or empty string if invalid/missing
read_timestamp_file() {
    local file="$1"
    local ts=""
    if [ -f "$file" ]; then
        ts="$(tr -d '\n' <"$file" 2>/dev/null || true)"
    fi
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        printf '%s' "$ts"
    fi
}

# Write a timestamp to a file atomically
# Uses a temp file + mv to avoid partial writes
write_timestamp_file() {
    local file="$1"
    local ts="$2"
    local tmp="$file.$$.$RANDOM"

    if ! printf '%s\n' "$ts" >"$tmp" 2>/dev/null; then
        log_debug "write_timestamp_file: failed to write temp file: $tmp"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    if ! mv -f "$tmp" "$file" 2>/dev/null; then
        log_debug "write_timestamp_file: failed to move temp file into place: $file"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    return 0
}

# Check if timestamp is within the given window
# Returns 0 if within window (should suppress), 1 if outside
is_within_window() {
    local last="$1"
    local now="$2"
    local window_ms="$3"

    if ! [[ "$last" =~ ^[0-9]+$ ]] || [ "$last" -le 0 ]; then
        return 1
    fi
    local delta=$((now - last))
    if [ "$delta" -ge 0 ] && [ "$delta" -lt "$window_ms" ]; then
        return 0
    fi
    return 1
}

# Try to acquire a directory-based lock
# Sets _LOCK_ACQUIRED=1 if acquired, 0 if not
# Arguments: lock_dir
acquire_lock() {
    local lock="$1"
    _LOCK_ACQUIRED=0

    if mkdir "$lock" 2>/dev/null; then
        _LOCK_ACQUIRED=1
        printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
        return 0
    fi

    # Check if lock is stale (owner process dead or empty pid file)
    local pid=""
    pid="$(tr -d '\n' <"$lock/pid" 2>/dev/null || true)"

    # Empty pid file - process died between mkdir and write
    if [ -d "$lock" ] && [ ! -s "$lock/pid" ]; then
        rm -rf "$lock" 2>/dev/null || true
        if mkdir "$lock" 2>/dev/null; then
            _LOCK_ACQUIRED=1
            printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
            return 0
        fi
    fi

    # Process no longer running
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
        rm -rf "$lock" 2>/dev/null || true
        if mkdir "$lock" 2>/dev/null; then
            _LOCK_ACQUIRED=1
            printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
            return 0
        fi
    fi

    return 1
}

# Release a directory-based lock
release_lock() {
    local lock="$1"
    rm -rf "$lock" 2>/dev/null || true
}

# Check if GC should run based on last GC time
# Returns 0 if should run, 1 if too recent
gc_should_run() {
    local gc_file="$1"
    local now="$2"
    local interval_ms="$3"

    local last_gc=""
    last_gc="$(read_timestamp_file "$gc_file")"

    if [ -n "$last_gc" ] && [ "$last_gc" -gt 0 ]; then
        local since=$((now - last_gc))
        if [ "$since" -ge 0 ] && [ "$since" -lt "$interval_ms" ]; then
            return 1
        fi
    fi
    return 0
}

# Purge expired entries from dedupe directory
# Arguments: dir, now, ttl_ms
gc_purge_expired() {
    local dir="$1"
    local now="$2"
    local ttl_ms="$3"

    local f=""
    for f in "$dir"/*.ts; do
        [ -e "$f" ] || break
        local base="${f##*/}"
        # Skip the GC marker file
        if [ "$base" = ".gc.ts" ]; then
            continue
        fi
        local ts=""
        ts="$(read_timestamp_file "$f")"
        if [ -z "$ts" ]; then
            rm -f "$f" 2>/dev/null || true
            continue
        fi
        local delta=$((now - ts))
        if [ "$delta" -ge "$ttl_ms" ]; then
            rm -f "$f" 2>/dev/null || true
        fi
    done
}

# Check if GC lock is stale based on age and process status
# Returns 0 if stale, 1 if still valid
gc_lock_is_stale() {
    local lock_dir="$1"
    local now="$2"
    local stale_threshold="${3:-3600000}"  # 1 hour default

    local lock_pid=""
    local lock_ts=""
    lock_pid="$(tr -d '\n' <"$lock_dir/pid" 2>/dev/null || true)"
    lock_ts="$(tr -d '\n' <"$lock_dir/ts" 2>/dev/null || true)"

    # Invalid timestamp format
    if ! [[ "$lock_ts" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    # Lock too old
    local age=$((now - lock_ts))
    if [ "$age" -lt 0 ] || [ "$age" -gt "$stale_threshold" ]; then
        return 0
    fi

    # Process no longer running
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        return 0
    fi

    return 1
}

# =============================================================================
# Main Deduplication Functions
# =============================================================================

# Run garbage collection on deduplication cache (if due)
#
# This function cleans up old timestamp files from the dedupe cache.
# It uses a lock to prevent concurrent GC runs and only runs every 24 hours.
#
# Arguments:
#   $1 - dir: Cache directory path
#   $2 - now: Current timestamp in milliseconds
#   $3 - window_ms: Dedupe window (used to adjust TTL)
#
# GC Parameters:
#   - Interval: 24 hours between GC runs
#   - TTL: 7 days (or dedupe window if larger)
#   - Lock stale threshold: 1 hour
#
# Side effects:
#   - Creates/updates .gc.ts marker file
#   - Removes expired .ts files
#   - Uses directory-based locking
dedupe_gc_maybe() {
    local dir="${1:-}"
    local now="${2:-0}"
    local window_ms="${3:-0}"
    [ -n "$dir" ] || return 0
    if ! [[ "$now" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if ! [[ "$window_ms" =~ ^[0-9]+$ ]]; then
        window_ms="0"
    fi

    local gc_interval_ms="86400000" # 24h
    local ttl_ms="604800000" # 7d
    if [ "$ttl_ms" -lt "$window_ms" ]; then
        ttl_ms="$window_ms"
    fi

    local gc_file="$dir/.gc.ts"

    # Quick check: skip if GC ran recently
    if ! gc_should_run "$gc_file" "$now" "$gc_interval_ms"; then
        return 0
    fi

    # Try to acquire GC lock
    local gc_lock="$dir/.gc.lock"
    local acquired="0"
    if mkdir "$gc_lock" 2>/dev/null; then
        acquired="1"
    else
        # Check if lock is stale
        if gc_lock_is_stale "$gc_lock" "$now" 3600000; then
            rm -rf "$gc_lock" 2>/dev/null || true
            if mkdir "$gc_lock" 2>/dev/null; then
                acquired="1"
            fi
        fi
    fi

    [ "$acquired" -eq 1 ] || return 0
    printf '%s\n' "$$" >"$gc_lock/pid" 2>/dev/null || true
    printf '%s\n' "$now" >"$gc_lock/ts" 2>/dev/null || true

    # Re-check under lock (double-checked locking)
    if ! gc_should_run "$gc_file" "$now" "$gc_interval_ms"; then
        release_lock "$gc_lock"
        return 0
    fi

    # Update GC marker and purge expired entries
    write_timestamp_file "$gc_file" "$now"
    gc_purge_expired "$dir" "$now" "$ttl_ms"

    release_lock "$gc_lock"
}

# Check if an event is enabled based on whitelist/blacklist/default
# Usage: is_event_enabled "event_name" "whitelist" "blacklist" "default_list"
# whitelist: comma-separated, empty=use default, *=all
# blacklist: comma-separated events to exclude
# Returns 0 if enabled, 1 if disabled
csv_list_contains() {
    local list="${1:-}"
    local needle="${2:-}"

    needle="$(trim_ws "$needle")"
    [ -n "$needle" ] || return 1

    list="${list//$'\n'/,}"
    list="$(trim_ws "$list")"
    [ -n "$list" ] || return 1

    local -a parts=()
    local IFS=','
    read -r -a parts <<<"$list"

    local part=""
    for part in "${parts[@]}"; do
        part="$(trim_ws "$part")"
        [ -n "$part" ] || continue
        if [ "$part" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

is_event_enabled() {
    local event="${1:-}"
    local whitelist="${2:-}"    # comma-separated, empty=use default, *=all
    local blacklist="${3:-}"    # comma-separated, *=all
    local default_list="${4:-}" # default whitelist

    event="$(trim_ws "$event")"
    [ -n "$event" ] || return 1

    whitelist="${whitelist//$'\n'/,}"
    blacklist="${blacklist//$'\n'/,}"
    default_list="${default_list//$'\n'/,}"

    whitelist="$(trim_ws "$whitelist")"
    blacklist="$(trim_ws "$blacklist")"
    default_list="$(trim_ws "$default_list")"

    # Determine effective whitelist.
    local effective_list=""
    if [ -n "$whitelist" ]; then
        effective_list="$whitelist"
    else
        effective_list="$default_list"
    fi
    effective_list="$(trim_ws "$effective_list")"

    # Empty effective list means "disabled".
    [ -n "$effective_list" ] || return 1

    # Blacklist wins.
    if [ "$blacklist" = "*" ]; then
        return 1
    fi
    if csv_list_contains "$blacklist" "$event"; then
        return 1
    fi

    # Whitelist.
    if [ "$effective_list" = "*" ]; then
        return 0
    fi
    if csv_list_contains "$effective_list" "$event"; then
        return 0
    fi
    return 1
}

# Format notification title with optional event type
# Usage: format_notify_title "prefix" "event" "message" "show_type"
# show_type: 1=show event type in brackets (default), 0=hide
format_notify_title() {
    local prefix="$1"      # "Codex" or "Claude"
    local event="${2:-}"   # event type
    local message="$3"     # message content
    local show_type="${4:-1}"  # show event type (default=1)

    event="$(trim_ws "$event")"

    if is_truthy "$show_type" && [ -n "$event" ]; then
        printf '%s' "$prefix [$event]: $message"
    else
        printf '%s' "$prefix: $message"
    fi
}

# Check if a notification should be suppressed as duplicate
#
# Uses a cache of SHA256-hashed notification keys with timestamps.
# If the same key was seen within the window, returns 0 (suppress).
# Otherwise, records the timestamp and returns 1 (allow).
#
# Arguments:
#   $1 - window_ms: Suppression window in milliseconds
#   $2 - key: Notification key (target+title+body)
#
# Returns:
#   0 if notification should be suppressed (duplicate)
#   1 if notification should be allowed (not duplicate or disabled)
#
# Cache location:
#   $XDG_CACHE_HOME/tmux-notify-jump/dedupe/ or
#   ~/.cache/tmux-notify-jump/dedupe/
#
# Locking strategy:
#   - Uses per-key directory locks for race condition prevention
#   - Falls back to read-only check if lock acquisition fails
#   - Triggers GC periodically to clean old entries
dedupe_should_suppress() {
    local window_ms="${1:-0}"
    local key="${2:-}"
    [ -n "$key" ] || return 1
    if ! [[ "$window_ms" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [ "$window_ms" -le 0 ]; then
        return 1
    fi

    local now
    now="$(now_ms)"
    if ! [[ "$now" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    local root
    root="$(cache_root_dir)"
    local dir="$root/tmux-notify-jump/dedupe"
    if ! mkdir -p "$dir" 2>/dev/null; then
        log_debug "dedupe_should_suppress: failed to create cache dir: $dir"
        return 1
    fi

    local hash
    hash="$(printf '%s' "$key" | sha256_hex_stdin 2>/dev/null | tr -d '\n' || true)"
    [ -n "$hash" ] || return 1

    local file="$dir/$hash.ts"

    # Run GC occasionally
    dedupe_gc_maybe "$dir" "$now" "$window_ms" || true

    # Try to acquire per-key lock with retries
    local lock="$file.lock"
    local attempt=0
    while [ "$attempt" -lt 3 ]; do
        if acquire_lock "$lock"; then
            break
        fi
        sleep 0.02 2>/dev/null || true
        attempt=$((attempt + 1))
    done

    # If lock not acquired, fall back to read-only check
    if [ "${_LOCK_ACQUIRED:-0}" -ne 1 ]; then
        local last=""
        last="$(read_timestamp_file "$file")"
        if is_within_window "$last" "$now" "$window_ms"; then
            return 0
        fi
        return 1
    fi

    # Check if we should suppress (within window)
    local last=""
    last="$(read_timestamp_file "$file")"
    local should_suppress=1
    if is_within_window "$last" "$now" "$window_ms"; then
        should_suppress=0
    fi

    # Update timestamp if not suppressing
    if [ "$should_suppress" -ne 0 ]; then
        write_timestamp_file "$file" "$now"
    fi

    release_lock "$lock"

    if [ "$should_suppress" -eq 0 ]; then
        return 0
    fi
    return 1
}
