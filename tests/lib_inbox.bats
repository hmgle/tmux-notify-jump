#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"
    export TMUX_NOTIFY_TMUX_SOCKET="$TEST_TEMP_DIR/tmux.sock"
    unset TMUX TMUX_NOTIFY_TMUX_KEY TMUX_NOTIFY_ENTRYPOINT
    unset TMUX_NOTIFY_REMOTE_MODE TMUX_NOTIFY_REMOTE
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY
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
    FAKE_ATTENTION_COUNT=""
    FAKE_COMPLETE_COUNT=""
    FAKE_STATUS_RIGHT=""
    FAKE_KEY_OPTION=""
    FAKE_BINDING=""
    FAKE_HOOK_COMMAND=""
    FAKE_SWITCH_FAIL=0
    FAKE_SWITCH_NOOP=0
    FAKE_PANE_EXISTS=1
    FAKE_WINDOW_EXISTS=1
    FAKE_SESSION_EXISTS=1
    FAKE_DISPLAY_FAIL=0
    FAKE_INVENTORY_FAIL=0
    FAKE_PANE_ROWS='%9|$1|@2|3|0|work'
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
            [ "$FAKE_DISPLAY_FAIL" -eq 0 ] || return 1
            if [ "${2:-}" = "-p" ] && [ "${3:-}" = '#{pid}' ]; then
                printf '4242\n'
            elif [ "${2:-}" = "-p" ] && [ "${3:-}" = '#{socket_path}' ]; then
                printf '%s\n' "$FAKE_SOCKET_PATH"
            elif [ "${2:-}" = "-p" ] && [ "${3:-}" = '#{version}' ]; then
                printf '%s\n' "${FAKE_TMUX_VERSION#tmux }"
            elif [ "${2:-}" = "-p" ] && [ "${3:-}" = "-t" ]; then
                case "${5:-}" in
                    '#{session_id}|#{window_id}|#{pane_id}|#{window_index}|#{session_name}')
                        printf '%s|%s|%s|%s|%s\n' \
                            "$FAKE_TARGET_SESSION_ID" "$FAKE_TARGET_WINDOW_ID" \
                            "$FAKE_TARGET_PANE_ID" "$FAKE_TARGET_WINDOW_INDEX" \
                            "$FAKE_TARGET_SESSION_NAME"
                        ;;
                    '#{pane_id}')
                        [ "$FAKE_PANE_EXISTS" -eq 1 ] && [ "${4:-}" = "$FAKE_TARGET_PANE_ID" ] \
                            && printf '%s\n' "$FAKE_TARGET_PANE_ID"
                        ;;
                    '#{window_id}')
                        [ "$FAKE_WINDOW_EXISTS" -eq 1 ] \
                            && { [ "${4:-}" = "$FAKE_TARGET_WINDOW_ID" ] || is_pane_id "${4:-}"; } \
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
        list-panes)
            [ "$FAKE_INVENTORY_FAIL" -eq 0 ] || return 1
            if [ "${4:-}" = '#{session_id}|#{window_id}|#{pane_id}' ]; then
                if [ -n "${FAKE_SELECTION_ROWS+x}" ]; then
                    printf '%s\n' "$FAKE_SELECTION_ROWS"
                elif [ "$FAKE_PANE_EXISTS" -eq 1 ]; then
                    printf '%s|%s|%s\n' "$FAKE_TARGET_SESSION_ID" "$FAKE_TARGET_WINDOW_ID" "$FAKE_TARGET_PANE_ID"
                elif [ "$FAKE_WINDOW_EXISTS" -eq 1 ]; then
                    printf '%s|%s|%%1\n' "$FAKE_TARGET_SESSION_ID" "$FAKE_TARGET_WINDOW_ID"
                elif [ "$FAKE_SESSION_EXISTS" -eq 1 ]; then
                    printf '%s|@99|%%1\n' "$FAKE_TARGET_SESSION_ID"
                else
                    printf '$99|@99|%%99\n'
                fi
            else
                printf '%s\n' "$FAKE_PANE_ROWS"
            fi
            ;;
        display-menu|display-popup)
            printf '%s\n' "$@" >"$TEST_TEMP_DIR/picker.args"
            ;;
        capture-pane)
            printf 'recent pane output\n'
            ;;
        list-keys)
            [ -z "$FAKE_BINDING" ] || printf '%s\n' "$FAKE_BINDING"
            ;;
        show-hooks)
            [ -n "$FAKE_HOOK_COMMAND" ] || return 0
            if [ -n "${3:-}" ]; then
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
                @tmux-notify-jump-attention) printf '%s' "$FAKE_ATTENTION_COUNT" ;;
                @tmux-notify-jump-complete) printf '%s' "$FAKE_COMPLETE_COUNT" ;;
                @tmux-notify-jump-key) printf '%s' "$FAKE_KEY_OPTION" ;;
                status-right) printf '%s' "$FAKE_STATUS_RIGHT" ;;
            esac
            ;;
        set-option)
            case "${3:-}" in
                @tmux-notify-jump-inbox-root) FAKE_INBOX_ROOT="${4:-}" ;;
                @tmux-notify-jump-attention) FAKE_ATTENTION_COUNT="${4:-}" ;;
                @tmux-notify-jump-complete) FAKE_COMPLETE_COUNT="${4:-}" ;;
                @tmux-notify-jump-key) FAKE_KEY_OPTION="${4:-}" ;;
                status-right) FAKE_STATUS_RIGHT="${4:-}" ;;
            esac
            ;;
        switch-client)
            [ "$FAKE_SWITCH_FAIL" -eq 0 ] || return 1
            [ "$FAKE_SWITCH_NOOP" -eq 0 ] || return 0
            local row client_name="${3:-}" pane_id selected_pane="$FAKE_TARGET_PANE_ID"
            [ "$FAKE_PANE_EXISTS" -eq 1 ] || selected_pane='%1'
            local updated=""
            while IFS= read -r row; do
                IFS='|' read -r mode activity name tty pid sid pane_id session_name <<<"$row"
                if [ "$name" = "$client_name" ]; then
                    row="$mode|$activity|$name|$tty|$pid|$FAKE_TARGET_SESSION_ID|$selected_pane|$FAKE_TARGET_SESSION_NAME"
                fi
                updated+="$row"$'\n'
            done <<<"$FAKE_CLIENT_ROWS"
            FAKE_CLIENT_ROWS="${updated%$'\n'}"
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

