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
    [ "${TMUX_NOTIFY_CONFIG+x}" = x ]
    [ -z "$TMUX_NOTIFY_CONFIG" ]
}

write_config_callback() {
    TMUX_NOTIFY_ENTRYPOINT="$TEST_TEMP_DIR/callback"
    cat >"$TMUX_NOTIFY_ENTRYPOINT" <<'CALLBACK'
#!/usr/bin/env bash
. "$1/tmux-notify-jump-lib.sh"
unset TNJ_TEST_CONFIG_VALUE
load_user_config
printf '%s\n%s\n' "$TMUX_NOTIFY_CONFIG" "${TNJ_TEST_CONFIG_VALUE:-unloaded}"
CALLBACK
    chmod +x "$TMUX_NOTIFY_ENTRYPOINT"
}

@test "relative config stays absolute after loading and callback directory changes" {
    mkdir -p "$TEST_TEMP_DIR/caller" "$TEST_TEMP_DIR/server" "$TEST_TEMP_DIR/pane"
    printf 'TNJ_TEST_CONFIG_VALUE=caller\n' >"$TEST_TEMP_DIR/caller/env file"
    printf 'TNJ_TEST_CONFIG_VALUE=server\n' >"$TEST_TEMP_DIR/server/env file"
    printf 'TNJ_TEST_CONFIG_VALUE=pane\n' >"$TEST_TEMP_DIR/pane/env file"
    cd "$TEST_TEMP_DIR/caller"
    export TMUX_NOTIFY_CONFIG='env file'
    load_user_config
    [ "$TMUX_NOTIFY_CONFIG" = "$TEST_TEMP_DIR/caller/env file" ]
    write_config_callback
    cd "$TEST_TEMP_DIR/server"
    command="$(tmux_notify_inbox_command "$PROJECT_ROOT")"
    for directory in "$TEST_TEMP_DIR/server" "$TEST_TEMP_DIR/pane"; do
        cd "$directory"
        run /bin/sh -c "$command"
        [ "$status" -eq 0 ]
        [ "${lines[0]}" = "$TEST_TEMP_DIR/caller/env file" ]
        [ "${lines[1]}" = caller ]
    done
}

@test "callbacks absolutize relative config even when invoked without loading it" {
    mkdir -p "$TEST_TEMP_DIR/caller" "$TEST_TEMP_DIR/pane"
    printf 'TNJ_TEST_CONFIG_VALUE=caller\n' >"$TEST_TEMP_DIR/caller/env"
    cd "$TEST_TEMP_DIR/caller"
    export TMUX_NOTIFY_CONFIG=./env
    write_config_callback
    command="$(tmux_notify_inbox_command "$PROJECT_ROOT")"
    cd "$TEST_TEMP_DIR/pane"
    run /bin/sh -c "$command"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$TEST_TEMP_DIR/caller/./env" ]
    [ "${lines[1]}" = caller ]
}

@test "a callback generated without HOME cannot adopt the server default config" {
    mkdir -p "$HOME/.config/tmux-notify-jump"
    printf 'TNJ_TEST_CONFIG_VALUE=server\n' >"$HOME/.config/tmux-notify-jump/env"
    server_home="$HOME"
    unset HOME TMUX_NOTIFY_CONFIG
    write_config_callback
    command="$(tmux_notify_inbox_command "$PROJECT_ROOT")"
    export HOME="$server_home"
    run /bin/sh -c "$command"
    [ "$status" -eq 0 ]
    [ "$output" = $'\nunloaded' ]
}

@test "explicit empty config disables HOME defaults" {
    mkdir -p "$HOME/.config/tmux-notify-jump"
    printf 'TNJ_TEST_CONFIG_VALUE=unexpected\n' >"$HOME/.config/tmux-notify-jump/env"
    export TMUX_NOTIFY_CONFIG=''
    load_user_config
    [ -z "${TNJ_TEST_CONFIG_VALUE:-}" ]
    run tmux_notify_config_path
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "relative config callback preserves a trailing newline in the filename" {
    cd "$TEST_TEMP_DIR"
    export TMUX_NOTIFY_CONFIG=$'env\n'
    printf 'TNJ_TEST_CONFIG_VALUE=newline\n' >"$TMUX_NOTIFY_CONFIG"
    load_user_config
    [ "$TMUX_NOTIFY_CONFIG" = "$TEST_TEMP_DIR/"$'env\n' ]
    write_config_callback
    command="$(tmux_notify_inbox_command "$PROJECT_ROOT")"
    cd /
    run /bin/sh -c "$command"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'env\n\nnewline' ]]
}
