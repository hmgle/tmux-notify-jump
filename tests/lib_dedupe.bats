#!/usr/bin/env bats
# Tests for deduplication functions

load 'test_helper'

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

# =============================================================================
# read_timestamp_file() tests
# =============================================================================

@test "read_timestamp_file: returns timestamp from valid file" {
    echo "1234567890" > "$TEST_TEMP_DIR/test.ts"
    result="$(read_timestamp_file "$TEST_TEMP_DIR/test.ts")"
    [ "$result" = "1234567890" ]
}

@test "read_timestamp_file: returns empty for missing file" {
    result="$(read_timestamp_file "$TEST_TEMP_DIR/nonexistent.ts")"
    [ "$result" = "" ]
}

@test "read_timestamp_file: returns empty for invalid content" {
    echo "not-a-number" > "$TEST_TEMP_DIR/test.ts"
    result="$(read_timestamp_file "$TEST_TEMP_DIR/test.ts")"
    [ "$result" = "" ]
}

@test "read_timestamp_file: handles file with trailing newline" {
    printf '9876543210\n' > "$TEST_TEMP_DIR/test.ts"
    result="$(read_timestamp_file "$TEST_TEMP_DIR/test.ts")"
    [ "$result" = "9876543210" ]
}

# =============================================================================
# write_timestamp_file() tests
# =============================================================================

@test "write_timestamp_file: creates file with timestamp" {
    write_timestamp_file "$TEST_TEMP_DIR/test.ts" "1234567890"
    [ -f "$TEST_TEMP_DIR/test.ts" ]
    content="$(cat "$TEST_TEMP_DIR/test.ts")"
    [ "$content" = "1234567890" ]
}

@test "write_timestamp_file: overwrites existing file" {
    echo "old_value" > "$TEST_TEMP_DIR/test.ts"
    write_timestamp_file "$TEST_TEMP_DIR/test.ts" "9999999999"
    content="$(cat "$TEST_TEMP_DIR/test.ts")"
    [ "$content" = "9999999999" ]
}

# =============================================================================
# is_within_window() tests
# =============================================================================

@test "is_within_window: returns success when within window" {
    run is_within_window "1000" "1500" "1000"
    [ "$status" -eq 0 ]
}

@test "is_within_window: returns failure when outside window" {
    run is_within_window "1000" "3000" "1000"
    [ "$status" -ne 0 ]
}

@test "is_within_window: returns failure for empty last" {
    run is_within_window "" "1500" "1000"
    [ "$status" -ne 0 ]
}

@test "is_within_window: returns failure for zero last" {
    run is_within_window "0" "1500" "1000"
    [ "$status" -ne 0 ]
}

@test "is_within_window: returns failure for negative delta" {
    run is_within_window "2000" "1000" "1000"
    [ "$status" -ne 0 ]
}

@test "is_within_window: boundary case - exactly at window edge" {
    run is_within_window "1000" "2000" "1000"
    [ "$status" -ne 0 ]  # delta == window means outside
}

@test "is_within_window: boundary case - one ms before edge" {
    run is_within_window "1000" "1999" "1000"
    [ "$status" -eq 0 ]  # delta = 999 < 1000
}

# =============================================================================
# acquire_lock() / release_lock() tests
# =============================================================================

@test "acquire_lock: acquires fresh lock" {
    acquire_lock "$TEST_TEMP_DIR/test.lock"
    [ "${_LOCK_ACQUIRED:-0}" -eq 1 ]
    [ -d "$TEST_TEMP_DIR/test.lock" ]
    [ -f "$TEST_TEMP_DIR/test.lock/pid" ]
}

@test "acquire_lock: fails when lock exists with valid pid" {
    mkdir -p "$TEST_TEMP_DIR/test.lock"
    echo "$$" > "$TEST_TEMP_DIR/test.lock/pid"  # current process pid
    acquire_lock "$TEST_TEMP_DIR/test.lock" || true
    [ "${_LOCK_ACQUIRED:-0}" -eq 0 ]
}

