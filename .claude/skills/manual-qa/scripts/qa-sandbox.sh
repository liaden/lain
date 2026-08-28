#!/usr/bin/env bash
# Build an isolated manual-QA sandbox and its driver helpers.
#
#   bash .claude/skills/manual-qa/scripts/qa-sandbox.sh [round-tag] [lain-repo]
#
# Idempotent per tag: re-running with the same tag REUSES the sandbox (it is evidence).
# Pass a fresh tag for a fresh round.
set -euo pipefail

TAG="${1:-$(date +%Y-%m-%d)}"
REPO="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
QA="$HOME/tmp/lain-qa-$TAG"
SOCK="lain-qa-$TAG"

[ -x "$REPO/exe/lain" ] || { echo "not a lain repo: $REPO" >&2; exit 1; }

mkdir -p "$QA"/{xdg/config,xdg/state,xdg/cache,xdg/runtime,tmp,shim,records,project}
chmod 700 "$QA/xdg/runtime"

# --- the environment every helper sources ------------------------------------
cat > "$QA/env.sh" <<EOF
export QA="$QA"
export LAIN_REPO="$REPO"
export QA_SOCK="$SOCK"
eval "\$(mise env -s bash ruby@4.0.6)"
export XDG_CONFIG_HOME="\$QA/xdg/config"
export XDG_STATE_HOME="\$QA/xdg/state"
export XDG_CACHE_HOME="\$QA/xdg/cache"
export XDG_RUNTIME_DIR="\$QA/xdg/runtime"
export TMPDIR="\$QA/tmp"
export LAIN_NUM_BATCH=2048
export PATH="\$QA/shim:/mnt/nvme/opt/ollama-0.32.12/bin:\$PATH"
EOF

# --- the shim: PANE_ENV forwards LAIN_* only, so carry the toolchain in here --
cat > "$QA/shim/lain" <<EOF
#!/usr/bin/env bash
eval "\$(mise env -s bash ruby@4.0.6)"
exec "$REPO/exe/lain" "\$@"
EOF
chmod +x "$QA/shim/lain"

# --- which pane is the chat? which is the editor? ----------------------------
# Sourced by BOTH drive.sh and peek.sh so aiming a send and aiming a read cannot
# drift apart -- they are the same question asked twice.
cat > "$QA/panes.sh" <<'EOF'
# shellcheck shell=bash   # sourced, never run, so it carries no shebang
# Resolve panes by what is RUNNING in them, process tree and all.
#
# `#{pane_current_command}` answers "what is this pane's FOREGROUND process",
# which is not the same question. The cockpit's own launch line ends in `exec`,
# so its chat pane genuinely reads `ruby` and its editor pane reads `nvim` --
# but a chat that is NOT its pane's foreground process, one under a shell
# wrapper, reads `zsh`, contributed no candidate at all, and the ambiguity that
# should have refused the send looked like a clean single match. Measured live:
# a prompt meant for one chat landed in the cockpit, past a refusal that only
# ever compared foreground commands and so read as far stronger than it was.
#
# What keeps this walk off the shell that ASKS the question is that it is ROOTED
# at each pane's own pid -- a helper's shell is not a descendant of any pane on
# this server, so it is never visited at all. That rooting is the load-bearing
# part, not the choice of field: comparing /proc/<pid>/comm rather than matching
# a pattern over argv is a second, smaller guard, and a driver that runs INSIDE
# a pane on this socket would be found by a comm comparison alone. Neither is a
# bare `pgrep -f`, which has twice killed the command issuing it, mid-heredoc.
#
# For the `ruby` query ONLY, a wrapped descendant additionally has to look like
# lain, because a `ruby` process is not a chat: this sandbox ships three ruby
# listeners of its own -- counter.rb, pathcount.rb, proxy.rb -- that scenarios
# start with `&`, and one of them backgrounded in a pane on this socket would
# otherwise make the whole server ambiguous and disable driving for the rest of
# the round. Matching the mere STRING `lain` does not do it: this sandbox lives
# under `~/tmp/lain-qa-<tag>`, so `ruby $QA/counter.rb` mentions `lain` in its
# path and stays a phantom candidate. What is matched is an argv WORD that is
# `lain` or ends in `/lain` -- which is a good proxy for the exe and not a proof
# of it (`ruby -e '...' lain` would pass), and it is deliberately not narrowed
# to argv[1], because `bundle exec lain` is a legitimate spelling.
#
# The `nvim` query gets NO such test, and that scoping is load-bearing: the
# cockpit editor's argv carries `plugin/nvim` and a socket path but no `lain`
# word at all, so requiring one made the editor's tree branch dead and quietly
# reverted `peek.sh <n> nvim` to foreground-command matching -- this card's own
# defect, reintroduced on the read side, and invisible because `lain up` always
# execs nvim into the foreground. There is no phantom to exclude there: nothing
# else on the round's server is nvim.
#
# The FOREGROUND branch of both queries stays unconditional, so the degraded
# launch a chat can have (a `ruby` pane with no `lain chat` in its argv at all)
# still resolves.

