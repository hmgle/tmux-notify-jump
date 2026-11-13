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
    jq -e '.hooks.PermissionRequest[0].hooks[0].async == true' "$CFG"
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
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
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

@test "Codex hooks installer preserves empty prompt and agent handlers" {
    mkdir -p "${CFG%/*}"
    cat >"$CFG" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"prompt"},{"type":"agent"}]}],"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"agent"},{"type":"prompt"}]}]}}
JSON
    cp "$CFG" "$TEST_TEMP_DIR/original.json"
    install_hooks
    [ "$status" -eq 0 ]
    jq -e '.hooks.PermissionRequest | length == 2 and .[1].hooks[0].async == true' "$CFG"
    jq 'del(.hooks.PermissionRequest[1])' "$CFG" >"$TEST_TEMP_DIR/preserved.json"
    run jq -e --slurp '.[0] == .[1]' "$TEST_TEMP_DIR/original.json" "$TEST_TEMP_DIR/preserved.json"
    [ "$status" -eq 0 ]
    cmp "$TEST_TEMP_DIR/original.json" "$CFG.bak."*
    before="$(cat "$CFG")"
    install_hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *'already configured'* ]]
    [ "$(cat "$CFG")" = "$before" ]
}

@test "Codex installation honors CODEX_HOME for config and hooks" {
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
    export CODEX_HOME="$TEST_TEMP_DIR/custom codex"
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
        --configure-codex --configure-codex-hooks
    [ "$status" -eq 0 ]
    rg -q '^notify = ' "$CODEX_HOME/config.toml"
    jq -e '.hooks.PermissionRequest | length == 1' "$CODEX_HOME/hooks.json"
    [ ! -e "$HOME/.codex" ]
}

@test "Codex explicit config and hooks paths override CODEX_HOME" {
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
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
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
    export CODEX_HOME=''
    run "$PROJECT_ROOT/install.sh" --bindir "$TEST_TEMP_DIR/bin" \
        --configure-codex --configure-codex-hooks
    [ "$status" -eq 0 ]
    [ -f "$HOME/.codex/config.toml" ]
    [ -f "$HOME/.codex/hooks.json" ]
}

@test "Codex installer upgrades its synchronous hook without duplicating handlers" {
    install_hooks
    [ "$status" -eq 0 ]
    jq '.hooks.PermissionRequest[0].matcher = "Bash" |
        .hooks.PermissionRequest[0].hooks[0] |= (.async = false | .timeout = 3 | .statusMessage = "keep") |
        .hooks.PermissionRequest[0].hooks += [{type:"command",command:"unrelated",async:false}]' \
        "$CFG" >"$TEST_TEMP_DIR/sync.json"
    cp "$TEST_TEMP_DIR/sync.json" "$CFG"
    install_hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *'trust the new definition with /hooks'* ]]
    jq -e '.hooks.PermissionRequest | length == 1 and
        .[0].matcher == "Bash" and (.[0].hooks | length == 2 and
        .[0].async == true and .[0].timeout == 3 and .[0].statusMessage == "keep" and
        .[1].command == "unrelated" and .[1].async == false)' "$CFG"
    cmp "$TEST_TEMP_DIR/sync.json" "$CFG.bak."*
    before="$(cat "$CFG")"
    install_hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *'already configured'* ]]
    [ "$(cat "$CFG")" = "$before" ]
    jq 'del(.hooks.PermissionRequest[0].hooks[0].async)' "$CFG" >"$TEST_TEMP_DIR/no-async.json"
    cp "$TEST_TEMP_DIR/no-async.json" "$CFG"
    install_hooks
    [ "$status" -eq 0 ]
    jq -e '.hooks.PermissionRequest[0].hooks[0].async == true' "$CFG"
}

@test "Codex hooks installer refuses inline TOML hooks without touching either source" {
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
    export CODEX_CONFIG_PATH="$TEST_TEMP_DIR/profile/config.toml"
    mkdir -p "${CODEX_CONFIG_PATH%/*}" "${CFG%/*}"
    printf '{"hooks":{}}\n' >"$CFG"
    local content
    while IFS= read -r content; do
        printf '%s\n' "$content" >"$CODEX_CONFIG_PATH"
        install_hooks
        [ "$status" -ne 0 ]
        [[ "$output" == *'contains inline hooks'*'Merge PermissionRequest manually into one hook source'* ]]
        [ "$(cat "$CODEX_CONFIG_PATH")" = "$content" ]
        [ "$(cat "$CFG")" = '{"hooks":{}}' ]
        [ ! -e "$CFG.bak."* ]
        [ ! -e "$CFG.tmp."* ]
        [ ! -e "$CODEX_CONFIG_PATH.bak."* ]
    done <<'TOML'
[[hooks.Stop]]
hooks = { Stop = [{ hooks = [{ type = "command", command = "notify-codex.sh" }] }] }
"hooks".Stop = [{}]
"\u0068ooks" = { PermissionRequest = [{ hooks = [{ type = "command", command = "notify-codex.sh" }] }] }
TOML
    rm "$CFG"
    install_hooks
    [ "$status" -ne 0 ]
    [ ! -e "$CFG" ]
}

