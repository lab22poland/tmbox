#!/bin/zsh
#
# cmd/destroy.zsh - what a teardown leaves behind on this Mac (#13).
#
# The Hetzner half is audited against the live API on every real destroy. The
# Mac half had no such check, and left both the Time Machine destination and
# credential files it did not know the names of.

source "$TMBOX_ROOT/lib/answers.zsh"
source "$TMBOX_ROOT/lib/log.zsh"
source "$TMBOX_ROOT/lib/ui.zsh"
source "$TMBOX_ROOT/lib/json.zsh"
source "$TMBOX_ROOT/lib/state.zsh"
source "$TMBOX_ROOT/lib/secrets.zsh"
source "$TMBOX_ROOT/lib/sshx.zsh"
source "$TMBOX_ROOT/lib/macos.zsh"
source "$TMBOX_ROOT/lib/transport.zsh"
source "$TMBOX_ROOT/lib/preflight.zsh"
source "$TMBOX_ROOT/cmd/destroy.zsh"

ui_init --no-tty-ok
typeset -g UI_LOG="$TMBOX_STATE_DIR/ui.out"
typeset -g DEST="0A1B2C3D-0000-4000-8000-00000000A11A"

_fresh() {
  rm -rf -- "$TMBOX_STATE_DIR"
  state_init >/dev/null 2>&1
  kc_init
  : > "$UI_LOG"
  exec {TMBOX_UI_FD}>>"$UI_LOG"
  : > "$CALLS"
  state_set destination_id "$DEST" mac_name studio >/dev/null 2>&1
}

typeset -g CALLS="$TMBOX_STATE_DIR/calls"
# What the stubs record goes to a file: the calls under test send their own
# output to /dev/null, and a stub's stdout with it.
_calls() { cat "$CALLS" 2>/dev/null }
# The UI wraps long lines, so a command it prints may be split across two.
_said() { local t; t="$(cat "$UI_LOG")"; print -r -- "${(j: :)${=t}}" }

_listed() { print -r -- "<plist><dict><key>ID</key><string>${DEST}</string></dict></plist>" }

test_the_destination_is_removed_with_the_appliance() {
  _fresh
  local ran
  ran="$(
    tm_destinations_plist() { _listed }
    fda_granted()    { return 0 }
    priv_prime()     { return 0 }
    priv_run_quiet() { print -rn -- "$*" >> "$CALLS" }
    destroy_tm_destination >/dev/null
  )"
  assert_eq "/usr/bin/tmutil removedestination ${DEST}" "$(_calls)"
}

test_without_full_disk_access_the_command_is_given_not_attempted() {
  # removedestination needs FDA and fails with tmutil's catch-all exit code.
  # A teardown must not stop on it; the user gets the exact command instead.
  _fresh
  local ran
  ran="$(
    tm_destinations_plist() { _listed }
    fda_granted()    { return 1 }
    priv_prime()     { print -rn -- "PRIMED " >> "$CALLS" }
    priv_run_quiet() { print -rn -- "RAN " >> "$CALLS" }
    destroy_tm_destination >/dev/null
  )"
  assert_empty "$(_calls)" "nothing attempted"
  assert_contains "$(_said)" "sudo tmutil removedestination ${DEST}"
}

test_a_destination_already_gone_is_not_touched() {
  _fresh
  local ran
  ran="$(
    tm_destinations_plist() { print -r -- "<plist></plist>" }
    fda_granted()    { return 0 }
    priv_prime()     { print -rn -- "PRIMED " >> "$CALLS" }
    priv_run_quiet() { print -rn -- "RAN " >> "$CALLS" }
    destroy_tm_destination >/dev/null
  )"
  assert_empty "$(_calls)"
}

test_credentials_removed_means_all_of_them() {
  # Only the current kinds were deleted, so a file an older version or a test
  # run had written survived "credentials removed".
  _fresh
  kc_set samba-password "x" >/dev/null 2>&1
  print -rn -- "left over" > "$TMBOX_SECRET_DIR/timemachine-password"
  kc_delete_all
  assert_status 1 test -e "$TMBOX_SECRET_DIR"
}

test_zz_cleanup() {
  rm -rf -- "$TMBOX_STATE_DIR"
}
