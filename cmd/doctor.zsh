#!/bin/zsh
#
# tmbox doctor - every way this is known to break, as a named check.
#
# The command that decides support load. Every defect found in the three
# validation runs and in building 0.1.0 is a check here, with the fix it
# implies, because a fault a user cannot name is a fault they have to ask
# somebody about.
#
# **Each check says what it found, not only pass or fail.** "CIFS mount is
# soft, not hard" is actionable; "mount check failed" is a second question.
#
# `--fix` repairs the four faults that are safe to repair without asking:
# re-pinning the firewall to this Mac's current address, clearing stale Samba
# sessions, restarting a dead tunnel, and turning SMB multichannel off on an
# appliance built before 0.1.3. Everything else is reported with the
# command that would fix it, because the rest either destroy data, cost money,
# or need a decision.
#
# Exit status: 0 all passed, 1 something failed, 2 warnings only. That makes it
# usable from a cron job, which is how the SaaS edition will consume it.

typeset -gi DOCTOR_FAILED=0
typeset -gi DOCTOR_WARNED=0

# Initialised only when absent. The option parser in bin/tmbox.zsh sets this
# before cmd_doctor is called, and a plain assignment here would undo it for
# whichever source order happens to apply - the same trap lib/answers.zsh
# documents for TMBOX_NONINTERACTIVE.
(( ${+DOCTOR_FIX} )) || typeset -gi DOCTOR_FIX=0

cmd_doctor() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --fix) DOCTOR_FIX=1 ;;
      *) ui_die "tmbox doctor: unknown option '$arg'" ;;
    esac
  done

  # Needed before any Hetzner call: the API client writes curl's config into a
  # private temporary directory so the token never reaches argv, and without it
  # every request fails as though the network were down. --fix is the only path
  # that talks to the API, but it is cheap and it keeps the failure honest.
  http_init || ui_die "Could not create a private temporary directory."

  ui_banner "tmbox doctor" "Checking everything that is known to break"

  if ! state_has server_id && ! state_has box_id; then
    ui_warn "This Mac has no appliance recorded, so there is nothing to check."
    ui_say "Run 'tmbox setup' to build one."
    return 3
  fi

  doctor_run_checks

  doctor_summary
}

# doctor_run_checks
#
# The order is a dependency order, not a reading order. The tunnel is an ssh
# connection, so it can only come up once the firewall admits this Mac: with
# --fix, re-pinning a changed address has to happen before the tunnel is
# restarted. The other way round, the restart timed out against the old rules,
# was reported as a failure, and the re-pin that followed fixed it a moment too
# late to show (#5).
doctor_run_checks() {
  doctor_check_reachability
  doctor_check_mac
  doctor_check_appliance
  doctor_check_timemachine
}

# --- the check primitives ---------------------------------------------------
#
# Three outcomes, not two. A warning is something that is not wrong now but
# will be: an unencrypted destination, a dataset at 90%. Treating those as
# failures trains people to ignore the output.

doc_pass() { ui_ok   "$1"; [[ -n "${2:-}" ]] && ui_dim "    $2"; return 0 }
doc_warn() { ui_warn "$1"; [[ -n "${2:-}" ]] && ui_dim "    $2"; (( DOCTOR_WARNED++ )); return 0 }
doc_fail() { ui_bad  "$1"; [[ -n "${2:-}" ]] && ui_dim "    $2"; (( DOCTOR_FAILED++ )); return 0 }

# --- 1. this Mac ------------------------------------------------------------

