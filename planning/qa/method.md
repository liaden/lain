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
find ~/.local/state/lain -newermt '2026-08-20T10:55:13Z'    # must be empty -- keep the Z
```

**A trailing `=` on that grep pattern is a silent self-defeat, and it reads exactly like a real
leak.** Writing the alternation as `'^(XDG_|TMPDIR)='` instead of `'^(XDG_|TMPDIR)'` anchors the
`=` to the alternation, so it matches no `XDG_*` variable at all — only a literal `TMPDIR=` line —
and the truncated output (round 7 survey: it printed only `TMPDIR`) reads like the documented
"`PANE_ENV` forwards `LAIN_*` and nothing else" failure. The sandbox was fine; the grep was
mistyped. Same family as the `-newermt` traps above — copy the pattern's parentheses literally
rather than respelling it.

**The check needs a positive control, because step 2's existing "an empty result means re-check"
guard cannot catch this one — the mistyped grep's whole danger is that it DOES return output.** A
correctly-spelled pass shows **several** `XDG_*` lines per pane (`XDG_CONFIG_HOME`, `XDG_STATE_HOME`,
`XDG_CACHE_HOME`, `XDG_RUNTIME_DIR`) plus `TMPDIR`; one line back — `TMPDIR` alone — means the
pattern is wrong, not that the sandbox leaked.

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

**That check passes VACUOUSLY on this box in two independent ways, and it is the one check whose
false pass costs the most** -- both were live in round 7.

- **`find` here is `bfs`, not GNU findutils**, and it *rejects* `-newermt 'yesterday'` (and any
  non-ISO-8601 timestamp) with an error on **stderr**, matching nothing. The recipe habitually
  pipes stderr to `/dev/null`, so it prints `0` and reads as a pass.
- **`records/round-start` is stamped in UTC with a `Z`.** Spelling it `-newermt
  '2026-08-20T10:55:13'` -- no `Z` -- makes `find` read it as **local** time; at UTC-4 that is
  four hours in the FUTURE, so it returns 0 unconditionally.

So keep the `Z`, and **always run a positive control beside it**, or the zero means nothing:

```bash
find ~/.local/state/lain -newermt '2026-08-20T10:55:13Z' | wc -l   # the assertion: 0
find ~/.local/state/lain -newermt '2026-08-19'          | wc -l   # the control: MUST be > 0
```

Round 7 read 0 against 286 and 24 on the controls, which is what made the 0 evidence rather than a
spelling accident.

**Close-out is not done until the repo the run launched from has been checked too — `git status`
on it is part of close-out, not just `find ~/.local/state/lain`.** Round 8 verified the sandbox
negative above and never looked at the working tree it started from; `git status --porcelain`
there came back non-empty hours later, after a QA-sandbox `GEM_HOME` had reached `exe/lain` and
bundler had silently re-locked `Gemfile.lock` (**P9**, findings round 8). A dirty `Gemfile.lock`
with nobody having edited it is exactly what that mechanism produces, and the sandbox's own
negative check cannot see it because the repo is outside `~/.local/state/lain`.

```bash
LAIN_REPO=/home/tara/dev/lain   # the lain checkout itself, NOT $QA -- the repo the run launched from
git -C "$LAIN_REPO" status --porcelain   # the OTHER close-out: must be empty
# ^^ RUN THIS IN A SHELL THAT HAS NOT SOURCED THE SANDBOX ENV. A redirected HOME (which
#    secret-boundary REQUIRES) hides git's global ignore at $HOME/.config/git/ignore, so every
#    globally-ignored file reports as untracked -- four false positives in round 9 (P16), and the
#    obvious "cleanup" response would commit the operator's .envrc and local settings.
```

**P16's false positives CAMOUFLAGE true ones, and that is the half round 14 had to learn.** The
warning above says a sandbox-env shell reports globally-ignored files as untracked. The consequence
nobody wrote down is that a real leak sitting in that same list reads as more of the same noise.
Round 14 found `not/absolute/.local/state/nvim/nvim.log` and `.local/state/nvim/nvim.log` in the
checkout, dated **four days earlier** -- a round-11/12 probe that gave `XDG_STATE_HOME` a RELATIVE
value, so nvim resolved its log dir against the cwd. Neither is gitignored; both had been sitting in
`git status` through two rounds' close-outs, indistinguishable from `.envrc` and friends.

So: take the baseline in a clean shell, compare in a clean shell, and **diff against the baseline
rather than reading the list**. A diff of two clean lists has no P16 noise in it at all, which is the
whole reason to take a baseline before act 0.

**And a THIRD close-out check, because the two above are BOTH blind to it (P11, round 9).**
`Project` writes `.lain/state.json` into the **cwd lain was launched from**, which for an agent
driving non-interactive probes is usually the lain checkout itself. `find ~/.local/state/lain`
cannot see it -- it is not under that tree -- and `git status --porcelain` cannot see it either,
because lain's own repo gitignores `/.lain/` (`.gitignore:22`). Round 9 ran
`session-and-window` 1/2/7 from the checkout and left a `.lain/state.json` in it while both
negatives reported clean. Either `cd` into the sandbox project for every probe, or check:

```bash
ls -d "$LAIN_REPO"/.lain 2>/dev/null && echo "LEAKED: remove it"   # must print nothing
```

**Keep this check, but know its rationale changed (round 13).** The status feed no longer lands in
`.lain/`, so the specific leak P11 described — `Project` writing `.lain/state.json` into the launch
cwd — is gone. `.lain/` is still where `config.toml`, `slots/`, `skills/`, `prompt.toml` and
`epics/` live, and a remembered approval persisted into `.lain/config.toml` in the lain checkout is
exactly the kind of durable state this check exists to catch. It is still invisible to
`git status` (`.gitignore:22`).

**The warning that prevents it: never put a `GEM_HOME` on a path `exe/lain` will inherit.**
`exe/lain:28-32` pins `BUNDLE_GEMFILE` to lain's own Gemfile and requires `bundler/setup` — so a
`GEM_HOME` exported for a scenario's own gem install (a sandbox-local Rails, say) is visible to
every `lain` invocation launched from that shell, not just to the scenario's own subprocesses. If
that `GEM_HOME` carries a gem version satisfying one of lain's own version constraints more loosely
than the committed lock, bundler re-locks lain's `Gemfile.lock` silently — no output, on a command
that was doing something else entirely. If a scenario needs gems the project under test does not
have, install them somewhere the lain process launching the cockpit cannot resolve against.


## The approval gate is the point, not the paperwork

A local model requests tool calls on a real machine. Whoever drives is the gate, and the gate is
only worth having if it is read rather than skimmed:

1. **Read every command for what it would do if a path resolved somewhere unexpected**, not for
   whether it contains a scary word.
2. **Refuse anything reaching outside the sandbox — as an allow-list against `$QA`, not an
   enumerated deny-list.** The sandbox path is known, so the rule is "does this path resolve
   under `$QA`?", never "does it match one of these names". **P8** (findings round 8): the second
   pass's approval loop encoded the deny-list shape literally — `$HOME`, `~/.config`, `~/.ssh`,
   `/etc` — with no entry for `/tmp`, and auto-approved a command that created a directory outside
   the sandbox precisely because `/tmp` was not on the list. An allow-list has no such gap by
   construction: anything not under `$QA` is refused, named or not. Record the refusal; a model
   that asks is a finding.
3. **A convincing rationale for a destructive command is a worse sign, not a better one.**
4. **Start at `accept_edits`, the default.** Postures: `plan` (reads only, `deny_all`), `manual`
   (everything, `queue`), `accept_edits` (everything, `queue`, `shadow_git`), `auto` (`approve_all`).
   Confirm with `/mode`. **Never `/mode auto` or `/mode +auto_approve`** — the posture and the layer
   are two ways to the same approve-all gate, and either one silently answers every question this
   method exists to ask. `/mode !` resets to the floor. The only sanctioned exceptions are the two
   sections written to watch what an approve-all gate does — `repl-commands.md` §6 and
   `secret-boundary.md` §5 — each scoped to a throwaway tree and each ending with `/mode !` before
   anything else in the round.
   `accept_edits`'s lighter is deliberately the empty string, so its prompt is byte-identical to one
   with no mode support at all — you cannot tell the posture by looking.
5. **Answering "always" writes durable state.** `Approval::Remembered` persists a pre-approval into
   `.lain/config.toml`. Check that file between acts; a non-empty approvals table is itself a finding.
6. **If a gated call never renders a prompt, read `lain://approval` over RPC before answering.**
   Round 4 (F18) found a pending approval the chat pane never drew; approving it blind would have
   been approving an unread command. The nvim buffer held the full command text.

