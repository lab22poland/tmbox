#!/bin/bash
#
# tmbox-transport - the appliance's half of a VPN transport (#22).
#
# The SSH tunnel needs nothing here beyond the restricted account the bootstrap
# creates, and that account stays whatever else is chosen: it is the restore
# path from macOS Recovery. WireGuard and Tailscale need an interface, a
# service that brings it up at boot, and a guard on what may come in through it.
#
#   tmbox-transport wireguard-keygen
#       a fresh private key and its public key, one per line. Nothing is
#       written: this is the Mac's key, made here because a stock Mac has no
#       `wg` until WireGuard is installed, and it leaves only in the reply.
#   tmbox-transport wireguard-up <peer-pubkey> <addr> <peer-addr> <port>
#       install wireguard-tools, keep (or make) the appliance's own key, write
#       wg0, start it at boot, guard it; prints pubkey=<appliance public key>
#   tmbox-transport wireguard-down
#   tmbox-transport tailscale-install
#   tmbox-transport tailscale-up <hostname>   (the auth key arrives on stdin)
#   tmbox-transport tailscale-guard <peer-addr>
#   tmbox-transport tailscale-down
#   tmbox-transport show
#       transport=<none|wireguard|tailscale> up=<yes|no> guard=<on|off>
#       handshake=<seconds ago|never> ts_ip=<addr|-> ts_expiry=<time|->
#
# **The guard.** A VPN interface reaches the whole appliance, where the SSH
# forward reached one port. So an nftables table of tmbox's own admits, on the
# VPN interface and from the one peer address only, Samba (445), SSH (22, the
# administration path that has to keep working when the Mac's public address
# has moved) and ping, and drops everything else. It is a separate table:
# Tailscale manages rules of its own, and an accept there does not undo a drop
# here - each base chain decides, and a packet must pass all of them.
#
# The Mac sends this script on every change, so an appliance built before it
# existed gets it without being rebuilt.
#
# Copyright (c) 2026, Lab22 Poland Sp. z o.o.  BSD-3-Clause.

set -euo pipefail

WG_IF=wg0
WG_CONF=/etc/wireguard/${WG_IF}.conf
WG_KEY=/etc/wireguard/tmbox.key
TS_IF=tailscale0
GUARD=/etc/tmbox/guard.nft
GUARD_UNIT=/etc/systemd/system/tmbox-guard.service
APT_OPTS="-o DPkg::Lock::Timeout=300"

die() { printf 'tmbox-transport: %s\n' "$*" >&2; exit 1; }

