#!/usr/bin/env bats
# Smoke tests for the GitHub Copilot CLI hook integration.

load 'test_helper'

setup() {
    setup_temp_dir
    unset TMUX TMUX_PANE TMUX_NOTIFY_TMUX_SOCKET
    unset COPILOT_HOOKS_PATH COPILOT_NOTIFY_EVENTS COPILOT_NOTIFY_EXCLUDE_EVENTS
    unset COPILOT_NOTIFY_FOCUS_ONLY_FALLBACK COPILOT_NOTIFY_FALLBACK_TARGET
    unset COPILOT_NOTIFY_DEBUG
    export HOME="$TEST_TEMP_DIR/home" TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/absent-env"
    export TMUX_NOTIFY_FOCUS_ONLY_FALLBACK=1
    export TMUX_NOTIFY_FALLBACK_TARGET=0
    export COPILOT_NOTIFY_SHOW_EVENT_TYPE=1
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"
    export PATH="$fake_bin:$PATH"

    cat >"$fake_bin/tmux-notify-jump" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CAPTURE_FILE"
exit 0
FAKE
    cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
    chmod +x "$fake_bin/tmux-notify-jump" "$fake_bin/tmux"
    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_args"
    export TMUX_NOTIFY_JUMP_SH="$fake_bin/tmux-notify-jump"
}

teardown() {
    teardown_temp_dir
}

require_jq() {
    command -v jq >/dev/null || skip 'jq is not installed'
}

run_copilot_hook() {
    local event="$1" payload="$2"
    run "$PROJECT_ROOT/notify-copilot.sh" "$event" <<<"$payload"
}

captured_args() {
    [ -f "$CAPTURE_FILE" ] || return 1
    cat "$CAPTURE_FILE"
}

@test "notify-copilot.sh: agentStop notifies only the root end-of-turn event" {
    require_jq
    run_copilot_hook agentStop \
        '{"sessionId":"session_abc","stopReason":"end_turn","agentId":null}'

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    captured="$(captured_args)"
    [[ "$captured" == *"--focus-only"* ]]
    [[ "$captured" == *"--detach"* ]]
    [[ "$captured" == *$'--notify-kind\ncomplete'* ]]
    [[ "$captured" == *"Copilot [agentStop]: Agent Turn Stopping"* ]]
    [[ "$captured" == *"Click to focus terminal"* ]]

    rm -f "$CAPTURE_FILE"
    run_copilot_hook agentStop \
        '{"sessionId":"session_abc","stopReason":"end_turn","agentId":"subagent"}'
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]
}

@test "notify-copilot.sh: permission and elicitation notifications need attention" {
    require_jq
    run_copilot_hook notification \
        '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow bash"}'
    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"Copilot [permission_prompt]: Permission Needed"* ]]
    [[ "$captured" == *"Allow bash"* ]]
    [[ "$captured" == *$'--notify-kind\nattention'* ]]

    rm -f "$CAPTURE_FILE"
    run_copilot_hook notification \
        '{"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"Which option?"}'
    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"Copilot [elicitation_dialog]: Input Needed"* ]]
    [[ "$captured" == *"Which option?"* ]]
}

@test "notify-copilot.sh: forwards Copilot bell and terminal options" {
    require_jq
    export COPILOT_NOTIFY_BELL=1 COPILOT_NOTIFY_TERMINAL_METHOD=osc777
    run_copilot_hook agentStop '{"stopReason":"end_turn"}'

    [ "$status" -eq 0 ]
    rg -qx -- '--bell' "$CAPTURE_FILE"
    rg -A1 -x -- '--terminal-method' "$CAPTURE_FILE" | rg -qx 'osc777'
}

@test "notify-copilot.sh: irrelevant, malformed, and excluded events fail open" {
    require_jq
    run_copilot_hook notification \
        '{"hook_event_name":"Notification","notification_type":"agent_idle","message":"Ready"}'
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]

    run_copilot_hook agentStop 'invalid JSON'
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]

    export COPILOT_NOTIFY_EXCLUDE_EVENTS='*'
    run_copilot_hook agentStop \
        '{"sessionId":"session_abc","stopReason":"end_turn","agentId":null}'
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]
}

