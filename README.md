# tmbox

A private Time Machine destination on Hetzner, set up by one shell script from a
Mac that has nothing installed.

```zsh
curl -fsSLO https://github.com/lab22poland/tmbox/releases/download/v0.1.1/tmbox.zsh
curl -fsSLO https://github.com/lab22poland/tmbox/releases/download/v0.1.1/tmbox.zsh.sha256
shasum -a 256 -c tmbox.zsh.sha256    # must print "tmbox.zsh: OK"
less tmbox.zsh && zsh tmbox.zsh setup
```

The digest is published twice: as the `tmbox.zsh.sha256` asset on the release,
and in the repository itself at
[`dist/tmbox.zsh.sha256`](dist/tmbox.zsh.sha256) under the `v0.1.1` tag. The
file is the line `shasum -a 256` itself prints, so `shasum -c` checks it
directly when both files are in the same directory. The build is reproducible,
so `make dist` on a checkout of the tag produces the same digest.

The one-liner form works too, and is offered second on purpose:

```zsh
curl -fsSL https://github.com/lab22poland/tmbox/releases/download/v0.1.1/tmbox.zsh | zsh -s -- setup
```

At the end, Time Machine is backing up to an appliance in your own Hetzner
account, encrypted at rest, reachable only through an SSH tunnel from your Mac,
costing about **€17.39/month at 2 TB**. You need a Mac, an administrator
password and a payment card. You do not need a Hetzner account yet, a package
manager, or any idea what a sparsebundle is.

