#!/bin/zsh
#
# tmbox setup - from nothing to a private Time Machine destination.
#
# Nine steps. Each records what it did before moving on, so a failure at step 7
# means running tmbox again rather than starting over - which matters, because
# from step 5 onward the user is paying for a server.
#
# Steps 1-5 are here: welcome and capacity, the Hetzner account, the API token,
# the confirmation that is the commitment point, and the provisioning itself.
# Steps 6-9 hand off to the appliance bootstrap, the tunnel, the Time Machine
# destination and the first backup.
#
# Two conventions run through all of it.
#
# **Nothing is created before step 5, and step 5 is announced.** Everything up
# to the confirmation is undone by pressing ctrl-c, and the confirmation states
# the real monthly bill, read from the live price list, before the first POST.
#
# **Every resource is labelled tmbox=1.** That is what makes the teardown audit
# decisive: destroy can ask the API what exists rather than trusting what this
# script believes it created.

typeset -gi SETUP_STEPS=9

# setup_capacity_bytes <label>
#
# The capacities offered are a short list of round numbers rather than a
# free-text field. The number that matters to the user is the monthly bill, and
# the Storage Box tiers are coarse, so asking "how many GB?" would invite a
# precision the pricing does not have.
setup_capacity_bytes() {
  case "$1" in
    1TB)  print -rn -- $(( 1  * 10**12 )) ;;
    2TB)  print -rn -- $(( 2  * 10**12 )) ;;
    4TB)  print -rn -- $(( 4  * 10**12 )) ;;
    5TB)  print -rn -- $(( 5  * 10**12 )) ;;
    10TB) print -rn -- $(( 10 * 10**12 )) ;;
    *)    return 1 ;;
  esac
}

# setup_sanitise_name <raw>
#
# Sanitised rather than validated-and-rejected: the user should not have to care
# that this project measured a macOS 26 bug where non-ASCII share and server
# names fail. The name ends up in `tm-<name>`, so it is kept boring on purpose.
setup_sanitise_name() {
  local name="${(L)1}"
  name="${name//[^a-z0-9-]/-}"
  while [[ "$name" == *--* ]]; do name="${name//--/-}"; done
  while [[ "$name" == -* ]];   do name="${name#-}";   done
  while [[ "$name" == *- ]];   do name="${name%-}";   done
  [[ -n "$name" ]] || name="mac"
  print -rn -- "${name[1,24]}"
}

# setup_require <value> <what>
#
# Every function that creates something returns its identifier on stdout, and
# reports failure by printing nothing after ui_die has already explained why.
# ui_die cannot stop this caller, because capturing output means a subshell and
# exiting a subshell exits only the subshell - measured on the first live run,
# where reserving the address failed, said so, and setup then tried to create a
# server with an empty primary-IP id. So the value is checked here, where the
# exit actually ends the run.
setup_require() {
  local value="$1" what="$2"
  [[ -n "$value" ]] && { print -rn -- "$value"; return 0 }
  ui_blank
  ui_bad "Could not $what."
  ui_say "The reason is above, and the full exchange with Hetzner is in ${TMBOX_LOG_FILE}."
  ui_say "Anything already created is recorded; run tmbox destroy to remove it."
  ui_blank
  exit 1
}

cmd_setup() {
  http_init || ui_die "Could not create a private temporary directory."

  # Before anything is created. A run that cannot finish should stop while
  # nothing is billing - and once the destination is set, it is not needed.
  if [[ -z "$(state_get destination_id)" ]] && ! preflight_time_machine_ready; then
    ui_blank
    if setup_existing; then
      ui_say "Nothing was changed; what this Mac already has in Hetzner is untouched, and still billed."
    else
      ui_say "Nothing has been created, and nothing is being billed."
    fi
    exit 1
  fi

  # A Mac that has been here before continues what it started (#4). Replaying
  # the new-install flow over it re-asked questions whose answers can no longer
  # change anything - and one that can still break things: the share is named
  # after the Mac, so a different name pointed Time Machine at a share that
  # does not exist.
  if setup_existing; then
    SETUP_RESUMING=1
    setup_resume_intro
  else
    setup_step1_welcome
  fi
  setup_step2_account
  setup_step3_token
  setup_step4_confirm
  setup_step5_provision
  setup_step6_bootstrap
  setup_step7_tunnel
  setup_step8_destination
  setup_step9_first_backup

  ui_blank
  setup_show_state
  return 0
}

# --- resuming ---------------------------------------------------------------
#
# Every step already skips what the state file says it did, which is what makes
# a re-run safe. What it did not make it was honest: a resumed run walked
# through the questions and the cost screen of a new install, said "nothing
# exists" over resources that were billing, and overwrote the original answers
# with new ones (#4). Resuming is now its own path: say what exists, ask once
# whether to go on, and never ask again what was decided the first time.

typeset -gi SETUP_RESUMING=0

# setup_existing - 0 when this Mac already has an appliance, or part of one
#
# Anything billable counts, and so does the firewall: a run interrupted between
# creating those and the server still has to continue rather than start over,
# or it would create a second set.
setup_existing() {
  state_has box_id || state_has server_id || state_has primary_ip_id || state_has firewall_id
}

setup_resume_intro() {
  ui_banner "tmbox ${TMBOX_VERSION}" "Continuing the setup this Mac started"

  ui_say "This Mac already has a tmbox appliance, or the start of one, in Hetzner. Setup continues it rather than starting again: nothing is created twice, and the answers given the first time stand."
  ui_blank
  setup_resume_summary
  ui_blank

  ui_confirm RESUME "Continue with this appliance?" "y" || {
    ui_blank
    ui_say "Stopped. Nothing was changed - and what already exists in Hetzner is still there, and still billed."
    ui_say "tmbox status shows it. tmbox destroy removes it."
    exit 0
  }

  # A run interrupted before step 1 recorded its answers has resources but no
  # name or size. Rare, and the only case in which a resumed run asks.
  if [[ -z "$(state_get mac_name)" || -z "$(state_get capacity)" ]]; then
    setup_ask_capacity_and_name
  fi
}

# setup_resume_summary - what exists, and which steps are done
setup_resume_summary() {
  local done="${C_OK}${G_OK}${C_RESET}" todo="${C_MUTED}not yet${C_RESET}"
  ui_kv "This Mac"     "$(state_get mac_name) (share tm-$(state_get mac_name))"
  ui_kv "Size"         "$(state_get capacity), Storage Box $(state_get box_type)"
  ui_kv "Location"     "$(state_get region)"
  ui_kv "Storage Box"  "$(state_has box_id && print -rn -- "$done $(state_get box_id)" || print -rn -- "$todo")"
  ui_kv "Server"       "$(state_has server_id && print -rn -- "$done $(state_get server_ip)" || print -rn -- "$todo")"
  ui_kv "Built"        "$([[ "$(state_get bootstrapped)" == yes ]] && print -rn -- "$done" || print -rn -- "$todo")"
  ui_kv "Tunnel"       "$([[ -f "$TMBOX_TUNNEL_PLIST" ]] && print -rn -- "$done" || print -rn -- "$todo")"
  ui_kv "Time Machine" "$(state_has destination_id && print -rn -- "$done" || print -rn -- "$todo")"
}

# --- 1. welcome and capacity ------------------------------------------------

