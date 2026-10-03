#!/bin/zsh
#
# Static gate for every script in the repository.
#
# Two interpreters live here and they are checked separately, by extension:
#
#   *.zsh  - runs on the Mac. zsh 5.9 is the default login shell on every
#            supported macOS, and the published one-liner pipes into it.
#   *.sh   - runs on the Debian appliance, under its bash 5. Nothing in this
#            half may assume zsh, because Debian does not ship it.
#
# shellcheck is only useful for the bash half: it has no zsh parser at all and
# declines the file. For the zsh half the equivalents are `zsh -n`, a
# `setopt warn_create_global` smoke pass, and the pattern checks below - which
# is a genuine loss of coverage and the reason those patterns exist.
#
#   tools/lint.zsh [file...]
#
emulate -L zsh
setopt pipe_fail

ROOT="${0:A:h:h}"
cd -- "$ROOT" || exit 2

red() { print -r -- $'\033[31m'"$*"$'\033[0m' }
grn() { print -r -- $'\033[32m'"$*"$'\033[0m' }
ylw() { print -r -- $'\033[33m'"$*"$'\033[0m' }

local -a files zsh_files sh_files
if (( $# > 0 )); then
  files=("$@")
else
  files=(
    ${~:-}bin/**/*.zsh(N) lib/**/*.zsh(N) cmd/**/*.zsh(N)
    tools/**/*.zsh(N) test/**/*.zsh(N)
    appliance/**/*.sh(N) macos/**/*(N.x)
  )
fi

for f in $files; do
  case "$f" in
    *.zsh) zsh_files+=("$f") ;;
    *.sh)  sh_files+=("$f") ;;
    *)
      # Extensionless executables under macos/ are zsh helpers; read the shebang
      # rather than guessing, because getting this backwards means a file is
      # never checked at all.
      case "$(head -1 -- "$f" 2>/dev/null)" in
        *zsh*)  zsh_files+=("$f") ;;
        *bash*|*/sh) sh_files+=("$f") ;;
      esac
      ;;
  esac
done

