#!/bin/zsh
#
# The macOS side: Time Machine, SMB, launchd and the loopback alias.
#
# Thin wrappers, but not pointless ones - each of these has a detail that is
# easy to get wrong once and then wrong everywhere, and the wrapper is where
# that detail is written down.

typeset -g TM_LOOPBACK_ALIAS="127.0.0.2"

# The Samba account on the appliance. One account, one share per Mac, created by
# the bootstrap - the name is here because the destination URL, the mount and
# the doctor checks all have to agree on it.
typeset -g TMBOX_SHARE_USER="tmuser"

# --- Time Machine -----------------------------------------------------------

# tm_destinations_plist - `tmutil destinationinfo -X`
#
# Note what this does *not* contain: any indication of whether a destination is
# encrypted. Checked on macOS 26.7 - the plist carries Kind, ID, Name,
# MountPoint and LastDestination and nothing else. Encryption is verified
# against the sparsebundle itself with tm_bundle_is_encrypted.
tm_destinations_plist() { tmutil destinationinfo -X 2>/dev/null }

# tm_destination_id <name-or-url-fragment> - the destination UUID, or empty
tm_destination_id() {
  local want="$1" plist
  plist="$(tm_destinations_plist)" || return 1
  print -r -- "$plist" | plutil -convert json -o - -- - 2>/dev/null \
    | jq -er --arg w "$want" '
        .Destinations[]? | select((.Name // "") + (.URL // "") | contains($w)) | .ID // empty' \
    2>/dev/null
}

# tm_has_destination <fragment>
tm_has_destination() { [[ -n "$(tm_destination_id "$1")" ]] }

# tm_bundle_is_encrypted <path-to-sparsebundle>
#
# The only trustworthy answer to "is this backup encrypted". `hdiutil
# isencrypted` reads the image's own header, so it reports what is actually on
# the destination rather than what the client was asked to do.
tm_bundle_is_encrypted() {
  [[ -e "$1" ]] || return 2
  hdiutil isencrypted "$1" 2>/dev/null | grep -qi 'encrypted: *YES'
}

# tm_destination_mountpoint <share-name>
#
# Where backupd actually mounted the share. Not /Volumes/<share>: a Time Machine
# network destination is mounted out of sight under
# /Volumes/.timemachine/<host>/<uuid>/<share>, which is root-only and does not
# appear in the Finder. Looking in /Volumes/<share> finds nothing and invites
# the conclusion that the share is not mounted at all.
tm_destination_mountpoint() {
  local share="$1" line
  line="$(mount 2>/dev/null | grep -F "/${share} on " | head -1)" || return 1
  [[ -n "$line" ]] || return 1
  # "//user@host/share on /path (smbfs, ...)" - the path is between " on " and
  # " (", and it can contain spaces.
  line="${line#* on }"
  # The paren is escaped: with extended_glob on, "${line% (*}" is not a literal
  # but an unterminated glob group, and zsh rejects the whole pattern.
  print -rn -- "${line% \(*}"
}

# tm_bundle_path <share-name> - the sparsebundle on the destination, or empty
#
# Needs root: the .timemachine mount point is not readable by the user who is
# being backed up.
tm_bundle_path() {
  local mp; mp="$(tm_destination_mountpoint "$1")" || return 1
  [[ -n "$mp" ]] || return 1
  # The glob has to be expanded by the privileged shell, not by this one.
  # `priv_run_quiet /bin/ls -d -- "$mp"/*.sparsebundle` reads as though sudo
  # does the matching, but zsh expands it here first - and here is
  # unprivileged, while the mount point under /Volumes/.timemachine is
  # root-only. So the pattern matched nothing, the function failed silently,
  # and every caller reported the encryption state as "not checked" no matter
  # how much root it had. Quoted and handed to a shell under sudo, it works.
  local found
  found="$(priv_run_quiet /bin/sh -c "ls -d -- \"\$1\"/*.sparsebundle 2>/dev/null" sh "$mp" 2>/dev/null | head -1)" || return 1
  [[ -n "$found" ]] || return 1
  print -rn -- "$found"
}

# tm_latest_backup - the newest completed backup, or empty
#
# `tmutil latestbackup` exits 0 even when it has found nothing, printing
# "Failed to find any backups found for current machine" - so its status cannot
# be used to decide whether a backup completed. Measured on macOS 26.6, where
# trusting the status made tmbox report a first backup as finished while the
# destination held nothing but an incomplete bundle.
tm_latest_backup() {
  local out; out="$(tmutil latestbackup 2>/dev/null)" || out=""
  [[ "$out" == /* ]] || return 1
  print -rn -- "$out"
}

# tm_status_plist / tm_running / tm_percent
#
# `tmutil status` is the live view. Its byte counters are not trustworthy -
# measured in this project reporting "Total copied: 0.00 MB" for 23 MiB actually
# transferred - but the phase and the fraction are usable for a progress bar,
# and the phase is what tells a stall from a slow link.
tm_status_plist() { tmutil status 2>/dev/null }

# tm_running [destination-id]
#
# With an id, only a backup *to that destination* counts. A Mac that also backs
# up to a local disk runs those backups too, and without the filter setup showed
# one of them as the appliance's first backup and would have called it finished
# (#7). The id is missing from the status in the opening phases, before backupd
# has picked a destination, so a running backup with no id is counted: it may
# be ours, and tm_running_elsewhere does not claim it either.
tm_running() {
  local plist; plist="$(tm_status_plist)"
  print -r -- "$plist" | grep -qE '"?Running"? *= *1' || return 1
  [[ -n "${1:-}" ]] || return 0
  local dest; dest="$(_tm_status_destination "$plist")"
  [[ -z "$dest" || "$dest" == "$1" ]]
}

# tm_running_elsewhere <destination-id> - a backup to some other destination
tm_running_elsewhere() {
  local plist; plist="$(tm_status_plist)"
  print -r -- "$plist" | grep -qE '"?Running"? *= *1' || return 1
  local dest; dest="$(_tm_status_destination "$plist")"
  [[ -n "$dest" && "$dest" != "$1" ]]
}

_tm_status_destination() {
  print -r -- "$1" | sed -n 's/.*DestinationID"\{0,1\} *= *"\{0,1\}\([A-Fa-f0-9-]*\).*/\1/p' | head -1
}

# tm_last_snapshot <destination-id> - the newest completed backup to it
#
# Printed as a local "YYYY-MM-DD-HHMMSS" stamp, the form backup paths use, so
# status_backup_age reads both. `tmutil latestbackup` cannot answer this: it
# picks a destination itself, and needs root and Full Disk Access to do even
# that. Time Machine's preferences keep a SnapshotDates list per destination,
# appended to when a backup completes, and plutil reads it without either.
#
# Returns 1 when the destination has no completed backup, 2 when the
# preferences cannot be read at all - a caller can then fall back rather than
# report "none" for a destination it simply could not see.
typeset -g TMBOX_TM_PREFS="${TMBOX_TM_PREFS:-/Library/Preferences/com.apple.TimeMachine.plist}"

tm_last_snapshot() {
  local want="$1" id n iso
  plutil -extract Destinations raw -o - "$TMBOX_TM_PREFS" >/dev/null 2>&1 || return 2
  local -i i=0
  while id="$(plutil -extract "Destinations.${i}.DestinationID" raw -o - "$TMBOX_TM_PREFS" 2>/dev/null)"; do
    if [[ "$id" == "$want" ]]; then
      n="$(plutil -extract "Destinations.${i}.SnapshotDates" raw -o - "$TMBOX_TM_PREFS" 2>/dev/null)" || return 1
      [[ "$n" == <-> ]] && (( n > 0 )) || return 1
      iso="$(plutil -extract "Destinations.${i}.SnapshotDates.$(( n - 1 ))" raw -o - "$TMBOX_TM_PREFS" 2>/dev/null)" || return 1
      local -i epoch
      epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null)" || return 1
      date -r "$epoch" '+%Y-%m-%d-%H%M%S'
      return 0
    fi
    (( i++ ))
  done
  return 1
}

# tm_latest_backup_for <destination-id> - tm_last_snapshot, or the old answer
#
# Falls back to `tmutil latestbackup` only when the preferences are unreadable,
# and only then, because that answer may be about another destination.
tm_latest_backup_for() {
  local out rc=0
  out="$(tm_last_snapshot "$1")" || rc=$?
  case $rc in
    0) print -rn -- "$out" ;;
    2) tm_latest_backup ;;
    *) return 1 ;;
  esac
}

