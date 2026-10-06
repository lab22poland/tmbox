#!/bin/zsh
#
# cmd/status.zsh and cmd/doctor.zsh - the parts that decide what to say.
#
# Neither command can be run for real in a test: everything interesting needs
# an appliance, a tunnel and root. What is tested here is the reasoning that
# turns a remote answer into a verdict, because that is where a check quietly
# becomes wrong - a threshold off by one, a field read from the wrong line -
# and a check that is wrong in that way still prints a tick.

source "$TMBOX_ROOT/lib/answers.zsh"
source "$TMBOX_ROOT/lib/log.zsh"
source "$TMBOX_ROOT/lib/ui.zsh"
source "$TMBOX_ROOT/lib/json.zsh"
source "$TMBOX_ROOT/lib/state.zsh"
source "$TMBOX_ROOT/lib/secrets.zsh"
source "$TMBOX_ROOT/lib/sshx.zsh"
source "$TMBOX_ROOT/lib/macos.zsh"
source "$TMBOX_ROOT/lib/transport.zsh"
source "$TMBOX_ROOT/lib/uplink.zsh"
source "$TMBOX_ROOT/cmd/tunnel.zsh"
source "$TMBOX_ROOT/cmd/transport.zsh"
source "$TMBOX_ROOT/cmd/status.zsh"
source "$TMBOX_ROOT/cmd/doctor.zsh"

# The checks below call the real reporting functions, which write to the UI
# rather than to stdout - so without this the suite prints a doctor report in
# the middle of the test output.
ui_init --no-tty-ok
exec {TMBOX_UI_FD}>/dev/null

_reset() { DOCTOR_FAILED=0; DOCTOR_WARNED=0; DOCTOR_FIX=0 }

# --- reading a backup's age -------------------------------------------------

test_backup_age_reads_the_timestamp_out_of_the_path() {
  # The real thing backupd produces, captured from the guest.
  local p="/Volumes/.timemachine/7DDEEF69/2026-09-19-073758.backup/2026-09-19-073758.backup"
  assert_contains "$(status_backup_age "$p")" "2026-09-19 07:37" \
    "the date and time come from the directory name"
}

test_backup_age_survives_a_path_it_does_not_understand() {
  # tmutil's output format is not a promise. An unparseable path must degrade
  # to showing it, never to an error or an empty field.
  assert_eq "something-else" "$(status_backup_age "/x/y/something-else")"
}

# --- how full is too full ---------------------------------------------------

test_space_warns_before_it_is_too_late_and_fails_when_it_is() {
  # Measured in validation: Time Machine stalls silently on a full
  # destination and the client never says so. These thresholds are the only
  # warning anyone gets, so their boundaries are worth pinning.
  _reset; doctor_check_space "10G" "100G" 10 >/dev/null
  assert_eq 0 $DOCTOR_WARNED "10% is unremarkable"
  assert_eq 0 $DOCTOR_FAILED

  _reset; doctor_check_space "85G" "100G" 85 >/dev/null
  assert_eq 1 $DOCTOR_WARNED "85% is where the warning starts"
  assert_eq 0 $DOCTOR_FAILED

  _reset; doctor_check_space "95G" "100G" 95 >/dev/null
  assert_eq 1 $DOCTOR_FAILED "95% is a failure, not a warning"

  _reset; doctor_check_space "" "" "" >/dev/null
  assert_eq 1 $DOCTOR_WARNED "an unreadable figure is a warning, not a pass"
}

# --- the remote script ------------------------------------------------------

test_the_remote_script_asks_for_exactly_the_fields_that_are_read() {
  # The reader is positional, so the count has to match exactly. It did not
  # once: a printf without a trailing newline ran two values together, the
  # dataset read as "00% full" and the session count silently vanished.
  state_set mac_name "livetest" >/dev/null 2>&1
  local script; script="$(doctor_remote_script)"
  local -i lines; lines="$(print -r -- "$script" | grep -c .)"
  assert_eq 13 "$lines" "thirteen facts are read, so thirteen must be asked for"
}

test_the_usage_line_ends_in_a_newline() {
  local script; script="$(doctor_remote_script)"
  # The specific bug: printf "%d" with no \n. Anything that prints a field
  # must terminate it, or the next field joins it.
  assert_not_contains "$script" 'printf "%d",' "the usage figure must end its line"
  assert_contains "$script" '\n' "and it does that with an explicit newline"
}

