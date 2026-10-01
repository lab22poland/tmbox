#!/bin/zsh
#
# Hetzner Storage Box - https://api.hetzner.com/v1
#
# A different host from the Cloud API, with its own action objects, but the same
# Console token authenticates both - so the user still supplies one credential.
#
# The Storage Box is where the backups physically live, and that shapes two
# rules that are not negotiable:
#
#   **It is never deleted by automation.** `tmbox destroy` removes the server,
#   the address, the firewall and the key, and then prints the command to delete
#   the box. Deleting it is the one irreversible act in the product, and the
#   thing it destroys is the only copy of the user's backups. An explicit
#   --delete-storage-box is the only way it happens.
#
#   **reachable_externally stays false.** The SMB path from the appliance to the
#   box then never leaves Hetzner's network, so it is not an exposure that has
#   to be defended - it is a route that does not exist.
#
# The API was rewired in 2025-10 with deprecations that expired in 2026-04, so
# the shapes here are checked against the published spec rather than against
# older examples: https://docs.hetzner.cloud/hetzner.spec.json

typeset -g HBOX_API="https://api.hetzner.com/v1"

hb() { http_request "$1" "${HBOX_API}$2" "${3:-}" "$TMBOX_HCLOUD_TOKEN" }

hb_fail() {
  local what="$1" msg
  msg="$(json_error "$HTTP_BODY")"
  log_error "storage box: $what failed: $HTTP_STATUS ${msg:-$HTTP_BODY}"
  case "$HTTP_STATUS" in
    401) ui_die "Hetzner rejected the API token while $what." ;;
    403) ui_die "The API token is not allowed to manage Storage Boxes ($what). It needs Read & Write permission." ;;
    422) ui_die "Hetzner rejected the request while $what: ${msg:-invalid input}." ;;
    000) ui_die "Could not reach api.hetzner.com while $what. Check the network and try again." ;;
    *)   ui_die "Hetzner returned $HTTP_STATUS while $what: ${msg:-see the transcript}." ;;
  esac
}

# hb_wait_action <action-id> <what> [timeout]
#
# Storage Box actions live under their own path, so hc_wait_action cannot be
# reused. Creating a box took about 20 seconds when this was measured; the
# default allows far more, because the cost of waiting too long is a slow
# install and the cost of giving up too early is an orphaned billable resource.
hb_wait_action() {
  local id="$1" what="$2"
  local -i timeout="${3:-600}" waited=0 interval=5
  [[ -n "$id" && "$id" != "null" ]] || return 0

  while (( waited < timeout )); do
    hb GET "/storage_boxes/actions/${id}" || hb_fail "checking $what"
    case "$(json_get '.action.status' "$HTTP_BODY")" in
      success) log_debug "storage box action $id ($what) succeeded after ${waited}s"; return 0 ;;
      error)
        local msg; msg="$(json_get '.action.error.message' "$HTTP_BODY")"
        ui_die "Hetzner could not complete $what: ${msg:-see the transcript}."
        ;;
    esac
    sleep $interval
    (( waited += interval ))
  done
  ui_die "Hetzner is still working on $what after ${timeout}s. Check the console - the Storage Box may already exist."
}

# --- types and pricing ------------------------------------------------------

# hb_types_json - the full type list, for the capacity menu and the cost screen
hb_types_json() {
  hb GET "/storage_box_types" || hb_fail "listing Storage Box types"
  print -rn -- "$HTTP_BODY"
}

# hb_type_for_bytes <types-json> <wanted-bytes> - the smallest type that fits
#
# Chosen by size rather than by a hardcoded name, so a new tier appearing in the
# catalogue is picked up without a code change - and so a tier being renamed
# cannot silently select the wrong one.
hb_type_for_bytes() {
  print -r -- "$1" | jq -er --argjson want "$2" '
    [.storage_box_types[] | select(.size >= $want)]
    | sort_by(.size) | .[0].name // empty'
}

# hb_type_price <types-json> <type-name> <location> - net monthly, or empty
hb_type_price() {
  print -r -- "$1" | jq -er --arg n "$2" --arg l "$3" '
    .storage_box_types[] | select(.name == $n)
    | .prices[] | select(.location == $l)
    | .price_monthly.net // empty'
}

# hb_type_size <types-json> <type-name> - bytes
hb_type_size() {
  print -r -- "$1" | jq -er --arg n "$2" '
    .storage_box_types[] | select(.name == $n) | .size // empty'
}

# --- the box ----------------------------------------------------------------