tm_percent() {
  local frac
  frac="$(tm_status_plist | sed -n 's/.*"\{0,1\}_raw_Percent"\{0,1\} *= *"\{0,1\}\([0-9.]*\).*/\1/p' | head -1)"
  [[ -n "$frac" ]] || { print -rn -- 0; return }
  local -i pct; pct=$(printf '%.0f' $(( frac * 100 )))
  # Clamped, because the value is not always a fraction of the work: between
  # phases tmutil reports -1, and during the opening phases it reports 1 -
  # which as a percentage would be a progress bar that starts at 100 and then
  # goes back to nothing.
  (( pct < 0 ))   && pct=0
  (( pct > 100 )) && pct=100
  print -rn -- $pct
}

tm_phase() {
  tm_status_plist | sed -n 's/.*BackupPhase"\{0,1\} *= *"\{0,1\}\([A-Za-z]*\).*/\1/p' | head -1
}

# --- SMB --------------------------------------------------------------------

# smb_statshares <mount-point>
#
# The proof that the share is a Time Machine destination. `testparm` on the
# appliance is not proof - it echoes parametric fruit: options back verbatim
# without validating them, so a typo yields a clean config and a share Time
# Machine will not use. OS_X_SERVER TRUE here is the fact that matters.
smb_statshares() { smbutil statshares -m "$1" 2>/dev/null }

