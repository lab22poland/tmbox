# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | Yes |

Fixes are made on the latest 0.1.x release.

## Reporting a vulnerability

Please report vulnerabilities privately, not in a public issue or pull request.

Use GitHub's private vulnerability reporting on
[lab22poland/tmbox](https://github.com/lab22poland/tmbox): open the
**Security** tab, then **Report a vulnerability**. The report is visible only to
the maintainers until an advisory is published.

A useful report says:

- which version you ran (`tmbox --version`), and on which macOS version;
- what an attacker can do, and from where - the network, another account on the
  Mac, the Hetzner side, or the appliance;
- the steps to reproduce it, or the code it is in.

Please leave out real credentials, API tokens, IP addresses and Storage Box
identifiers. The transcript in `~/.config/tmbox/tmbox.log` masks secrets, but
check it before attaching it.

## Scope

In scope: the installer (`tmbox.zsh` and everything under `bin/`, `cmd/`, `lib/`
and `macos/`), the appliance bootstrap (`appliance/`), and the release artifact
and its published digest.

Out of scope: vulnerabilities in macOS, Time Machine, Debian, OpenZFS, Samba,
OpenSSH or Hetzner's services themselves - please report those to their
maintainers. The limitations listed in the README under "Limitations in 0.1.0"
are known and documented, though a way to exploit one beyond what is described
there is welcome.
