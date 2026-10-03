#!/bin/zsh
#
# tmbox tunnel - the SSH forward that carries SMB, and the daemon that keeps it.
#
#   tmbox tunnel install     put the daemon in place and start it
#   tmbox tunnel status      is it loaded, is the alias up, is 445 answering
#   tmbox tunnel start|stop|restart
#   tmbox tunnel uninstall   remove the daemon, the key and the alias
#
# This is the whole transport. There is no VPN, no third-party agent and
# nothing listening on this Mac's network interfaces: one outbound SSH
# connection, a listener on a loopback alias, and a key that can open that one
# forward and do nothing else.
#
# **What needs root, and why.** Binding port 445 and adding a loopback alias
# both do, and the port cannot be avoided - `tmutil setdestination` validates a
# network destination by opening its own SMB session, and that session ignores a
# port in the URL. Measured in the Tart guest on macOS 26.6: 127.0.0.2:445
# succeeds, 127.0.0.2:4445 fails with authentication error 80, everything else
# held constant. `tmutil setdestination` needs root in its own right, so a
# tmbox setup asks for the administrator password once and does both.
#
# **What root does not get.** The key installed for the daemon is the restricted
# one: its authorized_keys line on the appliance is
# `restrict,port-forwarding,permitopen="127.0.0.1:445",command=""`, so a
# compromise of this Mac yields the ability to reach one Samba port on one
# machine - not a shell, not the pool, and not the key that decrypts it.

typeset -g TMBOX_TUNNEL_LABEL="pl.lab22.tmbox.tunnel"
# Not ~/.config/tmbox, where everything else tmbox keeps now lives. This is a
# LaunchDaemon: it starts before anyone logs in, so a path under a home
# directory is not reliably there when it runs, and its key and known_hosts must
# be root-owned files no user can replace. /Library/Application Support is the
# documented home for exactly that. The XDG argument is about command-line tools
# and the people who type their paths; it does not reach a root daemon.
typeset -g TMBOX_SYS_DIR="/Library/Application Support/tmbox"
typeset -g TMBOX_TUNNEL_PLIST="/Library/LaunchDaemons/${TMBOX_TUNNEL_LABEL}.plist"
typeset -g TMBOX_TUNNEL_LOG_DIR="/Library/Logs/tmbox"
typeset -g TMBOX_TUNNEL_LOG="${TMBOX_TUNNEL_LOG_DIR}/tunnel.log"
typeset -g TMBOX_TUNNEL_USER="tmtunnel"

cmd_tunnel() {
  local action="${1:-status}"
  case "$action" in
    install)   tunnel_install ;;
    uninstall) tunnel_uninstall ;;
    start)     tunnel_kickstart ;;
    stop)      tunnel_stop ;;
    restart)   tunnel_stop; tunnel_kickstart ;;
    status)    tunnel_report ;;
    *)
      ui_bad "Unknown action: ${action}"
      ui_say "Try: tmbox tunnel {install|start|stop|restart|status|uninstall}"
      return 2
      ;;
  esac
}

# --- the payloads -----------------------------------------------------------
#
# Embedded in the built artifact and read from the checkout otherwise, so the
# installer never fetches a second file at install time.

tunnel_payload_bin() {
  if (( ${+TMBOX_TUNNEL_BIN_B64} )) && [[ -n "$TMBOX_TUNNEL_BIN_B64" ]]; then
    print -rn -- "$TMBOX_TUNNEL_BIN_B64" | base64 -d
    return 0
  fi
  local src="${TMBOX_ROOT:-}/macos/tmbox-tunnel"
  [[ -f "$src" ]] || return 1
  cat -- "$src"
}

tunnel_payload_plist() {
  if (( ${+TMBOX_TUNNEL_PLIST_B64} )) && [[ -n "$TMBOX_TUNNEL_PLIST_B64" ]]; then
    print -rn -- "$TMBOX_TUNNEL_PLIST_B64" | base64 -d
    return 0
  fi
  local src="${TMBOX_ROOT:-}/macos/tunnel.plist"
  [[ -f "$src" ]] || return 1
  cat -- "$src"
}

# tunnel_render_plist <host>
#
# The template's @TOKENS@ become real paths. Substituted in the shell rather
# than with sed, because two of these values are absolute paths containing
# spaces and one sed metacharacter in a path is a silently malformed daemon.
tunnel_render_plist() {
  local host="$1"
  local body; body="$(tunnel_payload_plist)" || return 1
  body="${body//@LABEL@/$TMBOX_TUNNEL_LABEL}"
  body="${body//@HELPER@/${TMBOX_SYS_DIR}/tmbox-tunnel}"
  body="${body//@HOST@/$host}"
  body="${body//@USER@/$TMBOX_TUNNEL_USER}"
  body="${body//@KEY@/${TMBOX_SYS_DIR}/tunnel_key}"
  body="${body//@KNOWN_HOSTS@/${TMBOX_SYS_DIR}/known_hosts}"
  body="${body//@BIND@/$TM_LOOPBACK_ALIAS}"
  body="${body//@LOG@/$TMBOX_TUNNEL_LOG}"
  print -r -- "$body"
}