doctor_check_mac() {
  ui_blank
  ui_rule "This Mac"
  ui_blank

  if [[ -f "$TMBOX_TUNNEL_PLIST" ]]; then
    doc_pass "The tunnel is installed."
  else
    doc_fail "The tunnel is not installed." "Fix: tmbox tunnel install"
    return 0
  fi

  if launchd_is_loaded "$TMBOX_TUNNEL_LABEL"; then
    doc_pass "launchd has the tunnel loaded."
  else
    doc_fail "launchd does not have the tunnel loaded." "Fix: tmbox tunnel restart"
  fi

  # The check this command exists for. See tunnel_listening: the port is bound
  # by ssh itself, so a TCP connect proves nothing about the far end.
  if tunnel_listening; then
    doc_pass "Samba answers through the tunnel." "An SMB2 negotiate was sent and answered."
  elif tunnel_port_open; then
    doc_fail "The tunnel's port is open but nothing answers on it." \
             "The forward is bound locally and the appliance is not serving. The checks below say why."
  else
    if (( DOCTOR_FIX )); then
      ui_item "Restarting the tunnel…"
      tunnel_kickstart >/dev/null 2>&1
      if tunnel_wait_listening 20; then
        doc_pass "The tunnel was down; restarting it fixed it."
      else
        doc_fail "The tunnel is down and restarting it did not help." "See: tmbox tunnel status"
      fi
    else
      doc_fail "The tunnel is down - nothing is holding the port." "Fix: tmbox doctor --fix, or tmbox tunnel restart"
    fi
  fi

  lo_alias_present && doc_pass "The ${TM_LOOPBACK_ALIAS} loopback alias is present." \
    || doc_warn "The ${TM_LOOPBACK_ALIAS} loopback alias is missing." "The tunnel daemon adds it at start."

  doctor_check_tunnel_stability
}

# doctor_check_tunnel_stability - has the tunnel been dying and restarting?
#
# The gap this fills, found on 2026-09-19: every other check passed - tunnel
# answering, pool online, Samba running, plenty of space - while no backup
# would complete. The tunnel had been dropping mid-transfer and launchd had
# been restarting it, so by the time anyone looked it was up again and nothing
# said otherwise.
#
# launchd keeps both numbers, and together they are the whole story: `runs`
# counts starts since load, and `last exit code` is why the previous one
# stopped. A tunnel that is up now and exited non-zero before is a tunnel that
# is cycling, which reads as a network fault to Time Machine and as perfect
# health to everything else.
doctor_check_tunnel_stability() {
  local info
  info="$(priv_run_quiet /bin/launchctl print "system/${TMBOX_TUNNEL_LABEL}" 2>/dev/null)" || return 0
  [[ -n "$info" ]] || return 0

  local -i runs=0
  local last=""
  runs="$(print -r -- "$info" | awk '/^[[:space:]]*runs =/ {print $3; exit}')" || runs=0
  last="$(print -r -- "$info" | awk -F'= *' '/last exit code/ {print $2; exit}')"
  last="${last//[[:space:]]/}"

  if [[ -z "$last" || "$last" == "(never"* || "$last" == "0" ]]; then
    doc_pass "The tunnel has not dropped since it was loaded." "Started ${runs} time(s)."
    return 0
  fi

  doc_warn "The tunnel has dropped and been restarted (last exit ${last}, started ${runs} times)." \
    "A drop mid-backup looks to Time Machine like the network going away. If backups keep failing part-way, this is why - see /Library/Logs/tmbox/tunnel.log."
}

# --- 2. can we still get in -------------------------------------------------
#
# The standing weakness of an SSH forward against a VPN: the firewall is pinned
# to one address and home addresses change. When it happens, backups stop and
# nothing on the Mac explains why - so this is the check that earns the
# transport decision its keep.

