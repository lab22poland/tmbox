#!/bin/zsh
#
# Diagnostics, kept strictly apart from the interface.
#
# lib/ui.zsh talks to the person sitting there. This file talks to whoever reads
# the transcript afterwards - us, on a support mail, with no access to the
# machine. The two have opposite requirements: the interface hides detail, and
# the transcript keeps all of it, including timestamps and the exact command
# that failed.
#
# The transcript is a plain file under the state directory, one line per event,
# and it is the first thing `tmbox doctor` offers to show. It must never contain
# a secret: every line routes through log_redact, and every caller holding a
# credential is expected to register it with log_secret, so that a value which
# later reaches the log by accident is masked anyway.

zmodload zsh/datetime 2>/dev/null

typeset -g TMBOX_LOG_FILE="${TMBOX_LOG_FILE:-}"
typeset -g TMBOX_LOG_LEVEL="${TMBOX_LOG_LEVEL:-info}"   # debug|info|warn|error
# Never reset: re-sourcing this file must not discard the secrets already
# registered for redaction, or lines logged afterwards would print them.
(( ${+TMBOX_LOG_SECRETS} )) || typeset -ga TMBOX_LOG_SECRETS=()

_log_level_num() {
  case "$1" in
    debug) print -rn -- 10 ;;
    info)  print -rn -- 20 ;;
    warn)  print -rn -- 30 ;;
    error) print -rn -- 40 ;;
    *)     print -rn -- 20 ;;
  esac
}

_log_now() {
  # zsh/datetime gives this without forking; `date` is the fallback for the
  # improbable case where the module is unavailable.
  if (( ${+EPOCHSECONDS} )); then
    strftime '%Y-%m-%dT%H:%M:%SZ' $(( EPOCHSECONDS )) 2>/dev/null && return
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# log_open <path>
#
# Start (or continue) a transcript. Appends rather than truncates: a resumed
# setup is one story, not several, and the previous attempt is usually the
# interesting half. Failure to open is never fatal - losing the log is a
# nuisance, losing the run is not acceptable.
log_open() {
  TMBOX_LOG_FILE="$1"
  mkdir -p -- "${TMBOX_LOG_FILE:h}" 2>/dev/null || { TMBOX_LOG_FILE=""; return 0 }
  : >> "$TMBOX_LOG_FILE" 2>/dev/null   || { TMBOX_LOG_FILE=""; return 0 }
  chmod 0600 "$TMBOX_LOG_FILE" 2>/dev/null
  log_raw "--- tmbox ${TMBOX_VERSION:-dev} starting, pid $$ ---"
  return 0
}

# log_secret <value>
#
# Register a value to be masked wherever it appears. Short values are ignored:
# masking every occurrence of a three-character string would shred the log, and
# nothing tmbox generates is that short.
log_secret() {
  local v="$1"
  (( ${#v} >= 8 )) || return 0
  (( ${TMBOX_LOG_SECRETS[(Ie)$v]} )) && return 0
  TMBOX_LOG_SECRETS+=("$v")
  return 0
}

# log_redact <text...>
#
# Replace every registered secret with a fixed marker. Deliberately a literal
# substitution: a password can contain any character a pattern would treat as
# syntax, so ${text//$s/...} is used with $s quoted rather than any form that
# would interpret it.
log_redact() {
  local text="$*" s
  for s in $TMBOX_LOG_SECRETS; do
    text="${text//"$s"/[REDACTED]}"
  done
  print -rn -- "$text"
}

log_raw() {
  [[ -n "$TMBOX_LOG_FILE" ]] || return 0
  print -r -- "$(_log_now) $(log_redact "$*")" >> "$TMBOX_LOG_FILE" 2>/dev/null
  return 0
}

_log_at() {
  local level="$1"; shift
  (( $(_log_level_num "$level") >= $(_log_level_num "$TMBOX_LOG_LEVEL") )) || return 0
  log_raw "${(r:5:)level} $*"
}

log_debug() { _log_at debug "$@" }
log_info()  { _log_at info  "$@" }
log_warn()  { _log_at warn  "$@" }
log_error() { _log_at error "$@" }

# log_run <description> <command...>
#
# Run a command, record it and its status, and keep its output in the transcript
# but off the screen. Returns the command's own status, so callers read
# naturally:
#
#   out="$(log_run 'import the pool' ssh $host zpool import tank)" || ui_die …
#
log_run() {
  local what="$1"; shift
  local out; local -i rc=0
  log_debug "run: $what -> $*"
  out="$("$@" 2>&1)" || rc=$?
  # Newlines folded to a record separator so one command is one log line and
  # `grep` over the transcript stays useful.
  [[ -n "$out" ]] && log_debug "out: ${out//$'\n'/$'\036'}"
  (( rc != 0 )) && log_error "$what failed with status $rc"
  print -rn -- "$out"
  return $rc
}

# log_path - where the transcript is, for the message that points a user at it
log_path() { print -rn -- "$TMBOX_LOG_FILE" }
