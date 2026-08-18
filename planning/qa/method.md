# The QA method

**Standing procedure, scenario-independent.** Every doc in `scenarios/` assumes this one and does
not repeat it. Read it once per round; it changes only when a round teaches it something.

**The premise: every defect this has found so far lived in a seam that had specs on both sides.**
A manual run is not a slower unit test. It is the only thing that drives two real components
against each other with a human at the gate, and that is where this codebase's defects live.
Round 1 found eleven defects behind a green suite of ten thousand examples.

**The corollary, learned in round 3: a fix can make the failure mode worse.** F7a's >400s silent
hang became a hard crash of the whole session. When a scenario says "confirm the old defect behaves
differently now", *differently* is not the same as *better* — record which.

---

## Toolchain

CLAUDE.md's `~/.rubies` path is unusable on this box and the working environment lives in `.envrc`,
which is machine-local and globally gitignored — so a reader of this plan alone will not find it:

```bash
eval "$(mise env -s bash ruby@4.0.6)"
```

**Override `.envrc`'s `TMPDIR` with the run's own sandbox**, or the QA run and the spec suite share
a tmp tree.

**Do NOT copy CLAUDE.md's `LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib`.** Verified 2026-08-18:
that directory does not exist on this box, and the mise-installed 4.0.6 loads OpenSSL 3.5.5 without
it and does not link Homebrew at all. The workaround belongs to the `~/.rubies/ruby-4.0.6` build,
which CLAUDE.md itself says not to use. Harmless, but it implies a fragility that is not there.

`.claude/skills/manual-qa/scripts/qa-sandbox.sh` builds the whole sandbox — XDG redirection, the
`lain` shim, `drive.sh`, `peek.sh`, `nv.sh` — and is the supported way in. The rest of this section
explains what it does and why, because a driver who does not understand the sandbox cannot tell a
lain defect from a leaked environment.

## Isolation: XDG is necessary and NOT sufficient

`Lain::Paths` resolves durable locations from an injected environment and `xdg_dir` appends `lain`,
so four exports redirect a **directly invoked** `lain` command:

```bash
QA=~/tmp/lain-qa-<date>
export XDG_CONFIG_HOME="$QA/xdg/config"   # -> $QA/xdg/config/lain
export XDG_STATE_HOME="$QA/xdg/state"     # -> $QA/xdg/state/lain/sessions/<project_hash>
export XDG_CACHE_HOME="$QA/xdg/cache"
export XDG_RUNTIME_DIR="$QA/xdg/runtime"  # -> $QA/xdg/runtime/lain   (nvim + lain-core sockets)
chmod 700 "$QA/xdg/runtime"
```

**That is not enough for the cockpit.** `lain up` runs in tmux panes, and **tmux hands a pane the
SERVER's environment, not the client's** — measured, and recorded in `cli/up/pane_command.rb`'s own
comment. `PANE_ENV` is an explicit allowlist of eleven `LAIN_*` names: no `XDG_*`, no `HOME`, no
`TMPDIR`. A pane on a pre-existing server reads them as **empty**, and `Paths#present` treats a
non-absolute value as unset, so it falls back to the real `~/.local/state`.

So the recipe has three parts and the second is not optional:

```bash
# 1. give the run its own tmux server, started FROM the exported shell.
tmux -L lain-qa kill-server 2>/dev/null
tmux -L lain-qa new-session -d -s bootstrap -x 220 -y 50
tmux -L lain-qa set-option -g default-size 220x50

# 2. VERIFY before act 1. `command grep` is load-bearing: under an agent shell `grep` is often a
#    FUNCTION, and the unqualified form returned NOTHING against a correctly-isolated cockpit in
#    the 2026-08-18 run. An empty result is a reason to RE-CHECK, not to abort.
for p in $(tmux -L lain-qa list-panes -a -F '#{pane_pid}'); do
  tr '\0' '\n' < /proc/$p/environ | command grep -E '^(XDG_|TMPDIR)'
done

# 3. VERIFY THE NEGATIVE at close-out. This is the proof the sandbox held:
find ~/.local/state/lain -newermt '<run start time>'    # must be empty
```

3. **`PANE_ENV` forwards `LAIN_*` and nothing else.** Anything else the run depends on must be
   exported into the shell that *starts the tmux server*, and a variable changed mid-run does not
   reach a pane at all. This is why `LAIN_NUM_BATCH=2048` is the right lever rather than
   `--num-batch`.

Two more, both verified:

- `XDG_RUNTIME_DIR` relocates the **nvim and lain-core** sockets. It does **not** relocate the tmux
  server socket, which lives under `TMUX_TMPDIR` or `/tmp/tmux-<uid>` and ignores XDG entirely —
  `-L` is the lever there.
- **Check `~/.lain` does not exist before act 1.** A stray `~/.lain/state.json` makes every directory
  under `$HOME` resolve `$HOME` as the project root, silently invalidating a sandbox living there.
  It is currently at `~/.lain.bak`.

