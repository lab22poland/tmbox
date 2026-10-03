#!/bin/zsh
#
# lib/macos.zsh - reading Time Machine's own state.
#
# Every function here parses output from a tool that cannot be run in a test, so
# the tools are replaced by functions that return output captured from the real
# thing on macOS 26.6. That makes these tests about the parsing, which is where
# all three bugs found in this area actually were.

source "$TMBOX_ROOT/lib/answers.zsh"
source "$TMBOX_ROOT/lib/log.zsh"
source "$TMBOX_ROOT/lib/ui.zsh"
source "$TMBOX_ROOT/lib/json.zsh"
source "$TMBOX_ROOT/lib/macos.zsh"

ui_init --no-tty-ok

# --- where backupd mounts the share -----------------------------------------

# Captured from the guest while a backup was running. Note the path: not
# /Volumes/<share>, and it contains a space before the options.
mount() {
  print -r -- "/dev/disk2s1s1 on / (apfs, sealed, local, read-only, journaled)"
  print -r -- "//tmuser@127.0.0.2/tm-studio on /Volumes/.timemachine/127.0.0.2/3F2A9C1E-7B4D-4E8A-9C61-0D5B8E2F4A17/tm-studio (smbfs, nobrowse)"
  print -r -- "/dev/disk8s1 on /Volumes/Backups of Managed's Virtual Machine (apfs, local, nodev, nosuid, journaled, nobrowse)"
}

test_finds_the_hidden_mount_point_backupd_uses() {
  local mp; mp="$(tm_destination_mountpoint tm-studio)"
  # The whole point: a network destination is mounted out of sight under
  # /Volumes/.timemachine, so looking in /Volumes/<share> finds nothing and
  # invites the conclusion that the share is not mounted.
  assert_eq "/Volumes/.timemachine/127.0.0.2/3F2A9C1E-7B4D-4E8A-9C61-0D5B8E2F4A17/tm-studio" "$mp"
}

test_mount_point_pattern_survives_extended_glob() {
  # The bug this exists for: the options are separated from the path by " (",
  # and with extended_glob on - which tmbox sets globally - an unescaped paren
  # is an unterminated glob group. zsh then rejected the pattern outright with
  # "bad pattern: (*" and the function returned nothing at all.
  setopt local_options extended_glob
  local mp; mp="$(tm_destination_mountpoint tm-studio)"
  assert_nonempty "$mp" "with extended_glob on"
  assert_not_contains "$mp" "(" "the options were stripped"
}

test_absent_share_is_absent_rather_than_wrong() {
  assert_status 1 tm_destination_mountpoint tm-nosuch
}

# --- progress ----------------------------------------------------------------

test_percent_is_a_percentage_of_the_work() {
  tmutil() { print -r -- '    "_raw_Percent" = "0.0424896562451988";' }
  assert_eq "4" "$(tm_percent)"
}

test_percent_clamps_what_tmutil_reports_between_phases() {
  # -1 between phases, and 1 during the opening ones. Unclamped, the first
  # renders as a bar of -100% and the second as a bar that starts at 100 and
  # then falls back to nothing - which is what it did in the guest.
  tmutil() { print -r -- '    "_raw_Percent" = "-1";' }
  assert_eq "0" "$(tm_percent)"
  tmutil() { print -r -- '    "_raw_Percent" = "1";' }
  assert_eq "100" "$(tm_percent)"
  tmutil() { print -r -- 'nothing useful here' }
  assert_eq "0" "$(tm_percent)" "and no number at all is zero, not an error"
}

test_running_and_phase_come_from_the_same_plist() {
  tmutil() {
    print -r -- 'Backup session status:'
    print -r -- '    BackupPhase = Copying;'
    print -r -- '    Running = 1;'
  }
  assert_status 0 tm_running
  assert_eq "Copying" "$(tm_phase)"

  tmutil() { print -r -- '    Running = 0;' }
  assert_status 1 tm_running
}

# --- completion --------------------------------------------------------------

test_completion_is_decided_by_output_not_by_exit_status() {
  # Measured on macOS 26.6: with no backups at all, `tmutil latestbackup`
  # prints an error and still exits 0. Trusting the status made tmbox announce
  # a finished first backup while the destination held nothing but an
  # incomplete bundle.
  tmutil() { print -r -- 'Failed to find any backups found for current machine, error: (null)'; return 0 }
  assert_status 1 tm_latest_backup "an error message is not a backup"

  tmutil() { print -r -- '/Volumes/.timemachine/127.0.0.2/x/tm-studio/x.sparsebundle/2026-09-17-201500' }
  assert_nonempty "$(tm_latest_backup)"
}

# --- which destination a backup is going to (#7) ---------------------------

typeset -g TM_OURS="0A1B2C3D-0000-4000-8000-00000000A11A"
typeset -g TM_LOCAL="0A1B2C3D-0000-4000-8000-00000000D15C"

# Captured on macOS 26.7.1 while a Mac backed up to its local disk, with the
# appliance configured as a second destination.
_tm_status_local_disk() {
  print -r -- 'Backup session status:'
  print -r -- '{'
  print -r -- '    BackupPhase = Copying;'
  print -r -- '    ClientID = "com.apple.backupd";'
  print -r -- '    DestinationID = "0A1B2C3D-0000-4000-8000-00000000D15C";'
  print -r -- '    DestinationMountPoint = "/Volumes/Local Disk";'
  print -r -- '    Running = 1;'
  print -r -- '}'
}

