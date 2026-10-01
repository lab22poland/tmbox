#!/bin/zsh
#
# lib/json.zsh - extraction and construction.
#
# The behaviour under test that matters most is what happens when a value is
# missing. An API response that silently reads as "" produces a confident and
# completely wrong outcome further down: a firewall rule with no address, a
# server created in the wrong location, an ssh to nowhere.

source "$TMBOX_ROOT/lib/json.zsh"

typeset -g SAMPLE='{
  "server": {"id": 42, "name": "tmbox-studio", "public_net": {"ipv4": {"ip": "1.2.3.4"}}},
  "nulls":  {"absent": null},
  "list":   [{"n": "a"}, {"n": "b"}, {"n": "c"}],
  "empty":  [],
  "odd key.with.dots": "kept",
  "quote":  "he said \"hi\"",
  "utf8":   "łódź ✓"
}'

test_get_extracts_scalars() {
  assert_eq "42"          "$(json_get '.server.id' "$SAMPLE")"
  assert_eq "tmbox-studio" "$(json_get '.server.name' "$SAMPLE")"
  assert_eq "1.2.3.4"     "$(json_get '.server.public_net.ipv4.ip' "$SAMPLE")"
}

test_get_survives_awkward_content() {
  # Every one of these is a thing plutil's keypath syntax could not do, which is
  # why jq is the dependency rather than plutil.
  assert_eq 'he said "hi"' "$(json_get '.quote' "$SAMPLE")"
  assert_eq 'łódź ✓'       "$(json_get '.utf8' "$SAMPLE")"
  assert_eq 'kept'         "$(json_get '."odd key.with.dots"' "$SAMPLE")"
}

test_get_returns_empty_for_missing_and_null() {
  # Callers want "absent", not the four characters n-u-l-l.
  assert_empty "$(json_get '.nope' "$SAMPLE")"          "a missing key"
  assert_empty "$(json_get '.nulls.absent' "$SAMPLE")"  "an explicit null"
  assert_empty "$(json_get '.list[9].n' "$SAMPLE")"     "past the end of an array"
}

test_get_reads_stdin() {
  assert_eq "42" "$(print -r -- "$SAMPLE" | json_get '.server.id')"
}

test_get_on_malformed_input_is_empty_not_garbage() {
  assert_empty "$(json_get '.a' 'this is not json')"
  assert_empty "$(json_get '.a' '')"
}

test_array_is_newline_separated() {
  local -a got=( ${(f)"$(json_array '[.list[].n]' "$SAMPLE")"} )
  assert_eq 3   ${#got}    "element count"
  assert_eq "a" "${got[1]}"
  assert_eq "c" "${got[3]}"
  assert_empty "$(json_array '.empty' "$SAMPLE")" "an empty array yields nothing"
}

test_len() {
  assert_eq 3 "$(json_len '.list' "$SAMPLE")"
  assert_eq 0 "$(json_len '.empty' "$SAMPLE")"
  assert_eq 0 "$(json_len '.nope' "$SAMPLE")"  "a missing key counts as zero"
}

test_valid() {
  assert_status 0 json_valid "$SAMPLE"
  assert_status 0 json_valid '{}'
  assert_status 1 json_valid 'not json'
  assert_status 1 json_valid ''
}

test_error_reads_hetzner_failures() {
  local err='{"error":{"code":"unauthorized","message":"the token you have provided is invalid"}}'
  assert_eq "unauthorized: the token you have provided is invalid" "$(json_error "$err")"
  assert_empty "$(json_error "$SAMPLE")" "a successful response is not an error"
}

test_str_escapes_so_a_password_cannot_break_out() {
  # Hetzner's password policy requires a special character, so a quote or a
  # backslash in a generated credential is ordinary rather than exotic. Built
  # with jq rather than printf precisely so it cannot change the shape of the
  # request it lands in.
  assert_eq '"pa\"ss"'     "$(json_str 'pa"ss')"
  assert_eq '"back\\slash"' "$(json_str 'back\slash')"
  assert_eq '"line\nbreak"' "$(json_str $'line\nbreak')"
  # And the result must still parse as JSON.
  assert_status 0 json_valid "{\"p\": $(json_str 'pa"ss\and\\more')}"
}

test_obj_builds_a_flat_object() {
  local out; out="$(json_obj name "tmbox-studio" location "fsn1")"
  assert_status 0 json_valid "$out"
  assert_eq "tmbox-studio" "$(json_get '.name' "$out")"
  assert_eq "fsn1"         "$(json_get '.location' "$out")"
}

test_obj_escapes_its_values() {
  local out; out="$(json_obj password 'pa"ss\word' note $'two\nlines')"
  assert_status 0 json_valid "$out"
  assert_eq 'pa"ss\word'  "$(json_get '.password' "$out")"
  assert_eq $'two\nlines' "$(json_get '.note' "$out")"
}
