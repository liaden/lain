#!/usr/bin/env bash
# tpm-style entry point: `run-shell .../plugin/tmux/lain.tmux` from tmux.conf
# (or `set -g @plugin` once this ships as its own repo). Two jobs:
#
# * interpolate the `#{lain_status}` placeholder in status-left/status-right
#   into a `#(scripts/lain-status '#{pane_current_path}')` job, so the HUD
#   follows whichever project the active pane is in;
# * bind prefix keys for the /btw popup and /fork window. Each binding is
#   wrapped in if-shell on the command's own binary, so a machine without
#   `lain` on tmux's PATH degrades to a display-message -- never a bound
#   error. (The --btw/--fork flags land with T3; this file only owns the
#   command lines.)
#
# Every default is an option (`set -g @lain_... "..."` BEFORE the run-shell
# line): @lain_btw_key, @lain_fork_key, @lain_btw_command, @lain_fork_command.
set -eu

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLACEHOLDER='#{lain_status}'
# tmux format-expands the #() job body, then hands it to /bin/sh -c WITHOUT
# re-quoting -- so the quoting must come from tmux itself. #{q:...} is
# tmux's shell-quote modifier and it must sit UNQUOTED in the job: a
# hand-written '#{pane_current_path}' slot is an injection surface, because
# a pane cwd containing a single quote closes the slot and the rest of the
# path executes (proved live by the T6 panel's probe_real_tmux2.sh; pinned
# by spec/plugin/tmux_plugin_spec.rb's hostile-cwd regression). The script
# path is single-quoted for the same shell: an install path with spaces
# must stay one argument.
STATUS_JOB="#('$CURRENT_DIR/scripts/lain-status' #{q:pane_current_path})"

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