> **Status: 0.1.1 is the current release.** It is 0.1.0, the first release,
> with one display bug fixed; everything said here about 0.1.0 applies to it
> unchanged. It builds the appliance, connects
> your Mac to it, points Time Machine at it, starts the first backup, and gives
> you commands to check, repair, unlock and remove it. It has been run end to
> end on a stock macOS 26 install with nothing added. It does **not** yet unlock
> the appliance by itself after a reboot, produce a recovery card, or support
> restoring from macOS Recovery. Read [Limitations in 0.1.0](#limitations-in-010)
> before you rely on it.

## What it builds

```
Mac (nothing installed)                 Hetzner (your own account)
┌──────────────────────┐              ┌──────────────────────────────────┐
│ tmbox.zsh (zsh 5.9)  │   REST/curl  │ CAX11, Debian 13, arm64          │
│  ├─ curl + plutil    │─────────────►│  ├─ CIFS ──► Storage Box         │
│  ├─ ssh / ssh-keygen │   ssh, setup │  │    └─ tank.img (container)    │
│  ├─ osascript        │─────────────►│  ├─ loop, direct-io asserted     │
│  └─ tmutil           │              │  ├─ ZFS, natively encrypted      │
└──────────────────────┘  SMB3 in SSH │  └─ Samba + vfs_fruit            │
                       ◄─────────────►└──────────────────────────────────┘
```

Every layer above was measured on real hardware before it was written into the
installer.

In your Hetzner account, `tmbox setup` creates one CAX11 server, one reserved
IPv4 address, one Cloud Firewall, one registered SSH key and one Storage Box,
all labelled `tmbox=1`. On your Mac it creates:

| What | Where |
|---|---|
| State, credentials, SSH keys, pinned host key, transcript | `~/.config/tmbox/` (or `$XDG_CONFIG_HOME/tmbox/`) |
| The tunnel's LaunchDaemon | `/Library/LaunchDaemons/pl.lab22.tmbox.tunnel.plist` |
| The tunnel's helper, key and pinned host key | `/Library/Application Support/tmbox/` |
| The tunnel's log | `/Library/Logs/tmbox/tunnel.log` |
| A loopback alias the SMB client needs | `127.0.0.2` on `lo0` |
| A Time Machine destination | `smb://tmuser@127.0.0.2/tm-<mac-name>` |

tmbox does not install itself as a command. Keep `tmbox.zsh` and run it with
`zsh tmbox.zsh <command>`; the rest of this page writes that as `tmbox
<command>`. An alias does the same: `alias tmbox='zsh ~/tmbox.zsh'`.

## Requirements

- A Mac running macOS 26 or later. Nothing else - no Homebrew, no Xcode tools.
  tmbox refuses to run on an older macOS, because nothing it does has been
  checked there. Nothing on the Mac side is specific to Apple silicon, but only
  Apple silicon has been tested.
- An administrator account. macOS asks for your password through `sudo`, to
  bind port 445 on the loopback alias, install the tunnel's LaunchDaemon and set
  the Time Machine destination. The password goes to `sudo`; tmbox never sees
  or stores it.
- A payment card. Hetzner account creation is the one step nobody can automate
  for you; the script opens the page and waits.
- Full Disk Access for the terminal app you run setup in (Terminal, iTerm,
  kitty, …), in System Settings → Privacy & Security → Full Disk Access. macOS
  accepts a new Time Machine destination only from a program that has it, and
  there is no command-line way to grant it. Setup checks before it creates
  anything and stops if it is missing. Quit and reopen the terminal app after
  switching it on; a running app does not pick up the change. It is needed for
  that one step: once setup has finished you can switch it off again, and
  `tmbox status` then shows the backup history as not readable rather than
  empty.

## Usage

```
tmbox <command> [options]
```

Run with no command, or with `--help`, for the full usage text.

### Commands

**`tmbox setup`** builds everything, in nine steps: capacity and a name for this
Mac, the Hetzner account, an API token, a confirmation screen with the monthly
cost, provisioning, the appliance bootstrap, the tunnel, the Time Machine
destination, and the first backup. Nothing is created in Hetzner before you
confirm on the cost screen, and the prices shown there are read live from
Hetzner's API. Every step records what it did, the moment it does it, so setup
can be stopped at any point and run again. On a Mac that already has an
appliance, or part of one, it shows what exists and asks once whether to
continue; it does not ask again for the size, the name or the location, and
creates only what is missing. Before it connects to the appliance it re-pins
the firewall if this connection's public address has changed, and it re-reads
the share password from the appliance if the copy on this Mac differs. Needs a
terminal unless run with `--non-interactive`.

**`tmbox status`** answers four questions - is a backup running, when was the
last one, is the tunnel up, how full is the appliance - and shows the monthly
cost. It is read-only and never changes anything. It still works when the
appliance is unreachable, and says so.

**`tmbox doctor [--fix]`** runs every known failure as a named check: the
tunnel daemon, whether Samba actually answers through the tunnel (it sends a
real SMB2 negotiate, not just a TCP connect), whether the tunnel has been
dropping and restarting, whether the firewall still allows this Mac's current
public address, whether the appliance is locked, the ZFS pool's health, the
Storage Box mount, the loop device, Samba, free space, stale Samba sessions,
the Time Machine destination, Time Machine encryption and the last backup.

With `--fix` it repairs the three faults that are safe to repair without
asking: it re-pins the firewall to this Mac's current address, clears stale
Samba sessions by restarting Samba, and restarts a tunnel that is down.
Everything else is reported with the command that would fix it.

Exit status, so it can run from cron or a monitoring job:

| Code | Meaning |
|---|---|
| 0 | Every check passed |
| 1 | At least one check failed |
| 2 | Warnings only, nothing broken |
| 3 | This Mac has no appliance recorded, so nothing was checked |

**`tmbox unlock`** sends the ZFS passphrase to an appliance that has rebooted,
so it can serve the share again. It first asks the appliance whether it is
locked, and does nothing if it is not. The passphrase comes from the copy this
Mac saved during setup, from `--zfs-passphrase`, or from a prompt, in that
order, and it travels over SSH on standard input - never on a command line and
never into a file on the appliance. It then reports whether Samba came back.
Exit status: 0 unlocked or already unlocked, 3 no appliance recorded, 4 the
appliance did not answer, 5 the passphrase was not accepted, 6 no passphrase
available.

**`tmbox tunnel <action>`** manages the LaunchDaemon that carries SMB over SSH.
Actions: `install`, `uninstall`, `start`, `stop`, `restart`, and `status` (the
default). Setup installs the tunnel itself; these are for repair. A stopped
tunnel means failed backups until it is started again.

**`tmbox destroy [--delete-storage-box] [--yes]`** tears the appliance down and
then audits your Hetzner project against the API. See
[Uninstalling](#uninstalling).

**`tmbox help`** and **`tmbox version`** do what they say.

### General options

| Option | Effect |
|---|---|
| `-h`, `--help` | Usage text |
| `-V`, `--version` | Version, and build date for the built file |
| `-v`, `--verbose` | Show on screen everything the transcript records |
| `-q`, `--quiet` | Errors only |
| `--no-color` | No ANSI colour. `NO_COLOR` is honoured too |

### Running unattended

Every question tmbox asks can be answered in advance: by its own flag, by
`--yes` for the ordinary confirmations, by an environment variable, or by an
answers file. Precedence is flag, then environment, then answers file, then the
prompt's own default.

| Option | Effect |
|---|---|
| `-y`, `--yes` | Accept every ordinary confirmation. It never answers the one that deletes the Storage Box |
| `-n`, `--non-interactive` | Never prompt. A missing answer is an error that names the flag that would have supplied it |
| `--answers FILE` | Answers as `KEY=value`, one per line. Lines starting with `#` are comments |
| `--show-answers` | Print the answers in force, secrets masked, then exit |
| `--dry-run` | Setup stops after the cost screen; nothing is created in Hetzner |

Setup answers:

| Flag | Meaning |
|---|---|
| `--capacity` | `1TB`, `2TB`, `4TB`, `5TB` or `10TB`. tmbox picks the smallest Storage Box that fits |
| `--region` | A location Hetzner offers CAX11 in, such as `fsn1`, `nbg1` or `hel1`. The menu is built from the API |
| `--mac-name` | The name of this Mac's share. Reduced to `a-z`, `0-9` and `-`, 24 characters at most |
| `--hetzner-token` | The Hetzner Cloud API token, with Read & Write permission |
| `--container-mb` | Size of the pool's container file in MiB. Defaults to 95% of the Storage Box |
| `--backup-wait` | Minutes to watch the first backup. `0` starts it and returns; unset watches until it ends |
| `--zfs-passphrase` | The appliance's dataset passphrase, for `tmbox unlock` |

Any answer can also be given as `TMBOX_ANSWER_<KEY>` in the environment, for
example `TMBOX_ANSWER_CAPACITY=2TB`.

`--fix` (for `doctor`) and `--delete-storage-box` (for `destroy`) are described
with their commands.

One thing still needs a person or a policy: administrator rights. Unattended,
run tmbox under `sudo` or from an account with passwordless `sudo`, or it stops
at the step that needs them.

```zsh
tmbox setup --capacity 2TB --region fsn1 --mac-name studio --yes
TMBOX_ANSWER_HETZNER_TOKEN=... tmbox setup --non-interactive --answers ./studio.answers
```

## What it costs

About **€17.39 a month at 2 TB**, net of VAT, at Hetzner's prices in September
2026: a CAX11 server with its IPv4 address (€6.49) and a BX21 Storage Box
(€10.90). 4 TB lands on the same Storage Box tier and costs the same.

Everything is billed by Hetzner to your own account; nothing is hosted or
billed by us. Setup reads the current prices from Hetzner's API and shows the
total before it creates anything, so the figure on that screen is the one that
counts. Hetzner bills hourly against a monthly cap, and VAT is added according
to your account's country.

## Limitations in 0.1.0

Read these before you trust it with your only backup.

- **A rebooted appliance stops your backups until you unlock it.** The
  appliance comes up with its encrypted dataset locked, because the key is
  never stored on it. Nothing unlocks it automatically yet. Until you run
  `tmbox unlock` from your Mac, Time Machine has nowhere to write. `tmbox
  status` and `tmbox doctor` both report a locked appliance.
- **Restoring needs a working Mac.** To reach your backups you need a Mac with
  tmbox's state (`~/.config/tmbox/`, which holds the keys, the address and the
  credentials) and the ZFS passphrase. Restoring from macOS Recovery is not
  supported and has not been tested. 0.1.0's testing covered backing up, not
  restoring.
- **The ZFS passphrase exists only on the Mac that ran setup**, in
  `~/.config/tmbox/secrets/zfs-passphrase`. If that Mac is lost, so are the
  backups: nobody, including us, can unlock the appliance without it. 0.1.0
  does not produce a recovery card, so **copy that file - better, the whole
  `~/.config/tmbox/` directory - somewhere durable that does not depend on
  this Mac**, such as a password manager or an encrypted drive kept elsewhere.
- **Time Machine's own encryption cannot be turned on for you.** macOS has no
  command-line way to set it, so tmbox cannot. Your data is still encrypted at
  rest by ZFS on the appliance, so the Storage Box holds nothing readable; but
  while the appliance is unlocked, anyone with root on it could read the
  backups. Time Machine's encryption is the layer that excludes everyone else.
  tmbox reports whether it is on. To turn it on: System Settings → General →
  Time Machine, remove the tmbox destination, add it again and tick **Encrypt
  Backup Disk**. If macOS asks for the share's credentials, the user is
  `tmuser` and the password is in `~/.config/tmbox/secrets/samba-password`.
  Keep the encryption password you choose; tmbox does not store it, and it
  cannot be recovered.
- **A rebuilt appliance can need a Mac restart.** Once this Mac has backed up
  to one appliance, a destination pointing at a rebuilt one can fail every
  backup with an authentication error until the Mac restarts - even under a
  different Mac name, and even if the old destination was removed first. tmbox
  cannot clear this. It warns you when it replaces an old destination itself;
  if you removed it by hand or chose a different name, restart the Mac before
  the first backup.
- **The firewall is pinned to your Mac's public IP address.** When that address
  changes - a new ISP lease, another network - backups stop. Run `tmbox doctor
  --fix` to re-pin it. That needs the Hetzner API token this Mac saved during
  setup.
- **macOS 26 or later only, and one server type.** The appliance is always a
  Hetzner CAX11 (Arm64) running Debian 13.

## Security model

- **SMB is never exposed to the internet.** The Hetzner firewall allows only
  SSH and ping, and only from your Mac's public address. Samba is reached
  through one outbound SSH connection from your Mac, and it requires SMB 3.1.1
  with encryption on top of that.
- **The tunnel's key can do one thing.** On the appliance it is restricted to
  opening a single forward to Samba's port - no shell, no other forward.
- **Host keys are pinned.** The appliance's SSH host key is recorded on first
  connection, and a different key afterwards is refused. Hetzner recycles
  addresses, so trusting whatever answers would mean trusting the next holder
  of yours.
- **The encryption key is never stored on the appliance.** The ZFS passphrase
  is generated on your Mac and sent over SSH into `zfs load-key`'s standard
  input, so it exists on the appliance only in memory. That is why a disk,
  Storage Box or snapshot held by anyone else is ciphertext - and why a reboot
  locks the appliance.
- **No credential is ever passed on a command line**, where `ps` would show it.
  The Hetzner token reaches `curl` through a config read from standard input,
  and passwords travel on standard input or in mode-0600 temporary files. A
  test enforces this.
- **Credentials are files, not keychain items**, mode 0600 under
  `~/.config/tmbox/secrets/`. At rest they are protected by FileVault; while
  you are logged in, anything running as you can read them, exactly as with
  `~/.ssh`.

## Uninstalling

```zsh
tmbox destroy
```

This removes, in order: the tunnel from this Mac, the server (after stopping
Samba and closing the pool cleanly), its IPv4 address, the firewall and the SSH
key registered with Hetzner. It then asks the Hetzner API what is still there
and reports anything billing, so a resource tmbox failed to record is found
rather than forgotten. `--yes` answers its confirmation, for an unattended
teardown.

**The Storage Box is kept** - it holds your backups, and it keeps billing. So
are the credentials on this Mac, because without them the backups on that box
cannot be read. To delete the Storage Box as well:

```zsh
tmbox destroy --delete-storage-box
```

That asks a second, separate question before deleting anything, and `--yes`
never answers it; only `--delete-storage-box` does. There is no undo. Once the
Storage Box is gone, destroy also removes tmbox's credentials, keys and state
from this Mac.

destroy also removes the tunnel and the Time Machine destination from this Mac,
whether or not the Storage Box is kept; removing a destination deletes nothing
on it. That needs Full Disk Access for the terminal app, as setting it did; without
it destroy carries on and prints the `tmutil removedestination` command to run
later. If you set tmbox up again on the same Mac and the first backup fails with
an authentication error, restart the Mac: macOS can keep the old destination's
connection state for the 127.0.0.2 address until then.

## Why zsh

zsh has been the default login shell for new accounts since macOS 10.15, and
Apple has pointed developers at it in anticipation of `/bin/bash` going away.
The bash that ships is 3.2.57, frozen in 2007 because bash 4 moved to GPLv3 -
so `curl … | bash` on a Mac means an eighteen-year-old shell with no
associative arrays, byte-wise string lengths, and a deprecation notice over it.
Targeting `/bin/zsh` 5.9 is both the more capable choice and the more durable
one. The installer is macOS-only by definition - it drives `tmutil` - so
nothing is lost by not being portable to Linux.

The appliance half is a separate story: `appliance/bootstrap.sh` runs on Debian
under bash, because Debian does not ship zsh. `tools/lint.zsh` checks each half
with the interpreter it actually runs on and refuses zsh builtins in the Debian
half.

## Development

```zsh
make help      # every target
make check     # lint + unit tests, under /bin/zsh
make dist      # build dist/tmbox.zsh and its SHA-256
make demo      # render the interface without provisioning anything
```

Tests and lint both run under Apple's `/bin/zsh` on purpose: a check that passes
under a Homebrew zsh and fails under 5.9 is a check that did not run.

Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## Reporting a security issue

Please do not open a public issue. See [SECURITY.md](SECURITY.md).

## Licence

BSD-3-Clause. Copyright (c) 2026, Lab22 Poland Sp. z o.o. See [LICENSE](LICENSE).

tmbox is a backup destination for Apple Time Machine. It is not affiliated with
or endorsed by Apple Inc. or by Hetzner Online GmbH.
