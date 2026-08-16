#!/usr/bin/env bats
#
# Integration coverage for the acknowledgement hooks against a real tmux
# server.
#
# The rest of the suite stubs tmux_cmd, which pins the command strings this
# tool installs but never the semantics tmux gives them. Formats such as
# #{hook_client} expand differently per hook family, so only a live server can
# show whether an installed hook actually fires and clears an Inbox entry.

load 'test_helper'

TMUX_SERVER_SOCKET=""

start_tmux_server() {
    # -f /dev/null keeps the developer's own tmux configuration out of the run.
    tmux -S "$TMUX_SERVER_SOCKET" -f /dev/null \
        new-session -d -s main -n home -x 80 -y 24 'sleep 300'
    tmux -S "$TMUX_SERVER_SOCKET" new-window -d -t main: -n worker 'sleep 300'
}

# Print the pane a client lands on when it selects the worker window.
worker_active_pane() {
    tmux -S "$TMUX_SERVER_SOCKET" list-panes -t main:worker \
        -F '#{pane_id} #{pane_active}' | awk '$2 == 1 { print $1 }'
}

inbox_count() {
    tmux -S "$TMUX_SERVER_SOCKET" show-option -gqv "@tmux-notify-jump-$1"
}

# Print the prefix-table lines that carry an Inbox jump binding.
jump_bindings() {
    tmux -S "$TMUX_SERVER_SOCKET" list-keys -T prefix | rg -F -- '--inbox-next' || true
}

# Hooks run through `run-shell -b`, so the count converges asynchronously.
wait_for_inbox_count() {
    local name="$1" expected="$2" attempt=0
    while [ "$attempt" -lt 100 ]; do
        [ "$(inbox_count "$name")" != "$expected" ] || return 0
        attempt=$((attempt + 1))
        sleep 0.1
    done
    echo "timed out waiting for $name count to reach $expected"
    echo "  actual: $(inbox_count "$name")"
    return 1
}

setup() {
    command -v tmux >/dev/null 2>&1 || skip "tmux is not installed"

    setup_temp_dir
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"
    # Neutralize any developer config file; the entry point loads one by default.
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/absent-env"
    TMUX_SERVER_SOCKET="$TEST_TEMP_DIR/tmux.sock"
    export TMUX_NOTIFY_TMUX_SOCKET="$TMUX_SERVER_SOCKET"
    unset TMUX TMUX_PANE TMUX_NOTIFY_TMUX_KEY

    local major=""
    major="$(tmux_notify_tmux_major_version)"
    if [ -n "$major" ] && [ "$major" -lt 3 ]; then
        skip "tmux 3.0 or newer is required for acknowledgement hooks"
    fi

    start_tmux_server
    "$PROJECT_ROOT/tmux-notify-jump" --tmux-init >/dev/null
}

teardown() {
    if [ -n "$TMUX_SERVER_SOCKET" ]; then
        tmux -S "$TMUX_SERVER_SOCKET" kill-server 2>/dev/null || true
    fi
    teardown_temp_dir
}

@test "selecting a window acknowledges that pane's Inbox entry" {
    pane="$(worker_active_pane)"
    tmux_notify_inbox_enqueue "$pane" complete Codex "Build finished"
    [ "$(inbox_count complete)" = "1" ]

    tmux -S "$TMUX_SERVER_SOCKET" select-window -t main:worker

    wait_for_inbox_count complete 0
    root="$(tmux_notify_inbox_root)"
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' -print -quit)" ]
}

@test "selecting a pane acknowledges that pane's Inbox entry" {
    tmux -S "$TMUX_SERVER_SOCKET" split-window -d -t main:worker 'sleep 300'
    tmux -S "$TMUX_SERVER_SOCKET" select-window -t main:worker
    other_pane="$(tmux -S "$TMUX_SERVER_SOCKET" list-panes -t main:worker \
        -F '#{pane_id} #{pane_active}' | awk '$2 == 0 { print $1; exit }')"
    tmux_notify_inbox_enqueue "$other_pane" attention Claude "Permission needed"
    [ "$(inbox_count attention)" = "1" ]

    tmux -S "$TMUX_SERVER_SOCKET" select-pane -t "$other_pane"

    wait_for_inbox_count attention 0
}

@test "selecting an unrelated pane leaves other Inbox entries armed" {
    pane="$(worker_active_pane)"
    tmux_notify_inbox_enqueue "$pane" complete Codex "Build finished"

    tmux -S "$TMUX_SERVER_SOCKET" select-window -t main:home

    # The acknowledgement runs but must not clear a pane the client never saw.
    run wait_for_inbox_count complete 0
    [ "$status" -eq 1 ]
    [ "$(inbox_count complete)" = "1" ]
}