smb_is_time_machine_capable() {
  smb_statshares "$1" | grep -qE 'OS_X_SERVER[[:space:]]+TRUE'
}

smb_dialect() {
  smb_statshares "$1" | sed -n 's/.*SMB_VERSION[[:space:]]*\(.*\)/\1/p' | head -1 | tr -d ' '
}

smb_is_encrypted() {
  smb_statshares "$1" | grep -qE 'SESSION_ENCRYPTED[[:space:]]+TRUE|SHARE_ENCRYPTED[[:space:]]+TRUE'
}

# --- the loopback alias -----------------------------------------------------
#
# macOS has 127.0.0.1 on lo0 and nothing else. The SMB client refuses
# 127.0.0.1 - it decides the server is this Mac and declines to mount from
# itself - so the forward is bound to an alias instead. Adding one needs root
# and does not survive a reboot, which is why the LaunchDaemon re-adds it rather
# than assuming it.

lo_alias_present() {
  ifconfig lo0 2>/dev/null | grep -qE "inet ${TM_LOOPBACK_ALIAS}\b"
}

# lo_alias_add - needs root
lo_alias_add() {
  lo_alias_present && return 0
  ifconfig lo0 alias "$TM_LOOPBACK_ALIAS" up 2>/dev/null
}

# --- launchd ----------------------------------------------------------------
#
# `launchctl bootstrap`/`bootout`, not the deprecated load/unload: the modern
# subcommands report a usable error instead of failing silently, which matters
# because the thing being loaded here is what keeps the backup reachable.

# launchd_is_loaded <label> [domain]
launchd_is_loaded() {
  local label="$1" domain="${2:-system}"
  launchctl print "${domain}/${label}" >/dev/null 2>&1
}

# launchd_load <plist> <label> [domain]
launchd_load() {
  local plist="$1" label="$2" domain="${3:-system}"
  launchd_is_loaded "$label" "$domain" && launchctl bootout "${domain}/${label}" >/dev/null 2>&1
  launchctl bootstrap "$domain" "$plist" 2>&1
}

# launchd_unload <label> [domain]
launchd_unload() {
  local label="$1" domain="${2:-system}"
  launchd_is_loaded "$label" "$domain" || return 0
  launchctl bootout "${domain}/${label}" >/dev/null 2>&1
}

# --- the privilege boundary -------------------------------------------------
#
# Two steps in this product need root, and both are macOS's rules rather than
# ours: binding port 445 on a loopback alias for the forward, and
# `tmutil setdestination`, which requires root in its own right. Everything
# privileged goes through here, so there is one place that knows how tmbox
# escalates - and so an unattended run fails with a sentence instead of waiting
# for a password nobody is there to type.

