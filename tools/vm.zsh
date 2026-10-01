#!/bin/zsh
#
# The throwaway macOS guest that proves tmbox runs on a stock Mac.
#
# The machine this is developed on is not evidence: it has Homebrew, a populated
# keychain, an existing Time Machine destination and whatever else has
# accumulated. The guest has none of that, so it is where "no Homebrew, no
# Xcode, nothing installed" stops being a claim.
#
# It is also the only place the whole nine-step flow can be driven end to end
# without touching the developer's own backups - `tmutil setdestination` is not
# something to experiment with on a Mac whose backups matter.
#
# **The guest is stopped, never deleted.** Re-creating it is a 27 GB pull, and
# the Full Disk Access grant inside it is a TCC decision with no command-line
# equivalent - it has to be clicked, once, through VNC. Deleting the guest
# throws that away.
#
#   tools/vm.zsh up      boot it and wait for ssh
#   tools/vm.zsh ssh     a shell, or a command
#   tools/vm.zsh run     copy dist/tmbox.zsh in and run it
#   tools/vm.zsh serve   serve dist/ over HTTP, for the real curl | zsh shape
#   tools/vm.zsh probe   what the guest has, to check the stock-Mac assumption
#   tools/vm.zsh down    shut it down cleanly
#
emulate -L zsh
setopt pipe_fail extended_glob

typeset -g ROOT="${0:A:h:h}"
typeset -g VM_NAME="${VM_NAME:-tmbox-e2e}"
typeset -g VM_USER="${VM_USER:-admin}"
typeset -g RUNDIR="$ROOT/.run"

die() { print -u2 -- "vm: $*"; exit 1 }

(( $+commands[tart] )) || die "tart is not installed (brew install cirruslabs/cli/tart)"

# vm_key - the ssh identity for the guest
#
# The key lives under .run/keys, injected once when the guest was created, and
# is located once and remembered here.
vm_key() {
  local cached="$RUNDIR/vm_key_path"
  if [[ -f "$cached" ]]; then
    local k; k="$(cat -- "$cached")"
    [[ -f "$k" ]] && { print -rn -- "$k"; return 0 }
  fi

  local ip; ip="$(tart ip "$VM_NAME" 2>/dev/null)" || return 1
  local candidate
  for candidate in \
    "$RUNDIR"/keys/id_ed25519_guest(N)
  do
    if ssh -i "$candidate" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=6 \
           "${VM_USER}@${ip}" true 2>/dev/null; then
      mkdir -p -- "$RUNDIR"
      print -rn -- "$candidate" > "$cached"
      print -rn -- "$candidate"
      return 0
    fi
  done
  return 1
}

vm_ip() { tart ip "$VM_NAME" 2>/dev/null }

vm_ssh_opts() {
  # Host checking off, deliberately: the guest takes a fresh DHCP address on
  # every boot, so pinning would produce a warning on every run and train the
  # operator to ignore exactly the warning that matters elsewhere.
  print -rl -- \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o BatchMode=yes \
    -o ConnectTimeout=10
}

cmd_up() {
  if ! pgrep -qf "tart run $VM_NAME"; then
    mkdir -p -- "$RUNDIR"
    print -r -- "booting $VM_NAME"
    nohup tart run "$VM_NAME" --no-graphics --vnc-experimental \
      > "$RUNDIR/tart.log" 2>&1 &
    sleep 5
  else
    print -r -- "$VM_NAME is already running"
  fi

  local ip="" i
  for i in {1..60}; do
    ip="$(vm_ip)"
    [[ -n "$ip" ]] && break
    sleep 5
  done
  [[ -n "$ip" ]] || die "no DHCP lease after five minutes; see $RUNDIR/tart.log"
  print -r -- "guest address: $ip"

  local key; key="$(vm_key)" || die "no working ssh key for the guest"
  print -r -- "guest key:     $key"

  # The VNC URL is the only way to reach the Full Disk Access dialog, which
  # cannot be granted from a shell.
  grep -m1 -o 'vnc://[^ ]*' "$RUNDIR/tart.log" 2>/dev/null \
    | sed 's/^/vnc:           /' || true
}