test_stale_is_defined_by_a_missing_socket_not_by_a_guess() {
  # A session whose smbd process holds no TCP socket is stale: the client
  # vanished and Samba is waiting for a lease break that will never come.
  # Anything vaguer than that reports healthy sessions as stale and gets
  # itself ignored.
  local script; script="$(doctor_remote_script)"
  assert_contains "$script" "smbstatus -p" "sessions come from smbstatus"
  assert_contains "$script" "ss -tnp"      "and are checked against real sockets"
}

# --- the tunnel probe -------------------------------------------------------

test_the_negotiate_packet_is_a_wellformed_smb2_request() {
  # Built once and carried as a constant, because a hundred hand-counted \x00
  # is wrong by two bytes and still looks right - which it was.
  local raw; raw="$(print -rn -- "$TMBOX_SMB_NEGOTIATE_B64" | base64 -D | wc -c | tr -d ' ')"
  assert_eq "106" "$raw" "4 bytes of NetBIOS framing, 64 of SMB2 header, 38 of body"

  local magic; magic="$(print -rn -- "$TMBOX_SMB_NEGOTIATE_B64" | base64 -D | dd bs=1 skip=4 count=4 2>/dev/null)"
  assert_eq $'\xfeSMB' "$magic" "the SMB2 protocol id"

  # The length field must agree with what follows it, or Samba ignores the
  # request and the probe reports a healthy tunnel as dead. Kept as a string:
  # od pads its output, and feeding that to zsh arithmetic is how this test
  # first failed rather than the thing it was testing.
  local declared
  declared="$(print -rn -- "$TMBOX_SMB_NEGOTIATE_B64" | base64 -D \
    | dd bs=1 skip=1 count=3 2>/dev/null \
    | od -An -tu1 | tr -s ' ' | sed 's/^ //;s/ $//')"
  assert_eq "0 0 102" "$declared" "the NetBIOS length must match the SMB2 message"
}

test_the_probe_is_not_a_tcp_connect() {
  # The whole reason this check was rewritten: `ssh -L` binds the port itself,
  # so a connect succeeds against an appliance that is off, locked, or not
  # running Samba. Measured against a deliberately locked appliance, where
  # `nc -z` reported success while every backup failed.
  # Extracted by line range rather than by parameter expansion: the comment
  # above the function names it too, so `${src#*smb_probe() {}` matched
  # inside the comment and cut the wrong text.
  local body
  # No `--` before the filename: BSD awk, which is what macOS ships, takes it
  # as a file to read rather than as an end-of-options marker, and then reads
  # nothing at all.
  body="$(awk '/^smb_probe\(\) \{/,/^\}/' "$TMBOX_ROOT/lib/transport.zsh")"
  assert_nonempty "$body" "the function must still be findable"
  assert_contains "$body" "TMBOX_SMB_NEGOTIATE_B64" "it must speak SMB"
  assert_not_contains "$body" "nc -z" "a bare connect is what this replaced"

  # And the tunnel's own check is that probe, not a connect of its own.
  body="$(awk '/^tunnel_listening\(\) /,/\}$/' "$TMBOX_ROOT/cmd/tunnel.zsh")"
  assert_contains "$body" "smb_probe" "the tunnel check goes through the SMB probe"
}

# --- the verdict ------------------------------------------------------------

test_the_exit_status_distinguishes_broken_from_merely_untidy() {
  # A cron job needs the difference: a warning is not a reason to wake anyone.
  _reset; assert_status 0 doctor_summary "clean is 0"
  _reset; DOCTOR_WARNED=2; assert_status 2 doctor_summary "warnings only is 2"
  _reset; DOCTOR_FAILED=1; assert_status 1 doctor_summary "a failure is 1"
  _reset; DOCTOR_FAILED=1; DOCTOR_WARNED=3
  assert_status 1 doctor_summary "a failure outranks any number of warnings"
}

# --- repair order (#5) ------------------------------------------------------

test_the_firewall_is_checked_before_the_tunnel() {
  # The tunnel is an ssh connection, so with --fix a changed address has to be
  # re-pinned before a dead tunnel is restarted. The other way round the
  # restart timed out against the old rules and was reported as a failure.
  local order
  order="$(
    doctor_check_reachability() { print -rn -- "reach " }
    doctor_check_mac()          { print -rn -- "mac " }
    doctor_check_appliance()    { print -rn -- "appliance " }
    doctor_check_timemachine()  { print -rn -- "tm" }
    doctor_run_checks
  )"
  assert_eq "reach mac appliance tm" "$order"
}

