#!/bin/zsh
#
# The interface. ANSI escapes and `read`, nothing else.
#
# Three constraints shape every function here, and all three come from the
# delivery method rather than from taste:
#
#   1. A stock Mac has no `dialog` and no `whiptail`. Checked on macOS 26:
#      neither exists, so a full-screen curses interface is not an option and
#      this is a scrolling interface built from escape sequences.
#
#   2. Under `curl … | zsh`, standard input *is* the script. Every read here
#      goes to /dev/tty explicitly; a plain `read` would consume the remainder
#      of the program, and the failure surfaces as a syntax error fifty lines
#      later. ui_init binds that channel once and says so plainly if there is
#      none, which is a far better error than the one that eats the script.
#
#   3. Everything the user sees goes to fd 3, never to stdout. stdout stays
#      clean so `tmbox status --json` can be piped, and so the interface still
#      renders when stdout is redirected to a file.
#
# Every prompt takes a key and can be answered in advance - see lib/answers.zsh.
# There is no interaction in tmbox that cannot also be supplied as a flag.

typeset -gi TMBOX_UI_FD=3
typeset -gi TMBOX_UI_WIDTH=80
typeset -gi TMBOX_UI_COLOR=0
typeset -gi TMBOX_UI_UTF8=0
typeset -gi TMBOX_UI_INTERACTIVE=0
typeset -gi TMBOX_ASSUME_YES="${TMBOX_ASSUME_YES:-0}"

# Confirmations --yes may not answer. Everything tmbox creates is rebuildable in
# ten minutes; the Storage Box holds the only copy of the user's backups. Those
# confirmations get their own flag, typed on purpose.
typeset -ga TMBOX_NEVER_ASSUME=(
  CONFIRM_DELETE_BOX
  DELETE_STORAGE_BOX
)

