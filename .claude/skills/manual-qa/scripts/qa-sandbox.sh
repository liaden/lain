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

# --- send ONE prompt, then wait for the JOURNAL to go quiet ------------------
cat > "$QA/drive.sh" <<'EOF'
#!/usr/bin/env bash
# drive.sh "<text>" [quiet_seconds] [max_seconds]
. "$(dirname "$0")/env.sh"
TXT="$1"; QUIET="${2:-45}"; MAX="${3:-900}"
CHAT=$(tmux -L "$QA_SOCK" list-panes -a -F '#{pane_id} #{pane_current_command}' | command grep -w ruby | head -1 | cut -d' ' -f1)
[ -n "$CHAT" ] || { echo "no chat pane on tmux -L $QA_SOCK" >&2; exit 1; }
J=$(ls -t "$XDG_STATE_HOME/lain/sessions"/*/*.ndjson | head -1)
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
# peek.sh [lines] [chat|nvim]
. "$(dirname "$0")/env.sh"
WHICH="${2:-chat}"; PAT=ruby; [ "$WHICH" = nvim ] && PAT=nvim
P=$(tmux -L "$QA_SOCK" list-panes -a -F '#{pane_id} #{pane_current_command}' | command grep -w "$PAT" | head -1 | cut -d' ' -f1)
tmux -L "$QA_SOCK" capture-pane -p -t "$P" | command grep -v '^$' | tail -"${1:-12}"
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
. "$(dirname "$0")/env.sh"
S=$(find "$XDG_RUNTIME_DIR" -name 'nvim-*.sock' -type s | head -1)
[ -n "$S" ] || { echo "no nvim socket under $XDG_RUNTIME_DIR" >&2; exit 1; }
case "${1:-}" in
  expr) nvim --server "$S" --remote-expr "$2" ;;
  send) nvim --server "$S" --remote-send "$2" ;;
  bufs) nvim --server "$S" --remote-expr "join(map(getbufinfo({'buflisted':0}), {_,b -> b.name.' ('.b.linecount.')'}), '\n')" ;;
  tabs) nvim --server "$S" --remote-expr "join(map(gettabinfo(), {_,t -> 'tab'.t.tabnr.'='.len(t.windows)}), ' ')" ;;
  msgs) nvim --server "$S" --remote-expr "execute('messages')" | tr '\\' '\n' ;;
  buf)  nvim --server "$S" --remote-expr "join(getbufline(bufnr('$2'), 1, ${3:-20}), '\n')" ;;
  *)    echo "usage: nv.sh {expr|send|bufs|tabs|msgs|buf} ..." >&2; exit 2 ;;
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

chmod +x "$QA/drive.sh" "$QA/peek.sh" "$QA/nv.sh"
cp "$QA/env.sh" "$QA/records/env.snapshot" 2>/dev/null || true
date -u +%Y-%m-%dT%H:%M:%SZ > "$QA/records/round-start"

cat <<EOF

sandbox   $QA
tmux      -L $SOCK
started   $(cat "$QA/records/round-start")   <- close-out negative check uses this

  . $QA/env.sh
  tmux -L $SOCK kill-server 2>/dev/null
  tmux -L $SOCK new-session -d -s bootstrap -x 220 -y 50
  tmux -L $SOCK set-option -g default-size 220x50
  lain up --socket $SOCK --session lain-qa \$QA/project -- --provider ollama --model qwen3-coder:30b

verify isolation BEFORE act 1:
  for p in \$(tmux -L $SOCK list-panes -a -F '#{pane_pid}'); do
    tr '\\0' '\\n' < /proc/\$p/environ | command grep -E '^(XDG_|TMPDIR)'
  done

helpers: \$QA/drive.sh  \$QA/peek.sh  \$QA/nv.sh  \$QA/counter.rb
EOF
