#!/bin/zsh
#
# tmbox - a private Time Machine destination on Hetzner.
#
# The entry point: parse arguments, set up the interface and the transcript,
# dispatch to a command in cmd/. This file is appended last by tools/build.zsh,
# so in the distributed single file it runs after every library is defined.
#
# Options are parsed here rather than inside each command because of the rule
# that shapes the whole product: **every question tmbox asks can be answered in
# advance.** A flag, an environment variable or an --answers file all feed the
# same store (lib/answers.zsh), and --non-interactive turns a missing answer
# into a named error instead of a prompt. That is what makes the flow testable
# in a VM, scriptable for more than one Mac, and reproducible from a support
# mail.
#
# Copyright (c) 2026, Lab22 Poland Sp. z o.o.  BSD-3-Clause.

emulate -L zsh
setopt no_unset pipe_fail extended_glob

typeset -g TMBOX_VERSION="${TMBOX_VERSION:-dev}"

# --- where the sources are, when not running as the built single file --------
#
# ${0:A} resolves symlinks and relative paths, but it is meaningless when the
# script arrived on stdin - which is exactly what `curl … | zsh` does. The
# built artifact sets TMBOX_BUNDLED and needs none of this; the repository
# checkout finds its own lib/ next door.
if (( ! ${+TMBOX_BUNDLED} )); then
  typeset -g TMBOX_ROOT="${TMBOX_ROOT:-${0:A:h:h}}"
  if [[ ! -d "$TMBOX_ROOT/lib" ]]; then
    print -u2 -- "tmbox: cannot find its own lib/ directory."
    print -u2 -- "Run the built file from dist/, or set TMBOX_ROOT to the checkout."
    exit 2
  fi
  # The built file carries its version in the header; a checkout reads the same
  # VERSION file the build does, so `--version` never reports something the
  # build would disagree with.
  [[ -f "$TMBOX_ROOT/VERSION" ]] && TMBOX_VERSION="$(cat -- "$TMBOX_ROOT/VERSION")"
  local _f
  for _f in answers log ui json http state secrets sshx macos hcloud hbox preflight uplink; do
    source "$TMBOX_ROOT/lib/${_f}.zsh"
  done
  for _f in setup status doctor tunnel unlock destroy limit; do
    [[ -f "$TMBOX_ROOT/cmd/${_f}.zsh" ]] && source "$TMBOX_ROOT/cmd/${_f}.zsh"
  done
fi

# --- usage ------------------------------------------------------------------

