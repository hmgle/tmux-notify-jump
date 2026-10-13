#!/usr/bin/env bats
# Tests for text processing functions: trim_ws, truncate_text

load 'test_helper'

# =============================================================================
# trim_ws() tests
# =============================================================================

@test "trim_ws: removes leading spaces" {
    result="$(trim_ws "   hello")"
    [ "$result" = "hello" ]
}

@test "trim_ws: removes trailing spaces" {
    result="$(trim_ws "hello   ")"
    [ "$result" = "hello" ]
}

@test "trim_ws: removes both leading and trailing spaces" {
    result="$(trim_ws "   hello world   ")"
    [ "$result" = "hello world" ]
}

@test "trim_ws: preserves internal spaces" {
    result="$(trim_ws "hello   world")"
    [ "$result" = "hello   world" ]
}

@test "trim_ws: handles tabs" {
    result="$(trim_ws $'\t\thello\t\t')"
    [ "$result" = "hello" ]
}

@test "trim_ws: handles mixed whitespace" {
    result="$(trim_ws $' \t  hello \t ')"
    [ "$result" = "hello" ]
}

@test "trim_ws: returns empty for whitespace-only input" {
    result="$(trim_ws "   ")"
    [ "$result" = "" ]
}

@test "trim_ws: returns empty for empty input" {
    result="$(trim_ws "")"
    [ "$result" = "" ]
}

@test "trim_ws: handles newlines at edges" {
    result="$(trim_ws $'\nhello\n')"
    [ "$result" = "hello" ]
}

# =============================================================================
# truncate_text() tests
# =============================================================================

@test "truncate_text: no truncation when text is shorter than max" {
    result="$(truncate_text 10 "hello")"
    [ "$result" = "hello" ]
}

@test "truncate_text: no truncation when text equals max" {
    result="$(truncate_text 5 "hello")"
    [ "$result" = "hello" ]
}

@test "truncate_text: truncates with ellipsis when text exceeds max" {
    result="$(truncate_text 5 "hello world")"
    [ "$result" = "he..." ]
}

@test "truncate_text: max of 0 means no truncation" {
    result="$(truncate_text 0 "hello world this is a long text")"
    [ "$result" = "hello world this is a long text" ]
}

@test "truncate_text: handles empty text" {
    result="$(truncate_text 10 "")"
    [ "$result" = "" ]
}

@test "truncate_text: handles max of 1" {
    result="$(truncate_text 1 "hello")"
    [ "$result" = "." ]
}

@test "truncate_text: handles max of 2" {
    result="$(truncate_text 2 "hello")"
    [ "$result" = "h." ]
}

@test "truncate_text: handles Unicode characters" {
    # This tests the Python3 path if available
    if command -v python3 >/dev/null 2>&1; then
        result="$(truncate_text 3 "日本語テスト")"
        [ "$result" = "日本." ]
    else
        skip "Python3 not available for Unicode test"
    fi
}

@test "truncate_text: exact boundary case" {
    result="$(truncate_text 10 "1234567890")"
    [ "$result" = "1234567890" ]
}

@test "truncate_text: one over boundary" {
    result="$(truncate_text 10 "12345678901")"
    [ "$result" = "1234567..." ]
}

@test "truncate_text: handles special characters" {
    result="$(truncate_text 5 "a&b<c>d")"
    [ "$result" = "a&..." ]
}

@test "truncate_text: handles newlines in text" {
    result="$(truncate_text 10 $'hello\nworld')"
    # The text is 11 chars including newline, so it should truncate and add "..."
    [ "$result" = $'hello\nw...' ]
}

@test "truncate_text_columns: preserves text that fits including wide characters" {
    [ "$(truncate_text_columns 6 'A通知B')" = 'A通知B' ]
    [ "$(truncate_text_columns 5 'hello')" = 'hello' ]
}

@test "truncate_text_columns: reserves ellipsis columns without splitting Unicode" {
    [ "$(truncate_text_columns 8 '通知已完成请检查结果')" = '通知...' ]
    [ "$(truncate_text_columns 5 'A通知B')" = 'A...' ]
    [ "$(truncate_text_columns 6 'A🚀𠮷BCD')" = 'A🚀...' ]
}

@test "truncate_text_columns: reserves two columns for tmux emoji width overrides" {
    [ "$(truncate_text_columns 6 '☝☝☝☝☝☝☝')" = '☝...' ]
}

@test "truncate_text_columns: bounds each codepoint in decomposed Hangul" {
    [ "$(truncate_text_columns 7 '가가가')" = '가...' ]
}

@test "truncate_text_columns: budgets combining marks conservatively" {
    [ "$(truncate_text_columns 7 $'e\xcc\x81cole')" = $'e\xcc\x81cole' ]
    [ "$(truncate_text_columns 6 $'e\xcc\x81cole')" = $'e\xcc\x81...' ]
}

@test "truncate_text_columns: handles budgets smaller than the ellipsis" {
    [ "$(truncate_text_columns 0 '通知')" = '' ]
    [ "$(truncate_text_columns 1 '通知')" = '.' ]
    [ "$(truncate_text_columns 2 '通知')" = '.' ]
    [ "$(truncate_text_columns 3 '通知')" = '通.' ]
}

@test "truncate_text_columns: works without Python in UTF-8 and C locales" {
    command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = python3 ]; then return 1; fi
        builtin command "$@"
    }
    [ "$(truncate_text_columns 7 'A通知ABC')" = 'A通...' ]
    [ "$(LC_ALL=C truncate_text_columns 7 'A通知ABC')" = 'A通...' ]
    [ "$(truncate_text_columns 6 'A通知B')" = 'A通知B' ]
    [ "$(truncate_text_columns 5 'hello world')" = 'he...' ]
}

@test "truncate_text_columns: does not consult Python width tables" {
    python3() { printf 'unexpected Python call'; }
    [ "$(truncate_text_columns 7 'A通知ABC')" = 'A通...' ]
    [ "$(truncate_text_columns 6 'A通知B')" = 'A通知B' ]
    [ "$(truncate_text_columns 6 '☝☝☝☝☝☝☝')" = '☝...' ]
}
