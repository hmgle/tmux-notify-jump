#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"
    export TMUX_NOTIFY_TMUX_SOCKET="$TEST_TEMP_DIR/tmux.sock"
    export TMUX_NOTIFY_INBOX_TTL_MS=604800000
    export TMUX_NOTIFY_INBOX_MAX=100
    TMUX_LOG="$TEST_TEMP_DIR/tmux.log"
    export TMUX_LOG
}

teardown() {
    teardown_temp_dir
}

tmux_cmd() {
    printf '%s\n' "$*" >>"$TMUX_LOG"
    case "$1" in
        display-message)
            if [ "${2:-}" = "-p" ] && [ "${3:-}" = '#{pid}' ]; then
                printf '4242\n'
            elif [ "${2:-}" = "-p" ] && [ "${3:-}" = "-t" ]; then
                printf '$1|@2|%%9|work|3\n'
            fi
            ;;
        list-clients)
            printf '0|10|/dev/pts/2|/dev/pts/2|222|$1|%%1|work\n'
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

    tmux_cmd() {
        printf '%s\n' "$*" >>"$TMUX_LOG"
        case "$1" in
            display-message)
                if [ "${2:-}" = "-p" ] && [ "${3:-}" = '#{pid}' ]; then
                    printf '4242\n'
                elif [ "${2:-}" = "-p" ] && [ "${3:-}" = "-t" ]; then
                    printf '$1|@3|%%10|work|4\n'
                fi
                ;;
            list-clients)
                printf '0|10|/dev/pts/2|/dev/pts/2|222|$1|%%1|work\n'
                ;;
        esac
    }
    tmux_notify_inbox_enqueue "%10" attention Claude "Permission" "Body"

    tmux_notify_inbox_next "/dev/pts/2"

    root="$(tmux_notify_inbox_root)"
    kinds="$(for entry in "$root"/*; do [ -f "$entry/kind" ] && cat "$entry/kind"; done)"
    [ "$kinds" = "complete" ]
    run rg 'select-pane -t %10' "$TMUX_LOG"
    [ "$status" -eq 0 ]
}