priv_run() {
  (( EUID == 0 )) && { "$@"; return $? }
  if (( TMBOX_NONINTERACTIVE )); then
    sudo -n "$@"
    return $?
  fi
  sudo "$@"
}

# priv_run_quiet <command...>
#
# For the one call that carries a credential on its stdin. -n rather than a
# prompt, always: if the timestamp has expired, sudo would read the password
# from the pipe - which is the share password, not the user's - and send a
# credential to the wrong reader. Failing is the only safe behaviour here, and
# priv_prime is what makes it not happen.
priv_run_quiet() {
  (( EUID == 0 )) && { "$@"; return $? }
  sudo -n "$@"
}

# priv_prime - explain, then get the credential once
#
# macOS caches the sudo timestamp for five minutes, so priming here means the
# privileged steps prompt once between them rather than at an unpredictable
# moment in the middle of one.
priv_prime() {
  (( EUID == 0 )) && return 0
  sudo -n true 2>/dev/null && return 0

  if (( TMBOX_NONINTERACTIVE )); then
    ui_bad "This step needs administrator rights and the run is non-interactive."
    ui_say "Either run tmbox with sudo, or allow passwordless sudo for this account."
    return 1
  fi

  ui_blank
  ui_rule "Administrator password"
  ui_blank
  ui_say "macOS asks for your account password now, for things it will not let any program do unprivileged:"
  ui_item "bind port 445 on a loopback address, which Time Machine insists on"
  ui_item "install the background job that keeps the connection up across reboots"
  ui_item "set the Time Machine destination, which tmutil only does as root"
  ui_blank
  ui_say "It is macOS asking, not tmbox: the password goes to sudo, and tmbox never sees it, stores it or sends it anywhere."
  ui_blank

  sudo -v || { ui_bad "Could not obtain administrator rights."; return 1 }
  return 0
}

# --- the operator's public address ------------------------------------------

# public_ipv4
#
# Two independent detectors that must agree. A single one returning an error
# page, a captive-portal redirect or a stale cached answer would otherwise
# become a firewall rule - and a firewall rule with the wrong address in it
# locks the owner out of their own appliance.
#
# Re-detected every run and never stored: a home connection's address changes.
public_ipv4() {
  local a b
  a="$(curl -sf4 --max-time 10 https://ifconfig.me 2>/dev/null)" || a=""
  b="$(curl -sf4 --max-time 10 https://api.ipify.org 2>/dev/null)" || b=""
  a="${a//[[:space:]]/}"
  b="${b//[[:space:]]/}"

  if [[ -z "$a" || -z "$b" ]]; then
    log_error "public address detection failed (ifconfig.me='$a' ipify='$b')"
    return 1
  fi
  if [[ "$a" != "$b" ]]; then
    log_error "the two public-address detectors disagree: '$a' vs '$b'"
    return 2
  fi
  if [[ ! "$a" == <->.<->.<->.<-> ]]; then
    log_error "public address is not a dotted quad: '$a'"
    return 3
  fi
  print -rn -- "$a"
}

# --- this Mac ---------------------------------------------------------------

# mac_default_name - a share-safe name derived from the computer's
#
# Lower-cased and reduced to [a-z0-9-]: the project measured a macOS 26 bug
# where non-ASCII share and server names fail, so the name that ends up in
# `tm-<name>` is kept boring on purpose.
mac_default_name() {
  local raw; raw="$(scutil --get ComputerName 2>/dev/null)" || raw=""
  [[ -n "$raw" ]] || raw="$(hostname -s 2>/dev/null)"
  [[ -n "$raw" ]] || raw="mac"
  local name="${(L)raw}"
  name="${name//[^a-z0-9-]/-}"
  while [[ "$name" == *--* ]]; do name="${name//--/-}"; done
  while [[ "$name" == -* ]];    do name="${name#-}";    done
  while [[ "$name" == *- ]];    do name="${name%-}";    done
  [[ -n "$name" ]] || name="mac"
  print -rn -- "${name[1,24]}"
}

# macos_major - 26 on macOS 26.x
macos_major() { sw_vers -productVersion 2>/dev/null | cut -d. -f1 }