# Glyphs, resolved once in ui_init. UTF-8 is the common case; the ASCII set
# exists because a locale-less ssh session renders box-drawing characters as
# mojibake, which reads as a broken program rather than a plain one.
typeset -g G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_H='-' G_V='|'
typeset -g G_OK='ok' G_BAD='X' G_WARN='!' G_ARROW='>' G_DOT='*'
typeset -ga UI_SPIN_FRAMES=('-' '\' '|' '/')

# SGR sequences, empty when colour is off, so every call site can interpolate
# them unconditionally.
typeset -g C_RESET='' C_BOLD='' C_DIM=''
typeset -g C_ACCENT='' C_OK='' C_WARN='' C_ERR='' C_MUTED=''

typeset -g TMBOX_ESC=$'\033'

# --- setup ------------------------------------------------------------------

# ui_init [--no-tty-ok]
#
# Bind fd 3, work out what the terminal can do, and size the layout. Call once,
# early. With --no-tty-ok a missing terminal is tolerated and output falls back
# to stderr - that is for `tmbox status` in a cron job, never for `setup`.
ui_init() {
  local tty_optional=0
  [[ "${1:-}" == "--no-tty-ok" ]] && tty_optional=1
  # Running unattended is a deliberate statement that nobody is there to answer,
  # so the absence of a terminal is expected rather than an error.
  (( TMBOX_NONINTERACTIVE )) && tty_optional=1

  # The braces matter: a redirection failure on `exec` is reported by the shell
  # itself, and `exec … 2>/dev/null` does not suppress it because the message is
  # emitted while the redirection is being set up. Wrapping the whole compound
  # command is what actually silences "Device not configured" - the normal case
  # in a build log, and not an error worth printing.
  if [[ -r /dev/tty && -w /dev/tty ]] && { exec 3<>/dev/tty } 2>/dev/null; then
    TMBOX_UI_INTERACTIVE=1
  elif (( tty_optional )); then
    exec 3>&2
    TMBOX_UI_INTERACTIVE=0
  else
    # Deliberately verbose: this is what a user hits when they pipe the script
    # into a context with no terminal, and the fix is not guessable.
    cat >&2 <<'EOF'
tmbox needs a terminal to ask you questions, and there isn't one here.

That usually means it was run from a script, a CI job, or an editor's output
pane. Either download it and run it from a terminal:

    curl -fsSLO https://github.com/lab22poland/tmbox/releases/latest/download/tmbox.zsh
    curl -fsSLO https://github.com/lab22poland/tmbox/releases/latest/download/tmbox.zsh.sha256
    shasum -a 256 -c tmbox.zsh.sha256
    zsh tmbox.zsh setup

or answer every question in advance and run it unattended:

    zsh tmbox.zsh setup --non-interactive --answers ./my.answers
EOF
    return 1
  fi

  # Width: the terminal's, clamped. Wider than 80 makes prose hard to read and
  # makes the panels look like tables; narrower than 48 makes them unusable.
  local -i cols=0
  if (( TMBOX_UI_INTERACTIVE )); then
    cols="${$(stty size < /dev/tty 2>/dev/null)[(w)2]:-0}"
    (( cols )) || cols="${COLUMNS:-0}"
    (( cols )) || cols="$(tput cols 2>/dev/null || print 0)"
  fi
  (( cols >= 48 )) || cols=80
  (( cols <= 80 )) || cols=80
  TMBOX_UI_WIDTH=$cols

  # Colour: honour NO_COLOR, and never emit escapes into something that is not a
  # terminal. TMBOX_FORCE_COLOR overrides the second half for destinations that
  # are not a tty but do understand escapes - `make demo` in a build log, or a
  # pipe into `less -R`.
  if [[ -n "${NO_COLOR:-}" || "${TERM:-dumb}" == "dumb" ]]; then
    TMBOX_UI_COLOR=0
  elif [[ -n "${TMBOX_FORCE_COLOR:-}" ]] || (( TMBOX_UI_INTERACTIVE )); then
    TMBOX_UI_COLOR=1
  else
    TMBOX_UI_COLOR=0
  fi

  if (( TMBOX_UI_COLOR )); then
    C_RESET="${TMBOX_ESC}[0m"
    C_BOLD="${TMBOX_ESC}[1m"
    C_DIM="${TMBOX_ESC}[2m"
    # 256-colour indexes rather than the basic eight: the basic palette is
    # remapped by most terminal themes, and "green" landing on a beige that is
    # illegible on a light background is a real failure mode for a wizard that
    # uses colour to distinguish a warning from a success.
    C_ACCENT="${TMBOX_ESC}[38;5;38m"    # deep sky blue
    C_OK="${TMBOX_ESC}[38;5;42m"        # green
    C_WARN="${TMBOX_ESC}[38;5;214m"     # amber
    C_ERR="${TMBOX_ESC}[38;5;203m"      # soft red
    C_MUTED="${TMBOX_ESC}[38;5;245m"    # grey
  fi

  # UTF-8: only if the locale says so. Guessing wrong produces mojibake.
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *(utf8|UTF8|utf-8|UTF-8)*) TMBOX_UI_UTF8=1 ;;
    *) TMBOX_UI_UTF8=0 ;;
  esac

  if (( TMBOX_UI_UTF8 )); then
    G_TL='╭'; G_TR='╮'; G_BL='╰'; G_BR='╯'; G_H='─'; G_V='│'
    G_OK='✓'; G_BAD='✗'; G_WARN='▲'; G_ARROW='→'; G_DOT='•'
    UI_SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  fi

  return 0
}

ui_is_interactive() { (( TMBOX_UI_INTERACTIVE )) }

# --- primitives -------------------------------------------------------------

_ui_out() { print -r -- "$*" >&$TMBOX_UI_FD }
_ui_raw() { print -rn -- "$*" >&$TMBOX_UI_FD }

# _ui_rep <string> <count> - a string repeated, without a shell loop
_ui_rep() {
  local s="$1"; local -i n="$2"
  (( n > 0 )) || return 0
  print -rn -- "${(pl:$n::$s:):-}"
}

