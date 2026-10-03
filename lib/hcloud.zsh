#!/bin/zsh
#
# Hetzner Cloud - https://api.hetzner.cloud/v1
#
# Servers, primary IPs, firewalls, SSH keys, images and pricing. Storage Boxes
# live on a different host and are in lib/hbox.zsh; one Console token covers
# both, which is why there is only ever one credential to ask the user for.
#
# Plain curl against the REST API, no provider and no state file. OpenTofu is
# forbidden in the product by licence (Terraform is BUSL) and would be the wrong
# shape anyway: the managed estate is one server, one IP, one firewall and one
# key, and an embedded binary plus a state file buys nothing over five HTTP
# calls while costing the user a second mental model on the day something
# breaks.
#
# Three cost rules are encoded here rather than documented, because each of them
# has already cost money on this project:
#
#   - public_net is always declared explicitly on a server. Omit it and Hetzner
#     attaches a primary IP that tmbox did not create, does not track, and will
#     not delete - and it keeps billing after the server is gone.
#   - a primary IP is created with auto_delete false and deleted deliberately,
#     so it is never orphaned by a server deletion and never silently discarded
#     while still reserved.
#   - backups and delete_protection are never enabled. The latter cannot be
#     cleared by the same call that would delete the resource, so it turns a
#     teardown into a support ticket.
#
# Every resource carries the label `tmbox=1`, which is what makes the teardown
# audit decisive rather than a matter of remembering what was created.

typeset -g HCLOUD_API="https://api.hetzner.cloud/v1"
typeset -g TMBOX_HCLOUD_TOKEN="${TMBOX_HCLOUD_TOKEN:-}"

# hc <method> <path> [body] - HTTP_BODY/HTTP_STATUS as in lib/http.zsh
hc() { http_request "$1" "${HCLOUD_API}$2" "${3:-}" "$TMBOX_HCLOUD_TOKEN" }

# hc_fail <what>
#
# Turn an API failure into a sentence a user can act on. The API's own message
# is the useful part and is always shown; the status code is for the transcript.
#
# **This ends in ui_die, and ui_die cannot stop a caller that wrapped it in
# `$( )`.** Command substitution is a subshell, so the exit kills the subshell
# and the script carries on with an empty string. That happened on the first
# live run: reserving the address failed, the message was printed, and setup
# proceeded to create a server with an empty primary-IP id. Every caller that
# captures one of the functions below therefore checks the result - see
# setup_require in cmd/setup.zsh - and this is why they return identifiers on
# stdout rather than raising.
hc_fail() {
  local what="$1" msg
  msg="$(json_error "$HTTP_BODY")"
  log_error "hcloud: $what failed: $HTTP_STATUS ${msg:-$HTTP_BODY}"
  case "$HTTP_STATUS" in
    401) ui_die "Hetzner rejected the API token while $what. Create a new Read & Write token and run tmbox again." ;;
    403) ui_die "The API token is not allowed to do this ($what). It probably has Read-only permission; create a Read & Write one." ;;
    404) ui_die "Hetzner could not find what tmbox asked for while $what. The transcript has the request." ;;
    409) ui_die "Hetzner reports a conflict while $what: ${msg:-a resource with that name already exists}." ;;
    422) ui_die "Hetzner rejected the request while $what: ${msg:-invalid input}." ;;
    000) ui_die "Could not reach api.hetzner.cloud while $what. Check the network and try again." ;;
    *)   ui_die "Hetzner returned $HTTP_STATUS while $what: ${msg:-see the transcript}." ;;
  esac
}

# --- credentials ------------------------------------------------------------

# hc_token_valid <token> - status 0 if the token authenticates at all
#
# GET /pricing is the cheapest authenticated endpoint and touches nothing.
hc_token_valid() {
  http_request GET "${HCLOUD_API}/pricing" "" "$1"
}

# hc_token_can_write <token>
#
# A Read-only token passes hc_token_valid and then fails at the first create,
# after the user has confirmed the cost - which is the worst possible moment to
# find out. Hetzner exposes no "describe this token" endpoint, so the check is
# an actual write: create an SSH key with a deliberately malformed public key.
#
# A read-only token is refused with 403 before validation runs; a read-write one
# reaches validation and is refused with 422. Nothing is created either way.
hc_token_can_write() {
  local token="$1"
  http_request POST "${HCLOUD_API}/ssh_keys" \
    "$(json_obj name "tmbox-permission-probe" public_key "ssh-ed25519 not-a-real-key")" \
    "$token"
  case "$HTTP_STATUS" in
    422) return 0 ;;   # reached validation, so writing is permitted
    403) return 1 ;;   # rejected before validation: read-only
    201|200)
      # Should be unreachable - but if Hetzner ever accepts that key, clean up
      # rather than leave a probe lying in the user's project.
      local id; id="$(json_get '.ssh_key.id' "$HTTP_BODY")"
      [[ -n "$id" ]] && http_request DELETE "${HCLOUD_API}/ssh_keys/${id}" "" "$token"
      return 0 ;;
    *) return 1 ;;
  esac
}

# --- actions ----------------------------------------------------------------

