#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    export HOME="$TEST_TEMP_DIR/home"
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/config/env"
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"
    export TMUX_NOTIFY_TMUX_SOCKET="$TEST_TEMP_DIR/tmux.sock"
    unset TMUX TMUX_PANE TMUX_NOTIFY_TMUX_STATUS
    mkdir -p "$TEST_TEMP_DIR/bin" "${TMUX_NOTIFY_CONFIG%/*}"
    printf '# user configuration\n' >"$TMUX_NOTIFY_CONFIG"
    FAKE_ROOT="$TEST_TEMP_DIR/cache/tmux-notify-jump/inbox/4242"
    FAKE_VERSION='3.7c'
    unset FAKE_CLIENT_VERSION
    FAKE_RUNNING=1
    FAKE_STATUS="$(tmux_notify_tmux_status_segment)"
    FAKE_HOOKS=1
    FAKE_BINDING='bind-key -T prefix N run-shell -b "tmux-notify-jump --inbox-next"'
    FAKE_OS=Linux
    for tool in tmux fzf jq ps notify-send xdotool; do
        printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TEMP_DIR/bin/$tool"
    done
    chmod +x "$TEST_TEMP_DIR/bin/"*
    printf '#!/usr/bin/env bash\ncat\n' >"$TEST_TEMP_DIR/bin/fzf"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

teardown() {
    teardown_temp_dir
}

uname() { printf '%s\n' "$FAKE_OS"; }

tmux_cmd() {
    printf '%s\n' "$*" >>"$TEST_TEMP_DIR/tmux.calls"
    case "$1" in
        -V) printf 'tmux %s\n' "${FAKE_CLIENT_VERSION:-$FAKE_VERSION}" ;;
        display-message)
            [ "$FAKE_RUNNING" -eq 1 ] || return 1
            case "$3" in
                '#{pid}') printf '4242\n' ;;
                '#{socket_path}') printf '%s\n' "$TMUX_NOTIFY_TMUX_SOCKET" ;;
                '#{version}') printf '%s\n' "$FAKE_VERSION" ;;
            esac
            ;;
        show-option)
            case "$3" in
                @tmux-notify-jump-inbox-root) printf '%s' "$FAKE_ROOT" ;;
                @tmux-notify-jump-key) printf '%s' "${FAKE_KEY:-}" ;;
                status-right) printf '%s' "$FAKE_STATUS" ;;
            esac
            ;;
        show-hooks)
            [ "$FAKE_HOOKS" -eq 1 ] || return 0
            for hook in client-attached client-session-changed after-select-pane after-select-window client-focus-in; do
                printf '%s[900] run-shell "tmux-notify-jump --inbox-ack-pane %%9"\n' "$hook"
            done
            ;;
        list-keys) printf '%s\n' "$FAKE_BINDING" ;;
        *) printf 'Unexpected mutation: %s\n' "$*" >&2; return 99 ;;
    esac
}

@test "doctor reports initialized integration without changing tmux or cache" {
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'popup and menu supported'* ]]
    [[ "$output" == *'not created yet'* ]]
    [[ "$output" == *'installed in global status-right'* ]]
    [[ "$output" == *'prefix+N jumps to next item'* ]]
    [ "$(printf '%s\n' "$output" | rg -c 'acknowledgement installed')" -eq 5 ]
    [ ! -e "$FAKE_ROOT" ]
    [ "$(cat "$TMUX_NOTIFY_CONFIG")" = '# user configuration' ]
    run rg '^(set-|refresh-|bind-|mkdir|chmod)' "$TEST_TEMP_DIR/tmux.calls"
    [ "$status" -eq 1 ]
}

@test "doctor warns about missing opt-in integration and old tmux" {
    FAKE_VERSION='2.9a'
    FAKE_ROOT=''
    FAKE_STATUS='user status'
    FAKE_HOOKS=0
    FAKE_BINDING='bind-key -T prefix N display-message user-command'
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'not initialized'* ]]
    [[ "$output" == *'menus and acknowledgement hooks need tmux 3.0'* ]]
    [[ "$output" == *'missing or customized'* ]]
    [[ "$output" == *'prefix+N belongs to another command'* ]]
    [ "$(printf '%s\n' "$output" | rg -c 'acknowledgement missing')" -eq 5 ]
}