doctor_check_reachability() {
  ui_rule "Reaching the appliance"
  ui_blank

  local recorded; recorded="$(state_get admin_cidr)"
  local current
  if ! current="$(public_ipv4)"; then
    doc_warn "Could not work out this connection's public address." \
             "Both detectors failed, which usually means no internet."
    return 0
  fi

  if [[ "$recorded" == "${current}/32" ]]; then
    doc_pass "The firewall allows this Mac's address (${current})."
    return 0
  fi

  if (( DOCTOR_FIX )); then
    local fw; fw="$(state_get firewall_id)"
    local token; token="$(kc_get hetzner-token 2>/dev/null)" || token=""
    if [[ -z "$fw" || -z "$token" ]]; then
      doc_fail "This Mac's address changed to ${current}, and it cannot be re-pinned." \
               "No firewall id or no API token on this Mac."
      return 0
    fi
    TMBOX_HCLOUD_TOKEN="$token"
    ui_item "Re-pinning the firewall to ${current}…"
    if hc_firewall_set_admin_cidr "$fw" "${current}/32" >/dev/null 2>&1; then
      state_set admin_cidr "${current}/32"
      doc_pass "The address had changed to ${current}; the firewall now allows it."
    else
      doc_fail "This Mac's address changed to ${current} and Hetzner refused the update." \
               "The full exchange is in ${TMBOX_LOG_FILE}."
    fi
  else
    doc_fail "This Mac's address has changed - the firewall still allows ${recorded:-nothing}, but you are now ${current}." \
             "Backups will fail until it is updated. Fix: tmbox doctor --fix"
  fi
}

# --- 3. the appliance -------------------------------------------------------
#
# One SSH round trip. Each fact is printed on its own line in a fixed order, so
# a command that is missing still occupies its line and the reader stays in
# step. Every one of these was a real defect in a validation run.

doctor_check_appliance() {
  ui_blank
  ui_rule "The appliance"
  ui_blank

  local host; host="$(state_get server_ip)"
  if [[ -z "$host" ]]; then
    doc_fail "No appliance address is recorded on this Mac."
    return 0
  fi

  local out
  if ! out="$(ssh_run "$host" "$(doctor_remote_script)" 2>/dev/null)"; then
    doc_fail "The appliance did not answer on ssh." \
             "If the address check above passed, the server may be off or still booting."
    return 0
  fi
  doc_pass "The appliance answers on ssh."

  local -a f=( "${(@f)out}" )
  local keystatus="${f[1]}" pool="${f[2]}" mountopts="${f[3]}" dio="${f[4]}"
  local smbd="${f[5]}" used="${f[6]}" quota="${f[7]}" pct="${f[8]}" mc="${f[9]}" sessions="${f[10]}"
  local shaper="${f[11]:-}"

  # Locked is not broken, and the difference matters: it is the resting state
  # after any reboot, and it has its own one-word fix.
  if [[ "$keystatus" == "available" ]]; then
    doc_pass "The dataset is unlocked."
  else
    doc_fail "The appliance is locked, so it is not serving the share." "Fix: tmbox unlock"
  fi

  case "$pool" in
    ONLINE)   doc_pass "The ZFS pool is ONLINE." ;;
    DEGRADED) doc_fail "The ZFS pool is DEGRADED." "On the appliance: zpool status -v tank" ;;
    SUSPENDED) doc_fail "The ZFS pool is SUSPENDED." \
                 "The Storage Box went away under it. On the appliance: zpool clear tank, then check the CIFS mount." ;;
    "")       doc_fail "The ZFS pool is not imported." "On the appliance: systemctl status tmbox-pool" ;;
    *)        doc_warn "The ZFS pool reports '${pool}'." ;;
  esac

  # Measured defect: mount.cifs defaults to soft and will not switch on
  # remount. Soft returns an error mid-write and leaves a truncated file, which
  # under ZFS is corruption - and nothing else reports it.
  case ",${mountopts}," in
    *,hard,*) doc_pass "The Storage Box is mounted hard, as required." ;;
    "",,)     doc_fail "The Storage Box is not mounted." "On the appliance: systemctl status mnt-sbox.mount" ;;
    *)        doc_fail "The Storage Box is mounted SOFT, not hard." \
                "A transport blip will silently truncate writes. Remount it: systemctl restart mnt-sbox.mount" ;;
  esac

  # Measured defect: buffered loop I/O over CIFS loses and reorders writes
  # while every other check stays green.
  case "$dio" in
    1) doc_pass "The loop device has direct-io on." ;;
    "") doc_warn "Could not read the loop device's direct-io setting." ;;
    *) doc_fail "The loop device has direct-io OFF." \
         "Writes can be lost or reordered. On the appliance: losetup -d, then bring the pool up again." ;;
  esac

  [[ "$smbd" == "active" ]] \
    && doc_pass "Samba is running." \
    || doc_fail "Samba is not running (${smbd:-unknown})." "On the appliance: systemctl status smbd"

  doctor_check_space "$used" "$quota" "$pct"
  doctor_check_multichannel "$host" "$mc"
  doctor_check_stale_sessions "$host" "$sessions"
  doctor_check_uplink "$host" "$shaper"
}

