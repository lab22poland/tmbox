#!/bin/zsh
#
# lib/uplink.zsh and cmd/limit.zsh - the upload limit (#20).
#
# The shaping itself runs on the appliance and was measured there (see
# appliance/shape.sh). What is tested here is everything that decides which
# number reaches it: reading networkQuality, turning what people type into
# kbit/s, the share taken by default, and the refusals.

source "$TMBOX_ROOT/lib/answers.zsh"
source "$TMBOX_ROOT/lib/log.zsh"
source "$TMBOX_ROOT/lib/ui.zsh"
source "$TMBOX_ROOT/lib/json.zsh"
source "$TMBOX_ROOT/lib/state.zsh"
source "$TMBOX_ROOT/lib/secrets.zsh"
source "$TMBOX_ROOT/lib/sshx.zsh"
source "$TMBOX_ROOT/lib/macos.zsh"
source "$TMBOX_ROOT/lib/uplink.zsh"
source "$TMBOX_ROOT/cmd/limit.zsh"

ui_init --no-tty-ok
exec {TMBOX_UI_FD}>/dev/null

typeset -g FIX="$TMBOX_ROOT/test/fixtures/networkquality-upload.json"

# A stand-in for /usr/bin/networkQuality that prints a fixed answer and records
# its arguments.
_fake_nq() {
  local dir; dir="$(mktemp -d)"
  print -r -- "#!/bin/sh
echo \"\$*\" > '$dir/args'
cat '$1'" > "$dir/nq"
  chmod +x "$dir/nq"
  print -rn -- "$dir"
}

# --- measuring ----------------------------------------------------------------

test_measure_reads_ul_throughput_in_kbit() {
  # Captured on macOS 26.6.2. It carries an error_code for one lost flow and a
  # good result anyway, so the result must be judged by the throughput alone.
  local dir; dir="$(_fake_nq "$FIX")"
  assert_eq 31553 "$(UPLINK_NQ="$dir/nq" uplink_measure)"
  assert_eq "-d -c -M 20" "$(cat "$dir/args")" "upload only, JSON, capped in time"
}

test_measure_fails_on_no_result() {
  local dir; dir="$(_fake_nq /dev/null)"
  assert_status 1 env_measure "$dir/nq"
  print -r -- '{"ul_throughput": 5000}' > "$dir/tiny.json"
  dir="$(_fake_nq "$dir/tiny.json")"
  assert_status 1 env_measure "$dir/nq" "a few kbit/s is a failed test, not a line"
  assert_status 1 env_measure /nonexistent/networkQuality
}
env_measure() { UPLINK_NQ="$1" uplink_measure >/dev/null }

# --- what people type -------------------------------------------------------

test_parse_takes_mbit_in_the_forms_speed_tests_print() {
  assert_eq 20000 "$(uplink_parse 20)"
  assert_eq 20000 "$(uplink_parse 20M)"
  assert_eq 20000 "$(uplink_parse '20 Mbit/s')"
  assert_eq 33200 "$(uplink_parse 33.2mbps)"
  assert_eq 2500  "$(uplink_parse 2.5)"
  assert_eq off   "$(uplink_parse off)"
  assert_eq off   "$(uplink_parse 0)"
  assert_eq auto  "$(uplink_parse AUTO)"
}

test_parse_refuses_what_it_cannot_mean() {
  assert_status 1 uplink_parse abc
  assert_status 1 uplink_parse 0.1 "below the shaper's floor"
  assert_status 1 uplink_parse 20000 "20 Gbit/s: someone typed kbit"
  assert_status 1 uplink_parse ""
}

test_format_and_round() {
  assert_eq "20 Mbit/s"  "$(uplink_fmt 20000)"
  assert_eq "2.5 Mbit/s" "$(uplink_fmt 2500)"
  assert_eq "no limit"   "$(uplink_fmt off)"
  assert_eq 33200 "$(uplink_share 41500)" "80% by default"
  assert_eq 33000 "$(limit_round 33200)" "whole Mbit/s, rounded down"
  assert_eq 1600  "$(limit_round 1600)" "below 2 Mbit/s nothing is rounded away"
  assert_eq 33    "$(limit_mbit 33000)"
  assert_eq 2.5   "$(limit_mbit 2500)"
}

