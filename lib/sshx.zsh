#!/bin/zsh
#
# SSH: keys, host pinning, and running commands on the appliance.
#
# Two keys are generated, and the split is the point rather than tidiness:
#
#   admin   full access. Used by setup, status, doctor and destroy. Lives in the
#           user's own directory and is used only when a person is driving.
#   tunnel  restricted on the appliance side to opening exactly one forward to
#           127.0.0.1:445 and nothing else. This is the key that has to sit
#           unattended in /etc where a root LaunchDaemon can read it, so it is
#           the key whose blast radius has to be small.
#
# Both are Ed25519. Small enough to print on the recovery card and retype from
# it - which matters, because in macOS Recovery the tunnel key is how a user
# reaches their backups, and there is no clipboard and no password manager there.
#
# Keys are files with mode 0600, alongside the other credentials - see
# lib/secrets.zsh for why none of this is in the login keychain.
#
# Host keys are pinned to a tmbox-private known_hosts on first connection. Not
# StrictHostKeyChecking=no: the appliance's address is a Hetzner primary IP that
# has belonged to someone else before and will again, so "trust anything" here
# means trusting whoever holds that address next. Pinning on first sight and
# refusing a change afterwards is the achievable guarantee.

typeset -g SSH_KEY_DIR="${SSH_KEY_DIR:-$TMBOX_STATE_DIR/keys}"
# **This path may contain a space, and that makes every use of it a trap.**
# `UserKnownHostsFile` takes a *whitespace-separated list* of filenames, so ssh
# splits the value regardless of how carefully the shell quoted the argument,
# and with StrictHostKeyChecking=accept-new it does so silently: the key lands
# in a file named after the first word and pinning never happens.
#
# Measured 2026-09-19, when the state directory was ~/Library/Application
# Support/tmbox: the pin was going to a file literally named
# "/Users/<u>/Library/Application" and host-key checking had never once worked.
# The default path has no space in it now, but the hazard has not gone away -
# XDG_CONFIG_HOME and $HOME are the user's to set, and the tunnel daemon still
# reads from /Library/Application Support/tmbox. So the value carries its own
# double quotes, which ssh strips after it has finished splitting. See ssh_opts.
typeset -g SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-$TMBOX_STATE_DIR/known_hosts}"

# ssh_key_path <admin|tunnel>
ssh_key_path() { print -rn -- "${SSH_KEY_DIR}/id_ed25519_${1}" }

# ssh_delete_keys - remove every keypair tmbox generated on this Mac.
#
# Called by `destroy` once the appliance is gone. A key to a server that no
# longer exists opens nothing, so this is hygiene rather than a breach - but
# leaving it has two costs worth avoiding. It makes "credentials removed from
# this Mac" untrue, and a later rebuild silently reuses the old keypair, so a
# run that is meant to start from nothing does not.
ssh_delete_keys() {
  [[ -d "$SSH_KEY_DIR" ]] || return 0
  local f
  for f in "$SSH_KEY_DIR"/id_ed25519_*(N) "$SSH_KEY_DIR"/id_ed25519_*.pub(N); do
    rm -f -- "$f"
  done
  rmdir -- "$SSH_KEY_DIR" 2>/dev/null
  return 0
}

# ssh_keygen <admin|tunnel> [comment]
#
# Idempotent: an existing key is kept. Regenerating would orphan the public half
# already installed on the appliance and lock the user out of their own machine.
ssh_keygen() {
  local kind="$1" comment="${2:-tmbox-${1}}"
  local key; key="$(ssh_key_path "$kind")"

  mkdir -p -- "$SSH_KEY_DIR" || return 1
  chmod 0700 "$SSH_KEY_DIR" 2>/dev/null

  if [[ -f "$key" ]]; then
    log_debug "reusing the existing $kind key"
    print -rn -- "$key"
    return 0
  fi

  # -N '' for no passphrase: this key is used unattended by a LaunchDaemon, and
  # a passphrase it could not answer would be theatre. The protection is the
  # file mode, the private state directory, and the permitopen restriction
  # on the appliance side.
  ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$key" </dev/null >/dev/null 2>&1 || {
    log_error "ssh-keygen failed for the $kind key"
    return 1
  }
  chmod 0600 "$key" 2>/dev/null
  chmod 0644 "${key}.pub" 2>/dev/null
  log_info "generated the $kind key"
  print -rn -- "$key"
}

# ssh_pubkey <admin|tunnel>
ssh_pubkey() {
  local key; key="$(ssh_key_path "$1")"
  [[ -f "${key}.pub" ]] || return 1
  cat -- "${key}.pub"
}

# ssh_fingerprint_md5 <admin|tunnel>
#
# Hetzner indexes SSH keys by their MD5 fingerprint, so this is what finds an
# already-uploaded key rather than uploading a duplicate.
ssh_fingerprint_md5() {
  local key; key="$(ssh_key_path "$1")"
  [[ -f "${key}.pub" ]] || return 1
  ssh-keygen -l -E md5 -f "${key}.pub" 2>/dev/null | awk '{print $2}' | sed 's/^MD5://'
}

