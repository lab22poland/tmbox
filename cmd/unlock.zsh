#!/bin/zsh
#
# tmbox unlock - hand the appliance its dataset passphrase.
#
# The appliance boots **locked**, by design: the pool imports, but `tank/tm` has
# no key, so it is not mounted and `smbd` is not started. That is what makes
# "Hetzner cannot read the datasets" true rather than decorative - the
# passphrase is never at rest on their hardware.
#
# The consequence is that **every reboot of the appliance stops the backups
# until someone unlocks it**, and this is the command that does it. Nothing
# recovers on its own and nothing ever will, because only a person holds the
# key. That is the trade the security model makes, stated here because this is
# the file where somebody meets it.
#
# The passphrase travels on **stdin** into `zfs load-key`, so it exists in that
# process's memory and in the kernel and nowhere else. Not in argv, where the
# appliance's own `ps` would show it to every account on the machine, and not in
# a file, which would survive the reboot and defeat the whole arrangement.
#
# Three sources, in the order a person would want them tried:
#
#   1. the copy this Mac saved at enrolment - the normal case, no typing,
#   2. --zfs-passphrase, for automation,
#   3. a prompt, for the durable copy of the passphrase file the user kept
#      somewhere other than this Mac.

cmd_unlock() {
  ui_banner "tmbox unlock" "Give the appliance its key"

  local host
  host="$(appliance_host)"
  if [[ -z "$host" ]]; then
    ui_bad "This Mac has no appliance recorded."
    ui_say "Run 'tmbox setup' first."
    return 3
  fi

  # Ask before sending anything. An appliance that is already serving needs no
  # passphrase, and prompting for one anyway would teach a habit worth not
  # teaching.
  # Not named `status`: that is a read-only special parameter in zsh, an alias
  # for $?, and assigning it aborts the function at runtime. Neither `zsh -n`
  # nor the linter catches it, because it is only an error when executed.
  local keystate
  if ! keystate="$(unlock_remote_status "$host")"; then
    ui_bad "The appliance at ${host} did not answer."
    ui_say "Check that it is running, and that tcp/22 is open to this Mac's address."
    ui_say "The firewall is pinned to one address, so a new public IP locks you out."
    return 4
  fi

  if [[ "$keystate" == "available" ]]; then
    ui_ok "The appliance is already unlocked."
    unlock_report_serving "$host"
    return 0
  fi

  ui_say "The appliance is locked, which is how it comes up after a reboot."
  ui_blank

  local passphrase
  passphrase="$(unlock_passphrase)" || return $?

  local out
  if ! out="$(ssh_send_secret "$host" /usr/local/sbin/tmbox-unlock "$passphrase" 2>&1)"; then
    ui_bad "The appliance did not accept the passphrase."
    log_debug "tmbox-unlock said: ${out}"
    ui_say "Setup saved the passphrase in $(kc_path zfs-passphrase)."
    ui_say "If you typed it or passed it as a flag, check it against that file or your copy of it."
    ui_say "There is no way to reach the data without it. That is the point of it."
    return 5
  fi

  ui_ok "Unlocked."
  unlock_report_serving "$host"

  if [[ -n "$(state_get destination_id)" ]]; then
    ui_blank
    ui_say "Time Machine will use the destination again at its next backup."
    ui_say "To start one now: sudo tmutil startbackup --destination $(state_get destination_id)"
  fi
}

# unlock_remote_status <host> - keystatus of tank/tm, or non-zero if unreachable
#
# `zfs get keystatus` prints "unavailable" for a locked dataset and "available"
# for an unlocked one, and exits 0 either way. So the distinction that matters
# here - locked, versus cannot-be-asked - is the exit status of ssh, not of zfs.
unlock_remote_status() {
  local host="$1" out
  out="$(ssh_run "$host" 'zfs get -H -o value keystatus tank/tm' 2>/dev/null)" || return 1
  out="${out//[[:space:]]/}"
  [[ -n "$out" ]] || return 1
  print -rn -- "$out"
}

# unlock_report_serving <host> - say whether Samba actually came back.
#
# Unlocking the dataset and serving it are two steps, and the second can fail on
# its own. Reporting "unlocked" while the share is still absent would send
# somebody looking for the fault in Time Machine.
unlock_report_serving() {
  local host="$1" serving
  serving="$(ssh_run "$host" 'systemctl is-active smbd' 2>/dev/null)" || serving=""
  serving="${serving//[[:space:]]/}"
  if [[ "$serving" == "active" ]]; then
    ui_kv "Samba" "serving"
  else
    ui_warn "The dataset is unlocked but Samba is not running (${serving:-unknown})."
    ui_say "On the appliance: systemctl status smbd"
  fi
}

# unlock_passphrase - the saved copy, an answer, or a prompt.
unlock_passphrase() {
  local p
  if p="$(kc_get zfs-passphrase 2>/dev/null)" && [[ -n "$p" ]]; then
    log_debug "using the passphrase saved on this Mac"
    print -rn -- "$p"
    return 0
  fi

  # Nothing saved. Under --non-interactive this must name the flag rather than
  # stop at a prompt nobody is there to see.
  if (( TMBOX_NONINTERACTIVE )) && ! ans_has ZFS_PASSPHRASE; then
    ui_bad "This Mac has no saved passphrase for the appliance."
    ui_say "Pass it with --zfs-passphrase, or run without --non-interactive to be asked."
    return 6
  fi

  ui_say "This Mac has no saved copy of the passphrase in $(kc_path zfs-passphrase)."
  ui_say "Enter it from the copy of that file you kept somewhere other than this Mac."
  p="$(ui_ask_secret ZFS_PASSPHRASE "Passphrase")"
  if [[ -z "$p" ]]; then
    ui_bad "Nothing was entered."
    return 6
  fi
  print -rn -- "$p"
}
