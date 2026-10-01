#!/bin/zsh
#
# cmd/tunnel.zsh - the daemon description, and the helper it runs.
#
# Neither of these can be exercised for real without root, so what is tested
# here is everything that happens *before* launchd is involved: that the
# rendered job is a valid plist, that no placeholder survives into it, that the
# values it carries are the ones measured to work, and that the helper refuses
# a configuration it cannot honour. A malformed plist is rejected by launchd
# with a message that helps nobody, so it has to be caught here.

source "$TMBOX_ROOT/lib/answers.zsh"
source "$TMBOX_ROOT/lib/log.zsh"
source "$TMBOX_ROOT/lib/ui.zsh"
source "$TMBOX_ROOT/lib/json.zsh"
source "$TMBOX_ROOT/lib/state.zsh"
source "$TMBOX_ROOT/lib/secrets.zsh"
source "$TMBOX_ROOT/lib/sshx.zsh"
source "$TMBOX_ROOT/lib/macos.zsh"
source "$TMBOX_ROOT/cmd/tunnel.zsh"

ui_init --no-tty-ok

typeset -g SCRATCH="${TMPDIR:-/tmp}/tmbox-tunnel-test-$$"

# Tests run in alphabetical order, so the scratch directory is (re)created by
# whichever test needs it rather than once at the top - where the cleanup test
# would have removed it before the first real test ran.
_fresh() { mkdir -p -- "$SCRATCH" }

# --- the job description ----------------------------------------------------

test_rendered_plist_is_valid_and_complete() {
  _fresh
  local out="$SCRATCH/tunnel.plist"
  tunnel_render_plist "203.0.113.9" > "$out"

  # launchd's own complaint about a malformed job names nothing actionable, so
  # the check has to happen on this side. No trailing message here:
  # assert_status passes everything after the expected status to the command,
  # and a message would arrive as a second file for plutil to lint.
  assert_status 0 plutil -lint -- "$out"

  local body; body="$(cat -- "$out")"
  # A surviving placeholder would be a daemon that runs ssh against a host
  # called "@HOST@" and reports a resolution failure at boot, forever. Checked
  # token by token rather than by looking for "@", because the template's own
  # comment mentions @TOKENS@ and that mention is meant to survive.
  local token
  for token in @LABEL@ @HELPER@ @HOST@ @USER@ @KEY@ @KNOWN_HOSTS@ @BIND@ @LOG@; do
    assert_not_contains "$body" "$token" "substituted ${token}"
  done
  assert_contains "$body" "203.0.113.9"
  assert_contains "$body" "$TMBOX_TUNNEL_LABEL"
  assert_contains "$body" "${TMBOX_SYS_DIR}/tmbox-tunnel"
  assert_contains "$body" "${TMBOX_SYS_DIR}/tunnel_key"
}

test_rendered_plist_keeps_the_job_alive_and_throttled() {
  _fresh
  local out="$SCRATCH/tunnel.plist"
  tunnel_render_plist "203.0.113.9" > "$out"

  # Read back through plutil rather than grepped: these are the two keys that
  # decide whether a dropped connection comes back, and a typo in either is
  # invisible in a passing grep.
  local json; json="$(plutil -convert json -o - -- "$out")"
  assert_eq "true" "$(print -r -- "$json" | jq -r '.KeepAlive')"
  assert_eq "true" "$(print -r -- "$json" | jq -r '.RunAtLoad')"
  assert_eq "30"   "$(print -r -- "$json" | jq -r '.ThrottleInterval')"
}

test_rendered_plist_binds_the_port_time_machine_insists_on() {
  _fresh
  local out="$SCRATCH/tunnel.plist"
  tunnel_render_plist "203.0.113.9" > "$out"
  local -a args
  args=( ${(f)"$(plutil -convert json -o - -- "$out" | jq -r '.ProgramArguments[]')"} )
  local flat="${(j: :)args}"

  # Measured in the Tart guest on macOS 26.6: tmutil setdestination validates a
  # network destination by opening its own SMB session, and that session ignores
  # a port in the URL. 127.0.0.2:445 is accepted; 127.0.0.2:4445 fails with
  # authentication error 80. So the bind address must be the alias and the port
  # must be 445, which is the whole reason this job needs root.
  assert_contains "$flat" "--bind ${TM_LOOPBACK_ALIAS}"
  assert_contains "$flat" "--host 203.0.113.9"
  assert_contains "$flat" "--user tmtunnel"
  # No --local-port: the helper's default is 445 and nothing may override it
  # here, because a destination on any other port cannot be set at all.
  assert_not_contains "$flat" "--local-port"
}

test_rendered_plist_carries_no_credential() {
  # The job description is root-owned but world-readable, and it ends up in
  # sysdiagnose archives and support mails. The key it names is a path; the key
  # itself is next door at 0600.
  local body; body="$(tunnel_render_plist "203.0.113.9")"
  assert_not_contains "$body" "PRIVATE KEY"
  assert_not_contains "$body" "password"
  assert_not_contains "$body" "passphrase"
}

test_payloads_are_present_in_this_build() {
  # In the built single file these come from base64 globals; in a checkout they
  # come from macos/. Either way a missing one must be a failure here rather
  # than an empty file installed as a daemon.
  assert_nonempty "$(tunnel_payload_bin)"   "the helper payload"
  assert_nonempty "$(tunnel_payload_plist)" "the job payload"
}

# --- the helper -------------------------------------------------------------

test_helper_refuses_an_incomplete_configuration() {
  _fresh
  local helper="$TMBOX_ROOT/macos/tmbox-tunnel"
  assert_file "$helper"

  # 78 is EX_CONFIG. The point is not the number but that it fails fast and
  # says which argument is missing: launchd will restart this job every thirty
  # seconds, and a silent failure would be thirty seconds of nothing in the log.
  local out
  out="$(/bin/zsh "$helper" 2>&1)"; assert_status 78 /bin/zsh "$helper"
  assert_contains "$out" "--host"

  out="$(/bin/zsh "$helper" --host 203.0.113.9 2>&1)"
  assert_contains "$out" "--key"

  out="$(/bin/zsh "$helper" --host 203.0.113.9 --key "$SCRATCH/nope" 2>&1)"
  assert_contains "$out" "cannot read"
}

test_helper_parses_cleanly() {
  assert_status 0 /bin/zsh -n -- "$TMBOX_ROOT/macos/tmbox-tunnel"
}

test_zz_cleanup() {
  rm -rf -- "$SCRATCH"
  assert_status 1 test -d "$SCRATCH"
}
