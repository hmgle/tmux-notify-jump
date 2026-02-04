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
#   --max-title, --max-body, --dedupe-ms, --detach
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
            LIST_ONLY=1
            _PARSE_CONSUMED=1
            return 0
            ;;
        --dry-run)
            DRY_RUN=1
            _PARSE_CONSUMED=1
            return 0
            ;;
        --quiet)
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
        --detach)
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

# Validate common options shared by both platform scripts
# Call this after parse_args()
validate_common_options() {
    validate_timeout
    validate_ui_mode
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

get_best_tmux_client_pane_id() {
    local output=""
    output="$(tmux_cmd list-clients -F "#{client_activity} #{client_pane}" 2>/dev/null || true)"
    local best_activity=0
    local best_pane=""
    local line=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local activity="${line%% *}"
        local pane="${line#* }"
        if ! is_integer "$activity"; then
            continue
        fi
        if [ -z "$pane" ] || ! is_pane_id "$pane"; then
            continue
        fi
        if [ "$activity" -gt "$best_activity" ]; then
            best_activity="$activity"
            best_pane="$pane"
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

get_current_tmux_session() {
    if [ -z "${TMUX:-}" ]; then
        return 1
    fi
    local session=""
    if [ -n "${TMUX_PANE:-}" ]; then
        session="$(tmux_cmd display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)"
    fi
    if [ -z "$session" ]; then
        session="$(tmux_cmd display-message -p '#S' 2>/dev/null || true)"
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
    output="$(tmux_cmd list-clients -F "#{client_activity} #{client_pid} #{client_session}" 2>/dev/null || true)"
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
        clients_by_pane="$(tmux_cmd list-clients -F "#{client_tty} #{client_pane}" 2>/dev/null || true)"
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
    tty="$(tmux_cmd display-message -p '#{client_tty}' 2>/dev/null || true)"
    if [ -n "$tty" ]; then
        printf '%s' "$tty"
        return 0
    fi

    local current_session=""
    current_session="$(get_current_tmux_session 2>/dev/null || true)"

    local best_tty=""
    local best_activity=0
    local clients_by_activity=""
    clients_by_activity="$(tmux_cmd list-clients -F "#{client_activity} #{client_tty} #{client_session}" 2>/dev/null || true)"
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
    output="$(tmux_cmd list-clients -F "#{client_tty} #{client_pid}" 2>/dev/null || true)"
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
        ts="$(cat "$file" 2>/dev/null | tr -d '\n' || true)"
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
    printf '%s\n' "$ts" >"$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file" 2>/dev/null || true
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
    pid="$(cat "$lock/pid" 2>/dev/null | tr -d '\n' || true)"

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
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null | tr -d '\n' || true)"
    lock_ts="$(cat "$lock_dir/ts" 2>/dev/null | tr -d '\n' || true)"

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
    mkdir -p "$dir" 2>/dev/null || true

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