# _ui_vislen <string> - length in printable characters
#
# zsh counts characters rather than bytes, so the only thing to remove is the
# SGR sequences. Under bash 3.2 this needed an awk subprocess and still got
# multibyte text wrong, which is what made box borders ragged.
_ui_vislen() {
  local s="${1//${TMBOX_ESC}\[[0-9;]#m/}"
  print -rn -- ${#s}
}

ui_blank() { _ui_out "" }

# --- text -------------------------------------------------------------------

# ui_say <text...> - body text, wrapped and indented to the layout
ui_say() {
  # `fold -s` breaks at a space and keeps it, leaving a trailing blank on every
  # wrapped line. Invisible on screen, but it shows up in a transcript pasted
  # into a support mail, so strip it here rather than explaining it later.
  print -r -- "$*" \
    | fold -s -w $(( TMBOX_UI_WIDTH - 4 )) \
    | sed -e 's/[[:space:]]*$//' -e 's/^/  /' >&$TMBOX_UI_FD
}

ui_dim() { ui_say "${C_MUTED}$*${C_RESET}" }

# Status lines. The glyph carries the meaning when colour is off, which is the
# only reason there is one.
ui_ok()   { _ui_out "  ${C_OK}${G_OK}${C_RESET} $*" }
ui_bad()  { _ui_out "  ${C_ERR}${G_BAD}${C_RESET} $*" }
ui_warn() { _ui_out "  ${C_WARN}${G_WARN}${C_RESET} $*" }
ui_item() { _ui_out "  ${C_MUTED}${G_DOT}${C_RESET} $*" }
ui_next() { _ui_out "  ${C_ACCENT}${G_ARROW}${C_RESET} $*" }

# ui_kv <key> <value...> - aligned two-column row
ui_kv() {
  local k="$1"; shift
  local -i gap=$(( 18 - $(_ui_vislen "$k") ))
  (( gap >= 1 )) || gap=1
  _ui_out "  ${C_MUTED}${k}${C_RESET}$(_ui_rep ' ' $gap)$*"
}

# --- structure --------------------------------------------------------------

ui_rule() {
  local label="${1:-}"
  local -i inner=$(( TMBOX_UI_WIDTH - 4 ))
  if [[ -z "$label" ]]; then
    _ui_out "  ${C_MUTED}$(_ui_rep "$G_H" $inner)${C_RESET}"
    return
  fi
  local -i tail=$(( inner - $(_ui_vislen "$label") - 3 ))
  (( tail >= 0 )) || tail=0
  _ui_out "  ${C_MUTED}${G_H}${G_H}${C_RESET} ${C_BOLD}${label}${C_RESET} ${C_MUTED}$(_ui_rep "$G_H" $tail)${C_RESET}"
}

# ui_banner <title> [subtitle]
ui_banner() {
  local title="$1" sub="${2:-}"
  local -i inner=$(( TMBOX_UI_WIDTH - 4 ))
  ui_blank
  _ui_out "  ${C_ACCENT}${G_TL}$(_ui_rep "$G_H" $inner)${G_TR}${C_RESET}"
  _ui_banner_line "${C_BOLD}${title}${C_RESET}" $inner
  [[ -n "$sub" ]] && _ui_banner_line "${C_MUTED}${sub}${C_RESET}" $inner
  _ui_out "  ${C_ACCENT}${G_BL}$(_ui_rep "$G_H" $inner)${G_BR}${C_RESET}"
  ui_blank
}

_ui_banner_line() {
  local text="$1"; local -i inner="$2"
  local -i gap=$(( inner - $(_ui_vislen "$text") - 2 ))
  (( gap >= 0 )) || gap=0
  _ui_out "  ${C_ACCENT}${G_V}${C_RESET} ${text}$(_ui_rep ' ' $gap) ${C_ACCENT}${G_V}${C_RESET}"
}

# ui_step <n> <total> <title>
#
# The step counter is not decoration. The flow is nine steps and resumable, and
# a user coming back after a failure needs to see where they are before they see
# anything else.
ui_step() {
  ui_blank
  ui_rule "${C_ACCENT}${1}/${2}${C_RESET}  ${3}"
  ui_blank
}

# --- waiting ----------------------------------------------------------------
#
# Anything taking more than a second or two gets a spinner with an elapsed
# clock. Provisioning a server is ninety seconds and preallocating a container
# is minutes; a silent terminal during either reads as a hang.

typeset -g  TMBOX_SPIN_PID=""
typeset -g  TMBOX_SPIN_MSG=""
typeset -gi TMBOX_SPIN_START=0

_ui_epoch() {
  if (( ${+EPOCHSECONDS} )); then print -rn -- $EPOCHSECONDS; else date +%s; fi
}

ui_spin_start() {
  TMBOX_SPIN_MSG="$*"
  TMBOX_SPIN_START=$(_ui_epoch)

  # No animation without a terminal: the frames would be hundreds of lines in a
  # log file. The message still appears, so an unattended transcript reads the
  # same as an attended one minus the motion.
  if (( ! TMBOX_UI_INTERACTIVE || ! TMBOX_UI_COLOR )); then
    _ui_out "  ${G_DOT} ${TMBOX_SPIN_MSG}…"
    return 0
  fi

  (
    trap 'exit 0' TERM INT
    local frame; local -i elapsed
    while :; do
      for frame in $UI_SPIN_FRAMES; do
        elapsed=$(( $(_ui_epoch) - TMBOX_SPIN_START ))
        print -rn -- $'\r'"${TMBOX_ESC}[K  ${C_ACCENT}${frame}${C_RESET} ${TMBOX_SPIN_MSG} ${C_MUTED}(${elapsed}s)${C_RESET}" >&$TMBOX_UI_FD
        sleep 0.1
      done
    done
  ) &
  TMBOX_SPIN_PID=$!
  # Keep the job out of the shell's notification path, or zsh prints its own
  # "terminated" line over the interface when the spinner is stopped.
  disown %% 2>/dev/null
}

# ui_spin_stop <ok|bad|warn> [message]
#
# Always call this, including on the error path - a spinner left running writes
# over whatever is printed next.
ui_spin_stop() {
  # Not `status`: that name is read-only in zsh, an alias for $?. Assigning to
  # it aborts the function, which in this one would leave the spinner running
  # and writing over everything printed afterwards.
  local outcome="${1:-ok}" msg="${2:-$TMBOX_SPIN_MSG}"

  # Nothing to stop. ui_die calls this unconditionally so that a failure during
  # a wait cannot leave the animation running, which means it is routinely
  # called when no spinner was ever started - and with TMBOX_SPIN_START still
  # zero the elapsed time came out as the whole Unix epoch.
  if (( TMBOX_SPIN_START == 0 )) && [[ -z "$TMBOX_SPIN_PID" ]]; then
    return 0
  fi

  local -i elapsed=$(( $(_ui_epoch) - TMBOX_SPIN_START ))
  TMBOX_SPIN_START=0

  if [[ -n "$TMBOX_SPIN_PID" ]]; then
    kill "$TMBOX_SPIN_PID" 2>/dev/null
    wait "$TMBOX_SPIN_PID" 2>/dev/null
    TMBOX_SPIN_PID=""
    _ui_raw $'\r'"${TMBOX_ESC}[K"
  fi

  local took=""
  (( elapsed >= 2 )) && took=" ${C_MUTED}(${elapsed}s)${C_RESET}"

  case "$outcome" in
    ok)   _ui_out "  ${C_OK}${G_OK}${C_RESET} ${msg}${took}" ;;
    bad)  _ui_out "  ${C_ERR}${G_BAD}${C_RESET} ${msg}${took}" ;;
    warn) _ui_out "  ${C_WARN}${G_WARN}${C_RESET} ${msg}${took}" ;;
    *)    _ui_out "  ${G_DOT} ${msg}${took}" ;;
  esac
}

