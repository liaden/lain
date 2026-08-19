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
. "$(dirname "$0")/env.sh"
TXT="$1"; QUIET="${2:-60}"; MAX="${3:-900}"
J="${LAIN_QA_JOURNAL:?LAIN_QA_JOURNAL is not pinned -- see method.md, 'Pin the journal'}"
[ -f "$J" ] || { echo "pinned journal does not exist: $J" >&2; exit 1; }
CHAT=$(tmux -L "$QA_SOCK" list-panes -a -F '#{pane_id} #{pane_current_command}' | command grep -w ruby | head -1 | cut -d' ' -f1)
[ -n "$CHAT" ] || { echo "no chat pane on tmux -L $QA_SOCK" >&2; exit 1; }

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
. "$(dirname "$0")/env.sh"
WHICH="${2:-chat}"; PAT=ruby; [ "$WHICH" = nvim ] && PAT=nvim
P=$(tmux -L "$QA_SOCK" list-panes -a -F '#{pane_id} #{pane_current_command}' | command grep -w "$PAT" | head -1 | cut -d' ' -f1)
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
case "${1:-}" in
  expr) nvim --server "$S" --remote-expr "$2" ;;
  send) nvim --server "$S" --remote-send "$2" ;;
  bufs) nvim --server "$S" --remote-expr "join(map(getbufinfo({'buflisted':0}), {_,b -> b.name.' ('.b.linecount.')'}), '\n')" ;;
  tabs) nvim --server "$S" --remote-expr "join(map(gettabinfo(), {_,t -> 'tab'.t.tabnr.'='.len(t.windows)}), ' ')" ;;
  msgs) nvim --server "$S" --remote-expr "execute('messages')" | tr '\\' '\n' ;;
  buf)  nvim --server "$S" --remote-expr "join(getbufline(bufnr('$2'), 1, ${3:-20}), '\n')" ;;
  fold) nvim --server "$S" --remote-expr "'level='.foldlevel($2).' closed='.foldclosed($2).' closedend='.foldclosedend($2)" ;;
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

helpers: \$QA/drive.sh  \$QA/peek.sh  \$QA/nv.sh  \$QA/counter.rb  \$QA/proxy.rb
EOF