# --- install ----------------------------------------------------------------

tunnel_install() {
  local host; host="$(state_get server_ip)"
  if [[ -z "$host" ]]; then
    ui_bad "This Mac has no appliance recorded."
    ui_say "Run tmbox setup first; the tunnel needs an address to connect to."
    return 1
  fi

  local key; key="$(ssh_key_path tunnel)"
  if [[ ! -f "$key" ]]; then
    ui_bad "The tunnel key is missing from ${key}."
    ui_say "It is created during setup and its public half is installed on the appliance. Without it, nothing can open the forward."
    return 1
  fi

  priv_prime || return 1

  # Staged in the private scratch directory first, then moved into place by
  # install(1) with the final owner and mode in one step. Nothing is ever
  # created world-readable and then narrowed: that window is small but real,
  # and one of the files is a private key.
  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/tmbox-tunnel.XXXXXX")" \
    || { ui_bad "Could not create a private temporary directory."; return 1 }
  chmod 0700 "$stage" 2>/dev/null

  ui_spin_start "Installing the tunnel"

  tunnel_payload_bin > "${stage}/tmbox-tunnel" 2>/dev/null \
    || { ui_spin_stop bad "missing payload"; rm -rf -- "$stage"
         ui_die "The tunnel helper is missing from this build." }

  tunnel_render_plist "$host" > "${stage}/tunnel.plist" 2>/dev/null \
    || { ui_spin_stop bad "missing payload"; rm -rf -- "$stage"
         ui_die "The tunnel job description is missing from this build." }

  # Checked before it is installed, because launchd's own complaint about a
  # malformed job says nothing a user could act on.
  if ! plutil -lint -- "${stage}/tunnel.plist" >/dev/null 2>&1; then
    ui_spin_stop bad "the generated job description is not valid"
    log_error "rendered plist failed plutil -lint"
    rm -rf -- "$stage"
    return 1
  fi

  priv_run mkdir -p -- "$TMBOX_SYS_DIR" "$TMBOX_TUNNEL_LOG_DIR" \
    || { ui_spin_stop bad "could not create ${TMBOX_SYS_DIR}"; rm -rf -- "$stage"; return 1 }
  priv_run chmod 0755 "$TMBOX_SYS_DIR" "$TMBOX_TUNNEL_LOG_DIR" 2>/dev/null

  # The key is copied rather than referenced in place. A daemon that reads its
  # key from the user's home directory depends on that home being available and
  # on a file the user can replace; root-owned at 0600 next to the job it serves
  # is what makes "a key a root daemon can read" true without qualification.
  priv_run install -m 0600 -o root -g wheel -- "$key" "${TMBOX_SYS_DIR}/tunnel_key" \
    || { ui_spin_stop bad "could not install the key"; rm -rf -- "$stage"; return 1 }

  # The pinned host key travels with it. Without it the daemon would pin the
  # host again on its own, from whatever answers at that address at boot.
  if [[ -f "$SSH_KNOWN_HOSTS" ]]; then
    priv_run install -m 0644 -o root -g wheel -- "$SSH_KNOWN_HOSTS" "${TMBOX_SYS_DIR}/known_hosts" \
      || { ui_spin_stop bad "could not install the pinned host key"; rm -rf -- "$stage"; return 1 }
  else
    log_warn "no pinned host key to install; the daemon will pin on first connection"
    : > "${stage}/known_hosts"
    priv_run install -m 0644 -o root -g wheel -- "${stage}/known_hosts" "${TMBOX_SYS_DIR}/known_hosts"
  fi

  priv_run install -m 0755 -o root -g wheel -- "${stage}/tmbox-tunnel" "${TMBOX_SYS_DIR}/tmbox-tunnel" \
    || { ui_spin_stop bad "could not install the helper"; rm -rf -- "$stage"; return 1 }

  priv_run install -m 0644 -o root -g wheel -- "${stage}/tunnel.plist" "$TMBOX_TUNNEL_PLIST" \
    || { ui_spin_stop bad "could not install the job"; rm -rf -- "$stage"; return 1 }

  rm -rf -- "$stage"

  # bootout first, and its failure is ignored on purpose: a job that was not
  # loaded is the normal case on a first install.
  priv_run launchctl bootout "system/${TMBOX_TUNNEL_LABEL}" >/dev/null 2>&1
  local out
  out="$(priv_run launchctl bootstrap system "$TMBOX_TUNNEL_PLIST" 2>&1)" || {
    ui_spin_stop bad "launchd refused the job"
    ui_say "${out}"
    return 1
  }

  ui_spin_stop ok "Tunnel installed"
  state_set tunnel_installed yes tunnel_host "$host"

  tunnel_wait_listening 30 || {
    ui_warn "The forward is not answering yet."
    tunnel_diagnose
    return 1
  }

  ui_ok "The forward is up: ${TM_LOOPBACK_ALIAS}:445 reaches the appliance's Samba."
  return 0
}

