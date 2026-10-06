#!/bin/zsh
#
# tmbox transport - how backups reach the appliance, and changing it (#22).
#
#   tmbox transport                   which one is in use, and whether it works
#   tmbox transport ssh               switch to the SSH tunnel
#   tmbox transport wireguard         switch to WireGuard
#   tmbox transport tailscale         switch to Tailscale
#
# Setup chooses once; this is for later - typically for a Mac that has moved to
# a connection whose address keeps changing. What each one is, and why there
# are three, is in lib/transport.zsh. This file installs and removes them: the
# Mac's half, the appliance's half (appliance/transport.sh), and the Time
# Machine destination, whose URL names the transport's address.
#
# Switching never touches the backups. Time Machine is pointed at the same share
# through the new address, and the old transport is removed only once the new
# one has answered and the destination has been moved.

typeset -g TMBOX_WG_LABEL="pl.lab22.tmbox.wireguard"
typeset -g TMBOX_WG_PLIST="/Library/LaunchDaemons/${TMBOX_WG_LABEL}.plist"
typeset -g TMBOX_WG_LOG="${TMBOX_TUNNEL_LOG_DIR}/wireguard.log"
typeset -g TMBOX_TRANSPORT_TOOL=/usr/local/sbin/tmbox-transport

cmd_transport() {
  local want="${1:-}"
  (( $# <= 1 )) || ui_die "tmbox transport takes one value: ssh, wireguard or tailscale."

  ui_banner "tmbox transport" "How backups reach the appliance"

  if ! state_has server_id; then
    ui_bad "This Mac has no appliance recorded."
    ui_say "Run 'tmbox setup' first."
    return 3
  fi

  if [[ -z "$want" ]]; then
    transport_report
    return $?
  fi

  transport_valid "$want" || {
    ui_bad "'${want}' is not a transport tmbox knows."
    ui_say "Choose one of: ${(j:, :)TMBOX_TRANSPORTS}."
    return 2
  }

  transport_switch "$want"
}

# --- payloads ---------------------------------------------------------------
#
# Embedded in the built artifact and read from the checkout otherwise, like the
# tunnel's: the installer never fetches a second file.

transport_payload() {
  local var="$1" file="$2"
  local embedded="${(P)var:-}"
  if [[ -n "$embedded" ]]; then
    print -rn -- "$embedded" | base64 -d
    return 0
  fi
  local src="${TMBOX_ROOT:-}/${file}"
  [[ -f "$src" ]] || return 1
  cat -- "$src"
}

# transport_send_tool <host> - the appliance's half, current every time
transport_send_tool() {
  local src; src="$(transport_payload TMBOX_TRANSPORT_B64 appliance/transport.sh)" || return 1
  ssh_put_data "$1" "$src" "$TMBOX_TRANSPORT_TOOL" 0755 >/dev/null 2>&1
}

# transport_remote_show <host> - the appliance's own report, or nothing
transport_remote_show() {
  ssh_run "$1" "$TMBOX_TRANSPORT_TOOL show" 2>/dev/null
}

# --- installing, per transport ----------------------------------------------

# transport_install <kind> - both halves, until SMB answers through it
#
# Returns non-zero, having said why, when it cannot. Idempotent: run again, it
# finishes what it did not.
transport_install() {
  local kind="$1"
  local host; host="$(state_get server_ip)"
  case "$kind" in
    ssh)       tunnel_install ;;
    wireguard) wg_install "$host" ;;
    tailscale) ts_install "$host" ;;
    *)         return 2 ;;
  esac
}

# transport_remove <kind> - the Mac's half, and the appliance's VPN
#
# The appliance's SSH account is never removed: it is the restore path.
transport_remove() {
  local kind="$1"
  local host; host="$(state_get server_ip)"
  case "$kind" in
    ssh)
      [[ -f "$TMBOX_TUNNEL_PLIST" ]] && tunnel_uninstall
      ;;
    wireguard)
      wg_daemon_uninstall
      ssh_run "$host" "$TMBOX_TRANSPORT_TOOL wireguard-down" >/dev/null 2>&1 \
        || log_warn "could not take WireGuard down on the appliance"
      ;;
    tailscale)
      ssh_run "$host" "$TMBOX_TRANSPORT_TOOL tailscale-down" >/dev/null 2>&1 \
        || log_warn "could not take Tailscale down on the appliance"
      ;;
  esac
  return 0
}

# --- WireGuard: the Mac's client --------------------------------------------
#
# Two ways to have one, and the owner picks:
#
#   brew  wireguard-tools from Homebrew, which brings wireguard-go. tmbox runs
#         it as a LaunchDaemon of its own, so it is up before anyone logs in,
#         restarts if it dies, and is tmbox's to check and repair.
#   app   the WireGuard app from the App Store. It cannot be configured by a
#         script, so tmbox writes a configuration to import, and checks only
#         that SMB answers through it. On-Demand in the app is what keeps it up.