valid_addr() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
valid_key()  { [[ "$1" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; }

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get $APT_OPTS install -y -qq "$@" >/dev/null
}

# --- the guard --------------------------------------------------------------

# guard_write <interface> <peer-addr>
#
# Loaded by its own unit, ordered before the interface's service, so there is
# no moment at boot when the interface is up and the guard is not. The table
# matches the interface by name, which works before the interface exists.
guard_write() {
  local dev="$1" peer="$2"
  mkdir -p /etc/tmbox
  cat > "$GUARD" <<EOF
# Written by tmbox-transport. What may reach the appliance through ${dev}.
table inet tmbox_guard
delete table inet tmbox_guard
table inet tmbox_guard {
  chain input {
    type filter hook input priority filter - 10; policy accept;
    iifname "${dev}" ct state established,related accept
    iifname "${dev}" ip saddr != ${peer} drop
    iifname "${dev}" tcp dport { 22, 445 } accept
    iifname "${dev}" icmp type echo-request accept
    iifname "${dev}" drop
  }
}
EOF
  cat > "$GUARD_UNIT" <<'EOF'
[Unit]
Description=tmbox - what may reach the appliance through the VPN
After=nftables.service
Before=wg-quick@wg0.service tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/sbin/nft -f /etc/tmbox/guard.nft
ExecStop=-/usr/sbin/nft delete table inet tmbox_guard

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable tmbox-guard.service >/dev/null 2>&1
  systemctl restart tmbox-guard.service
}

guard_remove() {
  systemctl disable --now tmbox-guard.service >/dev/null 2>&1 || true
  nft delete table inet tmbox_guard 2>/dev/null || true
  rm -f "$GUARD" "$GUARD_UNIT"
  systemctl daemon-reload
}

guard_on() { nft list table inet tmbox_guard >/dev/null 2>&1; }

# --- WireGuard --------------------------------------------------------------

wireguard_keygen() {
  command -v wg >/dev/null 2>&1 || apt_install wireguard-tools
  local key; key="$(wg genkey)"
  printf '%s\n%s\n' "$key" "$(printf '%s' "$key" | wg pubkey)"
}

wireguard_up() {
  local peer="${1:-}" addr="${2:-}" peer_addr="${3:-}" port="${4:-}"
  valid_key "$peer"       || die "not a WireGuard public key: '$peer'"
  valid_addr "$addr"      || die "not an address: '$addr'"
  valid_addr "$peer_addr" || die "not an address: '$peer_addr'"
  [[ "$port" =~ ^[0-9]+$ ]] || die "not a port: '$port'"

  command -v wg >/dev/null 2>&1 || apt_install wireguard-tools

  # The appliance's own key is kept across runs, so re-running this - or
  # changing the Mac's key - does not invalidate the copy the Mac holds.
  umask 077
  mkdir -p /etc/wireguard
  [ -s "$WG_KEY" ] || wg genkey > "$WG_KEY"

  local new
  new="# Written by tmbox-transport.
[Interface]
Address = ${addr}/24
ListenPort = ${port}
PrivateKey = $(cat "$WG_KEY")

[Peer]
PublicKey = ${peer}
AllowedIPs = ${peer_addr}/32"

  local changed=1
  if [ -f "$WG_CONF" ] && [ "$(cat "$WG_CONF")" = "$new" ]; then changed=0; fi
  printf '%s\n' "$new" > "$WG_CONF"

  # Guard first: there must be no moment with wg0 up and nothing in front of it.
  guard_write "$WG_IF" "$peer_addr"

  systemctl enable wg-quick@${WG_IF}.service >/dev/null 2>&1
  if [ "$changed" = 1 ] || ! systemctl is-active --quiet wg-quick@${WG_IF}.service; then
    systemctl restart wg-quick@${WG_IF}.service
  fi
  systemctl is-active --quiet wg-quick@${WG_IF}.service || die "wg-quick@${WG_IF} did not start"

  printf 'pubkey=%s\n' "$(wg pubkey < "$WG_KEY")"
}

wireguard_down() {
  systemctl disable --now wg-quick@${WG_IF}.service >/dev/null 2>&1 || true
  rm -f "$WG_CONF" "$WG_KEY"
  [ "$(guard_dev)" = "$WG_IF" ] && guard_remove
  return 0
}

# --- Tailscale --------------------------------------------------------------

# From Tailscale's own repository for Debian 13, signed with the key it
# publishes next to it. Only if it is not there already.
tailscale_install() {
  if command -v tailscale >/dev/null 2>&1; then
    systemctl enable --now tailscaled >/dev/null 2>&1
    return 0
  fi
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
    -o /etc/apt/sources.list.d/tailscale.list
  export DEBIAN_FRONTEND=noninteractive
  apt-get $APT_OPTS update -qq
  apt_install tailscale
  systemctl enable --now tailscaled >/dev/null 2>&1
}

# tailscale_up <hostname> - the auth key on stdin, into a file only root can
# read, handed over as file: so it never appears in a process list, and removed
# whatever happens.
tailscale_up() {
  local host="${1:-}"
  [[ "$host" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "not a hostname: '$host'"
  command -v tailscale >/dev/null 2>&1 || die "tailscale is not installed"

  local keyfile
  keyfile="$(mktemp /run/tmbox-ts.XXXXXX)"
  trap 'rm -f "$keyfile"' EXIT
  chmod 0600 "$keyfile"
  cat > "$keyfile"
  [ -s "$keyfile" ] || die "no auth key on stdin"

  # --accept-dns=false: the appliance resolves through Hetzner, and a tailnet's
  # DNS settings are the owner's business, not a server's. --reset so that a
  # second run with different settings replaces the first instead of failing.
  tailscale up --reset --auth-key="file:${keyfile}" --hostname="$host" \
    --accept-dns=false --accept-routes=false --timeout=60s >/dev/null
  rm -f "$keyfile"

  tailscale ip -4 | head -1
}

tailscale_down() {
  if command -v tailscale >/dev/null 2>&1; then
    tailscale logout >/dev/null 2>&1 || true
    systemctl disable --now tailscaled >/dev/null 2>&1 || true
  fi
  [ "$(guard_dev)" = "$TS_IF" ] && guard_remove
  return 0
}

# --- report -----------------------------------------------------------------

guard_dev() {
  [ -r "$GUARD" ] || return 0
  sed -n 's/.*iifname "\([a-z0-9]*\)" drop$/\1/p' "$GUARD" | head -1
}

show() {
  local kind=none up=no guard=off hs=never ts_ip=- ts_exp=-
  if systemctl is-enabled --quiet wg-quick@${WG_IF}.service 2>/dev/null; then
    kind=wireguard
    ip link show dev "$WG_IF" >/dev/null 2>&1 && up=yes
    local last
    last="$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '{print $2; exit}' || true)"
    if [ -n "$last" ] && [ "$last" != 0 ]; then hs=$(( $(date +%s) - last )); fi
  elif command -v tailscale >/dev/null 2>&1 && systemctl is-active --quiet tailscaled 2>/dev/null; then
    # Logged out, `tailscale ip` fails - and under set -e that failure would
    # end the report with nothing printed at all.
    ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    if [ -n "$ts_ip" ]; then kind=tailscale; up=yes; else ts_ip=-; fi
    # Absent when key expiry is disabled, as it is for tagged machines.
    ts_exp="$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // "-"' 2>/dev/null || true)"
    [ -n "$ts_exp" ] || ts_exp=-
  fi
  guard_on && guard=on
  printf 'transport=%s up=%s guard=%s handshake=%s ts_ip=%s ts_expiry=%s\n' "$kind" "$up" "$guard" "$hs" "$ts_ip" "$ts_exp"
}

[ "$(id -u)" -eq 0 ] || die "must run as root"

case "${1:-}" in
  wireguard-keygen)  wireguard_keygen ;;
  wireguard-up)      shift; wireguard_up "$@" ;;
  wireguard-down)    wireguard_down ;;
  tailscale-install) tailscale_install ;;
  tailscale-up)      shift; tailscale_up "$@" ;;
  tailscale-guard)   valid_addr "${2:-}" || die "not an address: '${2:-}'"; guard_write "$TS_IF" "$2" ;;
  tailscale-down)    tailscale_down ;;
  show)              show ;;
  *) die "usage: tmbox-transport wireguard-keygen | wireguard-up <peer-pubkey> <addr> <peer-addr> <port> | wireguard-down | tailscale-install | tailscale-up <hostname> | tailscale-guard <peer-addr> | tailscale-down | show" ;;
esac