@test "notify-copilot.sh: missing jq fails open without output" {
    # Hide jq even when the wrapper adds Homebrew directories to PATH.
    command() {
        if [ "$1" = -v ] && [ "$2" = jq ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command
    run_copilot_hook agentStop '{"stopReason":"end_turn"}'

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$CAPTURE_FILE" ]
}

@test "notify-copilot.sh: routes to the originating pane and socket" {
    require_jq
    export TMUX="$TEST_TEMP_DIR/tmux.sock,1234,0" TMUX_PANE='%12'
    cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s\n' "${TMUX_NOTIFY_TMUX_SOCKET:-}" "$*" >"$TMUX_CAPTURE_FILE"
[ "$1" = list-sessions ]
FAKE
    export TMUX_CAPTURE_FILE="$TEST_TEMP_DIR/tmux-captured"

    run_copilot_hook agentStop '{"stopReason":"end_turn"}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *$'--target\n%12'* ]]
    [[ "$captured" == *"Click to jump to tmux pane"* ]]
    [[ "$(cat "$TMUX_CAPTURE_FILE")" == "$TEST_TEMP_DIR/tmux.sock|list-sessions" ]]
}

@test "install.sh: configure-copilot honors COPILOT_HOME and is idempotent" {
    require_jq
    install_dir="$TEST_TEMP_DIR/install dir/bin"
    hooks_dir="$TEST_TEMP_DIR/copilot home/hooks"
    config="$hooks_dir/tmux-notify-jump.json"

    run env COPILOT_HOME="$TEST_TEMP_DIR/copilot home" \
        "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy --configure-copilot

    [ "$status" -eq 0 ]
    [ -x "$install_dir/notify-copilot.sh" ]
    [ -f "$config" ]
    run jq -e --arg cmd "$install_dir/notify-copilot.sh" '
        .version == 1 and
        (.hooks.agentStop | length) == 1 and
        .hooks.agentStop[0].bash == ("exec " + ([$cmd, "agentStop"] | @sh)) and
        .hooks.agentStop[0].timeoutSec == 5 and
        (.hooks.notification | length) == 1 and
        .hooks.notification[0].matcher == "permission_prompt|elicitation_dialog" and
        .hooks.notification[0].bash == ("exec " + ([$cmd, "notification"] | @sh))
    ' "$config"
    [ "$status" -eq 0 ]

    generated_cmd="$(jq -r '.hooks.agentStop[0].bash' "$config")"
    run bash -c 'printf "%s" "$1" | bash -c "$2"' _ \
        '{"sessionId":"session_abc","stopReason":"end_turn"}' "$generated_cmd"
    [ "$status" -eq 0 ]
    [[ "$(captured_args)" == *"Copilot [agentStop]: Agent Turn Stopping"* ]]

    run env COPILOT_HOME="$TEST_TEMP_DIR/copilot home" \
        "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy --configure-copilot
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
}

@test "install.sh: configure-copilot fails clearly when jq is missing" {
    minimal_bin="$TEST_TEMP_DIR/minimal-bin"
    install_dir="$TEST_TEMP_DIR/install/bin"
    hooks_dir="$TEST_TEMP_DIR/copilot/hooks"
    mkdir -p "$minimal_bin"
    ln -s "$(command -v bash)" "$minimal_bin/bash"
    ln -s "$(command -v dirname)" "$minimal_bin/dirname"

    run env PATH="$minimal_bin" COPILOT_HOME="$TEST_TEMP_DIR/copilot" \
        "$PROJECT_ROOT/install.sh" --bindir "$install_dir" \
        --copy --configure-copilot

    [ "$status" -eq 1 ]
    [[ "$output" == *"Install jq before using --configure-copilot"* ]]
    [ ! -e "$install_dir" ]
    [ ! -e "$hooks_dir" ]
}

@test "install.sh: configure-copilot preserves an existing hook file" {
    require_jq
    install_dir="$TEST_TEMP_DIR/install/bin"
    hooks_dir="$TEST_TEMP_DIR/copilot/hooks"
    config="$hooks_dir/tmux-notify-jump.json"
    mkdir -p "$hooks_dir"
    printf '{"version":1,"hooks":{"agentStop":[]}}\n' >"$config"

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-copilot --copilot-hooks-path "$hooks_dir"

    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists and differs"* ]]
    [ "$(cat "$config")" = '{"version":1,"hooks":{"agentStop":[]}}' ]
}
