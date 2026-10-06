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
source "$TMBOX_ROOT/cmd/transport.zsh"
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

# --- WireGuard: what is written ----------------------------------------------

_wg_state() {
  _fresh
  state_set transport wireguard server_ip 203.0.113.9 \
            wireguard_appliance_pubkey "1leExBDnO/vCN1arhGYKO1YYzw4uhLeIQDDaPbJ9pls=" \
            wireguard_mac_pubkey "7FDwh5y9qn418QqTUWXcvtc1mRhTAjAMnWQ/Q6PqAlY=" >/dev/null 2>&1
  kc_set wireguard-key "kGc2Hc7Bn1V1z9mHq2b7c9d0e1f2a3b4c5d6e7f8g9A=" >/dev/null 2>&1
}

test_the_daemons_configuration_is_for_setconf() {
  _wg_state
  local conf; conf="$(wg_render_conf daemon)"
  # `wg setconf` rejects wg-quick's Address line; the helper sets addresses.
  assert_not_contains "$conf" "Address"
  assert_contains "$conf" "Endpoint = 203.0.113.9:51820"
  assert_contains "$conf" "AllowedIPs = ${TMBOX_WG_APPLIANCE}/32" "only the appliance is routed"
  assert_contains "$conf" "PersistentKeepalive = 25" "or a hotspot's NAT forgets the tunnel"
  assert_contains "$conf" "PublicKey = 1leExBDnO/vCN1arhGYKO1YYzw4uhLeIQDDaPbJ9pls="
}

test_the_apps_configuration_carries_this_macs_address() {
  _wg_state
  local conf; conf="$(wg_render_conf app)"
  assert_contains "$conf" "Address = ${TMBOX_WG_MAC}/32"
  assert_contains "$conf" "AllowedIPs = ${TMBOX_WG_APPLIANCE}/32"
}

test_no_configuration_without_a_key() {
  _fresh
  state_set wireguard_appliance_pubkey "1leExBDnO/vCN1arhGYKO1YYzw4uhLeIQDDaPbJ9pls=" >/dev/null 2>&1
  assert_status 1 wg_render_conf daemon
}

test_the_wireguard_job_is_a_valid_plist_with_nothing_left_to_fill() {
  _wg_state
  local out="$TMBOX_STATE_DIR/wireguard.plist"
  ( wg_tool() { print -rn -- "/opt/homebrew/bin/$1" }; wg_render_plist ) > "$out"
  assert_status 0 plutil -lint -- "$out"
  local body; body="$(cat -- "$out")"
  local token
  for token in @LABEL@ @HELPER@ @WGGO@ @WG@ @CONF@ @ADDRESS@ @PEER@ @LOG@; do
    assert_not_contains "$body" "$token" "substituted ${token}"
  done
  assert_contains "$body" "/opt/homebrew/bin/wireguard-go"
  assert_contains "$body" "${TMBOX_SYS_DIR}/wireguard.conf"
  assert_not_contains "$body" "PrivateKey" "the key stays in the configuration file"
}

test_the_wireguard_helper_parses_and_refuses_what_it_cannot_run() {
  assert_status 0 zsh -n "$TMBOX_ROOT/macos/tmbox-wireguard"
  assert_status 78 zsh "$TMBOX_ROOT/macos/tmbox-wireguard" --address 10.209.77.2
  assert_status 78 zsh "$TMBOX_ROOT/macos/tmbox-wireguard" --bogus
}

test_the_appliance_guard_admits_only_samba_ssh_and_ping() {
  local src="$TMBOX_ROOT/appliance/transport.sh"
  assert_status 0 bash -n "$src"
  local guard; guard="$(awk '/^guard_write\(\) \{/,/^\}/' "$src")"
  assert_contains "$guard" 'tcp dport { 22, 445 } accept'
  assert_contains "$guard" 'ip saddr != ${peer} drop' "from the one peer only"
  assert_contains "$guard" 'iifname "${dev}" drop' "and nothing else through the interface"
  assert_not_contains "$guard" "policy drop" "the appliance's other interfaces are not its business"
}

test_the_tailscale_auth_key_never_reaches_a_command_line() {
  local src="$TMBOX_ROOT/appliance/transport.sh"
  local up; up="$(awk '/^tailscale_up\(\) \{/,/^\}/' "$src")"
  assert_contains "$up" '--auth-key="file:${keyfile}"'
  assert_contains "$up" 'cat > "$keyfile"' "it arrives on stdin"
}

