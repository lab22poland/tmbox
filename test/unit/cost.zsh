#!/bin/zsh
#
# What the appliance costs - setup's price helpers and status's live cost (#29).
#
# The recorded figure went stale without saying so: a price change or a
# rescale in the Console left status quoting an appliance that no longer
# existed. What is tested here is that status prices what exists, explains the
# total, says when it moved, never writes, and falls back to the recorded
# figure - marked as such - whenever the live one cannot be had. Hetzner is
# replaced by functions answering with fixtures shaped like the published
# specs; the state file and the secrets are the runner's scratch copies.

source "$TMBOX_ROOT/lib/answers.zsh"
source "$TMBOX_ROOT/lib/log.zsh"
source "$TMBOX_ROOT/lib/ui.zsh"
source "$TMBOX_ROOT/lib/json.zsh"
source "$TMBOX_ROOT/lib/state.zsh"
source "$TMBOX_ROOT/lib/secrets.zsh"
source "$TMBOX_ROOT/lib/http.zsh"
source "$TMBOX_ROOT/lib/hcloud.zsh"
source "$TMBOX_ROOT/lib/hbox.zsh"
source "$TMBOX_ROOT/lib/sshx.zsh"
source "$TMBOX_ROOT/lib/macos.zsh"
source "$TMBOX_ROOT/lib/transport.zsh"
source "$TMBOX_ROOT/lib/uplink.zsh"
source "$TMBOX_ROOT/cmd/tunnel.zsh"
source "$TMBOX_ROOT/cmd/transport.zsh"
source "$TMBOX_ROOT/cmd/status.zsh"

ui_init --no-tty-ok
typeset -g UI_LOG="$TMBOX_STATE_DIR/ui.out"

typeset -g PRICING SERVER BOX
PRICING="$(cat "$TMBOX_ROOT/test/fixtures/pricing.json")"
SERVER="$(cat "$TMBOX_ROOT/test/fixtures/server.json")"
BOX="$(cat "$TMBOX_ROOT/test/fixtures/storage_box.json")"

# Requests made, one "METHOD path attempts/connect/max" per line.
typeset -g CALLS="$TMBOX_STATE_DIR/calls"

_fresh() {
  rm -rf -- "$TMBOX_STATE_DIR"
  state_init >/dev/null 2>&1
  kc_init
  : > "$UI_LOG"
  : > "$CALLS"
  exec {TMBOX_UI_FD}>>"$UI_LOG"
  state_set server_id 168547811 box_id 664308 primary_ip_id 42 \
            region fsn1 monthly_eur 9.69 >/dev/null 2>&1
  kc_set hetzner-token "test-token" >/dev/null 2>&1
}

