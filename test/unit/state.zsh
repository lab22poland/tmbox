#!/bin/zsh
#
# lib/state.zsh and lib/secrets.zsh - what tmbox remembers, and where.
#
# The division is the thing under test: identifiers in a JSON file that will end
# up in support mails and migrations, credentials in mode-600 files and nowhere
# else. Both halves have a way of failing quietly, and both quiet failures are
# covered here.

source "$TMBOX_ROOT/lib/answers.zsh"
source "$TMBOX_ROOT/lib/log.zsh"
source "$TMBOX_ROOT/lib/ui.zsh"
source "$TMBOX_ROOT/lib/json.zsh"
source "$TMBOX_ROOT/lib/state.zsh"
source "$TMBOX_ROOT/lib/secrets.zsh"
source "$TMBOX_ROOT/lib/sshx.zsh"

ui_init --no-tty-ok

# A scratch state directory per suite run, so nothing here can touch a real
# installation on the machine running the tests.
typeset -g SCRATCH="${TMPDIR:-/tmp}/tmbox-test-$$"
TMBOX_STATE_DIR="$SCRATCH"
TMBOX_STATE_FILE="$SCRATCH/state.json"
SSH_KEY_DIR="$SCRATCH/keys"
SSH_KNOWN_HOSTS="$SCRATCH/known_hosts"

_fresh() { rm -rf -- "$SCRATCH"; state_init }

# --- state ------------------------------------------------------------------

test_state_round_trips_awkward_values() {
  _fresh
  state_set name "tmbox-studio" ip "1.2.3.4"
  assert_eq "tmbox-studio" "$(state_get name)"
  assert_eq "1.2.3.4"      "$(state_get ip)"
  # JSON is the format precisely so that these survive. The KEY=value file this
  # replaced mangled every one of them.
  state_set note $'two\nlines' quoted 'he said "hi"' unicode 'łódź ✓'
  assert_eq $'two\nlines'   "$(state_get note)"
  assert_eq 'he said "hi"'  "$(state_get quoted)"
  assert_eq 'łódź ✓'        "$(state_get unicode)"
}

test_state_default_and_absence() {
  _fresh
  assert_empty "$(state_get nothing)"
  assert_eq "fallback" "$(state_get nothing fallback)"
  assert_status 1 state_has nothing
  state_set something x
  assert_status 0 state_has something
}

test_state_unset_and_clear() {
  _fresh
  state_set a 1 b 2
  state_unset a
  assert_empty "$(state_get a)"
  assert_eq "2" "$(state_get b)" "unsetting one key leaves the others"
  state_clear
  assert_empty "$(state_get b)"
}