# --- uninstall --------------------------------------------------------------

tunnel_uninstall() {
  priv_prime || return 1
  ui_spin_start "Removing the tunnel"

  priv_run launchctl bootout "system/${TMBOX_TUNNEL_LABEL}" >/dev/null 2>&1
  priv_run rm -f -- "$TMBOX_TUNNEL_PLIST"
  priv_run rm -f -- "${TMBOX_SYS_DIR}/tunnel_key" \
                    "${TMBOX_SYS_DIR}/known_hosts" \
                    "${TMBOX_SYS_DIR}/tmbox-tunnel"
  # The directory goes only if it is empty: an unlock-at-boot agent, planned for
  # a later release, is to live here too, and removing the tunnel must not
  # disable it.
  priv_run rmdir -- "$TMBOX_SYS_DIR" 2>/dev/null

  # The alias is removed last. It is harmless to leave, but leaving it would
  # make a later `tmbox doctor` report a listener-less address as half-configured.
  lo_alias_present && priv_run ifconfig lo0 -alias "$TM_LOOPBACK_ALIAS" 2>/dev/null

  state_unset tunnel_installed
  ui_spin_stop ok "Tunnel removed"
  return 0
}

# --- start, stop ------------------------------------------------------------

tunnel_stop() {
  if ! launchd_is_loaded "$TMBOX_TUNNEL_LABEL"; then
    ui_ok "The tunnel is not running."
    return 0
  fi
  priv_prime || return 1
  # `bootout`, not `kill`: KeepAlive would restart anything that merely died.
  priv_run launchctl bootout "system/${TMBOX_TUNNEL_LABEL}" >/dev/null 2>&1
  ui_ok "Tunnel stopped. Backups will fail until it is started again."
  return 0
}

tunnel_kickstart() {
  if [[ ! -f "$TMBOX_TUNNEL_PLIST" ]]; then
    ui_warn "The tunnel is not installed."
    ui_say "Run: tmbox tunnel install"
    return 1
  fi
  priv_prime || return 1

  if launchd_is_loaded "$TMBOX_TUNNEL_LABEL"; then
    # -k restarts a running job rather than refusing; without it a hung ssh
    # would survive a "start" and look like a start that did nothing.
    priv_run launchctl kickstart -k "system/${TMBOX_TUNNEL_LABEL}" >/dev/null 2>&1
  else
    priv_run launchctl bootstrap system "$TMBOX_TUNNEL_PLIST" >/dev/null 2>&1
  fi

  if tunnel_wait_listening 30; then
    ui_ok "The forward is up."
    return 0
  fi
  ui_bad "The forward did not come up."
  tunnel_diagnose
  return 1
}

# --- state ------------------------------------------------------------------

# The smallest legal SMB2 NEGOTIATE request, base64 so it survives being
# embedded in a shell script: a 4-byte NetBIOS length followed by a 64-byte
# SMB2 header and a 38-byte negotiate body offering dialect 0x0202. Any SMB
# server answers it, before and without authentication.
#
# Carried as a constant rather than built with printf escapes, because counting
# a hundred \x00 by hand is exactly the kind of thing that is wrong by two
# bytes and still looks right - which it was, the first time this was written.
typeset -g TMBOX_SMB_NEGOTIATE_B64="AAAAZv5TTUJAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAkAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAg=="