# ssh_forget_host <host>
#
# Called when an appliance is destroyed. Without it the next appliance on a
# recycled address trips the host-key warning and looks like an attack.
ssh_forget_host() {
  [[ -f "$SSH_KNOWN_HOSTS" ]] || return 0
  ssh-keygen -q -f "$SSH_KNOWN_HOSTS" -R "$1" >/dev/null 2>&1
  rm -f -- "${SSH_KNOWN_HOSTS}.old"
  return 0
}

# ssh_opts <admin|tunnel> - the option array every connection shares
#
# accept-new, not no: the host key is pinned the first time and any later change
# is refused. StrictHostKeyChecking=no would keep accepting a new key forever,
# which on a recycled public address means trusting whoever holds it next.
ssh_opts() {
  local key; key="$(ssh_key_path "$1")"
  print -rl -- \
    -i "$key" \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="\"${SSH_KNOWN_HOSTS}\"" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o LogLevel=ERROR
}

# ssh_run <host> <command...> - output on stdout, status from the remote command
#
# BatchMode means a prompt is a failure rather than a hang, which is what an
# unattended installer needs: an appliance that has lost its key should report
# that immediately, not wait forever for a password nobody will type.
ssh_run() {
  local host="$1"; shift
  local -a opts=( ${(f)"$(ssh_opts admin)"} )
  mkdir -p -- "${SSH_KNOWN_HOSTS:h}" 2>/dev/null
  ssh $opts "root@${host}" -- "$@"
}

# ssh_run_quiet <host> <what> <command...>
#
# The same, with the output routed to the transcript instead of the screen.
# Most appliance steps are noisy and uninteresting until they fail.
ssh_run_quiet() {
  local host="$1" what="$2"; shift 2
  log_run "$what" ssh_run "$host" "$@"
}

# ssh_send_secret <host> <remote-command> <secret>
#
# Hand a credential to a command on the appliance without it ever touching a
# command line or a disk. It arrives on the remote process's stdin and lives in
# that process's memory only.
#
# This is how the ZFS passphrase reaches `zfs load-key`, and it is what makes
# "the key is never stored on the appliance" true rather than aspirational: a
# key in argv would be in the remote `ps`, and a key in a file would still be
# there after a reboot.
ssh_send_secret() {
  local host="$1" cmd="$2" secret="$3"
  local -a opts=( ${(f)"$(ssh_opts admin)"} )
  print -rn -- "$secret" | ssh $opts "root@${host}" -- "$cmd"
}

# ssh_put <host> <local-file> <remote-path> [mode]
#
# Piped through `cat` on the far side rather than using scp, so the mode is set
# by the shell that creates the file rather than inherited and then corrected.
# The window in which a private key exists world-readable is thereby zero rather
# than short.
ssh_put() {
  local host="$1" src="$2" dest="$3" mode="${4:-0600}"
  local -a opts=( ${(f)"$(ssh_opts admin)"} )
  ssh $opts "root@${host}" -- \
    "umask 077 && mkdir -p -- \"\$(dirname ${(q)dest})\" && cat > ${(q)dest} && chmod ${(q)mode} ${(q)dest}" \
    < "$src"
}

# ssh_put_data <host> <content> <remote-path> [mode] - the same, from a string
ssh_put_data() {
  local host="$1" content="$2" dest="$3" mode="${4:-0600}"
  local -a opts=( ${(f)"$(ssh_opts admin)"} )
  print -rn -- "$content" | ssh $opts "root@${host}" -- \
    "umask 077 && mkdir -p -- \"\$(dirname ${(q)dest})\" && cat > ${(q)dest} && chmod ${(q)mode} ${(q)dest}"
}

# ssh_wait <host> [timeout] - wait until the appliance answers
#
# A freshly created server accepts a TCP connection before sshd is listening and
# listens before cloud-init has installed the host keys, so this waits for an
# actual successful command rather than for a port.
ssh_wait() {
  local host="$1"
  local -i timeout="${2:-300}" waited=0 interval=5
  while (( waited < timeout )); do
    if ssh_run "$host" true >/dev/null 2>&1; then
      log_debug "ssh to $host answered after ${waited}s"
      return 0
    fi
    sleep $interval
    (( waited += interval ))
  done
  return 1
}

# ssh_authorized_keys_line <public-key>
#
# The restriction on the tunnel key, and the reason a key can sit unattended in
# /etc without being a liability.
#
#   restrict         everything off: no agent forwarding, no X11, no pty, no
#                    user rc file, and - importantly - no port forwarding.
#   port-forwarding  re-enables only that, because `restrict` turned it off.
#                    This pair is the part people get wrong: permitopen alone
#                    after restrict permits nothing at all.
#   permitopen=…445  and only to the appliance's own Samba.
#   command=""       so that even if a forward is opened, no shell runs.
ssh_authorized_keys_line() {
  print -rn -- "restrict,port-forwarding,permitopen=\"127.0.0.1:445\",command=\"\" $1"
}