if (( ${#zsh_files} + ${#sh_files} == 0 )); then
  ylw "lint: nothing to check yet"
  exit 0
fi

local fail=0

# --- 1. syntax, under the interpreter each file actually runs on -------------

for f in $zsh_files; do
  if ! out="$(/bin/zsh -n -- "$f" 2>&1)"; then
    red "SYNTAX  $f  (zsh)"
    print -r -- "$out" | sed 's/^/        /'
    fail=1
  fi
done

for f in $sh_files; do
  if ! out="$(/bin/bash -n -- "$f" 2>&1)"; then
    red "SYNTAX  $f  (bash)"
    print -r -- "$out" | sed 's/^/        /'
    fail=1
  fi
done

# --- 2. patterns ------------------------------------------------------------
#
# Each pattern names the fix, because a lint error that does not say what to
# write instead just gets suppressed. This file is excluded from its own pass:
# it has to spell the patterns out in order to search for them.

local -a scan
scan=(${zsh_files:#*tools/lint.zsh} $sh_files)

check_pattern() {
  local pattern="$1" why="$2" hits
  (( ${#scan} > 0 )) || return 0
  # /dev/null keeps grep in multi-file mode, so a single-file run still prints
  # the filename with the line number.
  hits="$(grep -nE -- "$pattern" $scan /dev/null 2>/dev/null | grep -v '# lint-ok')"
  if [[ -n "$hits" ]]; then
    red "PATTERN $why"
    print -r -- "$hits" | sed 's/^/        /'
    fail=1
  fi
}

# Portability of the appliance half. zsh-isms here would work on the Mac during
# development and fail on Debian, where there is no zsh to fall back to.
check_zsh_in_bash() {
  (( ${#sh_files} > 0 )) || return 0
  local hits
  hits="$(grep -nE -- '\b(setopt|emulate|zmodload|autoload -Uz|print -r|typeset -A)\b' \
          $sh_files /dev/null 2>/dev/null | grep -v '# lint-ok')"
  if [[ -n "$hits" ]]; then
    red "PATTERN zsh builtins in a file that runs on Debian - use bash equivalents"
    print -r -- "$hits" | sed 's/^/        /'
    fail=1
  fi
}
check_zsh_in_bash

check_pattern '\becho[[:space:]]+-e\b' \
  'echo -e is not portable - use printf, or print -r in zsh'

# A backslash escape in double quotes handed to `print -r`. In zsh "\r" is two
# characters, and -r turns escape processing off, so they reach the terminal as
# a visible backslash and letter. That is how the spinner drew every frame on
# one growing line in 0.1.0 (#1). The escape belongs in $'...'. A "$(" stops
# the match: the escape is then inside a command, where printf interprets it.
check_pattern '(print[[:space:]]+-r[a-zA-Z]*|_ui_raw|_ui_out)[[:space:]]+(--[[:space:]]+)?"([^"$]|\$[^(])*\\[rnte]' \
  "print -r does not interpret escapes - write \$'\\r' rather than \"\\r\""

# An unquoted `$(...)` inside [[ ]]. zsh does not word-split it, so unlike in
# bash this does not break loudly - it quietly compares something slightly
# different, most visibly when the command produces nothing at all. The pattern
# looks for `$(` preceded by an operator and whitespace, so a properly quoted
# "$(…)" does not match.
check_pattern '(\[\[|==|!=|\|\||&&)[[:space:]]+\$\(' \
  'quote command substitutions inside [[ ]]'

# A literal password or token assigned in source. Cheap check, catches the
# mistake that matters most in a repository that handles credentials.
check_pattern '(PASSWORD|PASSPHRASE|TOKEN|SECRET)=["'"'"'][A-Za-z0-9+/]{16,}' \
  'a credential appears to be hardcoded'

# Every secret must reach the appliance on stdin or in a mode-600 file, never as
# an argument: arguments are world-readable in ps for the life of the process.
check_pattern 'ssh .*(--password|--passphrase|-p [A-Za-z0-9]{12,})' \
  'do not pass a secret as a command argument - it is visible in ps'

# `emulate -L zsh` at the top level of a sourced library. `-L` scopes the reset
# to the enclosing function, and a sourced file at top level has none - so it
# acts as a plain `emulate zsh` and resets the *caller's* options. That turned
# extended_glob off once and made a secret-matching glob match nothing, which
# printed an API token in the clear. Options belong to the entry point.
check_lib_emulate() {
  local -a libs=( ${(M)scan:#lib/*} )
  (( ${#libs} > 0 )) || return 0
  local hits
  hits="$(grep -nE -- '^emulate[[:space:]]' $libs /dev/null 2>/dev/null | grep -v '# lint-ok')"
  if [[ -n "$hits" ]]; then
    red "PATTERN emulate at the top level of a library resets the caller's options"
    print -r -- "$hits" | sed 's/^/        /'
    fail=1
  fi
}
check_lib_emulate

# zsh's special parameters, declared as locals. This is a whole class of bug and
# each member fails differently:
#
#   status   read-only (an alias for $?); assigning aborts the function
#   path     tied to $PATH, so `local path=…` replaces the command search path
#            for the function and nothing called inside it resolves any more
#   argv     tied to the positional parameters
#   options, functions, commands, parameters, aliases - live views of shell
#            state, silently clobbered
#
# Both `zsh -n` and shellcheck accept all of them; three got through review here.
#
# The name is matched anywhere in the declaration, not just immediately after
# `local`. An earlier version anchored it to the first variable and therefore
# missed `local var="$1" path="$2"` - which set PATH to a filename and made
# base64 and tr stop resolving inside that function.
check_special_locals() {
  local -a zfiles=( ${(M)scan:#*.zsh} )
  (( ${#zfiles} > 0 )) || return 0
  local hits
  # Two forms, because only the first was caught until 2026-09-19 and the one
  # that got through cost a runtime abort in `tmbox unlock`:
  #
  #   local status="$(...)"     assignment on the declaring line
  #   local status             bare, assigned further down
  #
  # The second is the more dangerous of the two - it reads as ordinary and the
  # failure appears at a distance, when the later assignment aborts the
  # function. Neither `zsh -n` nor sourcing catches it, because it is an error
  # only when the line actually executes.
  local specials='status|path|cdpath|fpath|manpath|argv|options|functions|commands|parameters|aliases|modules|signals|dirstack|pipestatus'
  hits="$(grep -nE -- \
    "\\b(local|typeset|declare)\\b[^;&|#]*\\b(${specials})([=[:space:]]|\$)" \
    $zfiles /dev/null 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | grep -v '# lint-ok')"
  if [[ -n "$hits" ]]; then
    red "PATTERN a zsh special parameter is being used as a local variable"
    print -r -- "$hits" | sed 's/^/        /'
    fail=1
  fi
}
check_special_locals

# --- 3. zsh runtime smoke ---------------------------------------------------
#
# `zsh -n` parses but does not resolve; sourcing a library under
# warn_create_global catches the typo that creates a new global instead of
# assigning to the intended one, which is the single most common way a shell
# library goes subtly wrong.

for f in ${zsh_files:#*/tools/*}; do
  [[ "$f" == lib/* ]] || continue
  if ! out="$(/bin/zsh -c "
      emulate -L zsh
      setopt warn_create_global
      source '$f'
    " 2>&1)"; then
    red "SOURCE  $f does not load cleanly"
    print -r -- "$out" | sed 's/^/        /'
    fail=1
  elif [[ -n "$out" ]]; then
    ylw "WARN    $f"
    print -r -- "$out" | sed 's/^/        /'
  fi
done

# --- 4. shellcheck, for the bash half only ----------------------------------

if (( ${#sh_files} > 0 )); then
  if (( $+commands[shellcheck] )); then
    if ! shellcheck -s bash -S warning -- $sh_files; then
      red "SHELLCHECK failed"
      fail=1
    fi
  else
    ylw "shellcheck not installed - the Debian half is unchecked (brew install shellcheck)"
  fi
fi

if (( fail == 0 )); then
  grn "lint: ${#zsh_files} zsh + ${#sh_files} bash file(s) clean"
fi
exit $fail
