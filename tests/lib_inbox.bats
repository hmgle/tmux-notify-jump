#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"
    export TMUX_NOTIFY_TMUX_SOCKET="$TEST_TEMP_DIR/tmux.sock"
    unset TMUX
    export TMUX_NOTIFY_INBOX_TTL_MS=604800000
    export TMUX_NOTIFY_INBOX_MAX=100
    TMUX_LOG="$TEST_TEMP_DIR/tmux.log"
    export TMUX_LOG
    FAKE_TARGET_SESSION_ID='$1'
    FAKE_TARGET_WINDOW_ID='@2'
    FAKE_TARGET_PANE_ID='%9'
    FAKE_TARGET_SESSION_NAME='work'
    FAKE_TARGET_WINDOW_INDEX='3'
    FAKE_CLIENT_ROWS='0|10|/dev/pts/2|/dev/pts/2|222|$1|%1|work'
    FAKE_TMUX_VERSION='tmux 3.7'
    FAKE_SOCKET_PATH="$TMUX_NOTIFY_TMUX_SOCKET"
    FAKE_INBOX_ROOT=""
    FAKE_STATUS_RIGHT=""
    FAKE_KEY_OPTION=""
    FAKE_BINDING=""
    FAKE_HOOK_COMMAND=""
    FAKE_HOOK_NAME_ARG=1
    FAKE_SWITCH_FAIL=0
    FAKE_PANE_EXISTS=1
    FAKE_WINDOW_EXISTS=1
    FAKE_SESSION_EXISTS=1
}

teardown() {
    teardown_temp_dir
}

tmux_cmd() {
    printf '%s\n' "$*" >>"$TMUX_LOG"
    local cmd="${1:-}"
    case "$cmd" in
        -V)
            printf '%s\n' "$FAKE_TMUX_VERSION"
            ;;
        display-message)
            if [ "${2:-}" = "-p" ] && [ "${3:-}" = '#{pid}' ]; then
                printf '4242\n'
            elif [ "${2:-}" = "-p" ] && [ "${3:-}" = '#{socket_path}' ]; then
                printf '%s\n' "$FAKE_SOCKET_PATH"
            elif [ "${2:-}" = "-p" ] && [ "${3:-}" = "-t" ]; then
                case "${5:-}" in
                    '#{session_id}|#{window_id}|#{pane_id}|#{session_name}|#{window_index}')
                        printf '%s|%s|%s|%s|%s\n' \
                            "$FAKE_TARGET_SESSION_ID" "$FAKE_TARGET_WINDOW_ID" \
                            "$FAKE_TARGET_PANE_ID" "$FAKE_TARGET_SESSION_NAME" \
                            "$FAKE_TARGET_WINDOW_INDEX"
                        ;;
                    '#{pane_id}')
                        [ "$FAKE_PANE_EXISTS" -eq 1 ] && [ "${4:-}" = "$FAKE_TARGET_PANE_ID" ] \
                            && printf '%s\n' "$FAKE_TARGET_PANE_ID"
                        ;;
                    '#{window_id}')
                        [ "$FAKE_WINDOW_EXISTS" -eq 1 ] && [ "${4:-}" = "$FAKE_TARGET_WINDOW_ID" ] \
                            && printf '%s\n' "$FAKE_TARGET_WINDOW_ID"
                        ;;
                    '#{session_id}')
                        [ "$FAKE_SESSION_EXISTS" -eq 1 ] && [ "${4:-}" = "$FAKE_TARGET_SESSION_ID" ] \
                            && printf '%s\n' "$FAKE_TARGET_SESSION_ID"
                        ;;
                esac
            fi
            ;;
        list-clients)
            [ -z "$FAKE_CLIENT_ROWS" ] || printf '%s\n' "$FAKE_CLIENT_ROWS"
            ;;
        list-keys)
            [ -z "$FAKE_BINDING" ] || printf '%s\n' "$FAKE_BINDING"
            ;;
        show-hooks)
            [ -n "$FAKE_HOOK_COMMAND" ] || return 0
            if [ -n "${3:-}" ]; then
                # Releases that do not accept a hook name answer with nothing.
                [ "$FAKE_HOOK_NAME_ARG" -eq 1 ] || return 0
                printf '%s[900] %s\n' "$3" "$FAKE_HOOK_COMMAND"
                return 0
            fi
            local hook_name=""
            for hook_name in client-attached client-session-changed \
                after-select-pane after-select-window client-focus-in; do
                printf '%s[900] %s\n' "$hook_name" "$FAKE_HOOK_COMMAND"
            done
            ;;
        show-option)
            case "${3:-}" in
                @tmux-notify-jump-inbox-root) printf '%s' "$FAKE_INBOX_ROOT" ;;
                @tmux-notify-jump-key) printf '%s' "$FAKE_KEY_OPTION" ;;
                status-right) printf '%s' "$FAKE_STATUS_RIGHT" ;;
            esac
            ;;
        set-option)
            case "${3:-}" in
                @tmux-notify-jump-inbox-root) FAKE_INBOX_ROOT="${4:-}" ;;
                @tmux-notify-jump-key) FAKE_KEY_OPTION="${4:-}" ;;
                status-right) FAKE_STATUS_RIGHT="${4:-}" ;;
            esac
            ;;
        switch-client)
            [ "$FAKE_SWITCH_FAIL" -eq 0 ]
            ;;
    esac
}

