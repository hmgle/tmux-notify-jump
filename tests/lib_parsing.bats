#!/usr/bin/env bats
# Tests for parsing functions: parse_target, format_notify_title

load 'test_helper'

# =============================================================================
# parse_target() tests
# =============================================================================

@test "parse_target: parses pane ID correctly" {
    parse_target "%5"
    [ "$PANE_ID" = "%5" ]
    [ -z "$SESSION" ]
    [ -z "$WINDOW" ]
    [ -z "$PANE" ]
}

@test "parse_target: parses session:window.pane format" {
    parse_target "main:0.1"
    [ "$SESSION" = "main" ]
    [ "$WINDOW" = "0" ]
    [ "$PANE" = "1" ]
    [ -z "$PANE_ID" ]
}

@test "parse_target: parses complex session name" {
    parse_target "my-session:2.3"
    [ "$SESSION" = "my-session" ]
    [ "$WINDOW" = "2" ]
    [ "$PANE" = "3" ]
}

@test "parse_target: parses session with underscores" {
    parse_target "work_project:1.0"
    [ "$SESSION" = "work_project" ]
    [ "$WINDOW" = "1" ]
    [ "$PANE" = "0" ]
}

@test "parse_target: fails on missing colon" {
    # The die() override returns but prints error; check for error message
    run bash -c '. "'"$PROJECT_ROOT"'/tmux-notify-jump-lib.sh"; parse_target "invalid" 2>&1'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Target must be"* ]]
}

@test "parse_target: fails on missing dot" {
    run bash -c '. "'"$PROJECT_ROOT"'/tmux-notify-jump-lib.sh"; parse_target "session:window" 2>&1'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Target must be"* ]]
}

@test "parse_target: fails on empty session" {
    run parse_target ":0.1"
    [ "$status" -ne 0 ]
}

@test "parse_target: fails on empty window" {
    run parse_target "session:.1"
    [ "$status" -ne 0 ]
}

@test "parse_target: fails on empty pane" {
    run parse_target "session:0."
    [ "$status" -ne 0 ]
}

@test "parse_target: clears previous values when parsing pane ID" {
    # First parse a full target
    parse_target "session:0.1"
    # Then parse a pane ID
    parse_target "%10"
    [ "$PANE_ID" = "%10" ]
    [ -z "$SESSION" ]
    [ -z "$WINDOW" ]
    [ -z "$PANE" ]
}

@test "parse_target: clears previous pane ID when parsing full target" {
    # First parse a pane ID
    parse_target "%10"
    # Then parse a full target
    parse_target "new:1.2"
    [ "$SESSION" = "new" ]
    [ "$WINDOW" = "1" ]
    [ "$PANE" = "2" ]
    [ -z "$PANE_ID" ]
}

# =============================================================================
# format_notify_title() tests
# =============================================================================

@test "format_notify_title: includes event type by default" {
    result="$(format_notify_title "Claude" "task_complete" "Build done")"
    [ "$result" = "Claude [task_complete]: Build done" ]
}

@test "format_notify_title: hides event type when show_type is 0" {
    result="$(format_notify_title "Claude" "task_complete" "Build done" "0")"
    [ "$result" = "Claude: Build done" ]
}

@test "format_notify_title: shows event type when show_type is 1" {
    result="$(format_notify_title "Codex" "error" "Failed" "1")"
    [ "$result" = "Codex [error]: Failed" ]
}

@test "format_notify_title: handles empty event gracefully" {
    result="$(format_notify_title "Claude" "" "Message")"
    [ "$result" = "Claude: Message" ]
}

@test "format_notify_title: handles whitespace-only event" {
    result="$(format_notify_title "Claude" "   " "Message")"
    [ "$result" = "Claude: Message" ]
}

@test "format_notify_title: works with different prefixes" {
    result="$(format_notify_title "MyApp" "info" "Status" "1")"
    [ "$result" = "MyApp [info]: Status" ]
}

@test "format_notify_title: handles empty message" {
    result="$(format_notify_title "Claude" "event" "")"
    [ "$result" = "Claude [event]: " ]
}

@test "format_notify_title: handles special characters in message" {
    result="$(format_notify_title "Claude" "event" "Hello <world> & 'test'")"
    [ "$result" = "Claude [event]: Hello <world> & 'test'" ]
}