test_state_recovers_from_a_corrupt_file() {
  _fresh
  state_set appliance_id 12345
  # A truncated write, an editor, a half-finished sync. The run must not die on
  # it: the resources are still findable by their labels, so the state is a
  # convenience and losing it is survivable - but losing the run is not.
  print -r -- 'this is not json' > "$TMBOX_STATE_FILE"
  state_init
  assert_empty "$(state_get appliance_id)" "started clean"
  local -a saved=( "$SCRATCH"/state.json.broken.*(N) )
  assert_eq 1 ${#saved} "the damaged file was kept rather than deleted"
}

test_state_is_not_world_readable() {
  _fresh
  state_set appliance_id 1
  # It names the user's server and their Storage Box. Not credentials, and not
  # other users' business either.
  assert_matches "$(stat -f '%OLp' "$TMBOX_STATE_FILE")" '^6[0-4]0$' "state file mode"
  assert_eq "700" "$(stat -f '%OLp' "$SCRATCH")" "state directory mode"
}

test_state_audit_catches_a_planted_credential() {
  _fresh
  state_set appliance_id 12345 server_ip 1.2.3.4
  assert_status 0 state_audit_for_secrets "a clean file"

  # The enforcement half of "no secrets in the state file". A rule with no
  # check is a comment, and this is the check.
  state_set hetzner_token "$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | dd bs=1 count=64 2>/dev/null)"
  local found; found="$(state_audit_for_secrets)"
  assert_contains "$found" "hetzner_token" "caught by name and by shape"

  state_unset hetzner_token
  state_set innocuous "$(print -rn -- '-----BEGIN OPENSSH PRIVATE KEY-----')"
  found="$(state_audit_for_secrets)"
  assert_contains "$found" "innocuous" "caught by shape even with a harmless name"
}

# --- credentials -------------------------------------------------------------

test_secrets_round_trip_every_credential_kind() {
  _fresh
  local kind
  for kind in $TMBOX_CREDENTIAL_KINDS; do
    local value="value-for-${kind}-with-\"quotes\"-and-\$pecials and spaces"
    kc_set "$kind" "$value" >/dev/null 2>&1 || { fail "could not store $kind"; continue }
    assert_eq "$value" "$(kc_get "$kind")" "$kind"
  done
}

test_secrets_handle_what_the_keychain_could_not() {
  _fresh
  # The keychain truncated at 128 characters and could not hold a multi-line
  # value at all, which is why the SSH keys were never in it. Files have neither
  # limit, so the split that caused it no longer exists.
  local long; long="$(LC_ALL=C tr -dc 'a-z' </dev/urandom | dd bs=1 count=2000 2>/dev/null)"
  kc_set samba-password "$long" >/dev/null 2>&1 || fail "a long value was refused"
  assert_eq "$long" "$(kc_get samba-password)" "2000 characters"

  local key=$'-----BEGIN OPENSSH PRIVATE KEY-----\nabc\ndef\n-----END OPENSSH PRIVATE KEY-----'
  kc_set zfs-passphrase "$key" >/dev/null 2>&1 || fail "a multi-line value was refused"
  assert_eq "$key" "$(kc_get zfs-passphrase)" "multi-line"
}

test_secrets_report_a_missing_item_rather_than_an_empty_one() {
  _fresh
  kc_delete samba-password
  assert_status 1 kc_get samba-password
  assert_status 1 kc_has samba-password
}

test_secrets_are_never_world_readable() {
  _fresh
  kc_set samba-password "hunter2hunter2" >/dev/null 2>&1
  # Written under umask 077 in a subshell rather than created and then chmod-ed:
  # the second form leaves a window in which the file is readable, and a window
  # is all it takes.
  assert_eq "600" "$(stat -f '%OLp' "$(kc_path samba-password)")" "file mode"
  assert_eq "700" "$(stat -f '%OLp' "$TMBOX_SECRET_DIR")" "directory mode"
  assert_status 0 kc_audit "a correctly-permissioned store passes the audit"
}

test_secrets_audit_catches_a_widened_file() {
  _fresh
  kc_set samba-password "hunter2hunter2" >/dev/null 2>&1
  # An unusual umask, a restore from a backup, or a copy onto a shared volume
  # can all widen these, and nothing else in the system would notice.
  chmod 0644 "$(kc_path samba-password)"
  local found; found="$(kc_audit)"
  assert_contains "$found" "samba-password" "the widened file is named"
  assert_contains "$found" "644"
}

test_secrets_cannot_escape_their_directory() {
  _fresh
  # Nothing passes a user-supplied kind today. This is what keeps that safe if
  # something ever does.
  local p; p="$(kc_path '../../etc/passwd')"
  assert_not_contains "$p" ".."
  assert_contains "$p" "$TMBOX_SECRET_DIR"
}

test_secrets_delete_removes_the_value() {
  _fresh
  kc_set samba-password "hunter2hunter2" >/dev/null 2>&1
  local file; file="$(kc_path samba-password)"
  kc_delete samba-password
  assert_status 1 test -f "$file"
  assert_status 1 kc_has samba-password
}

test_secrets_are_registered_for_redaction_when_stored() {
  _fresh
  TMBOX_LOG_SECRETS=()
  kc_set samba-password "leakcanary12345" >/dev/null 2>&1
  local out; out="$(log_redact 'the value leakcanary12345 appears here')"
  assert_no_secret "$out" "leakcanary12345" "storing a secret registers it"
}

# --- ssh --------------------------------------------------------------------

test_ssh_keys_are_generated_once_and_kept() {
  _fresh
  local first; first="$(ssh_keygen tunnel tmbox-test)"
  assert_file "$first"
  assert_file "${first}.pub"
  assert_eq "600" "$(stat -f '%OLp' "$first")" "private key mode"

  local before; before="$(cat -- "$first")"
  ssh_keygen tunnel tmbox-test >/dev/null
  # Regenerating would orphan the public half already installed on the
  # appliance and lock the user out of their own machine.
  assert_eq "$before" "$(cat -- "$first")" "a second call reuses the key"
}

test_ssh_fingerprint_is_the_form_hetzner_indexes_by() {
  _fresh
  ssh_keygen admin tmbox-test >/dev/null
  local fp; fp="$(ssh_fingerprint_md5 admin)"
  # Hetzner looks keys up by MD5, colon-separated, with no "MD5:" prefix.
  assert_matches "$fp" '^([0-9a-f]{2}:){15}[0-9a-f]{2}$' "md5 fingerprint shape"
}

test_authorized_keys_line_enables_the_forwarding_restrict_turned_off() {
  local line; line="$(ssh_authorized_keys_line 'ssh-ed25519 AAAAC3Nz test')"

  # Verified against sshd(8) on macOS 26 (OpenSSH 10.3): `restrict` disables
  # port forwarding along with everything else, and `port-forwarding` is what
  # turns just that back on. `restrict,permitopen=...` without it permits
  # nothing at all - the tunnel would simply never open.
  assert_contains "$line" "restrict,"
  assert_contains "$line" "port-forwarding"
  assert_contains "$line" 'permitopen="127.0.0.1:445"'
  assert_contains "$line" 'command=""'
  assert_contains "$line" "ssh-ed25519 AAAAC3Nz test"
}

test_ssh_opts_pin_the_host_rather_than_trusting_anything() {
  _fresh
  ssh_keygen admin tmbox-test >/dev/null
  local opts; opts="$(ssh_opts admin)"
  # accept-new, never no. The appliance's address is a Hetzner primary IP that
  # has belonged to someone else before and will again, so "trust any key"
  # means trusting whoever holds it next.
  assert_contains     "$opts" "StrictHostKeyChecking=accept-new"
  assert_not_contains "$opts" "StrictHostKeyChecking=no"
  assert_contains     "$opts" "BatchMode=yes"       "a prompt must fail, not hang"
  assert_contains     "$opts" "IdentitiesOnly=yes"  "do not offer other keys"
  assert_contains     "$opts" "$SSH_KNOWN_HOSTS"    "a private known_hosts"
}

test_zz_cleanup() {
  rm -rf -- "$SCRATCH"
  assert_status 1 test -d "$SCRATCH"
}
