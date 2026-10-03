#!/bin/zsh
#
# Run every test/unit/*.zsh under /bin/zsh - the same interpreter the product
# runs under, not whatever newer zsh happens to be on PATH from Homebrew.
#
#   test/run-tests.zsh              - all suites
#   test/run-tests.zsh json state   - only test/unit/{json,state}.zsh
#
emulate -L zsh
setopt pipe_fail

typeset -g ROOT="${0:A:h:h}"
export TMBOX_ROOT="$ROOT"
export TMBOX_TESTING=1

source "$ROOT/test/env.zsh"

local -a suites
if (( $# > 0 )); then
  local name
  for name in "$@"; do suites+=("$ROOT/test/unit/$name.zsh"); done
else
  suites=("$ROOT"/test/unit/*.zsh(N))
fi

if (( ${#suites} == 0 )); then
  print -r -- $'\033[33m'"no test suites yet"$'\033[0m'
  exit 0
fi

local total_run=0 total_failed=0
local -a failed_suites

local suite name out counts
for suite in $suites; do
  if [[ ! -f "$suite" ]]; then
    print -r -- $'\033[31m'"no such suite: $suite"$'\033[0m'
    (( total_failed++ ))
    continue
  fi

  name="${suite:t:r}"
  print -r -- $'\033[1m'"$name"$'\033[0m'

  # Each suite runs in its own zsh, so a suite that sets a global, changes
  # directory or defines a helper cannot leak into the next one. An unset
  # variable or a failed command inside a test must not take the runner with it,
  # which is why err_exit is deliberately off.
  out="$(/bin/zsh -c '
    emulate -L zsh
    setopt pipe_fail
    source "$TMBOX_ROOT/test/lib.zsh"
    source "$1"

    # (M) keeps the matches rather than removing them, and the assignment is
    # deliberately unquoted: quoting an array substitution in zsh joins it into
    # a single element, which here silently selected every function in the file
    # - including the assertion helpers - and ran them as tests.
    local -a tests
    tests=( ${(o)${(M)${(k)functions}:#test_*}} )

    local fn before ran=0
    for fn in $tests; do
      CURRENT_TEST="$fn"
      before=$TESTS_FAILED
      "$fn"
      (( ran++ ))
      (( TESTS_FAILED == before )) && printf "  \033[32mok\033[0m    %s\n" "${fn#test_}"
    done
    printf "__COUNTS__ %s %s\n" "$ran" "$TESTS_FAILED"
  ' _ "$suite" 2>&1)"

  # Unquoted for the same reason as the function list above.
  local -a out_lines=( ${(f)out} )
  local -a count_lines=( ${(M)out_lines:#__COUNTS__*} )
  counts="${count_lines[-1]:-}"
  print -rl -- ${out_lines:#__COUNTS__*}

  if [[ -z "$counts" ]]; then
    print -r -- $'\033[31m'"  suite crashed before reporting"$'\033[0m'
    (( total_failed++ ))
    failed_suites+=("$name")
    continue
  fi

  local -a parts=(${=counts})
  (( total_run += parts[2] ))
  (( total_failed += parts[3] ))
  (( parts[3] == 0 )) || failed_suites+=("$name")
done

print
if (( total_failed == 0 )); then
  print -r -- $'\033[32m'"$total_run test(s) in ${#suites} suite(s), all passed"$'\033[0m'
  exit 0
fi
print -r -- $'\033[31m'"$total_failed failed of $total_run, in: ${(j:, :)failed_suites}"$'\033[0m'
exit 1
