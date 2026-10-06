#!/bin/zsh
#
# How the Time Machine traffic reaches the appliance (#22).
#
# Until 0.2.0 there was one answer, an SSH forward, and every command assumed
# it. That forward has two weaknesses on a connection whose address changes -
# a phone's hotspot, LTE, 5G - and neither can be fixed inside it:
#
#   1. the firewall admits tcp/22 from one address, so every change locks the
#      Mac out until `tmbox doctor --fix` re-pins it;
#   2. ssh is one TCP connection bound to that address, so every change ends it,
#      and a backup in flight ends with it.
#
# So the transport is chosen at setup, and this file is the one place that knows
# what each choice means:
#
#   ssh        the default, and still the one with nothing to install. Time
#              Machine talks to 127.0.0.2:445, which ssh forwards to the
#              appliance's own Samba.
#   wireguard  a WireGuard tunnel of tmbox's own, with an address at each end.
#              It roams: the appliance learns the Mac's new address from the next
#              authenticated packet, and the connections inside carry on.
#   tailscale  the owner's existing tailnet. Roams the same way, but only while
#              the Mac's Tailscale is on the tailnet the appliance joined.
#
# The SSH account and its restricted key are provisioned whatever is chosen:
# they are the restore path from macOS Recovery (D10), not only a transport.

typeset -ga TMBOX_TRANSPORTS=(ssh wireguard tailscale)

# The WireGuard addresses. A /24 that nothing in a home, a Hetzner project or a
# tailnet uses by default: not 10.0.x (Hetzner private networks, most routers),
# not 192.168.x, not 172.16-31 (Docker), not 100.64/10 (Tailscale, carrier NAT).
typeset -g TMBOX_WG_NET="${TMBOX_WG_NET:-10.209.77}"
typeset -g TMBOX_WG_APPLIANCE="${TMBOX_WG_NET}.1"
typeset -g TMBOX_WG_MAC="${TMBOX_WG_NET}.2"
typeset -gi TMBOX_WG_PORT=51820
# Tailscale's own default. Open on the appliance so it is the "easy" side of
# NAT traversal, which is what lets a Mac behind carrier NAT connect directly
# rather than through a relay.
typeset -gi TMBOX_TS_PORT=41641

# transport_kind - ssh, wireguard or tailscale
#
# An installation from before 0.2.0 has no transport recorded, and it is ssh.
transport_kind() {
  local kind; kind="$(state_get transport)"
  print -rn -- "${kind:-ssh}"
}

# transport_valid <name>
transport_valid() { (( ${TMBOX_TRANSPORTS[(Ie)$1]} )) }

# transport_label [kind] - for people
transport_label() {
  case "${1:-$(transport_kind)}" in
    ssh)       print -rn -- "SSH tunnel" ;;
    wireguard) print -rn -- "WireGuard" ;;
    tailscale) print -rn -- "Tailscale" ;;
    *)         print -rn -- "$1" ;;
  esac
}

# transport_name [kind] - the same, as it reads inside a sentence
#
# "through the SSH tunnel", but "through WireGuard": a product name takes no
# article, and "the WireGuard" is what the first switch printed.
transport_name() {
  case "${1:-$(transport_kind)}" in
    ssh) print -rn -- "the SSH tunnel" ;;
    *)   transport_label "${1:-}" ;;
  esac
}

# transport_Name [kind] - the same, at the start of a sentence
transport_Name() {
  local n; n="$(transport_name "${1:-}")"
  print -rn -- "${(U)n[1]}${n[2,-1]}"
}

# transport_smb_host [kind] - the address in Time Machine's smb:// URL
#
# Empty for tailscale until the appliance has joined the tailnet and its address
# is recorded.
transport_smb_host() {
  case "${1:-$(transport_kind)}" in
    ssh)       print -rn -- "$TM_LOOPBACK_ALIAS" ;;
    wireguard) print -rn -- "$TMBOX_WG_APPLIANCE" ;;
    tailscale) print -rn -- "$(state_get tailscale_ip)" ;;
  esac
}

# transport_url <share> [kind] - the destination as tmutil is given it
transport_url() {
  print -rn -- "smb://${TMBOX_SHARE_USER}@$(transport_smb_host "${2:-}")/${1}"
}

# transport_udp_port [kind] - what the firewall has to let in, or nothing
#
# Both are open to any address. Neither answers anything that does not carry a
# valid key - WireGuard and Tailscale both stay silent to unauthenticated
# packets - so there is nothing on these ports for a scanner to find.
transport_udp_port() {
  case "${1:-$(transport_kind)}" in
    wireguard) print -rn -- "$TMBOX_WG_PORT" ;;
    tailscale) print -rn -- "$TMBOX_TS_PORT" ;;
  esac
}