## Driving the cockpit

- **`lain up` execs `tmux attach`** — it replaces the process. In a non-interactive shell it fails
  with "open terminal failed: not a terminal" *after* the session was created, so for that failure
  the exit status is not the signal. Check `tmux -L lain-qa has-session -t lain-qa`.

  **That rule no longer covers every `lain up` failure, and inverting it is the point.** `lain up`
  now pre-flights the chat command *before* `new-session`, so a construction refusal — a missing API
  key, a bad `--num-ctx`, an unknown `--compact-strategy` — exits nonzero on the operator's own
  terminal with **no session created at all**. There the exit status IS the signal, and
  `has-session` failing is the pass rather than the defect. A third shape sits between them: a chat
  pane that dies within ~150ms makes `lain up` print the pane's scrollback and decline to attach,
  with the session left standing and the corpse inside it. So read the exit status *and*
  `has-session` together, and see `failure-injection.md` §11 for which combination means what. A
  creating `lain up` pays ~110ms for the pre-flight; a reattach is untaxed.
- **Launch by ABSOLUTE path, through a shim.** `bundle exec ./exe/lain up` leaves `$PROGRAM_NAME`
  relative and `PaneCommand.call` interpolates it into the pane's command, so the chat pane exits
  **127** the moment the cwd differs. The shim also re-establishes the mise toolchain, which does
  not survive `PANE_ENV`'s eleven-name `LAIN_*` allowlist.
- **Size the server before the panes exist.** At tmux's default 80x24 nvim hits its hit-enter prompt
  and the RPC attach **deadlocks**. `new-session -x 220 -y 50` *and* `set-option -g default-size
  220x50` — the option is what later panes inherit.

  **`kill-server` is asynchronous, so let it settle or the sizing silently does not happen.** Run
  back-to-back, `new-session` hits the dying server and prints `server exited unexpectedly`, then
  `set-option` prints `no server running` — **and both fail**, so `lain up` later creates the server
  itself at tmux's default **80x24** and you are in the deadlock this bullet exists to prevent.
  Reproduced 2026-08-19: 1 run in 3 raced, and the resulting cockpit came up 80x24 with 40x24 panes
  and an nvim RPC that hung until killed. `sleep` and then **verify**, rather than assuming:

  ```bash
  tmux -L "$QA_SOCK" kill-server 2>/dev/null; sleep 1
  tmux -L "$QA_SOCK" new-session -d -s bootstrap -x 220 -y 50; sleep 0.5
  tmux -L "$QA_SOCK" set-option -g default-size 220x50
  tmux -L "$QA_SOCK" show-options -g default-size    # must print `default-size 220x50`, not an error
  ```

  This is also the cheapest explanation for an nvim RPC that hangs: check the pane geometry
  (`list-panes -a -F '#{pane_width}x#{pane_height}'`) before hunting anything subtler.
- **The one-cockpit-at-a-time workaround is retired (2026-08-27).** Round 13's F73 — a second
  concurrent `lain up` deadlocking its nvim on the shared `lain-cockpit://start` swap path's
  `E325: ATTENTION` modal, before nvim ever serves RPC — is fixed: `setlocal noswapfile` now
  scopes to the scratch buffer and, the part that matters, runs *before* the `:file` that names
  it, since `:file` is what creates the swapfile. A guard placed after it never ran — nvim was
  already blocked on the recovery modal by then, and that is exactly the shape the first attempt
  at this fix took: a correct-looking argv that did not fix the bug. Verified 2026-08-27 through
  real tmux against a planted dirty swapfile: the pre-fix argv served no RPC and raised `E325`;
  the flag placed after `:file` also served no RPC and raised `E325`; the shipped ordering served
  RPC with no `E325`. A real file opened afterwards in that same nvim still gets its own
  swapfile, so this does not disable swap recovery generally. The kill-the-previous-session,
  clear-the-swap ritual this bullet used to prescribe is gone with it — recorded here, retired,
  so a driver who remembers the old rule knows it was lifted on purpose, not lost in an edit.

  Two facts about this class of bug are still worth carrying, because they govern how a driver
  reproduces it:
  - **`E325` fires on a *dirty* swapfile, not merely a present one.** A live-but-unmodified peer
    collides silently onto `.swo`. The cockpit's scratch buffer is dirty as soon as a view lands,
    so dirty is its steady state — but a check run against a clean buffer passes on the bug.
  - **A stale swapfile is what a *crash* leaves.** `:qa!` removes it on clean exit, so
    reproducing this needs a killed nvim, not a quit one.
