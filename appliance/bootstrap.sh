#!/bin/bash
#
# tmbox appliance bootstrap - runs on Debian 13 (arm64), as root, over SSH.
#
# This is the only part of tmbox that is bash rather than zsh: Debian does not
# ship zsh, and installing one in order to run the installer would be absurd.
#
# It turns a stock Debian cloud image into a Time Machine destination:
#
#   Storage Box ──CIFS──► /mnt/sbox ──► tank.img ──loop──► zpool tank
#                                                            └─ tank/tm  (encrypted)
#                                                                 └─ tank/tm/<mac>
#                                                                      └─ Samba share
#
# Every value here was measured on a real run of this stack, and several are
# load-bearing in a way that is invisible until they are wrong. The ones that
# corrupt silently rather than failing loudly are called out where they are used.
#
# **Idempotent by construction.** Every phase checks for what it would create
# and skips it. The installer re-runs this after any interruption, and the
# alternative to re-running is a second appliance.
#
# Input: /etc/tmbox/config, written by the installer before this runs. The ZFS
# passphrase arrives on stdin and is never written anywhere.
#
# Copyright (c) 2026, Lab22 Poland Sp. z o.o.  BSD-3-Clause.

set -euo pipefail

CONFIG=/etc/tmbox/config
STATE=/etc/tmbox
MOUNT=/mnt/sbox
IMG=/mnt/sbox/tank.img
POOL=tank
CREDS=/etc/tmbox/cifs-creds