setup_step1_welcome() {
  ui_banner "tmbox ${TMBOX_VERSION}" "A private Time Machine destination you own outright"

  ui_say "tmbox builds a backup appliance in your own Hetzner account. The backups live on hardware you rent, reachable only through an SSH tunnel from this Mac. Nothing about it is hosted by us."
  ui_blank
  ui_say "You need a payment card and about twenty minutes. Nothing is created, and nothing is charged, until you confirm on a screen showing the exact monthly cost."
  ui_blank

  ui_step 1 $SETUP_STEPS "How much space"
  setup_ask_capacity_and_name
}

setup_ask_capacity_and_name() {
  local capacity
  capacity="$(ui_menu CAPACITY "How much do you want to back up?" \
    "1TB"  "1 TB"  "One Mac with a modest disk." \
    "2TB"  "2 TB"  "The usual choice for one Mac." \
    "4TB"  "4 TB"  "A large disk, or a long history." \
    "5TB"  "5 TB"  "Two or three Macs." \
    "10TB" "10 TB" "A household.")"

  local mac_name
  mac_name="$(setup_sanitise_name \
    "$(ui_ask MAC_NAME "What should this Mac be called on the appliance" "$(mac_default_name)")")"

  state_set capacity "$capacity" mac_name "$mac_name"
  log_info "capacity=$capacity mac_name=$mac_name"
}

# --- 2. the Hetzner account -------------------------------------------------

setup_step2_account() {
  ui_step 2 $SETUP_STEPS "Your Hetzner account"

  # A stored token means this Mac has been here before. Reuse it rather than
  # sending the user back to the console.
  if ans_has HETZNER_TOKEN || kc_has hetzner-token; then
    ui_ok "A Hetzner API token is already available on this Mac."
    return 0
  fi

  ui_say "tmbox needs a Hetzner Cloud account. Creating one is the step nobody can automate for you: it involves identity and payment verification, and there is no API for it."
  ui_blank

  ui_confirm HAS_ACCOUNT "Do you already have a Hetzner account?" "n" && return 0

  ui_blank
  ui_say "tmbox will open the signup page. Create the account, then come back here."
  ui_blank
  ui_item "Choose Cloud when asked which product you want."
  ui_item "Verification usually takes a few minutes, occasionally longer."
  ui_blank

  if (( ! TMBOX_NONINTERACTIVE )) && (( $+commands[open] )); then
    open "https://accounts.hetzner.com/signUp" 2>/dev/null
  else
    ui_say "https://accounts.hetzner.com/signUp"
  fi

  ui_pause "Press return once the account is ready"
}

# --- 3. the API token -------------------------------------------------------

