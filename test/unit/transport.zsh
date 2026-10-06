#!/bin/zsh
#
# lib/transport.zsh, the firewall it shapes, and the commands that change it
# (#22).
#
# The transport decides three things that have to agree with each other: the
# address in Time Machine's URL, the UDP port the firewall lets in, and what
# the upload limit matches on the appliance. A mismatch between any two is a
# backup path that is silently closed, so each is checked here per transport.
# Hetzner and the network are replaced by functions; the state file is the
# real one, in the runner's scratch directory.

source "$TMBOX_ROOT/lib/answers.zsh"
source "$TMBOX_ROOT/lib/log.zsh"
source "$TMBOX_ROOT/lib/ui.zsh"
source "$TMBOX_ROOT/lib/json.zsh"
source "$TMBOX_ROOT/lib/state.zsh"
source "$TMBOX_ROOT/lib/secrets.zsh"
source "$TMBOX_ROOT/lib/sshx.zsh"
source "$TMBOX_ROOT/lib/macos.zsh"
source "$TMBOX_ROOT/lib/transport.zsh"
source "$TMBOX_ROOT/lib/http.zsh"
source "$TMBOX_ROOT/lib/hcloud.zsh"
source "$TMBOX_ROOT/lib/hbox.zsh"
source "$TMBOX_ROOT/lib/preflight.zsh"
source "$TMBOX_ROOT/lib/uplink.zsh"
source "$TMBOX_ROOT/cmd/tunnel.zsh"
source "$TMBOX_ROOT/cmd/setup.zsh"
source "$TMBOX_ROOT/cmd/status.zsh"
source "$TMBOX_ROOT/cmd/doctor.zsh"
source "$TMBOX_ROOT/cmd/firewall.zsh"

ui_init --no-tty-ok
typeset -g UI_LOG="$TMBOX_STATE_DIR/ui.out"

_fresh() {
  rm -rf -- "$TMBOX_STATE_DIR"
  state_init >/dev/null 2>&1
  kc_init
  : > "$UI_LOG"
  exec {TMBOX_UI_FD}>>"$UI_LOG"
  TMBOX_ANS=(); TMBOX_ANSSRC=()
  DOCTOR_FAILED=0; DOCTOR_WARNED=0; DOCTOR_FIX=0
}

# --- what each transport means ----------------------------------------------

test_an_installation_from_before_022_is_ssh() {
  _fresh
  assert_eq ssh "$(transport_kind)" "no transport recorded means the SSH tunnel"
  assert_eq "smb://tmuser@127.0.0.2/tm-studio" "$(transport_url tm-studio)"
  assert_empty "$(transport_udp_port)" "the SSH tunnel needs no UDP port"
}

test_each_transport_has_its_own_address_and_port() {
  _fresh
  state_set transport wireguard >/dev/null 2>&1
  assert_eq "smb://tmuser@10.209.77.1/tm-studio" "$(transport_url tm-studio)"
  assert_eq 51820 "$(transport_udp_port)"

  state_set transport tailscale tailscale_ip 100.101.102.103 >/dev/null 2>&1
  assert_eq "smb://tmuser@100.101.102.103/tm-studio" "$(transport_url tm-studio)"
  assert_eq 41641 "$(transport_udp_port)"
}

test_only_known_transports_are_valid() {
  local t
  for t in ssh wireguard tailscale; do assert_status 0 transport_valid "$t"; done
  assert_status 1 transport_valid ipsec
  assert_status 1 transport_valid ""
}

test_the_wireguard_addresses_avoid_the_usual_networks() {
  # 10.0.x is Hetzner's private networks and most routers, 192.168 is every
  # home, 172.16-31 is Docker, 100.64/10 is Tailscale and carrier NAT.
  [[ "$TMBOX_WG_APPLIANCE" == (10.0.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.*) ]] \
    && fail "the WireGuard address $TMBOX_WG_APPLIANCE collides with a common network"
  assert_ne "$TMBOX_WG_APPLIANCE" "$TMBOX_WG_MAC"
}

test_administration_uses_the_public_address_for_ssh() {
  _fresh
  state_set server_ip 203.0.113.9 >/dev/null 2>&1
  assert_eq 203.0.113.9 "$(appliance_host)"
}

test_administration_goes_through_the_vpn_when_it_answers() {
  _fresh
  state_set server_ip 203.0.113.9 transport wireguard >/dev/null 2>&1
  local got
  got="$(nc() { return 0 }; appliance_host)"
  assert_eq "$TMBOX_WG_APPLIANCE" "$got" "through the tunnel while it works"
  got="$(nc() { return 1 }; appliance_host)"
  assert_eq 203.0.113.9 "$got" "the public address when it does not"
}

# --- the firewall -----------------------------------------------------------

test_a_pinned_firewall_admits_one_address_and_no_smb() {
  local rules; rules="$(hc_firewall_rules 198.51.100.7/32)"
  assert_eq '["198.51.100.7/32"]' "$(print -r -- "$rules" | jq -c '[.[] | select(.port == "22") | .source_ips[]]')"
  assert_eq 2 "$(print -r -- "$rules" | jq 'length')" "ssh and icmp, nothing else"
  assert_eq 0 "$(print -r -- "$rules" | jq '[.[] | select(.port == "445" or .port == "139")] | length')"
}

