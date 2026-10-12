#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    export HOME="$TEST_TEMP_DIR/home"
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"
    unset TMUX_NOTIFY_CONFIG
}

teardown() {
    teardown_temp_dir
}

@test "configuration loader and Inbox callback use the same default path" {
    cfg="$(tmux_notify_config_path)"
    [ "$cfg" = "$HOME/.config/tmux-notify-jump/env" ]
    mkdir -p "${cfg%/*}"
    printf 'TNJ_TEST_CONFIG_VALUE=loaded\n' >"$cfg"
    load_user_config
    [ "$TNJ_TEST_CONFIG_VALUE" = loaded ]

    TMUX_NOTIFY_ENTRYPOINT=/usr/bin/env
    command="$(tmux_notify_inbox_command)"
    run /bin/sh -c "$command"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TMUX_NOTIFY_CONFIG=$cfg"* ]]
}

@test "explicit configuration works without HOME and callbacks preserve its path" {
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/custom ' config"
    printf 'TNJ_TEST_CONFIG_VALUE=explicit\n' >"$TMUX_NOTIFY_CONFIG"
    unset HOME
    load_user_config
    [ "$TNJ_TEST_CONFIG_VALUE" = explicit ]

    TMUX_NOTIFY_ENTRYPOINT=/usr/bin/env
    command="$(tmux_notify_inbox_command)"
    run /bin/sh -c "$command"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TMUX_NOTIFY_CONFIG=$TMUX_NOTIFY_CONFIG"* ]]
}

@test "configuration without HOME or an explicit path is absent" {
    unset HOME
    run tmux_notify_config_path
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    load_user_config
}
