#!/usr/bin/env bats

load 'test_helper'

setup() {
    command -v tmux >/dev/null 2>&1 || skip "tmux is not installed"
    command -v jq >/dev/null 2>&1 || skip "jq is not installed"
    setup_temp_dir
    ambient_socket="${TMUX:-}"
    ambient_socket="${ambient_socket%%,*}"
    socket="$TEST_TEMP_DIR/tmux.sock"
    [ "$socket" != "$ambient_socket" ] && [ ! -e "$socket" ] || skip "tmux socket is not isolated"
    unset TMUX TMUX_PANE TMUX_NOTIFY_TMUX_SOCKET
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/no-config"
    export TMUX_NOTIFY_JUMP_SH="$TEST_TEMP_DIR/jump"
    export OPENCODE_NOTIFY_EVENTS='*' OPENCODE_NOTIFY_EXCLUDE_EVENTS=
    export OPENCODE_NOTIFY_FALLBACK_TARGET=1 OPENCODE_NOTIFY_FOCUS_ONLY_FALLBACK=1
    export OPENCODE_NOTIFY_DEBUG=1 OPENCODE_NOTIFY_DEBUG_LOG="$TEST_TEMP_DIR/notify.log"
    cat >"$TMUX_NOTIFY_JUMP_SH" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$@"
SCRIPT
    chmod +x "$TMUX_NOTIFY_JUMP_SH"

    tmux -S "$socket" -f /dev/null new-session -d -s test 'sleep 60'
    pane_a="$(tmux -S "$socket" display-message -p -t test '#{pane_id}')"
    pane_b="$(tmux -S "$socket" split-window -d -P -F '#{pane_id}' -t test 'sleep 60')"
    cache_dir="$XDG_CACHE_HOME/tmux-notify-jump/opencode"
    mkdir -p "$cache_dir"
}

teardown() {
    if [ -n "${socket:-}" ] && [ "$socket" = "$TEST_TEMP_DIR/tmux.sock" ] &&
        [ "$socket" != "$ambient_socket" ] && [ -S "$socket" ]; then
        tmux -S "$socket" kill-server
    fi
    teardown_temp_dir
}

bind_pane() {
    local actual_pane="$1" session="$2" reported_pane="${3:-$1}" pid=""
    pid="$(tmux -S "$socket" display-message -p -t "$actual_pane" '#{pane_pid}')"
    jq -n --arg pane "$reported_pane" --arg socket "$socket" \
        --arg serverPID "$(tmux -S "$socket" display-message -p '#{pid}')" \
        --arg id "$session" '{pane:$pane, socket:$socket, serverPID:$serverPID, sessionID:$id}' \
        >"$cache_dir/$pid.json"
}

@test "OpenCode shared notifications select by session and pin the client socket" {
    bind_pane "$pane_a" ses_first
    bind_pane "$pane_b" ses_second
    tmux -S "$socket" select-pane -t "$pane_a"
    export TMUX_PANE="$pane_a" TMUX_NOTIFY_TMUX_SOCKET="$TEST_TEMP_DIR/unrelated.sock"

    run "$PROJECT_ROOT/notify-opencode.sh" <<<'{"event_type":"session.idle","shared_server":true,"properties":{"sessionID":"ses_second"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == "--target"$'\n'"$pane_b"$'\n'* ]]
    [[ "$output" == *"--tmux-socket"$'\n'"$socket"* ]]

    run "$PROJECT_ROOT/notify-opencode.sh" <<<'{"event_type":"permission.asked","shared_server":true,"properties":{"sessionID":"ses_child"},"parent_session_id":"ses_first"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "--target"$'\n'"$pane_a"$'\n'* ]]
}

@test "OpenCode shared notifications ignore ambiguous or misattributed pane bindings" {
    bind_pane "$pane_a" ses_shared
    bind_pane "$pane_b" ses_shared
    payload='{"event_type":"session.idle","shared_server":true,"properties":{"sessionID":"ses_shared"}}'

    run "$PROJECT_ROOT/notify-opencode.sh" <<<"$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == "--focus-only"$'\n'* ]]

    bind_pane "$pane_a" ses_other
    bind_pane "$pane_b" ses_shared "$pane_a"
    run "$PROJECT_ROOT/notify-opencode.sh" <<<"$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == "--focus-only"$'\n'* ]]

    bind_pane "$pane_b" ses_shared
    [ "$socket" = "$TEST_TEMP_DIR/tmux.sock" ] && [ "$socket" != "$ambient_socket" ]
    tmux -S "$socket" kill-pane -t "$pane_b"
    run "$PROJECT_ROOT/notify-opencode.sh" <<<"$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == "--focus-only"$'\n'* ]]
}
