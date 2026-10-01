#!/bin/zsh
#
# Render every widget in lib/ui.zsh without provisioning anything.
#
# This exists because the interface is the part of tmbox that cannot be
# unit-tested: no assertion tells you whether a wizard reads well. `make demo`
# is how the layout gets reviewed, and how a change to the colour or the box
# drawing gets checked on a light terminal, a dark one, and with NO_COLOR set.
#
#   make demo                 # pre-answered, renders start to finish
#   make demo-tty             # real prompts, for the interactive path
#   NO_COLOR=1 make demo      # the monochrome fallback
#   LANG=C make demo          # the ASCII fallback
#
emulate -L zsh
setopt no_unset pipe_fail extended_glob

typeset -g ROOT="${0:A:h:h}"
typeset -g TMBOX_VERSION="$(cat -- "$ROOT/VERSION")"

source "$ROOT/lib/answers.zsh"
source "$ROOT/lib/log.zsh"
source "$ROOT/lib/ui.zsh"

if [[ "${1:-}" == "--interactive" ]]; then
  ui_init || exit 1
else
  ans_set CAPACITY  "2TB"  "demo"
  ans_set REGION    "fsn1" "demo"
  ans_set PROCEED   "yes"  "demo"
  # Every prompt is pre-answered, so the demo renders without a terminal too -
  # which is how it gets reviewed from a build log or an editor pane.
  typeset -g TMBOX_FORCE_COLOR="${TMBOX_FORCE_COLOR:-1}"
  ui_init --no-tty-ok || exit 1
fi

ui_banner "tmbox $TMBOX_VERSION" "A private Time Machine destination on Hetzner"

ui_say "Body text wraps at the layout width, so a long paragraph explaining what is about to happen, and what it will cost, stays readable in a narrow terminal as well as a wide one."
ui_blank

ui_rule "Status lines"
ui_blank
ui_ok   "Storage Box reachable, SMB 3.1.1 negotiated"
ui_warn "Backports carries a newer ZFS; using the stock package"
ui_bad  "direct I/O is off on /dev/loop0 - refusing to import tank"
ui_item "A neutral bullet, for lists that are not outcomes"
ui_next "And the one that points at what happens next"
ui_blank

ui_rule "Key/value"
ui_blank
ui_kv "Server"      "cax11, arm64, Debian 13"
ui_kv "Location"    "fsn1 (Falkenstein)"
ui_kv "Storage Box" "bx21, 5 TiB"
ui_kv "Cost"        "EUR 17.39 / month net"
ui_blank

ui_step 3 9 "Your Hetzner API token"
ui_say "Open the console, create a Read & Write token, and paste it here. tmbox validates it before anything is created."
ui_blank

ui_rule "Waiting"
ui_blank
ui_spin_start "Creating the server"
sleep 2
ui_spin_stop ok "Server created, 203.0.113.10"
ui_spin_start "Waiting for cloud-init"
sleep 1
ui_spin_stop warn "cloud-init finished with warnings"
ui_blank

ui_rule "Progress"
ui_blank
typeset -i i=0
while (( i <= 40 )); do
  ui_progress $i 40 "preallocating tank.img  $(( i * 25 ))/1000 GiB"
  sleep 0.03
  (( i++ ))
done
ui_blank

ui_rule "Choices"
ui_blank
typeset -g capacity
capacity="$(ui_menu CAPACITY "How much space do you want?" \
  "1TB" "1 TB" "EUR 9.69/month. Enough for one Mac with a modest disk." \
  "2TB" "2 TB" "EUR 17.39/month. The common choice." \
  "5TB" "5 TB" "EUR 27.29/month. Two or three Macs, or one large one.")"
ui_kv "Chosen" "$capacity"
ui_blank

if ui_confirm PROCEED "Create these resources now?" "n"; then
  ui_ok "Proceeding"
else
  ui_warn "Stopped before anything was created"
fi
ui_blank

ui_banner "Done" "9 of 9 steps, first backup complete"
