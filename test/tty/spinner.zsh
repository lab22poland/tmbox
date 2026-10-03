#!/bin/zsh
#
# Fixture driven by test/run-tty-tests.zsh under a real pty.
#
# The animated spinner only runs with a terminal and colour, so neither the
# unit suites nor an unattended run ever draw it. This starts one, lets it draw
# a few frames, and stops it, so the runner can inspect the raw bytes.

emulate -L zsh
setopt no_unset pipe_fail extended_glob

typeset -g ROOT="${TMBOX_ROOT:?}"
typeset -g TMBOX_VERSION="tty-test"

source "$ROOT/lib/answers.zsh"
source "$ROOT/lib/log.zsh"
source "$ROOT/lib/ui.zsh"

ui_init || exit 1

print -r -- "STATE interactive=$TMBOX_UI_INTERACTIVE colour=$TMBOX_UI_COLOR"

ui_spin_start "Spinning"
sleep 0.5
ui_spin_stop ok "Spun"

print -r -- "RESULT done"