cmd_ssh() {
  local ip; ip="$(vm_ip)" || die "the guest is not running"
  local key; key="$(vm_key)" || die "no working ssh key"
  local -a opts=( ${(f)"$(vm_ssh_opts)"} )
  if (( $# > 0 )); then
    ssh -i "$key" $opts "${VM_USER}@${ip}" -- "$@"
  else
    ssh -i "$key" $opts -t "${VM_USER}@${ip}"
  fi
}

cmd_probe() {
  # The stock-Mac assumption, checked rather than asserted. Every tool tmbox
  # uses has to be here, and Homebrew has to not be.
  cmd_ssh 'zsh -c "
    print -r -- \"macOS \$(sw_vers -productVersion)  zsh \$ZSH_VERSION  shell \$SHELL\"
    print -r -- \"\"
    for t in brew jq curl ssh ssh-keygen security tmutil smbutil hdiutil plutil launchctl ifconfig scutil base64 shasum; do
      printf \"%-12s %s\n\" \$t \"\$(command -v \$t || print MISSING)\"
    done
    print -r -- \"\"
    print -rn -- \"jq is \"; codesign -dv --verbose=2 /usr/bin/jq 2>&1 | sed -n \"s/^Identifier=//p\"
  "'
}

cmd_run() {
  [[ -f "$ROOT/dist/tmbox.zsh" ]] || die "no dist/tmbox.zsh - run make dist first"
  local ip; ip="$(vm_ip)" || die "the guest is not running"
  local key; key="$(vm_key)" || die "no working ssh key"
  local -a opts=( ${(f)"$(vm_ssh_opts)"} )

  # Delivered on stdin and written by the far side, so the mode is set by the
  # shell that creates it rather than inherited from scp.
  ssh -i "$key" $opts "${VM_USER}@${ip}" -- \
    'cat > /tmp/tmbox.zsh && chmod 0755 /tmp/tmbox.zsh' < "$ROOT/dist/tmbox.zsh" \
    || die "could not copy the artifact"

  ssh -i "$key" $opts "${VM_USER}@${ip}" -- "/bin/zsh /tmp/tmbox.zsh $*"
}

cmd_pipe() {
  # The published shape, inside the guest: the script arrives on stdin and has
  # to read its answers from the terminal instead.
  [[ -f "$ROOT/dist/tmbox.zsh" ]] || die "no dist/tmbox.zsh - run make dist first"
  local ip; ip="$(vm_ip)" || die "the guest is not running"
  local key; key="$(vm_key)" || die "no working ssh key"
  local -a opts=( ${(f)"$(vm_ssh_opts)"} )
  ssh -i "$key" $opts "${VM_USER}@${ip}" -- \
    "cat > /tmp/tmbox.zsh && cat /tmp/tmbox.zsh | /bin/zsh -s -- $*" \
    < "$ROOT/dist/tmbox.zsh"
}

cmd_serve() {
  # A local HTTP server so the guest can run the genuine one-liner. Bound to the
  # host's address on the guest network only - this is a development artifact
  # and has no business being reachable from anywhere else.
  local addr; addr="$(ipconfig getifaddr bridge100 2>/dev/null || print 0.0.0.0)"
  print -r -- "serving $ROOT/dist on http://${addr}:8787/"
  print -r -- "in the guest:  curl -fsSL http://${addr}:8787/tmbox.zsh | zsh"
  print -r -- "ctrl-c to stop"
  ( cd -- "$ROOT/dist" && python3 -m http.server 8787 --bind "$addr" )
}

cmd_down() {
  # A clean shutdown, not a kill: the guest holds a Time Machine configuration
  # and a keychain, and both deserve to be closed properly.
  cmd_ssh 'sudo shutdown -h now' 2>/dev/null || true
  print -r -- "shutting down; the guest is kept, never deleted"
}

case "${1:-}" in
  up)    shift; cmd_up "$@" ;;
  ssh)   shift; cmd_ssh "$@" ;;
  probe) shift; cmd_probe "$@" ;;
  run)   shift; cmd_run "$@" ;;
  pipe)  shift; cmd_pipe "$@" ;;
  serve) shift; cmd_serve "$@" ;;
  down)  shift; cmd_down "$@" ;;
  *)     print -u2 -- "usage: vm.zsh {up|ssh|probe|run|pipe|serve|down}"; exit 2 ;;
esac
