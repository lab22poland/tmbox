#!/bin/zsh
#
# Interactive tests: the interface driven through a real pty.
#
# Kept apart from test/run-tests.zsh because these are seconds rather than
# milliseconds, and because they need python3 for the pty. `make check` stays
# fast and runs the unit suites; `make dist` runs these too, so nothing ships
# without them.
#
# What they establish, none of which a unit test can:
#
#   - ui_init really binds /dev/tty and reports an interactive terminal;
#   - every prompt reads from that terminal;
#   - and the case the whole product depends on - the script arriving on stdin,
#     as it does under `curl … | zsh`, while the prompts still work. Get that
#     wrong and `read` eats the rest of the program, which surfaces as a syntax
#     error hundreds of lines from the cause.
#
emulate -L zsh
setopt pipe_fail

typeset -g ROOT="${0:A:h:h}"
export TMBOX_ROOT="$ROOT"

typeset -g PTY="$ROOT/tools/pty-run.py"
typeset -g FIXTURE="$ROOT/test/tty/prompts.zsh"

if (( ! $+commands[python3] )); then
  print -r -- $'\033[33m'"python3 not found - skipping the pty tests"$'\033[0m'
  exit 0
fi

typeset -gi failed=0

_strip() { perl -pe 's/\e\[[0-9;]*m//g; s/\e\[K//g' }

_check() {
  local what="$1" out="$2" want="$3"
  if [[ "$out" == *"$want"* ]]; then
    printf "  \033[32mok\033[0m    %s\n" "$what"
  else
    printf "  \033[31mFAIL\033[0m  %s\n" "$what"
    print -r -- "        expected to find: $want"
    print -r -- "${(F)${(f)out}/#/        | }"
    (( failed++ ))
  fi
}

print -r -- $'\033[1m'"tty"$'\033[0m'

# --- 1. run normally, with a controlling terminal ---------------------------

local out
out="$(python3 "$PTY" --timeout 25 \
        --input mbp --input 3 --input 'hunter2hunter2' --input y \
        -- /bin/zsh "$FIXTURE" 2>&1 | _strip)"

_check "ui_init binds a real terminal"       "$out" "STATE interactive=1"
_check "the terminal's width is adopted"     "$out" "width=80"
_check "answers arrive from the terminal"    "$out" "RESULT name=[mbp] cap=[5TB]"
_check "a secret is read without echoing it" "$out" "secretlen=[14]"
_check "confirmation is read"                "$out" "proceed=[yes]"

# A typed password must never appear in what the terminal drew.
if [[ "$out" == *"hunter2hunter2"* ]]; then
  printf "  \033[31mFAIL\033[0m  %s\n" "the password was echoed to the terminal"
  (( failed++ ))
else
  printf "  \033[32mok\033[0m    %s\n" "the password was not echoed"
fi

# --- 2. the published form: the script arrives on stdin ---------------------

out="$(python3 "$PTY" --timeout 25 --stdin-file "$FIXTURE" \
        --input studio2 --input 2 --input pw12345678 --input n \
        -- /bin/zsh -s 2>&1 | _strip)"

_check "curl|zsh: still an interactive terminal" "$out" "STATE interactive=1"
_check "curl|zsh: prompts read from the tty"     "$out" "RESULT name=[studio2] cap=[2TB]"
_check "curl|zsh: read did not eat the script"   "$out" "proceed=[no]"

# --- 3. unattended: every prompt answered in advance ------------------------
#
# The other half of the contract: nothing in tmbox requires a human if the
# caller already knows the answers.

out="$(TMBOX_ANSWER_MACNAME=auto TMBOX_ANSWER_CAPACITY=1TB \
       TMBOX_ANSWER_SMB_PASSWORD=abcdefgh TMBOX_ANSWER_PROCEED=yes \
       /bin/zsh -c '
         emulate -L zsh
         source "$TMBOX_ROOT/lib/answers.zsh"
         TMBOX_NONINTERACTIVE=1
         ans_from_env
         source "$1"
       ' _ "$FIXTURE" 2>&1 | _strip)"

_check "unattended: runs with no terminal"    "$out" "STATE interactive=0"
_check "unattended: env answers are used"     "$out" "RESULT name=[auto] cap=[1TB]"
_check "unattended: confirmation from env"    "$out" "proceed=[yes]"

if [[ "$out" == *"abcdefgh"* ]]; then
  printf "  \033[31mFAIL\033[0m  %s\n" "a pre-supplied secret was printed"
  (( failed++ ))
else
  printf "  \033[32mok\033[0m    %s\n" "a pre-supplied secret stays hidden"
fi

print
if (( failed == 0 )); then
  print -r -- $'\033[32m'"tty tests passed"$'\033[0m'
  exit 0
fi
print -r -- $'\033[31m'"$failed tty test(s) failed"$'\033[0m'
exit 1
