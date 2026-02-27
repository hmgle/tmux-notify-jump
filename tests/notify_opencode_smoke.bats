#!/usr/bin/env bats
# Smoke tests for notify-opencode.sh wrapper.

load 'test_helper'

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

@test "notify-opencode.sh: empty stdin exits 0" {
    run bash -c 'echo -n "" | "$1"' _ "$PROJECT_ROOT/notify-opencode.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify-opencode.sh: invalid JSON exits 0" {
    run bash -c 'echo "not json" | "$1"' _ "$PROJECT_ROOT/notify-opencode.sh"

    [ "$status" -eq 0 ]
}

@test "notify-opencode.sh: valid session.idle payload calls tmux-notify-jump with correct title" {
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

    # Mock jq passthrough (use real jq)
    export CAPTURE_FILE="$TEST_TEMP_DIR/captured_args"
    export TMUX_NOTIFY_JUMP_SH="$fake_bin/tmux-notify-jump"

    run bash -c '
        export PATH="'"$fake_bin"':$PATH"
        export CAPTURE_FILE
        export TMUX_NOTIFY_JUMP_SH
        echo "{\"event_type\":\"session.idle\",\"message\":\"test idle\"}" \
            | "'"$PROJECT_ROOT/notify-opencode.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -f "$CAPTURE_FILE" ]

    captured="$(cat "$CAPTURE_FILE")"
    [[ "$captured" == *"Session Idle"* ]]
    [[ "$captured" == *"OpenCode"* ]]
}

@test "notify-opencode.sh: disabled event exits 0 silently" {
    run bash -c '
        export OPENCODE_NOTIFY_EVENTS="permission.asked"
        echo "{\"event_type\":\"session.error\",\"message\":\"oops\"}" \
            | "'"$PROJECT_ROOT/notify-opencode.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify-opencode.sh: excluded event exits 0 silently" {
    run bash -c '
        export OPENCODE_NOTIFY_EXCLUDE_EVENTS="session.idle"
        echo "{\"event_type\":\"session.idle\",\"message\":\"test\"}" \
            | "'"$PROJECT_ROOT/notify-opencode.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify-opencode.sh: session.error extracts properties.error" {
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
        export OPENCODE_NOTIFY_EVENTS="*"
        echo "{\"event_type\":\"session.error\",\"properties\":{\"error\":\"rate limit exceeded\"}}" \
            | "'"$PROJECT_ROOT/notify-opencode.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -f "$CAPTURE_FILE" ]

    captured="$(cat "$CAPTURE_FILE")"
    [[ "$captured" == *"Session Error"* ]]
    [[ "$captured" == *"rate limit exceeded"* ]]
}

@test "notify-opencode.sh: session.deleted extracts properties.reason" {
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
        export OPENCODE_NOTIFY_EVENTS="*"
        echo "{\"event_type\":\"session.deleted\",\"properties\":{\"reason\":\"user requested\",\"sessionID\":\"abc-123\"}}" \
            | "'"$PROJECT_ROOT/notify-opencode.sh"'"
    '

    [ "$status" -eq 0 ]
    [ -f "$CAPTURE_FILE" ]

    captured="$(cat "$CAPTURE_FILE")"
    [[ "$captured" == *"Session Ended"* ]]
    [[ "$captured" == *"user requested"* ]]
}
