#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/config/env"
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"
    export TMUX_NOTIFY_TMUX_SOCKET="$TEST_TEMP_DIR/tmux.sock"
    unset TMUX TMUX_PANE TMUX_NOTIFY_TMUX_STATUS
    mkdir -p "$TEST_TEMP_DIR/bin" "${TMUX_NOTIFY_CONFIG%/*}"
    printf '# user configuration\n' >"$TMUX_NOTIFY_CONFIG"
    FAKE_ROOT="$TEST_TEMP_DIR/cache/tmux-notify-jump/inbox/4242"
    FAKE_VERSION='3.7c'
    FAKE_RUNNING=1
    FAKE_STATUS="$(tmux_notify_tmux_status_segment)"
    FAKE_HOOKS=1
    FAKE_BINDING='bind-key -T prefix N run-shell -b "tmux-notify-jump --inbox-next"'
    FAKE_OS=Linux
    for tool in tmux fzf jq ps notify-send xdotool; do
        printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TEMP_DIR/bin/$tool"
    done
    chmod +x "$TEST_TEMP_DIR/bin/"*
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
    teardown_temp_dir
}

uname() { printf '%s\n' "$FAKE_OS"; }

tmux_cmd() {
    printf '%s\n' "$*" >>"$TEST_TEMP_DIR/tmux.calls"
    case "$1" in
        -V) printf 'tmux %s\n' "$FAKE_VERSION" ;;
        display-message)
            [ "$FAKE_RUNNING" -eq 1 ] || return 1
            case "$3" in
                '#{pid}') printf '4242\n' ;;
                '#{socket_path}') printf '%s\n' "$TMUX_NOTIFY_TMUX_SOCKET" ;;
                '#{version}') printf '%s\n' "$FAKE_VERSION" ;;
            esac
            ;;
        show-option)
            case "$3" in
                @tmux-notify-jump-inbox-root) printf '%s' "$FAKE_ROOT" ;;
                status-right) printf '%s' "$FAKE_STATUS" ;;
            esac
            ;;
        show-hooks)
            [ "$FAKE_HOOKS" -eq 1 ] || return 0
            for hook in client-attached client-session-changed after-select-pane after-select-window client-focus-in; do
                printf '%s[900] run-shell "tmux-notify-jump --inbox-ack-pane %%9"\n' "$hook"
            done
            ;;
        list-keys) printf '%s\n' "$FAKE_BINDING" ;;
        *) printf 'Unexpected mutation: %s\n' "$*" >&2; return 99 ;;
    esac
}

@test "doctor reports initialized integration without changing tmux or cache" {
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'popup and menu supported'* ]]
    [[ "$output" == *'not created yet'* ]]
    [[ "$output" == *'installed in global status-right'* ]]
    [[ "$output" == *'prefix+N jumps to next item'* ]]
    [ "$(printf '%s\n' "$output" | rg -c 'acknowledgement installed')" -eq 5 ]
    [ ! -e "$FAKE_ROOT" ]
    [ "$(cat "$TMUX_NOTIFY_CONFIG")" = '# user configuration' ]
    run rg '^(set-|refresh-|bind-|mkdir|chmod)' "$TEST_TEMP_DIR/tmux.calls"
    [ "$status" -eq 1 ]
}

@test "doctor warns about missing opt-in integration and old tmux" {
    FAKE_VERSION='2.9a'
    FAKE_ROOT=''
    FAKE_STATUS='user status'
    FAKE_HOOKS=0
    FAKE_BINDING='bind-key -T prefix N display-message user-command'
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'not initialized'* ]]
    [[ "$output" == *'menus and acknowledgement hooks need tmux 3.0'* ]]
    [[ "$output" == *'missing or customized'* ]]
    [[ "$output" == *'prefix+N belongs to another command'* ]]
    [ "$(printf '%s\n' "$output" | rg -c 'acknowledgement missing')" -eq 5 ]
}

@test "doctor reports unsafe permissions without repairing them" {
    mkdir -p "$FAKE_ROOT"
    chmod 755 "$FAKE_ROOT"
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'FAIL Inbox permissions'* ]]
    [ "$(stat -c '%a' "$FAKE_ROOT" 2>/dev/null || stat -f '%Lp' "$FAKE_ROOT")" = 755 ]

    chmod 700 "$FAKE_ROOT"
    mkdir -m 700 "$FAKE_ROOT/1"
    printf 'attention\n' >"$FAKE_ROOT/1/kind"
    chmod 644 "$FAKE_ROOT/1/kind"
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'unsafe entry ownership, permissions or symlinks'* ]]
    chmod 600 "$FAKE_ROOT/1/kind"
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'directories 700, files 600'* ]]
}

@test "doctor rejects invalid pinned roots and entry symlinks" {
    FAKE_ROOT="$TEST_TEMP_DIR/foreign"
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid; using default path'* ]]
    [ ! -e "$FAKE_ROOT" ]
    FAKE_ROOT="$TEST_TEMP_DIR/cache/tmux-notify-jump/inbox/4242"
    mkdir -p "$FAKE_ROOT"
    chmod 700 "$FAKE_ROOT"
    ln -s "$TMUX_NOTIFY_CONFIG" "$FAKE_ROOT/1"
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [ -L "$FAKE_ROOT/1" ]
}

@test "doctor reports a missing server even without TMUX in the environment" {
    FAKE_RUNNING=0
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'tmux server'*'not reachable'* ]]
    [[ "$output" != *'unbound variable'* ]]
}

@test "doctor supports disabled status and macOS dependencies without requiring them" {
    TMUX_NOTIFY_TMUX_STATUS=0
    FAKE_OS=Darwin
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'disabled by TMUX_NOTIFY_TMUX_STATUS'* ]]
    [[ "$output" == *'terminal-notifier'* ]]
    [[ "$output" == *'osascript'* ]]
    [[ "$output" != *'X11 display'* ]]
}

@test "doctor sanitizes terminal controls in diagnostic values" {
    TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/absent"$'\e[31m\nconfig'
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\e'* ]]
    [[ "$output" == *'absent [31m config'* ]]
}