# doctor_check_uplink - the upload limit, as the kernel has it (#20)
#
# No limit is a choice, and is reported as one when it was made. Never having
# been asked - an appliance from before 0.1.4 - is a warning, because the
# symptom is the whole network slowing down during a backup, and nothing
# points from there to here. A limit recorded but not in force is the real
# fault: the shaper did not come up after a reboot.
doctor_check_uplink() {
  local host="$1" report="$2" configured active chosen
  chosen="$(state_get uplink_kbit)"
  configured="$(uplink_field "$report" configured)" || configured=""
  active="$(uplink_field "$report" active)" || active=""

  if [[ -z "$configured" ]]; then
    if [[ "$chosen" == off ]]; then
      doc_pass "Backups have no upload limit, as chosen."
    else
      doc_warn "Backups can take the whole upload of this connection." \
        "If the network slows down or drops during a backup, set a limit: tmbox limit auto"
    fi
    return 0
  fi

  if [[ "$configured" == "$active" ]]; then
    [[ "$configured" == off ]] \
      && doc_pass "Backups have no upload limit, as chosen." \
      || doc_pass "Backups are limited to $(uplink_fmt "$configured")."
    return 0
  fi

  if (( DOCTOR_FIX )) && ssh_run "$host" "systemctl restart tmbox-shape.service" >/dev/null 2>&1; then
    doc_pass "The upload limit was not in force; it is now ($(uplink_fmt "$configured"))."
    return 0
  fi
  doc_fail "The upload limit of $(uplink_fmt "$configured") is recorded but not in force." \
    "Fix: tmbox doctor --fix, or on the appliance: systemctl status tmbox-shape"
}

# doctor_check_multichannel - off, or a brief stall ends the backup (#17)
#
# Appliances built before 0.1.3 have Samba's default, on. Turning it off needs a
# Samba restart, which would drop a backup in progress - so --fix does it only
# when no client is connected, and otherwise says to run it again later.
doctor_check_multichannel() {
  local host="$1" mc="$2"
  case "${(L)mc}" in
    no)  doc_pass "SMB multichannel is off."; return 0 ;;
    "")  doc_warn "Could not read Samba's multichannel setting."; return 0 ;;
  esac

  if (( ! DOCTOR_FIX )); then
    doc_warn "SMB multichannel is on." \
      "Over the tunnel it turns a brief network stall into a failed backup. Fix: tmbox doctor --fix, while no backup is running"
    return 0
  fi

  local out
  out="$(ssh_run "$host" "$(doctor_multichannel_off_script)" 2>/dev/null)" || out=""
  case "$out" in
    *DONE*)  doc_pass "SMB multichannel was on; it is off now, and Samba was restarted." ;;
    *BUSY*)  doc_warn "SMB multichannel is on, and was left on: a client is connected." \
               "Turning it off restarts Samba, which would drop a backup in progress. Run tmbox doctor --fix again when none is running." ;;
    *)       doc_fail "Could not turn SMB multichannel off." \
               "On the appliance: add 'server multi channel support = no' under [global] in /etc/samba/smb.conf, then systemctl restart smbd" ;;
  esac
}