test_any_opens_ssh_to_every_address_and_still_no_smb() {
  local rules; rules="$(hc_firewall_rules any)"
  assert_eq '["0.0.0.0/0","::/0"]' "$(print -r -- "$rules" | jq -c '[.[] | select(.port == "22") | .source_ips[]]')"
  assert_eq 0 "$(print -r -- "$rules" | jq '[.[] | select(.port == "445" or .port == "139")] | length')"
}

test_a_vpn_transport_adds_its_udp_port_and_only_that() {
  local rules; rules="$(hc_firewall_rules 198.51.100.7/32 51820)"
  assert_eq 3 "$(print -r -- "$rules" | jq 'length')"
  assert_eq '["udp/51820"]' "$(print -r -- "$rules" | jq -c '[.[] | select(.protocol == "udp") | "\(.protocol)/\(.port)"]')"
  # The pinned address still applies to ssh; the tunnel port is open to all,
  # because it is the one that has to work from wherever the Mac is.
  assert_eq '["198.51.100.7/32"]' "$(print -r -- "$rules" | jq -c '[.[] | select(.port == "22") | .source_ips[]]')"
}

test_re_pinning_keeps_the_transports_port() {
  # The rules are replaced as a whole. A re-pin that forgot the port would
  # close the tunnel the backups travel through.
  _fresh
  state_set firewall_id 77 admin_cidr 198.51.100.1/32 transport wireguard >/dev/null 2>&1
  local calls
  calls="$(
    public_ipv4() { print -rn -- 198.51.100.2 }
    hc_firewall_set_admin_cidr() { print -rn -- "$*" }
    setup_follow_address 2>/dev/null
  )"
  assert_eq "77 198.51.100.2/32 51820" "$calls"
}

test_an_open_firewall_is_never_re_pinned() {
  _fresh
  state_set firewall_id 77 admin_cidr any >/dev/null 2>&1
  local calls
  calls="$(
    public_ipv4() { print -rn -- 198.51.100.2 }
    hc_firewall_set_admin_cidr() { print -rn -- "CALLED" }
    setup_follow_address 2>/dev/null
  )"
  assert_empty "$calls"
}

test_setup_creates_an_open_firewall_when_asked() {
  _fresh
  ans_set admin-cidr any
  local calls
  calls="$(
    public_ipv4() { print -rn -- "DETECTED" }
    hc_firewall_create() { print -rn -- "$2|${3:-}" >&2; print -rn -- 42 }
    setup_provision_fw tmbox-test 2>&1 >/dev/null
  )"
  assert_contains "$calls" "any|" "created open, with no tunnel port for ssh"
  assert_not_contains "$calls" "DETECTED" "and without asking where this Mac is"
  assert_eq any "$(state_get admin_cidr)"
  assert_eq 42 "$(state_get firewall_id)"
}

test_the_admin_choice_refuses_what_it_cannot_mean() {
  _fresh
  local got
  ans_set admin-cidr ANY;  assert_eq any "$(setup_admin_choice)"
  ans_set admin-cidr auto; assert_eq pin "$(setup_admin_choice)"
  TMBOX_ANS=(); assert_eq pin "$(setup_admin_choice)" "the default is the pin"
  ans_set admin-cidr 0.0.0.0/0
  got="$(setup_admin_choice 2>/dev/null)"; assert_status 1 test -n "$got"
}

test_firewall_set_sends_the_transports_port() {
  _fresh
  state_set transport tailscale >/dev/null 2>&1
  # Into a file: firewall_set silences the call's own output.
  local log="${TMBOX_STATE_DIR}/calls"
  ( hc_firewall_set_admin_cidr() { print -rn -- "$*" > "$log" }
    firewall_set 77 any >/dev/null 2>&1 )
  assert_eq "77 any 41641" "$(cat -- "$log")"
  assert_eq any "$(state_get admin_cidr)"
}

# --- doctor -----------------------------------------------------------------

test_doctor_passes_an_open_firewall_without_looking_up_the_address() {
  _fresh
  state_set admin_cidr any >/dev/null 2>&1
  local out
  out="$(public_ipv4() { print -rn -- "LOOKED" }; doctor_check_reachability 2>&1; print -rn -- " failed=$DOCTOR_FAILED")"
  assert_contains "$(cat "$UI_LOG")" "any address"
  assert_not_contains "$out" "LOOKED"
  assert_contains "$out" "failed=0"
}

test_doctor_only_warns_about_a_moved_address_when_backups_use_a_vpn() {
  _fresh
  state_set admin_cidr 198.51.100.1/32 transport wireguard >/dev/null 2>&1
  local out
  out="$(public_ipv4() { print -rn -- 198.51.100.2 }; doctor_check_reachability >/dev/null 2>&1; print -rn -- "$DOCTOR_FAILED $DOCTOR_WARNED")"
  assert_eq "0 1" "$out" "a warning, not a failure"

  _fresh
  state_set admin_cidr 198.51.100.1/32 >/dev/null 2>&1
  out="$(public_ipv4() { print -rn -- 198.51.100.2 }; doctor_check_reachability >/dev/null 2>&1; print -rn -- "$DOCTOR_FAILED $DOCTOR_WARNED")"
  assert_eq "1 0" "$out" "with the SSH tunnel, backups stop: a failure"
}
