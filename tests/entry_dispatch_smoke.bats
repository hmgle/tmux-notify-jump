#!/usr/bin/env bats
load 'test_helper'
bats_require_minimum_version 1.5.0

setup() {
    setup_temp_dir
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/env"
    # Bound exec loops even when each re-exec replaces the process under test.
    cat >"$TMUX_NOTIFY_CONFIG" <<'CONFIG'
ENTRY_TEST_LOADS="$(cat "$TEST_TEMP_DIR/config-count" 2>/dev/null || echo 0)"
if [ "$ENTRY_TEST_LOADS" -ge 8 ]; then
    echo "entrypoint dispatch loop" >&2
    exit 99
fi
printf '%s\n' "$((ENTRY_TEST_LOADS + 1))" >"$TEST_TEMP_DIR/config-count"
CONFIG
    unset TMUX_NOTIFY_JUMP_SH _TMUX_NOTIFY_JUMP_OVERRIDE_ACTIVE
    entry_dir="$TEST_TEMP_DIR/entry with spaces"
    mkdir -p "$entry_dir" "$TEST_TEMP_DIR/bin"
    cp "$PROJECT_ROOT/tmux-notify-jump" "$entry_dir/"
    ln -s "$PROJECT_ROOT/tmux-notify-jump-lib.sh" "$entry_dir/"
    for platform in linux macos; do
        cat >"$entry_dir/tmux-notify-jump-$platform.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${_TMUX_NOTIFY_JUMP_OVERRIDE_ACTIVE:-}" ]
printf '%s\n' "${0##*/}"
printf '<%s>\n' "$@"
FAKE
        chmod +x "$entry_dir/tmux-notify-jump-$platform.sh"
    done
    cat >"$TEST_TEMP_DIR/bin/uname" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${TEST_OS:-Linux}"
FAKE
    chmod +x "$TEST_TEMP_DIR/bin/uname"
    export PATH="$TEST_TEMP_DIR/bin:$entry_dir:$PATH"
    export TEST_OS=Linux
    entry="$entry_dir/tmux-notify-jump"
}

teardown() {
    teardown_temp_dir
}

assert_linux_dispatch() {
    rm -f "$TEST_TEMP_DIR/config-count"
    run "$entry" --focus-only --dry-run --title "hello world" --body ""
    [ "$status" -eq 0 ]
    [ "$output" = $'tmux-notify-jump-linux.sh\n<--focus-only>\n<--dry-run>\n<--title>\n<hello world>\n<--body>\n<>' ]
}

@test "entry dispatch: unset and empty overrides use the native platform" {
    assert_linux_dispatch
    export TMUX_NOTIFY_JUMP_SH=""
    assert_linux_dispatch
    export TEST_OS=Darwin
    run "$entry" --help
    [ "$status" -eq 0 ]
    [ "$output" = $'tmux-notify-jump-macos.sh\n<--help>' ]
}

@test "Inbox picker rejects invalid options through entry and both platforms" {
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/no-config"
    for script in "$PROJECT_ROOT/tmux-notify-jump" \
        "$PROJECT_ROOT/tmux-notify-jump-linux.sh" "$PROJECT_ROOT/tmux-notify-jump-macos.sh"; do
        run "$script" --inbox-pick --kind invalid
        [ "$status" -eq 1 ]
        [[ "$output" == *'--kind must be attention or complete'* ]]
        run "$script" --inbox-pick --since yesterday
        [ "$status" -eq 1 ]
        run "$script" --inbox-pick --session
        [ "$status" -eq 1 ]
        [[ "$output" == *'--session requires an argument'* ]]
    done
}

@test "entry dispatch: absolute self-reference uses the native platform" {
    export TMUX_NOTIFY_JUMP_SH="$entry"
    assert_linux_dispatch
    export TEST_OS=Darwin
    run "$entry" --help
    [ "$status" -eq 0 ]
    [ "$output" = $'tmux-notify-jump-macos.sh\n<--help>' ]
}

@test "entry dispatch: relative self-reference uses the native platform" {
    cd "$entry_dir"
    export TMUX_NOTIFY_JUMP_SH=./tmux-notify-jump
    assert_linux_dispatch
}