# doctor_multichannel_off_script - runs on the appliance; prints DONE or BUSY
#
# Edits smb.conf in place rather than rewriting it: the bootstrap owns that
# file, and the next bootstrap writes the same line anyway. testparm is the
# proof the edit took, before anything is restarted.
doctor_multichannel_off_script() {
  print -r -- 'set -e
f=/etc/samba/smb.conf
if [ "$(smbstatus -b 2>/dev/null | awk "/^[0-9]+ /" | wc -l)" -gt 0 ]; then echo BUSY; exit 0; fi
if grep -qiE "^[[:space:]]*server multi channel support" "$f"; then
  sed -i -E "s/^([[:space:]]*server multi channel support[[:space:]]*=).*/\1 no/I" "$f"
else
  sed -i "/^\[global\]/a\    server multi channel support = no" "$f"
fi
[ "$(testparm -s --parameter-name="server multi channel support" 2>/dev/null)" = "No" ]
systemctl restart smbd
systemctl is-active --quiet smbd
echo DONE'
}

# doctor_check_space - a full destination is the failure nobody sees
#
# Measured: Time Machine stalls silently when the destination is full. The
# client never reports it, so this is the only dependable signal and it has to
# be read server-side.
doctor_check_space() {
  local used="$1" quota="$2" pct="$3"
  if [[ -z "$pct" ]]; then
    doc_warn "Could not read how full the dataset is."
    return 0
  fi
  if   (( pct >= 95 )); then
    doc_fail "The dataset is ${pct}% full (${used} of ${quota})." \
      "Time Machine stalls silently on a full destination. Grow the box, or lower what is backed up."
  elif (( pct >= 85 )); then
    doc_warn "The dataset is ${pct}% full (${used} of ${quota})."
  else
    doc_pass "The dataset is ${pct}% full (${used} of ${quota})."
  fi
}

# doctor_check_stale_sessions - the lease deadlock, found the hard way
#
# A client that vanishes holding the share open - a Mac that slept, a tunnel
# killed mid-mount, a rebooted laptop - leaves Samba waiting for a lease break
# that will never come. Every later client then blocks indefinitely, with
# nothing in any log naming the cause. It cost 15 minutes of an apparently hung
# `tmutil setdestination` on 2026-09-17 before it was understood.
#
# Stale means: a session whose connection is gone. Samba keeps them until
# `deadtime` reaps them, and the default deadtime is 0, meaning never.
doctor_check_stale_sessions() {
  local host="$1" sessions="$2"
  local -i n="${sessions:-0}"

  if (( n == 0 )); then
    doc_pass "No stale Samba sessions."
    return 0
  fi

  if (( DOCTOR_FIX )); then
    ui_item "Clearing ${n} stale Samba session(s)…"
    if ssh_run "$host" 'smbcontrol smbd close-share "$(testparm -s --parameter-name="" 2>/dev/null)" >/dev/null 2>&1; systemctl restart smbd' >/dev/null 2>&1; then
      doc_pass "Cleared ${n} stale Samba session(s) by restarting Samba."
    else
      doc_fail "Could not clear ${n} stale Samba session(s)." \
               "On the appliance: systemctl restart smbd"
    fi
  else
    doc_warn "${n} Samba session(s) look stale." \
      "These block later backups indefinitely. Fix: tmbox doctor --fix"
  fi
}

