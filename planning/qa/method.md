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

### Pin the journal, and size the quiet window above a model reload

Two ways the wait itself lies, both found in round 5 and both of which make a probe assert
nothing while looking like it passed.

**`drive.sh` picks the newest journal, which stops being the cockpit's.** It resolves
`ls -t "$XDG_STATE_HOME/lain/sessions"/*/*.ndjson | head -1`. Every non-interactive probe --
`session-and-window` §1/§2/§6 and `failure-injection` §5 all run several -- writes a journal
NEWER than the live cockpit's, so from the first such probe onward the quiet loop polls a
file that will never move again. It returns after one quiet window having waited for
nothing, and the driver then reads the cockpit BEFORE the render lands. Round 5 got a clean
"`lain://timeline` frozen at 4 lines" out of this, which is indistinguishable from round 4's
F17 and evaporated on re-measurement. **Pin it:**

```bash
export LAIN_QA_JOURNAL="$XDG_STATE_HOME/lain/sessions/<hash>/<the cockpit's file>"
```

and poll that, not `ls -t`. (`$QA/drive2.sh` in round 5's sandbox is `drive.sh` with exactly
this one change.)

**A model reload is longer than a naive quiet window.** `OLLAMA_KEEP_ALIVE=5m` plus any pause
between acts evicts the model, and the reload is **27-40s of total journal silence** (29.6s
measured cold, round 5). A quiet window at or below that reads the reload as "the turn is
done" and returns mid-turn. Use **>= 60s** for anything that may span a reload.

**Before calling a session wedged, check three things** -- round 5 twice diagnosed a "wedge"
that was neither:

```bash
tail -1 "$J" | ruby -rjson -e 'p JSON.parse(STDIN.read)["ts"]'   # how old is the last record?
date -u +%Y-%m-%dT%H:%M:%SZ                                      # ... against now
curl -s localhost:11434/api/ps | ruby -rjson -e 'puts JSON.parse(STDIN.read)["models"].empty? ? "COLD/RELOADING" : "RESIDENT"'
```

A `request_sent` a few seconds old with an empty `/api/ps` and a young `llama-server` child
is a RELOAD, not a hang. The HUD's `idle Ns` is no help here: it is a snapshot printed once
per prompt, so it goes stale by design.

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

# EVERY TOOL REFUSAL THE MODEL SAW -- the only trace a tripped bound leaves; see below
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="turn";
  Array(r["content"]).each{|b| next unless b["type"]=="tool_result" && b["is_error"];
    puts b["content"].to_s[0,200].gsub("\n"," ")}}' "$J"

# the compaction quartet: what was decided, what it paid for, and what shipped
ruby -rjson -e 'c=Hash.new(0); ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  c[r["type"]]+=1 if %w[compaction_decision compaction context_derived oracle_answer].include?(r["type"])}; p c' "$J"

# why a decision did NOT compact -- would_not_shrink is the field a short-output run pegs true
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="compaction_decision";
  puts "compacted=#{r["compacted"]} shrink_refused=#{r["would_not_shrink"]} hits=#{r["summary_hits"]} " \
       "misses=#{r["summary_misses"]} head=#{r["head_bytes"]}"}' "$J"
```

## Three things that make a check pass while asserting nothing

Each has already voided a probe. They are here rather than in a scenario because they void probes in
several.

1. **A tripped tool bound writes NO journal record.** `Tool::Bounds` returns a `Tool::Result.error`
   and nothing more — there is no `Telemetry` for it — so a bound is visible **only** as a
   `tool_result` block with `"is_error": true` inside a `turn` record (the reduction above), or as
   the text on screen. A driver grepping the journal for a record type will conclude, wrongly, that
   no bound fired. *(This is the chunk's own integration check 5, which cannot be performed as
   written; recorded here so the next round does not re-derive it.)*
2. **`Provider::Mock` reports all-zero cache fields.** Anything reading `cache_read_input_tokens` or
   `cache_creation_input_tokens` — cache waste, cold detection, `lain friction`'s dollars — passes
   vacuously against a mock, a `--dry-run`, or a recorded fixture built from one. **Cache readings
   need a real session against a real endpoint**, and the figure to sanity-check them against is
   `turn_usage.usage`, which is nested (see above).
3. **There is no `lain ledger` command.** The corrected price table (T1) is reachable from
   `lain friction SESSION`, from `lain bench arms`' cost column, and from `/ruby` inside a live
   session — nowhere else. A step written against `lain ledger` fails as an unknown command, which
   reads like a broken sandbox.

## `/ruby` is the no-model-call instrument, and it is under-used

`/ruby <expression>` evaluates inside a live session and prints the result's `inspect` — **no model
call, no tokens, no wall-clock**. `self` is a frozen `CLI::InspectionBinding` exposing `timeline`,
`session`, `supervisor` and `status`; anything else must be spelled fully qualified
(`Lain::PriceBook.default…`). It is read-mostly by construction: assigning an ivar raises
`FrozenError` rather than quietly rebinding what the next inspection reads.

That makes it the cheapest way to interrogate the *loaded library* from inside the cockpit the round
is already running — a constant's real value, a bound's real ceiling, whether this session records a
path as fully or only partially read:

```bash
# a session command journals nothing, so drive.sh's quiet window would just run out --
# pass a SHORT one and read the answer off the pane
$QA/drive.sh '/ruby Lain::Tools::ReadFile::WHOLE_BOUND.limit' 6 30 >/dev/null; $QA/peek.sh 6
$QA/drive.sh '/ruby session.partially_read?(File.expand_path("big.txt"))' 6 30 >/dev/null; $QA/peek.sh 6
```

Prefer it to reasoning from the source when a scenario asks "is this the number that is actually
live", and note the answer in the record — a constant read from a file is a claim about the repo, a
constant read through `/ruby` is a claim about the process under test.

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

- **The iteration ceiling bounds ONE ask, not the session** (T14, 2026-08-18). A session no longer
  goes dead after ~25 model calls, so an act may span many prompts and a `turn_usage` count in the
  hundreds is not by itself a reason to restart. What is still bounded is a single ask: 25 model
  calls **within one prompt** stops that ask, and the human is told in one line —
  `error: loop ran 25 iterations, ceiling is 25` — after which **the next prompt must be answered
  normally**. The round-4 failure to regress against is the opposite of a crash: a prompt accepted
  at `you>`, committed as a `turn`, immediately `run_interrupted`, and answered with nothing on
  screen while the HUD read `idle 0s`. So the check is not "did it stop" but **"did it say so, and
  did the session survive saying it"**.
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
  single file** — git status, then find, then grep, then more listing. Since T14 that ceiling is
  spent by ONE ask rather than by the session, so the same behaviour now ends in a rendered refusal
  and a session that still works: the loop is the model's, the recovery is the harness's.
- **Pointing a 3B-active MoE at multi-step orchestration scaffolds (`/create-plan`,
  `/execute-plan`) is the part it cannot do.** It writes the domain code fine. A failure to produce
  a usable plan is a MODEL finding, not a lain finding: hand-write the artifact and continue, because
  the seams the later acts exist to test still need driving.

**The mechanical escalation trigger:** three consecutive turns producing neither a spec file nor an
implementation file, or any single turn over ten minutes. Drop to the scenario's named simpler
fallback rather than redesigning mid-run.
