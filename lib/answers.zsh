#!/bin/zsh
#
# Pre-answered prompts, so nothing in tmbox requires a human if the caller
# already knows what the human would say.
#
# Every interactive call in lib/ui.zsh takes a key as its first argument. Before
# asking, it looks the key up here; if an answer is registered the prompt is
# skipped and the answer is echoed back with a note saying where it came from.
# That gives three things at once:
#
#   - automation: `tmbox setup --capacity 2TB --region fsn1 --yes` runs to
#     completion with no terminal input,
#   - testing: the Tart guest can drive the whole nine-step flow unattended,
#   - support: `--answers file` reproduces a user's run exactly.
#
# Precedence, highest first:
#
#   1. a command-line flag                  --capacity 2TB
#   2. an environment variable              TMBOX_ANSWER_CAPACITY=2TB
#   3. an answers file                      --answers ./run.answers
#   4. the prompt's own default
#
# In --non-interactive mode a missing answer is a hard error naming the flag
# that would have supplied it - never a silent default, and never a hang. A
# setup wizard that quietly picks for you is worse than one that stops.
#
# NOTE: no `emulate -L zsh` here, and none in any other library. `-L` scopes the
# reset to the enclosing function; a sourced file at top level has no such
# scope, so `emulate -L zsh` there behaves like a plain `emulate zsh` and
# permanently resets the caller's options. That silently turned extended_glob
# off once already, which broke the secret-matching pattern below and printed a
# token in plain text. Options are set once, by the entry point.

# Initialised only when absent, never reset. Sourcing a library must not undo
# what the caller already decided: a plain `typeset -gi TMBOX_NONINTERACTIVE=0`
# here silently re-enabled prompting for anyone who set the flag before loading
# the library, which is exactly what the test harness and the entry point both
# do. The same applies to the answer store - re-sourcing must not discard
# answers that are already registered.
(( ${+TMBOX_ANS} ))            || typeset -gA TMBOX_ANS=()
(( ${+TMBOX_ANSSRC} ))         || typeset -gA TMBOX_ANSSRC=()
typeset -gi TMBOX_NONINTERACTIVE="${TMBOX_NONINTERACTIVE:-0}"

# Every answer that can be given as `--flag value`, with a one-line description
# for the help text.
#
# Declared here, as data, rather than enumerated in the argument parser. The
# parser had a hand-written list twice and it went stale both times - once when
# destroy added a confirmation --yes did not cover, and once when step 6 added
# --container-mb and the parser rejected it as unknown. Adding an answer is now
# one line, in the file that owns the concept.
typeset -ga TMBOX_SETUP_FLAGS=(
  "capacity:How much space: 1TB, 2TB, 4TB, 5TB or 10TB"
  "region:Where to put it: fsn1, nbg1 or hel1"
  "mac-name:What to call this Mac's share"
  "hetzner-token:The Hetzner API token"
  "container-mb:Size of the pool's container file, in MiB"
  "backup-wait:Minutes to watch the first backup; 0 starts it and returns"
  "uplink-limit:Cap backups at this many Mbit/s; auto (80% of a measurement) or off"
  "zfs-passphrase:The appliance's dataset passphrase, for 'tmbox unlock'"
)

# ans_flag_names - just the flag names, for the parser
ans_flag_names() {
  local entry
  for entry in $TMBOX_SETUP_FLAGS; do print -r -- "${entry%%:*}"; done
}

# ans_norm <key> - the canonical key: upper case, [A-Z0-9_] only.
#
# Callers pass whatever reads best at the call site ("capacity", "storage-box",
# "CAPACITY"); normalising here means a flag, an environment variable and a file
# entry all land on the same key without each caller having to agree on a form.
ans_norm() {
  local k="${(U)1}"
  k="${k//[^A-Z0-9_]/_}"
  # Collapse and trim the separators, so `capacity!` and `storage--box` do not
  # become CAPACITY_ and STORAGE__BOX. This is what keeps ans_flag a true
  # inverse: an error message that names `--capacity-` names nothing.
  # Written as loops rather than with the `##` repetition operator, which would
  # need extended_glob and so would depend on the caller's options.
  while [[ "$k" == *__* ]]; do k="${k//__/_}"; done
  while [[ "$k" == _* ]];   do k="${k#_}";     done
  while [[ "$k" == *_ ]];   do k="${k%_}";     done
  print -rn -- "$k"
}

# ans_set <key> <value> [source]
ans_set() {
  local key; key="$(ans_norm "$1")"
  [[ -n "$key" ]] || return 1
  TMBOX_ANS[$key]="$2"
  TMBOX_ANSSRC[$key]="${3:-explicit}"
  return 0
}