# Each probe answers y or n. Run in a subshell so the stubbed tm_status_plist
# does not leak into later tests, and asserted outside it, because a failure
# recorded inside a subshell never reaches the runner's count.
_tm_probe() {
  local status_fn="$1"; shift
  (
    tm_status_plist() { $status_fn }
    local q
    for q in "$@"; do
      if eval "$q"; then print -rn -- y; else print -rn -- n; fi
    done
  )
}

_tm_status_unattributed() { print -r -- '{ BackupPhase = Starting; Running = 1; }' }
_tm_status_idle()         { print -r -- '{ ClientID = "com.apple.backupd"; Running = 0; }' }

test_a_backup_to_another_disk_is_not_ours() {
  assert_eq "nyyy" "$(_tm_probe _tm_status_local_disk \
      'tm_running $TM_OURS' 'tm_running_elsewhere $TM_OURS' 'tm_running' 'tm_running $TM_LOCAL')" \
    "ours / elsewhere / any / the local disk's own"
}

test_a_backup_with_no_destination_yet_may_be_ours() {
  # The opening phases report no DestinationID. Counted as possibly ours, and
  # never as someone else's.
  assert_eq "yn" "$(_tm_probe _tm_status_unattributed \
      'tm_running $TM_OURS' 'tm_running_elsewhere $TM_OURS')"
}

test_nothing_running_is_nothing_running() {
  assert_eq "nn" "$(_tm_probe _tm_status_idle \
      'tm_running $TM_OURS' 'tm_running_elsewhere $TM_OURS')"
}

# --- the last completed backup, per destination (#7) ------------------------

test_last_snapshot_is_read_for_the_destination_asked_about() {
  local TMBOX_TM_PREFS="$TMBOX_ROOT/test/fixtures/com.apple.TimeMachine.plist"
  local got rc=0
  got="$(TZ=UTC tm_last_snapshot "$TM_LOCAL")" || rc=$?
  assert_eq 0 $rc "the local disk has backups"
  assert_eq "2026-10-03-150649" "$got" "the newest one, as a path-style stamp in local time"

  rc=0; got="$(tm_last_snapshot "$TM_OURS")" || rc=$?
  assert_eq 1 $rc "the appliance has none - and the local disk's must not stand in for it"
  assert_empty "$got"

  rc=0; tm_last_snapshot "00000000-0000-0000-0000-000000000000" >/dev/null || rc=$?
  assert_eq 1 $rc "an unknown destination has none"
}

test_unreadable_preferences_are_not_reported_as_no_backup() {
  local TMBOX_TM_PREFS="/nonexistent/com.apple.TimeMachine.plist"
  local rc=0
  tm_last_snapshot "$TM_OURS" >/dev/null || rc=$?
  assert_eq 2 $rc "unreadable is its own answer, so callers can fall back"
}

# --- Full Disk Access (#6) --------------------------------------------------

test_fda_probe_reads_the_tcc_database_and_nothing_else() {
  # A readable probe is "granted", an unreadable one "denied", a missing one
  # "cannot tell" - which must not block setup on a Mac laid out differently.
  local probe; probe="$(mktemp "${TMPDIR:-/tmp}/tmbox-fda.XXXXXX")"
  print -r -- "SQLite format 3" > "$probe"
  local rc
  rc=0; TMBOX_FDA_PROBE="$probe" fda_granted || rc=$?
  assert_eq 0 $rc "readable"
  chmod 000 "$probe"
  rc=0; TMBOX_FDA_PROBE="$probe" fda_granted || rc=$?
  assert_eq 1 $rc "unreadable"
  rm -f -- "$probe"
  rc=0; TMBOX_FDA_PROBE="$probe" fda_granted || rc=$?
  assert_eq 2 $rc "missing"
}

test_fda_names_the_app_the_user_has_to_find() {
  assert_eq "kitty"    "$(__CFBundleIdentifier=net.kovidgoyal.kitty fda_app_name)" "kitty sets no TERM_PROGRAM"
  assert_eq "Terminal" "$(__CFBundleIdentifier=com.apple.Terminal fda_app_name)"
  assert_contains "$(__CFBundleIdentifier=org.example.Term fda_app_name)" "org.example.Term" "an unknown app is named by its id"
  assert_eq "your terminal app" "$(__CFBundleIdentifier= fda_app_name)"
}

test_history_without_fda_is_unknown_not_empty() {
  # After setup the user may switch FDA off, as setup says they can. Then the
  # history cannot be read - and "none yet" would tell them their backups do
  # not exist.
  local rc
  rc="$(
    TMBOX_TM_PREFS="/nonexistent/prefs.plist"
    tm_latest_backup() { return 1 }
    fda_granted() { return 1 }
    tm_latest_backup_for "$TM_OURS" >/dev/null; print -rn -- $?
  )"
  assert_eq 2 "$rc" "no FDA: cannot tell"
  rc="$(
    TMBOX_TM_PREFS="/nonexistent/prefs.plist"
    tm_latest_backup() { return 1 }
    fda_granted() { return 0 }
    tm_latest_backup_for "$TM_OURS" >/dev/null; print -rn -- $?
  )"
  assert_eq 1 "$rc" "FDA granted and still nothing: there is no backup"
}
