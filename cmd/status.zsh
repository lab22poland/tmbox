#!/bin/zsh
#
# tmbox status - what the appliance is doing, in one screen.
#
# The everyday command. It answers the four questions a person actually has -
# is it working, is a backup running, how full is it, what is it costing - and
# nothing else. Anything that requires a judgement about whether something is
# *wrong* belongs in `tmbox doctor`.
#
# **Read-only, and it never changes anything.** Someone running this is usually
# worried; a command that repairs things while reporting on them makes the next
# question unanswerable.
#
# It also works when the appliance is unreachable, because that is exactly when
# it will be run. Everything remote is attempted once, briefly, and its absence
# is reported as a fact rather than as an error.

cmd_status() {
  ui_banner "tmbox status" "$(state_get mac_name) → $(state_get server_ip)"

  if ! state_has server_id && ! state_has box_id; then
    ui_warn "This Mac has no appliance recorded."
    ui_say "Run 'tmbox setup' to build one."
    return 3
  fi

  status_backup
  status_destination
  status_tunnel
  status_appliance
  status_cost

  ui_blank
  ui_dim "Something look wrong? Run: tmbox doctor"
}

# --- the backup itself ------------------------------------------------------

status_backup() {
  ui_rule "Backups"
  ui_blank

  if tm_running; then
    local phase; phase="$(tm_phase)"
    local pct;   pct="$(tm_percent)"
    ui_ok "A backup is running."
    ui_progress "$pct" 100 "${phase:-working}"
  else
    ui_item "No backup is running."
  fi

  # The exit status of `tmutil latestbackup` is not usable - it is 0 even when
  # it prints "Failed to find any backups". tm_latest_backup reads the output.
  local latest; latest="$(tm_latest_backup)" || latest=""
  if [[ -n "$latest" ]]; then
    ui_kv "Last backup" "$(status_backup_age "$latest")"
  else
    ui_kv "Last backup" "none yet"
  fi
}