# _hetzner [server-json] [box-json] [pricing-json] - answer as Hetzner would
_hetzner() {
  typeset -g _S="${1:-$SERVER}" _B="${2:-$BOX}" _P="${3:-$PRICING}"
  hc() {
    print -r -- "hc $1 $2 $HTTP_MAX_ATTEMPTS/$HTTP_CONNECT_TIMEOUT/$HTTP_MAX_TIME" >> "$CALLS"
    [[ "$TMBOX_HCLOUD_TOKEN" == test-token ]] || { HTTP_STATUS=401; HTTP_BODY='{}'; return 1 }
    case "$2" in
      /servers/*) HTTP_STATUS=200; HTTP_BODY="$_S" ;;
      /pricing)   HTTP_STATUS=200; HTTP_BODY="$_P" ;;
      *)          HTTP_STATUS=404; HTTP_BODY='{}'; return 1 ;;
    esac
  }
  hb() {
    print -r -- "hb $1 $2" >> "$CALLS"
    case "$2" in
      /storage_boxes/*) HTTP_STATUS=200; HTTP_BODY="$_B" ;;
      *)                HTTP_STATUS=404; HTTP_BODY='{}'; return 1 ;;
    esac
  }
}

_out() { cat "$UI_LOG" }

# --- the helpers setup and status share --------------------------------------

test_helpers_read_the_prices_setup_quotes() {
  assert_eq "5.9900" "$(hc_pricing_server "$PRICING" cax11 fsn1)" "server"
  assert_eq "0.5000" "$(hc_pricing_ipv4 "$PRICING" fsn1)" "IPv4, not the free IPv6"
  assert_empty "$(hc_pricing_server "$PRICING" cax11 nbg1)" "a location without a price"
  assert_empty "$(hc_pricing_server "$PRICING" cx99 fsn1)" "a type that does not exist"
}

test_type_price_reads_a_type_embedded_in_a_resource() {
  local type
  type="$(print -r -- "$SERVER" | jq -c .server.server_type)"
  assert_eq "5.9900" "$(hc_type_price "$type" fsn1)" "server type"
  type="$(print -r -- "$BOX" | jq -c .storage_box.storage_box_type)"
  assert_eq "3.2000" "$(hc_type_price "$type" fsn1)" "Storage Box type"
  assert_empty "$(hc_type_price "" fsn1)" "nothing in, nothing out"
}

# --- status, live ------------------------------------------------------------

test_status_shows_the_live_total_and_what_it_is_made_of() {
  _fresh; _hetzner
  status_cost
  assert_contains "$(_out)" "EUR 9.69 / month, net"
  assert_contains "$(_out)" "server CAX11 5.99 · IPv4 0.50 · Storage Box BX11 3.20"
  assert_not_contains "$(_out)" "when it was set up" "unchanged, so nothing to compare"
  assert_not_contains "$(_out)" "about" "a live figure is not an estimate"
}

test_a_price_change_is_shown_against_the_recorded_figure() {
  _fresh
  _hetzner "${SERVER//5.9900/6.4900}"
  status_cost
  assert_contains "$(_out)" "EUR 10.19 / month, net"
  assert_contains "$(_out)" "EUR 9.69 when it was set up"
}

test_a_rescale_in_the_console_is_priced_as_what_it_became() {
  _fresh
  local server
  server="$(print -r -- "$SERVER" | jq -c --argjson t \
    "$(print -r -- "$PRICING" | jq -c '.pricing.server_types[]|select(.name=="cax21")')" \
    '.server.server_type = $t')"
  _hetzner "$server"
  status_cost
  assert_contains "$(_out)" "server CAX21 9.99"
  assert_contains "$(_out)" "EUR 13.69 / month, net"
}

test_prices_are_for_the_location_the_server_is_in() {
  _fresh
  _hetzner "$(print -r -- "$SERVER" | jq -c '.server.location.name = "hel1"')"
  status_cost_read || fail "a server in hel1 with a hel1 price was not priced"
  assert_eq "5.9900" "$STATUS_COST_SERVER"
}

test_no_ipv4_recorded_means_none_is_charged() {
  _fresh; _hetzner
  state_unset primary_ip_id >/dev/null 2>&1
  status_cost
  assert_not_contains "$(_out)" "IPv4"
  assert_contains "$(_out)" "EUR 9.19 / month, net"
  assert_not_contains "$(cat "$CALLS")" "/pricing" "nothing to price, nothing to ask"
}

test_status_never_writes_the_live_figure_back() {
  _fresh
  _hetzner "${SERVER//5.9900/6.4900}"
  status_cost
  assert_eq "9.69" "$(state_get monthly_eur)" "status is read-only"
}

test_status_asks_once_and_briefly() {
  _fresh; _hetzner
  status_cost
  local calls; calls="$(cat "$CALLS")"
  assert_contains "$calls" "hc GET /servers/168547811 1/5/10" "one attempt, short timeouts"
  assert_contains "$calls" "hb GET /storage_boxes/664308"
  assert_eq "5" "$HTTP_MAX_ATTEMPTS" "the shortcut does not outlive status"
  assert_eq "120" "$HTTP_MAX_TIME"
}

# --- status, when the live figure cannot be had ------------------------------

test_falls_back_to_the_recorded_figure_without_a_token() {
  _fresh; _hetzner
  kc_delete hetzner-token >/dev/null 2>&1
  status_cost
  assert_contains "$(_out)" "about EUR 9.69 / month, net"
  assert_contains "$(_out)" "at setup; current prices not readable"
  assert_empty "$(cat "$CALLS")" "no token, no request"
}

test_falls_back_when_hetzner_does_not_answer() {
  _fresh; _hetzner
  hc() { HTTP_STATUS=000; HTTP_BODY=""; return 1 }
  status_cost
  assert_contains "$(_out)" "about EUR 9.69 / month, net"
  assert_contains "$(_out)" "at setup; current prices not readable"
}

test_falls_back_when_a_part_has_no_price() {
  _fresh
  _hetzner "" "$(print -r -- "$BOX" | jq -c '.storage_box.location.name = "nbg1"')"
  status_cost
  assert_contains "$(_out)" "at setup; current prices not readable" \
    "a partial total would understate the bill"
}

test_says_nothing_with_neither_figure() {
  _fresh; _hetzner
  state_unset monthly_eur >/dev/null 2>&1
  hc() { return 1 }
  status_cost
  assert_not_contains "$(_out)" "Cost"
}
