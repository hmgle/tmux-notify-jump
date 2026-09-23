#!/usr/bin/env bats
# Smoke tests for install.sh --configure-step extension-directory resolution.

load 'test_helper'

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

# Run install.sh --configure-step with an isolated HOME and a scrubbed step
# environment; extra arguments are forwarded to env(1) as VAR=value pairs.
install_step() {
    run env \
        -u STEP_EXTENSION_PATH -u STEP_CODING_AGENT_DIR -u STEPCODE_CONFIG_DIR \
        HOME="$TEST_TEMP_DIR/home" \
        "$@" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --symlink --configure-step
}

@test "configure-step: installs into ~/.stepcode/agent/extensions" {
    install_step

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
    [ "$(readlink "$link")" = "$PROJECT_ROOT/step-extension/tmux-notify-jump.ts" ]
}

@test "configure-step: a second run reports the extension as already installed" {
    install_step
    [ "$status" -eq 0 ]

    install_step

    [ "$status" -eq 0 ]
    [[ "$output" == *"Step Code extension already installed"* ]]
    link="$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts"
    [ ! -e "$link.bak."* ]
}

@test "configure-step: STEPCODE_CONFIG_DIR renames the project directory" {
    install_step STEPCODE_CONFIG_DIR=.scode2

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.scode2/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-step: STEP_CODING_AGENT_DIR overrides the agent dir" {
    install_step STEP_CODING_AGENT_DIR="$TEST_TEMP_DIR/custom-agent"

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/custom-agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-step: STEP_CODING_AGENT_DIR expands a leading tilde" {
    install_step STEP_CODING_AGENT_DIR='~/tilt-agent'

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/tilt-agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
    [ ! -e "$TEST_TEMP_DIR/~/tilt-agent" ]
}

@test "configure-step: --step-extension-path wins over agent dir resolution" {
    run env \
        -u STEPCODE_CONFIG_DIR \
        HOME="$TEST_TEMP_DIR/home" STEP_CODING_AGENT_DIR="$TEST_TEMP_DIR/custom-agent" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --symlink --configure-step \
        --step-extension-path "$TEST_TEMP_DIR/explicit"

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/explicit/tmux-notify-jump.ts"
    [ -L "$link" ]
    [ ! -e "$TEST_TEMP_DIR/custom-agent/extensions" ]
}

@test "configure-step: whitespace-only STEP_CODING_AGENT_DIR falls back to the default" {
    install_step 'STEP_CODING_AGENT_DIR=   '

    [ "$status" -eq 0 ]
    # step trims before reading the value, so a blank override is ignored
    # rather than becoming a path relative to the filesystem root.
    link="$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
    [ ! -e "/extensions" ]
}

@test "configure-step: whitespace-only STEPCODE_CONFIG_DIR keeps .stepcode" {
    install_step 'STEPCODE_CONFIG_DIR=  '

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-step: surrounding whitespace is trimmed from the agent dir" {
    install_step "STEP_CODING_AGENT_DIR=  $TEST_TEMP_DIR/padded-agent  "

    [ "$status" -eq 0 ]
    link="$TEST_TEMP_DIR/padded-agent/extensions/tmux-notify-jump.ts"
    [ -L "$link" ]
}

@test "configure-step: an existing foreign extension is backed up, not deleted" {
    mkdir -p "$TEST_TEMP_DIR/home/.stepcode/agent/extensions"
    echo '// mine' >"$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts"

    install_step

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts.bak."*)" = "// mine" ]
    [ -L "$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts" ]
}

@test "configure-step: copy mode installs a real file" {
    run env \
        -u STEP_EXTENSION_PATH -u STEP_CODING_AGENT_DIR -u STEPCODE_CONFIG_DIR \
        HOME="$TEST_TEMP_DIR/home" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --copy --configure-step

    [ "$status" -eq 0 ]
    ext="$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts"
    [ -f "$ext" ]
    [ ! -L "$ext" ]
}

@test "configure-step: uninstall removes the installed extension" {
    install_step
    [ "$status" -eq 0 ]

    run env \
        -u STEP_EXTENSION_PATH -u STEP_CODING_AGENT_DIR -u STEPCODE_CONFIG_DIR \
        HOME="$TEST_TEMP_DIR/home" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --symlink \
        --uninstall --configure-step

    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed Step Code extension"* ]]
    [ ! -e "$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts" ]
    [ ! -e "$TEST_TEMP_DIR/prefix/bin/notify-step.sh" ]
}

