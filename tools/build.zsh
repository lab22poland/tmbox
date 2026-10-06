#!/bin/zsh
#
# Build dist/tmbox.zsh: one self-contained file, no runtime fetches.
#
# Why one file rather than a loader that pulls stages over HTTPS: the published
# form is `curl … | zsh`, and a script that downloads more script has a second
# supply-chain surface that must then be pinned by hash, verified, and kept in
# step with the first. Concatenating at build time removes the second stage
# instead of securing it. One artifact, one SHA-256, one thing for a reader to
# audit before running it.
#
# The appliance payloads are embedded the same way and delivered over SSH, so
# the appliance never fetches anything from us either - only from Debian, which
# is also what keeps the CDDL/GPL question out of the product.
#
#   make dist
#
emulate -L zsh
setopt err_exit no_unset pipe_fail

typeset -g ROOT="${0:A:h:h}"
cd -- "$ROOT"

typeset -g OUT="dist/tmbox.zsh"
typeset -g VERSION="$(cat -- VERSION)"
# The build has to be reproducible, because the whole supply-chain story is one
# published SHA-256 that a user compares against what they downloaded. So the
# artifact carries no time at all, only the version.
#
# A wall clock made every build a different artifact. The commit time was tried
# next and was no better: the digest is a tracked file, so recording it made a
# new commit and moved the stamp, and a squash or rebase merge on GitHub
# rewrites commit times as well. Anything that can change without the source
# changing does not belong in the file.

# Order matters: answers before ui, because every prompt consults it; ui and log
# before anything that might report an error; json before the API clients that
# parse with it.
typeset -ga LIBS=(
  lib/answers.zsh
  lib/log.zsh
  lib/ui.zsh
  lib/json.zsh
  lib/http.zsh
  lib/state.zsh
  lib/secrets.zsh
  lib/sshx.zsh
  lib/macos.zsh
  lib/transport.zsh
  lib/hcloud.zsh
  lib/hbox.zsh
  lib/preflight.zsh
  lib/uplink.zsh
)

typeset -ga CMDS=(
  cmd/setup.zsh
  cmd/status.zsh
  cmd/doctor.zsh
  cmd/tunnel.zsh
  cmd/transport.zsh
  cmd/unlock.zsh
  cmd/destroy.zsh
  cmd/limit.zsh
  cmd/firewall.zsh
)

mkdir -p dist
: > "$OUT"

# --- header -----------------------------------------------------------------

cat >> "$OUT" <<EOF
#!/bin/zsh
#
# tmbox $VERSION - a private Time Machine destination on Hetzner.
# Built from https://github.com/lab22poland/tmbox
#
# Copyright (c) 2026, Lab22 Poland Sp. z o.o.  BSD-3-Clause; see LICENSE.
#
# This file is generated. Edit the sources in lib/ and cmd/, then \`make dist\`.
#
# Targets /bin/zsh 5.9, the default login shell on every supported macOS.
# Apple froze /bin/bash at 3.2.57 in 2007 for licence reasons and has signalled
# it may be removed; zsh is where macOS is going, so that is what this targets.

emulate -L zsh
setopt no_unset pipe_fail extended_glob

typeset -g TMBOX_VERSION="$VERSION"
typeset -g TMBOX_BUNDLED=1
EOF

# --- embedded appliance payloads --------------------------------------------
#
# base64 rather than a heredoc: the bootstrap is itself a shell script full of
# heredocs, quotes and backslashes, and nesting those inside another heredoc is
# how a build system starts corrupting its own payload. Encoded, it is opaque to
# the shell and round-trips exactly.

embed_b64() {
  # `file`, not `path` - see append_source below. The same mistake here was
  # quieter and more confusing: PATH became "appliance/bootstrap.sh", so base64
  # and tr stopped resolving and the build failed with "command not found" for
  # tools that are obviously installed.
  local var="$1" file="$2"
  [[ -f "$file" ]] || { print -u2 -- "build: missing payload $file"; exit 1 }
  # An empty payload is a placeholder, not a payload: it would embed as '' and
  # the runtime would treat it as absent, or worse, install an empty file. A
  # piece that is not built yet stays out of the list until it is.
  [[ -s "$file" ]] || { print -u2 -- "build: empty payload $file"; exit 1 }
  print -r -- ""                          >> "$OUT"
  print -r -- "# --- embedded: $file ---" >> "$OUT"
  print -rn -- "typeset -g ${var}_B64='"  >> "$OUT"
  base64 < "$file" | tr -d '\n'           >> "$OUT"
  print -r -- "'"                         >> "$OUT"
}

