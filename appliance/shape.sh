#!/bin/bash
#
# tmbox-shape - limit how much of the owner's upload a backup may take (#20).
#
# Time Machine, Samba and ssh have no bandwidth setting between them, so a
# backup over the tunnel takes the whole upload of the line it runs on. On a
# line with a deep buffer in the modem - LTE and 5G especially - that is
# bufferbloat: measured on a real installation, ping went from ~40 ms to an
# average of 368 ms and the router logged the internet as down five times in
# fifteen minutes.
#
# The limit is applied here, on the receiving end, rather than on the Mac:
#
#   <dev> ingress ──<proto> dport <port>──► ifb-tm ──► cake bandwidth N ingress
#
# Shaping below the line's own rate moves the queue from the modem to this
# shaper, and CAKE's drops tell the sender's TCP to slow down. The Mac keeps an
# untouched pf, and the limit holds whichever network the Mac is on.
#
# What is matched depends on how the backups arrive (#22), and is recorded as
# MATCH by `tmbox-shape match`:
#
#   wan tcp 22           the SSH tunnel (the default, and all there was before)
#   wan udp 51820        WireGuard: the tunnel's own packets, before decryption
#   tailscale0 tcp 445   Tailscale: after decryption, because its packets come
#                        either directly on udp/41641 or relayed over a TCP
#                        connection the appliance opened itself
#
# Only that is redirected: the appliance's own traffic with the Storage Box
# (CIFS, to tcp/445 on the box, out of the WAN interface) must never be slowed.
#
# The kernel of the Debian 13 cloud image ships sch_cake, ifb, act_mirred and
# cls_flower as modules, so nothing is installed. Checked on 6.12.x+deb13-arm64,
# on eth0 and, for #22, on a WireGuard interface's ingress as well.
#
#   tmbox-shape set <kbit|off>             record the limit, enable the unit, apply it
#   tmbox-shape match <dev|wan> <tcp|udp> <port>
#                                          record what to match; re-apply if limited
#   tmbox-shape apply                      apply what is recorded (the unit runs this)
#   tmbox-shape clear                      remove the shaping, keep the record
#   tmbox-shape show                       configured=<kbit|off> active=<kbit|off>
#                                          dropped=<n> match=<dev>/<proto>/<port>
#
# The Mac installs this file on every change, so an appliance built before it
# existed gets it from `tmbox limit` without being rebuilt.
#
# Copyright (c) 2026, Lab22 Poland Sp. z o.o.  BSD-3-Clause.

set -euo pipefail

CONF=/etc/tmbox/uplink
UNIT=/etc/systemd/system/tmbox-shape.service
IFB=ifb-tm
# Filter priorities this script owns, so clearing never touches anything else.
PREF4=49
PREF6=50

die() { printf 'tmbox-shape: %s\n' "$*" >&2; exit 1; }

# The interface the default route leaves by. eth0 on every Hetzner Cloud image
# so far, but read rather than assumed.
wan_dev() {
  ip -o route show default 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

conf_get() {
  local v=""
  [ -r "$CONF" ] && v="$(sed -n "s/^$1=//p" "$CONF" | head -1)"
  printf '%s' "$v"
}

configured() {
  local v; v="$(conf_get RATE_KBIT)"
  printf '%s' "${v:-off}"
}

# match_spec - "<dev|wan> <proto> <port>"; the SSH tunnel's when none is
# recorded, which is every appliance from before #22.
match_spec() {
  local v; v="$(conf_get MATCH)"
  v="${v#\"}"; v="${v%\"}"
  printf '%s' "${v:-wan tcp 22}"
}

match_field() { match_spec | awk -v n="$1" '{ print $n }'; }

# match_dev - the interface to shape, with "wan" resolved
match_dev() {
  local d; d="$(match_field 1)"
  if [ "$d" = "wan" ]; then wan_dev; else printf '%s' "$d"; fi
}

valid_kbit() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 500 ] && [ "$1" -le 10000000 ]
}

valid_match() {
  case "$1" in ''|*[!a-z0-9]*) return 1 ;; esac
  case "$2" in tcp|udp) ;; *) return 1 ;; esac
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
  [ "$3" -ge 1 ] && [ "$3" -le 65535 ]
}

# conf_write <rate> <match> - the whole file, so neither value can go stale
conf_write() {
  mkdir -p "$(dirname "$CONF")"
  printf 'RATE_KBIT=%s\nMATCH="%s"\n' "$1" "$2" > "$CONF"
}

clear_shaping() {
  local dev
  # The WAN interface and the matched one, which differ for Tailscale: after a
  # change of transport the old one still carries the old filter.
  for dev in "$(wan_dev)" "$(match_dev)"; do
    [ -n "$dev" ] || continue
    # The whole ingress qdisc rather than just this script's filters: nothing
    # else on the appliance uses ingress, and a hand-made filter left over from
    # testing would otherwise survive every apply.
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
  done
  ip link del "$IFB" 2>/dev/null || true
}

