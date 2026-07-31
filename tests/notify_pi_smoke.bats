#!/usr/bin/env bats
# Smoke tests for notify-pi.sh wrapper.

load 'test_helper'

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

@test "notify-pi.sh: empty stdin exits 0" {
    run bash -c 'echo -n "" | "$1"' _ "$PROJECT_ROOT/notify-pi.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify-pi.sh: invalid JSON exits 0" {
    run bash -c 'echo "not json" | "$1"' _ "$PROJECT_ROOT/notify-pi.sh"

    [ "$status" -eq 0 ]
}

@test "notify-pi.sh: agent_settled payload calls tmux-notify-jump with correct title" {
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    # Mock tmux-notify-jump to capture args
    cat >"$fake_bin/tmux-notify-jump" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_FILE"
exit 0
FAKE
    chmod +x "$fake_bin/tmux-notify-jump"

    # Mock tmux as unavailable (forces --focus-only path)
    cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
    chmod +x "$fake_bin/tmux"

    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_args"
    export TMUX_NOTIFY_JUMP_SH="$fake_bin/tmux-notify-jump"

    run bash -c '
        export PATH="'"$fake_bin"':$PATH"
        export CAPTURE_FILE
        export TMUX_NOTIFY_JUMP_SH
        echo "{\"event\":\"agent_settled\"}" \
            | "'"$PROJECT_ROOT/notify-pi.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -f "$CAPTURE_FILE" ]

    captured="$(cat "$CAPTURE_FILE")"
    [[ "$captured" == *"Response Complete"* ]]
    [[ "$captured" == *"Pi"* ]]
    [[ "$captured" == *"--focus-only"* ]]
    [[ "$captured" == *"Click to focus terminal"* ]]
}

@test "notify-pi.sh: agent_end disabled by default exits 0 silently" {
    run bash -c '
        echo "{\"event\":\"agent_end\"}" \
            | "'"$PROJECT_ROOT/notify-pi.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify-pi.sh: PI_NOTIFY_EVENTS enables agent_end" {
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/tmux-notify-jump" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_FILE"
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

    run bash -c '
        export PATH="'"$fake_bin"':$PATH"
        export CAPTURE_FILE
        export TMUX_NOTIFY_JUMP_SH
        export PI_NOTIFY_EVENTS="agent_end"
        echo "{\"event\":\"agent_end\"}" \
            | "'"$PROJECT_ROOT/notify-pi.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -f "$CAPTURE_FILE" ]

    captured="$(cat "$CAPTURE_FILE")"
    [[ "$captured" == *"Agent Run Ended"* ]]
}

@test "notify-pi.sh: excluded event exits 0 silently" {
    run bash -c '
        export PI_NOTIFY_EXCLUDE_EVENTS="agent_settled"
        echo "{\"event\":\"agent_settled\"}" \
            | "'"$PROJECT_ROOT/notify-pi.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify-pi.sh: per-event UI and timeout routing" {
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/tmux-notify-jump" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_FILE"
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

    run bash -c '
        export PATH="'"$fake_bin"':$PATH"
        export CAPTURE_FILE
        export TMUX_NOTIFY_JUMP_SH
        export PI_NOTIFY_UI_BY_EVENT="agent_settled:dialog"
        export PI_NOTIFY_TIMEOUT_MS_BY_EVENT="agent_settled:12345"
        echo "{\"event\":\"agent_settled\"}" \
            | "'"$PROJECT_ROOT/notify-pi.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -f "$CAPTURE_FILE" ]

    captured="$(cat "$CAPTURE_FILE")"
    [[ "$captured" == *"--ui"* ]]
    [[ "$captured" == *"dialog"* ]]
    [[ "$captured" == *"12345"* ]]
}

@test "notify-pi.sh: remote ssh tmux client suppresses notification by default" {
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/tmux-notify-jump" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_FILE"
exit 0
FAKE
    chmod +x "$fake_bin/tmux-notify-jump"

    cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
cmd="$1"
shift || true

case "$cmd" in
    list-sessions)
        exit 0
        ;;
    display-message)
        if [ "${1:-}" = "-p" ] && [ "${2:-}" = "-t" ] && [ "${3:-}" = "%1" ] && [ "${4:-}" = "#S" ]; then
            printf 'work\n'
            exit 0
        fi
        exit 1
        ;;
    list-clients)
        if [ "${1:-}" = "-F" ] && [ "${2:-}" = "#{client_pid} #{client_session}" ]; then
            printf '222 work\n'
            exit 0
        fi
        exit 1
        ;;