setup_step3_token() {
  ui_step 3 $SETUP_STEPS "An API token"

  local token=""
  if ans_has HETZNER_TOKEN; then
    token="$(ans_get HETZNER_TOKEN)"
  elif kc_has hetzner-token; then
    token="$(kc_get hetzner-token)"
    ui_ok "Using the token tmbox already has for this Mac."
  fi

  if [[ -n "$token" ]]; then
    if setup_validate_token "$token"; then
      kc_set hetzner-token "$token"
      return 0
    fi
    ui_warn "That token no longer works; Hetzner tokens can be revoked in the console."
    token=""
    # A pre-supplied answer that does not work must not send the loop below
    # round asking for the same thing it was already given.
    ans_has HETZNER_TOKEN && ui_die "The token supplied on the command line was rejected."
  fi

  ui_say "tmbox needs a token so it can create the appliance. Tokens are per-project and revocable at any time. This one is written to a file only you can read, under ~/.config/tmbox, and nowhere else."
  ui_blank
  ui_say "In the Hetzner Cloud console:"
  ui_item "Open, or create, a project - a name like 'backups' is fine."
  ui_item "Go to Security, then API tokens, then Generate API token."
  ui_item "Give it Read & Write. Read-only cannot create anything."
  ui_item "Copy it. Hetzner shows the token exactly once."
  ui_blank

  if (( ! TMBOX_NONINTERACTIVE )) && (( $+commands[open] )); then
    open "https://console.hetzner.cloud/" 2>/dev/null
  else
    ui_say "https://console.hetzner.cloud/"
  fi
  ui_blank

  local -i tries=0
  while (( tries < 3 )); do
    (( tries++ ))
    token="${$(ui_ask_secret HETZNER_TOKEN "Paste the token")//[[:space:]]/}"

    if [[ -z "$token" ]]; then
      ui_warn "Nothing was pasted."
      continue
    fi
    # Checked before spending a round trip. Hetzner tokens are 64 characters;
    # the usual mistake is pasting the token's name, or only half of it.
    if (( ${#token} != 64 )); then
      ui_warn "That is ${#token} characters and a Hetzner token is 64. Did the copy include all of it?"
      continue
    fi

    if setup_validate_token "$token"; then
      kc_set hetzner-token "$token" || ui_die "Could not save the token."
      ui_ok "Token accepted, and saved for next time."
      return 0
    fi
  done

  ui_die "Could not get a working API token. Nothing has been created."
}

# setup_validate_token <token>
#
# Two questions, in the order that fails cheapest: does it authenticate, and may
# it write. The second matters because a read-only token passes every obvious
# check and then fails at the first create - after the user has confirmed the
# cost, which is the worst moment to find out.
setup_validate_token() {
  local token="$1"
  log_secret "$token"

  ui_spin_start "Checking the token"
  if ! hc_token_valid "$token"; then
    ui_spin_stop bad "Hetzner rejected that token"
    return 1
  fi
  if ! hc_token_can_write "$token"; then
    ui_spin_stop bad "That token is Read-only"
    ui_blank
    ui_say "tmbox has to create a server, so the token needs Read & Write. Generate a new one - the permission cannot be changed after a token exists."
    ui_blank
    return 1
  fi
  ui_spin_stop ok "Token works, and may create resources"

  TMBOX_HCLOUD_TOKEN="$token"
  return 0
}

# --- 4. the confirmation ----------------------------------------------------

setup_step4_confirm() {
  ui_step 4 $SETUP_STEPS "What this will cost"

  # Nothing left to buy: no screen asking whether to buy it (#4).
  if (( SETUP_RESUMING )) && state_has box_id && state_has primary_ip_id && state_has server_id; then
    local eur; eur="$(state_get monthly_eur)"
    ui_ok "Everything is already created${eur:+, about EUR ${eur} / month, net}."
    return 0
  fi

  local capacity; capacity="$(state_get capacity)"
  local -i want_bytes; want_bytes="$(setup_capacity_bytes "$capacity")"

  # A resumed run keeps the location it started in: the Storage Box and the
  # server have to share one, and whichever exists already decided it.
  local region; region="$(state_get region)"
  if (( ! SETUP_RESUMING )) || [[ -z "$region" ]]; then
    region="$(setup_choose_region)"
  fi

  # Prices come from the API, never from a constant. Hetzner changed cloud
  # prices in June 2026, and a wizard quoting a stale figure on the very screen
  # where the user commits money is worse than one quoting none.
  ui_spin_start "Reading current prices from Hetzner"

  local types; types="$(hb_types_json)"
  local box_type; box_type="$(hb_type_for_bytes "$types" "$want_bytes")"
  [[ -n "$box_type" ]] || { ui_spin_stop bad "no tier fits"; ui_die "Hetzner has no Storage Box large enough for ${capacity}." }

  local box_price; box_price="$(hb_type_price "$types" "$box_type" "$region")"
  local box_size;  box_size="$(hb_type_size  "$types" "$box_type")"

  hc GET "/pricing" || hc_fail "reading prices"
  local srv_price ip_price
  srv_price="$(print -r -- "$HTTP_BODY" | jq -er --arg l "$region" \
    '.pricing.server_types[]|select(.name=="cax11")|.prices[]|select(.location==$l)|.price_monthly.net // empty' 2>/dev/null)"
  ip_price="$(print -r -- "$HTTP_BODY" | jq -er --arg l "$region" \
    '.pricing.primary_ips[]|select(.type=="ipv4")|.prices[]|select(.location==$l)|.price_monthly.net // empty' 2>/dev/null)"
  ui_spin_stop ok "Prices read"

  [[ -n "$srv_price" && -n "$ip_price" && -n "$box_price" ]] \
    || ui_die "Hetzner did not report a price for every part. tmbox will not create anything it cannot cost."

  local -F total=$(( srv_price + ip_price + box_price ))

  ui_blank
  if (( SETUP_RESUMING )); then
    ui_say "Part of this already exists from the earlier run, and is billed. tmbox creates the rest, in your own Hetzner project:"
  else
    ui_say "tmbox will create these, in your own Hetzner project:"
  fi
  ui_blank
  ui_kv "Server"      "CAX11 - 2 vCPU Ampere, 4 GB, arm64, Debian 13"
  ui_kv "Location"    "$region"
  # TiB, not TB. The API reports 5497558138880 bytes for a BX21, which is
  # exactly 5 TiB but 5.5 TB - and showing "5.5 TB" next to a tier Hetzner
  # markets as 5 TB reads like an error rather than like precision.
  ui_kv "Storage Box" "$(printf '%s - %.0f TiB' "${(U)box_type}" $(( box_size / 1024.0**4 )))"
  ui_kv "Firewall"    "SSH from this connection only; SMB never exposed"
  ui_kv "IPv4"        "one address, reserved so it survives a rebuild"
  ui_blank
  ui_kv "Server"      "$(printf 'EUR %6.2f / month' $srv_price)"
  ui_kv "IPv4"        "$(printf 'EUR %6.2f / month' $ip_price)"
  ui_kv "Storage Box" "$(printf 'EUR %6.2f / month' $box_price)"
  ui_rule
  ui_kv "Total"       "${C_BOLD}$(printf 'EUR %6.2f / month, net' $total)${C_RESET}"
  ui_blank
  ui_say "Hetzner bills hourly against a monthly cap, so stopping early costs only the hours used. VAT is added according to your account's country."
  ui_blank

  state_set region "$region" box_type "$box_type" monthly_eur "$(printf '%.2f' $total)"

  if (( TMBOX_DRY_RUN )); then
    ui_warn "Dry run - stopping here. Nothing has been created."
    exit 0
  fi

  if (( SETUP_RESUMING )); then
    ui_confirm PROCEED "Create the rest now?" "n" || {
      ui_blank
      ui_say "Stopped. Nothing more was created - what the earlier run created still exists, and is billed."
      ui_say "tmbox destroy removes it."
      exit 0
    }
    return 0
  fi

  ui_say "This is the last point at which nothing exists. After it, tmbox starts creating resources and your account starts being billed."
  ui_blank

  ui_confirm PROCEED "Create these resources now?" "n" \
    || { ui_blank; ui_ok "Stopped. Nothing was created, and nothing is being billed."; exit 0 }
}

# setup_choose_region
#
# Offered from what the API says CAX11 can actually be created in, so the menu
# cannot present a combination Hetzner will refuse. The Storage Box goes in the
# same location as the server, or the SMB path between them leaves the
# datacenter - slower, and an exposure this design does not want.
setup_choose_region() {
  local -a locs=( ${(f)"$(hc_server_locations cax11)"} )
  (( ${#locs} > 0 )) || ui_die "Hetzner reports no locations for CAX11."

  local -a triples=()
  local l
  for l in $locs; do
    case "$l" in
      fsn1) triples+=("$l" "Falkenstein, Germany" "Central Europe.") ;;
      nbg1) triples+=("$l" "Nuremberg, Germany"   "Central Europe.") ;;
      hel1) triples+=("$l" "Helsinki, Finland"    "Northern Europe.") ;;
      *)    triples+=("$l" "$l" "") ;;
    esac
  done
  ui_menu REGION "Where should it live?" "${triples[@]}"
}

# --- 5. provisioning --------------------------------------------------------
#
# Each part checks the state file first and skips what already exists. That is
# what makes the whole step re-runnable: an interrupted provision leaves real
# resources behind, and the only safe way to continue is to recognise them
# rather than create a second set.

setup_step5_provision() {
  ui_step 5 $SETUP_STEPS "Creating the appliance"

  local region;   region="$(state_get region)"
  local box_type; box_type="$(state_get box_type)"
  local mac_name; mac_name="$(state_get mac_name)"

  # A stamp fixed on first use, so a re-run reuses the same names rather than
  # generating new ones and orphaning what it made last time.
  local stamp; stamp="$(state_get name_stamp)"
  if [[ -z "$stamp" ]]; then
    stamp="$(date -u +%Y%m%d%H%M%S)"
    state_set name_stamp "$stamp"
  fi

  local base="tmbox-${mac_name}"

  setup_provision_keys   "$base"
  setup_provision_box    "$base" "$box_type" "$region" "$stamp"
  setup_provision_fw     "$base"
  setup_provision_ip     "$base" "$region"
  setup_provision_server "$base" "$region"

  ui_blank
  ui_ok "The appliance exists."
}

setup_provision_keys() {
  local base="$1"
  if state_has ssh_key_id; then
    ui_ok "SSH keys already created."
    return 0
  fi

  ui_spin_start "Creating SSH keys"
  ssh_keygen admin  "tmbox-admin-${base}"  >/dev/null || ui_die "ssh-keygen failed."
  ssh_keygen tunnel "tmbox-tunnel-${base}" >/dev/null || ui_die "ssh-keygen failed."

  # Only the admin key is uploaded to Hetzner, because only it is needed at
  # first boot. The tunnel key is installed later by the bootstrap, carrying the
  # permitopen restriction that is the entire reason it is a separate key.
  local fp; fp="$(ssh_fingerprint_md5 admin)"
  local id; id="$(hc_ssh_key_find_by_fingerprint "$fp")"
  [[ -n "$id" ]] || id="$(setup_require "$(hc_ssh_key_create "${base}-admin" "$(ssh_pubkey admin)")" "register the SSH key with Hetzner")"

  state_set ssh_key_id "$id"
  ui_spin_stop ok "SSH keys ready"
}

setup_provision_box() {
  local base="$1" box_type="$2" region="$3" stamp="$4"
  local id

  if state_has box_id; then
    id="$(state_get box_id)"
    ui_ok "Storage Box already created."
  else
    ui_spin_start "Creating the Storage Box"
    local pw; pw="$(hb_password)"
    id="$(setup_require "$(hb_create "${base}-${stamp}" "$box_type" "$region" "$pw")" "create the Storage Box")"
    # Recorded the moment it exists, before the wait. The wait is minutes, and
    # a run stopped during it used to leave a box that was billing and that no
    # later run knew about - so the next one bought a second (#4).
    state_set box_id "$id"
    kc_set storagebox-password "$pw" || ui_die "Could not save the Storage Box password."
    ui_spin_stop ok "Storage Box ordered"
  fi

  # Each remaining part is checked on its own, so a run stopped between any two
  # of them continues from the one it had not reached. Skipping the whole
  # function on box_id alone left a resumed appliance with no subaccount.
  if ! state_has box_server; then
    ui_spin_start "Waiting for the Storage Box to become active"
    hb_wait_active "$id"
    state_set box_server "$(hb_server "$id")"
    ui_spin_stop ok "Storage Box ready"
  fi

  state_has box_subaccount && return 0

  # The appliance mounts a subaccount, not the owner. Its home directory is all
  # it can see, so the credentials that have to sit in a file on the appliance
  # cannot reach anything else on the box - including the snapshots, which are
  # the copy that survives the appliance itself being wrong.
  ui_spin_start "Creating a scoped subaccount for the appliance"
  local subpw; subpw="$(hb_password)"
  local sub;   sub="$(setup_require "$(hb_subaccount_create "$id" "tmbox" "$subpw")" "create the Storage Box subaccount")"
  kc_set subaccount-password "$subpw" || ui_die "Could not save the subaccount password."
  state_set box_subaccount "${sub%% *}" box_sub_server "${sub##* }"
  ui_spin_stop ok "Subaccount ${sub%% *} scoped to /tmbox"
}

setup_provision_fw() {
  local base="$1"
  if state_has firewall_id; then
    ui_ok "Firewall already created."
    setup_follow_address
    return 0
  fi

  ui_spin_start "Detecting this connection's public address"
  local ip
  if ! ip="$(public_ipv4)"; then
    ui_spin_stop bad "Could not determine this connection's public address"
    ui_say "tmbox checks it against two independent services and requires them to agree, because the answer becomes a firewall rule and a wrong one would lock you out of your own appliance."
    ui_die "Try again on a connection without a captive portal."
  fi
  ui_spin_stop ok "This connection appears as ${ip}"

  ui_spin_start "Creating the firewall"
  local id; id="$(setup_require "$(hc_firewall_create "$base" "${ip}/32")" "create the firewall")"
  state_set firewall_id "$id" admin_cidr "${ip}/32"
  ui_spin_stop ok "Firewall created - SSH from ${ip} only, SMB not exposed at all"
}

# setup_follow_address - re-pin the firewall if this connection's address moved
#
# The firewall admits one address, and a home connection's changes. A resumed
# run that did not check went on to time out on every ssh step that followed,
# with nothing saying why (#4); doctor --fix could repair it, setup could not.
# Same repair, made here before the first connection that needs it.
setup_follow_address() {
  local recorded current
  recorded="$(state_get admin_cidr)"
  if ! current="$(public_ipv4)"; then
    ui_warn "Could not check this connection's public address."
    ui_say "If it has changed since the firewall was created, the appliance will not answer. tmbox doctor --fix re-pins it."
    return 0
  fi
  [[ "$recorded" == "${current}/32" ]] && return 0

  ui_spin_start "This connection's address changed to ${current}; updating the firewall"
  hc_firewall_set_admin_cidr "$(state_get firewall_id)" "${current}/32"
  state_set admin_cidr "${current}/32"
  ui_spin_stop ok "The firewall now allows ${current}"
}

setup_provision_ip() {
  local base="$1" region="$2"
  if state_has primary_ip_id; then
    ui_ok "Address already reserved."
    return 0
  fi

  ui_spin_start "Reserving an IPv4 address"
  # A location, not a datacenter. The first live run resolved the datacenter and
  # sent it, which Hetzner refused with 422 - `datacenter` is not a field on
  # POST /primary_ips at all. The address is created unassigned and attached
  # when the server is created a moment later.
  local pair
  pair="$(setup_require "$(hc_primary_ip_create "${base}-ipv4" "$region")" \
          "reserve an IPv4 address")"
  state_set primary_ip_id "${pair%% *}" server_ip "${pair##* }"
  ui_spin_stop ok "Reserved ${pair##* }"
}

setup_provision_server() {
  local base="$1" region="$2"
  if state_has server_id; then
    ui_ok "Server already created."
    return 0
  fi

  ui_spin_start "Creating the server"
  local image; image="$(setup_require "$(hc_image_id debian-13 arm)" "find the Debian 13 image")"

  # Checked before the call, not after. hc_server_create interpolates these as
  # JSON numbers with --argjson, so an empty one does not produce a rejected
  # request - it produces malformed JSON, and Hetzner answers "can not read
  # request body", which says nothing about which value was missing. That is
  # exactly what the first live run reported after the address step had failed.
  local key_id fw_id pip_id
  key_id="$(setup_require "$(state_get ssh_key_id)"    "find the SSH key this run created")"
  fw_id="$(setup_require  "$(state_get firewall_id)"   "find the firewall this run created")"
  pip_id="$(setup_require "$(state_get primary_ip_id)" "find the address this run reserved")"

  local pair
  pair="$(setup_require "$(hc_server_create \
    "$base" cax11 "$region" "$image" "$key_id" "$fw_id" "$pip_id" \
    "$(setup_cloud_init)")" "create the server")"
  state_set server_id "${pair%% *}"
  ui_spin_stop ok "Server created"

  ui_spin_start "Waiting for it to start"
  hc_wait_action "${pair##* }" "starting the server"
  ui_spin_stop ok "Server started"

  ui_spin_start "Waiting for SSH"
  if ssh_wait "$(state_get server_ip)" 420; then
    ui_spin_stop ok "The appliance is reachable"
  else
    ui_spin_stop bad "The appliance did not answer SSH"
    ui_say "It exists and is billing. Run tmbox setup again to continue, or tmbox destroy to remove it."
    ui_die "Could not reach the new server over SSH."
  fi
}

# setup_cloud_init
#
# Deliberately minimal. Everything that matters happens in the bootstrap, over
# SSH, where a failure can be reported to the user as it happens - a cloud-init
# that does the real work fails silently into a log nobody reads.
#
# Assembling the appliance from Debian's own repositories at install time,
# rather than shipping an image, is also what keeps the CDDL/GPL question out
# of the product entirely.
setup_cloud_init() {
  cat <<'EOF'
#cloud-config
timezone: UTC
package_update: true
packages:
  - cifs-utils
ssh_pwauth: false
final_message: "cloud-init finished after $UPTIME s - ready for tmbox"
EOF
}

# --- what exists ------------------------------------------------------------

setup_show_state() {
  ui_rule "What exists now"
  ui_blank
  ui_kv "Server"      "$(state_get server_id) at $(state_get server_ip)"
  ui_kv "Storage Box" "$(state_get box_id) - $(state_get box_server)"
  ui_kv "Subaccount"  "$(state_get box_subaccount)"
  ui_kv "Firewall"    "$(state_get firewall_id) - SSH from $(state_get admin_cidr)"
  ui_kv "Cost"        "about EUR $(state_get monthly_eur) / month, net"
  ui_blank
  # The key path is quoted because this line is meant to be copied into a
  # terminal, and the path is not ours to predict: XDG_CONFIG_HOME and $HOME
  # both belong to the user. A space in either makes an unquoted -i argument
  # run as two and fail with "No such file or directory".
  ui_say "Reach it with:  ssh -i \"$(ssh_key_path admin)\" root@$(state_get server_ip)"
  ui_say "Remove it with: tmbox destroy"
  ui_blank
}

# --- 6. the appliance bootstrap ---------------------------------------------
#
# Everything the appliance is happens here, over SSH, where a failure can be
# reported to the user as it occurs. cloud-init deliberately does none of it: a
# cloud-init that does the real work fails silently into a log nobody reads.
#
# The passphrase for the pool is generated on this Mac, kept in the login
# secrets directory, and pushed over the tunnel to the bootstrap's stdin. It is never
# written to the appliance's disk, which is what makes the appliance come up
# locked after a reboot rather than come up readable by whoever holds the disk.

setup_step6_bootstrap() {
  ui_step 6 $SETUP_STEPS "Building the appliance"

  local ip; ip="$(setup_require "$(state_get server_ip)" "find the appliance's address")"

  if [[ "$(state_get bootstrapped)" == "yes" ]]; then
    ui_ok "The appliance is already built."
    setup_check_share_password "$ip"
    return 0
  fi

  setup_push_config "$ip"
  setup_run_bootstrap "$ip"

  state_set bootstrapped yes
  ui_blank
  ui_ok "The appliance is built and serving."
}

# setup_zfs_passphrase
#
# 32 bytes of urandom, base64, alphanumeric. Long enough that it is not worth
# attacking and short enough to retype from a copy kept elsewhere - which
# matters, because a copy the user keeps off this Mac is the only one that
# survives it.
setup_zfs_passphrase() {
  if kc_has zfs-passphrase; then
    kc_get zfs-passphrase
    return 0
  fi
  local pw
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | dd bs=1 count=44 2>/dev/null)"
  [[ ${#pw} -eq 44 ]] || ui_die "Could not generate a passphrase from /dev/urandom."
  kc_set zfs-passphrase "$pw" || ui_die "Could not save the passphrase."
  print -rn -- "$pw"
}

# setup_container_mb
#
# How large the container file should be. Defaults to 95% of the Storage Box,
# leaving room for the box's own snapshots of it - and overridable, because a
# multi-terabyte `dd` is hours and a test run should not have to wait for one.
setup_container_mb() {
  if ans_has CONTAINER_MB; then
    print -rn -- "$(ans_get CONTAINER_MB)"
    return 0
  fi
  local types; types="$(hb_types_json)"
  local -i size; size="$(hb_type_size "$types" "$(state_get box_type)")"
  print -rn -- $(( size / 1024 / 1024 * 95 / 100 ))
}

setup_push_config() {
  local ip="$1"
  ui_spin_start "Sending the appliance its configuration"

  local sub_user;   sub_user="$(state_get box_subaccount)"
  local sub_server; sub_server="$(state_get box_sub_server)"
  local sub_pw;     sub_pw="$(kc_get subaccount-password)" \
    || { ui_spin_stop bad "no subaccount password"; ui_die "The Storage Box subaccount password is missing from this Mac." }

  # A subaccount's SMB share is named after the subaccount itself, and it is
  # rooted at the home directory it was created with - so the appliance can
  # reach its own directory and nothing else on the box.
  local share="//${sub_server}/${sub_user}"

  local -i mb; mb="$(setup_container_mb)"
  # The refquota is what macOS sees as the disk size. A little under the
  # container, so ZFS has room for its own metadata and the client is told a
  # figure the pool can actually honour.
  local -i quota_gb=$(( mb / 1024 * 92 / 100 ))
  (( quota_gb >= 1 )) || quota_gb=1

  # Every value is single-quoted. The config is sourced by bash on the
  # appliance, and an SSH public key is three space-separated fields - unquoted,
  # the shell read the key material as a command and the bootstrap died on
  # "AAAAC3Nz...: command not found". None of these values can contain a single
  # quote: the key is base64 with a comment tmbox chose, and the rest are
  # identifiers and numbers.
  ssh_put_data "$ip" "$(cat <<EOF
# Written by tmbox. Not a secret: identifiers only.
TMBOX_MAC_NAME='$(state_get mac_name)'
TMBOX_SHARE='${share}'
TMBOX_SMB_USER='tmuser'
TMBOX_IMG_SIZE_MB='${mb}'
TMBOX_REFQUOTA='${quota_gb}G'
TMBOX_TUNNEL_PUBKEY='$(ssh_pubkey tunnel)'
EOF
)" /etc/tmbox/config 0600 >/dev/null 2>&1 \
    || { ui_spin_stop bad "could not write the configuration"; ui_die "Could not write /etc/tmbox/config on the appliance." }

  # The CIFS credentials file. mount.cifs reads it directly, and it is the one
  # credential that genuinely has to rest on the appliance's disk - which is why
  # it belongs to a subaccount scoped to one directory rather than to the box
  # owner.
  ssh_put_data "$ip" "username=${sub_user}
password=${sub_pw}
" /etc/tmbox/cifs-creds 0600 >/dev/null 2>&1 \
    || { ui_spin_stop bad "could not write the credentials"; ui_die "Could not write the Storage Box credentials on the appliance." }

  ui_spin_stop ok "Configuration sent"
}

# setup_bootstrap_source - the bootstrap script itself
#
# Embedded in the built artifact as base64 and read from the checkout otherwise,
# so there is never a second thing to download at install time. The appliance
# fetches nothing from us; only from Debian.
setup_bootstrap_source() {
  if (( ${+TMBOX_BOOTSTRAP_B64} )) && [[ -n "$TMBOX_BOOTSTRAP_B64" ]]; then
    print -rn -- "$TMBOX_BOOTSTRAP_B64" | base64 -d
    return 0
  fi
  local src="${TMBOX_ROOT:-}/appliance/bootstrap.sh"
  [[ -f "$src" ]] || ui_die "Cannot find the appliance bootstrap script."
  cat -- "$src"
}

# setup_wait_for_cloud_init <ip>
#
# sshd answers well before cloud-init has finished, and cloud-init's last act on
# a Debian cloud image is a round of apt work of its own. Sending the bootstrap
# as soon as SSH responds therefore lands a second apt-get on top of a running
# one, and the appliance dies on:
#
#   E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process …
#
# Measured on a from-zero run, 2026-09-19. It is a race, so it is intermittent
# by nature - which is the worst kind of bug to leave in a provisioning step
# that a user runs once and judges the product by.
#
# `cloud-init status --wait` is the supported way to ask, and it blocks until
# the run is done. Its exit status is deliberately not treated as fatal: 2 means
# "finished with warnings", which is common and harmless here, and an image
# without cloud-init at all should fall through to a bootstrap that then works.
# The wait itself is what matters, not the verdict.
setup_wait_for_cloud_init() {
  local ip="$1"

  ui_spin_start "Waiting for the server's own first-boot setup to finish"
  if ssh_run "$ip" 'command -v cloud-init >/dev/null 2>&1' >/dev/null 2>&1; then
    # Bounded: a cloud-init that never finishes must not hang the installer
    # for ever. If the wait times out the bootstrap still runs, and its own
    # apt failure is a better error than a silent stall here.
    ssh_run "$ip" 'cloud-init status --wait >/dev/null 2>&1 || true; cloud-init status --long 2>/dev/null | head -3' \
      >/dev/null 2>&1
    ui_spin_stop ok "First-boot setup finished"
  else
    ui_spin_stop ok "No first-boot setup to wait for"
  fi
}

setup_run_bootstrap() {
  local ip="$1"

  setup_wait_for_cloud_init "$ip"

  ui_spin_start "Sending the bootstrap"
  ssh_put_data "$ip" "$(setup_bootstrap_source)" /usr/local/sbin/tmbox-bootstrap 0700 >/dev/null 2>&1 \
    || { ui_spin_stop bad "could not send it"; ui_die "Could not copy the bootstrap to the appliance." }
  ui_spin_stop ok "Bootstrap sent"

  local pass; pass="$(setup_zfs_passphrase)"

  ui_blank
  ui_say "The appliance now installs ZFS and Samba from Debian's own repositories, compiles the ZFS module, and builds the pool. The module compile alone takes about five minutes on this hardware."
  ui_blank
  ui_say "Progress from the appliance:"
  ui_blank

  # Streamed rather than captured. This is minutes of work and the user needs to
  # see it moving; a spinner over a silent ten-minute SSH session is
  # indistinguishable from a hang.
  #
  # The passphrase goes to the remote process's stdin. Never an argument: an
  # argument is readable in ps on the appliance for the life of the process.
  local out; local -i rc=0
  out="$(print -rn -- "$pass" \
    | ssh ${(f)"$(ssh_opts admin)"} "root@${ip}" -- /usr/local/sbin/tmbox-bootstrap 2>&1 \
    | tee /dev/fd/$TMBOX_UI_FD)" || rc=$?

  log_debug "bootstrap output: ${out//$'\n'/$'\036'}"

  if (( rc != 0 )); then
    ui_blank
    ui_bad "The appliance bootstrap failed."
    ui_say "The last lines above say why, and the whole exchange is in ${TMBOX_LOG_FILE}. The appliance exists and is billing; running tmbox setup again resumes from where this stopped, and tmbox destroy removes it."
    exit 1
  fi

  setup_collect_share_password "$ip"
}

# --- 7. the transport -------------------------------------------------------
#
# The appliance is serving, but on a private address behind a firewall that
# admits one address. Nothing about it is published: the share becomes reachable
# because this Mac opens an outbound SSH connection and forwards a local port
# into it, which is also why no inbound rule, no VPN profile and no third-party
# agent appears anywhere in this product.

setup_step7_tunnel() {
  ui_step 7 $SETUP_STEPS "Connecting this Mac"

  local ip; ip="$(setup_require "$(state_get server_ip)" "find the appliance's address")"

  # Checked from the appliance's side first. A forward that lands on a port
  # nothing is listening to fails in the SMB client, several layers away from
  # the cause, and the message the user gets there names neither Samba nor the
  # pool being locked.
  ui_spin_start "Checking that the appliance is serving"
  local serving
  serving="$(ssh_run "$ip" 'systemctl is-active smbd 2>/dev/null; zfs get -H -o value keystatus tank/tm 2>/dev/null' 2>/dev/null)" \
    || serving=""
  if [[ "$serving" != *active* ]]; then
    ui_spin_stop bad "Samba is not running on the appliance"
    ui_say "The pool is probably still locked. tmbox unlock sends the key, and tmbox doctor says which of the two it is."
    exit 1
  fi
  ui_spin_stop ok "The appliance is serving"

  ui_blank
  ui_say "Time Machine will be pointed at ${TM_LOOPBACK_ALIAS}, an address that exists only inside this Mac. Everything sent to it goes through one outbound SSH connection to the appliance, so the share is never exposed to the network and the appliance's firewall stays closed to everything but this address."
  ui_blank

  tunnel_install || {
    ui_blank
    ui_bad "The tunnel could not be installed."
    ui_say "The appliance is built and recorded; once this is fixed, tmbox setup continues from here. tmbox tunnel status reports what is wrong."
    exit 1
  }
}

# setup_collect_share_password <ip>
#
# The share password is generated on the appliance, so it never has to travel
# from here, and it is fetched on its own connection rather than parsed out of
# the bootstrap's output. The bootstrap's output is streamed to the terminal and
# into the transcript; a credential printed there would live on in scrollback
# and in any support mail the transcript is pasted into.
setup_collect_share_password() {
  local ip="$1" smb_pw
  smb_pw="$(ssh_run "$ip" cat /etc/tmbox/smb_password 2>/dev/null)" || smb_pw=""
  if [[ -z "$smb_pw" ]]; then
    ui_warn "The appliance did not report a share password; tmbox doctor will check it."
    return 0
  fi
  log_secret "$smb_pw"
  kc_set samba-password "$smb_pw" || ui_die "Could not save the share password."
  ui_ok "Share credentials saved."
}

# setup_check_share_password <ip>
#
# The appliance's copy is the one Samba uses, so it is the one that is right.
# A run found the Mac holding a different one - cause never established, but
# one path is setup_collect_share_password keeping the stored value when the
# fetch fails - and step 8 then failed with tmutil's authentication error (#4).
# Compared by fingerprint, so neither copy is printed or logged, and replaced
# when they differ. step 8 sees the new fingerprint and replaces a destination
# that was set with the old one.
setup_check_share_password() {
  local ip="$1" remote_fp
  remote_fp="$(ssh_run "$ip" "tr -d '\\n' < /etc/tmbox/smb_password | sha256sum | cut -c1-16" 2>/dev/null)" || remote_fp=""
  if [[ -z "$remote_fp" ]]; then
    ui_warn "Could not read the share password's fingerprint from the appliance; tmbox doctor checks it."
    return 0
  fi
  [[ "$remote_fp" == "$(setup_pw_fingerprint)" ]] && return 0

  log_warn "share password on this Mac differs from the appliance's; fetching it again"
  ui_warn "The share password on this Mac did not match the appliance's."
  setup_collect_share_password "$ip"
}

# --- 8. the Time Machine destination ----------------------------------------
#
# The share is reachable; this is where macOS is told to use it.
#
# `tmutil setdestination` is the only supported way to add a network
# destination from a command line, and it has two properties that shape
# everything here. It needs root - and Full Disk Access, which is a TCC
# decision with no command-line equivalent, so it can only be asked for. And
# it reads the share password from a terminal rather than from stdin, which is
# why macos/setdest.exp exists: a pty is the only way to answer that prompt
# unattended, and /usr/bin/expect is the only thing on a stock Mac that can
# provide one.
#
# `-a` is never omitted. Without it the argument *replaces* the destination
# list, so a Mac that already backs up to a local disk would silently stop.

setup_step8_destination() {
  ui_step 8 $SETUP_STEPS "Pointing Time Machine at it"

  local share="tm-$(state_get mac_name)"
  local url="smb://${TMBOX_SHARE_USER}@${TM_LOOPBACK_ALIAS}/${share}"

  # Idempotent, and not only for tidiness: adding a destination twice is how a
  # Mac ends up with two entries for the same share and alternates between
  # them, halving the history it keeps in each.
  local existing; existing="$(tm_destination_id "$share")"
  if [[ -n "$existing" ]]; then
    # Matching the URL is not enough. The URL is a loopback address and a share
    # name, both of which a rebuilt appliance reproduces exactly - while its
    # Samba password is new. backupd then authenticates with what is still in
    # the System keychain and the backup dies with
    # BACKUP_FAILED_AUTHENTICATION_ERROR (29), which names the keychain rather
    # than the rebuild and sends people looking in the wrong place.
    #
    # Measured 2026-09-19, on exactly the path the docs recommend: destroy,
    # then build again. So the destination is stale if it was set for a
    # different appliance, or with a different password.
    if [[ "$(state_get destination_server_id)" == "$(state_get server_id)" \
       && "$(state_get destination_pw_fp)" == "$(setup_pw_fingerprint)" ]]; then
      ui_ok "Time Machine already has this destination."
      state_set destination_id "$existing" destination_url "$url"
      setup_report_encryption "$share"
      return 0
    fi

    ui_say "Time Machine has this destination from an earlier appliance, whose credentials no longer work. Replacing it."
    # Measured 2026-09-19, and the user has to be told because tmbox cannot fix
    # it from here. Replacing a destination that keeps the same smb:// URL
    # leaves macOS holding credential state that backupd cannot get past: every
    # backup then fails with BACKUP_FAILED_AUTHENTICATION_ERROR (29) even
    # though the new password is correct, the share is reachable, and
    # `tmutil setdestination` itself authenticated with it seconds earlier.
    #
    # Proven not to be any of the obvious things: the keychain item is created
    # fresh with the right attributes, deleting it and re-adding changes
    # nothing, and restarting backupd changes nothing. Samba sees the TCP
    # connection arrive and then end with no SMB negotiation at all, so the
    # client is giving up before it sends a byte. A reboot clears it, after
    # which the same destination works.
    #
    # Measured again 2026-10-01, and wider than the URL: a rebuild under a
    # different share name, with the old destination already removed by hand,
    # failed the same way until the Mac restarted. The state belongs to the
    # server address, 127.0.0.2, so this branch is only the case tmbox can see.
    TMBOX_DESTINATION_REPLACED=1
    # Removed rather than re-added: `setdestination -a` appends, and two
    # entries for one share make Time Machine alternate between them and halve
    # the history it keeps in each.
    priv_run_quiet /usr/bin/tmutil removedestination "$existing" >/dev/null 2>&1 \
      || ui_warn "The old destination could not be removed; continuing."
  fi

  # Checked at startup too. Again here because the terminal can change between
  # the two - a resumed run started from a different app, for one.
  preflight_time_machine_ready || {
    ui_blank
    ui_say "Everything up to here is built and recorded. Grant Full Disk Access and run tmbox setup again; it continues from this step."
    exit 1
  }

  local pw; pw="$(kc_get samba-password)" || pw=""
  if [[ -z "$pw" ]]; then
    ui_bad "The share password is not on this Mac."
    ui_say "It was generated on the appliance during setup. tmbox doctor can fetch it again."
    exit 1
  fi

  priv_prime || exit 1

  ui_spin_start "Adding the destination"
  local -i rc=0
  setup_run_setdestination "$url" "$pw" || rc=$?

  case $rc in
    0)  ui_spin_stop ok "Destination added" ;;
    64) ui_spin_stop bad "the password never reached tmutil"
        ui_die "Internal error: the share password was not delivered to tmutil." ;;
    90) ui_spin_stop bad "tmutil never asked for the password"
        ui_say "That usually means tmutil rejected the URL before authenticating. The transcript has its output: ${TMBOX_LOG_FILE}"
        exit 1 ;;
    91) ui_spin_stop bad "tmutil stopped responding"
        # Measured, and worth naming precisely: a client that held a lease on
        # the share and then vanished - a Mac that slept, or a tunnel killed
        # mid-mount - leaves Samba waiting for a lease break that will never
        # come, and every later client blocks behind it. It clears when the
        # stale session is closed on the appliance.
        ui_say "The share is reachable but not answering. This is usually a stale session left by a client that disappeared while holding the share open."
        ui_say "Run tmbox doctor, which finds and clears those, then run tmbox setup again."
        exit 1 ;;
    80) # tmutil uses 80 for two different failures, and only its own
        # message tells them apart. Missing Full Disk Access was reported here
        # as a wrong password once, and sent the user to sync a password that
        # had never been the problem (#6).
        if [[ "$SETUP_SETDEST_OUT" == *"Full Disk Access"* ]]; then
          ui_spin_stop bad "tmutil needs Full Disk Access"
          fda_explain
        else
          ui_spin_stop bad "the appliance rejected the share password"
          ui_say "tmutil's own message is in ${TMBOX_LOG_FILE}. tmbox doctor checks the share and its credentials."
        fi
        exit 1 ;;
    *)  ui_spin_stop bad "tmutil refused the destination (${rc})"
        ui_say "tmutil's own message is in ${TMBOX_LOG_FILE}."
        exit 1 ;;
  esac

  local id; id="$(tm_destination_id "$share")"
  if [[ -z "$id" ]]; then
    ui_bad "tmutil reported success but Time Machine has no such destination."
    exit 1
  fi
  state_set destination_id "$id" destination_url "$url" \
            destination_server_id "$(state_get server_id)" \
            destination_pw_fp "$(setup_pw_fingerprint)"
  ui_kv "Destination" "$id"

  setup_report_encryption "$share"

  # The one thing in tmbox that needs it is done. Said here because users
  # reasonably do not want a terminal holding Full Disk Access for good (#6).
  ui_blank
  ui_say "Full Disk Access was needed for that step only. You can switch it off for $(fda_app_name) now. tmbox status and doctor still run without it, but say so where a check needs it - reading the backup history, for one."

  if (( ${TMBOX_DESTINATION_REPLACED:-0} )); then
    ui_blank
    ui_warn "Restart this Mac before the next backup."
    ui_say "Replacing a destination leaves macOS holding credential state that Time Machine cannot get past; until the Mac restarts, every backup fails with an authentication error even though the share and the password are both fine. Nothing else clears it."
  fi
}