@test "Codex hooks installer accepts empty inline events without modifying TOML" {
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
    mkdir -p "${CFG%/*}"
    local content
    while IFS= read -r content; do
        printf '%s\n' "$content" >"${CFG%/*}/config.toml"
        install_hooks
        [ "$status" -eq 0 ]
        jq -e '.hooks.PermissionRequest | length == 1' "$CFG"
        [ "$(cat "${CFG%/*}/config.toml")" = "$content" ]
        [ ! -e "${CFG%/*}/config.toml.bak."* ]
        [ ! -e "$CFG.bak."* ]
    done <<'TOML'
[hooks]
hooks = {}
"hooks".Stop = []
"\u0068ooks" = { PermissionRequest = [], Stop = [] }
TOML
}

@test "Codex hooks installer remains idempotent and upgrades async after trust" {
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
    install_hooks
    [ "$status" -eq 0 ]
    cat >"${CFG%/*}/config.toml" <<'TOML'
[hooks.state."PermissionRequest:trusted-hook"]
enabled = true
trusted_hash = "sha256:keep-this-trust-hash"
[hooks.state."Stop:disabled-hook"]
enabled = false
TOML
    cp "${CFG%/*}/config.toml" "$TEST_TEMP_DIR/trusted.toml"
    before="$(cat "$CFG")"
    install_hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *'already configured'* ]]
    [ "$(cat "$CFG")" = "$before" ]
    [ ! -e "$CFG.bak."* ]
    jq '.hooks.PermissionRequest[0].hooks[0].async = false' "$CFG" >"$TEST_TEMP_DIR/sync.json"
    cp "$TEST_TEMP_DIR/sync.json" "$CFG"
    install_hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *'trust the new definition with /hooks'* ]]
    jq -e '.hooks.PermissionRequest | length == 1 and .[0].hooks[0].async == true' "$CFG"
    cmp "$TEST_TEMP_DIR/sync.json" "$CFG.bak."*
    install_hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *'already configured'* ]]
    cmp "$TEST_TEMP_DIR/trusted.toml" "${CFG%/*}/config.toml"
    [ ! -e "${CFG%/*}/config.toml.bak."* ]
}

@test "Codex hook trust state does not hide nonempty inline event groups" {
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
    mkdir -p "${CFG%/*}"
    cat >"${CFG%/*}/config.toml" <<'TOML'
[[hooks.Stop]]
hooks = [{type = "command", command = "notify-codex.sh"}]
[hooks.state."Stop:trusted-hook"]
trusted_hash = "sha256:keep"
TOML
    install_hooks
    [ "$status" -ne 0 ]
    [[ "$output" == *'contains inline hooks'* ]]
    [ ! -e "$CFG" ]
}

@test "Codex hooks installer checks TOML beside an explicit hooks path" {
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
    mkdir -p "${CFG%/*}" "$TEST_TEMP_DIR/target"
    printf '[[hooks.PermissionRequest]]\nhooks = [{type="command",command="notify-codex.sh"}]\n' >"${CFG%/*}/config.toml"
    printf '{"hooks":{}}\n' >"$TEST_TEMP_DIR/target/hooks.json"
    ln -s "$TEST_TEMP_DIR/target/hooks.json" "$CFG"
    install_hooks
    [ "$status" -ne 0 ]
    [[ "$output" == *'contains inline hooks'*"${CFG%/*}/config.toml"* ]]
    [ -L "$CFG" ]
    [ "$(cat "$CFG")" = '{"hooks":{}}' ]
    [ ! -e "$TEST_TEMP_DIR/target/hooks.json.bak."* ]
}

@test "Codex hooks installer ignores hook text in comments strings and other tables" {
    python3 -c 'import tomllib' 2>/dev/null || skip 'Existing TOML inspection needs Python 3.11+'
    mkdir -p "${CFG%/*}"
    cat >"${CFG%/*}/config.toml" <<'TOML'
# [hooks]
model_instructions = '''
[hooks]
[[hooks.Stop]]
'''
[features]
hooks = false
[other.hooks]
value = "keep"
TOML
    cp "${CFG%/*}/config.toml" "$TEST_TEMP_DIR/original.toml"
    install_hooks
    [ "$status" -eq 0 ]
    jq -e '.hooks.PermissionRequest | length == 1' "$CFG"
    cmp "$TEST_TEMP_DIR/original.toml" "${CFG%/*}/config.toml"
    [ ! -e "${CFG%/*}/config.toml.bak."* ]
}

@test "Codex hooks installer refuses unchecked TOML but JSON-only installs need no Python" {
    mkdir -p "${CFG%/*}"
    printf '[invalid' >"${CFG%/*}/config.toml"
    install_hooks
    [ "$status" -ne 0 ]
    [[ "$output" == *'Cannot check Codex config for inline hooks'* ]]
    [ ! -e "$CFG" ]
    mkdir -p "$TEST_TEMP_DIR/stubs"
    printf '#!/usr/bin/env bash\nexit 1\n' >"$TEST_TEMP_DIR/stubs/python3"
    chmod +x "$TEST_TEMP_DIR/stubs/python3"
    export PATH="$TEST_TEMP_DIR/stubs:$PATH"
    printf 'model = "keep"\n' >"${CFG%/*}/config.toml"
    install_hooks
    [ "$status" -ne 0 ]
    [[ "$output" == *'need valid TOML and Python 3.11+'* ]]
    [ ! -e "$CFG" ]
    [ "$(cat "${CFG%/*}/config.toml")" = 'model = "keep"' ]
    rm "${CFG%/*}/config.toml"
    install_hooks
    [ "$status" -eq 0 ]
    jq -e '.hooks.PermissionRequest | length == 1' "$CFG"
}
