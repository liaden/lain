#!/usr/bin/env bash
# tpm-style entry point AND the plugin's per-pane resolver. Called three ways:
#
#   lain.tmux                    install: what `run-shell` from tmux.conf runs
#   lain.tmux state-path [DIR]   print the state file DIR's session publishes
#   lain.tmux status    [DIR]    resolve DIR, then render the HUD from it
#
# Install mode does two jobs:
#
# * interpolate the `#{lain_status}` placeholder in status-left/status-right
#   into a `#(lain.tmux status '#{pane_current_path}')` job, so the HUD
#   follows whichever project the active pane is in;
# * bind prefix keys for the /btw popup and /fork window. Each binding is
#   wrapped in if-shell on the command's own binary, so a machine without
#   `lain` on tmux's PATH degrades to a display-message -- never a bound
#   error. (The --btw/--fork flags land with T3; this file only owns the
#   command lines.)
#
# Every default is an option (`set -g @lain_... "..."` BEFORE the run-shell
# line): @lain_btw_key, @lain_fork_key, @lain_btw_command, @lain_fork_command.
#
# WHY THE JOB CALLS THIS FILE AND NOT scripts/lain-status DIRECTLY (T9/F50).
# The feed moved out of the project into
# `$XDG_STATE_HOME/lain/status/<sha256(realpath(dir))[0,12]>/state.json`, so
# something has to turn a pane's directory into a file name. It cannot be
# `scripts/lain-status`: that one is POSIX `sh` whose contract is to never
# blank and never error with `jq` its only optional dependency, and a digest
# binary is not something POSIX promises. And it cannot happen when this file
# is SOURCED: tmux expands `#{pane_current_path}` per pane at RENDER time, so
# a path computed here at install time would describe one directory and be
# confidently wrong in every pane sitting anywhere else -- worse than blank,
# because a wrong number reads as a real one. So the job re-enters this file,
# which is bash and may compute, once per pane per status-interval.
#
# This makes the recipe's THIRD spelling (Ruby's Lain::Paths#project_hash,
# Lua's plugin/nvim, and here). spec/plugin/tmux_plugin_spec.rb cross-pins
# `state-path` against Ruby's locator byte for byte, because the failure mode
# of drift is a permanently blank status bar, not an error anyone would see.
set -eu

# `cd` resolves a RELATIVE operand against $CDPATH when one is exported, AND
# echoes where it landed -- which would make `pwd -P` below two lines and the
# project hash one of neither directory. Ruby's File.expand_path always
# resolves against the cwd; unsetting here is how both `cd`s in this file say
# the same. One place, because a missed `CDPATH= ` prefix fails silently.
unset CDPATH