say()  { printf '>> %s\n' "$*"; }
die()  { printf 'XX %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -r "$CONFIG" ] || die "missing $CONFIG - the installer writes it before running this"
# shellcheck source=/dev/null
. "$CONFIG"

: "${TMBOX_MAC_NAME:?config is missing TMBOX_MAC_NAME}"
: "${TMBOX_SHARE:?config is missing TMBOX_SHARE}"
: "${TMBOX_SMB_USER:?config is missing TMBOX_SMB_USER}"
: "${TMBOX_IMG_SIZE_MB:?config is missing TMBOX_IMG_SIZE_MB}"
: "${TMBOX_REFQUOTA:?config is missing TMBOX_REFQUOTA}"

DATASET="$POOL/tm/$TMBOX_MAC_NAME"
SHARE_NAME="tm-$TMBOX_MAC_NAME"

# The passphrase, read once from stdin. It lives in this process's memory and
# nowhere else - that is what makes "the key is never stored on the appliance"
# true rather than aspirational.
ZFS_KEY=""
if [ ! -t 0 ]; then
  IFS= read -r ZFS_KEY || true
fi

# ---------------------------------------------------------------------------
# 1. packages
# ---------------------------------------------------------------------------

phase_packages() {
  if command -v zpool >/dev/null 2>&1 && command -v smbd >/dev/null 2>&1 \
     && command -v mount.cifs >/dev/null 2>&1; then
    say "packages already installed"
    return 0
  fi

  say "installing packages - the ZFS module is compiled here, so allow a few minutes"
  export DEBIAN_FRONTEND=noninteractive

  # Wait, rather than fail, if anything else holds the dpkg lock.
  #
  # A from-zero run on 2026-09-19 died here with "Could not get lock
  # /var/lib/dpkg/lock-frontend ... held by process 1072 (apt-get)": sshd
  # answers before cloud-init has finished, and cloud-init's own last act is a
  # round of apt work. The installer now waits for cloud-init before sending
  # this script, but that check sits on the far side of an SSH connection and
  # cannot see unattended-upgrades, a retried bootstrap, or anything else
  # Debian starts by itself.
  #
  # DPkg::Lock::Timeout is apt's own answer and has been available since apt
  # 2.0 (Debian 11), so it needs nothing installed - which `fuser` would have,
  # since psmisc is not on a minimal cloud image. An apt failure aborts the
  # whole provisioning run, so five minutes of patience is cheap.
  APT_OPTS="-o DPkg::Lock::Timeout=300"

  # zfs-dkms is in contrib, not main. Debian 13 uses the deb822 source format;
  # the older one-line form is handled too, because a rebuilt image could carry
  # either.
  if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    sed -i 's/^Components: .*/Components: main contrib/' /etc/apt/sources.list.d/debian.sources
  elif [ -f /etc/apt/sources.list ]; then
    sed -i 's/^\(deb .*trixie[^ ]* main\)$/\1 contrib/' /etc/apt/sources.list
  fi

  apt-get $APT_OPTS update -qq
  # Headers for the *running* kernel: DKMS will happily build against a
  # different one, and the module then silently does not load.
  apt-get $APT_OPTS install -y -qq \
    "linux-headers-$(uname -r)" \
    zfsutils-linux zfs-dkms \
    samba samba-common-bin samba-vfs-modules \
    cifs-utils acl attr jq curl >/dev/null

  say "packages installed"
}

phase_zfs_module() {
  if lsmod | grep -q '^zfs'; then
    say "zfs module already loaded"
    return 0
  fi
  # Measured: DKMS builds and installs zfs.ko but does not load it in the same
  # boot, so an installer going straight from apt to `zpool create` fails on
  # every fresh host with "The ZFS modules cannot be auto-loaded".
  say "loading the zfs module"
  modprobe zfs || die "the ZFS module did not load; check: dkms status"
  echo zfs > /etc/modules-load.d/zfs.conf
  zfs version | head -1
}

# ---------------------------------------------------------------------------
# 2. the Storage Box, over CIFS
# ---------------------------------------------------------------------------

phase_cifs_mount() {
  if mountpoint -q "$MOUNT"; then
    say "Storage Box already mounted"
    assert_cifs_hard
    return 0
  fi

  [ -r "$CREDS" ] || die "missing $CREDS"
  mkdir -p "$MOUNT"

  say "mounting the Storage Box"
  install_mount_unit
  systemctl daemon-reload
  systemctl start mnt-sbox.mount \
    || die "could not mount the Storage Box; see: journalctl -u mnt-sbox.mount"
  mountpoint -q "$MOUNT" || die "the mount unit reported success but nothing is mounted"
  assert_cifs_hard
}

# The single most important mount option in this stack.
#
# mount.cifs defaults to `soft`, which returns an error mid-write and leaves a
# truncated file. Under a ZFS pool that is corruption. `hard` makes the write
# block until the server returns, which is the contract ZFS expects from a block
# device - and it is why this profile works on Linux and was rejected on
# FreeBSD, whose userspace SMB client has no equivalent.
#
# CIFS will not switch between the two on remount, so this is asserted against
# the live mount rather than against the unit file that asked for it.
assert_cifs_hard() {
  local opts
  opts="$(findmnt -no OPTIONS "$MOUNT")" || die "could not read the mount options"
  case ",$opts," in
    *,hard,*) say "mount is hard, as required" ;;
    *) die "the Storage Box is mounted soft, not hard - refusing to continue, because a transport blip would silently truncate writes" ;;
  esac
}

