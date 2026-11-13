#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    command -v jq >/dev/null || skip 'jq is not installed'
    export HOME="$TEST_TEMP_DIR/home"
    unset CODEX_CONFIG_PATH CODEX_HOOKS_PATH
    CFG="$TEST_TEMP_DIR/config/hooks.json"
}

teardown() { teardown_temp_dir; }

install_hooks() {
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin with ' quote" \
        --configure-codex-hooks --codex-hooks-path "$CFG" "$@"
}

@test "Codex hooks installer adds only approval and is idempotent" {
    install_hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *'trust the new definition with /hooks'* ]]
    jq -e '.hooks | keys == ["PermissionRequest"]' "$CFG"
    command="$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' "$CFG")"
    run bash -c "$command" </dev/null
    [ "$status" -eq 0 ]
    before="$(cat "$CFG")"
    install_hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *'already configured'* ]]
    [ "$(cat "$CFG")" = "$before" ]
    [ ! -e "$CFG.bak."* ]
}

@test "Codex hooks installer preserves existing hooks and symlinks with a backup" {
    mkdir -p "$TEST_TEMP_DIR/target" "${CFG%/*}"
    target="$TEST_TEMP_DIR/target/hooks.json"
    printf '{"description":"keep","hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing"}]}]}}\n' >"$target"
    ln -s "$target" "$CFG"
    install_hooks
    [ "$status" -eq 0 ]
    [ -L "$CFG" ]
    jq -e '.description == "keep" and .hooks.Stop[0].hooks[0].command == "existing"' "$target"
    [ -f "$target.bak."* ]
}

@test "Codex hooks installer refuses malformed and incompatible configs" {
    mkdir -p "${CFG%/*}"
    local content
    for content in invalid '[]' '{"hooks":[]}' '{"hooks":{"PermissionRequest":{}}}'; do
        printf '%s' "$content" >"$CFG"
        install_hooks
        [ "$status" -ne 0 ]
        [ "$(cat "$CFG")" = "$content" ]
        [ ! -e "$CFG.bak."* ]
    done
}

@test "Codex hooks default path follows the explicit Codex config directory" {
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
        --configure-codex --configure-codex-hooks --codex-config "$TEST_TEMP_DIR/profile/config.toml"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/profile/hooks.json" ]
    rg -q '^notify = ' "$TEST_TEMP_DIR/profile/config.toml"
    [ ! -e "$HOME/.codex/hooks.json" ]
}