test_the_appliance_tool_is_embedded_in_the_build() {
  local build; build="$(cat "$TMBOX_ROOT/tools/build.zsh")"
  assert_contains "$build" "embed_b64 TMBOX_TRANSPORT    appliance/transport.sh"
  assert_contains "$build" "embed_b64 TMBOX_WG_BIN       macos/tmbox-wireguard"
  assert_contains "$build" "embed_b64 TMBOX_WG_PLIST     macos/wireguard.plist"
}

# --- WireGuard: choosing it ---------------------------------------------------

test_an_unattended_setup_that_does_not_say_gets_ssh() {
  _fresh
  local saved=$TMBOX_NONINTERACTIVE
  TMBOX_NONINTERACTIVE=1
  setup_ask_transport >/dev/null 2>&1
  TMBOX_NONINTERACTIVE=$saved
  assert_eq ssh "$(state_get transport)"
}

test_choosing_wireguard_records_it_and_its_client_before_anything_is_bought() {
  _fresh
  ans_set transport wireguard
  ans_set wireguard-client app
  setup_ask_transport >/dev/null 2>&1
  assert_eq wireguard "$(state_get transport)"
  assert_eq app "$(state_get wireguard_client)"
  # Step 5 then opens the tunnel's port with the rest of the firewall.
  assert_eq 51820 "$(transport_udp_port)"
}

test_an_existing_installation_is_not_asked() {
  _fresh
  state_set transport ssh >/dev/null 2>&1
  ans_set transport wireguard
  setup_ask_transport >/dev/null 2>&1
  assert_eq ssh "$(state_get transport)" "decided once, at the first setup"
}

# --- switching ------------------------------------------------------------------

test_a_switch_keeps_the_old_port_open_until_time_machine_has_moved() {
  _fresh
  state_set server_id 1 server_ip 203.0.113.9 firewall_id 77 admin_cidr any \
            transport ssh destination_id ABC >/dev/null 2>&1
  local log="${TMBOX_STATE_DIR}/switch"
  (
    tm_running() { return 1 }
    hc_firewall_set_admin_cidr() { print -r -- "fw $3" >> "$log" }
    transport_install() { print -r -- "install $1" >> "$log"; state_set transport_ready "$1" >/dev/null 2>&1 }
    transport_repoint_destination() { print -r -- "repoint $(transport_url tm-x)" >> "$log" }
    transport_remove() { print -r -- "remove $1" >> "$log" }
    TMBOX_HCLOUD_TOKEN=x
    kc_set hetzner-token x >/dev/null 2>&1
    ans_set switch-transport yes
    transport_switch wireguard >/dev/null 2>&1
  )
  assert_eq "fw 51820
install wireguard
repoint smb://tmuser@10.209.77.1/tm-x
remove ssh
fw 51820" "$(cat -- "$log")"
  assert_eq wireguard "$(state_get transport)"
}

test_a_switch_that_cannot_move_time_machine_keeps_the_old_transport() {
  _fresh
  state_set server_id 1 server_ip 203.0.113.9 transport ssh destination_id ABC >/dev/null 2>&1
  local log="${TMBOX_STATE_DIR}/switch"
  (
    tm_running() { return 1 }
    transport_install() { print -r -- "install $1" >> "$log" }
    transport_repoint_destination() { return 1 }
    transport_remove() { print -r -- "remove $1" >> "$log" }
    ans_set switch-transport yes
    transport_switch wireguard >/dev/null 2>&1
  )
  assert_eq "install wireguard" "$(cat -- "$log")" "nothing is removed"
  assert_eq ssh "$(state_get transport)" "and backups still go the old way"
}

test_a_switch_refuses_while_a_backup_runs() {
  _fresh
  state_set server_id 1 transport ssh destination_id ABC >/dev/null 2>&1
  local rc=0
  ( tm_running() { return 0 }; transport_switch wireguard >/dev/null 2>&1 ) || rc=$?
  assert_eq 5 "$rc"
}

# --- doctor, the appliance's half ----------------------------------------------

test_doctor_reads_the_appliances_tunnel_report() {
  _fresh
  state_set transport wireguard >/dev/null 2>&1
  doctor_check_vpn_appliance "transport=wireguard up=yes guard=on handshake=12 ts_ip=-" >/dev/null 2>&1
  assert_eq "0 0" "$DOCTOR_FAILED $DOCTOR_WARNED"

  _fresh
  state_set transport wireguard >/dev/null 2>&1
  doctor_check_vpn_appliance "transport=wireguard up=yes guard=off handshake=12 ts_ip=-" >/dev/null 2>&1
  assert_eq "1 0" "$DOCTOR_FAILED $DOCTOR_WARNED" "an unguarded tunnel is a failure"

  _fresh
  state_set transport wireguard >/dev/null 2>&1
  doctor_check_vpn_appliance "transport=none up=no guard=off handshake=never ts_ip=-" >/dev/null 2>&1
  assert_eq "1 0" "$DOCTOR_FAILED $DOCTOR_WARNED" "not up at all"

  _fresh
  state_set transport wireguard >/dev/null 2>&1
  doctor_check_vpn_appliance "transport=wireguard up=yes guard=on handshake=900 ts_ip=-" >/dev/null 2>&1
  assert_eq "0 1" "$DOCTOR_FAILED $DOCTOR_WARNED" "a stale handshake is worth knowing"
}

