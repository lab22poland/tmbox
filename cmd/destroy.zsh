#!/bin/zsh
#
# tmbox destroy - tear the appliance down, in the right order, and prove it.
#
# Three rules, and each of them is here because of something that went wrong on
# this project before the product existed.
#
# **The Storage Box is never deleted by automation.** It holds the backups. The
# server, the address, the firewall and the key are all rebuildable in ten
# minutes; the box is the only copy of the user's data. Deleting it needs
# --delete-storage-box, typed deliberately, and even then it is confirmed
# separately from everything else.
#
# **Order matters.** The pool is exported and the share stopped before the
# machine holding them goes away, because the reverse order is how a clean
# shutdown turns into a hang with a half-written container file on the far side.
#
# **The audit is against the API, not against the state file.** The resource
# worth catching is precisely the one the script has forgotten about - an
# unassigned primary IP still bills, and a snapshot is not deleted with the
# server it came from. Asking the API what exists is the only check that can
# find what we failed to record.

cmd_destroy() {
  http_init || ui_die "Could not create a private temporary directory."

  ui_banner "tmbox destroy" "Remove the appliance and stop the billing"

  local token
  token="$(kc_get hetzner-token)" || token="$(ans_get HETZNER_TOKEN)"
  [[ -n "$token" ]] || ui_die "No Hetzner API token. Nothing can be checked or removed without one."
  TMBOX_HCLOUD_TOKEN="$token"

  local server_id;  server_id="$(state_get server_id)"
  local box_id;     box_id="$(state_get box_id)"
  local server_ip;  server_ip="$(state_get server_ip)"

  if [[ -z "$server_id" && -z "$box_id" ]]; then
    ui_warn "There is nothing in this Mac's records to remove."
    ui_say "Auditing your Hetzner project anyway, in case something was created and not recorded."
    ui_blank
    destroy_audit
    return 0
  fi

  destroy_show_what_goes
  ui_confirm CONFIRM_DESTROY "Remove these now?" "n" \
    || { ui_ok "Nothing was removed."; return 0 }

  # The tunnel goes first. It is a KeepAlive job pointed at an address that is
  # about to stop existing, so leaving it in place means launchd reconnecting to
  # whoever holds that address next, every thirty seconds, forever.
  if [[ -f "$TMBOX_TUNNEL_PLIST" ]]; then
    tunnel_uninstall || ui_warn "The tunnel could not be removed; see tmbox tunnel status."
  fi
  # And a WireGuard tunnel, for the same reason (#22). Tailscale's own app is
  # the owner's and stays; the appliance leaves the tailnet below.
  if [[ -f "$TMBOX_WG_PLIST" ]]; then
    wg_daemon_uninstall || ui_warn "The WireGuard tunnel could not be removed; see tmbox tunnel status."
  fi
  destroy_tm_destination

  destroy_quiesce_appliance "$server_ip"
  destroy_cloud_resources
  destroy_storage_box "$box_id"
  destroy_local_traces "$server_ip"

  ui_blank
  destroy_audit

  # Measured on 2026-09-19 and again on 2026-10-01: a new destination at the
  # same 127.0.0.2 address can fail every backup with an authentication error
  # until the Mac restarts. Said here, where it can still be planned for.
  if (( DESTROY_TM_REMOVED )); then
    ui_blank
    ui_say "If you set tmbox up again on this Mac and the first backup fails with an authentication error, restart the Mac: macOS can hold on to the old destination's connection state until then."
  fi
}

# --- what is about to happen ------------------------------------------------

destroy_show_what_goes() {
  ui_rule "What will be removed"
  ui_blank
  local v
  v="$(state_get server_id)";     [[ -n "$v" ]] && ui_item "Server ${v} at $(state_get server_ip)"
  v="$(state_get primary_ip_id)"; [[ -n "$v" ]] && ui_item "IPv4 address $(state_get server_ip)"
  v="$(state_get firewall_id)";   [[ -n "$v" ]] && ui_item "Firewall ${v}"
  v="$(state_get ssh_key_id)";    [[ -n "$v" ]] && ui_item "The SSH key registered with Hetzner"
  ui_item "The tunnel and the Time Machine destination on this Mac"
  ui_blank

  local box_id; box_id="$(state_get box_id)"
  if [[ -n "$box_id" ]]; then
    ui_rule "What will be kept"
    ui_blank
    ui_kv "Storage Box" "${box_id} - $(state_get box_server)"
    ui_say "Your backups are on it. tmbox does not delete it, and the monthly charge for it continues."
    ui_blank
    if ans_has DELETE_STORAGE_BOX; then
      ui_warn "--delete-storage-box was given, so it will be offered for deletion at the end."
      ui_blank
    else
      ui_say "To remove it too, run: tmbox destroy --delete-storage-box"
      ui_blank
    fi
  fi
}

