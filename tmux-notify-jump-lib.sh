#!/usr/bin/env bash
set -euo pipefail

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
        printf '%s…' "${text:0:$max}"
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

normalize_int() {
    local value="$1"
    local fallback="$2"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
        return
    fi
    echo "$fallback"
}

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

is_truthy() {
    local v="${1:-}"
    case "$v" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
    esac
    return 1
}

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

check_tmux_server() {
    tmux_cmd list-sessions >/dev/null 2>&1 || die "tmux server is not running"
}

list_panes() {
    require_tool tmux
    if ! tmux_cmd list-sessions >/dev/null 2>&1; then
        die "tmux server is not running; cannot list panes"
    fi
    tmux_cmd list-panes -a -F "  #{?pane_active,*, } #{session_name}:#{window_index}.#{pane_index} - #{pane_title}"
}

is_pane_id() {
    local s="${1:-}"
    [[ "$s" =~ ^%[0-9]+$ ]]
}

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

ensure_target_resolved() {
    if [ -n "${PANE_ID:-}" ] && [ -z "${SESSION:-}" ]; then
        resolve_target_from_pane_id
    fi
}

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
    local last_gc="0"
    if [ -f "$gc_file" ]; then
        last_gc="$(cat "$gc_file" 2>/dev/null | tr -d '\n' || true)"
    fi
    if [[ "$last_gc" =~ ^[0-9]+$ ]] && [ "$last_gc" -gt 0 ]; then
        local since=$((now - last_gc))
        if [ "$since" -ge 0 ] && [ "$since" -lt "$gc_interval_ms" ]; then
            return 0
        fi
    fi

    local gc_lock="$dir/.gc.lock"
    local acquired="0"
    if mkdir "$gc_lock" 2>/dev/null; then
        acquired="1"
    else
        # If a previous GC run crashed (e.g. SIGKILL), the lock dir may be left behind.
        # Treat missing/invalid metadata or stale timestamps as stale and break the lock.
        local lock_pid=""
        local lock_ts=""
        lock_pid="$(cat "$gc_lock/pid" 2>/dev/null | tr -d '\n' || true)"
        lock_ts="$(cat "$gc_lock/ts" 2>/dev/null | tr -d '\n' || true)"
        local stale="0"
        if ! [[ "$lock_ts" =~ ^[0-9]+$ ]]; then
            stale="1"
        else
            local age=$((now - lock_ts))
            if [ "$age" -lt 0 ] || [ "$age" -gt 3600000 ]; then
                stale="1"
            fi
        fi
        if [ "$stale" -eq 0 ] && [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
            if ! kill -0 "$lock_pid" 2>/dev/null; then
                stale="1"
            fi
        fi
        if [ "$stale" -eq 1 ]; then
            rm -rf "$gc_lock" 2>/dev/null || true
            if mkdir "$gc_lock" 2>/dev/null; then
                acquired="1"
            fi
        fi
    fi
    [ "$acquired" -eq 1 ] || return 0
    printf '%s\n' "$$" >"$gc_lock/pid" 2>/dev/null || true
    printf '%s\n' "$now" >"$gc_lock/ts" 2>/dev/null || true

    # Re-check under lock.
    last_gc="0"
    if [ -f "$gc_file" ]; then
        last_gc="$(cat "$gc_file" 2>/dev/null | tr -d '\n' || true)"
    fi
    if [[ "$last_gc" =~ ^[0-9]+$ ]] && [ "$last_gc" -gt 0 ]; then
        local since=$((now - last_gc))
        if [ "$since" -ge 0 ] && [ "$since" -lt "$gc_interval_ms" ]; then
            rm -rf "$gc_lock" 2>/dev/null || true
            return 0
        fi
    fi

    local tmp_gc="$gc_file.$$.$RANDOM"
    printf '%s\n' "$now" >"$tmp_gc" 2>/dev/null || true
    mv -f "$tmp_gc" "$gc_file" 2>/dev/null || true

    local f=""
    for f in "$dir"/*.ts; do
        [ -e "$f" ] || break
        local base="${f##*/}"
        if [ "$base" = ".gc.ts" ]; then
            continue
        fi
        local ts=""
        ts="$(cat "$f" 2>/dev/null | tr -d '\n' || true)"
        if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
            rm -f "$f" 2>/dev/null || true
            continue
        fi
        local delta=$((now - ts))
        if [ "$delta" -ge "$ttl_ms" ]; then
            rm -f "$f" 2>/dev/null || true
        fi
    done

    rm -rf "$gc_lock" 2>/dev/null || true
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

    dedupe_gc_maybe "$dir" "$now" "$window_ms" || true

    # Best-effort per-key lock to avoid races when multiple processes notify at once.
    local lock="$file.lock"
    local acquired="0"
    local attempt=0
    while [ "$attempt" -lt 3 ]; do
        if mkdir "$lock" 2>/dev/null; then
            acquired="1"
            printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
            break
        fi
        local pid=""
        pid="$(cat "$lock/pid" 2>/dev/null | tr -d '\n' || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$lock" 2>/dev/null || true
            continue
        fi
        sleep 0.02 2>/dev/null || true
        attempt=$((attempt + 1))
    done

    if [ "$acquired" -ne 1 ] && [ -d "$lock" ] && [ ! -s "$lock/pid" ]; then
        # If a process died between `mkdir` and writing pid, the lock may be empty forever.
        rm -rf "$lock" 2>/dev/null || true
        if mkdir "$lock" 2>/dev/null; then
            acquired="1"
            printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
        fi
    fi

    if [ "$acquired" -ne 1 ]; then
        # Couldn't lock (permissions or contention). Fall back to a best-effort read-only check.
        local last="0"
        if [ -f "$file" ]; then
            last="$(cat "$file" 2>/dev/null | tr -d '\n' || true)"
        fi
        if [[ "$last" =~ ^[0-9]+$ ]] && [ "$last" -gt 0 ]; then
            local delta=$((now - last))
            if [ "$delta" -ge 0 ] && [ "$delta" -lt "$window_ms" ]; then
                return 0
            fi
        fi
        return 1
    fi

    local suppress="1"
    local last="0"
    if [ -f "$file" ]; then
        last="$(cat "$file" 2>/dev/null | tr -d '\n' || true)"
    fi
    if [[ "$last" =~ ^[0-9]+$ ]] && [ "$last" -gt 0 ]; then
        local delta=$((now - last))
        if [ "$delta" -ge 0 ] && [ "$delta" -lt "$window_ms" ]; then
            suppress="0"
        fi
    fi

    if [ "$suppress" -ne 0 ]; then
        local tmp="$file.$$.$RANDOM"
        printf '%s\n' "$now" >"$tmp" 2>/dev/null || true
        mv -f "$tmp" "$file" 2>/dev/null || true
    fi

    rm -rf "$lock" 2>/dev/null || true
    if [ "$suppress" -eq 0 ]; then
        return 0
    fi
    return 1
}
