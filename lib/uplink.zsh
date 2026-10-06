#!/bin/zsh
#
# How much of this connection's upload a backup may take (#20).
#
# A backup over the tunnel otherwise takes all of it, and on a line with a deep
# buffer in the modem that makes everything else on the network wait behind
# it: measured on a real installation, ping rose to an average of 368 ms and
# the router reported the internet as down. The limit itself lives on the
# appliance (appliance/shape.sh); this file measures the line, turns answers
# into a rate, and hands the rate over.
#
# **Measured with macOS's own networkQuality**, which has shipped with every
# supported macOS since 12. Upload only (-d), machine-readable (-c), and capped
# in time (-M), so it costs about fifteen seconds and nothing to install. It
# uses a dozen parallel flows to Apple's measurement servers, which is what
# makes it a measure of the line rather than of one route.
#
# Rates are kept in kbit/s throughout, because that is what tc takes and what
# the state file records; Mbit/s exists only at the edge, where people type it.

typeset -g UPLINK_NQ="${UPLINK_NQ:-/usr/bin/networkQuality}"
typeset -g UPLINK_NQ_SECONDS="${UPLINK_NQ_SECONDS:-20}"
typeset -gi UPLINK_DEFAULT_PCT="${UPLINK_DEFAULT_PCT:-80}"
typeset -g UPLINK_SHAPER=/usr/local/sbin/tmbox-shape

# uplink_measure - the upload of this connection in kbit/s, or status 1
#
# The JSON carries an error_code even when it also carries a usable result: one
# lost flow among twelve is reported, and the throughput is still good. So the
# result is judged by ul_throughput alone.
uplink_measure() {
  [[ -x "$UPLINK_NQ" ]] || return 1
  local out bps
  out="$("$UPLINK_NQ" -d -c -M "$UPLINK_NQ_SECONDS" 2>/dev/null)" || out=""
  log_debug "networkQuality: ${out[1,200]}"
  bps="$(json_get '.ul_throughput | floor' "$out")" || return 1
  [[ "$bps" == <-> ]] || return 1
  (( bps >= 100000 )) || return 1
  print -rn -- $(( bps / 1000 ))
}

# uplink_share <kbit> [percent] - that share of it, in kbit/s
uplink_share() {
  print -rn -- $(( $1 * ${2:-$UPLINK_DEFAULT_PCT} / 100 ))
}

# uplink_parse <text> - kbit/s, "off", "auto", or status 1
#
# People type Mbit/s, because that is what every speed test shows them: "20",
# "20M", "20 Mbit/s", "2.5". A bare number is Mbit/s.
uplink_parse() {
  local t="${(L)1//[[:space:]]/}"
  case "$t" in
    off|none|no|0)   print -rn -- off;  return 0 ;;
    auto|measure)    print -rn -- auto; return 0 ;;
  esac
  t="${t%/s}"; t="${t%mbps}"; t="${t%mbit}"; t="${t%m}"
  [[ "$t" == <->(|.<->) ]] || return 1
  local -i kbit
  (( kbit = t * 1000 ))
  (( kbit >= 500 && kbit <= 10000000 )) || return 1
  print -rn -- $kbit
}

# uplink_fmt <kbit|off> - for people: "20 Mbit/s", "2.5 Mbit/s", "no limit"
uplink_fmt() {
  [[ "$1" == <-> ]] || { print -rn -- "no limit"; return 0 }
  if (( $1 % 1000 == 0 )); then
    print -rn -- "$(( $1 / 1000 )) Mbit/s"
  else
    printf '%.1f Mbit/s' $(( $1 / 1000.0 ))
  fi
}

# uplink_shaper_source - the appliance half, embedded or from the checkout
uplink_shaper_source() {
  if (( ${+TMBOX_SHAPER_B64} )) && [[ -n "$TMBOX_SHAPER_B64" ]]; then
    print -rn -- "$TMBOX_SHAPER_B64" | base64 -d
    return 0
  fi
  local src="${TMBOX_ROOT:-}/appliance/shape.sh"
  [[ -f "$src" ]] || return 1
  cat -- "$src"
}

# uplink_apply <host> <kbit|off> - install the shaper and set the rate
#
# The script is sent every time rather than once at bootstrap, so an appliance
# built before it existed gets it here, and one built with an older copy gets
# the current one. So is the match for the transport in use (#22): the limit
# has to catch whatever the backups actually arrive as. Prints the shaper's own
# report of what is now in force.
uplink_apply() {
  local host="$1" rate="$2" src out
  src="$(uplink_shaper_source)" || return 1
  ssh_put_data "$host" "$src" "$UPLINK_SHAPER" 0755 >/dev/null 2>&1 || return 1
  local -a match
  match=( ${(s: :)"$(transport_shape_match)"} )
  out="$(ssh_run "$host" "$UPLINK_SHAPER match ${(j: :)${(@q)match}} >/dev/null && $UPLINK_SHAPER set ${(q)rate}" 2>&1)" || {
    log_warn "tmbox-shape set ${rate}: ${out}"
    return 1
  }
  log_info "tmbox-shape: ${out}"
  state_set uplink_kbit "$rate"
  print -rn -- "$out"
}

# uplink_field <report> <name> - one value from "configured=… active=… dropped=…"
uplink_field() {
  local word
  for word in ${=1}; do
    [[ "$word" == "$2="* ]] && { print -rn -- "${word#*=}"; return 0 }
  done
  return 1
}