@test "doctor accepts development tmux version strings" {
    FAKE_VERSION='next-3.9'

    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'popup and menu supported'* ]]
    [[ "$output" != *'menus and acknowledgement hooks need tmux 3.0'* ]]
}

@test "doctor checks the server version even with a newer client binary" {
    FAKE_VERSION='2.9a'
    FAKE_CLIENT_VERSION='next-3.9'

    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'tmux executable'*'next-3.9'* ]]
    [[ "$output" == *'menus and acknowledgement hooks need tmux 3.0'* ]]
    [[ "$output" != *'popup and menu supported'* ]]
}

@test "doctor reports unsafe permissions without repairing them" {
    mkdir -p "$FAKE_ROOT"
    chmod 755 "$FAKE_ROOT"
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'FAIL Inbox permissions'* ]]
    [ "$(stat -c '%a' "$FAKE_ROOT" 2>/dev/null || stat -f '%Lp' "$FAKE_ROOT")" = 755 ]

    chmod 700 "$FAKE_ROOT"
    mkdir -m 700 "$FAKE_ROOT/1"
    printf 'attention\n' >"$FAKE_ROOT/1/kind"
    chmod 644 "$FAKE_ROOT/1/kind"
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'unsafe entry ownership, permissions or symlinks'* ]]
    chmod 600 "$FAKE_ROOT/1/kind"
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'directories 700, files 600'* ]]
}

@test "doctor rejects invalid pinned roots and entry symlinks" {
    FAKE_ROOT="$TEST_TEMP_DIR/foreign"
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid; using default path'* ]]
    [ ! -e "$FAKE_ROOT" ]
    FAKE_ROOT="$TEST_TEMP_DIR/cache/tmux-notify-jump/inbox/4242"
    mkdir -p "$FAKE_ROOT"
    chmod 700 "$FAKE_ROOT"
    ln -s "$TMUX_NOTIFY_CONFIG" "$FAKE_ROOT/1"
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [ -L "$FAKE_ROOT/1" ]
}

@test "doctor reports a missing server even without TMUX in the environment" {
    FAKE_RUNNING=0
    run tmux_notify_doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'tmux server'*'not reachable'* ]]
    [[ "$output" != *'unbound variable'* ]]
    [[ "$output" != *'Wrapper codex'* ]]
    [[ "$output" != *'picker options supported'* ]]
}

@test "doctor supports disabled status and macOS dependencies without requiring them" {
    TMUX_NOTIFY_TMUX_STATUS=0
    FAKE_OS=Darwin
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'disabled by TMUX_NOTIFY_TMUX_STATUS'* ]]
    [[ "$output" == *'terminal-notifier'* ]]
    [[ "$output" == *'osascript'* ]]
    [[ "$output" != *'X11 display'* ]]
}

@test "doctor sanitizes terminal controls in diagnostic values" {
    TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/absent"$'\e[31m\nconfig'
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\e'* ]]
    [[ "$output" == *'absent [31m config'* ]]
}

@test "doctor identifies missing HOME and explicit empty configuration as unset" {
    unset HOME TMUX_NOTIFY_CONFIG
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'Configuration'*'(unset) using environment/defaults'* ]]
    export HOME="$TEST_TEMP_DIR/home" TMUX_NOTIFY_CONFIG=''
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'Configuration'*'(unset) using environment/defaults'* ]]
}

@test "doctor probes fzf options without executing a preview or changing Inbox state" {
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'picker options supported'* ]]
    printf '#!/usr/bin/env bash\nexit 2\n' >"$TEST_TEMP_DIR/bin/fzf"
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'picker options unsupported'* ]]
    [ ! -e "$FAKE_ROOT" ]
}