- **`remain-on-exit on` for every window the DRIVER opens**, or a crash erases its own evidence:
  `tmux -L lain-qa set-option -w -t <window> remain-on-exit on`.
- **Chat input needs `-l`**: `send-keys -t <chat> -l '<text>'` then `send-keys -t <chat> Enter`.
  Without `-l` a leading `/` or `@`, and any `;`, are eaten by tmux's key parser.
- **Never pipe `lain` through `tee`** — that puts stdout on a pipe, the TUI never leaves the
  alternate screen, and `capture-pane` reads blank.
- **`lain --version` does not exist** — it parses as `lain chat --version`. Smoke-test with `lain help`.
- **`--prompt` is a SEED, not a batch mode, and its exit status says nothing about the ask.**
  `Repl#converse` takes it as `first_prompt` and then reads the terminal as usual, so with
  `< /dev/null` it dispatches one turn, hits EOF and exits **0** — including when the turn failed
  outright. Round 6 measured exit 0 on a blackhole endpoint after four exhausted retries, and again
  on connection-refused. Several scenarios use `--prompt` as "the cheap vehicle": judge those by the
  rendered text and the journal, **never by `$?`**. A launch-level refusal is the opposite case and
  does exit 1 — the split is construction (exits nonzero) versus a turn that failed (exits 0).

### Send Enter ONCE, then poll the JOURNAL — never the status line

The 2026-08-17 edition said the opposite ("retry until the status leaves `idle`") and that rule is a
defect **generator**: one intended prompt became **4 `turn` records, 4 `request_sent`, 4
`compaction_decision`**. Readiness is the journal going quiet — `drive.sh` implements it.

Round 4 drove every act this way and produced **zero** duplicated turns. Keep the rule.

**And do not type at all while an approval is parked -- the Enter IS the answer, and it denies.**
The rule above bounds how many times you send; this one bounds *when*. At an `[y/N]` prompt the
newline a driver sends to submit its next PROMPT is consumed as the approval's answer, and the
default is **deny**. Round 6 lost a `bash` call that way and then spent three turns watching the
model recover from a denial nobody intended -- which reads exactly like a model failure and is the
driver's. **The rule governs HAND-TYPED sends too, not only `drive.sh` ones** -- round 7 sent a
`/mode` by raw `send-keys` without checking, and had to discard the probe as invalid.
`drive.sh` now refuses to send while `lain://approval` holds anything, and a driver
sending keys by hand should make the same check:

```bash
$QA/nv.sh buf 'lain://approval' 2 | command grep -q 'no approvals pending' || echo "ANSWER IT FIRST"
```

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

**A hand-rolled `curl` probe can MANUFACTURE that reload, and then you measure it as latency.**
`bench.md` records `--num-ctx` forcing a runner reload; the same is true of **any** option that
differs from the resident runner's argv, and `num_batch` is the one a driver reaches for. Round 6
measured "30.9s to first token" for a 33KB prompt and nearly filed it as prefill cost; the request
had passed `num_batch: 2048` against a runner started with `-b 512`, so the figure was a ~27s
reload. Re-measured without it: **9.3s**. Read the runner's real argv first, and pass nothing that
disagrees with it:

```bash
tr '\0' '\n' < /proc/$(pgrep -P "$(pgrep -x ollama | head -1)" | head -1)/cmdline | paste -sd' '
```

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

That last one is how round 4 found F22, when a refusal delivered as a Lua error scrolled away behind
a `Press ENTER` modal and `:messages` was the only place it survived. **The modal is gone** — the
refusal rail is now width-, break- and height-aware, so no refusal can raise a hit-enter or
`-- More --` prompt — but the read is more useful than ever rather than less: the rail *deliberately*
displays one fitted line and records the complete, unfolded sentence to `:messages`. So `:messages`
is now where the full text lives **by design**, not a workaround for a prompt. Read it whenever a
refusal looks truncated on the message line; that truncation is the mechanism working.

(Recording the unfolded copy needs `'messagesopt'`, which is nvim 0.11+ — the stated minimum, so
there is no fallback path and a truncated `:messages` is a regression rather than a degrade.
`cockpit-surfaces.md` §4 has the detail; record `nvim --version` anyway, because an editor below the
minimum makes every reading in a round untrustworthy.)

### Making a session with `message` and `child_turn` records

Several probes need a session whose causal edges are **not** plain `parent` links —
`failure-injection.md` §3's `causal_parents` damage, and any F23-style fork/resume regression. A
session of ordinary turns has none, so a probe written against that key silently tests nothing, and
the scenario tells you to check first without telling you how to make one. It is one prompt:

```bash
@researcher[/critique] <path-to-some-file>     # spawns; produces message + child_turn records
```

**The bracket and the path are load-bearing.** A bare `@researcher <question>` does **not** spawn —
it is treated as ordinary prose and produces no `message` record at all, which looks like a broken
fleet. Verify rather than assume:

```bash
ruby -rjson -e 'c=Hash.new(0); File.foreach(ARGV[0]){|l| r=JSON.parse(l) rescue next; c[r["type"]]+=1}
  p c.select{|k,_| %w[message child_turn].include?(k)}' "$LAIN_QA_JOURNAL"
```

Expect the HUD to gain a `fleet N` segment and the prompt to become `human>`. **Answering there is
its own hazard — see the `human>` note below.**

