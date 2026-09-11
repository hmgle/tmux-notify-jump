#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/env"
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"
    export TMUX_NOTIFY_TMUX_SOCKET="$TEST_TEMP_DIR/tmux.sock"
    export TMUX_PANE='%9'
    export TMUX_NOTIFY_BELL=0
    export TMUX_NOTIFY_REMOTE_MODE=tmux
    export TMUX_NOTIFY_DEBUG=0
    unset TMUX_NOTIFY_JUMP_SH TMUX_NOTIFY_ALREADY_DETACHED
    local prefix
    for prefix in CODEX CLAUDE KIMI GROK OPENCODE PI OMP; do
        unset "${prefix}_NOTIFY_BELL" "${prefix}_NOTIFY_EVENTS" "${prefix}_NOTIFY_EXCLUDE_EVENTS"
    done
    export CAPTURE_FILE="$TEST_TEMP_DIR/args"
    mkdir -p "$TEST_TEMP_DIR/bin"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export BELL_TEST_PATH="$PATH"
    cat >"$TEST_TEMP_DIR/bin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -S ]; then shift 2; fi
case "$1" in
    list-panes) printf '%%9\n' ;;
    list-clients) printf '%s\n' "${BELL_TEST_CLIENT_ROWS:-}" ;;
    display-message)
        case "${*: -1}" in
            '#S:#I.#P') echo work:0.0 ;;
            '#{session_id}|#{pane_id}') printf '$1|%%9\n' ;;
            '#{session_id}|#{window_id}|#{pane_id}|#{session_name}|#{window_index}')
                printf '$1|@1|%%9|work|0\n' ;;
            '#{socket_path}') printf '%s\n' "$TMUX_NOTIFY_TMUX_SOCKET" ;;
            '#{pid}') echo 987654 ;;
        esac ;;
esac
exit 0
SH
    cat >"$TEST_TEMP_DIR/bin/ps" <<'SH'
#!/usr/bin/env bash
echo sshd
SH
    cat >"$TEST_TEMP_DIR/bin/capture-jump" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CAPTURE_FILE"
SH
    cat >"$TEST_TEMP_DIR/bin/notify-send" <<'SH'
#!/usr/bin/env bash
echo unexpected-desktop >>"$TEST_TEMP_DIR/desktop"
if [ "${BELL_TEST_ALLOW_DESKTOP:-0}" = 1 ]; then
    echo dismiss
    exit 0
fi
exit 1
SH
    cp "$TEST_TEMP_DIR/bin/notify-send" "$TEST_TEMP_DIR/bin/terminal-notifier"
    cp "$TEST_TEMP_DIR/bin/notify-send" "$TEST_TEMP_DIR/bin/osascript"
    chmod +x "$TEST_TEMP_DIR/bin/"*
}

teardown() {
    teardown_temp_dir
}

@test "all agent wrappers forward per-agent bell overrides and filter disabled events" {
    command -v jq >/dev/null || skip "jq is not installed"
    export TMUX_NOTIFY_JUMP_SH="$TEST_TEMP_DIR/bin/capture-jump"
    local script prefix payload value
    while IFS='|' read -r script prefix payload; do
        for value in 0 1; do
            echo "$script bell=$value"
            run env "${prefix}_NOTIFY_BELL=$value" "$PROJECT_ROOT/$script" "$payload" <<<"$payload"
            [ "$status" -eq 0 ]
            [ -f "$CAPTURE_FILE" ]
            if [ "$value" = 1 ]; then
                rg -qx -- '--bell' "$CAPTURE_FILE"
            else
                rg -qx -- '--no-bell' "$CAPTURE_FILE"
            fi
            rm "$CAPTURE_FILE"
        done
        run "$PROJECT_ROOT/$script" "$payload" <<<"$payload"
        [ "$status" -eq 0 ]
        [ -f "$CAPTURE_FILE" ]
        ! rg -q -- '^--(no-)?bell$' "$CAPTURE_FILE"
        rm "$CAPTURE_FILE"
        run env "${prefix}_NOTIFY_BELL=1" "${prefix}_NOTIFY_EXCLUDE_EVENTS=*" \
            "$PROJECT_ROOT/$script" "$payload" <<<"$payload"
        [ "$status" -eq 0 ]
        [ ! -e "$CAPTURE_FILE" ]
    done <<'CASES'
notify-codex.sh|CODEX|{"type":"agent-turn-complete"}
notify-claude-code.sh|CLAUDE|{"hook_event_name":"Stop"}
notify-kimi-code.sh|KIMI|{"hook_event_name":"Stop"}
notify-grok.sh|GROK|{"hookEventName":"stop","reason":"end_turn"}
notify-opencode.sh|OPENCODE|{"event_type":"session.idle"}
notify-pi.sh|PI|{"event":"agent_settled"}
notify-omp.sh|OMP|{"event":"session_stop"}
CASES
}

@test "alert-bell hook avoids a second bell unless explicitly requested" {
    export TMUX_NOTIFY_JUMP_SH="$TEST_TEMP_DIR/bin/capture-jump"
    run "$PROJECT_ROOT/tmux-notify-jump-hook.sh" --event alert-bell --pane-id %9
    [ "$status" -eq 0 ]
    rg -qx -- '--no-bell' "$CAPTURE_FILE"
    run "$PROJECT_ROOT/tmux-notify-jump-hook.sh" --event alert-bell --pane-id %9 --bell
    [ "$status" -eq 0 ]
    rg -qx -- '--bell' "$CAPTURE_FILE"
    ! rg -qx -- '--no-bell' "$CAPTURE_FILE"
    run "$PROJECT_ROOT/tmux-notify-jump-hook.sh" --event alert-activity --pane-id %9
    [ "$status" -eq 0 ]
    ! rg -q -- '^--(no-)?bell$' "$CAPTURE_FILE"
}

@test "Linux and macOS dry-run report the effective bell configuration" {
    local platform
    printf 'TMUX_NOTIFY_BELL=1\n' >"$TMUX_NOTIFY_CONFIG"
    for platform in linux macos; do
        run "$PROJECT_ROOT/tmux-notify-jump-$platform.sh" --target %9 --dry-run
        [ "$status" -eq 0 ]
        [[ "$output" == *'Terminal bell: yes'* ]]
        run "$PROJECT_ROOT/tmux-notify-jump-$platform.sh" --target %9 --dry-run --no-bell
        [ "$status" -eq 0 ]
        [[ "$output" == *'Terminal bell: no'* ]]
    done
}

@test "PTY receives one BEL through redirected and detached platform notifications" {
    command -v uv >/dev/null || skip "uv is required for the isolated PTY test"
    command -v python3 >/dev/null || skip "Python is required for the isolated PTY test"
    run uv run --offline --no-project --no-managed-python python "$TEST_DIR/bell_pty.py" "$PROJECT_ROOT"
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TEMP_DIR/desktop" ]
}