install_mount_unit() {
  # The unit filename must match the mount point, or systemd ignores it.
  cat > /etc/systemd/system/mnt-sbox.mount <<EOF
[Unit]
Description=tmbox - Hetzner Storage Box over CIFS
DefaultDependencies=no
Requires=network-online.target
After=network-online.target

[Mount]
What=//${TMBOX_SHARE#//}
Where=${MOUNT}
Type=cifs
# hard: mount.cifs defaults to soft, which truncates a write mid-flight.
# seal: SMB3 encryption in transit; not on by default on the client side, and
#       worth having even inside one datacenter.
# vers: pinned to the dialect this was measured against.
Options=credentials=${CREDS},iocharset=utf8,uid=0,gid=0,seal,vers=3.1.1,hard,_netdev
TimeoutSec=90

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# 3. the container file
# ---------------------------------------------------------------------------

phase_container() {
  if [ -f "$IMG" ]; then
    say "container already present ($(( $(stat -c %s "$IMG") / 1024 / 1024 )) MiB)"
    return 0
  fi

  say "preallocating ${TMBOX_IMG_SIZE_MB} MiB - this is the slow part"

  # dd, never fallocate or truncate. On CIFS those produce a sparse file, and a
  # sparse file on a share that cannot actually grow to its nominal size is a
  # corrupt filesystem later, discovered at the worst possible moment.
  #
  # Run under systemd-run so it survives the SSH session going away: at
  # multi-terabyte sizes this is hours, and holding a connection open for hours
  # is a way to lose the work to a closed laptop.
  systemd-run --unit=tmbox-prealloc --collect --quiet \
    /bin/dd if=/dev/zero "of=$IMG" bs=1M "count=$TMBOX_IMG_SIZE_MB" conv=fsync \
    || die "could not start the preallocation"

  local waited=0
  while systemctl is-active --quiet tmbox-prealloc; do
    sleep 5
    waited=$(( waited + 5 ))
    if [ $(( waited % 60 )) -eq 0 ] && [ -f "$IMG" ]; then
      printf '   %s of %s MiB\n' \
        "$(( $(stat -c %s "$IMG") / 1024 / 1024 ))" "$TMBOX_IMG_SIZE_MB"
    fi
  done

  [ -f "$IMG" ] || die "the preallocation produced no file"
  local got_mb
  got_mb=$(( $(stat -c %s "$IMG") / 1024 / 1024 ))
  [ "$got_mb" -ge "$TMBOX_IMG_SIZE_MB" ] \
    || die "the container is ${got_mb} MiB but should be ${TMBOX_IMG_SIZE_MB} - the Storage Box may be full"
  sync
  say "container ready (${got_mb} MiB)"
}

# ---------------------------------------------------------------------------
# 4. the loop device
# ---------------------------------------------------------------------------

phase_loop() {
  local loop
  loop="$(losetup -j "$IMG" -O NAME -n 2>/dev/null | tr -d ' ')"
  if [ -z "$loop" ]; then
    loop="$(losetup -f --show --direct-io=on "$IMG")" || die "losetup failed"
  fi
  losetup --direct-io=on "$loop"

  # Assert rather than assume. A loop device defaults to buffered I/O, and on a
  # CIFS backing file that caches the data twice: writes can be lost or
  # reordered while every check stays green and fsck reports clean. It is the
  # one failure in this stack that corrupts content silently, so the pool is not
  # touched unless direct I/O is genuinely on.
  local dio
  dio="$(losetup -l -O DIO -n "$loop" | tr -d ' ')"
  [ "$dio" = "1" ] || die "direct I/O is off on $loop - refusing to continue"

  say "loop device $loop, direct I/O confirmed" >&2
  printf '%s' "$loop"
}

# ---------------------------------------------------------------------------
# 5. the pool and the encrypted dataset
# ---------------------------------------------------------------------------

phase_pool() {
  local loop="$1"

  if zpool list -H -o name "$POOL" >/dev/null 2>&1; then
    say "pool $POOL already imported"
    return 0
  fi
  if zpool import -d "$loop" "$POOL" >/dev/null 2>&1; then
    say "pool $POOL imported from the existing container"
    return 0
  fi

  say "creating pool $POOL"
  # ashift=12 explicitly: autodetect trusts the device's reported sector size
  # and a loop device reports 512. Getting this wrong cannot be fixed without
  # recreating the pool.
  #
  # cachefile=none, because zfs-import-cache.service runs long before any
  # network mount exists, finds a pool it cannot reach and fails - measured, the
  # first reboot came up degraded. tmbox imports from its own unit instead.
  #
  # autotrim=on so discard travels through the loop device and CIFS to the
  # backing file and the Storage Box gives space back; without it, metered usage
  # grows with write churn rather than with live data.
  zpool create \
    -o ashift=12 \
    -o cachefile=none \
    -o autotrim=on \
    -O mountpoint=none \
    "$POOL" "$loop" || die "zpool create failed"

  systemctl disable --now zfs-import-cache.service >/dev/null 2>&1 || true
  systemctl reset-failed zfs-import-cache.service >/dev/null 2>&1 || true
}

phase_dataset() {
  if zfs list -H -o name "$POOL/tm" >/dev/null 2>&1; then
    say "encrypted dataset already exists"
  else
    [ -n "$ZFS_KEY" ] || die "no passphrase on stdin, and the encrypted dataset does not exist yet"
    say "creating the encrypted dataset"

    # Native ZFS encryption rather than LUKS under the loop device, for two
    # reasons that matter here. `zfs load-key` reads a passphrase from stdin, so
    # the key can arrive over SSH and live only in the kernel keyring, which is
    # what "never stored on the appliance" requires. And dm-crypt blocks discard
    # by default, which would silently undo the autotrim above and make the
    # Storage Box bill for churn instead of for data.
    #
    # The passphrase arrives on this command's stdin. Never as an argument: an
    # argument is readable in ps for the life of the process.
    printf '%s' "$ZFS_KEY" | zfs create \
      -o encryption=aes-256-gcm \
      -o keyformat=passphrase \
      -o keylocation=prompt \
      -o mountpoint=/srv/tm \
      "$POOL/tm" || die "could not create the encrypted dataset"
  fi

  if zfs list -H -o name "$DATASET" >/dev/null 2>&1; then
    say "dataset $DATASET already exists"
  else
    zfs create "$DATASET" || die "could not create $DATASET"
  fi

  # refquota, not quota. It is what macOS sees through statvfs, so it is what
  # Time Machine budgets against - and it is the working replacement for
  # `fruit:time machine max size`, which is broken with .backupbundle
  # (Samba bug 14409, still open).
  #
  # The rest are set explicitly because the pool defaults are wrong for this
  # workload: atime on costs a write per read, aclinherit defaults to restricted,
  # dnodesize to legacy. sync is never disabled - Time Machine depends on
  # F_FULLFSYNC meaning what it says.
  zfs set \
    refquota="$TMBOX_REFQUOTA" \
    compression=lz4 \
    atime=off \
    xattr=sa \
    acltype=posix \
    aclinherit=passthrough \
    dnodesize=auto \
    recordsize=128K \
    sync=standard \
    "$DATASET"

  zfs mount -a 2>/dev/null || true
  say "dataset ready: refquota $(zfs get -H -o value refquota "$DATASET") on $DATASET"
}

# ---------------------------------------------------------------------------
# 6. Samba
# ---------------------------------------------------------------------------

phase_samba() {
  local mp
  mp="$(zfs get -H -o value mountpoint "$DATASET")"
  [ -d "$mp" ] || die "the dataset is not mounted at $mp"

  if ! id -u "$TMBOX_SMB_USER" >/dev/null 2>&1; then
    # A fixed uid: if the appliance is ever rebuilt, only the pool travels, and
    # a different uid on the new machine makes every file in the share
    # inaccessible.
    useradd -u 5000 -M -s /usr/sbin/nologin "$TMBOX_SMB_USER"
  fi
  chown "$TMBOX_SMB_USER:$TMBOX_SMB_USER" "$mp"
  chmod 0700 "$mp"

  # Generated here and reported to the installer on stdout. Re-read rather than
  # rotated on a second run: rotating would silently invalidate the credentials
  # Time Machine has already saved, and the failure would look like a broken
  # destination rather than a changed password.
  local smb_pw
  if [ -s "$STATE/smb_password" ]; then
    smb_pw="$(cat "$STATE/smb_password")"
  else
    smb_pw="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    printf '%s' "$smb_pw" > "$STATE/smb_password"
    chmod 0600 "$STATE/smb_password"
  fi
  printf '%s\n%s\n' "$smb_pw" "$smb_pw" | smbpasswd -s -a "$TMBOX_SMB_USER" >/dev/null
  smbpasswd -e "$TMBOX_SMB_USER" >/dev/null

  write_smb_conf "$mp"
  testparm -s >/dev/null 2>&1 || die "smb.conf is not valid"

  # `enable` without `--now`, then one `restart`. Doing both starts smbd twice
  # in quick succession, and smbd forks smbd-notifyd and smbd-cleanupd, which
  # outlive the first start just long enough for systemd to find them in the
  # control group of the second - it logs "found left-over process", waits for
  # the notify that never comes, and fails the unit after ninety seconds.
  # Measured on the first live run; a single start works every time.
  systemctl enable smbd >/dev/null 2>&1
  systemctl restart smbd
  systemctl is-active --quiet smbd || die "smbd did not start; see: journalctl -u smbd"

  # Checked rather than assumed. Samba 4.22.0-4.22.5 and 4.23.0-4.23.2 break
  # Time Machine on macOS 26 (bug 15926); Debian 13 ships 4.22.11, which is
  # clear, but an appliance rebuilt later from a different snapshot might not be.
  local ver
  ver="$(smbd --version | awk '{print $2}')"
  say "Samba $ver"
  # The password is deliberately NOT printed. This phase's output is streamed to
  # the user's terminal and into the installer's transcript, and a credential
  # that appears there survives in scrollback and in any support mail the
  # transcript is pasted into. It is left in a mode-600 file, and the installer
  # reads it over its own SSH connection.

  say "Samba serving $SHARE_NAME"
}

write_smb_conf() {
  local mp="$1"
  cat > /etc/samba/smb.conf <<EOF
# Written by tmbox. Changes here are overwritten on the next run.
#
# Every fruit: option is global on purpose: AAPL is negotiated on the first tree
# connect, before a share is chosen, so a per-share setting arrives too late.
#
# testparm is not proof that this is right. It echoes parametric fruit: options
# back verbatim without validating them, so a typo yields a clean config and a
# share Time Machine quietly will not use. The proof is the client's own
# smbutil statshares reporting OS_X_SERVER TRUE.

[global]
    workgroup            = WORKGROUP
    server string        = tmbox
    netbios name         = TMBOX
    server role          = standalone server
    security             = user

    server min protocol  = SMB3_11
    server signing       = auto
    smb encrypt          = required
    ea support           = yes

    # Order matters: fruit must come before streams_xattr.
    vfs objects          = fruit streams_xattr

    fruit:aapl                                = yes
    fruit:metadata                            = stream
    fruit:model                               = MacSamba
    fruit:veto_appledouble                    = no
    fruit:nfs_aces                            = no
    fruit:wipe_intentionally_left_blank_rfork = yes
    fruit:delete_empty_adfiles                = yes
    # fruit:resource is deliberately left at its default of "file". On Linux
    # with ZFS the per-attribute xattr ceiling is exactly 65536 bytes, so
    # "stream" fails only on large resource forks - the worst kind of failure.

    # One TCP connection, to a loopback address, through one ssh forward:
    # multichannel has nothing to spread across. It is on by default on both
    # ends, and it broke reconnects - after a brief stall the macOS client
    # reconnected, then failed to match 127.0.0.2 to a network interface
    # ("could not find one of the nics") and dropped every outstanding write,
    # ending the backup (#17).
    server multi channel support = no

    # A rebooted client leaves leases on the band files that block its own next
    # backup with BACKUP_FAILED_DISK_IMAGE_BUSY. Samba's default deadtime is
    # seven days; across a link that drops, an unreaped session is not an edge
    # case.
    deadtime             = 10

    log level            = 1
    logging              = file
    log file             = /var/log/samba/log.%m
    max log size         = 1000

    load printers        = no
    printing             = bsd
    printcap name        = /dev/null
    disable spoolss      = yes

[${SHARE_NAME}]
    path                 = ${mp}
    valid users          = ${TMBOX_SMB_USER}
    read only            = no
    browseable           = yes
    fruit:time machine   = yes
    # fruit:time machine max size is never set - broken with .backupbundle
    # (Samba bug 14409). The limit is the ZFS refquota on the dataset.
EOF
}

# ---------------------------------------------------------------------------
# 7. the restricted tunnel account
# ---------------------------------------------------------------------------

phase_tunnel_user() {
  if [ -z "${TMBOX_TUNNEL_PUBKEY:-}" ]; then
    say "no tunnel key supplied; skipping the tunnel account"
    return 0
  fi

  if ! id -u tmtunnel >/dev/null 2>&1; then
    useradd -r -M -d /var/empty -s /usr/sbin/nologin tmtunnel
  fi
  mkdir -p /var/empty/.ssh
  chmod 0700 /var/empty/.ssh

  # `restrict` turns everything off, including port forwarding, and
  # `port-forwarding` turns just that back on. Verified against sshd(8): without
  # naming it explicitly, permitopen permits nothing and the tunnel never opens.
  # command="" so that even with a forward open, no shell runs.
  printf 'restrict,port-forwarding,permitopen="127.0.0.1:445",command="" %s\n' \
    "$TMBOX_TUNNEL_PUBKEY" > /var/empty/.ssh/authorized_keys
  chmod 0600 /var/empty/.ssh/authorized_keys
  chown -R tmtunnel:tmtunnel /var/empty/.ssh

  say "tunnel account ready, restricted to one forward to 127.0.0.1:445"
}

# ---------------------------------------------------------------------------
# 8. boot ordering, and unlocking
# ---------------------------------------------------------------------------

phase_boot_units() {
  cat > /usr/local/sbin/tmbox-pool-up <<'SCRIPT'
#!/bin/bash
# Attach the container and import the pool. The dataset stays locked: it is
# unlocked when a Mac connects and sends the key, which is the entire point of
# the key not living here.
set -euo pipefail
IMG=/mnt/sbox/tank.img
POOL=tank

loop="$(losetup -j "$IMG" -O NAME -n | tr -d ' ')"
[ -n "$loop" ] || loop="$(losetup -f --show --direct-io=on "$IMG")"
losetup --direct-io=on "$loop"

dio="$(losetup -l -O DIO -n "$loop" | tr -d ' ')"
[ "$dio" = "1" ] || { echo "direct I/O is off on $loop - refusing to import $POOL" >&2; exit 1; }

zpool list -H -o name "$POOL" >/dev/null 2>&1 || zpool import -d "$loop" "$POOL"
zpool list -H -o name,health "$POOL"
SCRIPT

  cat > /usr/local/sbin/tmbox-pool-down <<'SCRIPT'
#!/bin/bash
# Reverse order of assembly. Exporting before the mount goes away is what turns
# a reboot into a clean shutdown rather than a hang with a half-written
# container file on the far side. unload-key takes the passphrase back out of
# the kernel keyring on the way past.
IMG=/mnt/sbox/tank.img
POOL=tank
zfs unmount -a 2>/dev/null || true
zfs unload-key -a 2>/dev/null || true
zpool export "$POOL" 2>/dev/null || zpool export -f "$POOL" 2>/dev/null || true
loop="$(losetup -j "$IMG" -O NAME -n | tr -d ' ')"
[ -n "$loop" ] && losetup -d "$loop" 2>/dev/null
exit 0
SCRIPT

  # The passphrase arrives on stdin, goes to zfs load-key, and exists here only
  # in this process's memory and then in the kernel keyring. Nothing writes it
  # down, and tmbox-pool-down takes it back out.
  cat > /usr/local/sbin/tmbox-unlock <<'SCRIPT'
#!/bin/bash
set -euo pipefail
POOL=tank

if [ "$(zfs get -H -o value keystatus "$POOL/tm" 2>/dev/null)" = "available" ]; then
  echo "already unlocked"
else
  zfs load-key "$POOL/tm" || { echo "the passphrase was not accepted" >&2; exit 1; }
fi
zfs mount -a
systemctl start smbd
echo "unlocked and serving"
SCRIPT

  # The inverse of tmbox-unlock, and the order in it is the whole point:
  # `zfs unload-key` refuses while the dataset is mounted, and it refuses
  # quietly - it reports success having done nothing, so a caller that stops
  # Samba and calls unload-key believes the appliance is locked when the key is
  # still in the kernel. Stop, unmount, then unload.
  cat > /usr/local/sbin/tmbox-lock <<'SCRIPT'
#!/bin/bash
set -euo pipefail
POOL=tank
systemctl stop smbd 2>/dev/null || true
zfs unmount -a 2>/dev/null || true
zfs unload-key "$POOL/tm" 2>/dev/null || true
state="$(zfs get -H -o value keystatus "$POOL/tm")"
[ "$state" = "unavailable" ] || { echo "still unlocked ($state)" >&2; exit 1; }
echo "locked"
SCRIPT

  chmod 0755 /usr/local/sbin/tmbox-pool-up \
             /usr/local/sbin/tmbox-pool-down \
             /usr/local/sbin/tmbox-unlock \
             /usr/local/sbin/tmbox-lock

  cat > /etc/systemd/system/tmbox-pool.service <<EOF
[Unit]
Description=tmbox - attach the container and import the pool
DefaultDependencies=no
Requires=mnt-sbox.mount
After=mnt-sbox.mount
Before=smbd.service
# DefaultDependencies=no drops these two, and without them the shutdown
# transaction reaches this unit only by way of mnt-sbox.mount. Stated here, the
# pool is exported as part of shutdown itself, before any mount is touched.
Conflicts=shutdown.target umount.target
Before=shutdown.target umount.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/local/sbin/tmbox-pool-up
ExecStop=/usr/local/sbin/tmbox-pool-down
TimeoutStartSec=300
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOF

  # smbd must not start before the share's directory exists. Measured: a share
  # whose path is missing comes up empty and never re-reads it, so the client
  # sees an empty destination and Time Machine starts a new history.
  mkdir -p /etc/systemd/system/smbd.service.d
  cat > /etc/systemd/system/smbd.service.d/after-pool.conf <<'EOF'
[Unit]
Requires=tmbox-pool.service
After=tmbox-pool.service
EOF

  systemctl daemon-reload
  systemctl enable mnt-sbox.mount tmbox-pool.service >/dev/null 2>&1

  # Enabled is not enough: started, too, in this boot. The pool was assembled by
  # hand above, so without this the unit is inactive until the next boot, and an
  # inactive unit has no ExecStop to run. Measured on the first reboot after a
  # fresh install: shutdown unmounted the Storage Box under a live pool, the
  # network went, and `zfs umount` hung in txg_sync on the hard mount for good -
  # the server never came back. tmbox-pool-up finds the loop device attached and
  # the pool imported, so starting it here changes nothing but systemd's record.
  systemctl start tmbox-pool.service
  systemctl is-active --quiet tmbox-pool.service \
    || die "tmbox-pool.service did not start - a reboot would hang on shutdown"

  # The appliance comes up locked: the pool imported, the dataset unmounted and
  # Samba not started. That is the intended resting state - with no Mac
  # connected there is nothing to back up, and a key that survived a reboot here
  # would not be a key the owner holds.
  systemctl disable smbd >/dev/null 2>&1 || true

  say "boot units installed; the appliance will come up locked and wait for a key"
}

# ---------------------------------------------------------------------------

main() {
  say "tmbox bootstrap on $(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m)"
  phase_packages
  phase_zfs_module
  phase_cifs_mount
  phase_container
  local loop
  loop="$(phase_loop)"
  phase_pool "$loop"
  phase_dataset
  phase_samba
  phase_tunnel_user
  # Last, deliberately. phase_samba enables and starts smbd because the share is
  # wanted now - the dataset is unlocked and the installer is about to use it -
  # and this phase then disables it for subsequent boots, so the appliance comes
  # up locked and waiting. Running these the other way round left smbd enabled
  # and the resting state wrong.
  phase_boot_units
  say "bootstrap complete"
}

main "$@"