# --- host keys ------------------------------------------------------------------

test_the_tunnel_address_is_pinned_to_the_same_host_key() {
  _fresh
  mkdir -p -- "${SSH_KNOWN_HOSTS:h}"
  print -r -- "203.0.113.9 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialForTestsOnly000000000000" > "$SSH_KNOWN_HOSTS"
  ssh_pin_alias 203.0.113.9 10.209.77.1
  assert_contains "$(cat -- "$SSH_KNOWN_HOSTS")" "10.209.77.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialForTestsOnly000000000000"
  ssh_pin_alias 203.0.113.9 10.209.77.1
  assert_eq 2 "$(grep -c . "$SSH_KNOWN_HOSTS")" "and only once"
  rm -f -- "$SSH_KNOWN_HOSTS"
}

# --- Tailscale ------------------------------------------------------------------

# The shape of `tailscale status --json`, trimmed to what tmbox reads.
_ts_json() {
  local tailnet="${1:-owner@example.com}" mine="${2:-100.64.0.2}" curaddr="${3-198.51.100.9:41641}" online="${4:-true}"
  print -r -- '{"BackendState":"Running",
    "Self":{"TailscaleIPs":["'"$mine"'","fd7a:115c:a1e0::2"]},
    "CurrentTailnet":{"Name":"'"$tailnet"'"},
    "Peer":{"nodekey:abc":{"HostName":"tmbox-studio","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"],
                           "Online":'"$online"',"CurAddr":"'"$curaddr"'","Relay":"fra"}}}'
}

_ts_state() {
  _fresh
  state_set transport tailscale server_ip 203.0.113.9 tailscale_ip 100.64.0.1 \
            tailscale_mac_ip 100.64.0.2 tailscale_tailnet owner@example.com mac_name studio >/dev/null 2>&1
}

test_the_path_to_the_appliance_is_read_from_tailscale() {
  assert_eq "direct 198.51.100.9:41641" "$(ts_peer 100.64.0.1 "$(_ts_json)")"
  assert_eq "relay fra" "$(ts_peer 100.64.0.1 "$(_ts_json x 100.64.0.2 '')")"
  assert_eq "offline"   "$(ts_peer 100.64.0.1 "$(_ts_json x 100.64.0.2 '' false)")"
  assert_empty "$(ts_peer 100.64.0.99 "$(_ts_json)")" "an unknown peer is no answer"
}

test_doctor_names_another_tailnet_as_the_cause() {
  _ts_state
  local out
  out="$(
    ts_cli() { print -rn -- /bin/true }
    ts_status() { _ts_json other@example.org }
    smb_probe() { return 1 }
    doctor_check_tailscale >/dev/null 2>&1
    print -rn -- "$DOCTOR_FAILED"
  )"
  assert_eq 1 "$out" "one failure, and it is the tailnet - not the probe as well"
  assert_contains "$(cat "$UI_LOG")" "other@example.org"
}

test_doctor_passes_a_working_direct_tailnet() {
  _ts_state
  local out
  out="$(
    ts_cli() { print -rn -- /bin/true }
    ts_status() { _ts_json }
    smb_probe() { return 0 }
    doctor_check_tailscale >/dev/null 2>&1
    print -rn -- "$DOCTOR_FAILED $DOCTOR_WARNED"
  )"
  assert_eq "0 0" "$out"
}

test_doctor_fix_moves_the_guard_to_this_macs_new_address() {
  _ts_state
  local log="${TMBOX_STATE_DIR}/calls"
  (
    ts_cli() { print -rn -- /bin/true }
    ts_status() { _ts_json owner@example.com 100.64.0.7 }
    smb_probe() { return 0 }
    ssh_run() { print -r -- "$2" >> "$log" }
    DOCTOR_FIX=1
    doctor_check_tailscale >/dev/null 2>&1
  )
  assert_contains "$(cat -- "$log")" "tmbox-transport tailscale-guard 100.64.0.7"
  assert_eq 100.64.0.7 "$(state_get tailscale_mac_ip)"
}

