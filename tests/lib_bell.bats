#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    BELL=1
    BELL_LOG="$TEST_TEMP_DIR/bells"
    : >"$BELL_LOG"
    FAKE_ROWS=$'0|20|remote|/dev/pts/1|101|$1|%9|work\n0|10|local|/dev/pts/2|102|$1|%2|work'
    FAKE_INFO='$1|@1|%9|work|0'
    TMUX_NOTIFY_REMOTE_MODE=tmux
}

teardown() {
    teardown_temp_dir
}

tmux_cmd() {
    case "$1" in
        list-clients) printf '%s\n' "$FAKE_ROWS" ;;
        display-message)
            if [ "${2:-}" = -p ]; then printf '%s\n' "$FAKE_INFO"; fi
            ;;
    esac
}

tmux_client_pid_ssh_state() {
    if [ "$1" = 101 ]; then echo remote; else echo local; fi
}

tmux_notify_inbox_ack_pane() { :; }
tmux_notify_inbox_enqueue() { :; }

capture_bells() {
    tmux_notify_write_bell() { printf '%s\n' "$1" >>"$BELL_LOG"; }
}

@test "bell reaches all target session terminals in every routing mode" {
    capture_bells
    FAKE_ROWS+=$'\n0|30|other|/dev/pts/3|103|$2|%3|other\n0|20|duplicate|/dev/pts/1|101|$1|%9|work'
    for TMUX_NOTIFY_REMOTE_MODE in tmux desktop both suppress; do
        : >"$BELL_LOG"
        tmux_notify_route_notification %9 Done Body complete Codex
        [ "$(cat "$BELL_LOG")" = $'/dev/pts/1\n/dev/pts/2' ]
    done
}

@test "bell excludes control clients and preserves legacy terminal discovery" {
    capture_bells
    FAKE_ROWS=$'1|90|control|/dev/pts/9|109|$1|%9|work\n|20||/dev/pts/1|101|$1|%9|work\n|30|||103|$1|%9|work\nunknown|40|unknown|/dev/pts/4|104|$1|%9|work'
    tmux_notify_route_notification %9 Done Body
    [ "$(cat "$BELL_LOG")" = /dev/pts/1 ]
}

@test "bell skips disabled delivery, missing clients and unresolved targets" {
    capture_bells
    BELL=0
    tmux_notify_route_notification %9 Done Body
    BELL=1
    FAKE_INFO=''
    tmux_notify_route_notification %9 Done Body
    FAKE_INFO='$1|@1|%9|work|0'
    FAKE_ROWS=''
    tmux_notify_route_notification %9 Done Body
    [ ! -s "$BELL_LOG" ]
}

@test "failed bell delivery continues to other clients and normal routing" {
    tmux_notify_write_bell() {
        [ "$1" != /dev/pts/1 ] || return 1
        printf '%s\n' "$1" >>"$BELL_LOG"
    }
    TMUX_NOTIFY_REMOTE_MODE=both
    tmux_notify_route_notification %9 Done Body
    [ "$TMUX_NOTIFY_ROUTE_DESKTOP" = 1 ]
    [ "$(cat "$BELL_LOG")" = /dev/pts/2 ]
}

@test "bell writer rejects regular files, missing devices and non-terminal devices" {
    printf 'untouched' >"$TEST_TEMP_DIR/file"
    for device in "$TEST_TEMP_DIR/file" /dev/tmux-notify-missing-device /dev/null; do
        run tmux_notify_write_bell "$device"
        [ "$status" -ne 0 ]
    done
    [ "$(cat "$TEST_TEMP_DIR/file")" = untouched ]
    [ ! -e /dev/tmux-notify-missing-device ]
}

@test "bell flags override configuration and the last flag wins" {
    BELL=yes
    parse_common_opt --no-bell
    [ "$BELL" = 0 ]
    [ "$_PARSE_CONSUMED" = 1 ]
    parse_common_opt --bell
    [ "$BELL" = 1 ]
    parse_common_opt --no-bell
    [ "$BELL" = 0 ]
}

@test "agent bell override inherits when empty and follows existing boolean rules" {
    unset CODEX_NOTIFY_BELL
    [ -z "$(tmux_notify_agent_bell_arg CODEX)" ]
    CODEX_NOTIFY_BELL=''
    [ -z "$(tmux_notify_agent_bell_arg CODEX)" ]
    CODEX_NOTIFY_BELL=YES
    [ "$(tmux_notify_agent_bell_arg CODEX)" = --bell ]
    CODEX_NOTIFY_BELL=0
    [ "$(tmux_notify_agent_bell_arg CODEX)" = --no-bell ]
}