## The approval gate is the point, not the paperwork

A local model requests tool calls on a real machine. Whoever drives is the gate, and the gate is
only worth having if it is read rather than skimmed:

1. **Read every command for what it would do if a path resolved somewhere unexpected**, not for
   whether it contains a scary word.
2. **Refuse anything reaching outside the sandbox** — `$HOME`, `~/.config`, `~/.ssh`, `/etc`, git
   history, another checkout. Record the refusal; a model that asks is a finding.
3. **A convincing rationale for a destructive command is a worse sign, not a better one.**
4. **Start at `accept_edits`, the default.** Postures: `plan` (reads only, `deny_all`), `manual`
   (everything, `queue`), `accept_edits` (everything, `queue`, `shadow_git`), `auto` (`approve_all`).
   Confirm with `/mode`. Never `/yolo` or `/mode +auto_approve`; `/mode !` resets to the floor.
   `accept_edits`'s lighter is deliberately the empty string, so its prompt is byte-identical to one
   with no mode support at all — you cannot tell the posture by looking.
5. **Answering "always" writes durable state.** `Approval::Remembered` persists a pre-approval into
   `.lain/config.toml`. Check that file between acts; a non-empty approvals table is itself a finding.
6. **If a gated call never renders a prompt, read `lain://approval` over RPC before answering.**
   Round 4 (F18) found a pending approval the chat pane never drew; approving it blind would have
   been approving an unread command. The nvim buffer held the full command text.

## Driving the cockpit

- **`lain up` execs `tmux attach`** — it replaces the process. In a non-interactive shell it fails
  with "open terminal failed: not a terminal" *after* the session was created, so the exit status is
  not the signal. Check `tmux -L lain-qa has-session -t lain-qa`.
- **Launch by ABSOLUTE path, through a shim.** `bundle exec ./exe/lain up` leaves `$PROGRAM_NAME`
  relative and `PaneCommand.call` interpolates it into the pane's command, so the chat pane exits
  **127** the moment the cwd differs. The shim also re-establishes the mise toolchain, which does
  not survive `PANE_ENV`'s eleven-name `LAIN_*` allowlist.
- **Size the server before the panes exist.** At tmux's default 80x24 nvim hits its hit-enter prompt
  and the RPC attach **deadlocks**. `new-session -x 220 -y 50` *and* `set-option -g default-size
  220x50` — the option is what later panes inherit.
- **`remain-on-exit on` for every window the DRIVER opens**, or a crash erases its own evidence:
  `tmux -L lain-qa set-option -w -t <window> remain-on-exit on`.
- **Chat input needs `-l`**: `send-keys -t <chat> -l '<text>'` then `send-keys -t <chat> Enter`.
  Without `-l` a leading `/` or `@`, and any `;`, are eaten by tmux's key parser.
- **Never pipe `lain` through `tee`** — that puts stdout on a pipe, the TUI never leaves the
  alternate screen, and `capture-pane` reads blank.
- **`lain --version` does not exist** — it parses as `lain chat --version`. Smoke-test with `lain help`.

### Send Enter ONCE, then poll the JOURNAL — never the status line

The 2026-08-17 edition said the opposite ("retry until the status leaves `idle`") and that rule is a
defect **generator**: one intended prompt became **4 `turn` records, 4 `request_sent`, 4
`compaction_decision`**. Readiness is the journal going quiet — `drive.sh` implements it.

Round 4 drove every act this way and produced **zero** duplicated turns. Keep the rule.

*(Since round 3's T10 fix the status line no longer claims `idle` mid-dispatch — it elides the
segment entirely. That makes the status line honest, but it is still a point-in-time snapshot
printed into the pane, not a live widget. Poll the journal.)*

### Drive nvim over RPC, not tmux keys

**The single biggest process improvement of round 4.** The old advice — "repeat `C-w h` until
`bufname()` prints `lain://review`" — cost fifteen minutes of the round-3 run. Use the socket:

```bash
S=$XDG_RUNTIME_DIR/lain/nvim-<project_hash>.sock
nvim --server "$S" --remote-expr "join(map(gettabinfo(), {_,t -> 'tab'.t.tabnr.'='.len(t.windows)}), ' ')"
nvim --server "$S" --remote-expr "join(map(tabpagebuflist(), {_,b -> bufname(b)}), ' | ')"
nvim --server "$S" --remote-send ':tabnext 3<CR>'    # the review tab
nvim --server "$S" --remote-send ':1wincmd w<CR>'    # the sidebar, deterministically
nvim --server "$S" --remote-expr 'bufname()'         # VERIFY before every gesture
nvim --server "$S" --remote-send '2G'                # then 'x', '<CR>', ':LainApprove<CR>' ...
nvim --server "$S" --remote-expr "execute('messages')"   # read a refusal the message line lost
```