@test "an empty Inbox leaves the select hooks inert" {
    [ "$(inbox_count complete)" = "0" ]

    tmux -S "$TMUX_SERVER_SOCKET" select-window -t main:worker

    # The format guard short-circuits before tmux spawns the script at all.
    root="$(tmux_notify_inbox_root)"
    [ ! -d "$root" ] || [ -z "$(find "$root" -mindepth 1 -print -quit)" ]
}

@test "uninit removes the hooks it installed from a live server" {
    pane="$(worker_active_pane)"
    tmux_notify_inbox_enqueue "$pane" complete Codex "Build finished"

    "$PROJECT_ROOT/tmux-notify-jump" --tmux-uninit >/dev/null

    run tmux -S "$TMUX_SERVER_SOCKET" show-hooks -g
    [ "$status" -eq 0 ]
    [[ "$output" != *'--inbox-ack-pane'* ]]
    [[ "$output" != *'--inbox-ack-client'* ]]
    run tmux -S "$TMUX_SERVER_SOCKET" list-keys -T prefix
    [ "$status" -eq 0 ]
    [[ "$output" != *'--inbox-next'* ]]
}

@test "init retires a jump binding naming an earlier install path" {
    # setup() bound prefix+N against $PROJECT_ROOT. Re-run init as if the tool
    # had been reinstalled under a different --bindir: the stale binding still
    # fires, and breaks as soon as the old install is removed.
    TMUX_NOTIFY_ENTRYPOINT="$TEST_TEMP_DIR/relocated/tmux-notify-jump"
    tmux_notify_tmux_init >/dev/null

    bindings="$(jump_bindings)"
    [ "$(printf '%s\n' "$bindings" | rg -c . )" = "1" ]
    [[ "$bindings" == *"$TEST_TEMP_DIR/relocated/tmux-notify-jump --inbox-next"* ]]
    [[ "$bindings" != *"$PROJECT_ROOT/tmux-notify-jump --inbox-next"* ]]
}

@test "init moves its jump binding when the configured key changes" {
    TMUX_NOTIFY_ENTRYPOINT="$PROJECT_ROOT/tmux-notify-jump"
    tmux -S "$TMUX_SERVER_SOCKET" set-option -g @tmux-notify-jump-key A

    tmux_notify_tmux_init >/dev/null

    bindings="$(jump_bindings)"
    [ "$(printf '%s\n' "$bindings" | rg -c . )" = "1" ]
    [[ "$bindings" == *' -T prefix A '* ]]
}

@test "uninit removes a jump binding the key option no longer names" {
    TMUX_NOTIFY_ENTRYPOINT="$PROJECT_ROOT/tmux-notify-jump"
    # Leave the binding on N while the option names A, the state a key change
    # produced before init learned to migrate it.
    tmux -S "$TMUX_SERVER_SOCKET" set-option -g @tmux-notify-jump-key A
    [ -n "$(jump_bindings)" ]

    "$PROJECT_ROOT/tmux-notify-jump" --tmux-uninit >/dev/null

    [ -z "$(jump_bindings)" ]
}

@test "init leaves a hook slot it does not own unchanged" {
    "$PROJECT_ROOT/tmux-notify-jump" --tmux-uninit >/dev/null
    tmux -S "$TMUX_SERVER_SOCKET" set-hook -g 'after-select-pane[900]' \
        'display-message user-hook'

    run env -u _QUIET "$PROJECT_ROOT/tmux-notify-jump" --tmux-init
    [ "$status" -eq 0 ]
    [[ "$output" == *'after-select-pane[900] is already set'* ]]

    run tmux -S "$TMUX_SERVER_SOCKET" show-hooks -g
    [ "$status" -eq 0 ]
    [[ "$output" == *'after-select-pane[900] display-message user-hook'* ]]
    # The other four slots were free, so acknowledgement still installs there.
    [ "$(printf '%s\n' "$output" | rg -c -- '--inbox-ack-')" = "4" ]
}

@test "uninit leaves a foreign hook slot in place" {
    "$PROJECT_ROOT/tmux-notify-jump" --tmux-uninit >/dev/null
    tmux -S "$TMUX_SERVER_SOCKET" set-hook -g 'after-select-pane[900]' \
        'display-message user-hook'
    "$PROJECT_ROOT/tmux-notify-jump" --tmux-init >/dev/null

    "$PROJECT_ROOT/tmux-notify-jump" --tmux-uninit >/dev/null

    run tmux -S "$TMUX_SERVER_SOCKET" show-hooks -g
    [ "$status" -eq 0 ]
    [[ "$output" == *'after-select-pane[900] display-message user-hook'* ]]
    [[ "$output" != *'--inbox-ack-'* ]]
}
