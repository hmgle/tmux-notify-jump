#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    export HOME="$TEST_TEMP_DIR/home"
    unset CODEX_HOME CODEX_CONFIG_PATH CODEX_HOOKS_PATH
    command -v jq >/dev/null || skip 'jq is not installed'
    command -v timeout >/dev/null || skip 'timeout is needed for blocking regressions'
    mkdir -p "$TEST_TEMP_DIR/config"
    mkfifo "$TEST_TEMP_DIR/fifo"
    mkdir "$TEST_TEMP_DIR/directory"
    ln -s "$TEST_TEMP_DIR/fifo" "$TEST_TEMP_DIR/fifo-link"
    ln -s "$TEST_TEMP_DIR/directory" "$TEST_TEMP_DIR/directory-link"
    ln -s /dev/null "$TEST_TEMP_DIR/device-link"
}

teardown() { teardown_temp_dir; }

assert_rejected_config() {
    [ "$status" -eq 1 ]
    [[ "$output" == *'not a regular file; not modifying'* ]]
    [[ "$output" != *'Created Codex config'* ]]
    [[ "$output" != *'Configured Codex'* ]]
    [ -p "$TEST_TEMP_DIR/fifo" ]
    [ -d "$TEST_TEMP_DIR/directory" ]
    [ -L "$TEST_TEMP_DIR/fifo-link" ]
    [ -L "$TEST_TEMP_DIR/directory-link" ]
    [ -L "$TEST_TEMP_DIR/device-link" ]
    [ -c /dev/null ]
    [ ! -e "$TEST_TEMP_DIR/config/hooks.json" ]
    local artifacts
    artifacts="$(find "$TEST_TEMP_DIR" \( -name '*.bak.*' -o -name '*.tmp.*' \) -print)"
    [ -z "$artifacts" ]
}

@test "Codex config entry points reject nonregular paths before reading or writing" {
    local flag target
    for flag in --configure-codex --configure-codex-hooks; do
        for target in "$TEST_TEMP_DIR/fifo" "$TEST_TEMP_DIR/directory" /dev/null \
            "$TEST_TEMP_DIR/fifo-link" "$TEST_TEMP_DIR/directory-link" "$TEST_TEMP_DIR/device-link"; do
            run timeout 5 "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
                "$flag" --codex-config "$target" \
                --codex-hooks-path "$TEST_TEMP_DIR/config/hooks.json"
            assert_rejected_config
        done
    done
}

@test "Codex hooks reject nonregular sibling TOML before parsing" {
    local target
    for target in "$TEST_TEMP_DIR/fifo" "$TEST_TEMP_DIR/directory" /dev/null; do
        ln -s "$target" "$TEST_TEMP_DIR/config/config.toml"
        run timeout 5 "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
            --configure-codex-hooks --codex-hooks-path "$TEST_TEMP_DIR/config/hooks.json"
        assert_rejected_config
        [ -L "$TEST_TEMP_DIR/config/config.toml" ]
        [ "$(readlink "$TEST_TEMP_DIR/config/config.toml")" = "$target" ]
        rm "$TEST_TEMP_DIR/config/config.toml"
    done
    mkfifo "$TEST_TEMP_DIR/config/config.toml"
    run timeout 5 "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
        --configure-codex-hooks --codex-hooks-path "$TEST_TEMP_DIR/config/hooks.json"
    assert_rejected_config
    [ -p "$TEST_TEMP_DIR/config/config.toml" ]
}

@test "Codex config entry points reject dangling symlinks" {
    ln -s "$TEST_TEMP_DIR/missing.toml" "$TEST_TEMP_DIR/config/config.toml"
    local flag
    for flag in --configure-codex --configure-codex-hooks; do
        run timeout 5 "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
            "$flag" --codex-config "$TEST_TEMP_DIR/config/config.toml"
        [ "$status" -eq 1 ]
        [[ "$output" == *'Codex config symlink is dangling'* ]]
        [ -L "$TEST_TEMP_DIR/config/config.toml" ]
        [ ! -e "$TEST_TEMP_DIR/missing.toml" ]
        [ ! -e "$TEST_TEMP_DIR/config/hooks.json" ]
    done
}

@test "Standalone Codex notify installation reports explicit config discovery limits" {
    export CODEX_CONFIG_PATH="$TEST_TEMP_DIR/env/config.toml"
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" --configure-codex
    [ "$status" -eq 0 ]
    [[ "$output" == *'path overrides do not register a config folder'* ]]
    [ -f "$CODEX_CONFIG_PATH" ]
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" --configure-codex \
        --codex-config "$TEST_TEMP_DIR/cli/config.toml"
    [ "$status" -eq 0 ]
    [[ "$output" == *'path overrides do not register a config folder'* ]]
    [ -f "$TEST_TEMP_DIR/cli/config.toml" ]
    before="$(cat "$TEST_TEMP_DIR/cli/config.toml")"
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" --configure-codex \
        --codex-config "$TEST_TEMP_DIR/cli/config.toml"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Codex already configured'* ]]
    [[ "$output" == *'path overrides do not register a config folder'* ]]
    [ "$(cat "$TEST_TEMP_DIR/cli/config.toml")" = "$before" ]
}

@test "Standalone Codex notify ignores an unused hooks override for discovery notices" {
    export CODEX_HOME="$TEST_TEMP_DIR/codex-home"
    export CODEX_HOOKS_PATH="$TEST_TEMP_DIR/unused/hooks.json"
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" --configure-codex
    [ "$status" -eq 0 ]
    [[ "$output" != *'path overrides do not register a config folder'* ]]
    [ -f "$CODEX_HOME/config.toml" ]
    [ ! -e "$CODEX_HOOKS_PATH" ]
}
