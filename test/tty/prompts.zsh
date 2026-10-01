#!/bin/zsh
#
# Fixture driven by test/run-tty-tests.zsh under a real pty.
#
# This exercises the path no unit test can reach: ui_init binding /dev/tty, and
# every prompt reading from it. Run with no terminal, the interface takes its
# non-interactive fallback and proves nothing about what a user actually meets.
#
# It prints one RESULT line the runner asserts against.

emulate -L zsh
setopt no_unset pipe_fail extended_glob

typeset -g ROOT="${TMBOX_ROOT:?}"
typeset -g TMBOX_VERSION="tty-test"

source "$ROOT/lib/answers.zsh"
source "$ROOT/lib/log.zsh"
source "$ROOT/lib/ui.zsh"

ui_init || exit 1

print -r -- "STATE interactive=$TMBOX_UI_INTERACTIVE colour=$TMBOX_UI_COLOR width=$TMBOX_UI_WIDTH"

typeset -g name cap secret proceed
name="$(ui_ask MACNAME "What should this Mac be called" "studio")"
cap="$(ui_menu CAPACITY "How much space" \
  1TB "1 TB" "cheap" \
  2TB "2 TB" "usual" \
  5TB "5 TB" "large")"
secret="$(ui_ask_secret SMB_PASSWORD "Share password")"
if ui_confirm PROCEED "Create it now?" "n"; then proceed=yes; else proceed=no; fi

print -r -- "RESULT name=[$name] cap=[$cap] secretlen=[${#secret}] proceed=[$proceed]"