test_doctor_warns_about_an_expiring_appliance_key() {
  _ts_state
  doctor_check_vpn_appliance "transport=tailscale up=yes guard=on handshake=never ts_ip=100.64.0.1 ts_expiry=2027-04-04T10:00:00Z" >/dev/null 2>&1
  assert_eq "0 1" "$DOCTOR_FAILED $DOCTOR_WARNED"
  _ts_state
  doctor_check_vpn_appliance "transport=tailscale up=yes guard=on handshake=never ts_ip=100.64.0.1 ts_expiry=-" >/dev/null 2>&1
  assert_eq "0 0" "$DOCTOR_FAILED $DOCTOR_WARNED"
}

test_the_auth_key_is_a_secret_and_must_look_like_one() {
  assert_status 0 ans_is_secret tailscale-authkey
  _fresh
  ans_set tailscale-authkey "not-a-key"
  assert_status 1 ts_ask_authkey
  ans_set tailscale-authkey "tskey-auth-kExample-0123456789abcdef"
  assert_eq "tskey-auth-kExample-0123456789abcdef" "$(ts_ask_authkey 2>/dev/null)"
}

test_a_package_not_signed_by_tailscale_is_not_installed() {
  _fresh
  local log="${TMBOX_STATE_DIR}/calls"
  (
    curl() { : > "${@[-1]}"; return 0 }
    pkgutil() { print -r -- "Status: signed by a developer certificate issued by Apple for distribution
   Notarization: trusted by the Apple notary service
    1. Developer ID Installer: Someone Else (ABCDE12345)" }
    priv_prime() { return 0 }
    priv_run() { print -r -- "$*" >> "$log" }
    ts_install_app >/dev/null 2>&1
  )
  assert_empty "$(cat -- "$log" 2>/dev/null)" "the installer never ran"
}

test_a_package_signed_by_tailscale_is_installed() {
  _fresh
  local log="${TMBOX_STATE_DIR}/calls"
  (
    curl() { : > "${@[-1]}"; return 0 }
    pkgutil() { print -r -- "Status: signed by a developer certificate issued by Apple for distribution
   Notarization: trusted by the Apple notary service
    1. Developer ID Installer: Tailscale Inc. (W5364U7YZB)" }
    priv_prime() { return 0 }
    priv_run() { print -r -- "$*" >> "$log" }
    ts_install_app >/dev/null 2>&1
  )
  assert_contains "$(cat -- "$log")" "/usr/sbin/installer -pkg"
}

# --- sessions the forward kept open (#22) ---------------------------------------

test_a_session_this_mac_no_longer_has_is_stale() {
  # sshd keeps its end of a forward open after the Mac has closed its own, so
  # Samba sees a socket and the old test called the session healthy.
  _fresh
  local out
  out="$(
    smb_client_connections() { print -rn -- 0 }
    tm_running() { return 1 }
    doctor_check_stale_sessions 203.0.113.9 0 1 >/dev/null 2>&1
    print -rn -- "$DOCTOR_WARNED"
  )"
  assert_eq 1 "$out"
}

test_a_session_this_mac_still_has_is_not_stale() {
  _fresh
  local out
  out="$(
    smb_client_connections() { print -rn -- 2 }
    tm_running() { return 1 }
    doctor_check_stale_sessions 203.0.113.9 0 1 >/dev/null 2>&1
    print -rn -- "$DOCTOR_WARNED"
  )"
  assert_eq 0 "$out"
}

test_nothing_is_called_stale_while_a_backup_runs() {
  _fresh
  local out
  out="$(
    smb_client_connections() { print -rn -- 0 }
    tm_running() { return 0 }
    doctor_check_stale_sessions 203.0.113.9 0 1 >/dev/null 2>&1
    print -rn -- "$DOCTOR_WARNED"
  )"
  assert_eq 0 "$out"
}

test_the_wireguard_helper_routes_the_appliance_through_the_tunnel_itself() {
  # A route cloned from the default one, left by a connection attempted while
  # the tunnel was down, sent everything into the tunnel from the wrong source
  # address for over a minute; the helper replaces it with its own.
  local src; src="$(cat "$TMBOX_ROOT/macos/tmbox-wireguard")"
  assert_contains "$src" 'route -q -n delete -inet -host "$W_PEER"'
  assert_contains "$src" 'route -q -n add -inet -host "$W_PEER" -interface "$IFN"'
}

test_the_smb_probe_bounds_the_connect_and_not_only_the_wait() {
  # macOS nc's -w does not bound a connect; -G does. Without it a probe sent
  # before the tunnel was up hung for the kernel's 75 seconds.
  local body; body="$(awk '/^smb_probe\(\) \{/,/^\}/' "$TMBOX_ROOT/lib/transport.zsh")"
  assert_contains "$body" 'nc -G "$timeout" -w "$timeout"'
}