qa_panes_require_sock() {
  : "${QA_SOCK:?refusing: QA_SOCK is unset -- an empty -L targets the DEFAULT tmux server}"
}

# Is this pid the lain exe, however its path was spelled?
qa_is_lain() {
  # `-z` makes the NUL that separates argv words the LINE terminator, so `^...$`
  # anchors to one whole argv word -- which is the difference between matching
  # the exe and matching any path that merely contains the four letters.
  command grep -qzaE '^(.*/)?lain$' "/proc/$1/cmdline" 2>/dev/null
}

# Only the interpreter query has to prove itself; see the header.
qa_descendant_qualifies() {
  [ "$2" != ruby ] || qa_is_lain "$1"
}

# Is a matching <command-name> anywhere in the process tree rooted at <pid>?
qa_tree_has() {
  local frontier=("$1") kids=() nxt=() pid comm
  while [ "${#frontier[@]}" -gt 0 ]; do
    nxt=()
    for pid in "${frontier[@]}"; do
      # The redirections apply left to right, so `2>` has to be installed
      # BEFORE the read: a pane that exits mid-walk otherwise puts a "No such
      # file or directory" on the driver's own stderr, and unexplained stderr
      # in a QA round gets read as a finding.
      comm=""
      read -r comm 2>/dev/null < "/proc/$pid/comm" || comm=""
      [ "$comm" = "$2" ] && qa_descendant_qualifies "$pid" "$2" && return 0
      mapfile -t kids < <(pgrep -P "$pid" 2>/dev/null)
      nxt+=("${kids[@]}")
    done
    frontier=("${nxt[@]}")
  done
  return 1
}

# Every pane on THIS round's server running <command-name>, one pane id a line.
# The foreground comparison is EXACT where the old resolver said `grep -w`, so a
# pane whose command reads `ruby-lsp` or `ruby-4.0.6` no longer matches on that
# branch. Narrower on purpose, and it fails loud -- a refusal, or "no chat pane"
# -- rather than aiming a send somewhere plausible.
qa_panes_running() {
  qa_panes_require_sock
  local id pid cmd
  while IFS=' ' read -r id pid cmd; do
    if [ "$cmd" = "$1" ] || qa_tree_has "$pid" "$1"; then printf '%s\n' "$id"; fi
  done < <(tmux -L "$QA_SOCK" list-panes -a -F '#{pane_id} #{pane_pid} #{pane_current_command}')
}

# What a refusal prints: a bare pane id does not say which one to pin, and the
# whole point of refusing is that the operator has to choose. `dead` is in there
# because `lain up` deliberately KEEPS a failed chat pane, so a refusal can
# otherwise ask an operator to choose between a live chat and a corpse with
# nothing on screen telling them apart.
qa_pane_label() {
  qa_panes_require_sock
  tmux -L "$QA_SOCK" display-message -p -t "$1" \
    '#{pane_id} cmd=#{pane_current_command} dead=#{pane_dead} pid=#{pane_pid} win=#{window_name}'
}