@test "Inbox root accepts only the owned namespace" {
    expected_root="$(tmux_notify_inbox_default_root)"
    server_id="${expected_root##*/}"

    FAKE_INBOX_ROOT="relative/inbox"
    [ "$(tmux_notify_inbox_root)" = "$expected_root" ]

    FAKE_INBOX_ROOT="$TEST_TEMP_DIR/absolute-inbox"
    [ "$(tmux_notify_inbox_root)" = "$expected_root" ]

    FAKE_INBOX_ROOT="$TEST_TEMP_DIR/tmux-notify-jump/inbox/wrong-server"
    [ "$(tmux_notify_inbox_root)" = "$expected_root" ]

    FAKE_INBOX_ROOT="$TEST_TEMP_DIR/custom/tmux-notify-jump/inbox/$server_id"
    [ "$(tmux_notify_inbox_root)" = "$FAKE_INBOX_ROOT" ]
}

@test "Inbox root rejects traversal and symbolic links" {
    expected_root="$(tmux_notify_inbox_default_root)"
    server_id="${expected_root##*/}"
    foreign_root="$TEST_TEMP_DIR/foreign"
    linked_root="$TEST_TEMP_DIR/linked/tmux-notify-jump/inbox/$server_id"
    linked_parent="$TEST_TEMP_DIR/linked-parent/tmux-notify-jump/inbox"
    mkdir -p "$foreign_root" "$(dirname "$linked_root")" \
        "$(dirname "$linked_parent")"
    ln -s "$foreign_root" "$linked_root"

    FAKE_INBOX_ROOT="$TEST_TEMP_DIR/tmux-notify-jump/inbox/../inbox/$server_id"
    [ "$(tmux_notify_inbox_root)" = "$expected_root" ]

    FAKE_INBOX_ROOT="$linked_root"
    [ "$(tmux_notify_inbox_root)" = "$expected_root" ]

    ln -s "$foreign_root" "$linked_parent"
    mkdir -p "$foreign_root/$server_id"
    FAKE_INBOX_ROOT="$linked_parent/$server_id"
    [ "$(tmux_notify_inbox_root)" = "$expected_root" ]
}

@test "Inbox default root ignores a relative cache base" {
    export HOME="$TEST_TEMP_DIR/home"
    export XDG_CACHE_HOME="relative/cache"

    root="$(tmux_notify_inbox_default_root)"

    [[ "$root" == "$HOME/.cache/tmux-notify-jump/inbox/"* ]]
}

@test "Inbox default root preserves a trailing newline in the cache base" {
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"$'\n'

    root="$(tmux_notify_inbox_default_root)"

    [[ "$root" == "$XDG_CACHE_HOME/tmux-notify-jump/inbox/"* ]]
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

@test "client SSH state detects an sshd ancestor" {
    ps() {
        case "${4:-}:${2:-}" in
            comm=:987654) printf '%s\n' "tmux" ;;
            ppid=:987654) printf '%s\n' "987653" ;;
            comm=:987653) printf '%s\n' "sshd" ;;
            ppid=:987653) printf '%s\n' "1" ;;
            *) return 1 ;;
        esac
    }

    [ "$(tmux_client_pid_ssh_state 987654)" = "remote" ]
}

@test "client SSH state confirms a local process tree" {
    ps() {
        case "${4:-}:${2:-}" in
            comm=:987654) printf '%s\n' "tmux" ;;
            ppid=:987654) printf '%s\n' "987653" ;;
            comm=:987653) printf '%s\n' "zsh" ;;
            ppid=:987653) printf '%s\n' "1" ;;
            *) return 1 ;;
        esac
    }

    [ "$(tmux_client_pid_ssh_state 987654)" = "local" ]
}

@test "client SSH state preserves inspection failures as unknown" {
    ps() { return 1; }

    [ "$(tmux_client_pid_ssh_state 987654)" = "unknown" ]
    [ "$(tmux_client_pid_ssh_state invalid)" = "unknown" ]
}

