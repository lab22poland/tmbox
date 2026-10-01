#!/bin/zsh
#
# Properties of the source itself, rather than of anything it computes.
#
# Both of these are promises tmbox makes in prose elsewhere, and prose does not
# fail a build. They are cheap to state as tests and expensive to discover by
# hand: the first went stale twice already (see the note above
# TMBOX_SETUP_FLAGS), and the second is the kind of thing that is noticed when
# a password turns up in someone's `ps` output.

source "$TMBOX_ROOT/lib/answers.zsh"

# --- every prompt can be answered without a human ---------------------------
#
# The rule: anything that stops to ask
# must also be settable from the command line, so the whole flow can run
# unattended. Confirmations are covered collectively by --yes; questions that
# take a value need their own flag.
#
# This is enforced by scanning the source rather than by a registry, because a
# registry is exactly the thing that goes stale - the prompt is added at the
# call site, so the call site is what has to be checked.

# _prompt_keys <kind> - the keys passed to ui_ask/ui_ask_secret/ui_menu (values)
# or to ui_confirm (confirmations), across every file that runs.
_prompt_keys() {
  local -a files=("$TMBOX_ROOT"/cmd/*.zsh(N) "$TMBOX_ROOT"/lib/*.zsh(N) "$TMBOX_ROOT"/bin/*.zsh(N))
  local pattern
  case "$1" in
    value)   pattern='ui_ask|ui_ask_secret|ui_menu' ;;
    confirm) pattern='ui_confirm' ;;
  esac
  # The key is the first argument and is always a bare upper-case literal at
  # the call sites; a computed key would defeat this check and is worth
  # failing on, which a non-match does.
  grep -hoE "\b(${pattern}) +[A-Z][A-Z0-9_]*" -- "${files[@]}" 2>/dev/null \
    | awk '{print $NF}' | sort -u
}

test_every_question_that_takes_a_value_has_a_flag() {
  local -a flags=()
  local entry key
  for entry in $TMBOX_SETUP_FLAGS; do
    # The flag name is kebab-case; ans_norm is what maps it onto the prompt key.
    flags+=("$(ans_norm "${entry%%:*}")")
  done

  local -a missing=()
  for key in $(_prompt_keys value); do
    (( ${flags[(Ie)$key]} )) || missing+=("$key")
  done

  assert_empty "${missing[*]}" \
    "prompts with no --flag to answer them (add one to TMBOX_SETUP_FLAGS)"
}

test_every_confirmation_is_covered_by_yes_or_its_own_flag() {
  # --yes answers confirmations wholesale. The one deliberate exception is
  # deleting the Storage Box, which --yes must never answer, so it carries its
  # own flag - and that flag has to keep existing for this to hold.
  local parser; parser="$(<"$TMBOX_ROOT/bin/tmbox.zsh")"
  assert_contains "$parser" "TMBOX_ASSUME_YES" "--yes must still exist"
  assert_contains "$parser" "ans_set CONFIRM_DELETE_BOX" \
    "deleting the Storage Box needs its own flag, never --yes"

  # And every confirmation the code asks for must be one or the other.
  local key
  for key in $(_prompt_keys confirm); do
    if [[ "$key" == "CONFIRM_DELETE_BOX" ]]; then continue; fi
    assert_contains "$parser" "TMBOX_ASSUME_YES" "$key is covered by --yes"
  done
}

test_the_flag_list_is_not_empty_so_the_scan_means_something() {
  # A regex that silently matched nothing would make both tests above pass.
  assert_nonempty "$(_prompt_keys value)"   "no value prompts found - check the scan"
  assert_nonempty "$(_prompt_keys confirm)" "no confirmations found - check the scan"
}

# --- no credential is ever passed in argv -----------------------------------
#
# Everything in argv is world-readable in `ps` for as long as the process runs,
# for every user on the machine. This is not theoretical: during the 2026-09-17
# run a Samba password appeared in the test guest's `ps` through a hand-typed
# `mount_smbfs` URL, and the credential had to be treated as burned. tmbox
# itself did not do it - these tests are what keep that true.

test_the_hetzner_token_reaches_curl_on_stdin() {
  # Comments stripped first. lib/http.zsh documents the mistake it avoids by
  # writing it out in full, so a check against the raw file matches the
  # explanation and fails on a correct file - which is what happened the first
  # time this was written.
  local http; http="$(grep -vE '^[[:space:]]*#' -- "$TMBOX_ROOT/lib/http.zsh")"

  # -K - is the whole mechanism: the Authorization header travels in a config
  # file read from a pipe.
  assert_contains "$http" '-K -' "curl must read its config from stdin"
  assert_not_contains "$http" '-H "Authorization' "header must not be in argv"
  assert_not_contains "$http" "-H 'Authorization" "header must not be in argv"
}

test_no_source_line_puts_a_secret_on_a_command_line() {
  local -a files=("$TMBOX_ROOT"/cmd/*.zsh(N) "$TMBOX_ROOT"/lib/*.zsh(N) "$TMBOX_ROOT"/bin/*.zsh(N))

  # Any expansion of a secret-looking variable that sits after a command rather
  # than inside a redirection or an assignment. Deliberately blunt: a false
  # positive costs a comment, a false negative costs a credential.
  local -a hits=()
  hits=("${(@f)$(grep -nE '\$\{?[A-Za-z_]*(token|TOKEN|password|PASSWORD|passphrase|PASSPHRASE|secret|SECRET)[A-Za-z_]*\}?' -- "${files[@]}" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+: *#' \
    | grep -vE '(print|printf) ' \
    | grep -vE '^[^:]+:[0-9]+: *(local|typeset|export)? *[A-Za-z_]+=' \
    | grep -vE '<<<|<\(|\|' \
    | grep -E '(curl|ssh|mount_smbfs|expect|security|zfs|smbutil) ')}")

  assert_empty "${hits[*]}" "secret expanded into a command's arguments"
}

test_the_secret_scan_can_actually_fail() {
  # Guards the test above: if the pattern stopped matching, it would pass on
  # anything. Proven against a line that is exactly the mistake it looks for.
  local bad='mount_smbfs "//user:${password}@host/share" /mnt'
  assert_matches "$bad" '(token|password|passphrase|secret)' "the pattern still matches"
}

# --- a path with a space survives being handed to ssh ------------------------
#
# `UserKnownHostsFile` takes a whitespace-separated *list* of filenames, so ssh
# splits the value no matter how carefully the shell quoted the argument - and
# with StrictHostKeyChecking=accept-new the failure is silent: the key is
# written to a file named after the first word and host-key pinning simply
# never happens.
#
# Measured on 2026-09-19, when the state directory was ~/Library/Application
# Support/tmbox and a rebuilt appliance on a recycled address was accepted by a
# pin living in "/Library/Application". The state directory moved to ~/.config
# afterwards, but this test keeps a path with a space in it: XDG_CONFIG_HOME
# and $HOME are the user's to set, and the tunnel daemon reads from
# /Library/Application Support/tmbox regardless. The fix is that the value
# carries its own double quotes, which ssh strips after it has split.

test_the_known_hosts_option_quotes_its_own_value() {
  source "$TMBOX_ROOT/lib/state.zsh" 2>/dev/null
  source "$TMBOX_ROOT/lib/sshx.zsh"

  SSH_KNOWN_HOSTS="/tmp/tmbox test dir/known_hosts"
  local opts; opts="$(ssh_opts admin)"

  assert_contains "$opts" 'UserKnownHostsFile="/tmp/tmbox test dir/known_hosts"' \
    "the path must reach ssh wrapped in quotes ssh can see"
}

test_the_tunnel_helper_quotes_it_too() {
  # The daemon runs out of /Library/Application Support/tmbox, so it has the
  # same space and needed the same fix.
  local helper; helper="$(<"$TMBOX_ROOT/macos/tmbox-tunnel")"
  assert_matches "$helper" 'UserKnownHostsFile="\\"' \
    "the tunnel helper must quote the value as well"
}

# --- a privileged glob must be expanded by the privileged shell -------------
#
# `priv_run_quiet /bin/ls -d -- "$mp"/*.sparsebundle` reads as though sudo does
# the matching. It does not: zsh expands the pattern in the calling shell,
# which is unprivileged, while the path being searched is root-only. The
# pattern matched nothing, tm_bundle_path failed silently, and every caller
# reported Time Machine encryption as "not checked" however much root it had.
#
# Measured 2026-09-19 against a real destination, where the only symptom was a
# check that never fired.

test_privileged_globs_are_not_expanded_by_the_calling_shell() {
  local -a files=("$TMBOX_ROOT"/cmd/*.zsh(N) "$TMBOX_ROOT"/lib/*.zsh(N))

  # An unquoted glob on a priv_run line is the mistake. A quoted one, handed to
  # a shell under sudo, is the fix.
  local -a hits=()
  # Lines that hand the pattern to a shell under sudo are the correct form and
  # are excluded; what is being looked for is a bare glob sitting in argv.
  hits=("${(@f)$(grep -nE 'priv_run(_quiet)?[^|;#]*\*' -- "${files[@]}" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+: *#' \
    | grep -vE 'sh -c')}")

  assert_empty "${hits[*]}" \
    "a glob on a priv_run line is expanded before sudo sees it"
}

# --- where tmbox keeps what it keeps ----------------------------------------
#
# The user-level directory is ~/.config/tmbox, honouring XDG_CONFIG_HOME, and
# the reasoning is in the header of lib/state.zsh. It is pinned here because
# the cost of it drifting is not a broken build: it is a second directory of
# credentials left behind on a Mac whose owner was told there was one, and
# `destroy` removing only the half it knows about.

test_user_state_goes_where_a_cli_tool_keeps_things() {
  local line
  line="$(grep -m1 '^typeset -g TMBOX_STATE_DIR=' "$TMBOX_ROOT/lib/state.zsh")"

  assert_contains "$line" 'XDG_CONFIG_HOME' "XDG_CONFIG_HOME wins when it is set"
  assert_contains "$line" '$HOME/.config'   "and ~/.config is the fallback"
  assert_not_contains "$line" 'Application Support' \
    "Application Support is for bundles and for the root daemon, not for this"
}

test_the_root_daemon_keeps_its_own_directory() {
  # The other half of the same decision: the tunnel daemon starts before login,
  # so its files cannot live under a home directory at all.
  local line
  line="$(grep -m1 '^typeset -g TMBOX_SYS_DIR=' "$TMBOX_ROOT/cmd/tunnel.zsh")"

  assert_contains "$line" '/Library/Application Support/tmbox' \
    "the daemon's support files stay where a daemon's files belong"
  assert_not_contains "$line" 'HOME' "and never under a user's home"
}

# --- every embedded payload is a real file ----------------------------------
#
# The build base64-embeds a fixed list of files into the one published script.
# An empty file in that list ships as an empty payload: a placeholder that looks
# like a feature in the artifact and does nothing at runtime. The build refuses
# one too; this says so earlier, while editing.

test_every_embedded_payload_exists_and_is_not_empty() {
  local -a payloads
  payloads=(${(f)"$(awk '$1 == "embed_b64" {print $3}' "$TMBOX_ROOT/tools/build.zsh")"})
  assert_nonempty "${payloads[*]}" "the list of embedded payloads"
  local f
  for f in $payloads; do
    assert_file "$TMBOX_ROOT/$f"
    [[ -s "$TMBOX_ROOT/$f" ]] || fail "embedded payload is empty: $f"
  done
}

# --- the pool unit is running before the first reboot -----------------------
#
# The bootstrap assembles the pool by hand, then installs the unit that does the
# same at boot. Enabling that unit without starting it left it inactive for the
# rest of the first boot, so the first reboot after an install never ran its
# ExecStop: the Storage Box was unmounted under a live pool and the server hung
# in shutdown for good. Both halves are pinned: started now, and part of the
# shutdown transaction in its own right.

test_the_bootstrap_starts_the_pool_unit_not_only_enables_it() {
  local body
  body="$(sed -n '/^phase_boot_units()/,/^}/p' "$TMBOX_ROOT/appliance/bootstrap.sh")"
  assert_nonempty "$body" "phase_boot_units exists"
  assert_contains "$body" 'systemctl start tmbox-pool.service' \
    "the pool unit is started in the boot that installs it"
  assert_contains "$body" 'systemctl is-active --quiet tmbox-pool.service' \
    "and the bootstrap checks that it really is active"
  assert_contains "$body" 'Conflicts=shutdown.target umount.target' \
    "the unit is stopped by shutdown itself"
  assert_contains "$body" 'Before=shutdown.target umount.target' \
    "and before any mount is taken down"
}