# hc_wait_action <action-id> <what> [timeout-seconds]
#
# Most creates return immediately with an action that is still running. Acting
# on a server before its action succeeds is how a script ends up ssh-ing to an
# address that is not routable yet.
hc_wait_action() {
  local id="$1" what="$2"
  local -i timeout="${3:-300}" waited=0 interval=3
  [[ -n "$id" && "$id" != "null" ]] || return 0

  while (( waited < timeout )); do
    hc GET "/actions/${id}" || hc_fail "checking $what"
    case "$(json_get '.action.status' "$HTTP_BODY")" in
      success) log_debug "action $id ($what) succeeded after ${waited}s"; return 0 ;;
      error)
        local msg; msg="$(json_get '.action.error.message' "$HTTP_BODY")"
        log_error "action $id ($what) failed: $msg"
        ui_die "Hetzner could not complete $what: ${msg:-see the transcript}."
        ;;
    esac
    sleep $interval
    (( waited += interval ))
  done
  ui_die "Hetzner is still working on $what after ${timeout}s. Check the console before retrying - the resource may exist."
}

# --- lookups ----------------------------------------------------------------

# hc_image_id <name> <architecture> - resolve an image by name
#
# Resolved every run, never pinned. Hetzner rebuilds the system images and the
# numeric id changes; a pinned id works until the day it silently does not.
hc_image_id() {
  hc GET "/images?name=${1}&architecture=${2}&type=system&sort=created:desc" \
    || hc_fail "looking up the ${1} image"
  local id; id="$(json_get '.images[0].id' "$HTTP_BODY")"
  [[ -n "$id" ]] || ui_die "Hetzner has no ${1} image for ${2}. This is unexpected; the transcript has the response."
  print -rn -- "$id"
}

# hc_server_type <name> - the full object, for cores/memory/prices
hc_server_type() {
  hc GET "/server_types?name=${1}" || hc_fail "looking up the ${1} server type"
  json_get ".server_types[0]" "$HTTP_BODY"
}

# hc_server_locations <type-name> - where a server type can actually be created
#
# CAX (arm64) exists in only some locations, and the set is Hetzner's to change.
# Reading it from the prices array means the region menu can never offer a
# combination that will be refused at create time.
hc_server_locations() {
  hc GET "/server_types?name=${1}" || hc_fail "looking up ${1} availability"
  json_array '[.server_types[0].prices[].location]' "$HTTP_BODY"
}

# --- ssh keys ---------------------------------------------------------------

# hc_ssh_key_find_by_fingerprint <md5-fingerprint> - id, or empty
hc_ssh_key_find_by_fingerprint() {
  hc GET "/ssh_keys?fingerprint=${1}" || hc_fail "looking for an existing SSH key"
  json_get '.ssh_keys[0].id' "$HTTP_BODY"
}

# hc_ssh_key_create <name> <public-key> - id
hc_ssh_key_create() {
  hc POST "/ssh_keys" "$(jq -n --arg n "$1" --arg k "$2" \
      '{name:$n, public_key:$k, labels:{tmbox:"1"}}')" \
    || hc_fail "creating the SSH key"
  json_get_or_die "$HTTP_BODY" '.ssh_key.id' "the new SSH key's id"
}

hc_ssh_key_delete() { hc DELETE "/ssh_keys/${1}" }

# --- firewall ---------------------------------------------------------------

# hc_firewall_create <name> <admin-cidr> - id
#
# The resting state, and the whole of it. Inbound default is deny, so what is
# absent matters as much as what is present:
#
#   tcp/22  from the operator's current address only. It carries administration
#           and, in a disaster, the SSH forward that reaches the backups.
#   icmp    from the same address, so `tmbox doctor` can tell "unreachable"
#           from "reachable but refusing".
#   tcp/445 nowhere. SMB is never exposed to the internet; it travels inside the
#           SSH forward. This is the project's oldest rule.
#
# The address is re-detected on every run and never stored, because a home
# connection's address changes and a stale rule locks the owner out of their own
# appliance.
hc_firewall_create() {
  local name="$1" cidr="$2"
  hc POST "/firewalls" "$(jq -n --arg n "$name" --arg c "$cidr" '{
      name: $n,
      labels: {tmbox: "1"},
      rules: [
        {direction:"in", protocol:"tcp",  port:"22", source_ips:[$c], description:"administration and the restore forward"},
        {direction:"in", protocol:"icmp",            source_ips:[$c], description:"reachability checks"}
      ]
    }')" || hc_fail "creating the firewall"
  json_get_or_die "$HTTP_BODY" '.firewall.id' "the new firewall's id"
}

