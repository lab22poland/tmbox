#!/bin/zsh
#
# Sourced by both test runners before anything else.
#
# Every path tmbox writes to, pointed at a scratch directory before any suite
# sources a library. Each library computes its paths once, when it is sourced,
# from $HOME - so a suite that set its own scratch directory afterwards still
# wrote credentials to the real ~/.config/tmbox/secrets. It did: on 2026-10-03
# a test run replaced every credential of a live installation with test values,
# including the ZFS passphrase, which the appliance was then built with (#11).
# HOME itself is moved too, so a path nobody thought of lands here as well.
typeset -g TEST_HOME; TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/tmbox-tests.XXXXXX")" || exit 1
trap 'rm -rf -- "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export XDG_CONFIG_HOME="$TEST_HOME/.config"
export TMBOX_STATE_DIR="$XDG_CONFIG_HOME/tmbox"
export TMBOX_STATE_FILE="$TMBOX_STATE_DIR/state.json"
export TMBOX_SECRET_DIR="$TMBOX_STATE_DIR/secrets"
export SSH_KEY_DIR="$TMBOX_STATE_DIR/keys"
export SSH_KNOWN_HOSTS="$TMBOX_STATE_DIR/known_hosts"
export TMBOX_LOG_FILE="$TMBOX_STATE_DIR/tmbox.log"