**This recipe parks the CHILD's question, so it cannot exercise the HUD's idle-elision check**
(`cockpit-surfaces.md` §7: "at the `human>` prompt of a parked `ask_human` the `idle` segment must be
absent entirely"). `PromptComposer#idle` elides on `@agent.dispatching?`, which reads the PARENT's
dispatch lock; with a subagent holding the question the parent is genuinely idle, so the line
correctly reads `... fleet 1 idle 5s` and a driver who does not know this files a defect that is not
there (round 8 nearly did, and withdrew it on the code read). Reaching §7's case needs the parent's
OWN `ask_human` parked — ask the top-level agent a question it must put to a human — not a `@role`
spawn.

### At the `human>` prompt: commands run, but `/inbox` opens a drain where the next line is an answer

**Round 6's F27 ("every command but `/inbox` is silently delivered to the subagent as a prose
answer") is WITHDRAWN — round 7 re-tested it and it does not reproduce.** With a subagent's question
freshly parked, `/status`, `/mode` and `/ruby 6*7` all rendered normally at a plain `human>` prompt —
journal unchanged, question still parked. `Wiring#build_repl` binds the command registry
(`wiring.rb:460`) and `Reply#typed` dispatches through it (`human_replies.rb`); the
mechanism works.

**The real trap is narrower, and is what round 6 actually hit: `/inbox` itself opens a
drain, and the very next line typed — even a registered `/command` — was read as the answer to the
parked question, not dispatched. The round-7 chunk fixes it by giving the drain the same
classification the outer prompt uses; the reproduction below is the PRE-FIX behaviour, kept so a
round-8 driver can tell a regression from a pass.** `Reply#drained` (`human_replies.rb`) builds a bare
reader lambda with no registry and no `prose?` check, so the classification the outer prompt applies
is simply absent for the one line typed right after `/inbox`. Reproduction, journal-verified (F29):

```bash
send '/status'   # -> renders status, journal UNCHANGED, still parked        (registry consulted)
send '/inbox'    # -> renders the question document, journal UNCHANGED       (opens its drain)
send '/mode'     # -> PRE-FIX: journal GROWS, model answers "/mode" as the reply (bypassed)
                 # -> POST-FIX: /mode RENDERS, journal unchanged, question still parked
```

**The lesson for the method:** `/inbox` changes what the next line means without changing the
prompt — `human>` reads identically either way, and a `/ruby` reading taken as that next line is not
a reading, it is a message to a subagent. Treat "typed right after `/inbox`" as its own state, and
confirm from the journal (did it grow? did the parked count drop?) rather than from the prompt
string. Check the prompt before every `/` command, and clear the inbox before taking any inspection
reading:

```bash
$QA/peek.sh 2 | tail -1        # `you>` or `human>`?
```

### `peek.sh` filters blank lines, so a stale tail reads like a frozen pane

`peek.sh <n>` pipes through `command grep -v '^$'` before `tail -n`, which is usually what you want
— but it means a pane whose visible rows have gone BLANK (the TUI between renders, or a prompt that
has not been redrawn) returns the same trailing text call after call. Round 13 read that as a wedged
session three times before capturing the pane raw and finding rows 29-50 were simply empty. When a
pane looks frozen, capture it without the filter and count the lines before diagnosing anything:

```bash
tmux -L "$QA_SOCK" capture-pane -p -t "$PANE" | cat -n | tail -25
```

### Three ways a driver aims at the wrong pane, all of them silent (round 15)

Each of these cost a probe in one round, and none of them announces itself — a helper aimed at the
wrong surface returns plausible text rather than an error.

- **`drive.sh` and `peek.sh` resolve the chat pane as `grep -w ruby | head -1`, so any leftover
  probe session steals the drive.** Round 15 sent a prompt intended for a `lain chat` probe and it
  landed in the **cockpit**, adding a turn to the subject session. Kill probe windows before
  bringing the cockpit up (`method.md` already says to pin the JOURNAL for the same class of
  reason; this is the same hazard one surface over), or resolve the pane explicitly and pass it in.
- **Resolving a pane by WINDOW name gets nvim, not the repl.** `lain up` puts nvim *and* the chat
  process in ONE window called `chat`, so `list-panes -F '#{window_name} #{pane_id}' | awk '$1=="chat"'`
  returns the editor. Everything then reads an editor pane that never shows an approval prompt.
- **An approval detector that greps the WHOLE pane false-positives forever after the first
  approval.** An answered `[y/N]` line stays on screen, so `capture-pane | grep '\[y/N\]'` keeps
  matching history. Read only the **last non-blank line**:

  ```bash
  tmux -L "$QA_SOCK" capture-pane -p -t "$PANE" | command grep -v '^$' | tail -1 \
    | command grep -qE '\[y/N\][[:space:]]*$'
  ```

**And `nv.sh expr` prints no trailing newline**, so two consecutive reads run together in a
transcript. Round 15 read `tab2=4` immediately followed by a bare `4` as `tab2=44` and briefly had a
44-window review tab. Echo a newline after each `expr`, or read one value per command.

They are a richer evidence surface, and **where they disagree with the pane, that disagreement is
itself the finding** (F17, F18). Cheap staleness probe:

```bash
nvim --server "$S" --remote-expr "getbufinfo('lain://timeline')[0].linecount"
```

Buffers: `lain://journal` (streamed tool output ONLY, not the NDJSON journal), `lain://timeline`,
`lain://workspace`, `lain://inbox`, `lain://approval`, `lain://request`, `lain://diff`,
`lain://review`.

## What a text read cannot verify, and how to capture it

Every RPC recipe above — `bufname()`, `getbufline`, `execute('messages')` — returns text, and text
answers a content question or a position question. Two properties this method needs do not survive
that channel, because the text they would need to carry is not text: whether a rendered cell carries
an ATTRIBUTE (colour, bold, underline) rather than a plain codepoint, and whether the line a text
read just fetched is sitting inside a CLOSED fold or an open one. `getbufline` returns the same
string either way — folded or not — so a check built only from it cannot tell "the row is folded to
its summary" from "the row happens to be one line". Both need a real terminal, and both are cheap to
ask for.

**Escalation check, not a residual worry:** `capture-pane -e` was measured 2026-08-19 against a real
nvim rendering a syntax-highlighted file in a scratch tmux pane (`termguicolors`, `TERM=tmux-256color`,
NVIM v0.12.4) and came back fully usable — every one of 50 captured lines carried a decodable SGR
sequence, not noise. If a future round ever finds `-e` output that is *not* usable this way — binary
soup a driver cannot correlate back to a line — say so here rather than shipping a recipe nobody
follows (this card's own escalation trigger). That has not happened yet.

**Never point `nv.sh` (or a hand-typed `nvim --server` recipe) at a socket you did not create.**
Several agents share this box, and `nv.sh` resolves its target by globbing
`$XDG_RUNTIME_DIR` for `nvim-*.sock` — if that variable is ever the real per-user runtime dir
rather than this sandbox's own (`env.sh` not sourced, the recipe run from outside the sandbox), the
glob matches every OTHER agent's live cockpit, and `send` can type into a stranger's editor.
Verified 2026-08-19: a reviewer following this file's own recipe attached to a different agent's
live nvim this way, opened a scratch buffer, and deleted it again — no damage, but it should have
been impossible. `nv.sh` now refuses rather than guesses (checks `$XDG_RUNTIME_DIR` against the
sandbox's own path before globbing, and refuses on more than one match instead of taking `head -1`);
a hand-typed recipe copied out of this doc has no such guard, so resolve `$S` through `$QA/nv.sh`
where possible rather than reimplementing the `find` by hand.

**The refusal's remedy is your own stale socket, and `nv.sh` will not remove it for you.** A killed
cockpit's nvim leaves its `$XDG_RUNTIME_DIR/lain/nvim-*.sock` behind, and that stale file is what
usually turns one live match into the ambiguous "more than one" this refusal is protecting against.
Remove the stale socket before bringing up the next cockpit, rather than working around the refusal.

**Never `rm` the glob.** Several agents share this box -- that is the whole premise of the paragraph
above -- and since the swapfile fix landed, two cockpits running at once is the ORDINARY state rather
than the anomaly it used to be, so more than one LIVE socket is now expected. A wildcard delete takes
a stranger's live cockpit with it, which is the same accident this section exists to prevent, in the
other direction. Delete only what nothing answers on:

```bash
for s in "$XDG_RUNTIME_DIR"/lain/nvim-*.sock; do
  timeout 2 nvim --server "$s" --remote-expr '1+1' >/dev/null 2>&1 || rm -f "$s"
done
```

### Pane attributes: `capture-pane -e`, not `-p`

`-p` is what every other recipe in this method uses, and it is the wrong flag for a colour question:
tmux's plain capture already stripped the SGR codes it read off the pane, by design — it is built
for a plain-text record, not a rendering record. `-e` preserves them. `$QA/peek.sh` now takes a third
argument for this (`peek.sh <lines> <chat|nvim> attrs`); the recipe it wraps:

```bash
tmux -L "$QA_SOCK" capture-pane -p -t "$PANE" > plain.txt      # tmux already stripped SGR
tmux -L "$QA_SOCK" capture-pane -e -t "$PANE" > escaped.txt    # -e keeps it -- note: -p is STILL required for stdout
grep -aPc '\x1b' plain.txt      # presence probe: count of lines carrying an ESC byte
grep -aPc '\x1b' escaped.txt
```

**Trap verified 2026-08-19: `-e` alone writes to a tmux paste buffer, not stdout — `-p` is required
alongside it, same as every other capture.** Omitting `-p` produced a silent zero-byte file that
looked like "no attributes", not "wrong flag".

Measured, on the setup above:

```
plain.txt:   50 lines, grep -aPc '\x1b' plain.txt   -> 0
escaped.txt: 50 lines, grep -aPc '\x1b' escaped.txt -> 50
```

A sample line from each, `cat -v`'d for the escaped one so the codes print rather than act:

```
plain.txt:1:      1   # frozen_string_literal: true
escaped.txt:1:    ^[[1m^[[38;2;219;206;146m^[[48;2;25;30;44m    1   ^[[0m^[[38;2;205;205;206m^[[48;2;41;50;73m# frozen_string_literal: true
```

The `\e[38;2;R;G;Bm` / `\e[48;2;R;G;Bm` pairs are 24-bit foreground/background SGR — exactly what
`termguicolors` emits and exactly what `-p` throws away. This is the recipe for any check phrased
"is this rendered in colour" — a torn-turn error highlight, a refusal rail's colour, a diff's
red/green — none of which a `getbufline` or a plain `capture-pane -p` can answer.

### `capture-pane` cannot page back in the chat pane — it is on the alternate screen

`-S -<n>` is the flag a driver reaches for to read more than the visible pane, and **on the chat
pane it does nothing**. The TUI runs on tmux's alternate screen, which has no scrollback at all.
Measured 2026-08-23, with `history-limit` at 2000:

```
alternate_on=1
capture-pane -S -50   -> 50 lines
capture-pane -S -400  -> 50 lines
capture-pane -S -2000 -> 50 lines
```

**This manufactures false findings, and it did (P14, round 9).** `/help` renders ~44 command lines
plus a skill catalog into a 50-row pane; the top scrolls away irrecoverably. Reading it back showed
four commands "absent from `/help`" — and they were exactly the first four in registration order,
both of which then dispatched correctly when typed. So: any check needing more than one screenful of
chat output cannot be driven this way. Narrow the output, or read a `lain://` buffer, which is a
real buffer with real lines that `getbufline` can page through. **And treat a "missing" item at the
very start or end of a long render as a capture artifact until proven otherwise.**

**Worse for a ONE-SHOT `lain chat`: the alternate screen is TORN DOWN on exit**, so a capture after
the process ends reads `Pane is dead` or the empty primary screen -- even with `remain-on-exit on`.
Round 10 lost a probe's final line this way repeatedly, including by polling every 0.4s: the last
render and the exit race each other and the exit always wins.

**The recipe P14 stops one line short of: `pipe-pane` captures the output STREAM, and survives the
teardown.**

```bash
LOG=$QA/records/probe.log; : > "$LOG"
tmux -L "$QA_SOCK" new-window -d -n probe "cd <dir> && exec $QA/shim/lain chat ... < /dev/null"
tmux -L "$QA_SOCK" pipe-pane -o -t probe "cat >> $LOG"
# ...wait for the window to disappear...
sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$LOG"        # strip SGR for reading
cat -A "$LOG"                                       # or keep them: this is how F58 was measured
```

This is the only way round 10 could read the `attempt 4, giving up` line, and `cat -A` on the same
log is what showed four retry lines sharing ONE newline (F58). Use it for any check about what a
non-interactive run actually printed.

### Fold state: `foldlevel()`/`foldclosed()` over RPC, not `getbufline`

A fold is a WINDOW-local rendering decision, not a buffer property `getbufline` exposes — the
underlying lines are all still there whether the fold is open or shut. The two primitives, now also
`$QA/nv.sh fold <lnum>` (reads against the CURRENT window, same as every other `nv.sh` gesture):

```bash
nvim --server "$S" --remote-expr "foldlevel(<lnum>)"      # fold nesting depth at that line; 0 = no fold
nvim --server "$S" --remote-expr "foldclosed(<lnum>)"     # the CLOSED fold's start line, or -1 if open/none
nvim --server "$S" --remote-expr "foldclosedend(<lnum>)"  # the closed fold's LAST line -- how much it hides
```

Both read against the CURRENT window, so switch tabs/windows first (`:tabnext N<CR>`, `:Nwincmd w<CR>`
per the RPC recipe above) exactly as any other gesture in this method does — a fold state read from
the wrong window answers a question about a buffer nobody is looking at.

**Measured 2026-08-19** against a real nvim (same instance as above, second tab) over a 9-line, three-
row fixture built to mimic a folded approval/inbox row — a one-line summary followed by two detail
lines, three rows, `foldmethod=manual`, one `:N,Mfold` per row:

```bash
nvim --server "$S" --remote-send ':1,3fold<CR>'    # row 1: lines 1-3
nvim --server "$S" --remote-send ':4,6fold<CR>'    # row 2: lines 4-6
nvim --server "$S" --remote-send ':7,9fold<CR>'    # row 3: lines 7-9

nvim --server "$S" --remote-expr 'foldlevel(1)'       # -> 1
nvim --server "$S" --remote-expr 'foldclosed(1)'      # -> 1      (closed, folds start closed)
nvim --server "$S" --remote-expr 'foldclosedend(1)'   # -> 3      (hides lines 1-3 down to a summary)

nvim --server "$S" --remote-send ':1foldopen<CR>'
nvim --server "$S" --remote-expr 'foldlevel(1)'       # -> 1      (still a fold at this line)
nvim --server "$S" --remote-expr 'foldclosed(1)'      # -> -1     (now OPEN -- level alone can't tell you this)

nvim --server "$S" --remote-expr 'foldclosed(4)'      # -> 4      (row 2 untouched: still closed on its own line)
```

That last line is the check integration check 7 actually needs: **each row's fold state is
independent of its neighbours' — opening row 1 must not open or close row 2 or row 3.** `foldlevel`
alone cannot distinguish open from closed (it stayed `1` across the open), which is why the
recipe needs both calls, not one: `foldlevel` answers "is there a fold here at all", `foldclosed`
answers "is it presently hiding its contents".

This is the exact recipe `cockpit-surfaces.md`'s review-flow and approval sections already point at
by hand (`nvim_get_mode`, `:messages`) for a related class of question, and it is what a round should
run against `lain://approval` and `lain://inbox` once T9/T12 land: read the row's line number off the
buffer's own record boundary (`RECORD_START`, the same test the `]]`/`[[` motions and the fold's own
`foldexpr` already ride — see `runtime/05_records.lua` and `runtime/10_folds.lua`), then `foldlevel`
and `foldclosed` that line before and after `<CR>`/`zo`/`zc`, both by eye (does the row visually
expand to its full command?) and over RPC (does the primitive agree with what the eye saw?).

## Record before you interpret

Per act, with literal spellings:

- **Session journal:** `$XDG_STATE_HOME/lain/sessions/<project_hash>/<UTC-ts>-<pid>.ndjson`.
  Compute the hash ahead of the act:
  `ruby -rdigest -e 'puts Digest::SHA256.hexdigest(File.realpath(ARGV[0]))[0,12]' <dir>`
  (kernel-resolved, so a symlinked sandbox names a different directory than the editor serves).
- **The status feed**, at `$XDG_STATE_HOME/lain/status/<project_hash>/state.json` — **not**
  `.lain/state.json`, which `ProjectDir` retired (round 13 lost a cross-check to the old spelling).
  `lain up` prints the resolved path on its `HUD state:` line; read it from there.
  And **`.lain/config.toml`** for the approval-persistence check, which is still under `.lain/`.
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

# what a compaction actually moved -- the proxy is BYTES and now says so
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="compaction";
  puts "before=#{r["bytes_before"]} after=#{r["bytes_after"]} saved=#{r["cost_saved"]} spent=#{r["cost_spent"]}"}' "$J"
```

**Mind the unit, and mind the vintage of the journal you are reading.** Two field pairs were renamed
this chunk because they counted bytes under token names, which cost a reader once already —
`tokens_before / window_tokens` read 80% occupancy against a session every other reader put at 32%,
because the numerator was bytes and the denominator provider-measured tokens:

| record | was | is now |
|---|---|---|
| `compaction` | `tokens_before` / `tokens_after` | **`bytes_before` / `bytes_after`** |
| the seam decision | `tokens_removed` / `tokens_after` | **`bytes_removed` / `bytes_after`** |

**`used_tokens` and `window_tokens` were deliberately NOT renamed** — those are provider-measured
token counts and always were, so the reductions above that read them are unchanged.

**Old journals are not migrated and no shim reads them.** A record written before this chunk still
carries `tokens_before`/`tokens_after` holding exactly these byte figures under the misleading name.
So a reduction written against the new names returns nothing on a pre-chunk file, which looks like
"no compaction fired" — check the vintage before concluding that, and say which naming a recorded
figure came from when comparing rounds.

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

**Round 10 found TWENTY-FOUR of them, 4 hours old, at load average 25.84** -- from
`.claude/worktrees/t13/probes-t13/stress.sh`, whose `kill $SPIN` never ran because its parent died
first. They were **reparented to init**, which is the cheap way to identify them:

```bash
ps -eo pid,ppid,args | awk '$2==1 && /while :; do :; done/'    # ppid 1 == nobody is coming back
```

**Round 12 found the SAME SIXTEEN round 11 had found, now 5.6 hours old** -- the round-11 driver was
refused permission to kill them, so they burned ~13 of 16 cores across two consecutive rounds. This
is the third round running to be contaminated by orphaned spinners, and the recurrence is the
finding: **a probe that saturates the box must clean up on the FAILURE path, not only the success
path.** The shape that spawns them is always the same --

```bash
for i in $(seq 1 $(nproc)); do (while :; do :; done) & done
loadpids=$(jobs -p)
...                       # anything here that dies takes the `kill` below with it
kill $loadpids 2>/dev/null
```

-- and the one-line fix is to arm the cleanup before the work rather than after it:

```bash
loadpids=$(jobs -p)
trap 'kill $loadpids 2>/dev/null' EXIT INT TERM     # survives a failure, a timeout and a Ctrl-C
```

**Write the `trap` on the line after the spawn, every time.** A `kill` on the last line is not
cleanup, it is cleanup *conditional on nothing going wrong*, which is the one case it is not needed
in. And a driver who finds orphans and cannot clear them should say so in the findings AND escalate
to the operator rather than absorbing it -- round 11 absorbed it and round 12 paid for it again.


**When the gate FAILS and cannot be cleared, a timing claim is still possible — as a CONTROL SET,
never as an absolute.** Round 11 drove a whole round at 0.0% idle behind 16 orphaned spinners it was
not permitted to kill, and still answered `survey.md` §2's "does it refuse without walking the tree"
question, because the question is comparative and the samples share the load:

| run | files | wall |
|---|---:|---:|
| REFUSE `lib` | 742 | 1578ms |
| SUCCEED `lib/lain/frontend` | 52 | 1676ms |
| SUCCEED `lib/lain/survey` | 9 | 1485ms |
| **`lain help`** — does no survey at all | — | **1521ms** |

The no-op baseline is the load-bearing row: the 742-file refusal costs ~57ms more than a command
that surveys nothing, and is FASTER than surveying 52 files. That conclusion survives any load the
four samples share. **The rule: when the gate fails, restate the question comparatively and include a
do-nothing baseline, rather than either reporting a contaminated absolute or dropping the check.**
Say in the findings that no absolute wall-clock claim rests on that round.

**Judge this gate on INSTANTANEOUS idle, not on `uptime`.** The 1-minute load average lags badly --
it still read 14.00 several minutes after all 24 were killed, which would read as a failed gate on a
machine that was 92% idle. Use:

```bash
top -bn2 -d2 | command grep '^%Cpu' | tail -1      # the SECOND sample; the first is since-boot
```

Round 10 is the first round where this gate actually fired, and the stakes are concrete: 24 busy
cores would have been attributed to lain by `bench-arms` (entirely wall-clock) and by every stall
reading, which is the F26 class.

**Ask with `pgrep -P` or the exe path, never a bare `pgrep -f` -- it matches YOUR OWN shell.** An
agent shell's command line contains the pattern you are grepping for, so `pgrep -f 'pre-commit'`
matches the `echo "=== pre-commit ==="` in the very command asking the question. Round 6 hit this
**four** times in one round -- orphan spinners, `pre-commit`, the ollama runner, and a
`bench arms` run it declared still-running two minutes after it had finished. Round 7 hit it a
FIFTH time, and destructively: `pkill -f 'counter.rb'` matched the agent shell's own command line
and **killed the command issuing it** (exit 144), losing a heredoc mid-write. CLAUDE.md records the
trap for `parallel_rspec`; it generalises to every `pgrep -f` here. The reliable forms:

```bash
pgrep -P "$(pgrep -x ollama | head -1)" | head -1     # a child, by parent pid
ps -eo pid,args | grep '[b]ench arms' | grep -v zsh   # bracket AND drop the shell
ls -l /proc/<pid>/exe                                 # what it really is
```

**A driver script with an UNSET `$QA_SOCK` aims at the operator's own tmux, and that is the same
family of hazard one step out (round 14).** A helper invoked without `$QA` exported ran
`tmux -L "" kill-server`, which resolves to the **default** socket rather than the round's. It
errored harmlessly here only because `/tmp/tmux-1000` is a directory; on a box where the operator
had a server on the default socket it would have killed it, mid-round, with no warning. The fix is
the same shape as the `pgrep` one -- refuse rather than guess:

```bash
: "${QA_SOCK:?refusing: QA_SOCK is unset -- an empty -L targets the DEFAULT tmux server}"
```

Put that line at the top of every helper that takes `-L "$QA_SOCK"`, not only the ones that kill.

**Round 13 hit it an EIGHTH time**, spelling it `pkill -u "$(id -u)" -f 'nvim.*lain-cockpit'` to
clear cockpit nvims: the pattern matched the issuing shell's own command line and killed it (exit
144). It also came within one broadened pattern of killing the operator's own unrelated `nvim`. The
form that worked first try, and the one to copy:

```bash
for p in $(ps -eo pid,args | command grep '[l]ain-cockpit://start' | awk '{print $1}'); do kill -9 $p; done
```

**Round 9 hit it a SIXTH time, having read this section**, reaching for `pkill -f` reflexively to
clear a hung `ollama run`: the pattern matched the agent shell's own command line and killed the
command issuing it (exit 144). Treat it as a standing hazard, not a lesson anyone has absorbed --
the safe form is one line longer and works first try.

**Round 10 hit it a SEVENTH time, in the QUIET-MACHINE GATE ITSELF** (P17). `pgrep -cf '[p]re-commit'`
returned 1 and `pgrep -cf '[l]ain'` returned 1, both matching the driver's own shell -- because the
gate command contained `echo "pre-commit: ..."`, so the literal string was on its command line even
though the bracket trick protected the pattern. **The bracket trick does not help when YOUR OWN
command line contains the word.** Two consequences: the gate reported contention that did not exist,
and it would equally have MISSED real contention behind a false positive nobody investigates twice.

The form that actually works is to exclude the issuing process rather than to keep re-spelling the
pattern:

```bash
pgrep -f 'pre-commit' | grep -v "^$$\$"              # drop the issuing shell by pid
pgrep -c -f 'pre-commit' --older 1                    # or: ignore anything younger than 1s
```

### The driver shell here is zsh, and zsh does not word-split unquoted parameters

Every recipe in these documents is written in bash idiom. In zsh, `$VAR` unquoted expands to ONE
word, so a loop like `for A in "--num-ctx 0" ...; do lain up ... $A; done` passes `--num-ctx 0` as a
single argument. What comes back is a Thor usage error --
`ERROR: "lain chat" was called with arguments ["--num-ctx 0"]` -- which exits 1 and creates no
session, so it wears the exact shape of the construction refusal the step is testing and reads as a
pass. Round 9 filed nothing on it only because the message did not match the expected text. Use
explicit arguments or an array; and when a refusal's WORDING is the assertion, check the wording.

## Instruments worth building

- **A counting TCP listener** — ~12 lines (accept, `SO_LINGER 0`, close, count to a file) — turns
  "how many attempts did it really make" into a number. It is what made round 4's F16 a finding
  rather than a suspicion, and it generalises the severing-proxy idea to any attempt/retry question.

  **`$QA/counter.rb` is CUMULATIVE and a driver cannot reset it.** It writes `"0"` once at startup
  and thereafter overwrites the file with its own running in-process total, so zeroing the file
  between probes reads garbage. Round 7 got 10, 11, 12, 18, 24, 30 out of it and briefly had
  construction-only appearing to make MORE connections than a full run. **Read DELTAS, or restart
  the listener per probe.**

- **A path-logging RST listener** (`$QA/pathcount.rb`) — the counter plus the request line, which
  is usually the question you actually have. A bare count cannot tell a retry from a window probe:
  round 7 measured **6 connections against 4 rendered attempts** and nearly filed the gap, when the
  attribution settled it instantly as `2 × GET /api/ps` + `4 × POST /api/chat` — four chat POSTs,
  four rendered ordinals, no hidden retries. Prefer it to `counter.rb` for anything phrased "how
  many of WHICH".
- **A severing proxy** — the same listener, but forwarding to the real endpoint and RST-ing after N
  bytes of response. Deterministic where killing a service is a timing race, and it leaves the
  operator's model server untouched. This is how F7 was found (control 1.9s vs >400s hung).
- **A logging pass-through proxy** — forward to the real endpoint and record start / first-byte / end
  per upstream request. This is the instrument for **concurrency**, which neither of the above can
  see: it is what turned round 6's F26 from "the model seems slow" into "the journaled request
  waited 35.8s for its first byte while an unjournaled sibling held the only slot", and it is the
  only way to count lain's real model calls against the journal's. `$QA/proxy.rb` ships with the
  sandbox; `failure-injection.md` §12 drives it.

## "Unreachable" is a claim about the bench, and it is checked, not assumed

Recorded because round 14 got it wrong four times in one round, and because the cost of the mistake
is invisible: a scenario written off as unreachable stops being a gap anyone can see, exactly like
one skipped by convention.

**The bench that is already up is the default answer.** `bench.md` brings up a local ollama with
`qwen3-coder:30b` resident, and most scenarios in `scenarios/` say in their own `Needs:` line that
this is all they want. Round 14 wrote "not driven — needs a model" against `subagents-and-backends`,
`memory-and-dogfood` and `rails-blog`, all three of which drive against exactly that bench, and
against `ollama-cloud-arm`, whose `OLLAMA_API_KEY` was in the repo's own `.envrc`. The second pass
drove all four and reached `rails-blog` §2, which thirteen rounds had not.

**Separate the two reasons, because only one of them is free to assert.**

| reason | how it is established |
|---|---|
| **budget** — "the round ran out of patience or wall-clock" | self-evident; say it and move on |
| **capability** — "this box cannot do X" | a CHECK, named in the findings beside the claim |

The capability checks are seconds each, and they are:

```bash
command grep -n 'Needs:' planning/qa/scenarios/<scenario>.md    # the scenario states its own preconditions
command grep -nE '^[[:space:]]*export[[:space:]]+[A-Z_]*(KEY|TOKEN)' .envrc   # names only -- NEVER print a value
command -v <the binary the scenario names>                      # rails, docker, cargo
curl -s localhost:11434/api/tags                                # is the local arm actually up?
```

**Grep for an `export`, not for the NAME — round 15 got the opposite answer from the loose form.**
This recipe used to be `grep -oE '[A-Z_]*(KEY|TOKEN)[A-Z_]*' .envrc`, which matches **comments**. On
this box that reports `ANTHROPIC_API_KEY`, out of a comment reading "This desktop has no
ANTHROPIC_API_KEY anywhere" -- so the check written to prevent a false *unreachable* manufactured a
false *reachable*, in a round that then had to disprove it three ways. A name in a file is not a key;
an `export` of it, or the variable being set, is. When it matters, test the variable rather than the
file: `[ -n "${ANTHROPIC_API_KEY:-}" ]`.

**A local model call is a budget cost, not a capability gap.** It spends patience and GPU seconds and
nothing else — no quota, no key, no network. Writing "needs a model" as though it were a wall is the
specific error to avoid; write "did not fit the round" if that is what happened, which is honest and
leaves the scenario visible as a debt.

**And read the scenario for the way around its own precondition before accepting it.** `rails-blog`
§2 wants tool results of real size and names `rails new` as the way to get them -- but the section
itself says "a non-minimal app, **or a directive that reads large generated files back**". Round 14
took the second clause, generated a tree, and reached a 120,045-byte tool result with no Rails on the
box at all. A scenario's stated subject is usually one way to satisfy its premise, not the only one;
the premise is what the round owes.

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
  later act measures a poisoned context (round 4, MODEL-1). **This rule has a corpus-shape cost,
  not just a driving cost (P10, findings round 8):** because every session is abandoned at the FIRST
  sighting, the corpus this bench accumulates can never contain a session where the model explains
  the syntax in prose without emitting it as a call — so a narrowed `<function=` detector can never
  be shown to catch a false positive a naive substring match would have missed. Keep restarting; know
  that this is why the comparison stays unmeasurable.

## What the local model does badly — do not re-derive this

`qwen3-coder:30b` behaviours that are neither lain defects nor interesting:

- **It emits tool calls as literal text.** `<function=web_search><parameter=query>...` and stray
  `</tool_call>` arrive as prose. Round 4 reproduced it out of a contaminated transcript and
  concluded that contamination was THE trigger rather than payload length — the same prompt that
  failed twice in a poisoned session succeeded immediately in a fresh one.
  **Round 8 overturned the "only when contaminated" half: it fired on a CLEAN transcript.** The
  session's entire history was two trivial one-word exchanges (`ping`, `pong`) with no tool calls at
  all, and the first substantive ask emitted `<function=` as assistant text, wrote no file and ended
  the turn; a restart plus the identical prompt then succeeded immediately. So contamination is *a*
  trigger and not *the* trigger, and **a fresh session is not protection** — the restart rule stands
  unchanged, but do not read a clean transcript as a reason to look for a lain defect instead.
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