@test "configure-step: uninstall removes a --copy install too" {
    run env \
        -u STEP_EXTENSION_PATH -u STEP_CODING_AGENT_DIR -u STEPCODE_CONFIG_DIR \
        HOME="$TEST_TEMP_DIR/home" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --copy --configure-step
    [ "$status" -eq 0 ]
    ext="$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts"
    [ -f "$ext" ]
    [ ! -L "$ext" ]

    run env \
        -u STEP_EXTENSION_PATH -u STEP_CODING_AGENT_DIR -u STEPCODE_CONFIG_DIR \
        HOME="$TEST_TEMP_DIR/home" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --symlink --uninstall --configure-step

    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed Step Code extension"* ]]
    [ ! -e "$ext" ]
}

@test "configure-step: uninstall works without readlink -f or python3" {
    install_step
    [ "$status" -eq 0 ]

    fake_bin="$TEST_TEMP_DIR/limited-bin"
    mkdir -p "$fake_bin"

    # A readlink that rejects -f (BSD-style) plus a broken python3: neither
    # can resolve a path the way GNU readlink -f does, so ownership has to be
    # decided without them.
    cat >"$fake_bin/readlink" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "-f" ]; then
    echo "readlink: illegal option -- f" >&2
    exit 1
fi
exec /usr/bin/readlink "$@"
FAKE
    chmod +x "$fake_bin/readlink"

    cat >"$fake_bin/python3" <<'FAKE'
#!/usr/bin/env bash
echo "python3 unavailable" >&2
exit 127
FAKE
    chmod +x "$fake_bin/python3"

    run env \
        -u STEP_EXTENSION_PATH -u STEP_CODING_AGENT_DIR -u STEPCODE_CONFIG_DIR \
        PATH="$fake_bin:$PATH" \
        HOME="$TEST_TEMP_DIR/home" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --symlink --uninstall --configure-step

    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed Step Code extension"* ]]
    [ ! -e "$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts" ]
}

@test "configure-step: a second run is idempotent without readlink -f or python3" {
    install_step
    [ "$status" -eq 0 ]

    fake_bin="$TEST_TEMP_DIR/limited-install-bin"
    mkdir -p "$fake_bin"

    cat >"$fake_bin/readlink" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "-f" ]; then
    exit 1
fi
exec /usr/bin/readlink "$@"
FAKE
    chmod +x "$fake_bin/readlink"

    cat >"$fake_bin/python3" <<'FAKE'
#!/usr/bin/env bash
exit 127
FAKE
    chmod +x "$fake_bin/python3"

    ext_dir="$TEST_TEMP_DIR/home/.stepcode/agent/extensions"
    run env \
        -u STEP_EXTENSION_PATH -u STEP_CODING_AGENT_DIR -u STEPCODE_CONFIG_DIR \
        PATH="$fake_bin:$PATH" \
        HOME="$TEST_TEMP_DIR/home" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --symlink --configure-step

    [ "$status" -eq 0 ]
    [[ "$output" == *"Step Code extension already installed"* ]]
    [ -z "$(find "$ext_dir" -maxdepth 1 -name 'tmux-notify-jump.ts.bak.*' -print -quit)" ]
}

@test "configure-step: uninstall keeps an extension it did not install" {
    install_step
    [ "$status" -eq 0 ]
    rm -f "$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts"
    echo '// mine' >"$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts"

    run env \
        -u STEP_EXTENSION_PATH -u STEP_CODING_AGENT_DIR -u STEPCODE_CONFIG_DIR \
        HOME="$TEST_TEMP_DIR/home" \
        "$PROJECT_ROOT/install.sh" \
        --prefix "$TEST_TEMP_DIR/prefix" --symlink \
        --uninstall --configure-step

    [ "$status" -eq 0 ]
    [[ "$output" == *"Keeping unrelated Step Code extension"* ]]
    [ "$(cat "$TEST_TEMP_DIR/home/.stepcode/agent/extensions/tmux-notify-jump.ts")" = "// mine" ]
}
