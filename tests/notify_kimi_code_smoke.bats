#!/usr/bin/env bats
# Smoke tests for notify-kimi-code.sh and Kimi installer integration.

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

run_kimi_hook() {
    local payload="$1"
    run bash -c '
        export PATH="'"$fake_bin"':$PATH"
        printf "%s" "$1" | "'"$PROJECT_ROOT/notify-kimi-code.sh"'"
    ' _ "$payload"
}

captured_args() {
    [ -f "$CAPTURE_FILE" ] || return 1
    cat "$CAPTURE_FILE"
}

@test "notify-kimi-code.sh: empty stdin exits 0" {
    run bash -c 'printf "" | "$1"' _ "$PROJECT_ROOT/notify-kimi-code.sh"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify-kimi-code.sh: invalid JSON exits 0" {
    run_kimi_hook 'not json'

    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]
}

@test "notify-kimi-code.sh: Stop maps to a detached focus notification" {
    run_kimi_hook '{"hook_event_name":"Stop","session_id":"session_abc","cwd":"/tmp/project"}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"--focus-only"* ]]
    [[ "$captured" == *"--detach"* ]]
    [[ "$captured" == *"Kimi [Stop]: Response Complete"* ]]
    [[ "$captured" == *"Click to focus terminal"* ]]
}

@test "notify-kimi-code.sh: PermissionRequest includes the requested action" {
    run_kimi_hook '{"hook_event_name":"PermissionRequest","tool_name":"Bash","action":"Run release command"}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"Kimi [PermissionRequest]: Permission Needed"* ]]
    [[ "$captured" == *"Run release command"* ]]
}

@test "notify-kimi-code.sh: StopFailure includes the error message" {
    run_kimi_hook '{"hook_event_name":"StopFailure","error_type":"APIError","error_message":"rate limit exceeded"}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"Kimi [StopFailure]: Turn Failed"* ]]
    [[ "$captured" == *"rate limit exceeded"* ]]
}

@test "notify-kimi-code.sh: Notification uses Kimi title and body fields" {
    run_kimi_hook '{"hook_event_name":"Notification","notification_type":"task.completed","title":"Background agent completed","body":"Repository inspection completed."}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"Kimi [task.completed]: Background agent completed"* ]]
    [[ "$captured" == *"Repository inspection completed."* ]]
}

@test "notify-kimi-code.sh: event and notification type exclusions suppress calls" {
    export KIMI_NOTIFY_EXCLUDE_EVENTS="StopFailure"
    run_kimi_hook '{"hook_event_name":"StopFailure","error_message":"failure"}'
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]

    export KIMI_NOTIFY_EXCLUDE_EVENTS=""
    export KIMI_NOTIFY_EXCLUDE_TYPES="task.completed"
    run_kimi_hook '{"hook_event_name":"Notification","notification_type":"task.completed"}'
    [ "$status" -eq 0 ]
    [ ! -f "$CAPTURE_FILE" ]
}

@test "notify-kimi-code.sh: Notification supports per-type UI and timeout routing" {
    export KIMI_NOTIFY_UI_BY_TYPE="task.completed:dialog"
    export KIMI_NOTIFY_TIMEOUT_MS_BY_TYPE="task.completed:4321"
    run_kimi_hook '{"hook_event_name":"Notification","notification_type":"task.completed","title":"Done","body":"Finished"}'

    [ "$status" -eq 0 ]
    captured="$(captured_args)"
    [[ "$captured" == *"--ui"$'\n'"dialog"* ]]
    [[ "$captured" == *"--timeout"$'\n'"4321"* ]]
}

@test "install.sh: configure-kimi creates valid hook blocks and is idempotent" {
    install_dir="$TEST_TEMP_DIR/install/bin"
    config="$TEST_TEMP_DIR/kimi/config.toml"

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-kimi --kimi-config "$config"
    [ "$status" -eq 0 ]
    [ -x "$install_dir/notify-kimi-code.sh" ]
    [ -f "$config" ]
    [ "$(grep -c '^\[\[hooks\]\]$' "$config")" -eq 4 ]
    [ "$(grep -c '^command = .*notify-kimi-code\.sh' "$config")" -eq 4 ]
    grep -q '^event = "Stop"$' "$config"
    grep -q '^event = "PermissionRequest"$' "$config"
    grep -q '^event = "StopFailure"$' "$config"
    grep -q '^event = "Notification"$' "$config"

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-kimi --kimi-config "$config"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
    [ "$(grep -c '^\[\[hooks\]\]$' "$config")" -eq 4 ]
}

@test "install.sh: configure-kimi backs up an existing config" {
    install_dir="$TEST_TEMP_DIR/install/bin"
    config="$TEST_TEMP_DIR/kimi/config.toml"
    mkdir -p "$(dirname "$config")"
    printf 'default_model = "kimi"\n' >"$config"

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-kimi --kimi-config "$config"

    [ "$status" -eq 0 ]
    backup="$(find "$(dirname "$config")" -type f -name 'config.toml.bak.*' | head -n 1)"
    [ -n "$backup" ]
    grep -q '^default_model = "kimi"$' "$backup"
    grep -q '^\[\[hooks\]\]$' "$config"
}

@test "install.sh: configure-kimi preserves a root inline hooks value" {
    install_dir="$TEST_TEMP_DIR/install/bin"
    config="$TEST_TEMP_DIR/kimi/config.toml"
    mkdir -p "$(dirname "$config")"
    printf 'hooks = []\n' >"$config"

    run "$PROJECT_ROOT/install.sh" --bindir "$install_dir" --copy \
        --configure-kimi --kimi-config "$config"

    [ "$status" -eq 0 ]
    [[ "$output" == *"top-level hooks= value; not modifying"* ]]
    [ "$(cat "$config")" = "hooks = []" ]
}
