#!/usr/bin/env bats
# Tests for validation functions: is_integer, is_truthy, is_pane_id

load 'test_helper'

# =============================================================================
# is_integer() tests
# =============================================================================

@test "is_integer: positive integer returns success" {
    run is_integer "123"
    [ "$status" -eq 0 ]
}

@test "is_integer: zero returns success" {
    run is_integer "0"
    [ "$status" -eq 0 ]
}

@test "is_integer: empty string returns failure" {
    run is_integer ""
    [ "$status" -ne 0 ]
}

@test "is_integer: negative number returns failure (no minus sign support)" {
    run is_integer "-5"
    [ "$status" -ne 0 ]
}

@test "is_integer: leading zeros returns success" {
    run is_integer "007"
    [ "$status" -eq 0 ]
}

@test "is_integer: non-digit characters return failure" {
    run is_integer "12abc"
    [ "$status" -ne 0 ]
}

@test "is_integer: float returns failure" {
    run is_integer "3.14"
    [ "$status" -ne 0 ]
}

@test "is_integer: whitespace returns failure" {
    run is_integer " 42 "
    [ "$status" -ne 0 ]
}

@test "is_integer: unset variable returns failure" {
    unset MY_VAR
    run is_integer "${MY_VAR:-}"
    [ "$status" -ne 0 ]
}

# =============================================================================
# is_truthy() tests
# =============================================================================

@test "is_truthy: '1' returns success" {
    run is_truthy "1"
    [ "$status" -eq 0 ]
}

@test "is_truthy: 'true' returns success" {
    run is_truthy "true"
    [ "$status" -eq 0 ]
}

@test "is_truthy: 'TRUE' returns success" {
    run is_truthy "TRUE"
    [ "$status" -eq 0 ]
}

@test "is_truthy: 'yes' returns success" {
    run is_truthy "yes"
    [ "$status" -eq 0 ]
}

@test "is_truthy: 'YES' returns success" {
    run is_truthy "YES"
    [ "$status" -eq 0 ]
}

@test "is_truthy: 'on' returns success" {
    run is_truthy "on"
    [ "$status" -eq 0 ]
}

@test "is_truthy: 'ON' returns success" {
    run is_truthy "ON"
    [ "$status" -eq 0 ]
}

@test "is_truthy: '0' returns failure" {
    run is_truthy "0"
    [ "$status" -ne 0 ]
}

@test "is_truthy: 'false' returns failure" {
    run is_truthy "false"
    [ "$status" -ne 0 ]
}

@test "is_truthy: 'FALSE' returns failure" {
    run is_truthy "FALSE"
    [ "$status" -ne 0 ]
}

@test "is_truthy: empty string returns failure" {
    run is_truthy ""
    [ "$status" -ne 0 ]
}

@test "is_truthy: 'True' (mixed case) returns failure" {
    run is_truthy "True"
    [ "$status" -ne 0 ]
}

@test "is_truthy: random string returns failure" {
    run is_truthy "maybe"
    [ "$status" -ne 0 ]
}

# =============================================================================
# is_pane_id() tests
# =============================================================================

@test "is_pane_id: '%0' returns success" {
    run is_pane_id "%0"
    [ "$status" -eq 0 ]
}

@test "is_pane_id: '%1' returns success" {
    run is_pane_id "%1"
    [ "$status" -eq 0 ]
}

@test "is_pane_id: '%123' returns success" {
    run is_pane_id "%123"
    [ "$status" -eq 0 ]
}

@test "is_pane_id: '1' (without %) returns failure" {
    run is_pane_id "1"
    [ "$status" -ne 0 ]
}

@test "is_pane_id: empty string returns failure" {
    run is_pane_id ""
    [ "$status" -ne 0 ]
}

@test "is_pane_id: '%' alone returns failure" {
    run is_pane_id "%"
    [ "$status" -ne 0 ]
}

@test "is_pane_id: '%abc' returns failure" {
    run is_pane_id "%abc"
    [ "$status" -ne 0 ]
}

@test "is_pane_id: 'session:window.pane' format returns failure" {
    run is_pane_id "main:0.1"
    [ "$status" -ne 0 ]
}
