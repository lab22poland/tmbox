#!/bin/zsh
#
# tmbox limit - how much of this connection's upload a backup may take (#20).
#
#   tmbox limit            what is in force, on the appliance itself
#   tmbox limit 20         at most 20 Mbit/s
#   tmbox limit auto       measure the upload and take 80% of it
#   tmbox limit off        no limit
#
# The same choice is offered once during setup, before the first backup, which
# is the one moment the line is guaranteed to be idle enough to measure. The
# mechanism and the measurements behind it are in lib/uplink.zsh and
# appliance/shape.sh.

cmd_limit() {
  local arg="${1:-}"
  (( $# <= 1 )) || ui_die "tmbox limit takes one value: a rate in Mbit/s, auto or off."

  ui_banner "tmbox limit" "How much of the upload backups may take"

  local host; host="$(appliance_host)"
  if [[ -z "$host" ]]; then
    ui_bad "This Mac has no appliance recorded."
    ui_say "Run 'tmbox setup' first."
    return 3
  fi

  if [[ -z "$arg" ]]; then
    limit_report "$host"
    return $?
  fi

  local rate
  if ! rate="$(uplink_parse "$arg")"; then
    ui_bad "'${arg}' is not a rate tmbox understands."
    ui_say "Give it in Mbit/s, from 0.5 up - for example 'tmbox limit 20' - or 'auto' or 'off'."
    return 2
  fi

  if [[ "$rate" == auto ]]; then
    rate="$(limit_measure_default "$host")" || return $?
  fi

  limit_apply "$host" "$rate"
}

# limit_report <host> - what the appliance says is in force
limit_report() {
  local host="$1" out
  if ! out="$(ssh_run "$host" "$UPLINK_SHAPER show" 2>/dev/null)"; then
    # Appliances built before 0.1.4 have no shaper at all, which is "no limit"
    # rather than a fault; anything else is the appliance not answering.
    if ssh_run "$host" true >/dev/null 2>&1; then
      ui_kv "Upload limit" "none - this appliance predates it"
      ui_say "Set one with tmbox limit auto, or tmbox limit <Mbit/s>."
      return 0
    fi
    ui_bad "The appliance at ${host} did not answer."
    return 4
  fi

  local configured active
  configured="$(uplink_field "$out" configured)" || configured=off
  active="$(uplink_field "$out" active)" || active=off
  ui_kv "Upload limit" "$(uplink_fmt "$configured")"
  if [[ "$configured" != "$active" ]]; then
    ui_warn "The appliance has $(uplink_fmt "$configured") recorded, but $(uplink_fmt "$active") is in force."
    ui_say "Apply it again with tmbox limit $(limit_mbit "$configured")."
    return 1
  fi
  if [[ "$configured" == off ]]; then
    ui_say "A backup can take the whole upload of this connection. tmbox limit auto measures it and leaves a fifth for everything else."
  fi
  return 0
}

# limit_measure_default <host> - 80% of a fresh measurement, in kbit/s
#
# Refused while a backup to the appliance is running: the measurement would see
# only what that backup leaves over, and suggest a limit lower still.
limit_measure_default() {
  local dest; dest="$(state_get destination_id)"
  if tm_running "$dest"; then
    ui_bad "A backup to the appliance is running, so the upload cannot be measured now."
    ui_say "Give a rate instead - tmbox limit 20 - or run tmbox limit auto when no backup is running."
    return 5
  fi

  local measured
  ui_spin_start "Measuring the upload of this connection (about ${UPLINK_NQ_SECONDS} seconds)"
  if ! measured="$(uplink_measure)"; then
    ui_spin_stop bad "Could not measure the upload"
    ui_say "networkQuality did not return a result. Give a rate instead: tmbox limit 20"
    return 6
  fi
  ui_spin_stop ok "Upload measured: $(uplink_fmt "$measured")"
  print -rn -- "$(limit_round "$(uplink_share "$measured")")"
}

# limit_apply <host> <kbit|off>
limit_apply() {
  local host="$1" rate="$2" out
  ui_spin_start "Setting the limit on the appliance"
  if ! out="$(uplink_apply "$host" "$rate")"; then
    ui_spin_stop bad "Could not set the limit"
    ui_say "The transcript has what the appliance said: ${TMBOX_LOG_FILE:-tmbox.log}"
    return 1
  fi
  ui_spin_stop ok "Done"

  local active; active="$(uplink_field "$out" active)" || active=""
  if [[ "$active" != "$rate" ]]; then
    ui_warn "The appliance recorded $(uplink_fmt "$rate"), but reports $(uplink_fmt "${active:-off}") in force."
    return 1
  fi
  if [[ "$rate" == off ]]; then
    ui_kv "Upload limit" "none - a backup can take the whole upload"
  else
    ui_kv "Upload limit" "$(uplink_fmt "$rate"), for backups only"
    ui_say "If the connection still slows down during a backup, lower it: the upload a line can sustain under load is often well below what a speed test shows, especially on LTE and 5G."
  fi
  return 0
}

# limit_round <kbit> - whole Mbit/s, down, once there are any to round to
limit_round() {
  if (( $1 >= 2000 )); then
    print -rn -- $(( $1 / 1000 * 1000 ))
  else
    print -rn -- "$1"
  fi
}

# limit_mbit <kbit|off> - the same rate as someone would type it
limit_mbit() {
  [[ "$1" == <-> ]] || { print -rn -- off; return 0 }
  if (( $1 % 1000 == 0 )); then
    print -rn -- $(( $1 / 1000 ))
  else
    printf '%.1f' $(( $1 / 1000.0 ))
  fi
}

# limit_setup <host> - the question setup asks, once, before the first backup
#
# Asked after the tunnel works and before the first backup starts, because that
# is when the line is idle and the measurement means something. Answered once:
# a resumed setup does not ask again, and tmbox limit changes it later.
limit_setup() {
  local host="$1"
  state_has uplink_kbit && return 0

  ui_blank
  ui_say "Time Machine sends a backup as fast as the connection allows, and on many lines that makes everything else on the network slow or drop while it runs. tmbox can cap the backup instead, on the appliance, leaving the rest of the upload free."

  local measured="" def="off"
  local preset; preset="$(ans_get UPLINK_LIMIT)"
  # A preset rate needs no measurement; auto, or a question, does.
  if [[ -z "$preset" || "$(uplink_parse "$preset" 2>/dev/null)" == auto ]]; then
    ui_spin_start "Measuring the upload of this connection (about ${UPLINK_NQ_SECONDS} seconds)"
    if measured="$(uplink_measure)"; then
      ui_spin_stop ok "Upload measured: $(uplink_fmt "$measured")"
      def="$(limit_mbit "$(limit_round "$(uplink_share "$measured")")")"
    else
      measured=""
      ui_spin_stop warn "Could not measure the upload"
      log_warn "networkQuality gave no result; offering no limit as the default"
    fi
  fi

  local answer rate
  while :; do
    answer="$(ui_ask UPLINK_LIMIT "Limit backups to how many Mbit/s (or off)" "$def")"
    if rate="$(uplink_parse "$answer")"; then
      if [[ "$rate" == auto ]]; then
        if [[ -n "$measured" ]]; then
          rate="$(limit_round "$(uplink_share "$measured")")"
          break
        fi
        rate=off
        ui_warn "Nothing was measured, so auto means no limit for now. tmbox limit auto tries again later."
      fi
      break
    fi
    ui_bad "'${answer}' is not a rate. Give Mbit/s, for example 20, or off."
    # A pre-supplied answer that does not parse would loop for ever.
    if ans_has UPLINK_LIMIT || (( TMBOX_NONINTERACTIVE )); then
      ui_die "--uplink-limit takes a rate in Mbit/s, auto or off."
    fi
  done

  if ! limit_apply "$host" "$rate"; then
    ui_warn "The backup goes ahead without a limit. tmbox limit tries again."
  fi
}
