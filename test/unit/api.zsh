#!/bin/zsh
#
# The pure parts of lib/hcloud.zsh, lib/hbox.zsh and lib/http.zsh - the
# selection logic, the password alphabet and the credential handling - against
# fixtures recorded from the live API rather than against the API itself.
#
# Anything that would create a billable resource is deliberately not here. That
# is what the live run is for, and a test suite that can spend money by accident
# is a test suite people stop running.

source "$TMBOX_ROOT/lib/answers.zsh"
source "$TMBOX_ROOT/lib/log.zsh"
source "$TMBOX_ROOT/lib/ui.zsh"
source "$TMBOX_ROOT/lib/json.zsh"
source "$TMBOX_ROOT/lib/http.zsh"
source "$TMBOX_ROOT/lib/hcloud.zsh"
source "$TMBOX_ROOT/lib/hbox.zsh"

typeset -g TYPES="$(cat "$TMBOX_ROOT/test/fixtures/storage_box_types.json")"

# --- capacity selection -----------------------------------------------------

test_type_for_bytes_picks_the_smallest_that_fits() {
  # Selected by size, not by a hardcoded name, so a renamed or newly added tier
  # cannot silently select the wrong one.
  assert_eq "bx11" "$(hb_type_for_bytes "$TYPES" $(( 1024 ** 4 )))"        "1 TiB"
  assert_eq "bx21" "$(hb_type_for_bytes "$TYPES" $(( 2 * 10**12 )))"       "2 TB"
  assert_eq "bx21" "$(hb_type_for_bytes "$TYPES" $(( 4 * 10**12 )))"       "4 TB"
  assert_eq "bx31" "$(hb_type_for_bytes "$TYPES" $(( 6 * 10**12 )))"       "6 TB"
  assert_eq "bx41" "$(hb_type_for_bytes "$TYPES" $(( 15 * 10**12 )))"      "15 TB"
}

test_type_for_bytes_is_exact_at_the_boundary() {
  # bx11 is exactly 1 TiB. Asking for exactly that must fit, and one byte more
  # must move up a tier - an off-by-one here sells the user a box that is
  # marginally too small and fails months later when it fills.
  local -i bx11; bx11=$(hb_type_size "$TYPES" bx11)
  assert_eq "bx11" "$(hb_type_for_bytes "$TYPES" $bx11)"         "exactly bx11's size"
  assert_eq "bx21" "$(hb_type_for_bytes "$TYPES" $(( bx11 + 1 )))" "one byte more"
}

test_type_for_bytes_refuses_rather_than_guesses() {
  assert_empty "$(hb_type_for_bytes "$TYPES" $(( 100 * 10**12 )))" "larger than any tier"
}

test_type_price_and_size_are_read_per_location() {
  assert_matches "$(hb_type_price "$TYPES" bx21 fsn1)" '^10\.9' "bx21 in fsn1"
  assert_nonempty "$(hb_type_size "$TYPES" bx11)"
  assert_empty "$(hb_type_price "$TYPES" bx21 nowhere)" "an unknown location"
  assert_empty "$(hb_type_price "$TYPES" bx99 fsn1)"    "an unknown type"
}

# --- the Storage Box password ----------------------------------------------

test_password_satisfies_hetzners_policy() {
  # Rejected with 422 without all four classes.
  local -i i
  for i in {1..20}; do
    local pw="$(hb_password)"
    assert_matches "$pw" '[A-Z]'      "an upper-case letter"
    assert_matches "$pw" '[a-z]'      "a lower-case letter"
    assert_matches "$pw" '[0-9]'      "a digit"
    assert_matches "$pw" '[^A-Za-z0-9]' "a special character"
  done
}

test_password_avoids_characters_that_break_the_mount() {
  # A '%' breaks mount_smbfs on macOS, which reads it as a percent-escape. The
  # same argument covers everything else significant in a URL, a CIFS
  # credentials file or a shell command line.
  local -i i
  for i in {1..20}; do
    local pw="$(hb_password)"
    assert_matches "$pw" '^[A-Za-z0-9-]+$' "only letters, digits and a hyphen"
  done
}

test_password_is_long_and_not_repeated() {
  local a b
  a="$(hb_password)"; b="$(hb_password)"
  assert_eq 28 ${#a} "length"
  assert_ne "$a" "$b" "two calls differ"
}

# --- credential handling ----------------------------------------------------

test_curl_config_escapes_and_omits_when_empty() {
  local out; out="$(_http_config 'tok123')"
  assert_contains "$out" 'header = "Authorization: Bearer tok123"'
  assert_empty "$(_http_config '')" "no token means no header line at all"

  # curl's config format is quoted with backslash escapes, so a credential
  # containing either must not be able to terminate the line.
  out="$(_http_config 'a"b\c')"
  assert_contains "$out" 'a\"b\\c'
}

# --- redaction --------------------------------------------------------------

test_log_redacts_registered_secrets() {
  TMBOX_LOG_SECRETS=()
  log_secret "tok_abcdefghijklmnop"
  local out; out="$(log_redact 'using tok_abcdefghijklmnop for the request')"
  assert_no_secret "$out" "tok_abcdefghijklmnop"
  assert_contains  "$out" "[REDACTED]"
}

test_log_redaction_is_literal_not_a_pattern() {
  # A password can contain any character a pattern would treat as syntax. If
  # this were a glob or a regex, a secret containing * or [ would either fail to
  # match - leaking - or match far too much.
  TMBOX_LOG_SECRETS=()
  log_secret 'p*ss[w]ord.123'
  local out; out="$(log_redact 'the value p*ss[w]ord.123 and also password123')"
  assert_no_secret "$out" 'p*ss[w]ord.123'
  assert_contains  "$out" "password123"  "an unrelated value is untouched"
}

test_log_ignores_short_secrets() {
  # Masking every occurrence of a three-character string would shred the log,
  # and nothing tmbox generates is that short.
  TMBOX_LOG_SECRETS=()
  log_secret "abc"
  assert_eq "value abc stays" "$(log_redact 'value abc stays')"
}

# --- audit ------------------------------------------------------------------

test_billable_list_covers_what_outlives_a_server() {
  # The classes that keep billing after the machine is gone are the ones a
  # teardown forgets. Each of these has to be in the audit.
  local -a want=(servers volumes primary_ips floating_ips firewalls
                 networks load_balancers placement_groups certificates)
  local r
  for r in $want; do
    (( ${HC_BILLABLE[(Ie)$r]} )) \
      || fail "$r is missing from the teardown audit"
  done
}
