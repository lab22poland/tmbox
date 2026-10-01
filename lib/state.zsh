#!/bin/zsh
#
# What tmbox remembers between runs.
#
# Setup is nine steps, several of them minutes long, and any of them can fail on
# something outside our control - a network drop, a Hetzner hiccup, a closed
# laptop. Without state, a failure at step 7 means either starting again (and
# paying for a second server) or hand-editing the aftermath. With it, the same
# failure means running tmbox again.
#
# One rule governs the file: **no secrets, ever.** It gets copied by migrations
# and backups, and is the first thing anyone will paste into a support mail.
# Credentials live in the mode-600 files next door - see lib/secrets.zsh - and
# the state file holds only the identifiers needed to find them again. tmbox
# doctor checks the file for anything that looks like a credential and complains
# if it finds one, because a rule with no enforcement is a comment.
#
# The format is JSON so that jq can do the escaping. A previous generation of
# this kind of file used KEY=value, and every one of them eventually met a
# value containing a newline.
#
# **Why ~/.config and not ~/Library/Application Support.** Apple's guidance for
# Application Support addresses applications: bundles in /Applications that
# manage files on the user's behalf. tmbox is a command-line tool, and
# command-line tools on macOS overwhelmingly use ~/.config - git, gh, rclone,
# kubectl, terraform. Someone who wants to find, copy or delete what tmbox keeps
# will look there first, and it is a path they can type without quoting it.
#
# It all lives in this one directory rather than being split across
# XDG_CONFIG_HOME, XDG_STATE_HOME and XDG_DATA_HOME as strict XDG would have it.
# That split suits a tool whose config a human edits and whose state is
# disposable; here it is neither. `destroy` has to remove every trace and the
# recovery card has to name one place, so three directories would be three
# chances to leave a credential behind. gh and rclone make the same call, and
# keep their tokens under ~/.config too.

typeset -g TMBOX_STATE_DIR="${TMBOX_STATE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/tmbox}"
typeset -g TMBOX_STATE_FILE="${TMBOX_STATE_FILE:-$TMBOX_STATE_DIR/state.json}"

# state_init - create the directory and an empty document if needed
state_init() {
  mkdir -p -- "$TMBOX_STATE_DIR" || return 1
  # 0700: the file names the user's server, its address and their Storage Box.
  # None of that is a credential, and none of it is other users' business.
  chmod 0700 "$TMBOX_STATE_DIR" 2>/dev/null
  if [[ ! -f "$TMBOX_STATE_FILE" ]]; then
    ( umask 077; print -r -- '{"version":1}' > "$TMBOX_STATE_FILE" )
  fi
  # A truncated or hand-edited file must not take the run down silently. Move it
  # aside, say so, and start clean - the resources it described are still found
  # by their labels, so nothing is lost that cannot be recovered.
  if ! json_valid "$(cat -- "$TMBOX_STATE_FILE" 2>/dev/null)"; then
    local wrecked="${TMBOX_STATE_FILE}.broken.$(date -u +%Y%m%d%H%M%S)"
    mv -f -- "$TMBOX_STATE_FILE" "$wrecked" 2>/dev/null
    ( umask 077; print -r -- '{"version":1}' > "$TMBOX_STATE_FILE" )
    log_warn "state file was not valid JSON; moved to $wrecked"
  fi
  return 0
}

# state_get <key> [default]
state_get() {
  local key="$1" def="${2:-}" value
  [[ -f "$TMBOX_STATE_FILE" ]] || { print -rn -- "$def"; return 0 }
  value="$(jq -er --arg k "$key" '.[$k] // empty' < "$TMBOX_STATE_FILE" 2>/dev/null)" || value=""
  print -rn -- "${value:-$def}"
}

# state_set <key> <value> [key value...]
#
# Written to a temporary file in the same directory and renamed over the
# original, so an interrupted write cannot leave a half-file behind. That is not
# theoretical here: the value most often being written is the id of a server
# that now exists and is billing.
state_set() {
  state_init || return 1
  local -a args=()
  local filter="." key value
  local -i n=0
  while (( $# >= 2 )); do
    (( n++ ))
    args+=(--arg "k$n" "$1" --arg "v$n" "$2")
    filter+=" | .[\$k$n] = \$v$n"
    shift 2
  done
  (( n > 0 )) || return 0

  local tmp="${TMBOX_STATE_FILE}.new.$$"
  if jq $args "$filter" < "$TMBOX_STATE_FILE" > "$tmp" 2>/dev/null; then
    chmod 0600 "$tmp" 2>/dev/null
    mv -f -- "$tmp" "$TMBOX_STATE_FILE"
    return 0
  fi
  rm -f -- "$tmp"
  log_error "could not update the state file"
  return 1
}

# state_unset <key>
state_unset() {
  state_init || return 1
  local tmp="${TMBOX_STATE_FILE}.new.$$"
  if jq --arg k "$1" 'del(.[$k])' < "$TMBOX_STATE_FILE" > "$tmp" 2>/dev/null; then
    chmod 0600 "$tmp" 2>/dev/null
    mv -f -- "$tmp" "$TMBOX_STATE_FILE"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# state_has <key>
state_has() { [[ -n "$(state_get "$1")" ]] }

# state_clear - forget everything
#
# Called by `tmbox destroy` after the audit passes. Deliberately not before: if
# the teardown fails halfway, the state is the only record of what exists.
state_clear() {
  [[ -f "$TMBOX_STATE_FILE" ]] || return 0
  ( umask 077; print -r -- '{"version":1}' > "$TMBOX_STATE_FILE" )
  return 0
}

# state_dump - the whole document, for doctor and for a support mail
state_dump() {
  [[ -f "$TMBOX_STATE_FILE" ]] || { print -r -- "(no state file)"; return 0 }
  jq -S . < "$TMBOX_STATE_FILE" 2>/dev/null || cat -- "$TMBOX_STATE_FILE"
}

# state_audit_for_secrets
#
# The enforcement half of the no-secrets rule. Looks for keys whose names say
# they carry a credential, and for values shaped like one: a Hetzner token is 64
# hex-ish characters, an OpenSSH private key announces itself in its first line.
#
# Prints an offending key per line; returns 0 when the file is clean.
state_audit_for_secrets() {
  [[ -f "$TMBOX_STATE_FILE" ]] || return 0
  local -a bad
  bad=( ${(f)"$(jq -r '
    to_entries[]
    | select(
        (.key | test("password|passphrase|token|secret|private";"i"))
        or (.value | type == "string" and (
              test("^[A-Za-z0-9]{40,}$") or test("BEGIN [A-Z ]*PRIVATE KEY")))
      )
    | .key' < "$TMBOX_STATE_FILE" 2>/dev/null)"} )
  bad=( ${bad:#} )
  (( ${#bad} == 0 )) && return 0
  print -rl -- $bad
  return 1
}
