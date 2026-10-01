#!/bin/zsh
#
# The HTTP layer both Hetzner APIs sit on.
#
# Two things here are not incidental.
#
# **The token never appears in argv.** `curl -H "Authorization: Bearer $tok"`
# puts the credential in the process arguments, where any user on the Mac can
# read it out of `ps` for the life of the request. curl reads a config file from
# stdin with `-K -`, so the header arrives down a pipe instead: off argv, off
# disk, and gone when the process exits. tools/lint.zsh enforces the rule.
#
# **Failure is never silent.** A non-2xx is a non-zero exit, and the status is
# always available. A request that quietly yields an empty body is how a script
# ends up creating a server in the wrong location or writing a firewall rule
# with no address in it.
#
# **Results come back in globals, not on stdout.** This is the one interface
# decision here worth arguing about. The obvious shape is
# `body="$(http_get "$url")"`, and it is wrong: command substitution runs a
# subshell, so HTTP_STATUS set inside it is discarded and the caller silently
# reads an empty status. That bit once already. So http_request assigns
# HTTP_BODY and HTTP_STATUS in the caller's own shell, and callers read:
#
#     http_get "$url" || api_fail "listing servers"
#     id="$(json_get '.servers[0].id' "$HTTP_BODY")"
#
# which also saves a fork per request.
#
# Retries cover the two failures worth retrying - 429 and 5xx - using the reset
# time the API actually reports rather than a guessed delay. Everything else,
# including 401 and 422, returns to the caller immediately: retrying a rejected
# token just wastes the user's time.

typeset -g  HTTP_STATUS=""
typeset -g  HTTP_BODY=""
typeset -gi HTTP_MAX_ATTEMPTS="${HTTP_MAX_ATTEMPTS:-5}"

# http_request <method> <url> [json-body] [token]
#
# Sets HTTP_BODY and HTTP_STATUS. Returns 0 for 2xx, 1 otherwise.
# Do NOT call inside $( ) - see the note above.
http_request() {
  local method="$1" url="$2" body="${3:-}" token="${4:-${TMBOX_HCLOUD_TOKEN:-}}"
  local -i attempt=1 delay=2

  # stdin belongs to the curl config, because that is what carries the
  # credential. A request body therefore cannot also come from stdin: it goes
  # into a mode-600 file inside the mode-700 scratch directory and is passed as
  # `--data-binary @file`. Getting this wrong is quiet and confusing - an
  # earlier version redirected stdin to the body file, so curl read the JSON as
  # its config, sent no Authorization header at all, and the API answered
  # "token is required" for a token that was perfectly valid.
  local bodyfile=""
  if [[ -n "$body" ]]; then
    bodyfile="${_http_tmpdir}/body.$$"
    ( umask 077; print -rn -- "$body" > "$bodyfile" )
  fi

  while (( attempt <= HTTP_MAX_ATTEMPTS )); do
    local -a args=(
      -sS --location
      --connect-timeout 15 --max-time 120
      -X "$method"
      -H 'Accept: application/json'
      -H "User-Agent: tmbox/${TMBOX_VERSION:-dev}"
      -D "$_http_hdrfile"
      -w $'\n%{http_code}'
    )
    [[ -n "$bodyfile" ]] && \
      args+=(-H 'Content-Type: application/json' --data-binary "@$bodyfile")

    local raw=""
    raw="$(_http_config "$token" | curl "${args[@]}" -K - "$url" 2>&1)" || true

    HTTP_STATUS="${raw##*$'\n'}"
    HTTP_BODY="${raw%$'\n'*}"

    # curl itself failed - DNS, TLS, connection refused - so there is no status.
    if [[ "$HTTP_STATUS" != <-> ]]; then
      log_warn "http: $method $url: curl failed: ${HTTP_BODY[1,200]}"
      HTTP_STATUS="000"
    fi

    log_debug "http: $method ${url##*/} -> $HTTP_STATUS (attempt $attempt)"

    case "$HTTP_STATUS" in
      2*)
        [[ -n "$bodyfile" ]] && rm -f -- "$bodyfile"
        return 0
        ;;
      429|000|5*)
        if (( attempt == HTTP_MAX_ATTEMPTS )); then break; fi
        local -i wait=$delay
        # Hetzner reports when the window resets; honour it rather than guessing.
        # The header is an absolute epoch, so the wait is computed from it, and
        # clamped - a clock skew must not turn into an hour-long sleep.
        if [[ "$HTTP_STATUS" == "429" ]]; then
          local reset
          reset="$(_http_header ratelimit-reset)"
          if [[ "$reset" == <-> ]]; then
            wait=$(( reset - $(_http_epoch) + 1 ))
            (( wait >= 1 )) || wait=1
            (( wait <= 120 )) || wait=120
          fi
          log_warn "http: rate limited, waiting ${wait}s"
        fi
        sleep "$wait"
        (( delay *= 2 ))
        (( attempt++ ))
        ;;
      *)
        [[ -n "$bodyfile" ]] && rm -f -- "$bodyfile"
        return 1
        ;;
    esac
  done

  [[ -n "$bodyfile" ]] && rm -f -- "$bodyfile"
  return 1
}

http_get()    { http_request GET    "$1" ""   "${2:-}" }
http_post()   { http_request POST   "$1" "$2" "${3:-}" }
http_put()    { http_request PUT    "$1" "$2" "${3:-}" }
http_delete() { http_request DELETE "$1" ""   "${2:-}" }

# --- internals --------------------------------------------------------------

typeset -g _http_tmpdir=""
typeset -g _http_hdrfile=""

# http_init - a private, mode-700 scratch directory for the header dump
#
# Response headers are written to a file because curl cannot interleave them
# with the body on stdout without making the body unparseable.
http_init() {
  [[ -n "$_http_tmpdir" && -d "$_http_tmpdir" ]] && return 0
  _http_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tmbox.XXXXXX")" || return 1
  chmod 0700 "$_http_tmpdir"
  _http_hdrfile="$_http_tmpdir/headers"
  : > "$_http_hdrfile"
  return 0
}

http_cleanup() {
  [[ -n "$_http_tmpdir" && -d "$_http_tmpdir" ]] && rm -rf -- "$_http_tmpdir"
  _http_tmpdir=""
  return 0
}

# _http_config <token> - a curl config file on stdout
#
# curl's config format takes a quoted value with backslash escapes. A Hetzner
# token is 64 hex-ish characters so neither can occur, but escaping anyway costs
# nothing and stops this from becoming an injection point if it is ever reused
# for a password.
_http_config() {
  local tok="${1:-}"
  [[ -n "$tok" ]] || return 0
  local esc="${tok//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  print -r -- "header = \"Authorization: Bearer ${esc}\""
}

# _http_header <name> - a header from the last response, lower-cased lookup
_http_header() {
  [[ -f "$_http_hdrfile" ]] || return 1
  local want="${(L)1}" line found=""
  # --location means the file can hold several header blocks, one per hop.
  # The last occurrence is the one that describes the response we actually got,
  # so keep overwriting rather than printing as we go.
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "${(L)line}" == "${want}:"* ]] || continue
    found="${${line#*:}## }"
  done < "$_http_hdrfile"
  print -rn -- "$found"
  return 0
}

_http_epoch() {
  if (( ${+EPOCHSECONDS} )); then print -rn -- $EPOCHSECONDS; else date +%s; fi
}