esac

exit 1
FAKE
    chmod +x "$fake_bin/tmux"

    cat >"$fake_bin/ps" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "-p" ] && [ "${3:-}" = "-o" ] && [ "${4:-}" = "ppid=" ]; then
    case "${2:-}" in
        222) printf '111\n' ;;
        111) printf '1\n' ;;
        *) printf '1\n' ;;
    esac
    exit 0
fi

if [ "${1:-}" = "-p" ] && [ "${3:-}" = "-o" ] && [ "${4:-}" = "comm=" ]; then
    case "${2:-}" in
        222) printf 'bash\n' ;;
        111) printf 'sshd\n' ;;
        *) printf 'init\n' ;;
    esac
    exit 0
fi

exit 1
FAKE
    chmod +x "$fake_bin/ps"

    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_args"
    export TMUX_NOTIFY_JUMP_SH="$fake_bin/tmux-notify-jump"

    run bash -c '
        export PATH="'"$fake_bin"':$PATH"
        export CAPTURE_FILE
        export TMUX_NOTIFY_JUMP_SH
        export TMUX="/tmp/tmux-test,123,0"
        export TMUX_PANE="%1"
        echo "{\"event\":\"agent_settled\"}" \
            | "'"$PROJECT_ROOT/notify-pi.sh"'"
    '

    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]
}

@test "notify-pi.sh: TMUX_NOTIFY_REMOTE allows remote ssh tmux notification" {
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/tmux-notify-jump" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_FILE"
exit 0
FAKE
    chmod +x "$fake_bin/tmux-notify-jump"

    cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
cmd="$1"
shift || true

case "$cmd" in
    list-sessions)
        exit 0
        ;;
    display-message)
        if [ "${1:-}" = "-p" ] && [ "${2:-}" = "-t" ] && [ "${3:-}" = "%1" ] && [ "${4:-}" = "#S" ]; then
            printf 'work\n'
            exit 0
        fi
        exit 1
        ;;
    list-clients)
        if [ "${1:-}" = "-F" ] && [ "${2:-}" = "#{client_pid} #{client_session}" ]; then
            printf '222 work\n'
            exit 0
        fi
        exit 1
        ;;
esac

exit 1
FAKE
    chmod +x "$fake_bin/tmux"

    cat >"$fake_bin/ps" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "-p" ] && [ "${3:-}" = "-o" ] && [ "${4:-}" = "ppid=" ]; then
    case "${2:-}" in
        222) printf '111\n' ;;
        111) printf '1\n' ;;
        *) printf '1\n' ;;
    esac
    exit 0
fi

if [ "${1:-}" = "-p" ] && [ "${3:-}" = "-o" ] && [ "${4:-}" = "comm=" ]; then
    case "${2:-}" in
        222) printf 'bash\n' ;;
        111) printf 'sshd\n' ;;
        *) printf 'init\n' ;;
    esac
    exit 0
fi

exit 1
FAKE
    chmod +x "$fake_bin/ps"

    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_args"
    export TMUX_NOTIFY_JUMP_SH="$fake_bin/tmux-notify-jump"

    run bash -c '
        export PATH="'"$fake_bin"':$PATH"
        export CAPTURE_FILE
        export TMUX_NOTIFY_JUMP_SH
        export TMUX="/tmp/tmux-test,123,0"
        export TMUX_PANE="%1"
        export TMUX_NOTIFY_REMOTE=1
        echo "{\"event\":\"agent_settled\"}" \
            | "'"$PROJECT_ROOT/notify-pi.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -f "$CAPTURE_FILE" ]

    captured="$(cat "$CAPTURE_FILE")"
    [[ "$captured" == *"--target"* ]]
    [[ "$captured" == *"Click to jump to tmux pane"* ]]
}