# ans_has <key>
ans_has() {
  local key; key="$(ans_norm "$1")"
  (( ${+TMBOX_ANS[$key]} ))
}

# ans_get <key>
ans_get() {
  local key; key="$(ans_norm "$1")"
  print -rn -- "${TMBOX_ANS[$key]:-}"
}

# ans_source <key> - where the answer came from, for the "using X" line
ans_source() {
  local key; key="$(ans_norm "$1")"
  print -rn -- "${TMBOX_ANSSRC[$key]:-explicit}"
}

# ans_flag <key> - the command-line flag that would supply this key
#
# Kept next to ans_norm so the two stay each other's inverse: an error message
# that names a flag which does not exist is worse than no error message.
ans_flag() {
  local key; key="$(ans_norm "$1")"
  print -rn -- "--${${(L)key}//_/-}"
}

# ans_from_env
#
# Import TMBOX_ANSWER_<KEY> from the environment. Lower precedence than a flag,
# which is why flags are parsed after this runs.
ans_from_env() {
  local name key
  for name in ${(k)parameters[(I)TMBOX_ANSWER_*]}; do
    # Exported parameters only. ${(k)parameters} lists every shell variable, not
    # just the environment, so an ordinary internal variable sharing the prefix
    # was imported as though the user had set it - which is how the array
    # declaring the flags briefly became an answer called FLAGS. To be an
    # answer, a value has to come from outside this process.
    [[ "${(tP)name}" == *export* ]] || continue
    key="${name#TMBOX_ANSWER_}"
    ans_has "$key" || ans_set "$key" "${(P)name}" "environment"
  done
}

# ans_from_file <path>
#
# KEY=value, one per line; # comments and blank lines ignored. The value is
# taken literally to the end of the line - no quoting rules, because a password
# containing a quote is far likelier than one containing a newline, and a
# quoting scheme here would mangle the former to permit the latter.
ans_from_file() {
  # The variable is `file` for a reason: in zsh the name `path` is tied to
  # $PATH, so declaring it as a local replaces the command search path for the
  # whole function and every command called inside it stops resolving.
  local file="$1" line key value
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == '#'* ]] && continue
    [[ "$line" == *=* ]] || continue
    # A key can never contain whitespace - ans_norm would fold it to _ anyway -
    # so removing all of it is both correct and free of the `#` repetition
    # operator, which would need extended_glob.
    key="${${line%%=*}//[[:space:]]/}"
    value="${line#*=}"
    ans_has "$key" || ans_set "$key" "$value" "${file:t}"
  done < "$file"
  return 0
}

# ans_require <key> <what>
#
# Called by a prompt when running non-interactively with no answer available.
# Names the exact flag that would have supplied it, because "missing answer" on
# its own just sends the user back to the documentation.
ans_require() {
  local key="$1" what="$2"
  ui_bad "No answer for $what, and there is no terminal to ask on."
  ui_blank
  ui_say "Supply it with one of:"
  ui_item "$(ans_flag "$key") <value>"
  ui_item "TMBOX_ANSWER_$(ans_norm "$key")=<value> in the environment"
  ui_item "$(ans_norm "$key")=<value> in a file passed to --answers"
  ui_blank
  exit 2
}

# ans_is_secret <key>
#
# Whether a key's value must never be printed. Matched on the name rather than
# tracked per answer, so a new secret-carrying prompt is covered by naming it
# sensibly rather than by remembering to register it.
#
# The pattern is plain alternation with no (#i) flag: ans_norm has already
# upper-cased the key, and (#i) needs extended_glob, which makes this depend on
# an option the caller controls. When that option was off the pattern silently
# matched nothing and ans_dump printed an API token in the clear - so this is
# written to be correct under default options, not under the right ones.
ans_is_secret() {
  local key; key="$(ans_norm "$1")"
  case "$key" in
    *PASSWORD*|*PASSPHRASE*|*TOKEN*|*SECRET*|*PRIVATE_KEY*) return 0 ;;
  esac
  return 1
}

# ans_dump
#
# Every answer in force, secrets masked. Printed by --show-answers and recorded
# at the top of the transcript, so a support mail carries the inputs as well as
# the outcome.
ans_dump() {
  local key
  for key in ${(ok)TMBOX_ANS}; do
    if ans_is_secret "$key"; then
      print -r -- "$key=[hidden] (${TMBOX_ANSSRC[$key]})"
    else
      print -r -- "$key=${TMBOX_ANS[$key]} (${TMBOX_ANSSRC[$key]})"
    fi
  done
}
