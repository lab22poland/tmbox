#!/bin/zsh
#
# lib/answers.zsh - the layer that lets every prompt be answered in advance.

source "$TMBOX_ROOT/lib/answers.zsh"

# Each test starts from an empty store; the library keeps global state on
# purpose, so the tests have to reset it rather than inherit it.
_reset() {
  TMBOX_ANS=()
  TMBOX_ANSSRC=()
  TMBOX_NONINTERACTIVE=0
}

test_norm_folds_to_one_canonical_form() {
  _reset
  # A flag, an environment variable and a file entry must land on the same key
  # without each caller having to agree on a spelling.
  assert_eq "STORAGE_BOX" "$(ans_norm 'storage-box')" "hyphen"
  assert_eq "STORAGE_BOX" "$(ans_norm 'Storage Box')" "space and case"
  assert_eq "STORAGE_BOX" "$(ans_norm 'STORAGE_BOX')" "already canonical"
  assert_eq "CAPACITY"    "$(ans_norm 'capacity!')"   "trailing punctuation trimmed"
  assert_eq "STORAGE_BOX" "$(ans_norm 'storage--box')" "runs collapsed"
  assert_eq "CAPACITY"    "$(ans_norm '  capacity  ')" "surrounding space trimmed"
}

test_flag_is_the_inverse_of_norm() {
  _reset
  # ans_require prints this flag in an error message. If it names a flag that
  # does not exist, the error is worse than none.
  assert_eq "--storage-box" "$(ans_flag 'storage-box')"
  assert_eq "--storage-box" "$(ans_flag 'STORAGE_BOX')"
  assert_eq "--capacity"    "$(ans_flag 'capacity')"
}

test_set_get_has() {
  _reset
  assert_status 1 ans_has CAPACITY
  ans_set CAPACITY "2TB" "flag"
  assert_status 0 ans_has CAPACITY
  assert_eq "2TB"  "$(ans_get CAPACITY)"
  assert_eq "flag" "$(ans_source CAPACITY)"
  # Reached by any spelling of the same key.
  assert_eq "2TB" "$(ans_get 'capacity')" "lower case lookup"
}

test_empty_value_is_still_an_answer() {
  _reset
  # "" is a legitimate answer - an empty label, a skipped optional field - and
  # must not be confused with "not answered".
  ans_set LABEL "" "flag"
  assert_status 0 ans_has LABEL
  assert_empty "$(ans_get LABEL)"
}

test_from_file_parses_and_respects_precedence() {
  _reset
  local f="${TMPPREFIX:-/tmp/tmbox}-answers.$$"
  cat > "$f" <<'EOF'
# a comment
CAPACITY=5TB
  REGION  =fsn1
LABEL=

PASSWORD=pa=ss#word with spaces
EOF
  ans_set CAPACITY "2TB" "flag"     # a flag already answered this
  ans_from_file "$f"

  assert_eq "2TB"  "$(ans_get CAPACITY)" "a flag outranks the file"
  assert_eq "flag" "$(ans_source CAPACITY)"
  assert_eq "fsn1" "$(ans_get REGION)"   "whitespace around the key"
  assert_status 0 ans_has LABEL          "an empty value is an answer"
  # Everything after the first = is the value, verbatim: a password may well
  # contain =, # or a space, and a quoting scheme here would mangle it.
  assert_eq 'pa=ss#word with spaces' "$(ans_get PASSWORD)" "value taken literally"
  rm -f "$f"
}

test_from_env() {
  _reset
  TMBOX_ANSWER_REGION=hel1 ans_from_env
  assert_eq "hel1"        "$(ans_get REGION)"
  assert_eq "environment" "$(ans_source REGION)"
}

test_secrets_are_recognised_by_name() {
  _reset
  assert_status 0 ans_is_secret HETZNER_TOKEN
  assert_status 0 ans_is_secret SMB_PASSWORD
  assert_status 0 ans_is_secret ZFS_PASSPHRASE
  assert_status 0 ans_is_secret CLIENT_PRIVATE_KEY
  assert_status 0 ans_is_secret 'api-token'
  assert_status 1 ans_is_secret CAPACITY
  assert_status 1 ans_is_secret REGION
}

test_secrets_are_recognised_under_default_options() {
  _reset
  # Regression. This was first written with a (#i) glob flag, which needs
  # extended_glob; with that option off the pattern matched nothing and
  # ans_dump printed a live API token in plain text. The check must hold
  # whatever options the caller happens to have set.
  local out
  out="$(/bin/zsh -c '
    emulate -L zsh
    unsetopt extended_glob
    source "$1/lib/answers.zsh"
    ans_set HETZNER_TOKEN "tok_livesecret1234567890" flag
    ans_dump
  ' _ "$TMBOX_ROOT" 2>&1)"

  assert_no_secret "$out" "tok_livesecret1234567890" "ans_dump with extended_glob off"
  assert_contains  "$out" "HETZNER_TOKEN=[hidden]"   "masked instead"
}

test_dump_masks_secrets_and_lists_sources() {
  _reset
  ans_set CAPACITY      "2TB"                   "flag"
  ans_set HETZNER_TOKEN "tok_abcdef1234567890"  "keychain"
  local out; out="$(ans_dump)"

  assert_contains  "$out" "CAPACITY=2TB (flag)"
  assert_contains  "$out" "HETZNER_TOKEN=[hidden] (keychain)"
  assert_no_secret "$out" "tok_abcdef1234567890"
}