@test "doctor checks all wrapper files and optional configuration references" {
    mkdir -p "$HOME/.claude" "$HOME/.codex"
    printf '{"hooks":{"Stop":[{"hooks":[{"command":"notify-claude-code.sh"}]}]}}\n' >"$HOME/.claude/settings.json"
    printf 'model = "custom"\n' >"$HOME/.codex/config.toml"
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | rg -c 'Wrapper .*executable')" -eq 8 ]
    [[ "$output" == *'Config claude'*'wrapper text reference found; registration unverified'* ]]
    [[ "$output" == *'Config codex'*'no wrapper text reference'* ]]
    [[ "$output" == *'Config kimi'*'absent or unreadable'* ]]
}

@test "doctor warns about missing and nonexecutable wrappers without repairing them" {
    mkdir -p "$TEST_TEMP_DIR/installed"
    cp "$PROJECT_ROOT/tmux-notify-jump-lib.sh" "$TEST_TEMP_DIR/installed/tmux-notify-jump-lib.sh"
    printf '#!/usr/bin/env bash\n' >"$TEST_TEMP_DIR/installed/notify-codex.sh"
    chmod 600 "$TEST_TEMP_DIR/installed/notify-codex.sh"
    source "$TEST_TEMP_DIR/installed/tmux-notify-jump-lib.sh"
    run tmux_notify_doctor_agents
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | rg -c 'missing or not executable')" -eq 8 ]
    [ ! -x "$TEST_TEMP_DIR/installed/notify-codex.sh" ]
}

@test "doctor accepts explicit profile config paths and rejects unknown agents" {
    cfg="$TEST_TEMP_DIR/custom profile.ts"
    printf 'const cmd = "notify-omp.sh";\n' >"$cfg"
    run tmux_notify_doctor_cli --agent-config "omp=$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$cfg (wrapper text reference found; registration unverified)"* ]]
    run tmux_notify_doctor_cli --agent-config "unknown=$cfg"
    [ "$status" -eq 1 ]
    [[ "$output" == 'Error: Unknown doctor agent: unknown' ]]
    run tmux_notify_doctor_cli --agent-config
    [ "$status" -eq 1 ]
}

@test "doctor reports a jump key the option names and its live binding" {
    FAKE_KEY='u'
    FAKE_BINDING='bind-key -T prefix u run-shell -b "tmux-notify-jump --inbox-next"'
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'prefix+u jumps to next item'* ]]
}

@test "doctor resolves the jump key from the environment like init does" {
    # TMUX_NOTIFY_KEY feeds initialization, so reporting the option value alone
    # could name a key that was never bound.
    FAKE_KEY='u'
    FAKE_BINDING='bind-key -T prefix v run-shell -b "tmux-notify-jump --inbox-next"'
    TMUX_NOTIFY_KEY='v'
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'prefix+v jumps to next item'* ]]

    TMUX_NOTIFY_TMUX_KEY='b'
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *'prefix+b missing'* ]]
}

@test "doctor reports a configured key that cannot name a tmux key" {
    FAKE_KEY='C-n'
    # test_helper exports _QUIET=1, which suppresses warn(); the entry point
    # runs without it, so drop it to see what a user would see.
    unset _QUIET
    run tmux_notify_doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"Inbox key 'C-n' is not one alphanumeric character"* ]]
    # The fallback is reported, so the binding shown is the one in effect.
    [[ "$output" == *'prefix+N jumps to next item'* ]]
}

@test "doctor rejects malformed config specs before printing diagnostics or querying tmux" {
    for spec in bogus=/x codex= codex /x =/x; do
        run tmux_notify_doctor_cli --agent-config "$spec"
        [ "$status" -eq 1 ]
        [[ "$output" == Error:* ]]
        [[ "$output" != *'diagnostics'* ]]
        [ ! -f "$TEST_TEMP_DIR/tmux.calls" ]
    done
    run tmux_notify_doctor bogus=/x
    [ "$status" -eq 1 ]
    [[ "$output" != *'diagnostics'* ]]
}