# ui_progress <current> <total> [label]
#
# Redraws in place. Used for the two long operations with a knowable end: the
# `dd` preallocation of the container, and the first backup.
ui_progress() {
  local -i cur="$1" total="$2"
  local label="${3:-}"
  (( total > 0 )) || total=1
  (( cur <= total )) || cur=$total

  # Without a terminal, in-place redraw would emit one line per tick. Print at
  # each decile instead, so a log records progress without drowning in it.
  if (( ! TMBOX_UI_INTERACTIVE )); then
    local -i pct=$(( cur * 100 / total ))
    (( pct % 10 == 0 && cur > 0 )) && _ui_out "  ${G_DOT} ${pct}%  ${label}"
    return 0
  fi

  local -i barw=$(( TMBOX_UI_WIDTH - 24 ))
  (( barw >= 10 )) || barw=10
  local -i pct=$(( cur * 100 / total ))
  local -i fill=$(( cur * barw / total ))

  local lb rb
  if (( TMBOX_UI_UTF8 )); then lb='█'; rb='░'; else lb='#'; rb='.'; fi

  _ui_raw "$(printf '\r%s[K  %s%s%s%s%s%s %3d%%  %s' \
    "$TMBOX_ESC" \
    "$C_ACCENT" "$(_ui_rep "$lb" $fill)" "$C_RESET" \
    "$C_MUTED"  "$(_ui_rep "$rb" $(( barw - fill )))" "$C_RESET" \
    "$pct" "$label")"

  (( cur >= total )) && _ui_raw $'\n'
  return 0
}