@test "remote tmux routing enqueues and skips desktop dependencies" {
    tmux_client_pid_ssh_state() { printf '%s' "remote"; }

    tmux_notify_route_notification "%9" "Needs input" "Approve tool" attention Claude

    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "0" ]
    root="$(tmux_notify_inbox_root)"
    entries=("$root"/*)
    [ "${#entries[@]}" -eq 1 ]
    [ "$(cat "${entries[0]}/kind")" = "attention" ]
    run rg 'display-message -c /dev/pts/2' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "remote target client suppresses desktop with local clients attached" {
    FAKE_CLIENT_ROWS=$'0|20|/dev/pts/remote|/dev/pts/remote|222|$1|%9|work\n0|10|/dev/pts/local|/dev/pts/local|333|$1|%9|work'
    tmux_client_pid_ssh_state() {
        case "$1" in
            222) printf '%s' "remote" ;;
            333) printf '%s' "local" ;;
        esac
    }
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY

    tmux_notify_route_notification "%9" "Done" "Body" complete Codex

    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "0" ]
    run rg 'display-message -c /dev/pts/remote' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "remote target client suppresses desktop from local clients in other sessions" {
    FAKE_CLIENT_ROWS=$'0|20|/dev/pts/remote|/dev/pts/remote|222|$1|%9|work\n0|10|/dev/pts/local|/dev/pts/local|333|$9|%7|main'
    tmux_client_pid_ssh_state() {
        case "$1" in
            222) printf '%s' "remote" ;;
            333) printf '%s' "local" ;;
        esac
    }
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY

    tmux_notify_route_notification "%9" "Done" "Body" complete Codex

    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "0" ]
}

@test "unknown target client does not enable desktop delivery" {
    FAKE_CLIENT_ROWS='0|10|/dev/pts/unknown|/dev/pts/unknown|222|$1|%9|work'
    tmux_client_pid_ssh_state() { printf '%s' "unknown"; }
    unset SSH_CONNECTION SSH_CLIENT SSH_TTY

    tmux_notify_route_notification "%9" "Done" "Body" complete Codex

    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "0" ]
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
    tmux_client_pid_ssh_state() { printf '%s' "local"; }

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

@test "both mode keeps desktop delivery for mixed remote and local clients" {
    FAKE_CLIENT_ROWS=$'0|20|/dev/pts/remote|/dev/pts/remote|222|$1|%9|work\n0|10|/dev/pts/local|/dev/pts/local|333|$9|%7|main'
    tmux_client_pid_ssh_state() {
        case "$1" in
            222) printf '%s' "remote" ;;
            333) printf '%s' "local" ;;
        esac
    }
    TMUX_NOTIFY_REMOTE_MODE=both

    tmux_notify_route_notification "%9" "Both" "Body" complete Codex

    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "1" ]
    run rg 'display-message -c /dev/pts/remote' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "missing target metadata respects remote routing modes" {
    FAKE_CLIENT_ROWS='0|10|/dev/pts/remote|/dev/pts/remote|222|$1|%9|work'
    tmux_client_pid_ssh_state() { printf '%s' "remote"; }
    tmux_notify_inbox_target_info() { return 0; }

    TMUX_NOTIFY_REMOTE_MODE=tmux
    tmux_notify_route_notification "%9" "Tmux" "Body" complete Codex
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "0" ]

    TMUX_NOTIFY_REMOTE_MODE=suppress
    tmux_notify_route_notification "%9" "Suppress" "Body" complete Codex
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "0" ]

    TMUX_NOTIFY_REMOTE_MODE=desktop
    tmux_notify_route_notification "%9" "Desktop" "Body" complete Codex
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = "1" ]
}

@test "visible target acknowledges existing Inbox entries" {
    tmux_notify_inbox_enqueue "%9" attention Claude "Permission" "Body"
    FAKE_CLIENT_ROWS='0|10|/dev/pts/local|/dev/pts/local|222|$1|%9|work'
    tmux_client_pid_ssh_state() { printf '%s' "local"; }

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

@test "ack miss avoids refreshing unchanged counts" {
    tmux_notify_inbox_enqueue "%9" complete Codex "Done"
    : >"$TMUX_LOG"

    tmux_notify_inbox_ack_pane "%99"

    run rg '^(set-option -gq @tmux-notify-jump-(attention|complete)|refresh-client)' \
        "$TMUX_LOG"
    [ "$status" -eq 1 ]
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

@test "Inbox clear removes only owned entry directories" {
    root="$(tmux_notify_inbox_root)"
    entry_key="$(printf '%s' 'owned entry' | sha256_hex_stdin)"
    mkdir -p "$root/$entry_key" "$root/project"
    : >"$root/$entry_key/kind"
    : >"$root/project/kind"

    tmux_notify_inbox_clear_all

    [ ! -e "$root/$entry_key" ]
    [ -d "$root/project" ]
}

@test "Inbox clear counts successful removals and reports failures" {
    root="$(tmux_notify_inbox_root)"
    removed_key="$(printf '%s' 'removed entry' | sha256_hex_stdin)"
    failed_key="$(printf '%s' 'failed entry' | sha256_hex_stdin)"
    removed_entry="$root/$removed_key"
    failed_entry="$root/$failed_key"
    mkdir -p "$removed_entry" "$failed_entry"
    : >"$removed_entry/kind"
    : >"$failed_entry/kind"
    rm() {
        local arg="" last=""
        for arg in "$@"; do last="$arg"; done
        [ "$last" != "$failed_entry" ] || return 1
        command rm "$@"
    }

    clear_status=0
    tmux_notify_inbox_clear_all || clear_status=$?
    unset -f rm

    [ "$clear_status" -eq 1 ]
    [ "$TMUX_NOTIFY_INBOX_CLEARED" -eq 1 ]
    [ "$TMUX_NOTIFY_INBOX_CLEAR_FAILURES" -eq 1 ]
    [ ! -e "$removed_entry" ]
    [ -d "$failed_entry" ]
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

@test "Inbox GC prunes when the cache path contains a backslash escape" {
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/ca"$'\\'"the"
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
}

@test "Inbox next selects when the cache path contains a backslash escape" {
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/ca"$'\\'"the"
    tmux_notify_inbox_enqueue "%9" attention Claude "Permission" "Body"

    tmux_notify_inbox_next "/dev/pts/2"

    root="$(tmux_notify_inbox_root)"
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
    run rg 'select-pane -t %9' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "Inbox GC prunes when the cache path contains a newline" {
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/ca"$'\n'"the"
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
}

@test "Inbox next selects when the cache path contains a newline" {
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/ca"$'\n'"the"
    tmux_notify_inbox_enqueue "%9" attention Claude "Permission" "Body"

    tmux_notify_inbox_next "/dev/pts/2"

    root="$(tmux_notify_inbox_root)"
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
    run rg 'select-pane -t %9' "$TMUX_LOG"
    [ "$status" -eq 0 ]
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
    run rg -F 'select-window -t $1:@2' "$TMUX_LOG"
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

@test "Inbox selection acknowledges both priorities without installed focus hooks" {
    tmux_notify_inbox_enqueue '%9' attention Claude 'Permission'
    tmux_notify_inbox_enqueue '%9' complete Claude 'Done'
    id="$(printf '%s' '%9|attention' | sha256_hex_stdin)"

    tmux_notify_inbox_select "$id" /dev/pts/2

    [ "$TMUX_NOTIFY_INBOX_ATTENTION" -eq 0 ]
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 0 ]
    [ -z "$(tmux_notify_inbox_list)" ]
}

@test "Inbox stale selection retires both priorities even without an attached client" {
    tmux_notify_inbox_enqueue '%9' attention Claude 'Permission'
    tmux_notify_inbox_enqueue '%9' complete Claude 'Done'
    id="$(printf '%s' '%9|complete' | sha256_hex_stdin)"
    FAKE_PANE_EXISTS=0
    FAKE_WINDOW_EXISTS=0
    FAKE_SESSION_EXISTS=0
    FAKE_CLIENT_ROWS=''

    run tmux_notify_inbox_select "$id" /dev/pts/gone

    [ "$status" -eq 1 ]
    [ -z "$(tmux_notify_inbox_list)" ]
}

@test "Inbox selection retains both priorities when switch reports success without moving" {
    tmux_notify_inbox_enqueue '%9' attention Claude 'Permission'
    tmux_notify_inbox_enqueue '%9' complete Claude 'Done'
    id="$(printf '%s' '%9|complete' | sha256_hex_stdin)"
    FAKE_SWITCH_NOOP=1

    run tmux_notify_inbox_select "$id" /dev/pts/2

    [ "$status" -eq 1 ]
    [ "$(tmux_notify_inbox_list | wc -l)" -eq 2 ]
}

@test "Inbox selection preserves both entries when all tmux queries fail" {
    tmux_notify_inbox_enqueue '%9' attention Claude 'Permission'
    tmux_notify_inbox_enqueue '%9' complete Claude 'Done'
    id="$(printf '%s' '%9|complete' | sha256_hex_stdin)"
    root="$(tmux_notify_inbox_root)"
    FAKE_INBOX_ROOT="$root"
    FAKE_DISPLAY_FAIL=1
    FAKE_INVENTORY_FAIL=1
    : >"$TMUX_LOG"

    run tmux_notify_inbox_select "$id" /dev/pts/2

    [ "$status" -eq 1 ]
    [ "$(find "$root" -name pane_id | wc -l)" -eq 2 ]
    run rg '^switch-client|^set-option' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}

@test "Inbox selection does not infer stale targets from failed or malformed inventory" {
    tmux_notify_inbox_enqueue '%9' attention Claude 'Permission'
    tmux_notify_inbox_enqueue '%9' complete Claude 'Done'
    id="$(printf '%s' '%9|attention' | sha256_hex_stdin)"
    FAKE_PANE_EXISTS=0
    FAKE_WINDOW_EXISTS=0
    FAKE_SESSION_EXISTS=0
    FAKE_INVENTORY_FAIL=1
    run tmux_notify_inbox_select "$id" /dev/pts/2
    [ "$status" -eq 1 ]
    FAKE_INVENTORY_FAIL=0
    for FAKE_SELECTION_ROWS in '' '$99|@99|' '$99|@99|%99'$'\n''#{session_id}|@2|%9'; do
        run tmux_notify_inbox_select "$id" /dev/pts/2
        [ "$status" -eq 1 ]
        [ "$(tmux_notify_inbox_list | wc -l)" -eq 2 ]
    done
}

@test "Inbox closed pane follows its window into another session using one snapshot" {
    tmux_notify_inbox_enqueue '%9' complete Claude 'Done'
    id="$(printf '%s' '%9|complete' | sha256_hex_stdin)"
    FAKE_PANE_EXISTS=0
    FAKE_TARGET_SESSION_ID='$8'
    : >"$TMUX_LOG"

    tmux_notify_inbox_select "$id" /dev/pts/2

    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 0 ]
    run rg -F 'switch-client -c /dev/pts/2 -t $8 ; select-window -t $8:@2' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$(rg -c '^list-panes -a -F' "$TMUX_LOG")" -eq 1 ]
}

@test "Inbox closed pane prefers its recorded session when the window is linked" {
    tmux_notify_inbox_enqueue '%9' complete Claude 'Done'
    id="$(printf '%s' '%9|complete' | sha256_hex_stdin)"
    FAKE_PANE_EXISTS=0
    FAKE_SELECTION_ROWS=$'$8|@2|%1\n$1|@2|%1'

    tmux_notify_inbox_select "$id" /dev/pts/2

    run rg -F 'switch-client -c /dev/pts/2 -t $1 ; select-window -t $1:@2' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 0 ]
}

@test "Inbox corrupted empty session IDs cannot resolve an ambient target" {
    tmux_notify_inbox_enqueue '%9' complete Claude 'Done'
    id="$(printf '%s' '%9|complete' | sha256_hex_stdin)"
    root="$(tmux_notify_inbox_root)"
    printf '\n' >"$root/$id/session_id"
    printf '\n' >"$root/$id/window_id"
    FAKE_PANE_EXISTS=0
    FAKE_WINDOW_EXISTS=0
    FAKE_SESSION_EXISTS=0
    : >"$TMUX_LOG"

    run tmux_notify_inbox_select "$id" /dev/pts/2

    [ "$status" -eq 1 ]
    [ -z "$(tmux_notify_inbox_list)" ]
    run rg '^switch-client|display-message -p -t' "$TMUX_LOG"
    [ "$status" -eq 1 ]
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

@test "tmux init acknowledges select hooks by pane and client hooks by client" {
    # tmux expands #{hook_client} empty in after-select-pane and
    # after-select-window, so guarding those on it silently disables
    # acknowledgement for every ordinary pane and window switch. Those hooks
    # expand #{pane_id} to the pane just selected instead.
    TMUX_NOTIFY_ENTRYPOINT='/opt/tmux-notify-jump'
    attention_opt='#{@tmux-notify-jump-attention}'
    complete_opt='#{@tmux-notify-jump-complete}'

    tmux_notify_tmux_init

    for hook in after-select-pane after-select-window; do
        run rg -F "set-hook -g ${hook}[900] if-shell -F '#{&&:#{||:${attention_opt},${complete_opt}},#{pane_id}}' { run-shell -b '/opt/tmux-notify-jump --inbox-ack-pane \"#{pane_id}\"' }" "$TMUX_LOG"
        [ "$status" -eq 0 ]
    done
    for hook in client-attached client-session-changed client-focus-in; do
        run rg -F "set-hook -g ${hook}[900] if-shell -F '#{&&:#{||:${attention_opt},${complete_opt}},#{hook_client}}' { run-shell -b '/opt/tmux-notify-jump --inbox-ack-client \"#{hook_client}\"' }" "$TMUX_LOG"
        [ "$status" -eq 0 ]
    done
    run rg -F 'set-hook -g after-select' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" != *'hook_client'* ]]
}

@test "tmux uninit removes pane acknowledgement hooks" {
    FAKE_KEY_OPTION=M
    FAKE_HOOK_COMMAND='if-shell -F 1 { run-shell -b "tmux-notify-jump --inbox-ack-pane %1" }'

    tmux_notify_tmux_uninit

    run rg -c '^set-hook -gu .+\[900\]$' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "tmux uninit recognizes a server marked only by pane acknowledgement hooks" {
    FAKE_HOOK_COMMAND='if-shell -F 1 { run-shell -b "tmux-notify-jump --inbox-ack-pane %1" }'

    tmux_notify_tmux_uninit

    run rg -c '^set-hook -gu .+\[900\]$' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "tmux init can remove its status segment" {
    status_segment="$(tmux_notify_tmux_status_segment)"
    FAKE_STATUS_RIGHT="left${status_segment} right"
    TMUX_NOTIFY_TMUX_STATUS=0

    tmux_notify_tmux_init

    [ "$FAKE_STATUS_RIGHT" = "left right" ]
}

@test "tmux uninit clears a second configured server and reports the count" {
    # Servers sharing a tmux configuration all run --tmux-init, so they carry
    # identical marks and the unrelated-server guard cannot single out the
    # intended one. Pin that limit, and pin the count that makes it visible.
    FAKE_KEY_OPTION=N
    FAKE_INBOX_ROOT="$(tmux_notify_inbox_default_root)"
    for label in 'first entry' 'second entry'; do
        entry_key="$(printf '%s' "$label" | sha256_hex_stdin)"
        mkdir -p "$FAKE_INBOX_ROOT/$entry_key"
        : >"$FAKE_INBOX_ROOT/$entry_key/kind"
    done

    run env -u _QUIET bash -c '
        . "'"$PROJECT_ROOT"'/tmux-notify-jump-lib.sh"
        export XDG_CACHE_HOME="'"$XDG_CACHE_HOME"'"
        export TMUX_NOTIFY_TMUX_SOCKET="'"$TMUX_NOTIFY_TMUX_SOCKET"'"
        tmux_cmd() {
            case "${1:-}" in
                display-message)
                    case "${3:-}" in
                        "#{pid}") printf "4242\n" ;;
                        "#{socket_path}") printf "%s\n" "$TMUX_NOTIFY_TMUX_SOCKET" ;;
                    esac
                    ;;
                show-option)
                    [ "${3:-}" = "@tmux-notify-jump-key" ] && printf "N"
                    ;;
            esac
            return 0
        }
        tmux_notify_tmux_uninit
    '

    [ "$status" -eq 0 ]
    [[ "$output" == *"2 Inbox entries"* ]]
    [ -z "$(find "$FAKE_INBOX_ROOT" -mindepth 1 -type d -print -quit)" ]
}

@test "tmux uninit reports incomplete Inbox cleanup" {
    _QUIET=0
    FAKE_KEY_OPTION=N
    FAKE_INBOX_ROOT="$(tmux_notify_inbox_default_root)"
    entry_key="$(printf '%s' 'failed uninstall entry' | sha256_hex_stdin)"
    failed_entry="$FAKE_INBOX_ROOT/$entry_key"
    mkdir -p "$failed_entry"
    : >"$failed_entry/kind"
    rm() {
        local arg="" last=""
        for arg in "$@"; do last="$arg"; done
        [ "$last" != "$failed_entry" ] || return 1
        command rm "$@"
    }

    run tmux_notify_tmux_uninit
    unset -f rm

    [ "$status" -eq 1 ]
    [[ "$output" == *"Inbox cleanup incomplete"* ]]
    [[ "$output" == *"0 Inbox entries removed"* ]]
    [[ "$output" == *"1 removal failures"* ]]
    [ -d "$failed_entry" ]
}

@test "tmux uninit removes its running server state" {
    status_segment="$(tmux_notify_tmux_status_segment)"
    FAKE_STATUS_RIGHT="left${status_segment} right"
    FAKE_KEY_OPTION=M
    FAKE_BINDING='bind-key -T prefix M run-shell -b "tmux-notify-jump --inbox-next"'
    FAKE_HOOK_COMMAND='if-shell -F 1 { run-shell -b "tmux-notify-jump --inbox-ack-client client" }'
    FAKE_INBOX_ROOT="$(tmux_notify_inbox_default_root)"
    entry_key="$(printf '%s' 'uninstall entry' | sha256_hex_stdin)"
    mkdir -p "$FAKE_INBOX_ROOT/$entry_key"
    : >"$FAKE_INBOX_ROOT/$entry_key/kind"

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

@test "tmux uninit reads the full hook table once" {
    FAKE_KEY_OPTION=M
    FAKE_HOOK_COMMAND='if-shell -F 1 { run-shell -b "tmux-notify-jump --inbox-ack-client client" }'

    tmux_notify_tmux_uninit

    run rg -c '^show-hooks -g$' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run rg '^show-hooks -g .+' "$TMUX_LOG"
    [ "$status" -eq 1 ]
    run rg -c '^set-hook -gu .+\[900\]$' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "tmux uninit names the server it changed" {
    run env -u _QUIET bash -c '
        . "'"$PROJECT_ROOT"'/tmux-notify-jump-lib.sh"
        tmux_cmd() {
            case "${1:-}" in
                display-message)
                    case "${3:-}" in
                        "#{pid}") printf "4242\n" ;;
                        "#{socket_path}") printf "/tmp/example.sock\n" ;;
                    esac
                    ;;
                show-option)
                    [ "${3:-}" = "@tmux-notify-jump-key" ] && printf "N\n"
                    ;;
            esac
            return 0
        }
        tmux_notify_tmux_uninit
    '

    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed tmux Inbox state from /tmp/example.sock"* ]]
    [[ "$output" == *"server pid 4242"* ]]
}

@test "tmux uninit leaves a server carrying none of its marks untouched" {
    root="$(tmux_notify_inbox_default_root)"
    entry_key="$(printf '%s' 'unrelated server entry' | sha256_hex_stdin)"
    mkdir -p "$root/$entry_key"
    : >"$root/$entry_key/kind"

    tmux_notify_tmux_uninit

    [ -f "$root/$entry_key/kind" ]
    run rg '^(set-hook|unbind-key|set-option|refresh-client)' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}

@test "tmux uninit reports leaving an unmarked server alone" {
    run env -u _QUIET bash -c '
        . "'"$PROJECT_ROOT"'/tmux-notify-jump-lib.sh"
        tmux_cmd() {
            [ "${1:-}" = "display-message" ] || return 0
            case "${3:-}" in
                "#{pid}") printf "4242\n" ;;
                "#{socket_path}") printf "/tmp/example.sock\n" ;;
            esac
        }
        tmux_notify_tmux_uninit
    '

    [ "$status" -eq 0 ]
    [[ "$output" == *"No tmux Inbox state on /tmp/example.sock"* ]]
    [[ "$output" == *"left unchanged"* ]]
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

@test "tmux init retires a jump binding naming an earlier install path" {
    # Reinstalling under a new --bindir leaves the old binding firing the old
    # path, which breaks once that install is removed. Matching on the current
    # path alone would also misreport this tool's own binding as third-party.
    TMUX_NOTIFY_ENTRYPOINT='/opt/new/tmux-notify-jump'
    FAKE_BINDING='bind-key -T prefix N run-shell -b "TMUX_NOTIFY_SENDER_TTY=\"#{client_tty}\" /opt/old/tmux-notify-jump --inbox-next"'
    _QUIET=0

    run tmux_notify_tmux_init

    [ "$status" -eq 0 ]
    [[ "$output" != *"already bound"* ]]
    run rg -F 'unbind-key -T prefix N' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run rg -F "bind-key N run-shell -b 'TMUX_NOTIFY_SENDER_TTY=\"#{client_tty}\" /opt/new/tmux-notify-jump --inbox-next'" "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "tmux init moves its jump binding when the configured key changes" {
    TMUX_NOTIFY_ENTRYPOINT='/opt/tnj/tmux-notify-jump'
    FAKE_KEY_OPTION=A
    FAKE_BINDING='bind-key -T prefix N run-shell -b "TMUX_NOTIFY_SENDER_TTY=\"#{client_tty}\" /opt/tnj/tmux-notify-jump --inbox-next"'

    run tmux_notify_tmux_init

    [ "$status" -eq 0 ]
    run rg -F 'unbind-key -T prefix N' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run rg '^bind-key A ' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "tmux init leaves a hook slot it does not own unchanged" {
    # Index 900 is conventional, not private: warn and keep a command this tool
    # did not install instead of silently replacing it.
    FAKE_HOOK_COMMAND='display-message "user hook"'
    _QUIET=0

    run tmux_notify_tmux_init

    [ "$status" -eq 0 ]
    [[ "$output" == *"after-select-pane[900] is already set"* ]]
    [[ "$output" == *"client-attached[900] is already set"* ]]
    run rg -F 'set-hook -g ' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}

@test "tmux init refreshes hook slots holding its own command" {
    FAKE_HOOK_COMMAND='if-shell -F 1 { run-shell -b "tmux-notify-jump --inbox-ack-pane %1" }'
    _QUIET=0

    run tmux_notify_tmux_init

    [ "$status" -eq 0 ]
    [[ "$output" != *"already set"* ]]
    run rg -c '^set-hook -g .+\[900\] ' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "tmux uninit removes jump bindings the key option no longer names" {
    FAKE_KEY_OPTION=A
    FAKE_BINDING='bind-key -T prefix N run-shell -b "tmux-notify-jump --inbox-next"
bind-key -T prefix A run-shell -b "tmux-notify-jump --inbox-next"'

    tmux_notify_tmux_uninit

    run rg -F 'unbind-key -T prefix N' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run rg -F 'unbind-key -T prefix A' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "tmux uninit recognizes a server marked only by a stale jump binding" {
    FAKE_BINDING='bind-key -T prefix Z run-shell -b "tmux-notify-jump --inbox-next"'

    tmux_notify_tmux_uninit

    run rg -F 'unbind-key -T prefix Z' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "Inbox picker uses one live inventory and prioritizes attention" {
    tmux_notify_inbox_enqueue '%9' complete Codex 'Done'
    FAKE_TARGET_PANE_ID='%10'
    tmux_notify_inbox_enqueue '%10' attention Claude 'Permission'
    FAKE_PANE_ROWS=$'%9|$1|@2|8|1|renamed\n%10|$1|@2|8|2|renamed'
    : >"$TMUX_LOG"

    run tmux_notify_inbox_picker_rows

    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *$'\t%10\tattention\tClaude\trenamed:8.2\t'* ]]
    [[ "${lines[1]}" == *$'\t%9\tcomplete\tCodex\trenamed:8.1\t'* ]]
    [ "$(rg -c '^list-panes -a -F' "$TMUX_LOG")" -eq 1 ]
    run rg 'display-message -p -t' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}

@test "Inbox picker filters kind source live session and recent time" {
    now_ms() { printf 100000; }
    tmux_notify_inbox_enqueue '%9' complete Codex 'Old build'
    old_key="$(printf '%s' '%9|complete' | sha256_hex_stdin)"
    root="$(tmux_notify_inbox_root)"
    printf '50000\n' >"$root/$old_key/last_ms"
    FAKE_TARGET_PANE_ID='%10'
    tmux_notify_inbox_enqueue '%10' attention Claude 'Permission'
    FAKE_PANE_ROWS=$'%9|$1|@2|8|1|renamed\n%10|$1|@2|8|2|renamed'

    run tmux_notify_inbox_picker_rows attention Claude renamed 10
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *$'\t%10\t'* ]]
    run tmux_notify_inbox_picker_rows '' '' '$1' 10
    [ "${#lines[@]}" -eq 1 ]
    run tmux_notify_inbox_picker_rows '' '' work 0
    [ -z "$output" ]
}

@test "Inbox next skips current pane while the picker marks it without changing IDs" {
    FAKE_TARGET_PANE_ID='%1'
    tmux_notify_inbox_enqueue '%1' attention Claude 'Current permission'
    FAKE_TARGET_PANE_ID='%9'
    tmux_notify_inbox_enqueue '%9' complete Codex 'Other done'
    FAKE_PANE_ROWS=$'%1|$1|@2|3|0|work\n%9|$1|@2|3|1|work'

    tmux_notify_inbox_pick --menu --sender-tty /dev/pts/2
    [[ "$(cat "$TEST_TEMP_DIR/picker.args")" == *'work:3.0 [current]'* ]]
    tmux_notify_inbox_next /dev/pts/2
    [ "$TMUX_NOTIFY_INBOX_ATTENTION" -eq 1 ]
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 0 ]
    run rg 'select-pane -t %9' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}

@test "Inbox next leaves notices pending when only the current pane has entries" {
    FAKE_TARGET_PANE_ID='%1'
    tmux_notify_inbox_enqueue '%1' attention Claude 'Permission'
    tmux_notify_inbox_enqueue '%1' complete Claude 'Done'
    : >"$TMUX_LOG"

    tmux_notify_inbox_next /dev/pts/2
    [ "$TMUX_NOTIFY_INBOX_ATTENTION" -eq 1 ]
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 1 ]
    run rg '^switch-client' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}

@test "Inbox metadata and picker filters preserve pipes in session names" {
    FAKE_TARGET_SESSION_NAME='work|qa|'
    tmux_notify_inbox_enqueue '%9' complete Codex 'Done'
    root="$(tmux_notify_inbox_root)"
    id="$(printf '%s' '%9|complete' | sha256_hex_stdin)"
    [ "$(cat "$root/$id/session_name")" = 'work|qa|' ]
    [ "$(cat "$root/$id/window_index")" = 3 ]
    FAKE_PANE_ROWS='%9|$1|@2|8|1|work|qa|'

    run tmux_notify_inbox_picker_rows '' '' 'work|qa|'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\twork|qa|:8.1\t'* ]]
    tmux_notify_inbox_select "$id" /dev/pts/2
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 0 ]
}

@test "Inbox menu truncates long labels before escaping tmux format markers" {
    title="$(printf '%0500d' 0)"
    tmux_notify_inbox_enqueue '%9' complete Codex "$title"
    tmux_notify_inbox_pick --menu --sender-tty /dev/pts/2
    label="$(sed -n '10p' "$TEST_TEMP_DIR/picker.args")"
    [ "${#label}" -le 60 ]
    [[ "$label" == *'...' ]]
}

@test "Inbox picker menu escapes tmux formats and carries config cache socket" {
    tmux_notify_inbox_enqueue '%9' complete Codex '#{pane_id}'
    TMUX_NOTIFY_ENTRYPOINT="$TEST_TEMP_DIR/path with quotes' and spaces/tmux-notify-jump"
    TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/custom env"

    tmux_notify_inbox_pick --menu --sender-tty /dev/pts/2

    args="$(cat "$TEST_TEMP_DIR/picker.args")"
    [[ "$args" == *'##{pane_id}'* ]]
    [[ "$args" == *'--inbox-select'* ]]
    [[ "$args" == *'TMUX_NOTIFY_CONFIG='* ]]
    [[ "$args" == *'XDG_CACHE_HOME='* ]]
    [[ "$args" == *'TMUX_NOTIFY_TMUX_SOCKET='* ]]
    [[ "$args" == *'--sender-tty'* ]]
}

write_picker_fzf_fake() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat >"$TEST_TEMP_DIR/bin/fzf" <<'FAKE'
#!/usr/bin/env bash
[ -z "$FZF_DEFAULT_OPTS$FZF_DEFAULT_OPTS_FILE$FZF_DEFAULT_COMMAND" ] || exit 99
for arg in "$@"; do
    if [ "$arg" = --filter=probe ]; then
        [ "${FZF_PROBE_FAIL:-0}" -eq 0 ] || exit 2
        cat
        exit 0
    fi
done
printf '%s\n' "$@" >"$TEST_TEMP_DIR/fzf.args"
cat >"$TEST_TEMP_DIR/fzf.rows"
[ "${FZF_TEST_EXIT:-0}" -eq 0 ] || exit "$FZF_TEST_EXIT"
head -n 1 "$TEST_TEMP_DIR/fzf.rows"
FAKE
    chmod +x "$TEST_TEMP_DIR/bin/fzf"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

# Execute generated callbacks through the real entrypoint and config loader.
# The external tmux stub rejects every call to the configured, wrong server.
write_picker_callback_tmux_fake() {
    export INBOX_CALLBACK_ROOT="$(tmux_notify_inbox_root)"
    export INBOX_CALLBACK_SOCKET="$TMUX_NOTIFY_TMUX_SOCKET"
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/callback.env"
    printf "TMUX_NOTIFY_TMUX_SOCKET='%s'\n" "$TEST_TEMP_DIR/wrong.sock" >"$TMUX_NOTIFY_CONFIG"
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat >"$TEST_TEMP_DIR/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_TEMP_DIR/callback.calls"
[ "${1:-}" = -S ] && [ "${2:-}" = "$INBOX_CALLBACK_SOCKET" ] || exit 99
shift 2
case "$1" in
    show-option)
        [ "${3:-}" != @tmux-notify-jump-inbox-root ] || printf '%s\n' "$INBOX_CALLBACK_ROOT"
        ;;
    display-message)
        case "${3:-}" in
            '#{pid}') printf '4242\n' ;;
            '#{socket_path}') printf '%s\n' "$INBOX_CALLBACK_SOCKET" ;;
            '#{version}') printf '3.7\n' ;;
        esac
        ;;
    list-clients) printf '0|10|/dev/pts/2|/dev/pts/2|222|$1|%%9|work\n' ;;
    list-panes)
        case "${4:-}" in
            '#{session_id}|#{window_id}|#{pane_id}') printf '$1|@2|%%9\n' ;;
            *) printf '%%9|$1|@2|3|0|work\n' ;;
        esac
        ;;
    capture-pane) printf 'preview from requested server\n' ;;
esac
exit 0
FAKE
    chmod +x "$TEST_TEMP_DIR/bin/tmux"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    TMUX_NOTIFY_TMUX_SOCKET="$TEST_TEMP_DIR/wrong.sock"
}

@test "Inbox menu callback keeps the CLI socket after configuration reload" {
    tmux_notify_inbox_enqueue '%9' attention Claude 'Permission'
    tmux_notify_inbox_enqueue '%9' complete Codex 'Done'
    write_picker_callback_tmux_fake

    tmux_notify_inbox_pick --menu --sender-tty /dev/pts/2 --tmux-socket "$INBOX_CALLBACK_SOCKET"
    callback="$(sed -n '12p' "$TEST_TEMP_DIR/picker.args")"
    run /bin/sh -c "exec /bin/sh -c ${callback#run-shell -b }"
    [ "$status" -eq 0 ]
    [ ! -e "$INBOX_CALLBACK_ROOT/$(printf '%s' '%9|attention' | sha256_hex_stdin)" ]
    [ ! -e "$INBOX_CALLBACK_ROOT/$(printf '%s' '%9|complete' | sha256_hex_stdin)" ]
    run rg -F 'select-pane -t %9' "$TEST_TEMP_DIR/callback.calls"
    [ "$status" -eq 0 ]
}

@test "Inbox popup callback keeps the CLI socket after configuration reload" {
    write_picker_fzf_fake
    tmux_notify_inbox_enqueue '%9' complete Codex 'Done'
    write_picker_callback_tmux_fake

    tmux_notify_inbox_pick --sender-tty /dev/pts/2 --tmux-socket "$INBOX_CALLBACK_SOCKET"
    callback="$(tail -n 1 "$TEST_TEMP_DIR/picker.args")"
    run /bin/sh -c "$callback"
    [ "$status" -eq 0 ]
    [ ! -e "$INBOX_CALLBACK_ROOT/$(printf '%s' '%9|complete' | sha256_hex_stdin)" ]
    run rg -F 'select-pane -t %9' "$TEST_TEMP_DIR/callback.calls"
    [ "$status" -eq 0 ]
}

@test "Inbox preview callback keeps the CLI socket after configuration reload" {
    write_picker_fzf_fake
    export FZF_TEST_EXIT=130
    tmux_notify_inbox_enqueue '%9' complete Codex 'Done'
    write_picker_callback_tmux_fake

    tmux_notify_inbox_pick --inline --sender-tty /dev/pts/2 --tmux-socket "$INBOX_CALLBACK_SOCKET"
    preview="$(rg '^--preview=' "$TEST_TEMP_DIR/fzf.args")"
    preview="${preview#--preview=}"
    run /bin/sh -c "${preview//\{2\}/\'%9\'}"
    [ "$status" -eq 0 ]
    [ "$output" = 'preview from requested server' ]
    [ -e "$INBOX_CALLBACK_ROOT/$(printf '%s' '%9|complete' | sha256_hex_stdin)" ]
}

@test "Inbox fzf selection shares validated jump and isolated fzf options" {
    write_picker_fzf_fake
    tmux_notify_inbox_enqueue '%9' complete Codex 'Done'
    export FZF_DEFAULT_OPTS='--bind enter:abort'
    export FZF_DEFAULT_OPTS_FILE=/missing/options
    export FZF_DEFAULT_COMMAND='arbitrary defaults'

    tmux_notify_inbox_pick --inline --query Codex --sender-tty /dev/pts/2

    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 0 ]
    run rg 'select-pane -t %9' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    args="$(cat "$TEST_TEMP_DIR/fzf.args")"
    [[ "$args" == *'--query=Codex'* ]]
    [[ "$args" == *'--inbox-preview'* ]]
}

@test "Inbox fzf cancellation preserves entries" {
    write_picker_fzf_fake
    tmux_notify_inbox_enqueue '%9' attention Claude 'Permission'
    export FZF_TEST_EXIT=130

    tmux_notify_inbox_pick --inline --sender-tty /dev/pts/2

    [ "$TMUX_NOTIFY_INBOX_ATTENTION" -eq 1 ]
    run rg '^switch-client' "$TMUX_LOG"
    [ "$status" -eq 1 ]
}

@test "Inbox picker uses fzf popup only on supported tmux versions" {
    write_picker_fzf_fake
    tmux_notify_inbox_enqueue '%9' complete Codex 'Done'
    tmux_notify_inbox_pick --sender-tty /dev/pts/2
    [ "$(head -n 1 "$TEST_TEMP_DIR/picker.args")" = display-popup ]
    [[ "$(cat "$TEST_TEMP_DIR/picker.args")" == *'--inline'* ]]

    FAKE_TMUX_VERSION='tmux 3.1c'
    tmux_notify_inbox_pick --sender-tty /dev/pts/2
    [ "$(head -n 1 "$TEST_TEMP_DIR/picker.args")" = display-menu ]

    FAKE_TMUX_VERSION='tmux 2.9a'
    run tmux_notify_inbox_pick --menu --sender-tty /dev/pts/2
    [ "$status" -eq 0 ]
    [[ "$output" == *'%9'* ]]
}

@test "Inbox picker falls back to menu when fzf lacks required options" {
    write_picker_fzf_fake
    export FZF_PROBE_FAIL=1
    tmux_notify_inbox_enqueue '%9' complete Codex 'Done'
    tmux_notify_inbox_pick --sender-tty /dev/pts/2
    [ "$(head -n 1 "$TEST_TEMP_DIR/picker.args")" = display-menu ]
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 1 ]
}

@test "Inbox picker menu paginates beyond its shortcut keys" {
    root="$(tmux_notify_inbox_root)"
    for n in {1..36}; do
        mkdir -p "$root/$n"
        printf 'complete\n' >"$root/$n/kind"
        printf '%%9\n' >"$root/$n/pane_id"
        printf 'Codex\n' >"$root/$n/source"
        printf '%s\n' "$n" >"$root/$n/first_ms"
    done
    tmux_notify_inbox_pick --menu --sender-tty /dev/pts/2
    args="$(cat "$TEST_TEMP_DIR/picker.args")"
    [[ "$args" == *'Next page'* ]]
    [[ "$args" != *'Previous page'* ]]

    tmux_notify_inbox_pick --menu --page 1 --sender-tty /dev/pts/2
    args="$(cat "$TEST_TEMP_DIR/picker.args")"
    [[ "$args" == *'Previous page'* ]]
    [[ "$args" != *'Next page'* ]]
    [[ "$args" == *'--inbox-select'* ]]
}

@test "Inbox selection follows a moved pane and does not consume on a detached caller" {
    tmux_notify_inbox_enqueue '%9' complete Codex 'Done'
    id="$(printf '%s' '%9|complete' | sha256_hex_stdin)"
    FAKE_TARGET_SESSION_ID='$8'
    FAKE_TARGET_WINDOW_ID='@20'
    run tmux_notify_inbox_select "$id" /dev/pts/gone
    [ "$status" -eq 1 ]
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 1 ]

    tmux_notify_inbox_select "$id" /dev/pts/2
    run rg -F 'switch-client -c /dev/pts/2 -t $8 ; select-window -t $8:@20' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    [ "$TMUX_NOTIFY_INBOX_COMPLETE" -eq 0 ]
}

@test "Inbox preview validates pane IDs and captures bounded history" {
    run tmux_notify_inbox_preview '%9'
    [ "$status" -eq 0 ]
    [ "$output" = 'recent pane output' ]
    run rg -F 'capture-pane -p -t %9 -S -80' "$TMUX_LOG"
    [ "$status" -eq 0 ]
    run tmux_notify_inbox_preview 'work:0.0; kill-server'
    [ "$status" -eq 1 ]
    run tmux_notify_inbox_select '../../foreign' /dev/pts/2
    [ "$status" -eq 1 ]
}

@test "Inbox callbacks quote literal shell metacharacters" {
    value="literal ' quotes \$(touch $TEST_TEMP_DIR/should-not-exist) \\ backslash"
    command="$(tmux_notify_shell_command printf '%s' "$value")"
    run /bin/sh -c "$command"
    [ "$status" -eq 0 ]
    [ "$output" = "$value" ]
    [ ! -e "$TEST_TEMP_DIR/should-not-exist" ]
}
