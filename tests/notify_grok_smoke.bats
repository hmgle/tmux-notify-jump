#!/usr/bin/env bats
# Smoke tests for notify-grok.sh and Grok installer integration.

load 'test_helper'

setup() {
    setup_temp_dir
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/tmux-notify-jump" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CAPTURE_FILE"
exit 0
FAKE
    chmod +x "$fake_bin/tmux-notify-jump"

    cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
    chmod +x "$fake_bin/tmux"

    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_args"
    export TMUX_NOTIFY_JUMP_SH="$fake_bin/tmux-notify-jump"
}

teardown() {
    teardown_temp_dir
}

run_grok_hook() {
    local payload="$1"
    run bash -c '
        export PATH="'"$fake_bin"':$PATH"
        printf "%s" "$1" | "'"$PROJECT_ROOT/notify-grok.sh"'"
    ' _ "$payload"
}

captured_args() {
    [ -f "$CAPTURE_FILE" ] || return 1
    cat "$CAPTURE_FILE"
}

@test "notify-grok.sh: empty stdin exits 0" {
    run bash -c 'printf "" | "$1"' _ "$PROJECT_ROOT/notify-grok.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify-grok.sh: invalid JSON exits 0" {
    run_grok_hook 'not json'

    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]
}

@test "notify-grok.sh: missing jq fails open" {
    minimal_bin="$TEST_TEMP_DIR/minimal-bin"
    mkdir -p "$minimal_bin"
    ln -s /usr/bin/bash "$minimal_bin/bash"
    ln -s /usr/bin/cat "$minimal_bin/cat"
    ln -s /usr/bin/dirname "$minimal_bin/dirname"

    run env PATH="$minimal_bin" /usr/bin/bash -c \
        'printf "%s" "{\"hookEventName\":\"stop\",\"reason\":\"end_turn\"}" | "$1"' \
        _ "$PROJECT_ROOT/notify-grok.sh"

    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]
}

@test "notify-grok.sh: debug logging follows GROK_HOME" {
    export GROK_NOTIFY_DEBUG=1
    export GROK_HOME="$TEST_TEMP_DIR/grok-home"
    run_grok_hook 'not json'

    [ "$status" -eq 0 ]
    [ -f "$GROK_HOME/logs/notify-grok.log" ]
    grep -q 'invalid JSON payload; ignoring' "$GROK_HOME/logs/notify-grok.log"
}

@test "notify-grok.sh: end-turn Stop maps to a detached focus notification" {
    run_grok_hook '{"hookEventName":"stop","reason":"end_turn","sessionId":"session_abc"}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"--focus-only"* ]]
    [[ "$captured" == *"--detach"* ]]
    [[ "$captured" == *"Grok [stop]: Response Complete"* ]]
    [[ "$captured" == *"Click to focus terminal"* ]]
}

@test "notify-grok.sh: session-end Stop is ignored" {
    run_grok_hook '{"hookEventName":"stop","reason":"channel_closed"}'
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]

    run_grok_hook '{"hookEventName":"stop","reason":"shutdown"}'
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]
}

@test "notify-grok.sh: Notification reads camelCase type and message" {
    run_grok_hook '{"hookEventName":"notification","notificationType":"permission_prompt","message":"Approve run_terminal_command"}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"Grok [permission_prompt]: Permission Needed"* ]]
    [[ "$captured" == *"Approve run_terminal_command"* ]]
    [[ "$captured" == *"--notify-kind"$'\n'"attention"* ]]
}

@test "notify-grok.sh: notification type filtering suppresses calls" {
    run_grok_hook '{"hookEventName":"notification","notificationType":"task_complete","message":"Done"}'
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]

    export GROK_NOTIFY_TYPES="task_complete"
    run_grok_hook '{"hookEventName":"notification","notificationType":"task_complete","message":"Done"}'
    [ "$status" -eq 0 ]
    [ -f "$CAPTURE_FILE" ]
}

