#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"
}

teardown() {
    teardown_temp_dir
}

write_tmux_inventory_fake() {
    cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
cmd="${1:-}"
shift || true

case "$cmd" in
    list-clients)
        [ "${1:-}" = "-F" ] || exit 1
        [ "${2:-}" = '#{client_control_mode}|#{client_activity}|#{client_name}|#{client_tty}|#{client_pid}|#{session_id}|#{pane_id}|#{session_name}' ] || exit 1
        printf '1|30|control-pty|/dev/pts/9|900|$2|%%9|target\n'
        if [ -f "$TEST_TEMP_DIR/switched" ]; then
            printf '0|20|/dev/pts/1|/dev/pts/1|100|$2|%%9|target\n'
        else
            printf '0|20|/dev/pts/1|/dev/pts/1|100|$1|%%1|work\n'
        fi
        ;;
    display-message)
        if [ "${1:-}" = "-p" ] && [ "${2:-}" = "-t" ] && [ "${3:-}" = "%9" ] && [ "${4:-}" = '#{session_id}|#{pane_id}' ]; then
            printf '$2|%%9\n'
            exit 0
        fi
        if [ "${1:-}" = "-c" ]; then
            printf '%s\n' "$*" >"$TEST_TEMP_DIR/display.args"
            exit 0
        fi
        exit 1
        ;;
    switch-client)
        printf '%s\n' "$*" >"$TEST_TEMP_DIR/switch.args"
        : >"$TEST_TEMP_DIR/switched"
        ;;
    *)
        exit 1
        ;;
esac
FAKE
    chmod +x "$fake_bin/tmux"
}

write_legacy_tmux_inventory_fake() {
    cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "list-clients" ] && [ "${2:-}" = "-F" ]; then
    printf '|120|legacy-terminal|/dev/pts/7|700|$1|%%7|legacy\n'
    printf '|130|legacy-background||701|$2|%%8|background\n'
    exit 0
fi
exit 1
FAKE
    chmod +x "$fake_bin/tmux"
}

@test "terminal client inventory excludes control clients even with a tty" {
    write_tmux_inventory_fake

    run env PATH="$fake_bin:$PATH" TEST_TEMP_DIR="$TEST_TEMP_DIR" bash -c \
        '. "'"$PROJECT_ROOT"'/tmux-notify-jump-lib.sh"; tmux_terminal_client_rows'

    [ "$status" -eq 0 ]
    [[ "$output" == *'/dev/pts/1|/dev/pts/1|100|$1|%1|work'* ]]
    [[ "$output" != *'control-pty'* ]]
}

@test "terminal client inventory uses tty fallback on pre-2.1 tmux" {
    write_legacy_tmux_inventory_fake

    run env PATH="$fake_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" bash -c \
        '. "'"$PROJECT_ROOT"'/tmux-notify-jump-lib.sh"; tmux_terminal_client_rows'

    [ "$status" -eq 0 ]
    [ "$output" = "120|legacy-terminal|/dev/pts/7|700|\$1|%7|legacy" ]
}

@test "strict jump reports a target session with only a control client" {
    write_tmux_inventory_fake

    run env PATH="$fake_bin:$PATH" TEST_TEMP_DIR="$TEST_TEMP_DIR" TMUX="/tmp/test,1,0" \
        bash -c '. "'"$PROJECT_ROOT"'/tmux-notify-jump-lib.sh";
            SESSION=target; WINDOW=0; PANE=0; PANE_ID=%9; SENDER_CLIENT_TTY=;
            prepare_tmux_jump_client'

    [ "$status" -ne 0 ]
    [[ "$output" == *'not visible (no ordinary terminal client)'* ]]
    run cat "$TEST_TEMP_DIR/display.args"
    [ "$status" -eq 0 ]
    [[ "$output" == *'-c /dev/pts/1'* ]]
    [[ "$output" == *'target session target is not visible'* ]]
}

@test "single-client fallback switches one explicit ordinary client" {
    write_tmux_inventory_fake

    run env PATH="$fake_bin:$PATH" TEST_TEMP_DIR="$TEST_TEMP_DIR" TMUX="/tmp/test,1,0" \
        TMUX_NOTIFY_UNATTACHED_FALLBACK=single _QUIET=0 bash -c \
        '. "'"$PROJECT_ROOT"'/tmux-notify-jump-lib.sh";
            SESSION=target; WINDOW=0; PANE=0; PANE_ID=%9; SENDER_CLIENT_TTY=;
            jump_to_pane'

    [ "$status" -eq 0 ]
    [[ "$output" == *'Jumped to target:0.0 via /dev/pts/1'* ]]
    run cat "$TEST_TEMP_DIR/switch.args"
    [ "$status" -eq 0 ]
    [[ "$output" == *'-c /dev/pts/1 -t target:0'* ]]
    [[ "$output" != *'control-pty'* ]]
}