apply_shaping() {
  local kbit; kbit="$(configured)"
  clear_shaping
  [ "$kbit" = "off" ] && return 0
  valid_kbit "$kbit" || die "invalid rate in $CONF: $kbit"

  local dev proto port
  dev="$(match_dev)"
  proto="$(match_field 2)"
  port="$(match_field 3)"
  [ -n "$dev" ] || die "no default route, so no interface to shape"
  valid_match "$dev" "$proto" "$port" || die "invalid MATCH in $CONF: $(match_spec)"

  # tailscale0 is created by tailscaled, which may still be starting when this
  # runs at boot. Waited for rather than failed on: the unit is ordered after
  # tailscaled, but the interface appears a moment after the service does.
  local i=0
  while ! ip link show dev "$dev" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 60 ] || die "$dev did not appear within a minute"
    sleep 1
  done

  # numifbs=0: without it, loading the module creates ifb0 and ifb1 as well.
  modprobe ifb numifbs=0
  modprobe sch_cake
  modprobe act_mirred
  modprobe cls_flower

  ip link add "$IFB" type ifb
  ip link set "$IFB" up
  # besteffort: there is one flow worth shaping and nothing to prioritise.
  # ingress: count what CAKE drops against the rate too, which is right when
  # the shaper sits after the bottleneck rather than before it.
  tc qdisc add dev "$IFB" root cake bandwidth "${kbit}kbit" besteffort ingress

  tc qdisc add dev "$dev" handle ffff: ingress
  tc filter add dev "$dev" parent ffff: pref "$PREF4" protocol ip \
    flower ip_proto "$proto" dst_port "$port" action mirred egress redirect dev "$IFB"
  tc filter add dev "$dev" parent ffff: pref "$PREF6" protocol ipv6 \
    flower ip_proto "$proto" dst_port "$port" action mirred egress redirect dev "$IFB"
}

# install_unit - written every time, and reloaded only when it changed
#
# It depends on what is matched. Shaping tailscale0 has to follow tailscaled:
# when that restarts, the interface is created anew without its ingress qdisc,
# so PartOf restarts this unit along with it.
install_unit() {
  local after="network-online.target" partof=""
  if [ "$(match_field 1)" = "tailscale0" ]; then
    after="network-online.target tailscaled.service"
    partof="PartOf=tailscaled.service"
  fi
  local new
  new="[Unit]
Description=tmbox - limit how much of the owner's upload backups take
After=${after}
Wants=network-online.target
${partof}

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/local/sbin/tmbox-shape apply
ExecStop=/usr/local/sbin/tmbox-shape clear

[Install]
WantedBy=multi-user.target"
  if [ -f "$UNIT" ] && [ "$(cat "$UNIT")" = "$new" ]; then
    return 0
  fi
  printf '%s\n' "$new" > "$UNIT"
  systemctl daemon-reload
}

# What is actually in the kernel, not what the file says: the two can differ
# after a failed apply, and that difference is what doctor looks for.
show() {
  local dev active="off" dropped=0 line
  dev="$(match_dev)"
  if [ -n "$dev" ] && tc filter show dev "$dev" parent ffff: 2>/dev/null | grep -qi "redirect to device $IFB"; then
    line="$(tc -s qdisc show dev "$IFB" 2>/dev/null || true)"
    active="$(printf '%s\n' "$line" | sed -n 's/.* bandwidth \([0-9][0-9]*\)\([KMG]*\)bit.*/\1 \2/p' | head -1 \
      | awk '{ m = 1; if ($2 == "Mbit" || $2 == "M") m = 1000; else if ($2 == "Gbit" || $2 == "G") m = 1000000; print $1 * m }')"
    dropped="$(printf '%s\n' "$line" | sed -n 's/.*(dropped \([0-9]*\),.*/\1/p' | head -1)"
  fi
  printf 'configured=%s active=%s dropped=%s match=%s\n' "$(configured)" "${active:-off}" "${dropped:-0}" \
    "$(match_spec | tr ' ' '/')"
}

[ "$(id -u)" -eq 0 ] || die "must run as root"

case "${1:-}" in
  set)
    rate="${2:-}"
    if [ "$rate" != "off" ]; then
      valid_kbit "$rate" || die "rate must be off or 500-10000000 kbit/s, not '$rate'"
    fi
    conf_write "$rate" "$(match_spec)"
    install_unit
    if [ "$rate" = "off" ]; then
      systemctl disable --now tmbox-shape.service >/dev/null 2>&1 || true
      clear_shaping
    else
      systemctl enable tmbox-shape.service >/dev/null 2>&1
      # restart rather than start: the unit is RemainAfterExit, so a start
      # while it is already active would do nothing and keep the old rate.
      systemctl restart tmbox-shape.service
    fi
    show
    ;;
  match)
    valid_match "${2:-}" "${3:-}" "${4:-}" \
      || die "match takes <interface|wan> <tcp|udp> <port>, not '${2:-} ${3:-} ${4:-}'"
    # The old interface is cleared before the record changes, while it is
    # still known which one it was.
    clear_shaping
    conf_write "$(configured)" "$2 $3 $4"
    install_unit
    if [ "$(configured)" != "off" ]; then
      systemctl restart tmbox-shape.service
    fi
    show
    ;;
  apply) apply_shaping ;;
  clear) clear_shaping ;;
  show)  show ;;
  *)     die "usage: tmbox-shape set <kbit|off> | match <dev|wan> <tcp|udp> <port> | apply | clear | show" ;;
esac
