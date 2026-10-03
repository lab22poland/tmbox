#!/bin/zsh
#
# What has to be true before tmbox creates anything.
#
# Every check here exists to move a failure earlier. The expensive failures in
# this product are the ones that happen after a server exists and is billing, or
# after the user has typed a credit-card number into Hetzner - so anything
# knowable beforehand is checked beforehand, and the run stops with a sentence
# that says what to do rather than a stack of shell errors.

# The tools tmbox uses, and what each is for. All of them ship with macOS; none
# implies Homebrew. Listed with a purpose so a missing one produces a useful
# message rather than "command not found".
typeset -ga TMBOX_REQUIRED_TOOLS=(
  "curl:talking to Hetzner"
  "jq:reading Hetzner's replies"
  "ssh:reaching the appliance"
  "ssh-keygen:creating the appliance keys"
  "tmutil:configuring Time Machine"
  "smbutil:checking the share"
  "hdiutil:checking that the backup is encrypted"
  "plutil:reading macOS property lists"
  "launchctl:keeping the tunnel running"
  "ifconfig:the loopback alias the SMB client needs"
  "nc:checking that the tunnel's listener answers"
  "install:placing the tunnel's files with their final mode"
  "scutil:reading this Mac's name"
  "base64:encoding the embedded appliance payloads"
  "shasum:verifying what was downloaded"
)

# The oldest macOS this is tested on. Not a guess: the whole product is built
# around behaviour measured on macOS 26 - zsh as the default shell, jq in
# /usr/bin, the Time Machine over SMB path, and Samba 4.22+ on the appliance
# side. Below that, tmbox would be claiming something nobody has checked.
typeset -gi TMBOX_MIN_MACOS=26

# preflight_all [--offline]
#
# Returns 0 when everything needed is present. Prints its own findings.
preflight_all() {
  local offline=0
  [[ "${1:-}" == "--offline" ]] && offline=1
  local -i problems=0

  preflight_platform  || (( problems++ ))
  preflight_shell     || (( problems++ ))
  preflight_tools     || (( problems++ ))
  preflight_writable  || (( problems++ ))
  (( offline )) || preflight_network || (( problems++ ))

  (( problems == 0 ))
}

preflight_platform() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    ui_bad "tmbox runs on macOS. This is $(uname -s)."
    ui_say "The appliance it builds is Debian, but the installer drives Time Machine, so it has to run on the Mac being backed up."
    return 1
  fi

  local -i major; major="$(macos_major)"
  if (( major < TMBOX_MIN_MACOS )); then
    ui_bad "tmbox needs macOS ${TMBOX_MIN_MACOS} or later; this is $(sw_vers -productVersion)."
    ui_say "Everything tmbox does was measured on macOS ${TMBOX_MIN_MACOS}. Running it on an older release would be claiming something nobody has checked."
    return 1
  fi

  # arm64 or x86_64 both work; there is nothing architecture-specific on the Mac
  # side. Recorded rather than checked, because it belongs in a support mail.
  log_info "macOS $(sw_vers -productVersion) ($(uname -m))"
  return 0
}

preflight_shell() {
  if [[ -z "${ZSH_VERSION:-}" ]]; then
    ui_bad "tmbox is a zsh script and this is not zsh."
    ui_say "Run it with:  zsh tmbox.zsh"
    return 1
  fi
  log_info "zsh $ZSH_VERSION"
  return 0
}

preflight_tools() {
  local -a missing=()
  local entry tool why
  for entry in $TMBOX_REQUIRED_TOOLS; do
    tool="${entry%%:*}"
    why="${entry#*:}"
    (( $+commands[$tool] )) || missing+=("$tool ($why)")
  done

  (( ${#missing} == 0 )) && return 0

  ui_bad "Some tools tmbox needs are missing:"
  local m
  for m in $missing; do ui_item "$m"; done
  ui_blank
  # All of these ship with macOS, so a missing one is not a "please install"
  # situation - it means something is wrong with this Mac or with PATH, and
  # saying so is more useful than suggesting Homebrew.
  ui_say "All of these ship with macOS. Their absence usually means PATH has been narrowed; check that /usr/bin and /usr/sbin are on it."
  return 1
}

preflight_writable() {
  if ! mkdir -p -- "$TMBOX_STATE_DIR" 2>/dev/null; then
    ui_bad "Cannot create ${TMBOX_STATE_DIR}."
    ui_say "tmbox keeps what it has done there so an interrupted setup can be resumed rather than restarted."
    return 1
  fi
  return 0
}

preflight_network() {
  # Reaching the API is checked rather than assumed, because the alternative is
  # a timeout in the middle of provisioning that looks like a Hetzner outage.
  if ! curl -sf --max-time 10 -o /dev/null https://api.hetzner.cloud/v1/pricing 2>/dev/null; then
    # /pricing without a token answers 401, which still proves reachability;
    # only a connection failure is a problem here.
    if ! curl -s --max-time 10 -o /dev/null -w '%{http_code}' https://api.hetzner.cloud/v1/pricing 2>/dev/null | grep -qE '^[0-9]{3}$'; then
      ui_bad "Cannot reach api.hetzner.cloud."
      ui_say "Check the network connection and try again. Nothing has been created."
      return 1
    fi
  fi
  return 0
}

# --- Full Disk Access -------------------------------------------------------
#
# Detected by fda_granted in lib/macos.zsh, which says why the probe is what it
# is. What is here is what the user is told.

# fda_explain - what to do, including the step everyone misses
fda_explain() {
  local app; app="$(fda_app_name)"
  ui_say "Time Machine only accepts a new destination from a program with Full Disk Access, and ${app} does not have it."
  ui_item "System Settings → Privacy & Security → Full Disk Access"
  ui_item "switch on ${app} (use + to add it if it is not listed)"
  ui_item "quit ${app} completely (⌘Q) and open it again - a running app does not pick up the change"
  ui_item "run tmbox setup again; it continues where it stopped"
  ui_say "It is needed for one command in setup. Once setup has finished you can switch it off again."
}

# preflight_time_machine_ready
#
# Called at the start of setup, before anything is created, and again right
# before the destination is set. Stopping at step 1 costs the user a minute;
# finding out at step 8 cost them a server already billing and a misleading
# "wrong password" (#6).
preflight_time_machine_ready() {
  local -i rc=0
  fda_granted || rc=$?
  case $rc in
    0) return 0 ;;
    2) log_warn "cannot tell whether Full Disk Access is granted: $TMBOX_FDA_PROBE is missing"
       return 0 ;;
  esac
  log_warn "Full Disk Access is not granted to ${__CFBundleIdentifier:-the terminal}"
  local app; app="$(fda_app_name)"
  ui_warn "${(U)app[1]}${app[2,-1]} does not have Full Disk Access."
  fda_explain
  return 1
}

# preflight_report - what the environment is, for the transcript
#
# Written to the log at every start. Most support questions are answered by
# these six lines, and collecting them after the fact means asking the user to
# run commands while something is broken.
preflight_report() {
  log_info "macOS $(sw_vers -productVersion 2>/dev/null) build $(sw_vers -buildVersion 2>/dev/null) on $(uname -m)"
  log_info "zsh ${ZSH_VERSION:-unknown}, tmbox ${TMBOX_VERSION:-dev}"
  log_info "jq $(jq --version 2>/dev/null), curl $(curl --version 2>/dev/null | head -1 | cut -d' ' -f2)"
  log_info "ssh $(ssh -V 2>&1 | cut -d, -f1)"
  log_info "state ${TMBOX_STATE_DIR}"
  return 0
}
