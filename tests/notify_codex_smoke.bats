#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    command -v jq >/dev/null || skip 'jq is not installed'
    export HOME="$TEST_TEMP_DIR/home"
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/absent"
    export TMUX_NOTIFY_TMUX_SOCKET="$TEST_TEMP_DIR/tmux.sock"
    export TMUX_PANE='%9'
    export CAPTURE_FILE="$TEST_TEMP_DIR/args"
    export TMUX_NOTIFY_JUMP_SH="$TEST_TEMP_DIR/bin/jump"
    unset CODEX_HOME CODEX_NOTIFY_EVENTS CODEX_NOTIFY_EXCLUDE_EVENTS CODEX_NOTIFY_DEBUG CODEX_NOTIFY_DEBUG_LOG
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat >"$TEST_TEMP_DIR/bin/jump" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CAPTURE_FILE"
echo 'hook stdout must stay empty'
SH
    cat >"$TEST_TEMP_DIR/bin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != -S ] || shift 2
case "$1" in
    list-sessions) exit 0 ;;
    list-panes) printf '%%9\n' ;;
    *) exit 1 ;;
esac
SH
    chmod +x "$TEST_TEMP_DIR/bin/"*
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() { teardown_temp_dir; }

native_codex() {
    run bash -c 'printf "%s" "$2" | "$1"' _ "$PROJECT_ROOT/notify-codex.sh" "$1"
}

@test "Codex v0.168 legacy payload remains compatible" {
    run "$PROJECT_ROOT/notify-codex.sh" '{"type":"agent-turn-complete","thread-id":"thread","turn-id":"turn","client":"codex-tui","cwd":"/tmp/project","input-messages":["Question"],"last-assistant-message":"Done"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    args="$(cat "$CAPTURE_FILE")"
    [[ "$args" == *$'--title\nCodex [agent-turn-complete]: Done\n'* ]]
    [[ "$args" == *$'--body\nQuestion\n'* ]]
    [[ "$args" == *$'--target\n%9\n'* ]]
}

@test "Codex native PermissionRequest reports attention without a decision or stdout" {
    export CODEX_NOTIFY_DEBUG=1
    native_codex '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"cargo test; echo ok"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    args="$(cat "$CAPTURE_FILE")"
    [[ "$args" == *$'--title\nCodex [PermissionRequest]: Approval requested: Bash\n'* ]]
    [[ "$args" == *$'--body\ncargo test; echo ok\n'* ]]
    [[ "$args" == *$'--notify-kind\nattention\n'* ]]
    [[ "$args" != *'Waiting For You'* ]]
    [ -f "$HOME/.codex/log/notify-codex.log" ]
}

@test "Codex native Stop accepts snake case fields" {
    native_codex '{"hook_event_name":"Stop","last_assistant_message":"Finished","cwd":"/tmp/project","stop_hook_active":true}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    args="$(cat "$CAPTURE_FILE")"
    [[ "$args" == *$'Codex [Stop]: Finished\n'* ]]
    [[ "$args" == *$'--body\n/tmp/project\n'* ]]
    [[ "$args" == *$'--notify-kind\ncomplete\n'* ]]
}

@test "Codex native events honor filtering and ignore malformed or unsupported input" {
    export CODEX_NOTIFY_EXCLUDE_EVENTS=PermissionRequest
    native_codex '{"hook_event_name":"PermissionRequest"}'
    [ "$status" -eq 0 ]
    [ ! -e "$CAPTURE_FILE" ]
    unset CODEX_NOTIFY_EXCLUDE_EVENTS
    local payload
    for payload in '' invalid '[]' 'null' '{"hook_event_name":[]}' '{"hook_event_name":"SessionStart"}'; do
        native_codex "$payload"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
        [ ! -e "$CAPTURE_FILE" ]
    done
}

@test "Codex native approval without a command falls back to its description" {
    native_codex '{"hook_event_name":"PermissionRequest","tool_name":"mcp__test__tool","tool_input":{"description":"Access example.com"}}'
    [ "$status" -eq 0 ]
    rg -qx 'Access example.com' "$CAPTURE_FILE"
}

@test "Codex debug log honors CODEX_HOME and explicit log path without HOME" {
    export CODEX_HOME="$TEST_TEMP_DIR/custom codex" CODEX_NOTIFY_DEBUG=1
    native_codex '{"hook_event_name":"PermissionRequest"}'
    [ "$status" -eq 0 ]
    [ -f "$CODEX_HOME/log/notify-codex.log" ]
    [ ! -e "$HOME/.codex" ]
    unset HOME
    export CODEX_NOTIFY_DEBUG_LOG="$TEST_TEMP_DIR/explicit.log"
    native_codex '{"hook_event_name":"PermissionRequest"}'
    [ "$status" -eq 0 ]
    [ -f "$CODEX_NOTIFY_DEBUG_LOG" ]
}