# --- the Time Machine destination -------------------------------------------
#
# Added by setup's step 8 and, until #13, never removed: after a destroy Time
# Machine kept trying a share that no longer existed, and a later setup on the
# same Mac re-added the same URL. Removed whether or not the Storage Box is
# kept - removing a destination deletes nothing on it.

typeset -gi DESTROY_TM_REMOVED=0

destroy_tm_destination() {
  local id; id="$(state_get destination_id)"
  [[ -n "$id" ]] || id="$(tm_destination_id "tm-$(state_get mac_name)")" || id=""
  [[ -n "$id" ]] || return 0
  # Only what Time Machine still has. destinationinfo needs no Full Disk Access.
  tm_destinations_plist 2>/dev/null | grep -q -- "$id" || return 0

  # removedestination does need it, and without it fails with the same exit
  # code as everything else. Not a reason to stop a teardown: say what to run.
  if [[ "$(fda_granted; print -rn -- $?)" == 1 ]]; then
    ui_warn "The Time Machine destination was not removed: that needs Full Disk Access for $(fda_app_name)."
    ui_say "Remove it later with:  sudo tmutil removedestination ${id}"
    return 0
  fi

  priv_prime || { ui_warn "The Time Machine destination was not removed."; ui_say "Remove it with:  sudo tmutil removedestination ${id}"; return 0 }
  if priv_run_quiet /usr/bin/tmutil removedestination "$id" >/dev/null 2>&1; then
    DESTROY_TM_REMOVED=1
    ui_ok "Time Machine destination removed"
  else
    ui_warn "Time Machine refused to remove the destination."
    ui_say "Remove it with:  sudo tmutil removedestination ${id}"
  fi
}

# --- stopping the appliance politely ----------------------------------------

destroy_quiesce_appliance() {
  local ip="$1"
  [[ -n "$ip" ]] || return 0

  ui_spin_start "Asking the appliance to stop cleanly"

  # Reachability is checked first, briefly. A destroyed-but-unrecorded server,
  # or one on a network the firewall no longer admits, must not turn a teardown
  # into a five-minute wait for an SSH timeout.
  if ! ssh_run "$ip" true >/dev/null 2>&1; then
    ui_spin_stop warn "The appliance is not answering - removing it anyway"
    return 0
  fi

  # Reverse order of assembly: stop serving, unmount, export the pool, detach
  # the loop device, unmount the Storage Box. The container file on the box is
  # about to outlive the machine writing to it, so it has to be closed properly.
  ssh_run "$ip" 'set -e
    systemctl stop smbd 2>/dev/null || true
    if command -v zpool >/dev/null 2>&1; then
      zfs unmount -a 2>/dev/null || true
      zpool export tank 2>/dev/null || zpool export -f tank 2>/dev/null || true
    fi
    loop=$(losetup -j /mnt/sbox/tank.img -O NAME -n 2>/dev/null | tr -d " ")
    [ -n "$loop" ] && losetup -d "$loop" 2>/dev/null || true
    umount /mnt/sbox 2>/dev/null || true
    sync
  ' >/dev/null 2>&1

  ui_spin_stop ok "The appliance stopped cleanly"
}

# --- the cloud resources ----------------------------------------------------
#
# Deleted in dependency order. The server goes first because the address and the
# firewall are attached to it, and Hetzner will not remove an address that is
# still assigned.

destroy_cloud_resources() {
  local id

  id="$(state_get server_id)"
  if [[ -n "$id" ]]; then
    ui_spin_start "Deleting the server"
    if hc_server_delete "$id"; then
      # DELETE returns an action; the address cannot be released until it has
      # finished, so waiting here is not politeness, it is ordering.
      local act; act="$(json_get '.action.id' "$HTTP_BODY")"
      [[ -n "$act" ]] && hc_wait_action "$act" "deleting the server"
      state_unset server_id
      ui_spin_stop ok "Server deleted"
    else
      ui_spin_stop warn "Server ${id} could not be deleted (${HTTP_STATUS}) - it may already be gone"
      state_unset server_id
    fi
  fi

  id="$(state_get primary_ip_id)"
  if [[ -n "$id" ]]; then
    ui_spin_start "Releasing the IPv4 address"
    # This one is the classic forgotten charge: a reserved address that is not
    # attached to anything still bills, month after month, invisibly.
    if hc_primary_ip_delete "$id"; then
      state_unset primary_ip_id
      ui_spin_stop ok "Address released"
    else
      ui_spin_stop warn "Address ${id} could not be released (${HTTP_STATUS}) - check the console, it still bills"
    fi
  fi

  id="$(state_get firewall_id)"
  if [[ -n "$id" ]]; then
    ui_spin_start "Deleting the firewall"
    if hc_firewall_delete "$id"; then
      state_unset firewall_id
      ui_spin_stop ok "Firewall deleted"
    else
      ui_spin_stop warn "Firewall ${id} could not be deleted (${HTTP_STATUS})"
    fi
  fi

  id="$(state_get ssh_key_id)"
  if [[ -n "$id" ]]; then
    ui_spin_start "Removing the SSH key from Hetzner"
    if hc_ssh_key_delete "$id"; then
      state_unset ssh_key_id
      ui_spin_stop ok "SSH key removed"
    else
      ui_spin_stop warn "SSH key ${id} could not be removed (${HTTP_STATUS})"
    fi
  fi
}