# transport_shape_match [kind] - where the upload limit catches the backup
#
# "<interface|wan> <tcp|udp> <port>", as appliance/shape.sh takes it. The limit
# has to see the traffic that actually carries the backup:
#
#   ssh        the tunnel arrives on the WAN interface as tcp/22
#   wireguard  the tunnel arrives on the WAN interface as udp/51820, whatever
#              is inside it - and that interface always exists, so the limit
#              does not depend on wg0 being up when it is applied
#   tailscale  Tailscale's packets arrive either directly on udp/41641 or
#              relayed over a TCP connection the appliance opened itself, so
#              the only place that sees both is tailscale0, after decryption,
#              where Samba's own port is what to match
transport_shape_match() {
  case "${1:-$(transport_kind)}" in
    ssh)       print -rn -- "wan tcp 22" ;;
    wireguard) print -rn -- "wan udp ${TMBOX_WG_PORT}" ;;
    tailscale) print -rn -- "tailscale0 tcp 445" ;;
  esac
}

# --- is SMB really there ----------------------------------------------------

# The smallest legal SMB2 NEGOTIATE request, base64 so it survives being
# embedded in a shell script: a 4-byte NetBIOS length followed by a 64-byte
# SMB2 header and a 38-byte negotiate body offering dialect 0x0202. Any SMB
# server answers it, before and without authentication.
#
# Carried as a constant rather than built with printf escapes, because counting
# a hundred \x00 by hand is exactly the kind of thing that is wrong by two
# bytes and still looks right - which it was, the first time this was written.
typeset -g TMBOX_SMB_NEGOTIATE_B64="AAAAZv5TTUJAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAkAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAg=="

# smb_probe <host> [timeout] - does a real SMB server answer there?
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
# the whole path end to end - whichever transport carries it, the appliance,
# and smbd actually serving - in one round trip and with no credential.
smb_probe() {
  local host="$1"
  local -i timeout="${2:-6}"
  [[ -n "$host" ]] || return 1
  local reply
  # -G as well as -w. On macOS -w only bounds an idle connection; the connect
  # itself waits for the kernel's own timeout, about 75 seconds. A probe sent
  # while a WireGuard tunnel was still coming up therefore hung for 77 seconds
  # on a SYN that had gone out of the wrong interface, measured three times
  # in a row, and every later probe waited behind it.
  reply="$(print -rn -- "$TMBOX_SMB_NEGOTIATE_B64" \
    | base64 -D 2>/dev/null \
    | nc -G "$timeout" -w "$timeout" "$host" 445 2>/dev/null \
    | dd bs=1 skip=4 count=4 2>/dev/null)"
  [[ "$reply" == $'\xfeSMB' ]]
}

# smb_client_connections - this Mac's open connections to the share's address
#
# Counted from this side, for doctor: a session the appliance still has while
# this Mac has no connection at all is a session nobody will ever close.
smb_client_connections() {
  local host; host="$(transport_smb_host)"
  [[ -n "$host" ]] || { print -rn -- 0; return 0 }
  local -i n
  n="$(netstat -an -p tcp 2>/dev/null | grep -F "${host}.445 " | grep -c ESTABLISHED)"
  print -rn -- $n
}

# smb_wait <host> <seconds>
smb_wait() {
  local host="$1"
  local -i timeout="${2:-30}" waited=0
  while (( waited < timeout )); do
    smb_probe "$host" && return 0
    sleep 2
    (( waited += 2 ))
  done
  return 1
}

# --- the history across a switch --------------------------------------------

# appliance_last_backup - the newest backup to the appliance, for status/doctor
#
# tm_latest_backup_for's answer, with one addition. Moving to another transport
# gives Time Machine a new destination, and a new destination has no backup
# dates of its own until its first backup - although the history is all there
# and the next backup continues it. So `tmbox transport` records the last
# backup from before the move, and until a backup lands through the new
# transport that one is reported, with status 3 to say where it came from.
appliance_last_backup() {
  local out rc=0
  out="$(tm_latest_backup_for "$(state_get destination_id)")" || rc=$?
  if (( rc == 0 )) && [[ -n "$out" ]]; then
    print -rn -- "$out"
    return 0
  fi
  local carried; carried="$(state_get destination_carried_backup)"
  if (( rc == 1 )) && [[ -n "$carried" ]]; then
    print -rn -- "$carried"
    return 3
  fi
  return $rc
}

# --- reaching the appliance for administration ------------------------------

# appliance_host - where ssh should go to administer the appliance
#
# With a VPN transport, through the VPN when it is up. That is what makes the
# address change a non-event for status, doctor, limit and unlock as well as for
# backups: the public firewall still admits only one address, but nothing needs
# it while the tunnel works. Falls back to the public address, which is also
# what every ssh-transport installation uses.
appliance_host() {
  local public; public="$(state_get server_ip)"
  local kind; kind="$(transport_kind)"
  if [[ "$kind" != ssh ]]; then
    local inner; inner="$(transport_smb_host "$kind")"
    if [[ -n "$inner" ]] && nc -z -G 3 -w 3 "$inner" 22 >/dev/null 2>&1; then
      print -rn -- "$inner"
      return 0
    fi
  fi
  print -rn -- "$public"
}
