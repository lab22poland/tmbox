#!/bin/zsh
#
# Credentials, in mode-600 files under the state directory.
#
# This used the login keychain first, and was moved for two reasons.
#
# **It prompted.** `security add-generic-password -T /usr/bin/security` puts the
# security binary on the item's access list, but macOS evaluates that list
# against the calling process's code signature and context. Read the same item
# from a different session, from a LaunchAgent, or from anything not descended
# from the process that created it, and the user gets an authorisation dialog -
# at login, unprompted, for a backup that is meant to be automatic. A tool that
# asks for the account password at unpredictable moments is a tool people stop
# using.
#
# **It was not protecting much anyway.** `security`'s password reader truncates
# silently at 128 characters, so the SSH private keys - an Ed25519 key is 532
# characters once encoded - had to live in files regardless. The key granting a
# root shell on the appliance was already on disk; putting the passwords behind
# a keychain the keys were not behind bought inconsistency rather than security.
#
# So it all lives in one place, with one set of permissions:
#
#     ~/.config/tmbox/secrets/   0700
#     ~/.config/tmbox/secrets/*  0600
#
# **What that does and does not protect.** At rest the protection is FileVault,
# on by default on macOS 26, so a stolen Mac gives up nothing without the login
# password. While the Mac is running and unlocked, anything running as this user
# - and root - can read these files. That is exactly the exposure of ~/.ssh, and
# it is the honest position: tmbox does not defend against code already running
# as you.
#
# The protection that matters for the backups themselves does not depend on any
# of this. Time Machine encryption, whose password the user chooses and tmbox
# never stores, is what makes the backups unreadable to anyone holding the
# appliance or the Storage Box.
#
# The function names keep the kc_ prefix from when this was the keychain, so
# every caller stayed unchanged when the storage did.

typeset -g TMBOX_SECRET_DIR="${TMBOX_SECRET_DIR:-$TMBOX_STATE_DIR/secrets}"

# The credentials tmbox keeps. Named here rather than scattered through the
# flow, so destroy and doctor both work from one list and a new credential
# cannot be added without appearing in both.
typeset -ga TMBOX_CREDENTIAL_KINDS=(
  hetzner-token          # the Console API token; the only one shared with Hetzner
  storagebox-password    # the box owner's password
  subaccount-password    # what the appliance actually mounts with
  samba-password         # what Time Machine authenticates with
  zfs-passphrase         # unlocks the dataset; never written to the appliance
)

# kc_path <kind>
#
# The name is reduced to [a-z0-9-], so a kind can never contain a slash or a
# `..` and escape the directory. Nothing passes a user-supplied kind today, and
# this is what keeps that safe if something ever does.
kc_path() {
  local kind="${(L)1}"
  kind="${kind//[^a-z0-9-]/-}"
  print -rn -- "${TMBOX_SECRET_DIR}/${kind}"
}

kc_init() {
  mkdir -p -- "$TMBOX_SECRET_DIR" || return 1
  chmod 0700 "$TMBOX_SECRET_DIR" 2>/dev/null
  return 0
}

# kc_set <kind> <value>
kc_set() {
  local kind="$1" value="$2"
  kc_init || { log_error "could not create $TMBOX_SECRET_DIR"; return 1 }

  # Registered for redaction before being stored, so a value that reaches the
  # transcript by some other route is masked there too.
  log_secret "$value"

  local file; file="$(kc_path "$kind")"
  # umask inside a subshell, so the file is never briefly world-readable.
  # Creating it and then chmod-ing leaves a window, and a window is all it takes.
  ( umask 077; print -rn -- "$value" > "$file" ) || {
    log_error "could not write $kind"
    return 1
  }

  # Verified by reading back. Cheap, and it turns a full disk into an error here
  # rather than into a credential that silently does not work days later.
  local check; check="$(kc_get "$kind")" || check=""
  if [[ "$check" != "$value" ]]; then
    log_error "$kind did not store correctly (read back ${#check} bytes, expected ${#value})"
    return 1
  fi

  log_debug "stored $kind"
  return 0
}

# kc_get <kind> - the value on stdout; non-zero if absent
kc_get() {
  local file; file="$(kc_path "$1")"
  [[ -f "$file" ]] || return 1
  local value; value="$(cat -- "$file")" || return 1
  [[ -n "$value" ]] || return 1
  log_secret "$value"
  print -rn -- "$value"
  return 0
}

kc_has() { local f; f="$(kc_path "$1")"; [[ -s "$f" ]] }

# kc_delete <kind>
#
# Truncated before unlinking. On an SSD that is not a guarantee - the controller
# may have written the data elsewhere - but it costs nothing and removes the
# value from any copy still reachable through the filesystem.
kc_delete() {
  local file; file="$(kc_path "$1")"
  [[ -f "$file" ]] || return 0
  : > "$file" 2>/dev/null
  rm -f -- "$file"
  return 0
}

kc_delete_all() {
  local kind
  for kind in $TMBOX_CREDENTIAL_KINDS; do kc_delete "$kind"; done
  rmdir -- "$TMBOX_SECRET_DIR" 2>/dev/null
  return 0
}

# kc_audit
#
# Any credential file that is not 0600, or a directory that is not 0700.
# `tmbox doctor` reports these: an unusual umask, a restore from a backup, or a
# copy onto a shared volume can all widen them, and nothing else would notice.
kc_audit() {
  [[ -d "$TMBOX_SECRET_DIR" ]] || return 0
  local -a bad=()
  local mode file
  mode="$(stat -f '%OLp' "$TMBOX_SECRET_DIR" 2>/dev/null)"
  [[ "$mode" == "700" ]] || bad+=("${TMBOX_SECRET_DIR} is $mode, expected 700")

  for file in "$TMBOX_SECRET_DIR"/*(N.); do
    mode="$(stat -f '%OLp' "$file" 2>/dev/null)"
    [[ "$mode" == "600" ]] || bad+=("${file:t} is $mode, expected 600")
  done

  (( ${#bad} == 0 )) && return 0
  print -rl -- $bad
  return 1
}

# kc_list - which credentials are present, for doctor
kc_list() {
  local kind
  for kind in $TMBOX_CREDENTIAL_KINDS; do
    if kc_has "$kind"; then
      print -r -- "$kind present"
    else
      print -r -- "$kind missing"
    fi
  done
}
