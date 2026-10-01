#!/bin/zsh
#
# JSON, via Apple's own jq.
#
# /usr/bin/jq ships with macOS - verified on 26.7: identifier com.apple.jq,
# version jq-1.7.1-apple, signed by "macOS Software Signing", living in a
# SIP-protected directory nothing but Apple can write to. So it is a stock tool
# in the same sense curl and plutil are, and no Homebrew is implied by using it.
#
# The alternative was `plutil -extract … raw -o - -- -`, which does read JSON
# from stdin. It was rejected after trying it: asked for a nested object it
# returns the key names rather than the value, it has no way to filter an array
# by a field, and its keypath syntax breaks on a key containing a dot. Every one
# of those shows up in the Hetzner API - picking the fsn1 entry out of a prices
# array is the common case. Building that out of plutil and shell would be a
# small, wrong JSON parser.
#
# Everything here treats a parse failure as an error rather than as an empty
# string. An API response that silently reads as "" produces a confident,
# completely wrong outcome further down - a firewall rule with no address, or a
# server created in the wrong location.

# json_get <filter> [input]
#
# Extract one value. Reads stdin when no input is given. A JSON null comes back
# as the empty string, because every caller wants "absent" rather than the
# four characters n-u-l-l.
json_get() {
  local filter="$1"
  if (( $# >= 2 )); then
    print -r -- "$2" | jq -er "$filter // empty" 2>/dev/null
  else
    jq -er "$filter // empty" 2>/dev/null
  fi
}

# json_get_or_die <input> <filter> <what>
#
# The same, but a missing or null value stops the run. Used for anything the
# next step would otherwise act on blindly: an id, an address, a status.
json_get_or_die() {
  local input="$1" filter="$2" what="$3" value
  value="$(json_get "$filter" "$input")" || value=""
  if [[ -z "$value" ]]; then
    log_error "missing $what ($filter) in: ${input[1,400]}"
    ui_die "The Hetzner API response did not contain $what. See the transcript."
  fi
  print -rn -- "$value"
}

# json_array <filter> [input] - one element per line
#
# Output is newline-separated so the caller can read it into an array with
# ${(f)…}. Values containing a newline would break that; none of the fields
# tmbox reads can contain one, and json_get is the right call for anything that
# could.
json_array() {
  local filter="$1"
  if (( $# >= 2 )); then
    print -r -- "$2" | jq -r "$filter // empty | .[]" 2>/dev/null
  else
    jq -r "$filter // empty | .[]" 2>/dev/null
  fi
}

# json_len <filter> [input]
json_len() {
  local filter="$1" out
  if (( $# >= 2 )); then
    out="$(print -r -- "$2" | jq -r "$filter // [] | length" 2>/dev/null)"
  else
    out="$(jq -r "$filter // [] | length" 2>/dev/null)"
  fi
  print -rn -- "${out:-0}"
}

# json_valid [input] - status 0 if it parses, 1 if not
#
# Normalised deliberately. jq distinguishes its failures by exit code - 4 for
# no output, 5 for a parse error - and leaking those through would make every
# caller either compare against a set of magic numbers or, more likely, get it
# subtly wrong. This is a predicate; it answers yes or no.
json_valid() {
  if (( $# >= 1 )); then
    print -r -- "$1" | jq -e . >/dev/null 2>&1 && return 0
  else
    jq -e . >/dev/null 2>&1 && return 0
  fi
  return 1
}

# json_error <input>
#
# Hetzner reports failures as {"error":{"code":…,"message":…}} on both APIs.
# Returns "code: message", or empty when the response is not an error.
json_error() {
  print -r -- "$1" \
    | jq -er '.error | select(. != null) | "\(.code): \(.message)"' 2>/dev/null
}

# json_str <value> - a JSON string literal, correctly escaped
#
# Request bodies are assembled with jq rather than with printf, so a password
# containing a quote or a backslash cannot break out of the literal and change
# the shape of the request. Hetzner's password policy requires a special
# character, so this is the ordinary case, not the edge case.
json_str() {
  jq -Rn --arg v "$1" '$v'
}

# json_obj <key> <value> [<key> <value>...] - a flat JSON object of strings
json_obj() {
  local -a pairs=("$@")
  local -a args=()
  local -i i=1
  local filter="{"
  while (( i < ${#pairs} )); do
    args+=(--arg "k$i" "${pairs[i]}" --arg "v$i" "${pairs[i+1]}")
    (( i > 1 )) && filter+=","
    filter+="(\$k$i): \$v$i"
    (( i += 2 ))
  done
  filter+="}"
  jq -n $args "$filter"
}