# hc_firewall_set_admin_cidr <firewall-id> <cidr>
#
# Replaces the whole rule set rather than editing it. Hetzner has no
# "change one rule" call, and a read-modify-write here would be a way to
# accidentally preserve a rule that should have expired - which is exactly how
# an open tcp/445 survived a teardown on an earlier run of this project.
#
# Returns once Hetzner reports the new rules applied, not when it accepts the
# request. The caller's next move is an ssh connection from the new address,
# and one made while the old rules still apply times out exactly as though
# nothing had been changed (#5). The response is an `actions` array - one per
# server the firewall is applied to - not the single `action` most calls return.
hc_firewall_set_admin_cidr() {
  hc POST "/firewalls/${1}/actions/set_rules" "$(jq -n --arg c "$2" '{
      rules: [
        {direction:"in", protocol:"tcp",  port:"22", source_ips:[$c], description:"administration and the restore forward"},
        {direction:"in", protocol:"icmp",            source_ips:[$c], description:"reachability checks"}
      ]
    }')" || hc_fail "updating the firewall"
  local act
  for act in ${(f)"$(json_get '.actions[]?.id' "$HTTP_BODY")"}; do
    hc_wait_action "$act" "applying the firewall rules" 120
  done
  return 0
}

hc_firewall_delete() { hc DELETE "/firewalls/${1}" }

# --- primary ip -------------------------------------------------------------

# hc_primary_ip_create <name> <location> - "id ip"
#
# `location`, and nothing else that binds it. The first attempt sent
# `datacenter` plus `assignee_type: "server"` and Hetzner refused it with 422
# on 'assignee_id', 'location' - `datacenter` is not a field on this endpoint at
# all, and assignee_type is only meaningful alongside an assignee_id, which
# there is none of because the server does not exist yet. The address is created
# unassigned and attached when the server is created.
#
# auto_delete is false deliberately. With it true, deleting the server discards
# the address, and the appliance comes back on a different one - which
# invalidates the known_hosts pin, the tunnel configuration and the firewall's
# idea of who is talking. tmbox deletes it explicitly at teardown instead.
hc_primary_ip_create() {
  hc POST "/primary_ips" "$(jq -n --arg n "$1" --arg l "$2" '{
      name: $n, type: "ipv4", location: $l,
      auto_delete: false,
      labels: {tmbox: "1"}
    }')" || hc_fail "reserving the IPv4 address"
  local id ip
  id="$(json_get_or_die "$HTTP_BODY" '.primary_ip.id' "the new address's id")"
  ip="$(json_get_or_die "$HTTP_BODY" '.primary_ip.ip'  "the new address")"
  print -rn -- "$id $ip"
}

hc_primary_ip_delete() { hc DELETE "/primary_ips/${1}" }

# --- server -----------------------------------------------------------------

# hc_server_create <name> <type> <location> <image-id> <ssh-key-id> <firewall-id> <primary-ip-id> <user-data>
#
# Returns "server-id action-id"; the caller waits on the action.
hc_server_create() {
  local name="$1" type="$2" loc="$3" image="$4" key="$5" fw="$6" pip="$7" udata="$8"
  hc POST "/servers" "$(jq -n \
      --arg n "$name" --arg t "$type" --arg l "$loc" --arg u "$udata" \
      --argjson img "$image" --argjson k "$key" --argjson f "$fw" --argjson p "$pip" '{
      name: $n, server_type: $t, image: $img, location: $l,
      ssh_keys: [$k],
      firewalls: [{firewall: $f}],
      public_net: {enable_ipv4: true, ipv4: $p, enable_ipv6: true},
      user_data: $u,
      labels: {tmbox: "1"},
      start_after_create: true,
      backups: false
    }')" || hc_fail "creating the server"

  local id act
  id="$(json_get_or_die "$HTTP_BODY" '.server.id' "the new server's id")"
  act="$(json_get '.action.id' "$HTTP_BODY")"
  print -rn -- "$id $act"
}

# hc_server_get <id>
hc_server_get() { hc GET "/servers/${1}" }

# hc_server_ipv4 <id>
hc_server_ipv4() {
  hc GET "/servers/${1}" || hc_fail "reading the server's address"
  json_get '.server.public_net.ipv4.ip' "$HTTP_BODY"
}

hc_server_delete() { hc DELETE "/servers/${1}" }

# --- audit ------------------------------------------------------------------
#
# What `tmbox destroy` checks afterwards, and what `tmbox doctor` reports.
#
# Audited against the API rather than against what the script believes it
# created: the failure worth catching is precisely the resource the script has
# forgotten about. Every class that can bill is listed, including the ones that
# outlive a server - an unassigned primary IP still costs money, and a snapshot
# is not deleted with the machine it came from.

typeset -ga HC_BILLABLE=(
  servers volumes primary_ips floating_ips firewalls networks
  load_balancers placement_groups certificates ssh_keys
)

# hc_count <resource> [label-selector] - how many exist
hc_count() {
  local resource="$1" selector="${2:-}"
  local url="/${resource}"
  [[ -n "$selector" ]] && url="${url}?label_selector=${selector}"
  hc GET "$url" || return 1
  json_len ".${resource}" "$HTTP_BODY"
}

# hc_count_images_snapshots - snapshots and backups, which outlive their server
hc_count_images_snapshots() {
  hc GET "/images?type=snapshot" || return 1
  local -i a=$(json_len '.images' "$HTTP_BODY")
  hc GET "/images?type=backup" || return 1
  local -i b=$(json_len '.images' "$HTTP_BODY")
  print -rn -- $(( a + b ))
}