@test "release_lock: removes lock directory" {
    mkdir -p "$TEST_TEMP_DIR/test.lock"
    echo "$$" > "$TEST_TEMP_DIR/test.lock/pid"
    release_lock "$TEST_TEMP_DIR/test.lock"
    [ ! -d "$TEST_TEMP_DIR/test.lock" ]
}

# =============================================================================
# gc_should_run() tests
# =============================================================================

@test "gc_should_run: returns success when gc file missing" {
    run gc_should_run "$TEST_TEMP_DIR/.gc.ts" "1000000" "86400000"
    [ "$status" -eq 0 ]
}

@test "gc_should_run: returns failure when gc ran recently" {
    echo "999999" > "$TEST_TEMP_DIR/.gc.ts"
    run gc_should_run "$TEST_TEMP_DIR/.gc.ts" "1000000" "86400000"
    [ "$status" -ne 0 ]
}

@test "gc_should_run: returns success when gc is old" {
    echo "1" > "$TEST_TEMP_DIR/.gc.ts"
    run gc_should_run "$TEST_TEMP_DIR/.gc.ts" "100000000" "86400000"
    [ "$status" -eq 0 ]
}

# =============================================================================
# gc_purge_expired() tests
# =============================================================================

@test "gc_purge_expired: removes expired entries" {
    echo "100" > "$TEST_TEMP_DIR/old.ts"
    echo "999999999" > "$TEST_TEMP_DIR/new.ts"
    gc_purge_expired "$TEST_TEMP_DIR" "1000000000" "1000"
    [ ! -f "$TEST_TEMP_DIR/old.ts" ]
    [ -f "$TEST_TEMP_DIR/new.ts" ]
}

@test "gc_purge_expired: preserves gc marker file" {
    echo "100" > "$TEST_TEMP_DIR/.gc.ts"
    gc_purge_expired "$TEST_TEMP_DIR" "1000000000" "1000"
    [ -f "$TEST_TEMP_DIR/.gc.ts" ]
}

@test "gc_purge_expired: removes files with invalid content" {
    echo "not-a-number" > "$TEST_TEMP_DIR/invalid.ts"
    gc_purge_expired "$TEST_TEMP_DIR" "1000000000" "1000"
    [ ! -f "$TEST_TEMP_DIR/invalid.ts" ]
}

# =============================================================================
# dedupe_should_suppress() tests
# =============================================================================

@test "dedupe_should_suppress: first call allows, second within window suppresses" {
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"

    NOW_MS="1000"
    now_ms() { printf '%s' "$NOW_MS"; }

    run dedupe_should_suppress "2000" "key-1"
    [ "$status" -eq 1 ]  # allow (not suppressed)

    NOW_MS="1500"
    run dedupe_should_suppress "2000" "key-1"
    [ "$status" -eq 0 ]  # suppress (duplicate)

    NOW_MS="4000"
    run dedupe_should_suppress "2000" "key-1"
    [ "$status" -eq 1 ]  # allow again (outside window)
}

@test "dedupe_should_suppress: window 0 disables dedupe and does not create cache dir" {
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"

    NOW_MS="1000"
    now_ms() { printf '%s' "$NOW_MS"; }

    run dedupe_should_suppress "0" "key-2"
    [ "$status" -eq 1 ]
    [ ! -d "$XDG_CACHE_HOME/tmux-notify-jump/dedupe" ]
}

@test "dedupe_should_suppress: falls back to read-only check when lock is held" {
    export XDG_CACHE_HOME="$TEST_TEMP_DIR/cache"

    NOW_MS="1500"
    now_ms() { printf '%s' "$NOW_MS"; }

    root="$(cache_root_dir)"
    dir="$root/tmux-notify-jump/dedupe"
    mkdir -p "$dir"

    key="key-locked"
    hash="$(printf '%s' "$key" | sha256_hex_stdin | tr -d '\n')"
    file="$dir/$hash.ts"

    # Pretend the key was recently seen
    echo "1000" >"$file"

    # Hold the per-key lock with the current test process pid
    mkdir -p "$file.lock"
    echo "$$" >"$file.lock/pid"

    run dedupe_should_suppress "2000" "$key"
    [ "$status" -eq 0 ]  # should suppress based on read-only check
}
