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

@test "tmux-notify-jump-linux.sh: awesome-client receives inline window id" {
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/zenity" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    chmod +x "$fake_bin/zenity"

    cat >"$fake_bin/xdotool" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
    search)
        printf '12345\n'
        exit 0
        ;;
    windowactivate)
        printf 'windowactivate %s\n' "$2" >>"$TEST_TEMP_DIR/xdotool.log"
        exit 0
        ;;
esac
exit 0
FAKE
    chmod +x "$fake_bin/xdotool"

    cat >"$fake_bin/xprop" <<'FAKE'
#!/usr/bin/env bash
if [ "$3" = "WM_STATE" ]; then
    printf 'WM_STATE(WM_STATE):\n'
    exit 0
fi
exit 1
FAKE
    chmod +x "$fake_bin/xprop"

    cat >"$fake_bin/awesome-client" <<'FAKE'
#!/usr/bin/env bash
payload="$(cat)"
printf '%s' "$payload" >"$TEST_TEMP_DIR/awesome-client.lua"
if printf '%s' "$payload" | grep -q 'local target = 12345'; then
    exit 0
fi
printf 'missing inline target' >&2
exit 1
FAKE
    chmod +x "$fake_bin/awesome-client"

    run env PATH="$fake_bin:$PATH" TEST_TEMP_DIR="$TEST_TEMP_DIR" \
        "$PROJECT_ROOT/tmux-notify-jump-linux.sh" \
        --focus-only \
        --sender-pid 4242 \
        --dedupe-ms 0 \
        --ui dialog \
        --title "hello" \
        --body "world"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Focused terminal"* ]]
    run cat "$TEST_TEMP_DIR/awesome-client.lua"
    [ "$status" -eq 0 ]
    [[ "$output" == *"local target = 12345"* ]]
    [[ "$output" != *'os.getenv("TMUX_NOTIFY_AWESOME_WINDOW_ID")'* ]]
    [ ! -f "$TEST_TEMP_DIR/xdotool.log" ]
}

@test "tmux-notify-jump-linux.sh: missing xdotool still allows awesome-client activation" {
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"
    ln -s /bin/bash "$fake_bin/bash"
    ln -s /usr/bin/dirname "$fake_bin/dirname"

    cat >"$fake_bin/zenity" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    chmod +x "$fake_bin/zenity"

    cat >"$fake_bin/awesome-client" <<'FAKE'
#!/usr/bin/env bash
payload="$(</dev/stdin)"
printf '%s' "$payload" >"$TEST_TEMP_DIR/awesome-client-no-xdotool.lua"
exit 0
FAKE
    chmod +x "$fake_bin/awesome-client"

    run env PATH="$fake_bin" TMUX_NOTIFY_WINDOW_ID=24680 TEST_TEMP_DIR="$TEST_TEMP_DIR" \
        "$PROJECT_ROOT/tmux-notify-jump-linux.sh" \
        --focus-only \
        --dedupe-ms 0 \
        --ui dialog \
        --title "hello" \
        --body "world"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Focused terminal"* ]]
    [[ "$output" == *"Missing xdotool; falling back to awesome-client-only activation"* ]]
    run cat "$TEST_TEMP_DIR/awesome-client-no-xdotool.lua"
    [ "$status" -eq 0 ]
    [[ "$output" == *"local target = 24680"* ]]
}

@test "tmux-notify-jump-linux.sh: detach forwards focus-only sender pid" {
    fake_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/notify-send" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    chmod +x "$fake_bin/notify-send"

    cat >"$fake_bin/setsid" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$TMUX_NOTIFY_ALREADY_DETACHED" >"$TEST_TEMP_DIR/setsid.env"
printf '%s\n' "$@" >"$TEST_TEMP_DIR/setsid.args"
exit 0
FAKE
    chmod +x "$fake_bin/setsid"

    cat >"$TEST_TEMP_DIR/invoke-parent.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$TEST_TEMP_DIR/expected_parent_pid"
"$PROJECT_ROOT/tmux-notify-jump-linux.sh" "$@"
FAKE
    chmod +x "$TEST_TEMP_DIR/invoke-parent.sh"

    run env PATH="$fake_bin:$PATH" TEST_TEMP_DIR="$TEST_TEMP_DIR" PROJECT_ROOT="$PROJECT_ROOT" \
        "$TEST_TEMP_DIR/invoke-parent.sh" \
        --focus-only \
        --detach \
        --no-activate \
        --dedupe-ms 0 \
        --title "hello" \
        --body "world"

    [ "$status" -eq 0 ]

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$TEST_TEMP_DIR/setsid.args" ] && break
        sleep 0.1
    done

    [ -f "$TEST_TEMP_DIR/setsid.args" ]
    run cat "$TEST_TEMP_DIR/expected_parent_pid"
    [ "$status" -eq 0 ]
    expected_parent_pid="$output"

    run cat "$TEST_TEMP_DIR/setsid.args"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--focus-only"* ]]
    [[ "$output" == *"--sender-pid"* ]]
    [[ "$output" == *"$expected_parent_pid"* ]]

    run cat "$TEST_TEMP_DIR/setsid.env"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "install.sh: unknown option returns error" {
    run "$PROJECT_ROOT/install.sh" --definitely-unknown-option

    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}