# The remedy a refusal offers, and it is deliberately NOT `export`: peek.sh
# reads LAIN_QA_PANE before it decides whether it was asked for the chat or the
# editor, so an exported pin makes `peek.sh <n> nvim` read the pinned CHAT and
# exit 0 as if it had read the editor. Per invocation, the pin dies with the
# call it aimed.
qa_pane_pin_hint() {
  echo "  aim ONE call: LAIN_QA_PANE=<pane id> $1 ...  (do not export it -- an exported pin also re-aims peek.sh's nvim read)"
}
EOF

# --- send ONE prompt, then wait for the PINNED journal to go quiet -----------
# The journal is PINNED via $LAIN_QA_JOURNAL and never resolved with `ls -t`:
# every non-interactive probe writes a journal NEWER than the cockpit's, so an
# `ls -t` driver silently polls a file that will never move again, returns after
# one quiet window having waited for nothing, and reads the cockpit BEFORE the
# render lands. Two rounds produced a false "frozen buffer" finding that way.
cat > "$QA/drive.sh" <<'EOF'
#!/usr/bin/env bash
# drive.sh "<text>" [quiet_seconds] [max_seconds]
#   requires $LAIN_QA_JOURNAL -- pin it to the COCKPIT's journal, e.g.
#   export LAIN_QA_JOURNAL="$XDG_STATE_HOME/lain/sessions/<hash>/<file>.ndjson"
#   optionally pin the pane too, per invocation and NOT exported:
#   LAIN_QA_PANE="%3" drive.sh '...' -- an exported pin also re-aims peek.sh's
#   nvim read. Same reason as pinning the journal, see below.
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/panes.sh"
# Called HERE and not from inside the resolver: every resolver call happens in a
# `$( )` or a process substitution, where `${QA_SOCK:?}` kills only the subshell
# and the caller carries on to report "no chat pane on tmux -L " at exit 1.
qa_panes_require_sock
TXT="$1"; QUIET="${2:-60}"; MAX="${3:-900}"
J="${LAIN_QA_JOURNAL:?LAIN_QA_JOURNAL is not pinned -- see method.md, 'Pin the journal'}"
[ -f "$J" ] || { echo "pinned journal does not exist: $J" >&2; exit 1; }

# Pin the pane the same way the journal above is pinned, or refuse rather than
# guess: several agents share this box, and a leftover probe session with its
# own chat pane makes more than one candidate. Picking the first one (`head -1`)
# used to send a probe's prompt into the cockpit and add a turn to the subject
# session with no error at all. Candidates come from panes.sh, which sees a chat
# running under a shell wrapper as well as one that is its pane's foreground
# process: matching the foreground command alone missed exactly that pane, so an
# ambiguous send read as unambiguous and went to the wrong chat with the refusal
# below never firing at all. A wrapped candidate has to be a lain process, not
# merely a `ruby` one, or this sandbox's own backgrounded listeners would make
# every pane ambiguous and refuse every send for the rest of the round.
if [ -n "${LAIN_QA_PANE:-}" ]; then
  # A pin is only as good as the pane behind it -- `tmux send-keys` into a dead
  # pane writes "can't find pane" to stderr and returns success, so an unchecked
  # pin would make the quiet-wait loop run out against a journal that never
  # moved and print the ordinary success summary at exit 0: the exact shape of
  # a delivered send. A stale LAIN_QA_PANE surviving from an earlier sandbox in
  # a shared shell is the same class of leftover state this whole card exists
  # to stop guessing past.
  mapfile -t LIVE_PANES < <(tmux -L "$QA_SOCK" list-panes -a -F '#{pane_id}')
  printf '%s\n' "${LIVE_PANES[@]}" | command grep -qxF "$LAIN_QA_PANE" \
    || { echo "pinned pane does not exist: $LAIN_QA_PANE on tmux -L $QA_SOCK" >&2; exit 1; }
  CHAT="$LAIN_QA_PANE"