# tunnel_listening - does a real SMB server answer through the forward?
#
# **Not a TCP connect.** `ssh -L` binds the local port itself, so the port
# accepts connections whether or not the far end is reachable: `nc -z` succeeds
# against an appliance that is switched off, locked, or not running Samba.
# Measured 2026-09-19 against a deliberately locked appliance - `nc -z`
# reported success while every backup failed. A check that passes when the
# thing it checks is broken is worse than no check, because it sends people
# looking elsewhere.
#
# So the probe speaks SMB: send a NEGOTIATE, require an SMB2 reply. That proves
# the whole path end to end - daemon, ssh channel, the appliance's sshd, its
# loopback, and smbd actually serving - in one round trip and with no
# credential.
tunnel_listening() {
  local -i timeout="${1:-6}"
  local reply
  reply="$(print -rn -- "$TMBOX_SMB_NEGOTIATE_B64" \
    | base64 -D 2>/dev/null \
    | nc -w "$timeout" "$TM_LOOPBACK_ALIAS" 445 2>/dev/null \
    | dd bs=1 skip=4 count=4 2>/dev/null)"
  [[ "$reply" == $'\xfeSMB' ]]
}

# tunnel_port_open - the weaker question, kept because it separates two faults
#
# If this succeeds and tunnel_listening does not, the daemon is running and the
# appliance is not answering. If neither succeeds, the daemon itself is down.
# Saying which of those it is turns a diagnosis into an instruction.
tunnel_port_open() {
  nc -z -G 3 -w 3 "$TM_LOOPBACK_ALIAS" 445 >/dev/null 2>&1
}

tunnel_wait_listening() {
  local -i timeout="${1:-30}" waited=0
  while (( waited < timeout )); do
    tunnel_listening && return 0
    sleep 2
    (( waited += 2 ))
  done
  return 1
}

tunnel_report() {
  ui_rule "Tunnel"
  ui_blank

  local host; host="$(state_get server_ip)"
  ui_kv "Appliance" "${host:-(none recorded)}"
  ui_kv "Listener"  "${TM_LOOPBACK_ALIAS}:445 → 127.0.0.1:445 on the appliance"

  if [[ -f "$TMBOX_TUNNEL_PLIST" ]]; then
    ui_ok "Installed"
  else
    ui_warn "Not installed - run: tmbox tunnel install"
  fi

  if launchd_is_loaded "$TMBOX_TUNNEL_LABEL"; then
    ui_ok "Loaded by launchd"
    # The last exit status is the useful field: a KeepAlive job that is
    # restarting every thirty seconds looks loaded, and its last exit code is
    # the only thing on screen that says otherwise.
    local last
    last="$(priv_run launchctl print "system/${TMBOX_TUNNEL_LABEL}" 2>/dev/null \
            | sed -n 's/^[[:space:]]*last exit code = \(.*\)$/\1/p' | head -1)"
    # Numeric and non-zero only: a job that has never exited reports the literal
    # "(never exited)", which is the healthiest possible answer and must not be
    # dressed up as a warning.
    [[ "$last" == <-> && "$last" != "0" ]] && ui_warn "Last exit code: ${last}"
  else
    ui_warn "Not loaded"
  fi

  if lo_alias_present; then
    ui_ok "Loopback alias ${TM_LOOPBACK_ALIAS} is up"
  else
    ui_warn "Loopback alias ${TM_LOOPBACK_ALIAS} is missing"
  fi

  if tunnel_listening; then
    ui_ok "Port 445 answers on ${TM_LOOPBACK_ALIAS}"
  else
    ui_bad "Nothing answers on ${TM_LOOPBACK_ALIAS}:445"
  fi

  # If Time Machine's share happens to be mounted, the one fact worth printing
  # is the one that cannot be inferred from the appliance's own configuration.
  local mp
  for mp in /Volumes/*(N/); do
    smb_statshares "$mp" | grep -q "$TM_LOOPBACK_ALIAS" || continue
    if smb_is_time_machine_capable "$mp"; then
      ui_ok "Mounted at ${mp}, and the server advertises Time Machine support"
    else
      ui_bad "Mounted at ${mp}, but the server does not advertise Time Machine support"
    fi
    ui_kv "Dialect" "$(smb_dialect "$mp")"
  done

  ui_blank
  return 0
}

# tunnel_diagnose - what to read when the forward will not come up
tunnel_diagnose() {
  ui_blank
  ui_say "What to check, in the order that usually finds it:"
  ui_item "the appliance is reachable:  $(ssh_hint "$(state_get server_ip)" true)"
  ui_item "the daemon's own errors:     sudo tail -20 ${TMBOX_TUNNEL_LOG}"
  ui_item "the job's state:             sudo launchctl print system/${TMBOX_TUNNEL_LABEL}"
  ui_blank
  if [[ -r "$TMBOX_TUNNEL_LOG" ]]; then
    local -a lines
    lines=( ${(f)"$(tail -5 -- "$TMBOX_TUNNEL_LOG" 2>/dev/null)"} )
    if (( ${#lines} )); then
      ui_rule "Last lines from the tunnel"
      local l; for l in $lines; do ui_item "$l"; done
      ui_blank
    fi
  fi
  return 0
}
