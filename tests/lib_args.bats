#!/usr/bin/env bats
# Tests for argument parsing helpers: parse_common_opt, handle_positional_arg, validate_nonneg_int

load 'test_helper'

setup() {
    # Initialize globals expected by parse_common_opt / handle_positional_arg
    TARGET=""
    TITLE=""
    BODY=""
    FOCUS_ONLY=0
    NO_ACTIVATE=0
    LIST_ONLY=0
    DRY_RUN=0
    QUIET=0
    TIMEOUT="10000"
    UI="notification"
    MAX_TITLE="80"
    MAX_BODY="200"
    DEDUPE_MS="2000"
    DETACH=0
    TMUX_SOCKET=""
    TMUX_NOTIFY_TMUX_SOCKET=""
    SENDER_CLIENT_TTY=""
    _PARSE_CONSUMED=0
}

# =============================================================================
# parse_common_opt() tests
# =============================================================================

@test "parse_common_opt: parses --target <value>" {
    parse_common_opt --target "main:0.1"
    status=$?
    [ "$status" -eq 0 ]
    [ "$_PARSE_CONSUMED" -eq 2 ]
    [ "$TARGET" = "main:0.1" ]
}

@test "parse_common_opt: parses --focus-only flag" {
    parse_common_opt --focus-only
    status=$?
    [ "$status" -eq 0 ]
    [ "$_PARSE_CONSUMED" -eq 1 ]
    [ "$FOCUS_ONLY" -eq 1 ]
}

@test "parse_common_opt: parses --title/--body" {
    parse_common_opt --title "hello"
    status=$?
    [ "$status" -eq 0 ]
    [ "$_PARSE_CONSUMED" -eq 2 ]
    [ "$TITLE" = "hello" ]

    parse_common_opt --body "world"
    status=$?
    [ "$status" -eq 0 ]
    [ "$_PARSE_CONSUMED" -eq 2 ]
    [ "$BODY" = "world" ]
}

@test "parse_common_opt: returns help sentinel for --help" {
    parse_common_opt --help
    status=$?
    [ "$status" -eq 0 ]
    [ "$_PARSE_CONSUMED" = "help" ]
}

@test "parse_common_opt: returns end sentinel for --" {
    parse_common_opt --
    status=$?
    [ "$status" -eq 0 ]
    [ "$_PARSE_CONSUMED" = "end" ]
}

@test "parse_common_opt: returns failure for unknown option" {
    if parse_common_opt --not-a-real-option; then
        status=0
    else
        status=$?
    fi
    [ "$status" -ne 0 ]
    [ "$_PARSE_CONSUMED" -eq 0 ]
}

# =============================================================================
# handle_positional_arg() tests
# =============================================================================

@test "handle_positional_arg: assigns target/title/body in order" {
    handle_positional_arg "tgt"
    [ "$TARGET" = "tgt" ]
    [ "$TITLE" = "" ]
    [ "$BODY" = "" ]

    handle_positional_arg "ttl"
    [ "$TARGET" = "tgt" ]
    [ "$TITLE" = "ttl" ]
    [ "$BODY" = "" ]

    handle_positional_arg "bdy"
    [ "$TARGET" = "tgt" ]
    [ "$TITLE" = "ttl" ]
    [ "$BODY" = "bdy" ]
}

@test "handle_positional_arg: errors on too many positional args" {
    handle_positional_arg "tgt"
    handle_positional_arg "ttl"
    handle_positional_arg "bdy"
    run handle_positional_arg "extra"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Too many arguments"* ]]
}

# =============================================================================
# validate_nonneg_int() tests
# =============================================================================

@test "validate_nonneg_int: accepts digits-only values" {
    run validate_nonneg_int "0" "--max-title"
    [ "$status" -eq 0 ]
    run validate_nonneg_int "42" "--max-title"
    [ "$status" -eq 0 ]
}

@test "validate_nonneg_int: rejects non-integers" {
    run validate_nonneg_int "abc" "--max-title"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--max-title must be a non-negative integer"* ]]
}
