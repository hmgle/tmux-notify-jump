#!/usr/bin/env bats

load 'test_helper'

setup() {
    setup_temp_dir
    export TMUX_NOTIFY_CONFIG="$TEST_TEMP_DIR/no-config"
    plugin_dir="$TEST_TEMP_DIR/plugins"
}

teardown() {
    teardown_temp_dir
}

@test "OpenCode installer adds the TUI plugin and converts symlinks to copies" {
    mkdir -p "$plugin_dir"
    ln -s "$PROJECT_ROOT/opencode-plugin/tmux-notify-jump.ts" "$plugin_dir/tmux-notify-jump.ts"

    run "$PROJECT_ROOT/install.sh" --prefix "$TEST_TEMP_DIR/install" --symlink \
        --configure-opencode --opencode-plugin-path "$plugin_dir"
    assert_equals 0 "$status" "$output"
    [ "$plugin_dir/tmux-notify-jump-client" -ef "$PROJECT_ROOT/opencode-plugin/client" ]
    [ ! -e "$TEST_TEMP_DIR/install/bin/opencode-mini" ]
    [ ! -L "$TEST_TEMP_DIR/install/bin/opencode-mini" ]

    run "$PROJECT_ROOT/install.sh" --prefix "$TEST_TEMP_DIR/install" --copy \
        --configure-opencode --opencode-plugin-path "$plugin_dir"
    assert_equals 0 "$status" "$output"
    [ ! -e "$TEST_TEMP_DIR/install/bin/opencode-mini" ]
    [ ! -L "$TEST_TEMP_DIR/install/bin/notify-opencode.sh" ]
    cmp "$PROJECT_ROOT/notify-opencode.sh" "$TEST_TEMP_DIR/install/bin/notify-opencode.sh"
    [ ! -L "$plugin_dir/tmux-notify-jump-client" ]
    cmp "$PROJECT_ROOT/opencode-plugin/client/tui.ts" "$plugin_dir/tmux-notify-jump-client/tui.ts"
    [ ! -L "$plugin_dir/tmux-notify-jump.ts" ]
    cmp "$PROJECT_ROOT/opencode-plugin/tmux-notify-jump.ts" "$plugin_dir/tmux-notify-jump.ts"
}
