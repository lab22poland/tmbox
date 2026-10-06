#!/bin/zsh
#
# tmbox firewall - who may reach the appliance's SSH (#22).
#
#   tmbox firewall        what Hetzner's firewall admits right now
#   tmbox firewall any    SSH from any address; only tmbox's keys can log in
#   tmbox firewall pin    SSH from this connection's address only (the default)
#
# The pin is the right default and the wrong one for a Mac whose address keeps
# changing: on a phone's hotspot or an LTE line every change locks the Mac out
# until `tmbox doctor --fix` re-pins it, and with the SSH transport the backups
# stop in the meantime. What "any" exposes is an sshd that takes no passwords
# and two keys, one of which can open a single forward to Samba and nothing
# else. SMB itself stays closed to the internet either way.

cmd_firewall() {
  local arg="${1:-}"
  (( $# <= 1 )) || ui_die "tmbox firewall takes one value: any or pin."

  http_init || ui_die "Could not create a private temporary directory."
  ui_banner "tmbox firewall" "Who may reach the appliance's SSH"

  local fw; fw="$(state_get firewall_id)"
  if [[ -z "$fw" ]]; then
    ui_bad "This Mac has no firewall recorded."
    ui_say "Run 'tmbox setup' first."
    return 3
  fi

  local token; token="$(kc_get hetzner-token 2>/dev/null)" || token=""
  if [[ -z "$token" ]]; then
    ui_bad "No Hetzner API token on this Mac, so the firewall cannot be read or changed."
    return 3
  fi
  TMBOX_HCLOUD_TOKEN="$token"

  case "$arg" in
    "")  firewall_report "$fw" ;;
    any) firewall_set "$fw" any ;;
    pin) firewall_pin "$fw" ;;
    *)   ui_bad "'${arg}' is not something tmbox firewall understands."
         ui_say "Use: tmbox firewall any, or tmbox firewall pin."
         return 2 ;;
  esac
}

# firewall_report <firewall-id> - the rules as Hetzner has them
#
# Read from the API rather than from the state file, because the console can
# change them and the state file would not know.
firewall_report() {
  local fw="$1"
  if ! hc GET "/firewalls/${fw}"; then
    ui_bad "Hetzner did not return the firewall (${HTTP_STATUS})."
    return 4
  fi
  local rule
  for rule in ${(f)"$(json_get '.firewall.rules[] | "\(.protocol)\(if .port then "/" + .port else "" end) from \(.source_ips | join(", "))"' "$HTTP_BODY")"}; do
    ui_item "$rule"
  done
  ui_blank
  if [[ "$(state_get admin_cidr)" == any ]]; then
    ui_say "SSH is open to any address; only tmbox's own keys can log in. tmbox firewall pin limits it to this connection again."
  else
    ui_say "SSH is limited to one address. If this Mac's address keeps changing - a phone's hotspot, LTE - tmbox firewall any stops that locking you out."
  fi
  return 0
}

# firewall_pin <firewall-id> - this connection's address, freshly detected
firewall_pin() {
  local fw="$1" ip
  ui_spin_start "Detecting this connection's public address"
  if ! ip="$(public_ipv4)"; then
    ui_spin_stop bad "Could not determine this connection's public address"
    ui_say "Nothing was changed."
    return 1
  fi
  ui_spin_stop ok "This connection appears as ${ip}"
  firewall_set "$fw" "${ip}/32"
}

# firewall_set <firewall-id> <cidr|any>
#
# The transport's UDP port goes in with every change: the rules are replaced as
# a whole, and leaving it out would close the tunnel the backups travel through.
firewall_set() {
  local fw="$1" cidr="$2"
  ui_spin_start "Updating the firewall"
  if ! hc_firewall_set_admin_cidr "$fw" "$cidr" "$(transport_udp_port)" >/dev/null 2>&1; then
    ui_spin_stop bad "Hetzner refused the update (${HTTP_STATUS:-no answer})"
    ui_say "The full exchange is in ${TMBOX_LOG_FILE}. Nothing was changed."
    return 1
  fi
  state_set admin_cidr "$cidr"
  if [[ "$cidr" == any ]]; then
    ui_spin_stop ok "SSH is now open to any address; only tmbox's keys can log in"
  else
    ui_spin_stop ok "SSH is now limited to ${cidr%/32}"
  fi
  return 0
}
