#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    unset TMUX TMUX_PANE TMUX_NOTIFY_TARGET_ANCESTRY
    PANE_ROWS=$'%1|100|0\n%2|200|0'
    PROCESS_ROWS=$'300 250\n250 200\n200 1\n100 1'
    INVENTORY_FAIL=0
    PS_FAIL=0
}

teardown() {
    teardown_temp_dir
}

tmux_cmd() {
    printf '%s\n' "$*" >>"$TEST_TEMP_DIR/tmux.calls"
    case "$1" in
        list-panes)
            [ "$INVENTORY_FAIL" -eq 0 ] || return 1
            printf '%s\n' "$PANE_ROWS"
            ;;
        display-message) printf '%%1\n' ;;
        list-clients) printf '0|30|ordinary|/dev/pts/1|100|$1|%%1|work\n' ;;
    esac
}

ps() {
    printf '%s\n' "$*" >>"$TEST_TEMP_DIR/ps.calls"
    [ "$PS_FAIL" -eq 0 ] || return 1
    printf '%s\n' "$PROCESS_ROWS"
}

@test "target resolution prefers an explicit pane without querying inventories" {
    export TMUX_PANE='%9'
    run resolve_tmux_notify_target 0 300
    [ "$status" -eq 0 ]
    [ "$output" = '%9' ]
    [ ! -f "$TEST_TEMP_DIR/tmux.calls" ]
    [ ! -f "$TEST_TEMP_DIR/ps.calls" ]
}

@test "target resolution uses process ancestry before the ambient TMUX pane" {
    export TMUX='/tmp/fake.sock,1234,0'
    run resolve_tmux_notify_target 0 300
    [ "$status" -eq 0 ]
    [ "$output" = '%2' ]
    [ "$(wc -l <"$TEST_TEMP_DIR/tmux.calls")" -eq 1 ]
    [ "$(wc -l <"$TEST_TEMP_DIR/ps.calls")" -eq 1 ]
    [ "$(cat "$TEST_TEMP_DIR/tmux.calls")" = 'list-panes -a -F #{pane_id}|#{pane_pid}|#{pane_dead}' ]
}

@test "target resolution chooses the nearest root in nested tmux processes" {
    PANE_ROWS=$'%1|100|0\n%2|250|0'
    PROCESS_ROWS=$'300 250\n250 100\n100 1'
    run resolve_tmux_notify_target 0 300
    [ "$status" -eq 0 ]
    [ "$output" = '%2' ]
}

@test "target resolution refuses unrelated and dead panes by default" {
    export TMUX='/tmp/fake.sock,1234,0'
    PANE_ROWS=$'%1|100|0\n%2|200|1'
    run resolve_tmux_notify_target 0 300
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run rg 'display-message|list-clients' "$TEST_TEMP_DIR/tmux.calls"
    [ "$status" -eq 1 ]
}

@test "target resolution fails open when inventories fail or ancestry cycles" {
    INVENTORY_FAIL=1
    run resolve_tmux_notify_target 0 300
    [ "$status" -eq 1 ]
    INVENTORY_FAIL=0
    PS_FAIL=1
    run resolve_tmux_notify_target 0 300
    [ "$status" -eq 1 ]
    PS_FAIL=0
    PROCESS_ROWS=$'300 250\n250 300'
    run resolve_tmux_notify_target 0 300
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "target resolution retains ambient and ordinary-client fallback when opted in" {
    PROCESS_ROWS='300 1'
    export TMUX='/tmp/fake.sock,1234,0'
    run resolve_tmux_notify_target 1 300
    [ "$status" -eq 0 ]
    [ "$output" = '%1' ]
    unset TMUX
    run resolve_tmux_notify_target 1 300
    [ "$status" -eq 0 ]
    [ "$output" = '%1' ]
}

@test "target resolution can disable ancestry for shared daemons" {
    export TMUX_NOTIFY_TARGET_ANCESTRY=0
    run resolve_tmux_notify_target 0 300
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ ! -f "$TEST_TEMP_DIR/tmux.calls" ]
    [ ! -f "$TEST_TEMP_DIR/ps.calls" ]

    export TMUX_PANE='%9'
    run resolve_tmux_notify_target 0 300
    [ "$status" -eq 0 ]
    [ "$output" = '%9' ]
}

@test "disabled ancestry still permits explicitly enabled ambient fallback" {
    export TMUX_NOTIFY_TARGET_ANCESTRY=false
    export TMUX='/tmp/fake.sock,1234,0'
    run resolve_tmux_notify_target 1 300
    [ "$status" -eq 0 ]
    [ "$output" = '%1' ]
    [ ! -f "$TEST_TEMP_DIR/ps.calls" ]
    run rg 'list-panes' "$TEST_TEMP_DIR/tmux.calls"
    [ "$status" -eq 1 ]
}