# `dirname` is deliberately NOT called. This line runs on the RENDER path,
# above every degrade guard, so a PATH without coreutils exited 1 with a BLANK
# segment -- the one failure the renderer exists to prevent, and one the old
# job (which called scripts/lain-status directly and looked nothing up) never
# had. `${x%/*}` is the bash-native spelling; an invocation found through PATH
# carries no directory part, and `.` is what dirname would have answered.
case "${BASH_SOURCE[0]}" in
  */*) SELF_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) SELF_DIR="." ;;
esac
CURRENT_DIR="$(cd -- "$SELF_DIR" && pwd)"
STATUS_SCRIPT="$CURRENT_DIR/scripts/lain-status"

# `$XDG_STATE_HOME/lain`, or `$HOME/.local/state/lain`. The XDG spec says a
# non-absolute value is invalid and MUST be ignored, which is exactly
# Lain::Paths#present's rule -- so a relative setting falls back rather than
# resolving against the pane's cwd.
#
# `$HOME` is deliberately NOT held to that rule here, and the asymmetry is the
# point. Lain::Paths#home RAISES NonAbsoluteHome on a non-absolute $HOME
# because every XDG accessor falls back to it, so a relative one puts the state
# path back INSIDE the user's repository -- F50, the defect this whole card
# exists to undo. But that is a hazard of WRITING the path. A renderer only
# reads: it composes, finds no file, and says "no state yet". So the side that
# writes refuses, and the side that reads degrades.
#
# `${base%/}` sits on BOTH bases because Ruby composes with File.join, which
# collapses one separator at the join. `$HOME=/` is the case that makes it
# matter rather than a curiosity: it is what root gets in a container,
# NonAbsoluteHome's docstring accepts it by name, and `//.local/...` has an
# implementation-defined meaning in POSIX that `/.local/...` does not.
state_home() {
  local home
  case "${XDG_STATE_HOME:-}" in
    /*) printf '%s/lain' "${XDG_STATE_HOME%/}" ;;
    *) home="${HOME:-}"; printf '%s/.local/state/lain' "${home%/}" ;;
  esac
}

# sha256 of the REALPATH, first twelve hex characters -- Lain::Paths#project_hash.
# `cd -- "$dir" && pwd -P` is the realpath, and it is a shell builtin: no
# `realpath`/`readlink -f` binary is involved, and a directory that does not
# exist fails here rather than hashing a name for a file nobody will write.
# The digest is the one real dependency, tried three ways; a box with none of
# them makes this return nonzero, and the caller then supplies NO path at all.
project_hash() {
  local resolved digest
  resolved="$(cd -- "$1" 2>/dev/null && pwd -P)" || return 1
  [ -n "$resolved" ] || return 1
  # printf without a newline: Ruby hashes the string, not a line.
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$resolved" | sha256sum)"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$resolved" | shasum -a 256)"
  elif command -v openssl >/dev/null 2>&1; then
    digest="$(printf '%s' "$resolved" | openssl dgst -sha256 -r)"
  else
    return 1
  fi
  # The twin of the `resolved` guard above, and it needs to be explicit:
  # `set -e` does NOT cover the assignments above, because errexit is
  # suppressed inside `$( )` whenever the caller tests with `|| return 1`. A
  # tool that is on PATH but yields nothing -- `shasum` without perl, a
  # FIPS-restricted `openssl` -- otherwise composed `.../status//state.json`
  # and returned 0, naming no file, confidently.
  digest="${digest%% *}"
  [ -n "$digest" ] || return 1
  printf '%s' "${digest:0:12}"
}

# ProjectDir::STATE_KIND is `status`, the sibling of `sessions` and `epics`.
state_path() {
  local hash
  hash="$(project_hash "$1")" || return 1
  printf '%s/status/%s/state.json\n' "$(state_home)" "$hash"
}

# An unresolvable directory hands the renderer an EMPTY argument rather than a
# guess, and the renderer says "lain: no state yet" -- true, and never blank.
render_status() {
  local path
  path="$(state_path "$1")" || path=""
  exec "$STATUS_SCRIPT" "$path"
}

# The empty case falls through to install mode, which is the whole rest of
# this file; `status` execs and never comes back.
case "${1:-}" in
  state-path)
    state_path "${2:-$PWD}" || exit 1
    exit 0
    ;;
  status)
    render_status "${2:-$PWD}"
    ;;
  "")
    ;;
  *)
    printf 'lain.tmux: unknown subcommand %s\n' "$1" >&2
    exit 64
    ;;
esac

PLACEHOLDER='#{lain_status}'
# tmux format-expands the #() job body, then hands it to /bin/sh -c WITHOUT
# re-quoting -- so the quoting must come from tmux itself. #{q:...} is
# tmux's shell-quote modifier and it must sit UNQUOTED in the job: a
# hand-written '#{pane_current_path}' slot is an injection surface, because
# a pane cwd containing a single quote closes the slot and the rest of the
# path executes (proved live by the T6 panel's probe_real_tmux2.sh; pinned
# by spec/plugin/tmux_plugin_spec.rb's hostile-cwd regression). The plugin
# path is single-quoted for the same shell: an install path with spaces
# must stay one argument.
STATUS_JOB="#('$CURRENT_DIR/lain.tmux' status #{q:pane_current_path})"

lain_option() {
  local value
  value="$(tmux show-option -gqv "$1")"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

interpolate() {
  local value
  value="$(tmux show-option -gqv "$1")"
  case "$value" in
    *"$PLACEHOLDER"*) tmux set-option -g "$1" "${value//"$PLACEHOLDER"/$STATUS_JOB}" ;;
  esac
}

guarded_bind() {
  local key="$1" action="$2" command="$3" binary
  binary="${command%% *}"
  tmux bind-key "$key" if-shell "command -v $binary >/dev/null" \
    "$action \"$command\"" \
    "display-message \"lain: $binary not found on PATH\""
}

interpolate status-left
interpolate status-right

guarded_bind "$(lain_option "@lain_btw_key" "b")" "display-popup -E" \
  "$(lain_option "@lain_btw_command" "lain chat --btw")"
guarded_bind "$(lain_option "@lain_fork_key" "F")" "new-window" \
  "$(lain_option "@lain_fork_command" "lain chat --fork")"