# status_backup_age <path> - "2026-09-19 07:38 (3 hours ago)"
#
# The timestamp is in the path rather than in the file's metadata, because the
# path is what Time Machine treats as authoritative and the mtime of a
# directory on a network destination is not dependable.
status_backup_age() {
  # Not named `path`: that is $PATH in zsh, and declaring it local replaces the
  # command search path for the rest of the function.
  local leaf="${1:t}"
  # 2026-09-19-073758.backup, or the same without a suffix.
  local stamp="${leaf%%.*}"
  if [[ ! "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
    print -rn -- "$leaf"
    return 0
  fi

  local pretty="${stamp[1,10]} ${stamp[12,13]}:${stamp[14,15]}"
  # `then` is a reserved word, so the timestamp gets a duller name.
  local -i taken now age
  taken="$(date -j -f '%Y-%m-%d-%H%M%S' "$stamp" '+%s' 2>/dev/null)" || {
    print -rn -- "$pretty"; return 0
  }
  now="$(date '+%s')"
  (( age = now - taken ))

  local ago
  if   (( age < 90 ));    then ago="just now"
  elif (( age < 5400 ));  then ago="$(( age / 60 )) minutes ago"
  elif (( age < 172800 )); then ago="$(( age / 3600 )) hours ago"
  else                         ago="$(( age / 86400 )) days ago"
  fi
  print -rn -- "${pretty} (${ago})"
}

# --- the destination --------------------------------------------------------

status_destination() {
  local share="tm-$(state_get mac_name)"
  local id; id="$(tm_destination_id "$share")"

  ui_blank
  if [[ -z "$id" ]]; then
    ui_warn "Time Machine has no destination for this appliance."
    ui_say "Run 'tmbox setup' to add it again."
    return 0
  fi

  local mp; mp="$(tm_destination_mountpoint "$share")" || mp=""
  if [[ -n "$mp" ]]; then
    ui_kv "Destination" "mounted"
  else
    # Not a fault. macOS mounts a network destination only while it is using
    # it, so "not mounted" is the resting state between backups.
    ui_kv "Destination" "not mounted (normal between backups)"
  fi

  status_encryption "$share"
}

# status_encryption <share>
#
# tm_bundle_is_encrypted answers with its exit status - 0 encrypted, 1 not,
# 2 no such bundle - and takes the sparsebundle's path rather than the share
# name. Finding that path needs root, because the destination is mounted under
# /Volumes/.timemachine, which is root-only. Without root the honest answer is
# "not checked", and saying so beats implying the backups are unencrypted.
status_encryption() {
  local share="$1" bundle
  bundle="$(tm_bundle_path "$share" 2>/dev/null)" || bundle=""

  if [[ -z "$bundle" ]]; then
    ui_item "Encryption: not checked (needs administrator access, or no backup exists yet)."
    return 0
  fi

  if tm_bundle_is_encrypted "$bundle"; then
    ui_ok "Backups are encrypted by Time Machine."
  else
    ui_warn "Backups are NOT encrypted by Time Machine."
    ui_say  "That is the only layer nobody else can read, including us. Turn it on in System Settings → Time Machine."
  fi
}

# --- the tunnel -------------------------------------------------------------

status_tunnel() {
  ui_blank
  if [[ ! -f "$TMBOX_TUNNEL_PLIST" ]]; then
    ui_warn "The tunnel is not installed."
    return 0
  fi

  # Two questions, because they have different answers and different fixes.
  if tunnel_listening; then
    ui_ok "Tunnel up - the appliance's Samba answered."
  elif tunnel_port_open; then
    ui_bad "Tunnel down - the port is bound but the appliance is not answering."
    ui_say "The appliance may be off, locked, or unreachable. Try: tmbox unlock"
  else
    ui_bad "Tunnel down - the daemon is not holding the port."
    ui_say "Try: tmbox tunnel restart"
  fi
}

# --- the appliance ----------------------------------------------------------
#
# One SSH round trip for everything, because each one costs a second or two on
# a WAN link and a status screen that takes ten seconds gets run less often.

status_appliance() {
  local host; host="$(state_get server_ip)"
  [[ -n "$host" ]] || return 0

  ui_blank
  local out
  if ! out="$(ssh_run "$host" "$(status_remote_script)" 2>/dev/null)"; then
    ui_warn "The appliance did not answer on ssh."
    ui_say "It may be off, or your address may have changed - tmbox doctor checks that."
    return 0
  fi

  local keystatus pool used quota
  keystatus="$(print -r -- "$out" | sed -n '1p')"
  pool="$(print -r -- "$out"      | sed -n '2p')"
  used="$(print -r -- "$out"      | sed -n '3p')"
  quota="$(print -r -- "$out"     | sed -n '4p')"

  case "$keystatus" in
    available) ;;
    *) ui_bad "The appliance is locked - it is not serving the share."
       ui_say "Run: tmbox unlock" ;;
  esac

  [[ -n "$pool" ]] && ui_kv "Pool" "$pool"
  if [[ -n "$used" && -n "$quota" ]]; then
    ui_kv "Used" "${used} of ${quota}"
  fi
}

# status_remote_script - four facts, one line each, in a fixed order
#
# Fixed order rather than key=value because the reader above is positional and
# a missing value must still occupy its line. `echo` on failure keeps the line
# count right when a command is absent.
status_remote_script() {
  local mac; mac="$(state_get mac_name)"
  print -r -- "zfs get -H -o value keystatus tank/tm 2>/dev/null || echo unknown
zpool list -H -o health tank 2>/dev/null || echo unknown
zfs get -H -o value used tank/tm/${mac} 2>/dev/null || echo ''
zfs get -H -o value refquota tank/tm/${mac} 2>/dev/null || echo ''"
}

# --- what it costs ----------------------------------------------------------

status_cost() {
  local monthly; monthly="$(state_get monthly_eur)"
  [[ -n "$monthly" ]] || return 0
  ui_blank
  ui_kv "Cost" "about EUR ${monthly} / month, net"
}