# hb_password - a password Hetzner will accept and mount_smbfs will not mangle
#
# Two constraints, both learned the hard way:
#
#   Hetzner's policy requires upper, lower, digit and a special character, or
#   the create is rejected with 422.
#
#   A '%' in the password breaks mount_smbfs on macOS, which reads it as the
#   start of a percent-escape. The same argument applies to the other characters
#   that are significant in a URL, a CIFS credentials file or a shell, so the
#   alphabet is restricted to letters and digits and the policy is satisfied by
#   appending a fixed, safe suffix.
#
# LC_ALL=C on tr: without it, tr rejects bytes from /dev/urandom that are not
# valid in a UTF-8 locale and the output comes up short or empty.
hb_password() {
  local body
  body="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | dd bs=1 count=24 2>/dev/null)"
  [[ ${#body} -eq 24 ]] || ui_die "Could not generate a password from /dev/urandom."
  print -rn -- "${body}Aa1-"
}

# hb_find_by_name <name> - id, or empty
hb_find_by_name() {
  hb GET "/storage_boxes" || hb_fail "listing Storage Boxes"
  print -r -- "$HTTP_BODY" | jq -er --arg n "$1" \
    '.storage_boxes[] | select(.name == $n) | .id // empty' 2>/dev/null
}

# hb_create <name> <type> <location> <password> - id
#
# access_settings is the security posture, stated once:
#
#   reachable_externally false - the box answers only inside Hetzner's network,
#     so the SMB path from the appliance is not an internet-facing service.
#   samba_enabled true       - that path is SMB.
#   ssh_enabled true         - needed for snapshots and for a manual rescue.
#   webdav_enabled false     - unused, so not exposed.
#   zfs_enabled false        - this is the box's own snapshot browser, unrelated
#                              to the ZFS pool inside the container file, and
#                              leaving it visible only invites confusion.
hb_create() {
  hb POST "/storage_boxes" "$(jq -n \
      --arg n "$1" --arg t "$2" --arg l "$3" --arg p "$4" '{
      name: $n, storage_box_type: $t, location: $l, password: $p,
      labels: {tmbox: "1"},
      access_settings: {
        reachable_externally: false,
        samba_enabled: true,
        ssh_enabled: true,
        webdav_enabled: false,
        zfs_enabled: false
      }
    }')" || hb_fail "creating the Storage Box"

  local id act
  id="$(json_get_or_die "$HTTP_BODY" '.storage_box.id' "the new Storage Box's id")"
  act="$(json_get '.action.id' "$HTTP_BODY")"
  [[ -n "$act" ]] && hb_wait_action "$act" "creating the Storage Box"
  print -rn -- "$id"
}

# hb_get <id> - the object in HTTP_BODY
hb_get() { hb GET "/storage_boxes/${1}" }

# hb_server <id> - the hostname to mount, e.g. u123456.your-storagebox.de
hb_server() {
  hb GET "/storage_boxes/${1}" || hb_fail "reading the Storage Box"
  json_get_or_die "$HTTP_BODY" '.storage_box.server' "the Storage Box's hostname"
}

hb_username() {
  hb GET "/storage_boxes/${1}" || hb_fail "reading the Storage Box"
  json_get_or_die "$HTTP_BODY" '.storage_box.username' "the Storage Box's username"
}

# hb_wait_active <id> [timeout]
hb_wait_active() {
  local id="$1"; local -i timeout="${2:-600}" waited=0 interval=5
  while (( waited < timeout )); do
    hb GET "/storage_boxes/${id}" || hb_fail "waiting for the Storage Box"
    [[ "$(json_get '.storage_box.status' "$HTTP_BODY")" == "active" ]] && return 0
    sleep $interval
    (( waited += interval ))
  done
  ui_die "The Storage Box is still not active after ${timeout}s."
}

# hb_delete <id>
#
# Never called by setup, and never by destroy without --delete-storage-box.
# It is here so the deliberate path exists, not so the automatic one does.
hb_delete() { hb DELETE "/storage_boxes/${1}" }

# --- subaccount -------------------------------------------------------------

# hb_subaccount_create <box-id> <home-directory> <password> - "username server"
#
# The home directory is **relative**, with no leading slash. The spec's pattern
# permits one, so "/tmbox" looks legal and is refused with 422 invalid_input -
# found on the first live run. It is relative to the box's own root, which is
# the only thing it could be relative to.
#
# The appliance mounts the subaccount, not the box owner. Its home directory is
# the only thing it can see, so the credentials sitting in a file on the
# appliance cannot reach anything else on the box - including the snapshots,
# which is the copy that survives the appliance being wrong.
hb_subaccount_create() {
  hb POST "/storage_boxes/${1}/subaccounts" "$(jq -n \
      --arg h "$2" --arg p "$3" '{
      home_directory: $h,
      password: $p,
      description: "tmbox appliance",
      labels: {tmbox: "1"},
      access_settings: {
        reachable_externally: false,
        samba_enabled: true,
        ssh_enabled: false,
        webdav_enabled: false,
        readonly: false
      }
    }')" || hb_fail "creating the Storage Box subaccount"

  local act; act="$(json_get '.action.id' "$HTTP_BODY")"
  local created="$HTTP_BODY"
  [[ -n "$act" ]] && hb_wait_action "$act" "creating the subaccount"

  local user server
  user="$(json_get '.subaccount.username' "$created")"
  server="$(json_get '.subaccount.server' "$created")"

  # The create response may carry the record before the action has finished
  # populating it; re-read rather than guess at the username, because the mount
  # is built from it and a wrong one fails minutes later with a bad-credentials
  # error that points nowhere useful.
  if [[ -z "$user" || -z "$server" ]]; then
    hb GET "/storage_boxes/${1}/subaccounts" || hb_fail "reading the subaccount"
    user="$(json_get '.subaccounts[-1].username' "$HTTP_BODY")"
    server="$(json_get '.subaccounts[-1].server' "$HTTP_BODY")"
  fi

  [[ -n "$user" && -n "$server" ]] \
    || ui_die "Hetzner created the subaccount but did not report its username. The transcript has the response."
  print -rn -- "$user $server"
}

hb_subaccount_list() { hb GET "/storage_boxes/${1}/subaccounts" }

# hb_count - how many Storage Boxes exist, for the teardown audit
hb_count() {
  hb GET "/storage_boxes" || return 1
  json_len '.storage_boxes' "$HTTP_BODY"
}