# --- copyable ssh lines (#5) ------------------------------------------------

test_the_ssh_hint_names_tmboxs_own_known_hosts() {
  # The host key is pinned in tmbox's file, not ~/.ssh/known_hosts. A hint
  # without it fails with "Host key verification failed" when copied.
  local hint; hint="$(ssh_hint 203.0.113.10 true)"
  assert_contains "$hint" "-o UserKnownHostsFile=\"${SSH_KNOWN_HOSTS}\""
  assert_contains "$hint" "-i \"$(ssh_key_path admin)\""
  assert_matches  "$hint" ' root@203\.0\.113\.10 true$'
  assert_matches  "$(ssh_hint 203.0.113.10)" ' root@203\.0\.113\.10$' "no command, no trailing space"
}

# --- SMB multichannel (#17) -------------------------------------------------

test_multichannel_off_passes_and_on_warns() {
  _reset; doctor_check_multichannel 203.0.113.10 "No" >/dev/null
  assert_eq 0 $DOCTOR_WARNED "off is what tmbox builds"
  _reset; doctor_check_multichannel 203.0.113.10 "Yes" >/dev/null
  assert_eq 1 $DOCTOR_WARNED "on is worth a warning, not a failure: backups mostly work"
  assert_eq 0 $DOCTOR_FAILED
}

test_multichannel_fix_never_restarts_samba_under_a_backup() {
  # Turning it off restarts Samba. With a client connected that would end the
  # very backup the change is meant to protect, so the remote script refuses
  # and doctor says to come back later.
  local warned
  warned="$(
    _reset; DOCTOR_FIX=1
    ssh_run() { print -r -- BUSY }
    doctor_check_multichannel 203.0.113.10 "Yes" >/dev/null
    print -rn -- "$DOCTOR_WARNED $DOCTOR_FAILED"
  )"
  assert_eq "1 0" "$warned"
  local script; script="$(doctor_multichannel_off_script)"
  local busy_line; busy_line="$(print -r -- "$script" | grep -n BUSY | cut -d: -f1)"
  local restart_line; restart_line="$(print -r -- "$script" | grep -n 'systemctl restart' | cut -d: -f1)"
  (( busy_line < restart_line )) || fail "the busy check must come before the restart"
}

test_multichannel_fix_reports_success() {
  local counts
  counts="$(
    _reset; DOCTOR_FIX=1
    ssh_run() { print -r -- DONE }
    doctor_check_multichannel 203.0.113.10 "Yes" >/dev/null
    print -rn -- "$DOCTOR_WARNED $DOCTOR_FAILED"
  )"
  assert_eq "0 0" "$counts"
}

# --- the upload limit (#20) --------------------------------------------------

_uplink_counts() {
  (
    _reset; DOCTOR_FIX="$3"
    state_set uplink_kbit "$1" >/dev/null 2>&1
    [[ -n "$1" ]] || state_unset uplink_kbit >/dev/null 2>&1
    ssh_run() { return 0 }
    doctor_check_uplink 203.0.113.10 "$2" >/dev/null
    print -rn -- "$DOCTOR_WARNED $DOCTOR_FAILED"
  )
}

test_uplink_in_force_passes() {
  assert_eq "0 0" "$(_uplink_counts 20000 "configured=20000 active=20000 dropped=3" 0)"
}

test_uplink_never_asked_warns_and_chosen_off_passes() {
  # An appliance from before 0.1.4 has no shaper, so the report is empty.
  assert_eq "1 0" "$(_uplink_counts "" "" 0)" "never set: the symptom points nowhere, so say it"
  assert_eq "0 0" "$(_uplink_counts off "" 0)" "off was a choice"
  assert_eq "0 0" "$(_uplink_counts off "configured=off active=off dropped=0" 0)"
}

test_uplink_recorded_but_not_in_force_fails_unless_fixed() {
  assert_eq "0 1" "$(_uplink_counts 20000 "configured=20000 active=off dropped=0" 0)"
  assert_eq "0 0" "$(_uplink_counts 20000 "configured=20000 active=off dropped=0" 1)" "--fix restarts the unit"
}