# --- the Storage Box, only if asked -----------------------------------------

destroy_storage_box() {
  local box_id="$1"
  [[ -n "$box_id" ]] || return 0

  if ! ans_has DELETE_STORAGE_BOX; then
    ui_blank
    ui_kv "Storage Box" "${box_id} - kept, still billing"
    return 0
  fi

  ui_blank
  ui_rule "Deleting the Storage Box"
  ui_blank
  ui_bad "This destroys the backups. There is no undo and no copy anywhere else."
  ui_say "Everything else tmbox created can be rebuilt in ten minutes. This cannot."
  ui_blank

  # A second confirmation, worded as the thing itself rather than as a step. The
  # first confirmation was about a teardown; this one is about data loss, and
  # conflating them is how people agree to the wrong one.
  if ! ui_confirm CONFIRM_DELETE_BOX "Permanently delete the backups on Storage Box ${box_id}?" "n"; then
    ui_ok "Storage Box kept."
    return 0
  fi

  ui_spin_start "Deleting the Storage Box"
  if hb_delete "$box_id"; then
    state_unset box_id
    state_unset box_server
    state_unset box_subaccount
    ui_spin_stop ok "Storage Box deleted"
  else
    ui_spin_stop bad "Could not delete the Storage Box (${HTTP_STATUS})"
  fi
}

# --- this Mac ---------------------------------------------------------------

destroy_local_traces() {
  local ip="$1"

  # The host key first. Hetzner recycles public addresses, so leaving a pin
  # behind means the next appliance - or the next customer's machine on that
  # address - trips a host-key warning that looks exactly like an attack.
  [[ -n "$ip" ]] && ssh_forget_host "$ip"
  # And under the tunnel addresses it was pinned to as well (#22).
  ssh_forget_host "$TMBOX_WG_APPLIANCE"
  local ts; ts="$(state_get tailscale_ip)"
  [[ -n "$ts" ]] && ssh_forget_host "$ts"
  # A WireGuard configuration written for the App Store app, if it was never
  # imported: it holds this Mac's tunnel key.
  rm -rf -- "${TMBOX_STATE_DIR}/wireguard"

  # Credentials go only if the box went too. While the backups still exist, the
  # Time Machine password is the only thing that can read them, and it is
  # unrecoverable by design - deleting it would silently destroy the data it
  # protects while leaving the bill running.
  if state_has box_id; then
    ui_blank
    ui_warn "The stored credentials are kept, because the Storage Box was kept."
    ui_say "The Time Machine password among them cannot be recovered by anyone, including us, and without it the backups on that box cannot be read."
  else
    kc_delete_all
    ssh_delete_keys
    state_clear
    ui_ok "Credentials, keys and the local record removed from this Mac."
  fi
}

# --- the audit --------------------------------------------------------------

destroy_audit() {
  ui_rule "Audit"
  ui_blank
  ui_say "Checked against the Hetzner API rather than against what tmbox thinks it created, because the resource worth finding is the one it failed to record."
  ui_blank

  local -i total=0
  local resource count
  for resource in $HC_BILLABLE; do
    count="$(hc_count "$resource")" || count="?"
    if [[ "$count" == "0" ]]; then
      ui_ok "$(printf '%-18s none' "$resource")"
    else
      ui_warn "$(printf '%-18s %s' "$resource" "$count")"
      [[ "$count" == <-> ]] && (( total += count ))
    fi
  done

  # Snapshots and backups outlive the server they came from, so they are not
  # covered by anything above.
  count="$(hc_count_images_snapshots)" || count="?"
  if [[ "$count" == "0" ]]; then
    ui_ok "$(printf '%-18s none' "snapshots/backups")"
  else
    ui_warn "$(printf '%-18s %s' "snapshots/backups" "$count")"
    [[ "$count" == <-> ]] && (( total += count ))
  fi

  local -i boxes_kept=0
  count="$(hb_count)" || count="?"
  if [[ "$count" == "0" ]]; then
    ui_ok "$(printf '%-18s none' "storage boxes")"
  else
    ui_item "$(printf '%-18s %s (kept on purpose)' "storage boxes" "$count")"
    boxes_kept=1
  fi

  ui_blank
  if (( total == 0 )); then
    if (( boxes_kept )); then
      ui_ok "Nothing is billing apart from the Storage Box you chose to keep."
    else
      ui_ok "Nothing in your Hetzner project is billing."
    fi
  else
    ui_warn "${total} resource(s) remain. They are listed above and they are billing."
    ui_say "Some may belong to something else in this project. Check the Hetzner console before deleting anything tmbox did not create."
  fi
  ui_blank
}
