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

# Load user configuration from env file
#
# Loads environment variables from user's config file.
# Config file location: $TMUX_NOTIFY_CONFIG or ~/.config/tmux-notify-jump/env
#
# Side effects:
#   - Sources config file, setting exported variables
load_user_config() {
    local home="${HOME:-}"
    [ -n "$home" ] || return 0

    local cfg="${TMUX_NOTIFY_CONFIG:-$home/.config/tmux-notify-jump/env}"
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
    command -v "$tool" >/dev/null 2>&1 || die "Missing dependency: $tool"
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
#   --max-title, --max-body, --dedupe-ms, --detach, --notify-kind,
#   --notify-source
#
# Special return values in _PARSE_CONSUMED:
#   "help" - caller should print_usage and exit 0
#   "end"  - end of options marker (--) was seen
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

resolve_tmux_notify_target() {
    local allow_fallback="${1:-0}"

    if [ -n "${TMUX_PANE:-}" ] && is_pane_id "$TMUX_PANE"; then
        printf '%s' "$TMUX_PANE"
        return 0
    fi

    if [ -n "${TMUX:-}" ]; then
        local pane=""
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

    if is_truthy "$allow_fallback"; then
        get_best_tmux_client_pane_id
        return $?
    fi

    return 1
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

jump_to_pane() {
    if [ -z "${JUMP_CLIENT_NAME:-}" ]; then
        prepare_tmux_jump_client
    fi
    if ! tmux_cmd switch-client -c "$JUMP_CLIENT_NAME" -t "$SESSION:$WINDOW" ';' \
        select-pane -t "$JUMP_TARGET_PANE_ID" 2>/dev/null; then
        die "Failed to switch terminal client $JUMP_CLIENT_NAME to $SESSION:$WINDOW.$PANE"
    fi

    local rows=""
    rows="$(tmux_terminal_client_rows)"
    local matched=0
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read_tmux_client_row "$line"
        if [ "$CLIENT_NAME" != "$JUMP_CLIENT_NAME" ] \
            || [ "$CLIENT_SESSION_ID" != "$JUMP_TARGET_SESSION_ID" ]; then
            continue
        fi
        # Old tmux releases do not expand #{pane_id} in client context. Verify
        # the session only there instead of failing a jump that did happen.
        if [ -z "$CLIENT_PANE_ID" ]; then
            log_debug "client pane not reported; verified session only"
        elif [ "$CLIENT_PANE_ID" != "$JUMP_TARGET_PANE_ID" ]; then
            continue
        fi
        matched=1
        break
    done <<<"$rows"
    if [ "$matched" -ne 1 ]; then
        log_debug "client switch postcondition failed: client=$JUMP_CLIENT_NAME target_session=$JUMP_TARGET_SESSION_ID target_pane=$JUMP_TARGET_PANE_ID rows=$rows"
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

process_tree_has_sshd() {
    local pid="${1:-}"
    if ! is_integer "$pid"; then
        return 1
    fi

    local current_pid="$pid"
    local depth=0
    while is_integer "$current_pid" && [ "$current_pid" -gt 1 ] && [ "$depth" -lt 50 ]; do
        local comm=""
        comm="$(ps -p "$current_pid" -o comm= 2>/dev/null || true)"
        comm="$(trim_ws "$comm")"
        case "$comm" in
            sshd|sshd:*|*/sshd|*/sshd:*)
                return 0
                ;;
        esac

        local ppid=""
        ppid="$(ps -p "$current_pid" -o ppid= 2>/dev/null || true)"
        ppid="$(trim_ws "$ppid")"
        if ! is_integer "$ppid" || [ "$ppid" -le 1 ] || [ "$ppid" = "$current_pid" ]; then
            break
        fi

        current_pid="$ppid"
        depth=$((depth + 1))
    done

    return 1
}

tmux_client_pid_is_remote_ssh() {
    local pid="${1:-}"
    if ! is_integer "$pid"; then
        return 1
    fi

    process_env_has_ssh "$pid" && return 0
    process_tree_has_sshd "$pid" && return 0
    return 1
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

tmux_notify_inbox_default_root() {
    local requested_socket="${TMUX_NOTIFY_TMUX_SOCKET:-}"
    local socket="" server_id=""
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
    printf '%s/tmux-notify-jump/inbox/%s' "$(cache_root_dir)" "$id"
}

tmux_notify_inbox_root() {
    local configured_root=""
    configured_root="$(
        tmux_cmd show-option -gqv @tmux-notify-jump-inbox-root 2>/dev/null || true
    )"
    if [ -n "$configured_root" ]; then
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

tmux_notify_inbox_entry_read() {
    local dir="$1"
    INBOX_KIND="$(cat "$dir/kind" 2>/dev/null || true)"
    INBOX_COUNT="$(cat "$dir/count" 2>/dev/null || true)"
    INBOX_FIRST_MS="$(cat "$dir/first_ms" 2>/dev/null || true)"
    # shellcheck disable=SC2034
    INBOX_LAST_MS="$(cat "$dir/last_ms" 2>/dev/null || true)"
    INBOX_PANE_ID="$(cat "$dir/pane_id" 2>/dev/null || true)"
    INBOX_WINDOW_ID="$(cat "$dir/window_id" 2>/dev/null || true)"
    INBOX_SESSION_ID="$(cat "$dir/session_id" 2>/dev/null || true)"
    # shellcheck disable=SC2034
    INBOX_SESSION_NAME="$(cat "$dir/session_name" 2>/dev/null || true)"
    # shellcheck disable=SC2034
    INBOX_WINDOW_INDEX="$(cat "$dir/window_index" 2>/dev/null || true)"
    # shellcheck disable=SC2034
    INBOX_SOURCE="$(cat "$dir/source" 2>/dev/null || true)"
    # shellcheck disable=SC2034
    INBOX_TITLE="$(cat "$dir/title" 2>/dev/null || true)"
}

tmux_notify_inbox_secure_dir() {
    local dir="$1" create="${2:-0}"
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then
        return 1
    fi
    if [ ! -d "$dir" ]; then
        [ "$create" -eq 1 ] || return 0
        mkdir -p "$dir" || return 1
    fi
    chmod 700 "$dir" 2>/dev/null
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
    local attention=0 complete=0 dir=""
    for dir in "$root"/*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/kind" ] || continue
        local kind="" count=""
        kind="$(cat "$dir/kind" 2>/dev/null || true)"
        count="$(cat "$dir/count" 2>/dev/null || true)"
        [[ "$count" =~ ^[0-9]+$ ]] || count=1
        if [ "$kind" = "attention" ]; then
            attention=$((attention + count))
        else
            complete=$((complete + count))
        fi
    done
    tmux_cmd set-option -gq @tmux-notify-jump-attention "$attention" 2>/dev/null || true
    tmux_cmd set-option -gq @tmux-notify-jump-complete "$complete" 2>/dev/null || true
    tmux_cmd refresh-client -S 2>/dev/null || true
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
        [ -d "$dir" ] || continue
        [ -f "$dir/kind" ] || continue
        last="$(cat "$dir/last_ms" 2>/dev/null || true)"
        if [[ "$last" =~ ^[0-9]+$ ]] && [ "$ttl" -gt 0 ] && [ "$now" -gt "$last" ] && [ $((now - last)) -ge "$ttl" ]; then
            rm -rf "$dir" 2>/dev/null || true
        fi
    done
    if [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ]; then
        local count=0 list=""
        for dir in "$root"/*; do
            [ -d "$dir" ] || continue
            [ -f "$dir/kind" ] || continue
            last="$(cat "$dir/last_ms" 2>/dev/null || echo 0)"
            list+="$last|$dir\n"
            count=$((count + 1))
        done
        if [ "$count" -gt "$max" ]; then
            printf '%b' "$list" | sort -n -t '|' -k1,1 | head -n $((count - max)) | cut -d '|' -f2- | while IFS= read -r dir; do
                if [ -n "$dir" ]; then rm -rf "$dir" 2>/dev/null || true; fi
            done
        fi
    fi
}

tmux_notify_inbox_target_info() {
    local target="$1"
    tmux_cmd display-message -p -t "$target" '#{session_id}|#{window_id}|#{pane_id}|#{session_name}|#{window_index}' 2>/dev/null || true
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
    IFS='|' read -r session_id window_id pane_id session_name window_index <<<"$info"
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
    local pane_id="$1" root="" kind="" key="" dir="" changed=0
    root="$(tmux_notify_inbox_root)"
    tmux_notify_inbox_secure_dir "$root" || return 1
    for kind in attention complete; do
        key="$(printf '%s|%s' "$pane_id" "$kind" | sha256_hex_stdin)"
        dir="$root/$key"
        [ -d "$dir" ] || continue
        rm -rf "$dir" 2>/dev/null || true
        changed=1
    done
    if [ "$changed" -eq 1 ]; then
        tmux_notify_inbox_sync_counts
    fi
}

tmux_notify_inbox_clear_all() {
    local root="" dir
    root="$(tmux_notify_inbox_root)"
    tmux_notify_inbox_secure_dir "$root" || return 1
    for dir in "$root"/*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/kind" ] || continue
        rm -rf "$dir" 2>/dev/null || true
    done
    tmux_notify_inbox_sync_counts
}

tmux_notify_route_notification() {
    local target="$1" title="$2" body="$3" kind="${4:-complete}" source="${5:-tmux-notify-jump}"
    TMUX_NOTIFY_ROUTE_DESKTOP=0
    local mode="" rows="" info=""
    mode="$(tmux_notify_remote_mode)"
    rows="$(tmux_terminal_client_rows 2>/dev/null || true)"
    info="$(tmux_notify_inbox_target_info "$target")"
    if [ -z "$info" ]; then
        # Legacy tmux and restricted command stubs may not expand the complete
        # metadata format. Preserve the pre-Inbox desktop path in that case.
        TMUX_NOTIFY_ROUTE_DESKTOP=1
        export TMUX_NOTIFY_ROUTE_DESKTOP
        return 0
    fi
    local session_id="" window_id="" pane_id="" session_name="" window_index=""
    IFS='|' read -r session_id window_id pane_id session_name window_index <<<"$info"
    local visible=0 local_client=0 remote_target_client=0 row message is_remote
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        read_tmux_client_row "$row"
        is_remote=0
        if tmux_client_pid_is_remote_ssh "${CLIENT_PID:-}"; then
            is_remote=1
        else
            local_client=1
        fi
        [ "$CLIENT_SESSION_ID" = "$session_id" ] || continue
        if [ "$CLIENT_PANE_ID" = "$pane_id" ]; then visible=1; fi
        if [ "$is_remote" -eq 1 ]; then
            remote_target_client=1
            if [ "$mode" = "tmux" ] || [ "$mode" = "both" ]; then
                message="[$(tmux_notify_compact_text "$source")] $(tmux_notify_compact_text "$title")"
                tmux_cmd display-message -c "$CLIENT_NAME" \
                    "${message}: $(tmux_notify_compact_text "$body")" >/dev/null 2>&1 || true
            fi
        fi
    done <<<"$rows"
    if [ "$mode" = "tmux" ] || [ "$mode" = "both" ]; then
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
            if [ "$local_client" -eq 1 ] \
                || { [ "$remote_target_client" -eq 0 ] && ! tmux_notify_process_is_remote_ssh; }; then
                TMUX_NOTIFY_ROUTE_DESKTOP=1
            fi
            ;;
    esac
    export TMUX_NOTIFY_ROUTE_DESKTOP
}

tmux_notify_inbox_ack_client() {
    local client="$1" pane=""
    [ -n "$client" ] || return 0
    pane="$(tmux_cmd display-message -p -c "$client" '#{pane_id}' 2>/dev/null || true)"
    [ -n "$pane" ] && tmux_notify_inbox_ack_pane "$pane"
}

tmux_notify_target_id_exists() {
    local target="$1" format="$2" expected="$3" actual=""
    actual="$(tmux_cmd display-message -p -t "$target" "$format" 2>/dev/null || true)"
    [ "$actual" = "$expected" ]
}

tmux_notify_inbox_next() {
    local sender_tty="${1:-}" root="" list="" dir
    root="$(tmux_notify_inbox_root)"
    local now=""
    now="$(now_ms)"
    tmux_notify_inbox_secure_dir "$root" 1 || return 1
    tmux_notify_inbox_gc "$root" "$now"
    for dir in "$root"/*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/kind" ] || continue
        tmux_notify_inbox_entry_read "$dir"
        local rank=1
        [ "${INBOX_KIND:-complete}" = "attention" ] && rank=0
        list+="$rank|${INBOX_FIRST_MS:-0}|$dir\n"
    done
    local selected=""
    selected="$(printf '%b' "$list" | sort -n -t '|' -k1,1 -k2,2 | head -n 1 | cut -d '|' -f3- || true)"
    [ -n "$selected" ] || { tmux_notify_inbox_sync_counts; return 0; }
    tmux_notify_inbox_entry_read "$selected"
    local client="" target_client="" row target_activity=0
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        read_tmux_client_row "$row"
        if [ -n "$sender_tty" ] && [ "$CLIENT_TTY" = "$sender_tty" ]; then client="$CLIENT_NAME"; break; fi
        [ "$CLIENT_SESSION_ID" = "$INBOX_SESSION_ID" ] || continue
        if is_integer "$CLIENT_ACTIVITY" && [ "$CLIENT_ACTIVITY" -gt "$target_activity" ]; then
            target_activity="$CLIENT_ACTIVITY"
            target_client="$CLIENT_NAME"
        elif [ -z "$target_client" ]; then
            target_client="$CLIENT_NAME"
        fi
    done <<<"$(tmux_terminal_client_rows)"
    [ -n "$client" ] || client="$target_client"
    [ -n "$client" ] || client="$(tmux_cmd display-message -p '#{client_name}' 2>/dev/null || true)"
    [ -n "$client" ] || return 1
    if tmux_notify_target_id_exists "$INBOX_PANE_ID" '#{pane_id}' "$INBOX_PANE_ID"; then
        tmux_cmd switch-client -c "$client" -t "$INBOX_SESSION_ID" ';' \
            select-window -t "$INBOX_WINDOW_ID" ';' \
            select-pane -t "$INBOX_PANE_ID" >/dev/null 2>&1 || return 1
    elif tmux_notify_target_id_exists "$INBOX_WINDOW_ID" '#{window_id}' "$INBOX_WINDOW_ID"; then
        tmux_cmd switch-client -c "$client" -t "$INBOX_SESSION_ID" ';' \
            select-window -t "$INBOX_WINDOW_ID" >/dev/null 2>&1 || return 1
    elif tmux_notify_target_id_exists "$INBOX_SESSION_ID" '#{session_id}' "$INBOX_SESSION_ID"; then
        tmux_cmd switch-client -c "$client" -t "$INBOX_SESSION_ID" >/dev/null 2>&1 || return 1
    else
        rm -rf "$selected" 2>/dev/null || true
        tmux_notify_inbox_sync_counts
        return 1
    fi
    rm -rf "$selected" 2>/dev/null || true
    tmux_notify_inbox_sync_counts
}

tmux_notify_inbox_list() {
    local root="" dir
    root="$(tmux_notify_inbox_root)"
    tmux_notify_inbox_secure_dir "$root" || return 1
    for dir in "$root"/*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/kind" ] || continue
        tmux_notify_inbox_entry_read "$dir"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${INBOX_KIND:-complete}" "${INBOX_COUNT:-1}" \
            "$INBOX_PANE_ID" "$INBOX_SOURCE" "$INBOX_TITLE"
    done
}

tmux_notify_tmux_major_version() {
    local version=""
    version="$(tmux_cmd -V 2>/dev/null || true)"
    version="${version#tmux }"
    version="${version%%.*}"
    if [[ "$version" =~ ^[0-9]+$ ]]; then
        printf '%s' "$version"
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

tmux_notify_tmux_init() {
    local path="${TMUX_NOTIFY_ENTRYPOINT:-tmux-notify-jump}" quoted_path="" key="" configured_key="" root=""
    printf -v quoted_path '%q' "$path"
    root="$(tmux_notify_inbox_default_root)"
    tmux_cmd set-option -gq @tmux-notify-jump-inbox-root "$root"
    configured_key="$(tmux_cmd show-option -gqv @tmux-notify-jump-key 2>/dev/null || true)"
    key="${TMUX_NOTIFY_TMUX_KEY:-${configured_key:-N}}"
    case "$key" in [A-Za-z0-9]) ;; *) key=N ;; esac
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
    local hook major="" hook_failed=0 hook_command=""
    local ack_guard='#{&&:#{||:#{@tmux-notify-jump-attention},#{@tmux-notify-jump-complete}},#{hook_client}}'
    hook_command="if-shell -F '$ack_guard' { run-shell -b '$quoted_path --inbox-ack-client \"#{hook_client}\"' }"
    major="$(tmux_notify_tmux_major_version)"
    if [ -n "$major" ] && [ "$major" -lt 3 ]; then
        warn "tmux 3.0 or newer is required for automatic Inbox acknowledgement hooks"
    else
        for hook in client-attached client-session-changed after-select-pane after-select-window client-focus-in; do
            if ! tmux_cmd set-hook -g "${hook}[900]" \
                "$hook_command" 2>/dev/null; then
                hook_failed=1
            fi
        done
        if [ "$hook_failed" -eq 1 ]; then
            warn "Some automatic Inbox acknowledgement hooks could not be installed"
        fi
    fi
    local existing_binding="" serialized_quoted_path=""
    serialized_quoted_path="${quoted_path//\\/\\\\}"
    existing_binding="$(tmux_notify_tmux_prefix_binding "$key")"
    if [ -n "$existing_binding" ]; then
        if [[ "$existing_binding" != *"$quoted_path --inbox-next"* \
            && "$existing_binding" != *"$serialized_quoted_path --inbox-next"* ]]; then
            warn "tmux prefix+$key is already bound; leaving it unchanged"
        fi
    else
        tmux_cmd bind-key "$key" \
            "run-shell -b 'TMUX_NOTIFY_SENDER_TTY=\"#{client_tty}\" $quoted_path --inbox-next'"
    fi
    tmux_notify_inbox_sync_counts
}

tmux_notify_tmux_uninit() {
    local server_pid="" configured_key="" key="" status="" status_segment=""
    local existing_binding="" hook="" hook_command="" option=""
    server_pid="$(tmux_cmd display-message -p '#{pid}' 2>/dev/null || true)"
    [ -n "$server_pid" ] || return 0

    tmux_notify_inbox_clear_all >/dev/null 2>&1 || true

    configured_key="$(tmux_cmd show-option -gqv @tmux-notify-jump-key 2>/dev/null || true)"
    key="${configured_key:-${TMUX_NOTIFY_TMUX_KEY:-N}}"
    case "$key" in [A-Za-z0-9]) ;; *) key=N ;; esac
    existing_binding="$(tmux_notify_tmux_prefix_binding "$key")"
    if [[ "$existing_binding" == *"--inbox-next"* ]]; then
        tmux_cmd unbind-key -T prefix "$key" 2>/dev/null || true
    fi

    for hook in client-attached client-session-changed after-select-pane after-select-window client-focus-in; do
        hook_command="$(tmux_cmd show-hooks -g "$hook" 2>/dev/null | awk -v name="${hook}[900]" '
            $1 == name { sub(/^[^ ]+ /, ""); print; exit }
        ' || true)"
        if [[ "$hook_command" == *"--inbox-ack-client"* ]]; then
            tmux_cmd set-hook -gu "${hook}[900]" 2>/dev/null || true
        fi
    done

    status="$(tmux_cmd show-option -gqv status-right 2>/dev/null || true)"
    status_segment="$(tmux_notify_tmux_status_segment)"
    if [[ "$status" == *"$status_segment"* ]]; then
        status="${status%%"$status_segment"*}${status#*"$status_segment"}"
        tmux_cmd set-option -g status-right "$status" 2>/dev/null || true
    fi

    for option in @tmux-notify-jump-attention @tmux-notify-jump-complete \
        @tmux-notify-jump-inbox-root @tmux-notify-jump-key; do
        tmux_cmd set-option -gu "$option" 2>/dev/null || true
    done
    tmux_cmd refresh-client -S 2>/dev/null || true
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
