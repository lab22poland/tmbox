# Changelog

All notable changes to tmbox are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and tmbox uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- WireGuard as a second transport, for a Mac whose address keeps changing - a phone's hotspot, LTE, 5G. The SSH tunnel is one TCP connection tied to the Mac's address and ends with it, taking a running backup along; WireGuard follows the Mac to its new address. Setup asks which to use (`--transport`). The Mac's side is `wireguard-go` from Homebrew, installed with your agreement and run by a LaunchDaemon of tmbox's own, or the App Store app (`--wireguard-client`). On the appliance, an nftables guard lets only Samba, SSH and ping through the tunnel, from this Mac only; the firewall opens udp/51820. `status`, `doctor`, `tmbox tunnel` and `destroy` handle it, and administration goes through the tunnel while it is up ([#22](https://github.com/lab22poland/tmbox/issues/22)).
- Tailscale as a third transport, for a Mac that already runs it: the appliance joins the owner's tailnet with an auth key that reaches it on standard input and is stored nowhere (`--tailscale-authkey`), and the same guard admits only Samba, SSH and ping from this Mac's tailnet address. If Tailscale is not installed, tmbox offers the standalone app from Tailscale's server and installs it only when the package is signed by Tailscale and notarised. `doctor` names the causes that matter here: Tailscale off, switched to another tailnet, this Mac's tailnet address changed, a relayed rather than direct path, an expiring appliance key, and a stale route that sends the appliance's address around Tailscale; `--fix` repairs the last two it can ([#22](https://github.com/lab22poland/tmbox/issues/22)).
- `tmbox transport [ssh | wireguard | tailscale]` switches an existing installation without touching its backups: the new transport is set up and checked, Time Machine is pointed at the same share through it and continues the same history, and only then is the old one removed ([#22](https://github.com/lab22poland/tmbox/issues/22)).
- `tmbox firewall [any | pin]` and `--admin-cidr any`: the appliance's SSH can be opened to every address instead of only this Mac's, for connections whose address keeps changing - a phone's hotspot, LTE, 5G - where the pin locked the Mac out after every change. Only tmbox's own keys can log in, and SMB stays closed to the internet. `doctor` reports an open firewall as such and no longer re-pins it ([#22](https://github.com/lab22poland/tmbox/issues/22)).

### Fixed

- `doctor` found stale Samba sessions only when their socket was gone. Through the SSH tunnel the socket is sshd's and can stay open after the Mac has closed its own, holding the backup image: the next backup failed with "Resource busy", and Samba's `deadtime` never reaps a session with open files. A session is now also stale when this Mac has no connection to the share at all and no backup is running, and `--fix` clears it ([#22](https://github.com/lab22poland/tmbox/issues/22)).
- The probe that checks Samba answers bounds its connection attempt too. On macOS `nc -w` does not, so a probe that could not connect waited about 75 seconds ([#22](https://github.com/lab22poland/tmbox/issues/22)).

## [0.1.4] - 2026-10-04

### Added

- An upload limit for backups. A backup otherwise takes the whole upload of the connection, and on lines with a deep modem buffer that made the rest of the network unusable and the router report the internet as down. Setup now measures the upload with macOS's `networkQuality` before the first backup and offers to cap backups at 80% of it (`--uplink-limit`). The cap is applied on the appliance with CAKE, to the tunnel's traffic only, and survives reboots. `tmbox limit` shows or changes it later and installs it on appliances built earlier; `status` shows it and `doctor` checks it is in force ([#20](https://github.com/lab22poland/tmbox/issues/20)).

## [0.1.3] - 2026-10-04

### Fixed

- A brief network stall no longer ends a backup. Samba and the macOS client both enable SMB multichannel by default; over the loopback tunnel the client's reconnect then failed to match 127.0.0.2 to a network interface and dropped every outstanding write, failing the backup with `BACKUP_FAILED_DISCONNECTED_NETWORK`. The appliance now turns multichannel off, and `tmbox doctor --fix` turns it off on appliances built earlier, when no backup is running ([#17](https://github.com/lab22poland/tmbox/issues/17)).

## [0.1.2] - 2026-10-03

### Fixed

- `tmbox destroy` removes the Time Machine destination it added, and with the Storage Box gone deletes the whole credentials directory rather than only the kinds the current version knows ([#13](https://github.com/lab22poland/tmbox/issues/13)).
- Running `tmbox setup` again on a Mac that already has an appliance resumes it: it shows what exists and asks once whether to continue, no longer asks for the size, name or location again or overwrites them, skips the cost screen when nothing is left to buy, and no longer says nothing is billed. It re-pins the firewall when the public address has changed and re-reads a share password that differs from the appliance's. A Storage Box is recorded as soon as it is ordered, so stopping setup while it activates no longer leads to a second one ([#4](https://github.com/lab22poland/tmbox/issues/4)).
- Missing Full Disk Access is detected before setup creates anything, with the app to grant it to and a reminder to restart that app. `tmutil`'s exit 80 is no longer reported as a wrong share password when its message says Full Disk Access, and its output is written to the log at the default level. `status` and `doctor` say the backup history needs Full Disk Access instead of reporting no backups ([#6](https://github.com/lab22poland/tmbox/issues/6)).
- On a Mac that also backs up to another destination, the first-backup step no longer shows that destination's backup as the appliance's, and starts the first backup with `--destination`. `tmbox status` and `tmbox doctor` report backups to the appliance only ([#7](https://github.com/lab22poland/tmbox/issues/7)).
- `tmbox doctor --fix` re-pins a changed address before it restarts the tunnel, and waits for Hetzner to apply the new firewall rules, instead of reporting a tunnel failure it then fixes ([#5](https://github.com/lab22poland/tmbox/issues/5)).
- The ssh commands tmbox prints for copying name its own `known_hosts`, so they no longer fail with "Host key verification failed" ([#5](https://github.com/lab22poland/tmbox/issues/5)).
- Running the test suite no longer writes to a real installation. The libraries computed their paths from `$HOME` when sourced, so the credential tests overwrote `~/.config/tmbox/secrets/`, including the ZFS passphrase. The runners now move every path into a scratch directory, and the suites refuse to run against the real one ([#11](https://github.com/lab22poland/tmbox/issues/11)).

## [0.1.1] - 2026-10-03

### Fixed

- The spinner shown during every wait in an interactive `tmbox setup` printed a literal `\r` and each frame on one growing line instead of redrawing in place ([#1](https://github.com/lab22poland/tmbox/issues/1)).

## [0.1.0] - 2026-10-01

The first release.

### Added

- `tmbox setup`: a nine-step guided flow from a stock Mac and no Hetzner account to a running Time Machine backup, with a cost screen read live from Hetzner's API before anything is created.
- Resumable setup: every step records what it did, so an interrupted run continues rather than starting over.
- Provisioning of a CAX11 server, reserved IPv4 address, Cloud Firewall, SSH key and Storage Box in the user's own Hetzner account, all labelled `tmbox=1`.
- Appliance bootstrap on Debian 13: a ZFS pool in a container file on the Storage Box, mounted `hard` with direct I/O asserted, a natively encrypted dataset with a per-Mac quota, and Samba with `vfs_fruit`, SMB 3.1.1 and mandatory encryption.
- A ZFS passphrase generated on the Mac and sent to the appliance only on standard input, never stored there.
- SMB carried over one outbound SSH connection, kept up by a LaunchDaemon that survives reboots and runs with nobody logged in, using a key restricted on the appliance to that single forward.
- A Hetzner firewall that admits only SSH and ping, only from the Mac's public address; SMB is never exposed.
- SSH host-key pinning on first connection.
- The Time Machine destination set unattended, and Time Machine encryption reported after the first backup.
- `tmbox status`: a read-only summary of backups, tunnel, appliance and cost.
- `tmbox doctor`: every known failure as a named check, including a real SMB2 negotiate through the tunnel; exit codes 0, 1 and 2 for scripts; `--fix` for firewall re-pinning, stale Samba sessions and a dead tunnel.
- `tmbox unlock`: unlocks a rebooted appliance with the passphrase saved on the Mac, a flag or a prompt.
- `tmbox tunnel`: install, uninstall, start, stop, restart and status for the SSH forward.
- `tmbox destroy`: ordered teardown followed by an audit against the Hetzner API; the Storage Box is deleted only with `--delete-storage-box`.
- Unattended operation: every prompt can be answered by a flag, `--yes`, a `TMBOX_ANSWER_*` environment variable or an `--answers` file, with `--non-interactive` and `--dry-run`.
- Credentials kept in mode-0600 files under `~/.config/tmbox/`, never in the keychain, and never passed on a command line.
- A single-file, reproducible build with a published SHA-256 and no runtime downloads.

### Known limitations

A rebooted appliance stays locked until `tmbox unlock` is run; restore needs a
working Mac and is not supported from macOS Recovery; the ZFS passphrase lives
only on the Mac that ran setup; Time Machine encryption has to be turned on by
hand; and the firewall must be re-pinned when the Mac's public address changes.
See [Limitations in 0.1.0](README.md#limitations-in-010) for the full list.

[Unreleased]: https://github.com/lab22poland/tmbox/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/lab22poland/tmbox/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/lab22poland/tmbox/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/lab22poland/tmbox/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/lab22poland/tmbox/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/lab22poland/tmbox/releases/tag/v0.1.0
