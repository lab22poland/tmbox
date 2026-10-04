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
#   eth0 ingress ──tcp dport 22──► ifb-tm ──► cake bandwidth N ingress
#
# Shaping below the line's own rate moves the queue from the modem to this
# shaper, and CAKE's drops tell the sender's TCP to slow down. The Mac keeps an
# untouched pf, and the limit holds whichever network the Mac is on. Only TCP
# to port 22 is redirected: the tunnel arrives that way, and the appliance's own
# traffic with the Storage Box (CIFS, from tcp/445) must never be slowed.
#
# The kernel of the Debian 13 cloud image ships sch_cake, ifb, act_mirred and
# cls_flower as modules, so nothing is installed. Checked on 6.12.x+deb13-arm64.
#
#   tmbox-shape set <kbit|off>   record the limit, enable the unit, apply it
#   tmbox-shape apply            apply what is recorded (the unit runs this)
#   tmbox-shape clear            remove the shaping, keep the record
#   tmbox-shape show             configured=<kbit|off> active=<kbit|off> dropped=<n>
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

configured() {
  local v=""
  [ -r "$CONF" ] && v="$(sed -n 's/^RATE_KBIT=//p' "$CONF" | head -1)"
  printf '%s' "${v:-off}"
}

valid_kbit() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 500 ] && [ "$1" -le 10000000 ]
}

clear_shaping() {
  local dev; dev="$(wan_dev)"
  if [ -n "$dev" ]; then
    # The whole ingress qdisc rather than just this script's filters: nothing
    # else on the appliance uses ingress, and a hand-made filter left over from
    # testing would otherwise survive every apply.
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
  fi
  ip link del "$IFB" 2>/dev/null || true
}

apply_shaping() {
  local kbit; kbit="$(configured)"
  clear_shaping
  [ "$kbit" = "off" ] && return 0
  valid_kbit "$kbit" || die "invalid rate in $CONF: $kbit"

  local dev; dev="$(wan_dev)"
  [ -n "$dev" ] || die "no default route, so no interface to shape"

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
    flower ip_proto tcp dst_port 22 action mirred egress redirect dev "$IFB"
  tc filter add dev "$dev" parent ffff: pref "$PREF6" protocol ipv6 \
    flower ip_proto tcp dst_port 22 action mirred egress redirect dev "$IFB"
}

install_unit() {
  [ -f "$UNIT" ] && return 0
  cat > "$UNIT" <<'EOF'
[Unit]
Description=tmbox - limit how much of the owner's upload backups take
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/local/sbin/tmbox-shape apply
ExecStop=/usr/local/sbin/tmbox-shape clear

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# What is actually in the kernel, not what the file says: the two can differ
# after a failed apply, and that difference is what doctor looks for.
show() {
  local dev active="off" dropped=0 line
  dev="$(wan_dev)"
  if [ -n "$dev" ] && tc filter show dev "$dev" parent ffff: 2>/dev/null | grep -qi "redirect to device $IFB"; then
    line="$(tc -s qdisc show dev "$IFB" 2>/dev/null || true)"
    active="$(printf '%s\n' "$line" | sed -n 's/.* bandwidth \([0-9][0-9]*\)\([KMG]*\)bit.*/\1 \2/p' | head -1 \
      | awk '{ m = 1; if ($2 == "Mbit" || $2 == "M") m = 1000; else if ($2 == "Gbit" || $2 == "G") m = 1000000; print $1 * m }')"
    dropped="$(printf '%s\n' "$line" | sed -n 's/.*(dropped \([0-9]*\),.*/\1/p' | head -1)"
  fi
  printf 'configured=%s active=%s dropped=%s\n' "$(configured)" "${active:-off}" "${dropped:-0}"
}

[ "$(id -u)" -eq 0 ] || die "must run as root"

case "${1:-}" in
  set)
    rate="${2:-}"
    if [ "$rate" != "off" ]; then
      valid_kbit "$rate" || die "rate must be off or 500-10000000 kbit/s, not '$rate'"
    fi
    mkdir -p "$(dirname "$CONF")"
    printf 'RATE_KBIT=%s\n' "$rate" > "$CONF"
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
  apply) apply_shaping ;;
  clear) clear_shaping ;;
  show)  show ;;
  *)     die "usage: tmbox-shape set <kbit|off> | apply | clear | show" ;;
esac