else
  mapfile -t CHAT_CANDIDATES < <(qa_panes_running ruby)
  case "${#CHAT_CANDIDATES[@]}" in
    0) echo "no chat pane on tmux -L $QA_SOCK" >&2; exit 1 ;;
    1) CHAT="${CHAT_CANDIDATES[0]}" ;;
    *) echo "REFUSING to send: ${#CHAT_CANDIDATES[@]} chat panes on tmux -L $QA_SOCK -- ambiguous, not guessing:" >&2
       for c in "${CHAT_CANDIDATES[@]}"; do echo "  $(qa_pane_label "$c")" >&2; done
       qa_pane_pin_hint "$0" >&2
       exit 2
       ;;
  esac
fi

# NEVER type while an approval is parked: at a `[y/N]` prompt the Enter below IS
# the answer, and the default is DENY. One round denied a call by accident this
# way and spent three turns watching the model recover from it.
#
# Refuse rather than guess when resolving the nvim socket -- several agents
# share this box, and `head -1` on an ambiguous glob silently picks a
# STRANGER's cockpit if XDG_RUNTIME_DIR ever falls back to the real per-user
# runtime dir. Only run the check when this shell's own env.sh sourcing above
# proves the sandbox is active; a mismatch here means something upstream
# already failed (see $LAIN_QA_JOURNAL's own check, above) rather than a
# reason to fall back to a wider glob.
if [ "$XDG_RUNTIME_DIR" = "$QA/xdg/runtime" ]; then
  mapfile -t NVSOCKS < <(find "$XDG_RUNTIME_DIR" -name 'nvim-*.sock' -type s 2>/dev/null)
  case "${#NVSOCKS[@]}" in
    0) : ;;  # no nvim attached (--no-nvim run) -- nothing to check
    1) if ! nvim --server "${NVSOCKS[0]}" --remote-expr "join(getbufline(bufnr('lain://approval'),1,2),' ')" 2>/dev/null \
            | command grep -q 'no approvals pending'; then
         echo "REFUSING to send: an approval is pending -- answer it first" >&2; exit 2
       fi
       ;;
    *) echo "REFUSING to send: ${#NVSOCKS[@]} nvim sockets under $XDG_RUNTIME_DIR -- ambiguous, not guessing:" >&2
       printf '  %s\n' "${NVSOCKS[@]}" >&2
       exit 2
       ;;
  esac
fi

before=$(wc -l < "$J")
tmux -L "$QA_SOCK" send-keys -t "$CHAT" -l "$TXT"; sleep 0.4
tmux -L "$QA_SOCK" send-keys -t "$CHAT" Enter
start=$SECONDS; last=-1; still=0
while :; do
  n=$(wc -l < "$J")
  if [ "$n" = "$last" ]; then still=$((still+3)); else still=0; last=$n; fi
  [ $still -ge "$QUIET" ] && break
  [ $((SECONDS-start)) -ge "$MAX" ] && { echo "[TIMEOUT ${MAX}s]"; break; }
  sleep 3
done
echo "[journal $before -> $(wc -l < "$J") lines in $((SECONDS-start))s, pane $CHAT]"
echo "$J"
EOF

# --- read a pane -------------------------------------------------------------
cat > "$QA/peek.sh" <<'EOF'
#!/usr/bin/env bash
# peek.sh [lines] [chat|nvim] [attrs]
# attrs (any non-empty 3rd arg) captures with -e -- tmux's plain -p strips SGR
# colour/attribute escapes on the way out, so a check phrased "is this coloured"
# needs -e instead, never -p. See method.md's "What a text read cannot verify"
# for the recipe this wraps and a real measurement. -e output is for a human or
# a decoder, not for grep -- it is unusable as plain text by design.
#   optionally pin the pane, per invocation and NOT exported:
#   LAIN_QA_PANE="%3" peek.sh 20 -- an exported pin is read before the chat/nvim
#   choice below, so it re-aims `peek.sh <n> nvim` at the pinned pane. Same
#   escape hatch as drive.sh, and for the same reason: see the refusal below.
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/panes.sh"
qa_panes_require_sock   # abort HERE; inside the resolver it would only kill a subshell
WHICH="${2:-chat}"; PAT=ruby; [ "$WHICH" = nvim ] && PAT=nvim
if [ -n "${LAIN_QA_PANE:-}" ]; then
  # Same validation as drive.sh, same reason: capture-pane on a dead pane
  # writes "can't find pane" to stderr and returns success with EMPTY stdout,
  # which is indistinguishable from a pane that exists and is genuinely blank.
  mapfile -t LIVE_PANES < <(tmux -L "$QA_SOCK" list-panes -a -F '#{pane_id}')
  printf '%s\n' "${LIVE_PANES[@]}" | command grep -qxF "$LAIN_QA_PANE" \
    || { echo "pinned pane does not exist: $LAIN_QA_PANE on tmux -L $QA_SOCK" >&2; exit 1; }
  P="$LAIN_QA_PANE"