# --- prompts ----------------------------------------------------------------
#
# Every prompt takes a KEY, and every prompt can therefore be answered in
# advance - see lib/answers.zsh. Nothing in tmbox requires a human if the caller
# already knows the answer, which is what makes the flow testable in a guest VM
# and scriptable for anyone provisioning more than one Mac.
#
# When an answer is registered the prompt is not drawn; a line is printed saying
# what was used and where it came from, so an unattended run still produces a
# readable transcript rather than a silent one.

# ui_ask <key> <prompt> [default] - answer on stdout
ui_ask() {
  local key="$1" prompt="$2" def="${3:-}" reply=""

  if ans_has "$key"; then
    reply="$(ans_get "$key")"
    _ui_out "  ${C_MUTED}${G_ARROW} ${prompt}: ${C_RESET}${reply} ${C_MUTED}($(ans_source "$key"))${C_RESET}"
    print -rn -- "$reply"
    return 0
  fi

  if (( TMBOX_NONINTERACTIVE )); then
    [[ -n "$def" ]] || ans_require "$key" "$prompt"
    _ui_out "  ${C_MUTED}${G_ARROW} ${prompt}: ${C_RESET}${def} ${C_MUTED}(default)${C_RESET}"
    print -rn -- "$def"
    return 0
  fi

  local hint=""
  [[ -n "$def" ]] && hint=" ${C_MUTED}[${def}]${C_RESET}"
  _ui_raw "  ${C_ACCENT}${G_ARROW}${C_RESET} ${prompt}${hint}: "
  IFS= read -r reply <&$TMBOX_UI_FD || reply=""
  [[ -n "$reply" ]] || reply="$def"
  print -rn -- "$reply"
}

# ui_ask_secret <key> <prompt> - answer on stdout, never echoed
#
# A pre-answered secret is acknowledged but never printed, unlike ui_ask.
ui_ask_secret() {
  local key="$1" prompt="$2" reply=""

  if ans_has "$key"; then
    _ui_out "  ${C_MUTED}${G_ARROW} ${prompt}: [supplied] ($(ans_source "$key"))${C_RESET}"
    ans_get "$key"
    return 0
  fi

  (( TMBOX_NONINTERACTIVE )) && ans_require "$key" "$prompt"

  _ui_raw "  ${C_ACCENT}${G_ARROW}${C_RESET} ${prompt}: "
  # -s suppresses the echo and swallows the newline the user typed, so the next
  # line would otherwise start mid-prompt.
  IFS= read -rs reply <&$TMBOX_UI_FD || reply=""
  _ui_raw $'\n'
  print -rn -- "$reply"
}

# ui_confirm <key> <question> [y|n] - status 0 for yes
#
# Unattended, a confirmation falls back to its default rather than erroring -
# with one exception the callers enforce: the commitment point that creates
# billable resources, and the recovery-card gate, both pass a default of "n", so
# an unattended run stops there unless the operator said yes explicitly.
ui_confirm() {
  local key="$1" q="$2" def="${3:-n}" reply="" hint

  # --yes answers the ordinary confirmations - "create these resources",
  # "remove these resources" - so an unattended run does not need a flag per
  # question. It deliberately does not answer the ones that destroy data
  # irreversibly: those are listed in TMBOX_NEVER_ASSUME and need their own
  # explicit flag, because a blanket --yes is exactly the shape of the mistake
  # that deletes someone's only copy of their backups.
  if (( ${TMBOX_ASSUME_YES:-0} )) && ! ans_has "$key"; then
    if (( ! ${TMBOX_NEVER_ASSUME[(Ie)$(ans_norm "$key")]} )); then
      _ui_out "  ${C_MUTED}${G_ARROW} ${q} yes (--yes)${C_RESET}"
      return 0
    fi
  fi

  if ans_has "$key"; then
    case "$(ans_get "$key")" in
      y|Y|yes|YES|Yes|true|1)
        _ui_out "  ${C_MUTED}${G_ARROW} ${q} yes ($(ans_source "$key"))${C_RESET}"; return 0 ;;
      *)
        _ui_out "  ${C_MUTED}${G_ARROW} ${q} no ($(ans_source "$key"))${C_RESET}";  return 1 ;;
    esac
  fi

  if (( TMBOX_NONINTERACTIVE )); then
    _ui_out "  ${C_MUTED}${G_ARROW} ${q} ${def} (default)${C_RESET}"
    [[ "$def" == "y" ]]
    return $?
  fi

  [[ "$def" == "y" ]] && hint="Y/n" || hint="y/N"
  while :; do
    _ui_raw "  ${C_ACCENT}${G_ARROW}${C_RESET} ${q} ${C_MUTED}[${hint}]${C_RESET} "
    IFS= read -r reply <&$TMBOX_UI_FD || reply=""
    [[ -n "$reply" ]] || reply="$def"
    case "$reply" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No)    return 1 ;;
      *) ui_warn "Please answer y or n." ;;
    esac
  done
}

