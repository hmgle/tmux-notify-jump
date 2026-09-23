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
