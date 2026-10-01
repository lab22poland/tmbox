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
