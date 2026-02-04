#!/usr/bin/env bats
# Tests for list functions: csv_list_contains, is_event_enabled

load 'test_helper'

# =============================================================================
# csv_list_contains() tests
# =============================================================================

@test "csv_list_contains: finds item in simple list" {
    run csv_list_contains "a,b,c" "b"
    [ "$status" -eq 0 ]
}

@test "csv_list_contains: finds first item" {
    run csv_list_contains "first,second,third" "first"
    [ "$status" -eq 0 ]
}

@test "csv_list_contains: finds last item" {
    run csv_list_contains "first,second,third" "third"
    [ "$status" -eq 0 ]
}

@test "csv_list_contains: returns failure for missing item" {
    run csv_list_contains "a,b,c" "d"
    [ "$status" -ne 0 ]
}

@test "csv_list_contains: returns failure for empty list" {
    run csv_list_contains "" "item"
    [ "$status" -ne 0 ]
}

@test "csv_list_contains: returns failure for empty needle" {
    run csv_list_contains "a,b,c" ""
    [ "$status" -ne 0 ]
}

@test "csv_list_contains: handles whitespace in list items" {
    run csv_list_contains "  a  ,  b  ,  c  " "b"
    [ "$status" -eq 0 ]
}

@test "csv_list_contains: handles whitespace in needle" {
    run csv_list_contains "a,b,c" "  b  "
    [ "$status" -eq 0 ]
}

@test "csv_list_contains: handles newlines converted to commas" {
    run csv_list_contains $'a\nb\nc' "b"
    [ "$status" -eq 0 ]
}

@test "csv_list_contains: single item list matches" {
    run csv_list_contains "only" "only"
    [ "$status" -eq 0 ]
}

@test "csv_list_contains: single item list doesn't match other" {
    run csv_list_contains "only" "other"
    [ "$status" -ne 0 ]
}

@test "csv_list_contains: partial match returns failure" {
    run csv_list_contains "foobar,baz" "foo"
    [ "$status" -ne 0 ]
}

# =============================================================================
# is_event_enabled() tests
# =============================================================================

@test "is_event_enabled: event in whitelist returns success" {
    run is_event_enabled "task_complete" "task_complete,error" "" ""
    [ "$status" -eq 0 ]
}

@test "is_event_enabled: event not in whitelist returns failure" {
    run is_event_enabled "other_event" "task_complete,error" "" ""
    [ "$status" -ne 0 ]
}

@test "is_event_enabled: event in blacklist returns failure even if in whitelist" {
    run is_event_enabled "blocked_event" "blocked_event,other" "blocked_event" ""
    [ "$status" -ne 0 ]
}

@test "is_event_enabled: empty whitelist uses default list" {
    run is_event_enabled "default_event" "" "" "default_event,other"
    [ "$status" -eq 0 ]
}

@test "is_event_enabled: * whitelist allows all events" {
    run is_event_enabled "any_event" "*" "" ""
    [ "$status" -eq 0 ]
}

@test "is_event_enabled: * blacklist blocks all events" {
    run is_event_enabled "any_event" "*" "*" ""
    [ "$status" -ne 0 ]
}

@test "is_event_enabled: blacklist takes precedence over * whitelist" {
    run is_event_enabled "blocked" "*" "blocked" ""
    [ "$status" -ne 0 ]
}

@test "is_event_enabled: empty event returns failure" {
    run is_event_enabled "" "*" "" ""
    [ "$status" -ne 0 ]
}

@test "is_event_enabled: empty whitespace event returns failure" {
    run is_event_enabled "   " "*" "" ""
    [ "$status" -ne 0 ]
}

@test "is_event_enabled: empty effective list returns failure" {
    run is_event_enabled "event" "" "" ""
    [ "$status" -ne 0 ]
}

@test "is_event_enabled: handles newlines in lists" {
    run is_event_enabled "event2" $'event1\nevent2\nevent3' "" ""
    [ "$status" -eq 0 ]
}

@test "is_event_enabled: default list used when whitelist empty" {
    run is_event_enabled "from_default" "" "" "from_default"
    [ "$status" -eq 0 ]
}

@test "is_event_enabled: whitelist overrides default list" {
    run is_event_enabled "from_default" "custom" "" "from_default"
    [ "$status" -ne 0 ]
}

@test "is_event_enabled: event in default not in custom whitelist fails" {
    run is_event_enabled "default_only" "whitelist_only" "" "default_only"
    [ "$status" -ne 0 ]
}
