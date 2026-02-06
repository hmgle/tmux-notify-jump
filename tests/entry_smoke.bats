#!/usr/bin/env bats
# Smoke tests for entry/platform scripts using --dry-run and error paths.

load 'test_helper'

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

@test "tmux-notify-jump-linux.sh: dry-run includes common and linux fields" {
    run "$PROJECT_ROOT/tmux-notify-jump-linux.sh" \
        --focus-only \
        --dry-run \
        --title "hello" \
        --body "world" \
        --ui notification \
        --wrap-cols 40 \
        --timeout 1234

    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: focus-only"* ]]
    [[ "$output" == *"Title: hello"* ]]
    [[ "$output" == *"Body: world"* ]]
    [[ "$output" == *"UI: notification"* ]]
    [[ "$output" == *"Wrap columns: 40"* ]]
    [[ "$output" == *"Timeout: 1234"* ]]
}

@test "tmux-notify-jump-macos.sh: dry-run includes common and macOS fields" {
    run "$PROJECT_ROOT/tmux-notify-jump-macos.sh" \
        --focus-only \
        --dry-run \
        --title "hello" \
        --body "world" \
        --ui dialog \
        --bundle-ids "com.github.wez.wezterm,com.apple.Terminal" \
        --timeout 2345

    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: focus-only"* ]]
    [[ "$output" == *"Title: hello"* ]]
    [[ "$output" == *"Body: world"* ]]
    [[ "$output" == *"UI: dialog"* ]]
    [[ "$output" == *"Bundle ids: com.github.wez.wezterm,com.apple.Terminal"* ]]
    [[ "$output" == *"Timeout: 2345"* ]]
}

@test "tmux-notify-jump-linux.sh: invalid --ui fails with shared validator" {
    run "$PROJECT_ROOT/tmux-notify-jump-linux.sh" --focus-only --ui invalid-ui

    [ "$status" -ne 0 ]
    [[ "$output" == *"--ui must be one of: notification, dialog"* ]]
}

@test "tmux-notify-jump-macos.sh: invalid --timeout fails with shared validator" {
    run "$PROJECT_ROOT/tmux-notify-jump-macos.sh" --focus-only --timeout abc

    [ "$status" -ne 0 ]
    [[ "$output" == *"--timeout must be a non-negative integer (ms)"* ]]
}

@test "tmux-notify-jump-macos.sh: wait-mode non-zero with payload does not fall back to -execute" {
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/terminal-notifier" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "-help" ]; then
    echo "-wait"
    exit 0
fi

# Simulate: notification showed, then timeout/close -> non-zero + JSON payload
if printf '%s\n' "$*" | grep -q -- "-wait"; then
    printf '{"activationType":"timeout","activationValue":""}'
    exit 1
fi

exit 0
FAKE
    chmod +x "$fake_bin/terminal-notifier"

    cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
echo "unexpected tmux call" >&2
exit 99
FAKE
    chmod +x "$fake_bin/tmux"

    run env PATH="$fake_bin:$PATH" "$PROJECT_ROOT/tmux-notify-jump-macos.sh" \
        --focus-only \
        --ui notification \
        --no-activate \
        --title "hello" \
        --body "world"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Notification sent"* ]]
}

@test "install.sh: unknown option returns error" {
    run "$PROJECT_ROOT/install.sh" --definitely-unknown-option

    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}
