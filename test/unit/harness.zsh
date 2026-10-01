#!/bin/zsh
#
# The harness testing itself. Cheap, and it catches the failure mode that
# matters most in a hand-rolled test runner: assertions that silently pass
# because they never actually ran.

test_assert_eq_passes_on_equal() {
  assert_eq "abc" "abc" "identical strings"
  assert_eq "" "" "two empty strings"
}

test_assert_eq_counts_a_failure() {
  # Run the failing assertion in a subshell so it does not poison this suite's
  # own counter, and check that it both reported and counted.
  local out
  out="$(
    TESTS_FAILED=0
    CURRENT_TEST="inner"
    assert_eq "want" "got" 2>&1
    print -rn -- "|$TESTS_FAILED"
  )"
  assert_contains "$out" "expected [want], got [got]" "failure message"
  assert_contains "$out" "|1" "failure counter incremented"
}

test_assert_contains() {
  assert_contains "the quick brown fox" "quick" "substring in the middle"
  assert_contains "abc" "abc" "whole string"
  assert_not_contains "abc" "xyz" "absent substring"
}

test_assert_matches() {
  assert_matches "u123456" '^u[0-9]{6}$' "storage box username shape"
  assert_matches "10.0.0.1" '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "dotted quad"
}

test_assert_empty_and_nonempty() {
  assert_empty "" "empty string"
  assert_nonempty "x" "one character"
}

test_assert_status() {
  assert_status 0 true
  assert_status 1 false
  assert_status 2 /bin/zsh -c 'exit 2'
}

test_assert_no_secret() {
  assert_no_secret "user=alice password=[REDACTED]" "hunter2hunter2" "redacted line"
}

test_running_under_the_shipped_zsh() {
  # The whole point of the harness. macOS 26 ships zsh 5.9 as the default login
  # shell, and that is what the published one-liner pipes into; if these tests
  # ever ran under a Homebrew zsh 5.10 they would stop proving anything about
  # the machine the product lands on.
  assert_nonempty "${ZSH_VERSION:-}" "running under zsh at all"
  assert_eq "5.9" "$ZSH_VERSION" "zsh version"
}

test_unicode_is_counted_in_characters() {
  # zsh counts characters, not bytes. The interface relies on this to align box
  # borders around text containing ✓, → and non-ASCII names; under bash 3.2 the
  # same expression returned a byte count and the boxes came out ragged.
  local s="ąćę✓→"
  assert_eq 5 ${#s} "length of a five-character multibyte string"
}
