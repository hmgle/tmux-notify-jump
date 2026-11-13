#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    command -v jq >/dev/null || skip 'jq is not installed'
    export HOME="$TEST_TEMP_DIR/home"
    unset CODEX_CONFIG_PATH CODEX_HOOKS_PATH CODEX_HOME
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

@test "Codex hooks installer validates every nested event before editing" {
    mkdir -p "${CFG%/*}"
    local content
    while IFS= read -r content; do
        printf '%s' "$content" >"$CFG"
        install_hooks
        [ "$status" -ne 0 ]
        [[ "$output" == *'incompatible schema; not modifying'* ]]
        [ "$(cat "$CFG")" = "$content" ]
        [ ! -e "$CFG.bak."* ]
        [ ! -e "$CFG.tmp."* ]
    done <<'JSON'
{"hooks":{"PermissionRequest":[null]}}
{"hooks":{"PermissionRequest":[{"hooks":null}]}}
{"hooks":{"PermissionRequest":[{"hooks":[null]}]}}
{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":7}]}]}}
{"hooks":{"PermissionRequest":[]},"description":false}
{"hooks":{"Stop":null}}
{"hooks":{"Stop":[{"matcher":false}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"command"}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo ok","async":null}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo ok","timeout":-1}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo ok","timeout":1.5}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo ok","statusMessage":0}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo ok","additionalContextLimit":"5"}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo ok","commandWindows":false}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo ok","commandWindows":"a","command_windows":"b"}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"mcp_tool","server":"test"}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"mcp_tool","server":"test","tool":"log","input":{"nested":[null]}}]}]}}
{"hooks":{"Stop":[{"hooks":[{"type":"unknown","command":"echo ok"}]}]}}
{"hooks":{"FutureEvent":[]}}
{"hooks":null}
{} {}
JSON
}

@test "Codex hooks installer preserves supported command and MCP configurations" {
    mkdir -p "${CFG%/*}"
    cat >"$CFG" <<'JSON'
{"description":null,"hooks":{"Stop":[{"matcher":null,"hooks":[{"type":"command","command":"echo ok","command_windows":"echo windows","async":false,"timeout":null,"statusMessage":null,"additionalContextLimit":0},{"type":"mcp_tool","server":"test","tool":"log","input":{"nested":[true,3,"ok",{"key":"value"}]},"timeout":5}]}],"SessionStart":[{}]}}
JSON
    jq '.hooks' "$CFG" >"$TEST_TEMP_DIR/expected-hooks"
    install_hooks
    [ "$status" -eq 0 ]
    jq 'del(.hooks.PermissionRequest) | .hooks' "$CFG" >"$TEST_TEMP_DIR/actual-hooks"
    cmp "$TEST_TEMP_DIR/expected-hooks" "$TEST_TEMP_DIR/actual-hooks"
}

@test "Codex installation honors CODEX_HOME for config and hooks" {
    export CODEX_HOME="$TEST_TEMP_DIR/custom codex"
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
        --configure-codex --configure-codex-hooks
    [ "$status" -eq 0 ]
    rg -q '^notify = ' "$CODEX_HOME/config.toml"
    jq -e '.hooks.PermissionRequest | length == 1' "$CODEX_HOME/hooks.json"
    [ ! -e "$HOME/.codex" ]
}

@test "Codex explicit config and hooks paths override CODEX_HOME" {
    export CODEX_HOME="$TEST_TEMP_DIR/unused-codex"
    export CODEX_CONFIG_PATH="$TEST_TEMP_DIR/env-profile/config.toml"
    export CODEX_HOOKS_PATH="$TEST_TEMP_DIR/env-hooks.json"
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
        --configure-codex --configure-codex-hooks
    [ "$status" -eq 0 ]
    [ -f "$CODEX_CONFIG_PATH" ]
    [ -f "$CODEX_HOOKS_PATH" ]
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
        --configure-codex --configure-codex-hooks \
        --codex-config "$TEST_TEMP_DIR/cli-profile/config.toml" --codex-hooks-path "$CFG"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/cli-profile/config.toml" ]
    [ -f "$CFG" ]
    [ ! -e "$CODEX_HOME" ]
}

@test "Codex empty CODEX_HOME falls back to HOME" {
    export CODEX_HOME=''
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
        --configure-codex --configure-codex-hooks
    [ "$status" -eq 0 ]
    [ -f "$HOME/.codex/config.toml" ]
    [ -f "$HOME/.codex/hooks.json" ]
}
