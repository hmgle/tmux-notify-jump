#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    TERMINAL_METHOD=osc777
    FAKE_ROWS=$'0|20|remote|/dev/pts/1|101|$1|%9|work\n0|10|local|/dev/pts/2|102|$1|%2|work'
    OSC_LOG="$TEST_TEMP_DIR/osc"
}

teardown() { teardown_temp_dir; }

tmux_cmd() { printf '%s\n' "$FAKE_ROWS"; }

@test "OSC 777 reaches distinct ordinary target terminals including legacy clients" {
    FAKE_ROWS+=$'\n0|30|other|/dev/pts/3|103|$2|%3|other\n0|20|duplicate|/dev/pts/1|101|$1|%9|work\n1|30|control|/dev/pts/9|109|$1|%9|work\n|40||/dev/pts/4|104|$1|%4|work'
    tmux_notify_write_osc777() { printf '%s|%s|%s\n' "$@" >>"$OSC_LOG"; }
    tmux_notify_terminal_notification '$1' "$(tmux_terminal_client_rows)" 'Done; now' $'Body\e\a'
    [ "$(cat "$OSC_LOG")" = $'/dev/pts/1|Done； now|Body  \n/dev/pts/2|Done； now|Body  \n/dev/pts/4|Done； now|Body  ' ]
}

@test "OSC 777 is opt-in and tolerates missing clients and failed writes" {
    tmux_notify_write_osc777() { printf '%s\n' "$1" >>"$OSC_LOG"; return 1; }
    TERMINAL_METHOD=none
    tmux_notify_terminal_notification '$1' "$(tmux_terminal_client_rows)" Done Body
    TERMINAL_METHOD=osc777
    tmux_notify_terminal_notification '' "$FAKE_ROWS" Done Body
    tmux_notify_terminal_notification '$1' '' Done Body
    [ ! -e "$OSC_LOG" ]
    tmux_notify_terminal_notification '$1' "$(tmux_terminal_client_rows)" Done Body
    [ "$(cat "$OSC_LOG")" = $'/dev/pts/1\n/dev/pts/2' ]
}

@test "OSC fields remove controls and invalid UTF-8 without damaging Unicode" {
    run tmux_notify_osc_field $'你好;ok\e\a\n\177\302\235\302\234\233\377'
    [ "$status" -eq 0 ]
    [ "$output" = '你好；ok        ' ]
    run env LC_ALL=C bash -c '. "$1"; tmux_notify_osc_field "$2"' _ \
        "$PROJECT_ROOT/tmux-notify-jump-lib.sh" '通知🚀;完成'
    [ "$status" -eq 0 ]
    [ "$output" = '通知🚀；完成' ]
}

@test "OSC fields fit a 255-byte buffer at UTF-8 boundaries" {
    local text='' i
    for ((i=0; i<100; i++)); do text+='🚀'; done
    result="$(tmux_notify_osc_field "$text")"
    [ "$(printf '%s' "$result" | wc -c)" -eq 255 ]
    [[ "$result" == *'…' ]]
    [ "${#result}" -eq 64 ]
}

@test "OSC writer rejects nonterminal files without modifying them" {
    printf original >"$TEST_TEMP_DIR/file"
    run tmux_notify_write_osc777 "$TEST_TEMP_DIR/file" Done Body
    [ "$status" -ne 0 ]
    [ "$(cat "$TEST_TEMP_DIR/file")" = original ]
    run tmux_notify_write_osc777 /dev/null Done Body
    [ "$status" -ne 0 ]
}