# setup_pw_fingerprint - identifies the share password without storing it
#
# A hash, because the state file is not a place for credentials and this only
# ever needs to answer "is it still the same one". Truncated: this is a change
# detector, not an authenticator.
setup_pw_fingerprint() {
  local pw; pw="$(kc_get samba-password 2>/dev/null)" || pw=""
  [[ -n "$pw" ]] || { print -rn -- ""; return 0 }
  print -rn -- "$pw" | shasum -a 256 | cut -c1-16
}

# setup_setdest_source - the pty driver for tmutil's password prompt
setup_setdest_source() {
  if (( ${+TMBOX_SETDEST_EXP_B64} )) && [[ -n "$TMBOX_SETDEST_EXP_B64" ]]; then
    print -rn -- "$TMBOX_SETDEST_EXP_B64" | base64 -d
    return 0
  fi
  local src="${TMBOX_ROOT:-}/macos/setdest.exp"
  [[ -f "$src" ]] || return 1
  cat -- "$src"
}

# setup_run_setdestination <url> <password>
#
# The password goes in on stdin and nowhere else: an argument would sit in `ps`
# for every user on the machine for as long as the process lived.
setup_run_setdestination() {
  local url="$1" pw="$2"
  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/tmbox-setdest.XXXXXX")" || return 65
  chmod 0700 "$stage" 2>/dev/null

  setup_setdest_source > "${stage}/setdest.exp" 2>/dev/null || { rm -rf -- "$stage"; return 66 }

  local out; local -i rc=0
  # priv_run_quiet, not priv_run: with the timestamp expired, a prompting sudo
  # would read the share password off this pipe. Failing is the only safe
  # outcome, and priv_prime above is what stops it happening.
  out="$(print -rn -- "$pw" | priv_run_quiet /usr/bin/expect -f "${stage}/setdest.exp" "$url" 2>&1)" || rc=$?
  rm -rf -- "$stage"

  # Kept for the caller, which needs the text to tell tmutil's two meanings of
  # 80 apart. Logged at info, not debug: the failure message points the user
  # at the transcript, and at the default level a debug line is never written
  # (#6). tmutil echoes its prompt; the password itself was registered as a
  # secret when it was stored, so log_redact removes it.
  typeset -g SETUP_SETDEST_OUT="$out"
  log_info "setdestination exit ${rc}, output: ${out//$'\n'/$'\036'}"
  return $rc
}

