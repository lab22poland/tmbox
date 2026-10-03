#!/bin/zsh
#
# Minimal assertion helpers for test/run-tests.zsh.
#
# Deliberately tiny and dependency-free. The tests run under the same /bin/zsh
# as the product, on a Mac with no Homebrew, so bats and shunit2 are both out -
# and a test framework that has to be installed first is a test framework that
# does not run on the machine where it matters.

# Refuse to run against a real installation. The runner moves every path into a
# scratch directory; a suite started some other way, or a path the runner does
# not know about, must not get as far as writing to ~/.config/tmbox (#11).
() {
  # ~user, not $HOME: the runner moves HOME, and the directory to protect is
  # the one in the password database. Assigned, because zsh expands ~$USER in
  # an assignment and not inside ${...}.
  local home=~$USER
  local real="${home:A}/.config/tmbox"
  local p
  for p in "${TMBOX_STATE_DIR:-}" "${TMBOX_SECRET_DIR:-}" "${SSH_KEY_DIR:-}" "${HOME:-}/.config/tmbox"; do
    if [[ -z "$p" || "${p:A}" == "${real:A}"* ]]; then
      print -u2 -r -- "test/lib.zsh: refusing to run - '${p:-an unset path}' is the real tmbox directory. Use test/run-tests.zsh."
      exit 70
    fi
  done
}

typeset -g TESTS_RUN=0
typeset -g TESTS_FAILED=0
typeset -g CURRENT_TEST=""

_t_red() { print -r -- $'\033[31m'"$*"$'\033[0m' }

fail() {
  (( TESTS_FAILED++ ))
  _t_red "  FAIL  $CURRENT_TEST"
  local line
  for line in "$@"; do print -r -- "        $line"; done
}

assert_eq() {
  local want="$1" got="$2" what="${3:-}"
  [[ "$want" == "$got" ]] && return 0
  fail "${what:+$what: }expected [$want], got [$got]"
}

assert_ne() {
  local unwanted="$1" got="$2" what="${3:-}"
  [[ "$unwanted" != "$got" ]] && return 0
  fail "${what:+$what: }expected anything but [$unwanted]"
}

assert_contains() {
  local haystack="$1" needle="$2" what="${3:-}"
  [[ "$haystack" == *"$needle"* ]] && return 0
  fail "${what:+$what: }expected to find [$needle] in [$haystack]"
}

assert_not_contains() {
  local haystack="$1" needle="$2" what="${3:-}"
  [[ "$haystack" != *"$needle"* ]] && return 0
  fail "${what:+$what: }did not expect [$needle] in [$haystack]"
}

assert_matches() {
  local got="$1" pattern="$2" what="${3:-}"
  # ERE via grep rather than zsh's own =~, so the patterns in tests read the
  # same as the ones in tools/lint.zsh.
  print -r -- "$got" | grep -qE -- "$pattern" && return 0
  fail "${what:+$what: }[$got] does not match /$pattern/"
}

assert_empty() {
  local got="$1" what="${2:-}"
  [[ -z "$got" ]] && return 0
  fail "${what:+$what: }expected empty, got [$got]"
}

assert_nonempty() {
  local got="$1" what="${2:-}"
  [[ -n "$got" ]] && return 0
  fail "${what:+$what: }expected a value, got nothing"
}

# assert_status <expected-code> <command...>
assert_status() {
  local want="$1"; shift
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  (( want == got )) && return 0
  fail "expected exit $want from [$*], got $got"
}

assert_file() {
  # Not `path` - see the note in lib/answers.zsh: that name is tied to $PATH.
  local file="$1" what="${2:-}"
  [[ -f "$file" ]] && return 0
  fail "${what:+$what: }expected a file at [$file]"
}

# assert_no_secret <text> <secret>
#
# Used wherever output could leak a credential - transcripts, state files, the
# answers dump. Worth its own helper because the check is easy to forget and the
# consequence of forgetting is a password in a support mail.
assert_no_secret() {
  local text="$1" secret="$2" what="${3:-}"
  [[ "$text" != *"$secret"* ]] && return 0
  fail "${what:+$what: }a secret leaked into output"
}