# doctor_remote_script - ten facts, one per line, order fixed
#
# `|| echo` on every line so a missing command still produces its line: the
# reader above is positional, and a short answer would shift every later value
# onto the wrong name.
#
# Every line must also *end* in a newline, which is less obvious. The usage
# percentage was first printed with `printf "%d"` and no newline, so it ran
# into the next command's output: the dataset read as "00% full" and the
# session count silently became empty. Exactly the failure the paragraph above
# warns about, committed in the same function.
#
# **Stale is defined here, not guessed at.** A stale session is an smbd
# process that still holds a session while having no TCP socket - the client
# vanished and Samba is still waiting for a lease break that will never come.
# Comparing smbstatus against `ss` is what makes that checkable rather than a
# matter of opinion.
doctor_remote_script() {
  local mac; mac="$(state_get mac_name)"
  print -r -- "zfs get -H -o value keystatus tank/tm 2>/dev/null || echo unknown
zpool list -H -o health tank 2>/dev/null || echo ''
findmnt -no OPTIONS /mnt/sbox 2>/dev/null || echo ''
losetup -j /mnt/sbox/tank.img -O DIO -n 2>/dev/null | tr -d ' ' || echo ''
systemctl is-active smbd 2>/dev/null || echo inactive
zfs get -H -o value used tank/tm/${mac} 2>/dev/null || echo ''
zfs get -H -o value refquota tank/tm/${mac} 2>/dev/null || echo ''
zfs list -Hp -o used,refquota tank/tm/${mac} 2>/dev/null | awk '{ if (\$2 > 0) printf \"%d\\n\", (\$1 * 100) / \$2; else print \"\" }' || echo ''
testparm -s --parameter-name='server multi channel support' 2>/dev/null || echo ''
for p in \$(smbstatus -p 2>/dev/null | awk '/^[0-9]+/ {print \$1}'); do ss -tnp 2>/dev/null | grep -q \"pid=\$p,\" || echo \$p; done | wc -l | tr -d ' '
${UPLINK_SHAPER} show 2>/dev/null || echo ''"
}

# --- 4. Time Machine's own state --------------------------------------------

doctor_check_timemachine() {
  ui_blank
  ui_rule "Time Machine"
  ui_blank

  local share="tm-$(state_get mac_name)"
  local id; id="$(tm_destination_id "$share")"

  if [[ -z "$id" ]]; then
    doc_fail "Time Machine has no destination for this appliance." "Fix: tmbox setup"
    return 0
  fi

  # A destination recorded for a different appliance authenticates with the old
  # password and fails every backup with an error that blames the keychain.
  if [[ -n "$(state_get destination_server_id)" \
     && "$(state_get destination_server_id)" != "$(state_get server_id)" ]]; then
    doc_fail "The destination was set for an earlier appliance." \
             "Backups will fail with an authentication error. Fix: tmbox setup, then restart this Mac."
  else
    doc_pass "Time Machine has the right destination."
  fi

  local bundle; bundle="$(tm_bundle_path "$share" 2>/dev/null)" || bundle=""
  if [[ -z "$bundle" ]]; then
    ui_item "Encryption: not checked (needs administrator access, or no backup exists yet)."
  elif tm_bundle_is_encrypted "$bundle"; then
    doc_pass "Backups are encrypted by Time Machine."
  else
    doc_warn "Backups are NOT encrypted by Time Machine." \
      "This is the only layer nobody else can read, including us. System Settings → Time Machine."
  fi

  local latest rc=0
  latest="$(tm_latest_backup_for "$(state_get destination_id)")" || rc=$?
  if (( rc == 2 )); then
    ui_item "Last backup: not checked - reading it needs Full Disk Access for $(fda_app_name)."
  elif [[ -z "$latest" ]]; then
    doc_warn "No backup to the appliance has completed yet."
  else
    doc_pass "Last backup: $(status_backup_age "$latest")"
  fi
}

# --- the verdict ------------------------------------------------------------

doctor_summary() {
  ui_blank
  ui_rule "Verdict"
  ui_blank

  if (( DOCTOR_FAILED > 0 )); then
    ui_bad "${DOCTOR_FAILED} problem(s) need attention."
    (( DOCTOR_WARNED > 0 )) && ui_warn "${DOCTOR_WARNED} thing(s) worth knowing about."
    (( DOCTOR_FIX )) || ui_say "Some of these can be repaired automatically: tmbox doctor --fix"
    return 1
  fi

  if (( DOCTOR_WARNED > 0 )); then
    ui_warn "${DOCTOR_WARNED} thing(s) worth knowing about, nothing broken."
    return 2
  fi

  ui_ok "Everything checks out."
  return 0
}