# setup_report_encryption <share>
#
# Time Machine's own encryption is the layer that excludes everyone else -
# Hetzner, us, and anyone who ends up holding the Storage Box. It cannot be
# turned on from a command line: `tmutil` has no encryption verb at all, which
# was checked against the binary's verb table rather than the man page. So the
# honest thing is to report what is actually true of the destination and say
# exactly where to change it.
setup_report_encryption() {
  local share="$1"
  local bundle; bundle="$(tm_bundle_path "$share")" || bundle=""

  if [[ -z "$bundle" ]]; then
    # Before the first backup there is nothing to inspect, and saying nothing is
    # better than guessing. Recorded rather than printed.
    log_info "no sparsebundle on the destination yet; encryption not determined"
    return 0
  fi

  # As root: the destination is mounted under /Volumes/.timemachine, which the
  # user being backed up cannot read. Run unprivileged, hdiutil reports
  # "Permission denied" - which is not an answer about encryption and must not
  # be treated as one.
  local answer
  answer="$(priv_run_quiet /usr/bin/hdiutil isencrypted "$bundle" 2>&1)" || answer=""
  if [[ -z "$answer" || "$answer" == *"denied"* || "$answer" == *"failed"* ]]; then
    ui_warn "Could not read the backup's encryption state."
    ui_say "tmbox doctor checks it again with the rights it needs."
    log_warn "hdiutil isencrypted: ${answer}"
    return 0
  fi

  if [[ "$answer" == *(#i)"encrypted: yes"* ]]; then
    ui_ok "The backup on the appliance is encrypted."
    state_set destination_encrypted yes
    return 0
  fi

  state_set destination_encrypted no
  ui_blank
  ui_warn "This destination is not encrypted."
  ui_say "The ZFS pool underneath it is, so the Storage Box holds nothing readable - but the appliance itself could read these backups. Time Machine's own encryption is what excludes it, and macOS only offers that switch in its interface:"
  ui_item "System Settings → General → Time Machine"
  ui_item "select ${share}, then Remove Backup Disk"
  ui_item "Add Backup Disk → ${share} → tick Encrypt Backup Disk"
  ui_say "Choose the encryption password yourself and keep a copy somewhere that does not depend on this Mac: tmbox does not store it, and nobody can recover it. If macOS asks for the share's credentials, the user is tmuser and the password is in $(kc_path samba-password). Nothing else about the setup changes."
  ui_blank
}

# --- 9. the first backup ----------------------------------------------------

setup_step9_first_backup() {
  ui_step 9 $SETUP_STEPS "The first backup"

  local -i wait_min=0
  local answer; answer="$(ans_get BACKUP_WAIT)"
  [[ "$answer" == <-> ]] && wait_min=$answer

  local dest; dest="$(state_get destination_id)"

  # A backup already under way must not be restarted. Measured the hard way:
  # starting a second one dropped the first with
  # BACKUP_IN_PROGRESS_REQUEST_DROPPED, and what was left on the destination was
  # an incomplete bundle and a failed backup.
  if tm_running "$dest"; then
    ui_ok "A backup to the appliance is already running."
    setup_watch_backup "$dest" $wait_min
    return 0
  fi

  # A backup to another destination - a local disk, typically - is not ours to
  # watch, and not ours to interrupt either: the same rule applies to it. It
  # was once shown here as the appliance's first backup (#7).
  if tm_running_elsewhere "$dest"; then
    ui_say "Time Machine is backing up to another destination right now. The first backup to the appliance can start when that one finishes."
    if [[ "$answer" == "0" ]] || ! ui_confirm WAIT_OTHER_BACKUP "Wait for it, then start the first backup to the appliance?" "y"; then
      ui_say "Time Machine alternates between its destinations and will get to the appliance on its own. To start it yourself once the other backup is done:"
      ui_say "  sudo tmutil startbackup --destination ${dest}"
      return 0
    fi
    ui_spin_start "Waiting for the other backup to finish"
    while tm_running_elsewhere "$dest"; do sleep 15; done
    ui_spin_stop ok "The other backup finished"
  fi

  if [[ "$answer" == "0" ]]; then
    ui_say "Starting the first backup and leaving it to run, as asked."
    setup_start_backup "$dest" \
      || { ui_warn "Could not start a backup; Time Machine will start one on its own schedule."; return 0 }
    ui_ok "Backup started. tmbox status shows how it is getting on."
    return 0
  fi

  ui_say "The first backup copies everything, so it is measured in hours rather than minutes - and it is bounded by the upload speed of this connection, not by the appliance. Later backups copy only what changed."
  ui_blank

  if ! setup_start_backup "$dest"; then
    ui_warn "Could not start a backup now."
    ui_say "Time Machine will start one on its own schedule; tmbox status reports it."
    return 0
  fi

  setup_watch_backup "$dest" $wait_min
}

# setup_start_backup <destination-id>
#
# Named explicitly. A bare `startbackup` lets Time Machine choose, and with a
# second destination configured it may well choose the other one.
setup_start_backup() {
  if [[ -n "$1" ]]; then
    priv_run tmutil startbackup --destination "$1" >/dev/null 2>&1
  else
    priv_run tmutil startbackup >/dev/null 2>&1
  fi
}

# setup_watch_backup <minutes, 0 for no limit>
#
# Progress comes from the phase and the fraction, not from the byte counters:
# this project measured `tmutil status` reporting "Total copied: 0.00 MB" for
# 23 MiB actually transferred, so the bytes are not trustworthy enough to show
# a user. The phase is, and it is also what distinguishes a slow link from a
# stall.
setup_watch_backup() {
  local dest="$1"
  local -i limit_min="$2" waited=0 interval=15
  local phase

  # Recorded first, so "finished" means a completed backup newer than this one
  # appeared for this destination - not that some backup exists somewhere.
  local before; before="$(tm_latest_backup_for "$dest")" || before=""

  while :; do
    # Out of 100, because what tmutil reports is a fraction rather than a byte
    # count - and its byte counters are the part measured to be wrong.
    phase="$(tm_phase)"
    ui_progress "$(tm_percent)" 100 "${phase:-starting}"

    if ! tm_running "$dest"; then
      # A backup that is no longer running either finished or failed, and
      # tmutil's own status does not say which. The destination's own record
      # does.
      ui_blank
      local latest; latest="$(tm_latest_backup_for "$dest")" || latest=""
      if [[ -n "$latest" && "$latest" != "$before" ]]; then
        ui_ok "The first backup finished."
        ui_kv "Backup" "$latest"
      else
        ui_warn "The backup stopped before completing."
        # The failure worth naming, because it is the one this profile
        # provokes: creating the sparsebundle and attaching it over the link
        # can take minutes, and backupd gives up waiting for the volume to
        # appear - "Backup volume device entry did not appear in IOKit registry
        # in a timely manner", then BACKUP_FAILED_DISCONNECTED_NETWORK. The
        # next attempt finds the bundle already there and does not have to wait.
        ui_say "A first attempt often fails while the backup image is being created, because attaching it over the link is slow and Time Machine stops waiting. It retries on its own, and the next attempt has less to do."
        ui_say "tmbox doctor reports what happened; tmbox status shows the retry."
      fi
      break
    fi

    sleep $interval
    (( waited += interval ))
    if (( limit_min > 0 && waited >= limit_min * 60 )); then
      ui_blank
      ui_ok "The backup is running, and will carry on without tmbox."
      ui_say "tmbox status reports its progress."
      break
    fi
  done

  # Now that the share has been mounted by backupd, the bundle exists and the
  # encryption question has a real answer rather than a guess.
  setup_report_encryption "tm-$(state_get mac_name)"
}