# ui_menu <key> <title> <value> <label> <description> [...] - chosen VALUE on stdout
#
# The value is printed, not the position: a pre-answer reads `--capacity 2TB`,
# which stays correct when the list is reordered, whereas `--capacity 2` would
# silently start meaning something else.
#
# Values, labels and descriptions come in threes so a choice can explain itself.
# This wizard asks people to pick a capacity and a region, and a bare list of
# names is not enough to decide on.
ui_menu() {
  local key="$1" title="$2"; shift 2
  local -a triples=("$@")

  # Every third element, starting at the first. zsh array slices take no stride
  # argument - ${a[1,-1,3]} is a bad substitution, not a step - so this is a
  # loop rather than a subscript.
  local -a values=()
  local -i vi=1
  while (( vi <= ${#triples} )); do
    values+=("${triples[vi]}")
    (( vi += 3 ))
  done

  if ans_has "$key"; then
    local reply; reply="$(ans_get "$key")"
    if (( ${values[(Ie)$reply]} )); then
      _ui_out "  ${C_MUTED}${G_ARROW} ${title}: ${C_RESET}${reply} ${C_MUTED}($(ans_source "$key"))${C_RESET}"
      print -rn -- "$reply"
      return 0
    fi
    ui_bad "\"${reply}\" is not a valid choice for ${title}."
    ui_say "Valid values: ${(j:, :)values}"
    exit 2
  fi

  ui_blank
  _ui_out "  ${C_BOLD}${title}${C_RESET}"
  ui_blank
  local -i i=0
  while (( i * 3 < ${#triples} )); do
    _ui_out "    ${C_ACCENT}$(( i + 1 ))${C_RESET}  ${C_BOLD}${triples[i*3+2]}${C_RESET}  ${C_MUTED}${triples[i*3+1]}${C_RESET}"
    [[ -n "${triples[i*3+3]}" ]] && _ui_out "       ${C_MUTED}${triples[i*3+3]}${C_RESET}"
    (( i++ ))
  done
  ui_blank

  (( TMBOX_NONINTERACTIVE )) && ans_require "$key" "$title"

  local -i n=${#values}
  local reply
  while :; do
    reply="$(ui_ask "${key}_INDEX" "Choose 1-${n}" "1")"
    if [[ "$reply" == <-> ]] && (( reply >= 1 && reply <= n )); then
      print -rn -- "${values[reply]}"
      return 0
    fi
    ui_warn "Enter a number between 1 and ${n}."
  done
}

# ui_pause [message]
ui_pause() {
  (( TMBOX_NONINTERACTIVE )) && return 0
  _ui_raw "  ${C_MUTED}${1:-Press return to continue}…${C_RESET}"
  IFS= read -r _ <&$TMBOX_UI_FD
  _ui_raw $'\n'
  return 0
}

# --- native dialogs ---------------------------------------------------------
#
# osascript is kept for the rare moment where a terminal line is not enough,
# such as a notification. Everything else stays in the terminal, where the user
# can scroll back.

# AppleScript string literals take backslash and double-quote escapes and
# nothing else - a password or a path containing a quote would otherwise end the
# literal and be executed as script.
_ui_osa_quote() {
  local s="${1//\\/\\\\}"
  print -rn -- "\"${s//\"/\\\"}\""
}

ui_osa_notify() {
  (( $+commands[osascript] )) || return 0
  osascript -e "display notification $(_ui_osa_quote "$2") with title $(_ui_osa_quote "$1")" \
    >/dev/null 2>&1
  return 0
}

# --- endings ----------------------------------------------------------------

ui_die() {
  ui_spin_stop bad "failed" 2>/dev/null
  ui_blank
  ui_bad "$*"
  [[ -n "${TMBOX_LOG_FILE:-}" ]] && { ui_blank; ui_dim "Full transcript: ${TMBOX_LOG_FILE}" }
  ui_blank
  exit 1
}