@test "notify-grok.sh: post-tool failure includes tool and error details" {
    run_grok_hook '{"hookEventName":"post_tool_use_failure","toolName":"run_terminal_command","errorDetails":"exit status 2"}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"Grok [post_tool_use_failure]: run_terminal_command failed"* ]]
    [[ "$captured" == *"exit status 2"* ]]
    [[ "$captured" == *"--notify-kind"$'\n'"attention"* ]]
}

@test "notify-grok.sh: wrapper options are forwarded" {
    export GROK_NOTIFY_UI="dialog"
    export GROK_NOTIFY_TIMEOUT_MS="4321"
    run_grok_hook '{"hookEventName":"stop","reason":"end_turn"}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"--ui"$'\n'"dialog"* ]]
    [[ "$captured" == *"--timeout"$'\n'"4321"* ]]
}

@test "install.sh: configure-grok creates native hooks and is idempotent" {
    install_dir="$TEST_TEMP_DIR/install/bin"
    hooks_dir="$TEST_TEMP_DIR/grok/hooks"
    config="$hooks_dir/tmux-notify-jump.json"

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-grok --grok-hooks-path "$hooks_dir"

    [ "$status" -eq 0 ]
    [ -x "$install_dir/notify-grok.sh" ]
    [ -f "$config" ]
    run jq -e --arg cmd "$install_dir/notify-grok.sh" '
        .hooks.Stop[0].hooks[0].command == $cmd and
        .hooks.Notification[0].matcher == "permission_prompt|idle_prompt" and
        .hooks.Notification[0].hooks[0].command == $cmd and
        .hooks.PostToolUseFailure[0].hooks[0].command == $cmd
    ' "$config"
    [ "$status" -eq 0 ]

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-grok --grok-hooks-path "$hooks_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
    [ "$(jq '[.hooks[][] | .hooks[] | select(.command | endswith("notify-grok.sh"))] | length' "$config")" -eq 3 ]
}

@test "install.sh: configure-grok preserves existing hooks and creates a backup" {
    install_dir="$TEST_TEMP_DIR/install/bin"
    hooks_dir="$TEST_TEMP_DIR/grok/hooks"
    config="$hooks_dir/tmux-notify-jump.json"
    mkdir -p "$hooks_dir"
    printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"existing.sh"}]}]},"custom":true}' >"$config"

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-grok --grok-hooks-path "$hooks_dir"

    [ "$status" -eq 0 ]
    backup="$(find "$hooks_dir" -type f -name 'tmux-notify-jump.json.bak.*' | head -n 1)"
    [ -n "$backup" ]
    run jq -e '
        .custom == true and
        .hooks.SessionStart[0].hooks[0].command == "existing.sh" and
        (.hooks.Stop | length) == 1
    ' "$config"
    [ "$status" -eq 0 ]
}

@test "install.sh: configure-grok completes a partial native setup" {
    install_dir="$TEST_TEMP_DIR/install/bin"
    hooks_dir="$TEST_TEMP_DIR/grok/hooks"
    config="$hooks_dir/tmux-notify-jump.json"
    notify_cmd="$install_dir/notify-grok.sh"
    mkdir -p "$hooks_dir"
    jq -n --arg cmd "$notify_cmd" '{
        hooks: {
            Stop: [{hooks: [{type: "command", command: $cmd}]}]
        }
    }' >"$config"

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-grok --grok-hooks-path "$hooks_dir"

    [ "$status" -eq 0 ]
    run jq -e --arg cmd "$notify_cmd" '
        (.hooks.Stop | length) == 1 and
        .hooks.Notification[0].hooks[0].command == $cmd and
        .hooks.PostToolUseFailure[0].hooks[0].command == $cmd
    ' "$config"
    [ "$status" -eq 0 ]
}

@test "install.sh: configure-grok does not replace an incompatible schema" {
    install_dir="$TEST_TEMP_DIR/install/bin"
    hooks_dir="$TEST_TEMP_DIR/grok/hooks"
    config="$hooks_dir/tmux-notify-jump.json"
    mkdir -p "$hooks_dir"
    printf '%s\n' '{"hooks":[]}' >"$config"

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-grok --grok-hooks-path "$hooks_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"non-object hooks; not modifying"* ]]
    [ "$(cat "$config")" = '{"hooks":[]}' ]
}
