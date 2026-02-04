#!/usr/bin/env bash
# Test helper functions for bats-core tests
#
# This file is sourced by all test files to provide common setup and utilities.

# Get the directory containing this test helper
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Source the library being tested
# shellcheck source=../tmux-notify-jump-lib.sh
. "$PROJECT_ROOT/tmux-notify-jump-lib.sh"

# Initialize quiet mode for tests (suppress log output)
_QUIET=1
export _QUIET

# Create a temporary directory for test artifacts
setup_temp_dir() {
    TEST_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tmux-notify-test.XXXXXX")"
    export TEST_TEMP_DIR
}

# Clean up temporary directory
teardown_temp_dir() {
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Assert that two values are equal
# Usage: assert_equals "expected" "actual" ["message"]
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed${message:+: $message}"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        return 1
    fi
}

# Assert that a command exits with code 0
# Usage: assert_success command [args...]
assert_success() {
    if ! "$@"; then
        echo "Expected command to succeed: $*"
        return 1
    fi
}

# Assert that a command exits with non-zero code
# Usage: assert_failure command [args...]
assert_failure() {
    if "$@"; then
        echo "Expected command to fail: $*"
        return 1
    fi
}

# Assert that output contains a substring
# Usage: assert_contains "haystack" "needle" ["message"]
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Assertion failed${message:+: $message}"
        echo "  Expected to contain: '$needle'"
        echo "  Actual: '$haystack'"
        return 1
    fi
}

# Assert that a string matches a regex
# Usage: assert_matches "string" "pattern" ["message"]
assert_matches() {
    local string="$1"
    local pattern="$2"
    local message="${3:-}"
    if ! [[ "$string" =~ $pattern ]]; then
        echo "Assertion failed${message:+: $message}"
        echo "  Expected to match pattern: '$pattern'"
        echo "  Actual: '$string'"
        return 1
    fi
}

# Override die() to not exit during tests
# This allows testing error conditions without terminating the test
die() {
    echo "Error: $*" >&2
    return 1
}
export -f die