@test "Inbox collapses repeated pane and kind notifications" {
    tmux_notify_inbox_enqueue "%9" complete Codex "Done" "First"
    tmux_notify_inbox_enqueue "%9" complete Codex "Done again" "Second"

    root="$(tmux_notify_inbox_root)"
    entries=("$root"/*)
    [ "${#entries[@]}" -eq 1 ]
    [ "$(cat "${entries[0]}/count")" = "2" ]
    [ "$(cat "${entries[0]}/title")" = "Done again" ]
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" = "2" ]
}

@test "Inbox commands share state across explicit and TMUX sockets" {
    export TMUX="$TMUX_NOTIFY_TMUX_SOCKET,4242,0"
    tmux_notify_inbox_enqueue "%9" attention Codex "Needs input" "Private body"
    explicit_root="$(tmux_notify_inbox_root)"

    unset TMUX_NOTIFY_TMUX_SOCKET

    [ "$(tmux_notify_inbox_root)" = "$explicit_root" ]
    output="$(tmux_notify_inbox_list)"
    [[ "$output" == *$'attention\t1\t%9\tCodex\tNeeds input'* ]]
}

@test "Inbox root queries the socket outside tmux" {
    explicit_root="$(tmux_notify_inbox_root)"

    unset TMUX_NOTIFY_TMUX_SOCKET

    [ "$(tmux_notify_inbox_root)" = "$explicit_root" ]
}

@test "tmux init pins the Inbox root across shell environments" {
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/server-cache"
    expected_root="$(tmux_notify_inbox_default_root)"

    tmux_notify_tmux_init
    [ "$FAKE_INBOX_ROOT" = "$expected_root" ]

    export XDG_CACHE_HOME="$TEST_TEMP_DIR/pane-cache"
    [ "$(tmux_notify_inbox_root)" = "$expected_root" ]
}

@test "Inbox root rejects a non-absolute pinned option" {
    expected_root="$(tmux_notify_inbox_default_root)"

    FAKE_INBOX_ROOT="relative/inbox"
    [ "$(tmux_notify_inbox_root)" = "$expected_root" ]

    FAKE_INBOX_ROOT="$TEST_TEMP_DIR/absolute-inbox"
    [ "$(tmux_notify_inbox_root)" = "$TEST_TEMP_DIR/absolute-inbox" ]
}

@test "Inbox cache is private and omits notification bodies" {
    previous_umask="$(umask)"
    umask 022
    tmux_notify_inbox_enqueue "%9" complete Codex "Private title" "Private body"
    umask "$previous_umask"

    root="$(tmux_notify_inbox_root)"
    entry="$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)"
    root_mode="$(stat -c '%a' "$root" 2>/dev/null || stat -f '%Lp' "$root")"
    entry_mode="$(stat -c '%a' "$entry" 2>/dev/null || stat -f '%Lp' "$entry")"
    title_mode="$(stat -c '%a' "$entry/title" 2>/dev/null || stat -f '%Lp' "$entry/title")"

    [ "$root_mode" = "700" ]
    [ "$entry_mode" = "700" ]
    [ "$title_mode" = "600" ]
    [ ! -e "$entry/body" ]
}

@test "acknowledging a pane removes both priorities" {
    tmux_notify_inbox_enqueue "%9" complete Codex "Done" "Body"
    tmux_notify_inbox_enqueue "%9" attention Claude "Permission" "Body"

    tmux_notify_inbox_ack_pane "%9"

    root="$(tmux_notify_inbox_root)"
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
    [ "$TMUX_NOTIFY_INBOX_ATTENTION" = "0" ]
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" = "0" ]
}

@test "legacy remote opt-in maps to desktop mode" {
    unset TMUX_NOTIFY_REMOTE_MODE
    export TMUX_NOTIFY_REMOTE=1
    [ "$(tmux_notify_remote_mode)" = "desktop" ]
}

@test "default remote mode is tmux" {
    unset TMUX_NOTIFY_REMOTE_MODE TMUX_NOTIFY_REMOTE
    [ "$(tmux_notify_remote_mode)" = "tmux" ]
}

@test "remote tmux routing enqueues and skips desktop dependencies" {
    tmux_client_pid_is_remote_ssh() { return 0; }

    tmux_notify_route_notification "%9" "Needs input" "Approve tool" attention Claude

    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "0" ]
    root="$(tmux_notify_inbox_root)"
    entries=("$root"/*)
    [ "${#entries[@]}" -eq 1 ]
    [ "$(cat "${entries[0]}/kind")" = "attention" ]
    run rg 'display-message -c /dev/pts/2' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "Inbox next chooses attention before completion" {
    tmux_notify_inbox_enqueue "%9" complete Codex "Done" "Body"

    FAKE_TARGET_WINDOW_ID='@3'
    FAKE_TARGET_PANE_ID='%10'
    FAKE_TARGET_WINDOW_INDEX='4'
    tmux_notify_inbox_enqueue "%10" attention Claude "Permission" "Body"
    FAKE_CLIENT_ROWS=$'0|20|/dev/pts/target|/dev/pts/target|222|$1|%1|work\n0|10|/dev/pts/sender|/dev/pts/sender|333|$9|%7|main'

    tmux_notify_inbox_next "/dev/pts/sender"

    root="$(tmux_notify_inbox_root)"
    kinds="$(for entry in "$root"/*; do [ -f "$entry/kind" ] && cat "$entry/kind"; done)"
    [ "$kinds" = "complete" ]
    run rg 'select-pane -t %10' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run rg 'switch-client -c /dev/pts/sender' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "local clients in another session retain desktop delivery" {
    FAKE_CLIENT_ROWS='0|10|/dev/pts/local|/dev/pts/local|222|$9|%7|main'
    tmux_client_pid_is_remote_ssh() { return 1; }

    tmux_notify_route_notification "%9" "Done" "Body" complete Codex

    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "1" ]
    root="$(tmux_notify_inbox_root)"
    [ -n "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
}

@test "headless routing distinguishes local and SSH processes" {
    FAKE_CLIENT_ROWS=''
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY

    tmux_notify_route_notification "%9" "Local" "Body" complete Codex
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "1" ]

    tmux_notify_inbox_clear_all
    export SSH_CONNECTION='client server'
    tmux_notify_route_notification "%9" "Remote" "Body" complete Codex
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "0" ]
}

@test "desktop both and suppress modes route explicitly" {
    FAKE_CLIENT_ROWS=''
    export SSH_CONNECTION='client server'
    local root="$(tmux_notify_inbox_root)"

    TMUX_NOTIFY_REMOTE_MODE=desktop
    tmux_notify_route_notification "%9" "Desktop" "Body" complete Codex
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "1" ]
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit 2>/dev/null)" ]

    TMUX_NOTIFY_REMOTE_MODE=both
    tmux_notify_route_notification "%9" "Both" "Body" complete Codex
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "1" ]
    [ -n "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]

    tmux_notify_inbox_clear_all
    TMUX_NOTIFY_REMOTE_MODE=suppress
    tmux_notify_route_notification "%9" "Suppress" "Body" complete Codex
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "0" ]
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit 2>/dev/null)" ]
}

@test "visible target acknowledges existing Inbox entries" {
    tmux_notify_inbox_enqueue "%9" attention Claude "Permission" "Body"
    FAKE_CLIENT_ROWS='0|10|/dev/pts/local|/dev/pts/local|222|$1|%9|work'
    tmux_client_pid_is_remote_ssh() { return 1; }

    tmux_notify_route_notification "%9" "Visible" "Body" complete Codex

    root="$(tmux_notify_inbox_root)"
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "1" ]
}

@test "ack miss still resynchronizes counts" {
    : >"$TMUX_LOG"

    tmux_notify_inbox_ack_pane "%99"

    run rg 'set-option -gq @tmux-notify-jump-attention 0' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run rg 'set-option -gq @tmux-notify-jump-complete 0' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "ack converges counts after entries vanish outside the Inbox flow" {
    tmux_notify_inbox_enqueue "%9" complete Codex "Done"
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" = "1" ]

    # Simulate a cleared cache: the tmux counts still arm the hook guard, so
    # the next acknowledgement must drive them back to zero.
    rm -rf "$(tmux_notify_inbox_root)"
    : >"$TMUX_LOG"

    tmux_notify_inbox_ack_pane "%1"

    [ "$TMUX_NOTIFY_INBOX_COMPLETE" = "0" ]
    [ "$TMUX_NOTIFY_INBOX_ATTENTION" = "0" ]
    run rg 'set-option -gq @tmux-notify-jump-complete 0' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "ack client ignores an empty hook client" {
    : >"$TMUX_LOG"

    tmux_notify_inbox_ack_client ""

    [ ! -s "$TMUX_LOG" ]
}

@test "Inbox GC enforces maximum entries and TTL" {
    export TMUX_NOTIFY_INBOX_MAX=1
    export TMUX_NOTIFY_INBOX_TTL_MS=0
    tmux_notify_inbox_enqueue "%9" complete Codex "First" "Body"
    root="$(tmux_notify_inbox_root)"
    first_entry="$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)"
    printf '1\n' >"$first_entry/last_ms"
    FAKE_TARGET_PANE_ID='%10'
    tmux_notify_inbox_enqueue "%10" complete Codex "Second" "Body"

    entries=("$root"/*)
    [ "${#entries[@]}" -eq 1 ]
    [ "$(cat "${entries[0]}/pane_id")" = "%10" ]

    export TMUX_NOTIFY_INBOX_TTL_MS=604800000
    printf '1\n' >"${entries[0]}/last_ms"
    tmux_notify_inbox_gc "$root" "604800002"
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
}

@test "Inbox next retains a live target after switch failure" {
    tmux_notify_inbox_enqueue "%9" attention Claude "Permission" "Body"
    FAKE_SWITCH_FAIL=1

    run tmux_notify_inbox_next "/dev/pts/2"

    [ "$status" -eq 1 ]
    root="$(tmux_notify_inbox_root)"
    [ -n "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
}

@test "Inbox next falls back to a live window and consumes the entry" {
    tmux_notify_inbox_enqueue "%9" attention Claude "Permission" "Body"
    FAKE_PANE_EXISTS=0

    tmux_notify_inbox_next "/dev/pts/2"

    root="$(tmux_notify_inbox_root)"
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
    run rg 'select-window -t @2' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run rg 'select-pane -t %9' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}

@test "Inbox next removes an entry whose session no longer exists" {
    tmux_notify_inbox_enqueue "%9" attention Claude "Permission" "Body"
    FAKE_PANE_EXISTS=0
    FAKE_WINDOW_EXISTS=0
    FAKE_SESSION_EXISTS=0

    run tmux_notify_inbox_next "/dev/pts/2"

    [ "$status" -eq 1 ]
    root="$(tmux_notify_inbox_root)"
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
}

@test "Inbox lock acquisition retries transient contention" {
    lock_attempts=0
    acquire_lock() {
        lock_attempts=$((lock_attempts + 1))
        [ "$lock_attempts" -ge 3 ]
    }

    tmux_notify_inbox_acquire_lock "$TEST_TEMP_DIR/test.lock"

    [ "$lock_attempts" -eq 3 ]
}

@test "tmux before 3.0 warns that automatic acknowledgement is unavailable" {
    FAKE_TMUX_VERSION='tmux 2.9a'
    _QUIET=0

    run tmux_notify_tmux_init

    [ "$status" -eq 0 ]
    [[ "$output" == *"tmux 3.0 or newer"* ]]
    run rg 'set-hook' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}

@test "tmux init quotes entrypoint paths in hooks and bindings" {
    TMUX_NOTIFY_ENTRYPOINT='/tmp/bin with spaces/tmux-notify-jump'

    tmux_notify_tmux_init

    run rg -F 'bin\ with\ spaces/tmux-notify-jump --inbox-ack-client' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run rg -F '#{&&:#{||:#{@tmux-notify-jump-attention},#{@tmux-notify-jump-complete}},#{hook_client}}' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run rg -F 'after-switch-client' "$TMUX_LOG"
    [ "$status" -eq 1 ]
    run rg -F 'bin\ with\ spaces/tmux-notify-jump --inbox-next' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "tmux init can remove its status segment" {
    status_segment="$(tmux_notify_tmux_status_segment)"
    FAKE_STATUS_RIGHT="left${status_segment} right"
    TMUX_NOTIFY_TMUX_STATUS=0

    tmux_notify_tmux_init

    [ "$FAKE_STATUS_RIGHT" = "left right" ]
}

@test "tmux uninit removes its running server state" {
    status_segment="$(tmux_notify_tmux_status_segment)"
    FAKE_STATUS_RIGHT="left${status_segment} right"
    FAKE_KEY_OPTION=M
    FAKE_BINDING='bind-key -T prefix M run-shell -b "tmux-notify-jump --inbox-next"'
    FAKE_HOOK_COMMAND='if-shell -F 1 { run-shell -b "tmux-notify-jump --inbox-ack-client client" }'
    FAKE_INBOX_ROOT="$TEST_TEMP_DIR/pinned-inbox"
    mkdir -p "$FAKE_INBOX_ROOT/item"
    : >"$FAKE_INBOX_ROOT/item/kind"

    tmux_notify_tmux_uninit

    [ "$FAKE_STATUS_RIGHT" = "left right" ]
    [ -z "$(find "$FAKE_INBOX_ROOT" -mindepth 1 -print -quit)" ]
    run rg -c '^set-hook -gu .+\[900\]$' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
    run rg -F 'unbind-key -T prefix M' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run rg -F 'set-option -gu @tmux-notify-jump-inbox-root' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "tmux uninit reads the full hook table when named lookup is unsupported" {
    FAKE_HOOK_NAME_ARG=0
    FAKE_KEY_OPTION=M
    FAKE_HOOK_COMMAND='if-shell -F 1 { run-shell -b "tmux-notify-jump --inbox-ack-client client" }'

    tmux_notify_tmux_uninit

    run rg -c '^set-hook -gu .+\[900\]$' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "tmux uninit preserves user-owned hooks and bindings" {
    FAKE_KEY_OPTION=M
    FAKE_BINDING='bind-key -T prefix M next-window'
    FAKE_HOOK_COMMAND='select-pane -L'

    tmux_notify_tmux_uninit

    run rg '^(set-hook -gu|unbind-key)' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}

@test "tmux init recognizes its serialized binding with a quoted path" {
    TMUX_NOTIFY_ENTRYPOINT='/tmp/bin with spaces/tmux-notify-jump'
    tmux_cmd() {
        printf '%s\n' "$*" >>"$TMUX_LOG"
        case "${1:-}" in
            -V)
                printf '%s\n' 'tmux 3.7'
                ;;
            list-keys)
                printf '%s\n' 'bind-key -T prefix N run-shell -b "TMUX_NOTIFY_SENDER_TTY=\"#{client_tty}\" /tmp/bin\\ with\\ spaces/tmux-notify-jump --inbox-next"'
                ;;
        esac
    }

    run tmux_notify_tmux_init

    [ "$status" -eq 0 ]
    [[ "$output" != *"already bound"* ]]
    run rg '^bind-key N ' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}