# wg_brew - Homebrew's own executable, or nothing
wg_brew() {
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$b" ]] && { print -rn -- "$b"; return 0 }
  done
  return 1
}

# wg_tool <wg|wireguard-go> - where Homebrew put it
#
# Looked up in Homebrew's prefixes rather than on PATH: the daemon runs as root
# from launchd, with a PATH that has neither.
wg_tool() {
  local d
  for d in /opt/homebrew/bin /usr/local/bin; do
    [[ -x "$d/$1" ]] && { print -rn -- "$d/$1"; return 0 }
  done
  return 1
}

wg_tools_present() { wg_tool wg >/dev/null && wg_tool wireguard-go >/dev/null }

wg_app_present() { [[ -d /Applications/WireGuard.app ]] }

# wg_choose_client - brew or app, asked once and recorded
#
# Asked when WireGuard is chosen, before anything is created or bought, so a
# Mac that can have neither finds out while nothing is billing.
wg_choose_client() {
  local have; have="$(state_get wireguard_client)"
  [[ -n "$have" ]] && { print -rn -- "$have"; return 0 }

  local client=""
  if ans_has WIREGUARD_CLIENT; then
    client="$(ans_get WIREGUARD_CLIENT)"
    [[ "$client" == (brew|app) ]] || ui_die "--wireguard-client takes brew or app."
  elif wg_tools_present || wg_brew >/dev/null; then
    client=brew
  elif wg_app_present; then
    client=app
  else
    client="$(ui_menu WIREGUARD_CLIENT "WireGuard needs a client on this Mac" \
      "app"  "The WireGuard app" "From the App Store. You import one file and switch on On-Demand; tmbox cannot do that for you." \
      "brew" "Homebrew"          "Install Homebrew first (brew.sh), then run tmbox setup again: tmbox installs and runs WireGuard itself.")"
    if [[ "$client" == brew ]] && ! wg_brew >/dev/null; then
      ui_say "Homebrew is not installed. Install it from https://brew.sh, then run tmbox setup again - nothing has been created."
      exit 1
    fi
  fi
  state_set wireguard_client "$client"
  print -rn -- "$client"
}

# wg_ensure_tools - wireguard-tools from Homebrew, with the owner's agreement
wg_ensure_tools() {
  wg_tools_present && return 0
  local brew; brew="$(wg_brew)" || {
    ui_bad "Homebrew is not installed, and WireGuard needs it here."
    ui_say "Install it from https://brew.sh, or choose the WireGuard app: tmbox transport wireguard --wireguard-client app"
    return 1
  }
  (( EUID == 0 )) && {
    ui_bad "Homebrew refuses to run as root, and tmbox is running as root."
    ui_say "Run tmbox as yourself; it asks for the administrator password when it needs it."
    return 1
  }

  ui_blank
  ui_say "WireGuard on this Mac comes from Homebrew: the formula wireguard-tools, which brings wireguard-go with it. Both are open source, from the WireGuard project, and installed with your own Homebrew - tmbox downloads nothing itself."
  ui_confirm INSTALL_WIREGUARD "Install wireguard-tools with Homebrew now?" "y" || {
    ui_say "Nothing was installed. Install it yourself with 'brew install wireguard-tools' and run this again."
    return 1
  }

  ui_spin_start "Installing wireguard-tools with Homebrew (a minute or two)"
  local out
  if ! out="$(HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install wireguard-tools 2>&1)"; then
    ui_spin_stop bad "Homebrew could not install it"
    log_error "brew install wireguard-tools: ${out//$'\n'/$'\036'}"
    ui_say "Its output is in ${TMBOX_LOG_FILE}."
    return 1
  fi
  log_info "brew install wireguard-tools: ${out//$'\n'/$'\036'}"
  ui_spin_stop ok "wireguard-tools installed"
  wg_tools_present
}

# --- WireGuard: keys and configuration --------------------------------------