else
  # Candidates come from panes.sh, which counts a chat or an editor running
  # under a shell wrapper too -- a pane's foreground command alone misses one,
  # and a read aimed at the surviving pane answers about the wrong session
  # without ever looking wrong.
  mapfile -t CANDIDATES < <(qa_panes_running "$PAT")
  case "${#CANDIDATES[@]}" in
    0) echo "no $WHICH pane on tmux -L $QA_SOCK" >&2; exit 1 ;;
    1) P="${CANDIDATES[0]}" ;;
    *) echo "REFUSING to read: ${#CANDIDATES[@]} $WHICH panes on tmux -L $QA_SOCK -- ambiguous, not guessing:" >&2
       for c in "${CANDIDATES[@]}"; do echo "  $(qa_pane_label "$c")" >&2; done
       qa_pane_pin_hint "$0" >&2
       exit 2
       ;;
  esac
fi
FLAGS=(-p); [ -n "${3:-}" ] && FLAGS=(-e -p)
tmux -L "$QA_SOCK" capture-pane "${FLAGS[@]}" -t "$P" | command grep -v '^$' | tail -"${1:-12}"
EOF

# --- nvim over RPC: the reliable way to drive the editor ---------------------
cat > "$QA/nv.sh" <<'EOF'
#!/usr/bin/env bash
# nv.sh expr  '<vim expression>'      -- evaluate and print
# nv.sh send  '<keys>'                -- send keys/commands
# nv.sh bufs                          -- every lain:// buffer with its linecount
# nv.sh tabs                          -- tab -> buffer map
# nv.sh msgs                          -- :messages (where modal refusals survive)
# nv.sh buf   lain://timeline [n]     -- first n lines of a buffer
# nv.sh fold  <lnum>                  -- level/closed/closedend of the CURRENT window's fold at lnum;
#                                         a text read (bufs/buf above) cannot see this -- fold state is
#                                         a window rendering decision, not buffer content. Navigate to
#                                         the right tab/window first (send ':tabnext N<CR>'), same as
#                                         every other gesture in this method -- verify with `expr bufname()`.
. "$(dirname "$0")/env.sh"

# Refuse rather than guess: several agents share this box, and this script
# must never attach to a socket it did not create. If XDG_RUNTIME_DIR ever
# falls back to the real per-user runtime dir -- env.sh not sourced, this
# file run from outside the sandbox, a copy-pasted recipe -- the glob below
# would match every OTHER agent's nvim on the machine, and `send` can TYPE
# into a stranger's editor. Verified 2026-08-19: a reviewer following this
# file's own recipe attached to a different agent's live cockpit this way.
[ "$XDG_RUNTIME_DIR" = "$QA/xdg/runtime" ] || {
  echo "refusing: this sandbox is not active in this shell (XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}, expected $QA/xdg/runtime) -- source $QA/env.sh first" >&2
  exit 1
}
mapfile -t NVSOCKS < <(find "$XDG_RUNTIME_DIR" -name 'nvim-*.sock' -type s)
case "${#NVSOCKS[@]}" in
  0) echo "no nvim socket under $XDG_RUNTIME_DIR" >&2; exit 1 ;;
  1) S="${NVSOCKS[0]}" ;;
  *) echo "refusing: ${#NVSOCKS[@]} nvim sockets under $XDG_RUNTIME_DIR -- ambiguous, not guessing:" >&2
     printf '  %s\n' "${NVSOCKS[@]}" >&2
     exit 1 ;;