@test "entry dispatch: PATH self-reference uses the native platform" {
    export TMUX_NOTIFY_JUMP_SH=tmux-notify-jump
    assert_linux_dispatch
}

@test "entry dispatch: symlink and hardlink self-references skip re-exec" {
    # These aliases have no co-located library, so executing them would fail.
    ln -s "$entry" "$TEST_TEMP_DIR/bin/symlink-entry"
    ln "$entry" "$TEST_TEMP_DIR/bin/hardlink-entry"
    for alias in symlink-entry hardlink-entry; do
        export TMUX_NOTIFY_JUMP_SH="$TEST_TEMP_DIR/bin/$alias"
        assert_linux_dispatch
        export TMUX_NOTIFY_JUMP_SH="$alias"
        assert_linux_dispatch
    done
}

@test "entry dispatch: self-reference loaded from config skips re-exec" {
    printf 'TMUX_NOTIFY_JUMP_SH=%q\nprintf "loaded\\n" >>%q\n' \
        "$entry" "$TEST_TEMP_DIR/config-loads" >>"$TMUX_NOTIFY_CONFIG"
    assert_linux_dispatch
    [ "$(cat "$TEST_TEMP_DIR/config-loads")" = "loaded" ]
}

@test "entry dispatch: custom executable preserves arguments and exit status" {
    cat >"$TEST_TEMP_DIR/bin/custom backend" <<'FAKE'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
exit 23
FAKE
    chmod +x "$TEST_TEMP_DIR/bin/custom backend"
    for override in "$TEST_TEMP_DIR/bin/custom backend" "custom backend"; do
        export TMUX_NOTIFY_JUMP_SH="$override"
        run "$entry" --title "hello world" --body ""
        [ "$status" -eq 23 ]
        [ "$output" = $'<--title>\n<hello world>\n<--body>\n<>' ]
    done
}

@test "entry dispatch: platform override still selects the requested backend" {
    export TMUX_NOTIFY_JUMP_SH="$PROJECT_ROOT/tmux-notify-jump-macos.sh"
    run "$entry" --focus-only --dry-run --bundle-ids com.apple.Terminal
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: focus-only"* ]]
    [[ "$output" == *"Bundle ids: com.apple.Terminal"* ]]
}

@test "entry dispatch: an override that execs the entrypoint runs only once" {
    cat >"$TEST_TEMP_DIR/bin/redirect" <<'FAKE'
#!/usr/bin/env bash
printf 'override\n' >>"$TEST_TEMP_DIR/override-calls"
exec "$TMUX_NOTIFY_ENTRYPOINT" "$@"
FAKE
    chmod +x "$TEST_TEMP_DIR/bin/redirect"
    printf 'TMUX_NOTIFY_JUMP_SH=%q\n' "$TEST_TEMP_DIR/bin/redirect" >>"$TMUX_NOTIFY_CONFIG"
    assert_linux_dispatch
    [ "$(cat "$TEST_TEMP_DIR/override-calls")" = "override" ]
}

@test "entry dispatch: an override that spawns the entrypoint runs only once" {
    cat >"$TEST_TEMP_DIR/bin/redirect" <<'FAKE'
#!/usr/bin/env bash
printf 'override\n' >>"$TEST_TEMP_DIR/override-calls"
"$TMUX_NOTIFY_ENTRYPOINT" "$@"
exit $?
FAKE
    chmod +x "$TEST_TEMP_DIR/bin/redirect"
    export TMUX_NOTIFY_JUMP_SH="$TEST_TEMP_DIR/bin/redirect"
    assert_linux_dispatch
    [ "$(cat "$TEST_TEMP_DIR/override-calls")" = "override" ]
}

@test "entry dispatch: a copied entrypoint cannot loop through an override" {
    cp "$entry" "$entry_dir/entry-copy"
    export TMUX_NOTIFY_JUMP_SH="$entry_dir/entry-copy"
    assert_linux_dispatch
}

@test "entry dispatch: missing overrides still report an execution failure" {
    for override in "$TEST_TEMP_DIR/missing-backend" missing-tmux-notify-backend; do
        export TMUX_NOTIFY_JUMP_SH="$override"
        run -127 "$entry" --help
        [ "$status" -eq 127 ]
        [[ "$output" == *"$override"* ]]
    done
}