test_field_reads_the_shapers_report() {
  local r="configured=20000 active=off dropped=7"
  assert_eq 20000 "$(uplink_field "$r" configured)"
  assert_eq off   "$(uplink_field "$r" active)"
  assert_status 1 uplink_field "" active
}

# --- the refusals and the apply path --------------------------------------------

test_auto_refuses_while_a_backup_to_the_appliance_runs() {
  # It would measure only what the backup leaves over.
  local rc=0
  ( tm_running() { return 0 }
    uplink_measure() { print -rn -- 40000 }
    limit_measure_default 203.0.113.10 >/dev/null ) || rc=$?
  assert_eq 5 $rc
}

test_apply_records_the_rate_only_when_the_appliance_took_it() {
  local got
  got="$(
    ssh_put_data() { return 0 }
    ssh_run() { print -r -- "configured=20000 active=20000 dropped=0" }
    state_unset uplink_kbit >/dev/null 2>&1
    limit_apply 203.0.113.10 20000 >/dev/null; print -rn -- "$? $(state_get uplink_kbit)"
  )"
  assert_eq "0 20000" "$got"

  got="$(
    ssh_put_data() { return 0 }
    ssh_run() { print -r -- "nope" >&2; return 1 }
    state_unset uplink_kbit >/dev/null 2>&1
    limit_apply 203.0.113.10 20000 >/dev/null; print -rn -- "$? $(state_get uplink_kbit)"
  )"
  assert_eq "1 " "$got" "a refused rate is not recorded"
}

test_setup_asks_once_and_takes_a_preset_answer_without_measuring() {
  local got
  got="$(
    ssh_put_data() { return 0 }
    ssh_run() { print -r -- "configured=15000 active=15000 dropped=0" }
    uplink_measure() { print -r -- MEASURED >&2; print -rn -- 40000 }
    state_unset uplink_kbit >/dev/null 2>&1
    ans_set UPLINK_LIMIT 15 test
    limit_setup 203.0.113.10 >/dev/null 2>"$TMBOX_STATE_DIR/err"
    print -rn -- "$(state_get uplink_kbit) $(grep -c MEASURED "$TMBOX_STATE_DIR/err")"
  )"
  assert_eq "15000 0" "$got"

  got="$(
    ssh_run() { print -r -- CALLED >&2 }
    state_set uplink_kbit 9000 >/dev/null 2>&1
    limit_setup 203.0.113.10 2>&1 >/dev/null
  )"
  assert_empty "$got" "a resumed setup does not ask again"
}

test_setup_auto_takes_eighty_percent_of_the_measurement() {
  local got
  got="$(
    ssh_put_data() { return 0 }
    ssh_run() { print -r -- "configured=33000 active=33000 dropped=0" }
    uplink_measure() { print -rn -- 41500 }
    state_unset uplink_kbit >/dev/null 2>&1
    ans_set UPLINK_LIMIT auto test
    limit_setup 203.0.113.10 >/dev/null 2>&1
    state_get uplink_kbit
  )"
  assert_eq 33000 "$got"
}

# --- the appliance half -----------------------------------------------------

test_the_shaper_touches_only_the_tunnels_port() {
  # The appliance's own traffic with the Storage Box must never be slowed:
  # every ZFS write goes that way.
  local src="$TMBOX_ROOT/appliance/shape.sh"
  assert_eq 2 "$(grep -c 'flower ip_proto tcp dst_port 22 action mirred' "$src")" "IPv4 and IPv6, port 22 only"
  assert_eq 0 "$(grep -cE 'dst_port (445|139)' "$src")"
}

test_the_shaper_is_embedded_in_the_build() {
  assert_contains "$(cat "$TMBOX_ROOT/tools/build.zsh")" "embed_b64 TMBOX_SHAPER       appliance/shape.sh"
}
