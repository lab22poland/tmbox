#!/bin/zsh
#
# cmd/setup.zsh - resuming an installation that already exists (#4).
#
# A resumed run is a run whose earlier half already spent money, so what is
# tested here is what it does with that: that it recognises it, never asks
# again what was decided, never buys anything twice, and re-checks the two
# things that change between runs - the Mac's address and the share password.
# Hetzner, ssh and the network are replaced by functions; the state file is
# the real one, in the runner's scratch directory.

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
source "$TMBOX_ROOT/cmd/tunnel.zsh"
source "$TMBOX_ROOT/cmd/setup.zsh"

ui_init --no-tty-ok
typeset -g UI_LOG="$TMBOX_STATE_DIR/ui.out"

_fresh() {
  rm -rf -- "$TMBOX_STATE_DIR"
  state_init >/dev/null 2>&1
  kc_init
  : > "$UI_LOG"
  exec {TMBOX_UI_FD}>>"$UI_LOG"
  TMBOX_ANS=(); TMBOX_ANSSRC=()
  SETUP_RESUMING=0
}

# --- recognising an existing install ----------------------------------------

test_a_fresh_mac_is_not_resuming() {
  _fresh
  setup_existing && fail "nothing recorded, yet treated as existing"
  return 0
}

test_any_billable_resource_or_the_firewall_means_resuming() {
  local key
  for key in box_id server_id primary_ip_id firewall_id; do
    _fresh
    state_set "$key" 123 >/dev/null 2>&1
    setup_existing || fail "$key alone was not recognised"
  done
}

# --- the resume screen ------------------------------------------------------

test_declining_to_resume_says_the_resources_still_bill() {
  _fresh
  state_set box_id 1 server_id 2 mac_name studio capacity 1TB region fsn1 >/dev/null 2>&1
  ans_set RESUME no
  local -i rc=0
  ( setup_resume_intro ) >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "declining is a clean stop"
  local -i went_on=0
  ( setup_resume_intro; exit 99 ) >/dev/null 2>&1 || went_on=$?
  assert_eq 0 "$went_on" "and it stops there rather than carrying on"
  local said; said="$(cat "$UI_LOG")"
  assert_contains "$said" "still billed"
  assert_not_contains "$said" "nothing is being billed" "the new-install wording must not appear"
}

test_resuming_does_not_ask_for_the_name_or_size_again() {
  # The share is tm-<mac_name>: asking again, and storing a different answer,
  # pointed Time Machine at a share that did not exist.
  _fresh
  state_set box_id 1 mac_name studio capacity 2TB region fsn1 >/dev/null 2>&1
  ans_set RESUME yes
  ans_set MAC_NAME something-else
  ans_set CAPACITY 10TB
  setup_resume_intro >/dev/null 2>&1
  assert_eq "studio" "$(state_get mac_name)"
  assert_eq "2TB"    "$(state_get capacity)"
}

test_resuming_with_everything_bought_skips_the_cost_screen() {
  _fresh
  SETUP_RESUMING=1
  state_set box_id 1 primary_ip_id 2 server_id 3 monthly_eur 9.69 region fsn1 >/dev/null 2>&1
  local asked
  asked="$(
    setup_choose_region() { print -rn -- "ASKED" }
    hb_types_json()       { print -rn -- "PRICED" }
    setup_step4_confirm >/dev/null 2>&1
  )"
  assert_empty "$asked" "neither the region nor the prices are asked for"
  assert_contains "$(cat "$UI_LOG")" "already created"
}

# --- re-checking what changes between runs -----------------------------------

test_a_moved_address_is_re_pinned_before_anything_connects() {
  _fresh
  state_set firewall_id 77 admin_cidr 198.51.100.1/32 >/dev/null 2>&1
  local calls
  calls="$(
    public_ipv4() { print -rn -- 198.51.100.2 }
    hc_firewall_set_admin_cidr() { print -rn -- "$1 $2" }
    setup_follow_address 2>/dev/null
  )"
  assert_eq "77 198.51.100.2/32" "$calls" "the firewall is re-pinned to the new address"
}

test_an_unchanged_address_is_left_alone() {
  _fresh
  state_set firewall_id 77 admin_cidr 198.51.100.1/32 >/dev/null 2>&1
  local calls
  calls="$(
    public_ipv4() { print -rn -- 198.51.100.1 }
    hc_firewall_set_admin_cidr() { print -rn -- "CALLED" }
    setup_follow_address 2>/dev/null
  )"
  assert_empty "$calls"
}

test_a_share_password_that_differs_from_the_appliance_is_fetched_again() {
  _fresh
  kc_set samba-password "stale-password-on-the-mac" >/dev/null 2>&1
  local calls
  calls="$(
    ssh_run() { print -rn -- "0123456789abcdef" }   # the appliance's fingerprint
    setup_collect_share_password() { print -rn -- "FETCHED $1" }
    setup_check_share_password 203.0.113.10 2>/dev/null
  )"
  assert_eq "FETCHED 203.0.113.10" "$calls"
}

test_a_matching_share_password_is_left_alone() {
  _fresh
  kc_set samba-password "the-right-one" >/dev/null 2>&1
  local fp; fp="$(setup_pw_fingerprint)"
  local calls
  calls="$(
    ssh_run() { print -rn -- "$fp" }
    setup_collect_share_password() { print -rn -- "FETCHED" }
    setup_check_share_password 203.0.113.10 2>/dev/null
  )"
  assert_empty "$calls"
}

# --- stopped half way through buying ----------------------------------------

test_a_box_ordered_but_not_yet_active_is_waited_for_not_bought_again() {
  # A run stopped during the wait used to leave a billing box nobody recorded,
  # and the next run bought a second.
  _fresh
  state_set box_id 555 >/dev/null 2>&1
  local calls
  calls="$(
    hb_create()            { print -rn -- "CREATE " }
    hb_wait_active()       { print -rn -- "WAIT:$1 " }
    hb_server()            { print -rn -- "u1.your-storagebox.de" }
    hb_password()          { print -rn -- "pw" }
    hb_subaccount_create() { print -rn -- "u1-sub1 u1-sub1.your-storagebox.de" }
    setup_provision_box base bx11 fsn1 stamp >/dev/null 2>&1
    print -rn -- "server=$(state_get box_server) sub=$(state_get box_subaccount)"
  )"
  assert_not_contains "$calls" "CREATE" "no second box"
  assert_contains "$calls" "server=u1.your-storagebox.de sub=u1-sub1"
}

test_zz_cleanup() {
  rm -rf -- "$TMBOX_STATE_DIR"
}