embed_b64 TMBOX_BOOTSTRAP    appliance/bootstrap.sh
embed_b64 TMBOX_SHAPER       appliance/shape.sh
embed_b64 TMBOX_TUNNEL_PLIST macos/tunnel.plist
embed_b64 TMBOX_TUNNEL_BIN   macos/tmbox-tunnel
embed_b64 TMBOX_SETDEST_EXP  macos/setdest.exp
embed_b64 TMBOX_TRANSPORT    appliance/transport.sh
embed_b64 TMBOX_WG_BIN       macos/tmbox-wireguard
embed_b64 TMBOX_WG_PLIST     macos/wireguard.plist

# --- libraries and commands -------------------------------------------------
#
# Each source loses its shebang and its own `emulate`/`setopt` preamble, which
# the header above has already established for the whole file. Everything else,
# comments included, survives: a reader auditing the one-liner should see the
# same reasoning a reader of the repository sees.

append_source() {
  # `file`, not `path`: in zsh that name is tied to $PATH, so a local of that
  # name replaces the command search path for the whole function.
  local file="$1" bar
  bar="${(l:60-${#file}::=:):-}"
  print -r -- ""                     >> "$OUT"
  print -r -- "# ===== $file $bar"   >> "$OUT"
  sed -e '1{/^#!/d;}' \
      -e '/^emulate -L zsh$/d' \
      -e '/^setopt .*$/d' \
      -- "$file"                     >> "$OUT"
}

local f
for f in $LIBS $CMDS; do
  [[ -f "$f" ]] || { print -u2 -- "build: missing source $f"; exit 1 }
  append_source "$f"
done

print -r -- ""                                          >> "$OUT"
print -r -- "# ===== entry point ${(l:44::=:):-}"        >> "$OUT"
sed -e '1{/^#!/d;}' -e '/^emulate -L zsh$/d' -e '/^setopt .*$/d' \
    -- bin/tmbox.zsh                                     >> "$OUT"

chmod 0755 "$OUT"

# --- verify what we just produced -------------------------------------------
#
# A build that emits a broken script and reports success is worse than no build,
# because the failure then surfaces on a user's machine rather than on ours.

/bin/zsh -n -- "$OUT" || { print -u2 -- "build: generated file does not parse"; exit 1 }

/bin/zsh -- "$OUT" --version >/dev/null 2>&1 \
  || { print -u2 -- "build: generated file cannot run --version"; exit 1 }

# The published form is a pipe, and a pipe means stdin is the script. Prove the
# artifact survives that, because it is the only way most people will run it.
#
# `cat` rather than `$(<file)`: zsh resolves the latter even under `zsh -n`, so
# a null-command form would make this file fail its own syntax check.
cat -- "$OUT" | /bin/zsh -s -- --version >/dev/null 2>&1 \
  || { print -u2 -- "build: generated file fails when piped into zsh"; exit 1 }

# Nothing that looks like a credential may leave here. The artifact is the one
# file that gets published, so this is the last point at which a secret that
# wandered into a source file - a token pasted into a comment while debugging,
# a test fixture with a real key in it - can still be caught for free.
#
# Shape-based, because the build cannot know any particular secret: a private
# key block, or a long unbroken run of credential-shaped characters assigned to
# a credential-shaped name. Base64 payloads are excluded by construction, since
# they are assigned to TMBOX_*_B64 names this does not match.
if grep -qE 'BEGIN (OPENSSH|RSA|EC|PGP) PRIVATE KEY' -- "$OUT"; then
  print -u2 -- "build: the artifact contains a private key"
  exit 1
fi
if grep -nE '(TOKEN|PASSWORD|SECRET|PASSPHRASE|APIKEY|API_KEY)[A-Za-z_]*=["'"'"']?[A-Za-z0-9+/_-]{16,}' -- "$OUT"; then
  print -u2 -- "build: the artifact assigns something credential-shaped (above)"
  exit 1
fi

# The standard `<hex>  tmbox.zsh` line, written from inside dist/ so it names
# the file by its basename. A user who downloads both release assets into one
# directory can then check them with `shasum -a 256 -c tmbox.zsh.sha256`.
( cd -- "${OUT:h}" && shasum -a 256 -- "${OUT:t}" ) > "$OUT.sha256"

digest="$(awk '{print $1}' < "$OUT.sha256")"
printf 'dist/tmbox.zsh  %s bytes  sha256 %s\n' \
  "$(wc -c < "$OUT" | tr -d ' ')" "$digest"