tmbox_usage() {
  # The answer flags are rendered from their declaration in lib/answers.zsh, so
  # the help can never list a flag the parser does not accept, or omit one it
  # does. Both happened while this was a hand-written list.
  local flags="" entry
  for entry in $TMBOX_SETUP_FLAGS; do
    flags+="$(printf '        --%-18s %s\n' "${entry%%:*}" "${entry#*:}")"$'\n'
  done

  cat <<EOF
tmbox - a private Time Machine destination on Hetzner.

USAGE
    tmbox <command> [options]

COMMANDS
    setup            Create the appliance and make the first backup
    status           What exists, what it costs, when it last backed up
    doctor           Check every assertion, and say which restore paths work
    tunnel           start | stop | status - the SSH forward carrying SMB
    unlock           Send the ZFS key so the appliance can serve the share
    limit            [Mbit/s | auto | off] - cap how much upload backups take
    destroy          Tear down, in the right order, then audit against the API

GENERAL OPTIONS
    -h, --help              This text
    -V, --version           Version and build date
    -v, --verbose           Everything the transcript records, on screen too
    -q, --quiet             Errors only
        --no-color          No ANSI colour (NO_COLOR is honoured too)

UNATTENDED OPERATION
    Every question has a flag. Precedence is flag, then environment, then
    --answers file, then the prompt's own default.

    -y, --yes               Accept every confirmation
    -n, --non-interactive   Never prompt; a missing answer is an error that
                            names the flag which would have supplied it
        --answers FILE      KEY=value per line
        --show-answers      Print the answers in force, then exit
        --dry-run           Say what would be created; create nothing

SETUP ANSWERS
${flags%$'\n'}

    Any answer can also be given as TMBOX_ANSWER_<KEY> in the environment,
    e.g. TMBOX_ANSWER_CAPACITY=2TB.

EXAMPLES
    tmbox setup
    tmbox setup --capacity 2TB --region fsn1 --mac-name studio --yes
    tmbox status
    tmbox doctor

The appliance costs about EUR 17.39/month at 2 TB and belongs to you, in your
own Hetzner account. Nothing about it is hosted by us.
EOF
}

tmbox_version() {
  print -r -- "tmbox ${TMBOX_VERSION}"
  return 0
}

# --- argument parsing -------------------------------------------------------
#
# Hand-rolled rather than zparseopts, because a flag here does two things at
# once: it sets a runtime option *or* it registers an answer, and the error
# message for an unknown flag has to be able to suggest the right one. That is
# easier to read as a case statement than as a spec string.

tmbox_main() {
  local -a positional=()
  local answers_file="" show_answers=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)            tmbox_usage; return 0 ;;
      -V|--version)         tmbox_version; return 0 ;;

      -v|--verbose)         TMBOX_LOG_LEVEL=debug ;;
      -q|--quiet)           TMBOX_LOG_LEVEL=error ;;
      --no-color)           NO_COLOR=1 ;;

      # Answers ordinary confirmations wherever they appear, rather than naming
      # keys here - a list of keys goes stale the moment a new question is
      # added, and the failure mode is an unattended run that stops at a prompt
      # nobody is there to answer. ui_confirm keeps its own short list of the
      # confirmations --yes may never answer.
      -y|--yes)             TMBOX_ASSUME_YES=1 ;;
      -n|--non-interactive) TMBOX_NONINTERACTIVE=1 ;;
      --dry-run)            TMBOX_DRY_RUN=1 ;;
      --show-answers)       show_answers=1 ;;

      --answers)            answers_file="${2:-}"; shift ;;
      --answers=*)          answers_file="${1#*=}" ;;

      # doctor repairs only what is safe to repair unasked: re-pinning the
      # firewall to this Mac's address, clearing stale Samba sessions, and
      # restarting a dead tunnel. It is parsed here rather than left to
      # cmd_doctor because every flag goes through this loop first, and one
      # that does not is rejected before the command ever sees it.
      --fix)                DOCTOR_FIX=1 ;;
      # Both keys, because this flag is the deliberate act: having typed it, the
      # user should not then be stopped by a second prompt they cannot answer
      # unattended. The prompt still appears, and is still answered "yes" only
      # by this flag and never by --yes.
      --delete-storage-box) ans_set DELETE_STORAGE_BOX yes "--delete-storage-box"
                            ans_set CONFIRM_DELETE_BOX yes "--delete-storage-box" ;;

      --)                   shift; positional+=("$@"); break ;;

      # Answer-bearing flags, from the declaration in lib/answers.zsh rather
      # than from a list here. `--capacity 2TB` and TMBOX_ANSWER_CAPACITY=2TB
      # have to mean exactly the same thing, or an unattended run diverges from
      # an attended one - so both land in the same store by the same route.
      -*)
        local flag="${1#--}" value=""
        local -i has_value=0
        if [[ "$flag" == *=* ]]; then
          value="${flag#*=}"; flag="${flag%%=*}"; has_value=1
        fi
        if (( ${${(f)"$(ans_flag_names)"}[(Ie)$flag]} )); then
          if (( has_value )); then
            ans_set "$flag" "$value" "--$flag"
          else
            ans_set "$flag" "${2:-}" "--$flag"; shift
          fi
        else
          print -u2 -- "tmbox: unknown option: $1"
          print -u2 -- "Try 'tmbox --help'."
          return 2
        fi
        ;;
      *)                    positional+=("$1") ;;
    esac
    shift
  done

  # Environment first, then the file - both below the flags already registered
  # above, because ans_set never overwrites and the flags got there first.
  ans_from_env
  if [[ -n "$answers_file" ]]; then
    ans_from_file "$answers_file" \
      || { print -u2 -- "tmbox: cannot read answers file: $answers_file"; return 2 }
  fi

  # The interface has to exist before anything can report a problem, and the
  # transcript before anything can fail interestingly.
  ui_init --no-tty-ok || return 1
  state_init
  log_open "${TMBOX_STATE_DIR}/tmbox.log"
  preflight_report

  if (( show_answers )); then
    ans_dump
    return 0
  fi

  local command="${positional[1]:-}"
  [[ -n "$command" ]] || { tmbox_usage; return 0 }
  shift_args=("${positional[@]:1}")

  # Only `setup` needs a terminal it can actually prompt on; the rest are
  # reporting commands that must work from a cron job or a LaunchAgent.
  case "$command" in
    setup)
      ui_init || return 1
      log_info "command: setup"
      cmd_setup "${shift_args[@]}"
      ;;
    status)  cmd_status  "${shift_args[@]}" ;;
    doctor)  cmd_doctor  "${shift_args[@]}" ;;
    tunnel)  cmd_tunnel  "${shift_args[@]}" ;;
    unlock)  cmd_unlock  "${shift_args[@]}" ;;
    limit)   cmd_limit   "${shift_args[@]}" ;;
    destroy)
      ui_init || return 1
      cmd_destroy "${shift_args[@]}"
      ;;
    help)    tmbox_usage ;;
    version) tmbox_version ;;
    *)
      print -u2 -- "tmbox: unknown command: $command"
      print -u2 -- "Try 'tmbox --help'."
      return 2
      ;;
  esac
}

typeset -ga shift_args=()
typeset -gi TMBOX_DRY_RUN="${TMBOX_DRY_RUN:-0}"

# The scratch directory has to go even when a command exits early or the user
# interrupts, because it may hold a request body containing a credential.
trap 'http_cleanup 2>/dev/null; ui_spin_stop bad "interrupted" 2>/dev/null; exit 130' INT TERM
trap 'http_cleanup 2>/dev/null' EXIT

tmbox_main "$@"
