#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    command -v jq >/dev/null 2>&1 || skip 'jq is not installed'
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat >"$TEST_TEMP_DIR/bin/jump" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CAPTURE_FILE"
FAKE
    cat >"$TEST_TEMP_DIR/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = list-sessions ]
FAKE
    chmod +x "$TEST_TEMP_DIR/bin/"*
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/no-config"
    export TMUX_NOTIFY_JUMP_SH="$TEST_TEMP_DIR/bin/jump"
    export CAPTURE_FILE="$TEST_TEMP_DIR/args"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export TMUX_PANE='%9'
}

teardown() {
    teardown_temp_dir
}

@test "reporter contract preserves completion labels across all adapters" {
    while IFS='|' read -r wrapper source payload; do
        rm -f "$CAPTURE_FILE"
        if [ "$wrapper" = codex ]; then
            run "$PROJECT_ROOT/notify-$wrapper.sh" "$payload"
        else
            run bash -c 'printf "%s" "$2" | "$1"' _ "$PROJECT_ROOT/notify-$wrapper.sh" "$payload"
        fi
        [ "$status" -eq 0 ]
        args="$(cat "$CAPTURE_FILE")"
        [[ "$args" == *$'--notify-kind\ncomplete\n'* ]]
        [[ "$args" == *$'--notify-source\n'"$source"$'\n'* ]]
        [[ "$args" == *$'--target\n%9\n'* ]]
    done <<'EVENTS'
codex|Codex|{"type":"agent-turn-complete"}
claude-code|Claude|{"hook_event_name":"Stop"}
kimi-code|Kimi|{"hook_event_name":"Stop"}
grok|Grok|{"hookEventName":"stop","reason":"end_turn"}
opencode|OpenCode|{"event_type":"session.idle"}
pi|Pi|{"event":"agent_settled"}
step|Step|{"event":"agent_settled"}
omp|omp|{"event":"session_stop"}
EVENTS
}

@test "reporter contract preserves native attention events and subtype distinctions" {
    [ "$(tmux_notify_event_kind claude Notification elicitation_dialog)" = attention ]
    [ "$(tmux_notify_event_kind claude Notification auth_success)" = complete ]
    [ "$(tmux_notify_event_kind kimi PermissionRequest)" = attention ]
    [ "$(tmux_notify_event_kind grok notification permission_prompt)" = attention ]
    [ "$(tmux_notify_event_kind grok notification auth_success)" = complete ]
    [ "$(tmux_notify_event_kind opencode permission.asked)" = attention ]
    [ "$(tmux_notify_event_kind opencode permission.replied)" = complete ]
    [ "$(tmux_notify_event_kind step ui_prompt_start)" = attention ]
    for agent in codex pi omp step; do
        [ "$(tmux_notify_event_kind "$agent" tool.failure)" = attention ]
        [ "$(tmux_notify_event_kind "$agent" tool.done)" = complete ]
    done
}

@test "focus-only default messages retain reporter source and priority" {
    unset TMUX_PANE
    while IFS='|' read -r wrapper source payload; do
        rm -f "$CAPTURE_FILE"
        run bash -c 'printf "%s" "$2" | "$1"' _ "$PROJECT_ROOT/notify-$wrapper.sh" "$payload"
        [ "$status" -eq 0 ]
        args="$(cat "$CAPTURE_FILE")"
        [[ "$args" == *$'--notify-kind\ncomplete\n'* ]]
        [[ "$args" == *$'--notify-source\n'"$source"$'\n'* ]]
        [[ "$args" == *$'--focus-only\n'* ]]
        [[ "$args" == *$'--body\nClick to focus terminal\n'* ]]
    done <<'EVENTS'
claude-code|Claude|{"hook_event_name":"Stop"}
kimi-code|Kimi|{"hook_event_name":"Stop"}
grok|Grok|{"hookEventName":"stop","reason":"end_turn"}
EVENTS
}