# wg_keys <host> - this Mac's key pair, made once
#
# Made on the appliance, which has `wg` - a Mac using the App Store app has no
# command that can. The private half is never written there: it exists in the
# reply to this one command and then only in this Mac's credentials directory.
wg_keys() {
  local host="$1"
  if kc_has wireguard-key && state_has wireguard_mac_pubkey; then
    return 0
  fi
  local out
  out="$(ssh_run "$host" "$TMBOX_TRANSPORT_TOOL wireguard-keygen" 2>/dev/null)" || return 1
  local -a pair=( "${(@f)out}" )
  [[ ${#pair} -eq 2 && -n "${pair[1]}" && -n "${pair[2]}" ]] || return 1
  log_secret "${pair[1]}"
  kc_set wireguard-key "${pair[1]}" || return 1
  state_set wireguard_mac_pubkey "${pair[2]}"
}

# wg_render_conf <for: daemon|app> - this Mac's side of the tunnel
#
# The daemon's copy is for `wg setconf`, which takes no addresses - the helper
# sets those. The app's is wg-quick's format, which the app imports, and which
# carries this Mac's address itself.
#
# PersistentKeepalive 25: a phone's hotspot and carrier NAT both forget an idle
# UDP mapping within a minute or two, and without traffic the appliance would
# have nowhere to send to until this Mac spoke first.
wg_render_conf() {
  local key; key="$(kc_get wireguard-key)" || return 1
  local peer; peer="$(state_get wireguard_appliance_pubkey)"
  [[ -n "$key" && -n "$peer" ]] || return 1
  print -r -- "[Interface]"
  print -r -- "PrivateKey = ${key}"
  [[ "$1" == app ]] && print -r -- "Address = ${TMBOX_WG_MAC}/32"
  print -r -- ""
  print -r -- "[Peer]"
  print -r -- "PublicKey = ${peer}"
  print -r -- "Endpoint = $(state_get server_ip):${TMBOX_WG_PORT}"
  print -r -- "AllowedIPs = ${TMBOX_WG_APPLIANCE}/32"
  print -r -- "PersistentKeepalive = 25"
}

# wg_render_plist - the daemon's job description
wg_render_plist() {
  local body
  body="$(transport_payload TMBOX_WG_PLIST_B64 macos/wireguard.plist)" || return 1
  local go wg
  go="$(wg_tool wireguard-go)" || return 1
  wg="$(wg_tool wg)" || return 1
  body="${body//@LABEL@/$TMBOX_WG_LABEL}"
  body="${body//@HELPER@/${TMBOX_SYS_DIR}/tmbox-wireguard}"
  body="${body//@WGGO@/$go}"
  body="${body//@WG@/$wg}"
  body="${body//@CONF@/${TMBOX_SYS_DIR}/wireguard.conf}"
  body="${body//@ADDRESS@/$TMBOX_WG_MAC}"
  body="${body//@PEER@/$TMBOX_WG_APPLIANCE}"
  body="${body//@LOG@/$TMBOX_WG_LOG}"
  print -r -- "$body"
}

# --- WireGuard: the whole thing ---------------------------------------------

wg_install() {
  local host="$1"
  [[ -n "$host" ]] || { ui_bad "No appliance address is recorded."; return 1 }
  local client; client="$(wg_choose_client)"

  if [[ "$client" == brew ]]; then
    wg_ensure_tools || return 1
  fi

  ui_spin_start "Setting up WireGuard on the appliance"
  if ! transport_send_tool "$host"; then
    ui_spin_stop bad "Could not copy tmbox-transport to the appliance"
    return 1
  fi
  if ! wg_keys "$host"; then
    ui_spin_stop bad "Could not make this Mac's WireGuard key"
    return 1
  fi
  local out
  if ! out="$(ssh_run "$host" "$TMBOX_TRANSPORT_TOOL wireguard-up $(state_get wireguard_mac_pubkey) ${TMBOX_WG_APPLIANCE} ${TMBOX_WG_MAC} ${TMBOX_WG_PORT}" 2>&1)"; then
    ui_spin_stop bad "The appliance could not bring WireGuard up"
    log_warn "wireguard-up: ${out}"
    ui_say "What it said is in ${TMBOX_LOG_FILE}."
    return 1
  fi
  local pub="${${(M)${(f)out}:#pubkey=*}#pubkey=}"
  [[ -n "$pub" ]] || { ui_spin_stop bad "The appliance did not report its key"; return 1 }
  state_set wireguard_appliance_pubkey "$pub"
  ui_spin_stop ok "WireGuard is up on the appliance, behind a guard that admits only Samba, SSH and ping"

  # The appliance's host key, already pinned for its public address, is the
  # same key behind its tunnel address: pinned for that too, so administration
  # through the tunnel is checked against it rather than trusted on first use.
  ssh_pin_alias "$host" "$TMBOX_WG_APPLIANCE"

  if [[ "$client" == app ]]; then
    wg_app_handoff || return 1
  else
    wg_daemon_install || return 1
  fi

  state_set transport_ready wireguard
  ui_ok "WireGuard works: ${TMBOX_WG_APPLIANCE}:445 reaches the appliance's Samba."
  return 0
}

wg_daemon_install() {
  priv_prime || return 1

  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/tmbox-wg.XXXXXX")" \
    || { ui_bad "Could not create a private temporary directory."; return 1 }
  chmod 0700 "$stage" 2>/dev/null

  ui_spin_start "Installing the WireGuard tunnel"
  {
    transport_payload TMBOX_WG_BIN_B64 macos/tmbox-wireguard > "${stage}/tmbox-wireguard" 2>/dev/null \
      && wg_render_plist > "${stage}/wireguard.plist" 2>/dev/null \
      && ( umask 077; wg_render_conf daemon > "${stage}/wireguard.conf" ) 2>/dev/null
  } || {
    ui_spin_stop bad "Could not prepare the tunnel's files"
    rm -rf -- "$stage"
    return 1
  }
  if ! plutil -lint -- "${stage}/wireguard.plist" >/dev/null 2>&1; then
    ui_spin_stop bad "the generated job description is not valid"
    rm -rf -- "$stage"
    return 1
  fi

  priv_run mkdir -p -- "$TMBOX_SYS_DIR" "$TMBOX_TUNNEL_LOG_DIR" \
    && priv_run chmod 0755 "$TMBOX_SYS_DIR" "$TMBOX_TUNNEL_LOG_DIR" \
    && priv_run install -m 0600 -o root -g wheel -- "${stage}/wireguard.conf" "${TMBOX_SYS_DIR}/wireguard.conf" \
    && priv_run install -m 0755 -o root -g wheel -- "${stage}/tmbox-wireguard" "${TMBOX_SYS_DIR}/tmbox-wireguard" \
    && priv_run install -m 0644 -o root -g wheel -- "${stage}/wireguard.plist" "$TMBOX_WG_PLIST"
  local -i rc=$?
  rm -rf -- "$stage"
  (( rc == 0 )) || { ui_spin_stop bad "Could not install the tunnel's files"; return 1 }

  priv_run launchctl bootout "system/${TMBOX_WG_LABEL}" >/dev/null 2>&1
  local out
  out="$(priv_run launchctl bootstrap system "$TMBOX_WG_PLIST" 2>&1)" || {
    ui_spin_stop bad "launchd refused the job"
    ui_say "$out"
    return 1
  }
  ui_spin_stop ok "WireGuard tunnel installed"

  ui_spin_start "Waiting for Samba to answer through it"
  if ! smb_wait "$TMBOX_WG_APPLIANCE" 40; then
    ui_spin_stop bad "Nothing answers at ${TMBOX_WG_APPLIANCE}:445"
    wg_diagnose
    return 1
  fi
  ui_spin_stop ok "Samba answers through WireGuard"
  return 0
}

wg_daemon_uninstall() {
  [[ -f "$TMBOX_WG_PLIST" ]] || return 0
  priv_prime || return 1
  priv_run launchctl bootout "system/${TMBOX_WG_LABEL}" >/dev/null 2>&1
  priv_run rm -f -- "$TMBOX_WG_PLIST" "${TMBOX_SYS_DIR}/wireguard.conf" "${TMBOX_SYS_DIR}/tmbox-wireguard"
  priv_run rmdir -- "$TMBOX_SYS_DIR" 2>/dev/null
  return 0
}

# wg_app_handoff - the configuration for the WireGuard app, and a wait
#
# The one manual step of this route: the app imports a tunnel only through its
# own window. The file holds this Mac's private key, so it is written where the
# other credentials are, readable by this user only, and removed once the
# tunnel answers.
wg_app_handoff() {
  local dir="${TMBOX_STATE_DIR}/wireguard"
  local conf="${dir}/tmbox.conf"
  mkdir -p -- "$dir" && chmod 0700 "$dir"
  ( umask 077; wg_render_conf app > "$conf" ) || { ui_bad "Could not write the WireGuard configuration."; return 1 }

  if smb_probe "$TMBOX_WG_APPLIANCE"; then
    rm -f -- "$conf"
    return 0
  fi

  ui_blank
  ui_rule "In the WireGuard app"
  ui_blank
  wg_app_present || ui_item "Install WireGuard from the App Store first: https://apps.apple.com/app/wireguard/id1451685025"
  ui_item "Choose Import Tunnel(s) from File… and pick: ${conf}"
  ui_item "Allow it to add a VPN configuration when macOS asks."
  ui_item "Select the tunnel, choose Edit, and tick On-Demand for Ethernet and Wi-Fi - that is what keeps it up after a restart."
  ui_item "Activate it."
  ui_blank
  if (( ! TMBOX_NONINTERACTIVE )); then
    wg_app_present && open -a WireGuard 2>/dev/null
  fi

  local -i tries=0
  while (( tries < 5 )); do
    (( tries++ ))
    if (( TMBOX_NONINTERACTIVE )); then
      smb_wait "$TMBOX_WG_APPLIANCE" 120 && break
      tries=5; break
    fi
    ui_pause "Press return once the tunnel is active"
    ui_spin_start "Checking that Samba answers through it"
    if smb_wait "$TMBOX_WG_APPLIANCE" 20; then
      ui_spin_stop ok "Samba answers through WireGuard"
      rm -f -- "$conf"
      return 0
    fi
    ui_spin_stop bad "Nothing answers at ${TMBOX_WG_APPLIANCE}:445 yet"
  done
  if smb_probe "$TMBOX_WG_APPLIANCE"; then
    rm -f -- "$conf"
    return 0
  fi
  ui_say "The configuration stays in ${conf} until it works. Run this again once the tunnel is active."
  return 1
}

wg_diagnose() {
  ui_blank
  ui_say "What to check, in the order that usually finds it:"
  ui_item "the daemon's own errors:  sudo tail -20 ${TMBOX_WG_LOG}"
  ui_item "the tunnel's state:       sudo $(wg_tool wg 2>/dev/null || print -rn -- wg) show"
  ui_item "the job's state:          sudo launchctl print system/${TMBOX_WG_LABEL}"
  ui_blank
  return 0
}

wg_kickstart() {
  [[ -f "$TMBOX_WG_PLIST" ]] || return 1
  priv_prime || return 1
  if launchd_is_loaded "$TMBOX_WG_LABEL"; then
    priv_run launchctl kickstart -k "system/${TMBOX_WG_LABEL}" >/dev/null 2>&1
  else
    priv_run launchctl bootstrap system "$TMBOX_WG_PLIST" >/dev/null 2>&1
  fi
  smb_wait "$TMBOX_WG_APPLIANCE" 30
}

# --- Tailscale --------------------------------------------------------------
#
# The owner's own tailnet, joined by the appliance with an auth key the owner
# makes in Tailscale's admin console. tmbox runs nothing on this Mac for it:
# the Tailscale app does, and tmbox only reads its state. That is also the
# transport's one real weakness, and the reason doctor names it - Tailscale is
# on one tailnet at a time, so while the app is switched to another one the
# appliance is out of reach and backups fail until it is switched back.
#
# Measured on Debian 13 with Tailscale 1.102.5: `tailscale up --auth-key`
# takes "file:<path>", so the key never appears on a command line there.

# The standalone package is Tailscale's own, signed by Tailscale's Developer ID
# and notarised. The signature is checked before anything is installed: the
# team id is Tailscale Inc.'s, read from the package on 2026-10-06.
typeset -g TMBOX_TS_PKG_URL="https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg"
typeset -g TMBOX_TS_TEAM="W5364U7YZB"

# ts_cli - the Tailscale command on this Mac, or nothing
#
# Both macOS variants of the app carry the CLI inside the bundle; the open
# source tailscaled installs a `tailscale` of its own.
ts_cli() {
  local c
  for c in /Applications/Tailscale.app/Contents/MacOS/Tailscale \
           /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
    [[ -x "$c" ]] && { print -rn -- "$c"; return 0 }
  done
  return 1
}

# ts_status - `tailscale status --json`, or nothing
ts_status() {
  local cli; cli="$(ts_cli)" || return 1
  "$cli" status --json 2>/dev/null
}

# ts_field <jq filter> [status-json] - one value from the status
ts_field() {
  local json="${2:-}"
  [[ -n "$json" ]] || json="$(ts_status)" || return 1
  json_get "$1" "$json"
}

ts_running() { [[ "$(ts_field '.BackendState')" == Running ]] }

# ts_preflight - Tailscale on this Mac, running and logged in
#
# Called when Tailscale is chosen, before anything is bought. Offers to install
# the standalone package when there is none, with the owner's agreement; the
# app's own first run - the system extension, the VPN configuration and the
# login - needs clicks that no script can make, so it waits for them.
ts_preflight() {
  if ! ts_cli >/dev/null; then
    ui_blank
    ui_say "Tailscale is not installed on this Mac. tmbox can install the standalone app from Tailscale's own server (${TMBOX_TS_PKG_URL}), after checking that the package is signed by Tailscale and notarised by Apple."
    ui_confirm INSTALL_TAILSCALE "Download and install Tailscale now?" "y" || {
      ui_say "Nothing was installed. Install Tailscale from https://tailscale.com/download/mac and run this again."
      return 1
    }
    ts_install_app || return 1
  fi

  local -i tries=0
  while ! ts_running; do
    (( tries++ ))
    if (( TMBOX_NONINTERACTIVE )) || (( tries > 5 )); then
      ui_bad "Tailscale is installed but not running and logged in."
      ui_say "Open Tailscale, log in to the tailnet the appliance should join, and run this again."
      return 1
    fi
    ui_blank
    ui_say "Open Tailscale and log in to the tailnet the appliance should join. On its first start macOS asks you to allow its system extension and VPN configuration."
    (( ! TMBOX_NONINTERACTIVE )) && open -a Tailscale 2>/dev/null
    ui_pause "Press return once Tailscale shows you as connected"
  done

  local json; json="$(ts_status)"
  local tailnet mine
  tailnet="$(ts_field '.CurrentTailnet.Name' "$json")"
  mine="$(ts_field '.Self.TailscaleIPs[] | select(test("^[0-9.]+$"))' "$json" | head -1)"
  [[ -n "$mine" ]] || { ui_bad "Tailscale did not report an IPv4 address for this Mac."; return 1 }
  state_set tailscale_tailnet "$tailnet" tailscale_mac_ip "$mine"
  ui_ok "Tailscale is running on this Mac (${mine}, tailnet ${tailnet:-unknown})."
  return 0
}

# ts_install_app - the standalone package, verified, then installed
ts_install_app() {
  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/tmbox-ts.XXXXXX")" || return 1
  chmod 0700 "$stage" 2>/dev/null
  local pkg="${stage}/Tailscale.pkg"

  ui_spin_start "Downloading Tailscale"
  if ! curl -fsSL --max-time 300 -o "$pkg" "$TMBOX_TS_PKG_URL"; then
    ui_spin_stop bad "Could not download it"
    rm -rf -- "$stage"
    return 1
  fi
  ui_spin_stop ok "Downloaded"

  # Not only "signed": signed by Tailscale, and notarised.
  local sig; sig="$(pkgutil --check-signature "$pkg" 2>&1)" || sig=""
  if [[ "$sig" != *"Developer ID Installer: Tailscale Inc. (${TMBOX_TS_TEAM})"* \
     || "$sig" != *"trusted by the Apple notary service"* ]]; then
    ui_bad "The package is not signed by Tailscale and notarised; it was not installed."
    log_warn "pkgutil --check-signature: ${sig//$'\n'/$'\036'}"
    rm -rf -- "$stage"
    return 1
  fi

  priv_prime || { rm -rf -- "$stage"; return 1 }
  ui_spin_start "Installing Tailscale"
  if ! priv_run /usr/sbin/installer -pkg "$pkg" -target / >/dev/null 2>&1; then
    ui_spin_stop bad "The installer failed"
    rm -rf -- "$stage"
    return 1
  fi
  rm -rf -- "$stage"
  ui_spin_stop ok "Tailscale installed"
  return 0
}

# ts_ask_authkey - the key the appliance joins with, asked for once
ts_ask_authkey() {
  if ! ans_has TAILSCALE_AUTHKEY; then
    ui_blank
    ui_say "The appliance joins your tailnet with an auth key, which you make in Tailscale's admin console. tmbox sends it to the appliance on standard input and stores it nowhere."
    ui_item "Open https://login.tailscale.com/admin/settings/keys and choose Generate auth key."
    ui_item "Leave it one-off (not reusable) and not ephemeral. Pre-approved, if your tailnet approves devices."
    ui_item "Tagging it is optional. Without a tag, disable key expiry for the appliance in the Machines list afterwards, or it leaves the tailnet when the key expires; tmbox doctor will remind you."
    ui_blank
    (( ! TMBOX_NONINTERACTIVE )) && open "https://login.tailscale.com/admin/settings/keys" 2>/dev/null
  fi
  local key
  local -i tries=0
  while (( tries < 3 )); do
    (( tries++ ))
    key="${$(ui_ask_secret TAILSCALE_AUTHKEY "Paste the auth key")//[[:space:]]/}"
    if [[ "$key" == tskey-* ]]; then
      log_secret "$key"
      print -rn -- "$key"
      return 0
    fi
    ui_warn "A Tailscale auth key starts with tskey-."
    ans_has TAILSCALE_AUTHKEY && break
  done
  return 1
}

ts_install() {
  local host="$1"
  [[ -n "$host" ]] || { ui_bad "No appliance address is recorded."; return 1 }
  ts_preflight || return 1

  ui_spin_start "Installing Tailscale on the appliance"
  if ! transport_send_tool "$host"; then
    ui_spin_stop bad "Could not copy tmbox-transport to the appliance"
    return 1
  fi
  local out
  if ! out="$(ssh_run "$host" "$TMBOX_TRANSPORT_TOOL tailscale-install" 2>&1)"; then
    ui_spin_stop bad "Could not install Tailscale on the appliance"
    log_warn "tailscale-install: ${out}"
    return 1
  fi
  ui_spin_stop ok "Tailscale installed on the appliance"

  # Joined only once: an appliance already on the tailnet keeps its address,
  # and a second auth key would make it a second machine.
  local ip; ip="$(ts_appliance_ip "$host")"
  if [[ -z "$ip" ]]; then
    local key; key="$(ts_ask_authkey)" || { ui_bad "No auth key, so the appliance cannot join the tailnet."; return 1 }
    ui_spin_start "Joining the appliance to your tailnet"
    if ! ip="$(ssh_send_secret "$host" "$TMBOX_TRANSPORT_TOOL tailscale-up tmbox-$(state_get mac_name)" "$key" 2>/dev/null)" \
       || [[ "$ip" != <->.<->.<->.<-> ]]; then
      ui_spin_stop bad "The appliance could not join the tailnet"
      ui_say "The key may be used, expired, or for a tailnet that needs devices approved. Make a new one and run this again."
      return 1
    fi
    ui_spin_stop ok "The appliance joined as tmbox-$(state_get mac_name), at ${ip}"
  fi
  state_set tailscale_ip "$ip"

  ui_spin_start "Guarding the appliance's tailnet interface"
  if ! ssh_run "$host" "$TMBOX_TRANSPORT_TOOL tailscale-guard $(state_get tailscale_mac_ip)" >/dev/null 2>&1; then
    ui_spin_stop bad "Could not set up the guard"
    return 1
  fi
  ui_spin_stop ok "Only Samba, SSH and ping from this Mac get through"

  ssh_pin_alias "$host" "$ip"

  ui_spin_start "Waiting for Samba to answer through Tailscale"
  if ! smb_wait "$ip" 60; then
    ui_spin_stop bad "Nothing answers at ${ip}:445"
    ui_say "If your tailnet has access rules, they have to let this Mac reach the appliance on port 445."
    return 1
  fi
  ui_spin_stop ok "Samba answers through Tailscale"

  state_set transport_ready tailscale
  return 0
}

# ts_appliance_ip <host> - the appliance's tailnet address, if it has one
ts_appliance_ip() {
  local report; report="$(transport_remote_show "$1")" || return 0
  local word
  for word in ${=report}; do
    [[ "$word" == ts_ip=<->.<->.<->.<-> ]] && { print -rn -- "${word#ts_ip=}"; return 0 }
  done
  return 0
}

# ts_peer <appliance-ip> [status-json] - the appliance as this Mac's Tailscale sees it
#
# "direct <addr>", "relay <region>" or "offline", for status and doctor.
ts_peer() {
  local ip="$1" json="${2:-}"
  [[ -n "$json" ]] || json="$(ts_status)" || return 1
  print -r -- "$json" | jq -er --arg ip "$ip" '
    [.Peer[]? | select((.TailscaleIPs // []) | index($ip))][0]
    | if . == null then empty
      elif (.Online | not) then "offline"
      elif (.CurAddr // "") != "" then "direct \(.CurAddr)"
      else "relay \(.Relay // "unknown")" end' 2>/dev/null
}

# --- switching --------------------------------------------------------------

# transport_switch <kind>
#
# In the order that keeps a working path at every step: bring the new one up
# and prove it, move the firewall and the upload limit to it, point Time
# Machine at it, and only then take the old one down. A failure anywhere before
# the last step leaves the old transport carrying the backups as before.
transport_switch() {
  local want="$1" have; have="$(transport_kind)"

  # The same one again is a repair: install what is missing, point Time
  # Machine at it if it is not, and remove nothing.
  if [[ "$want" == "$have" ]]; then
    ui_say "Backups already use the $(transport_label "$want"). Checking that every part of it is in place."
    ui_blank
    transport_install "$want" && transport_repoint_destination || return 1
    ui_ok "The $(transport_label "$want") is in place."
    return 0
  fi

  local dest; dest="$(state_get destination_id)"
  if tm_running "$dest"; then
    ui_bad "A backup to the appliance is running. Switching now would end it."
    ui_say "Run this again when it has finished."
    return 5
  fi

  ui_say "Backups go through the $(transport_label "$have") now. tmbox will set up the $(transport_label "$want"), point Time Machine at the same share through it, and then remove the $(transport_label "$have"). The backups themselves are not touched."
  ui_blank
  ui_confirm SWITCH_TRANSPORT "Switch to the $(transport_label "$want")?" "y" || { ui_ok "Nothing was changed."; return 0 }

  http_init || ui_die "Could not create a private temporary directory."

  # The firewall first: the new transport's port has to be open before the
  # appliance can be reached through it - and the old one's stays open until
  # Time Machine has moved, because until then it carries the backups.
  local old_udp new_udp
  old_udp="$(transport_udp_port "$have")"
  new_udp="$(transport_udp_port "$want")"
  if [[ "$old_udp" != "$new_udp" ]]; then
    transport_firewall_ports ${old_udp} ${new_udp} || return 1
  fi

  if ! transport_install "$want"; then
    ui_blank
    ui_bad "The $(transport_label "$want") could not be set up; backups still go through the $(transport_label "$have")."
    return 1
  fi

  # From here on, this Mac talks to the appliance through the new transport.
  local previous_ready; previous_ready="$(state_get transport_ready)"
  state_set transport "$want"

  # The limit follows the transport, or it would go on shaping traffic that no
  # longer arrives that way.
  local rate; rate="$(state_get uplink_kbit)"
  if [[ -n "$rate" ]]; then
    limit_apply "$(appliance_host)" "$rate" >/dev/null 2>&1 \
      || ui_warn "The upload limit could not be moved to the new transport; tmbox limit $(limit_mbit "$rate") tries again."
  fi

  if ! transport_repoint_destination; then
    # Put the record back: Time Machine still uses the old address, so the old
    # transport is the one that carries the backups.
    state_set transport "$have"
    [[ -n "$previous_ready" ]] && state_set transport_ready "$previous_ready"
    ui_blank
    ui_say "The $(transport_label "$want") is set up but Time Machine was not moved to it; backups still go through the $(transport_label "$have"). Fix what is said above and run this again."
    return 1
  fi

  ui_spin_start "Removing the $(transport_label "$have")"
  transport_remove "$have"
  ui_spin_stop ok "The $(transport_label "$have") is removed"

  # And its port. The SSH rule is left as it was - pinned or open is the
  # owner's choice, and has nothing to do with the transport.
  if [[ "$old_udp" != "$new_udp" ]]; then
    transport_firewall_ports ${new_udp} \
      || ui_warn "The firewall still admits the old transport's port; tmbox firewall $( [[ "$(state_get admin_cidr)" == any ]] && print -rn -- any || print -rn -- pin) rewrites it."
  fi

  ui_blank
  ui_ok "Backups now go through the $(transport_label "$want")."
  return 0
}

# transport_firewall_ports [udp-port...] - the rule set, with these UDP ports
transport_firewall_ports() {
  local fw; fw="$(state_get firewall_id)"
  [[ -n "$fw" ]] || return 0
  local token; token="$(kc_get hetzner-token 2>/dev/null)" || token=""
  if [[ -z "$token" ]]; then
    ui_bad "No Hetzner API token on this Mac, and the firewall has to change for this."
    return 1
  fi
  TMBOX_HCLOUD_TOKEN="$token"
  local cidr; cidr="$(state_get admin_cidr)"
  if [[ -z "$cidr" ]]; then
    cidr="$(public_ipv4)" || { ui_bad "Could not determine this connection's public address."; return 1 }
    cidr="${cidr}/32"
  fi
  ui_spin_start "Updating the firewall"
  hc_firewall_set_admin_cidr "$fw" "$cidr" "${(j: :)@}" >/dev/null 2>&1
  ui_spin_stop ok "Firewall updated"
}

# transport_repoint_destination - the same share, at the new address
#
# Time Machine names a network destination by its URL, and the URL names the
# transport's address. So the destination is removed and added again, which is
# what setup does - with the same checks and the same password - and the
# backups already on the share are found and continued.
transport_repoint_destination() {
  local share="tm-$(state_get mac_name)"
  local url; url="$(transport_url "$share")"
  # destinationinfo names a destination and its id, not its URL, so "already
  # there" is the recorded URL plus Time Machine still having the recorded id.
  local id; id="$(state_get destination_id)"
  if [[ "$(state_get destination_url)" == "$url" && -n "$id" ]] \
     && tm_destinations_plist 2>/dev/null | grep -q -- "$id"; then
    return 0
  fi

  preflight_time_machine_ready || return 1
  local existing; existing="$(tm_destination_id "$share")"
  setup_add_destination "$share" "$url" "$existing" || return 1
  return 0
}

# --- reporting --------------------------------------------------------------

# transport_report - which transport, and does SMB answer through it
transport_report() {
  local kind; kind="$(transport_kind)"
  ui_kv "Transport" "$(transport_label "$kind")"
  case "$kind" in
    ssh)
      tunnel_report
      ;;
    wireguard)
      ui_kv "Address" "${TMBOX_WG_APPLIANCE} (this Mac is ${TMBOX_WG_MAC})"
      ui_kv "Client" "$( [[ "$(state_get wireguard_client)" == app ]] && print -rn -- "the WireGuard app" || print -rn -- "wireguard-go, run by tmbox")"
      if smb_probe "$TMBOX_WG_APPLIANCE"; then
        ui_ok "Samba answers through WireGuard"
      else
        ui_bad "Nothing answers at ${TMBOX_WG_APPLIANCE}:445"
        wg_diagnose
        return 1
      fi
      ;;
    tailscale)
      ui_kv "Address" "$(state_get tailscale_ip) (this Mac is $(state_get tailscale_mac_ip))"
      ui_kv "Tailnet" "$(state_get tailscale_tailnet)"
      local peer; peer="$(ts_peer "$(state_get tailscale_ip)" 2>/dev/null)"
      [[ -n "$peer" ]] && ui_kv "Path" "$peer"
      if smb_probe "$(state_get tailscale_ip)"; then
        ui_ok "Samba answers through Tailscale"
      else
        ui_bad "Nothing answers at $(state_get tailscale_ip):445"
        return 1
      fi
      ;;
  esac
  return 0
}