esac
# --remote-expr writes the evaluated result with no terminator at all, so two
# back-to-back reads run together on whatever they are captured into -- round 15
# read `tab2=4` immediately followed by a bare `4` as `tab2=44` and briefly
# believed in a 44-window review tab, a finding that had to be withdrawn.
# Capturing into a variable and printing it back with printf adds exactly one
# newline at the end and touches nothing else -- any newlines already embedded
# in a multi-line value (a buffer read) survive as they were. The exception is
# `expr` itself: $(...) trims ALL trailing newlines a driver-supplied expression
# may genuinely return, not just the one nvim omits, so a value ending in several
# blank lines reads as only one fewer than it should.
# `rc` is captured on the line right after the assignment, before printf can
# overwrite $? with its own (always-zero) status -- otherwise a dead server or a
# bad expression, which real nvim reports with a non-zero exit and empty stdout,
# would come back through this wrapper looking like a successful empty read.
remote_expr() {
  local out rc
  out=$(nvim --server "$S" --remote-expr "$1")
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}
case "${1:-}" in
  expr) remote_expr "$2" ;;
  send) nvim --server "$S" --remote-send "$2" ;;
  bufs) remote_expr "join(map(getbufinfo({'buflisted':0}), {_,b -> b.name.' ('.b.linecount.')'}), '\n')" ;;
  tabs) remote_expr "join(map(gettabinfo(), {_,t -> 'tab'.t.tabnr.'='.len(t.windows)}), ' ')" ;;
  # :messages already separates its entries with real newlines and nvim never
  # escapes a literal backslash in message text -- piping through `tr '\\' '\n'`
  # was a no-op on ordinary content and active corruption on a message that
  # legitimately contains one (a Windows-shaped path, a regex in an error).
  # remote_expr's own terminator is what this arm was missing, not translation.
  msgs) remote_expr "execute('messages')" ;;
  buf)  remote_expr "join(getbufline(bufnr('$2'), 1, ${3:-20}), '\n')" ;;
  fold) remote_expr "'level='.foldlevel($2).' closed='.foldclosed($2).' closedend='.foldclosedend($2)" ;;
  *)    echo "usage: nv.sh {expr|send|bufs|tabs|msgs|buf|fold} ..." >&2; exit 2 ;;
esac
EOF

# --- a counting TCP listener: turns "how many attempts" into a number --------
cat > "$QA/counter.rb" <<'EOF'
# ruby counter.rb <count-file> [port]   -- accept, hard-RST, count.
require "socket"
srv = TCPServer.new("127.0.0.1", (ARGV[1] || 21434).to_i)
n = 0
File.write(ARGV[0], "0")
loop do
  c = srv.accept
  File.write(ARGV[0], (n += 1).to_s)
  c.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
  c.close
end
EOF

# --- a PATH-LOGGING RST listener: which endpoint did each connection hit? ---
# counter.rb answers "how many"; this answers "how many of WHICH", which is
# usually the real question. A bare count cannot separate a retry from a
# window probe -- round 7 read 6 connections against 4 rendered retry
# ordinals and nearly filed the gap; the attribution resolved it at once as
# 2x GET /api/ps + 4x POST /api/chat, i.e. four attempts and no hidden ones.
cat > "$QA/pathcount.rb" <<'EOF'
# ruby pathcount.rb <log-file> [port]  -- accept, log the request line, hard-RST.
require "socket"
srv = TCPServer.new("127.0.0.1", (ARGV[1] || 21435).to_i)
log = File.open(ARGV[0], "a"); log.sync = true
n = 0
loop do
  c = srv.accept
  n += 1
  line = ""
  begin
    line = c.recv(200) if IO.select([c], nil, nil, 1.0)
  rescue StandardError
    line = ""
  end
  log.puts "#{n} #{line.to_s[/\A[A-Z]+ \S+/] || '<no request line>'}"
  c.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
  c.close