That last one is how round 4 found F22. A refusal delivered as a Lua error scrolls away behind a
`Press ENTER` modal; `:messages` is the only place it survives.

### Read the `lain://` buffers, not just `capture-pane`

They are a richer evidence surface, and **where they disagree with the pane, that disagreement is
itself the finding** (F17, F18). Cheap staleness probe:

```bash
nvim --server "$S" --remote-expr "getbufinfo('lain://timeline')[0].linecount"
```

Buffers: `lain://journal` (streamed tool output ONLY, not the NDJSON journal), `lain://timeline`,
`lain://workspace`, `lain://inbox`, `lain://approval`, `lain://request`, `lain://diff`,
`lain://review`.

## Record before you interpret

Per act, with literal spellings:

- **Session journal:** `$XDG_STATE_HOME/lain/sessions/<project_hash>/<UTC-ts>-<pid>.ndjson`.
  Compute the hash ahead of the act:
  `ruby -rdigest -e 'puts Digest::SHA256.hexdigest(File.realpath(ARGV[0]))[0,12]' <dir>`
  (kernel-resolved, so a symlinked sandbox names a different directory than the editor serves).
- **`.lain/state.json`**, and **`.lain/config.toml`** for the approval-persistence check.
- **`capture-pane -p` for BOTH panes** at the moment of a finding.
- **`ollama ps`** — residency is a precondition for the cold-start reading and is not recoverable
  after the fact.

Useful journal reductions:

```bash
# every record type, counted
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; puts r["type"]}' "$J" | sort | uniq -c | sort -rn

# window provenance per turn
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "window=#{r["window_tokens"]} used=#{r["used_tokens"].inspect} prov=#{r["provenance"].inspect} sig=#{r["signals"].inspect}" \
    if r["type"]=="compaction_decision"}' "$J"

# tool calls live INSIDE turn records as content blocks, not as their own type
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="turn";
  Array(r["content"]).each{|b| puts "#{r["role"]}/#{b["type"]}: #{(b["text"]||b["name"]).to_s[0,90].gsub("\n"," ")}"}}' "$J"
```

## Check the machine is quiet, at the start and again before any timing claim

`uptime` and `ps -eo pcpu,etime,args --sort=-pcpu | head`. Any timing in a scenario is a claim about
a machine, so a busy one invalidates it silently rather than loudly.

The 2026-08-17 run found **six orphaned `while :; do :; done` spinners at ~98% CPU, 4.5 hours old**,
left by a sub-agent from the *previous* chunk. **Orphans from agent work are the expected
contaminant here**, not other people's jobs.

## Instruments worth building

- **A counting TCP listener** — ~12 lines (accept, `SO_LINGER 0`, close, count to a file) — turns
  "how many attempts did it really make" into a number. It is what made round 4's F16 a finding
  rather than a suspicion, and it generalises the severing-proxy idea to any attempt/retry question.
- **A severing proxy** — the same listener, but forwarding to the real endpoint and RST-ing after N
  bytes of response. Deterministic where killing a service is a timing race, and it leaves the
  operator's model server untouched. This is how F7 was found (control 1.9s vs >400s hung).

## Budget the round around the harness's own limits

- **A session is spent after ~25 model calls** (round 4's F21: the iteration ceiling is per-session,
  not per-ask) and then **silently swallows prompts**. Plan one act per session, restart
  deliberately, and check the `turn_usage` count before diagnosing a dead session. *Remove this note
  when F21 lands.*
- **Restart the session at the first literal `<function=` in a transcript.** Once one malformed tool
  call is committed as assistant text the model imitates it and the session never recovers, so every
  later act measures a poisoned context (round 4, MODEL-1).

## What the local model does badly — do not re-derive this

`qwen3-coder:30b` behaviours that are neither lain defects nor interesting:

- **It emits tool calls as literal text.** `<function=web_search><parameter=query>...` and stray
  `</tool_call>` arrive as prose. Reproduced cleanly in round 4: the trigger is a contaminated
  transcript, not payload length — the same prompt that failed twice in a poisoned session
  succeeded immediately in a fresh one.
- **It loops on clarifying questions instead of acting**, and on exploration instead of writing.
  Round 4 watched it burn the **entire 25-iteration ceiling on `/create-plan` without writing a
  single file** — git status, then find, then grep, then more listing.
- **Pointing a 3B-active MoE at multi-step orchestration scaffolds (`/create-plan`,
  `/execute-plan`) is the part it cannot do.** It writes the domain code fine. A failure to produce
  a usable plan is a MODEL finding, not a lain finding: hand-write the artifact and continue, because
  the seams the later acts exist to test still need driving.

**The mechanical escalation trigger:** three consecutive turns producing neither a spec file nor an
implementation file, or any single turn over ten minutes. Drop to the scenario's named simpler
fallback rather than redesigning mid-run.
