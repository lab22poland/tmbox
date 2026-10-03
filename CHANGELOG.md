# Changelog

All notable changes to tmbox are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and tmbox uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/lab22poland/tmbox/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/lab22poland/tmbox/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/lab22poland/tmbox/releases/tag/v0.1.0