end
EOF

# --- a LOGGING pass-through proxy: makes concurrency measurable -------------
# The counting listener answers "how many attempts"; this answers "were two
# requests in flight at once, and how long did the loser wait" -- which is the
# only way to see an unjournaled internal model call starving the main turn on a
# one-slot server. See failure-injection.md 12.
cat > "$QA/proxy.rb" <<'EOF'
# ruby proxy.rb <log-file> [listen-port] [upstream-port]
# Forwards to the real endpoint and records START / FIRST-BYTE / END per request.
require "socket"
LOG = File.open(ARGV[0], "a"); LOG.sync = true
LISTEN = (ARGV[1] || 21434).to_i
UPSTREAM = (ARGV[2] || 11434).to_i
T0 = Time.now
def stamp = format("%8.3f", Time.now - T0)
srv = TCPServer.new("127.0.0.1", LISTEN)
id = 0
loop do
  cli = srv.accept
  myid = (id += 1)
  LOG.puts "#{stamp} req##{myid} START"
  Thread.new(cli, myid) do |c, i|
    up = TCPSocket.new("127.0.0.1", UPSTREAM)
    head = +""
    pump = Thread.new do
      begin
        loop { d = c.readpartial(16_384); head << d if head.length < 200; up.write(d) }
      rescue IOError, SystemCallError, EOFError
        nil
      end
      begin; up.close_write; rescue IOError, SystemCallError; nil; end
    end
    first = true
    begin
      loop do
        d = up.readpartial(16_384)
        if first
          first = false
          LOG.puts "#{stamp} req##{i} FIRST-BYTE path=#{head[/^[A-Z]+ (\S+)/, 1]}"
        end
        c.write(d)
      end
    rescue IOError, SystemCallError, EOFError
      nil
    end
    LOG.puts "#{stamp} req##{i} END"
    pump.kill
    begin; c.close; rescue IOError; nil; end
    begin; up.close; rescue IOError; nil; end
  end
end
EOF

chmod +x "$QA/drive.sh" "$QA/peek.sh" "$QA/nv.sh"
cp "$QA/env.sh" "$QA/records/env.snapshot" 2>/dev/null || true
date -u +%Y-%m-%dT%H:%M:%SZ > "$QA/records/round-start"

cat <<EOF

sandbox   $QA
tmux      -L $SOCK
started   $(cat "$QA/records/round-start")   <- close-out negative check uses this

  . $QA/env.sh
  export LAIN_DESKTOP=0          # MUST be before new-session: not in PANE_ENV, so a
                                 # pane only gets it from the SERVER's environment.
                                 # Omit it only for a named notifier act.
  tmux -L $SOCK kill-server 2>/dev/null; sleep 1     # kill-server is async; without the
  tmux -L $SOCK new-session -d -s bootstrap -x 220 -y 50; sleep 0.5   # settles, new-session
  tmux -L $SOCK set-option -g default-size 220x50    # hits the dying server and BOTH fail
  tmux -L $SOCK show-options -g default-size         # VERIFY: must print 220x50, not an error
  lain up --socket $SOCK --session lain-qa \$QA/project -- --provider ollama --model qwen3-coder:30b

verify isolation BEFORE act 1:
  for p in \$(tmux -L $SOCK list-panes -a -F '#{pane_pid}'); do
    tr '\\0' '\\n' < /proc/\$p/environ | command grep -E '^(XDG_|TMPDIR)'
  done

PIN THE JOURNAL before driving anything -- drive.sh refuses without it:
  export LAIN_QA_JOURNAL=\$(ls -t "\$XDG_STATE_HOME/lain/sessions"/*/*.ndjson | head -1)

helpers: \$QA/drive.sh  \$QA/peek.sh  \$QA/nv.sh  (\$QA/panes.sh: pane resolution, sourced by the first two)
other:   \$QA/counter.rb  \$QA/pathcount.rb  \$QA/proxy.rb
EOF
