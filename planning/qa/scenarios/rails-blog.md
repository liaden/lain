# Scenario: a Rails blog (long-horizon, high-volume)

**Why this one exists:** bowling is a single small file. This scenario is the one built to reach
**tool-result size** the small scenarios cannot, over a run that stretches across **dozens of
turns** — so it is the natural home for the three things the small scenarios structurally cannot
reach:

1. **Compaction at scale** — filling the context until a compaction actually fires. Rounds 3 and 4
   both failed to reach this, making it the least-exercised path in the whole QA suite.

   **Round 15 correction: "hundreds of files" is no longer what `rails new` produces.** Rails
   **8.1.3.1** with `--skip-bundle` yields **78 files, 20 of them `.rb`, 440 KB** — the framework got
   smaller, not the scenario wrong. The premise still holds, but it is carried by tool-result
   **size**, not file **count**, so reach it the way §2's own second clause says (a directive that
   reads large generated files back) rather than by counting the tree. Round 15 hit 99.93% occupancy
   from a single 112 KB `read_file` — and see **F82**: at that point the compactable head was
   `head_bytes: 2`, because the oversized result sits in the tail `keep_last` retains. **A round that
   wants compaction to FIRE needs many medium results across many turns, not one enormous one.**
2. **Unbounded tool output.** `rails new` emits an enormous `bash` result; `list_files` on
   `app/`, `glob '**/*.rb'` and `read_file` on a schema are all large. Fourteen tools bound nothing
   today, and `arXiv:2508.21433` measures observation tokens at ~84% of an average agent turn.
3. **The approval gate under volume** — many `bash` calls per turn, which is exactly the shape that
   wedges on a second gated call in one turn.

**Cost:** expensive. Several sessions. Run it when the question is *context economics*, not when the
question is *does the loop work*.

**Needs:** `bench.md` up, and a working Rails toolchain — **check first, and if it is absent INSTALL
it rather than improvising a substitute mid-run.** A Sinatra app does **not** work here; it is too
small to be this scenario, and swapping it in produces a null that reads like a result.

```bash
gem list -i rails && rails --version        # both, not just the first
```

### Standing up the environment, measured 2026-08-21

`rails` was absent on this box for every round up to and including round 8, which is part of why this
scenario had never run. The recipe below took **~4 minutes** total and is contained entirely inside
the QA sandbox, so it is disposable with the sandbox and never touches the operator's own gems:

```bash
. "$QA/env.sh"
mkdir -p "$QA/gems"
export GEM_HOME="$QA/gems"
export PATH="$QA/gems/bin:$PATH"
gem install rails --no-document          # 32 gems, ~3 min; writes only under $QA
```

**Then put `GEM_HOME` and the `PATH` entry into `$QA/env.sh` itself, BEFORE the tmux server is
started.** This is the step that is easy to miss and silent when missed: `PaneCommand::PANE_ENV` is
an eleven-name `LAIN_*` allowlist, so a `GEM_HOME` exported in the shell that runs `lain up` does
**not** reach the chat pane — the model's very first `bash` call comes back
`rails: command not found`, which reads like a model failure or a broken tool layer and is neither.
It is the same `PANE_ENV` mechanism `method.md` describes for `XDG_*`, one variable over. (This
sentence used to compare it to `LAIN_DESKTOP`, a variable deleted with the desktop notifier in
`c40ab419`.) The `$QA/gems/bin` entry goes **before** `$QA/shim`, and the gate to run beside the
`XDG_*` one:

```bash
for p in $(tmux -L "$QA_SOCK" list-panes -a -F '#{pane_pid}'); do
  tr '\0' '\n' < /proc/$p/environ | command grep -c "^GEM_HOME=$QA/gems"   # every pane must report 1
done
```

**What is needed beyond the gem, all present on this box and all worth checking rather than
assuming:** a C toolchain (`gcc`/`make`) because `sqlite3` is a native gem, `sqlite3` itself, and
`node`/`yarn` (mise-provided here) for anything not `--minimal`. Verified end to end rather than
inferred — a full `rails new t2 --minimal` completed in **19s**, the native gems built, and
`bin/rails runner 'puts Rails.version'` printed **8.1.3.1**. `rails new t1 --minimal --skip-bundle`
generates **80 files**, which is the volume floor this scenario is built on.

**Round 17's two refinements, both measured.** Rails 8.1.3.1 installed in **26 s**. And a
`.bundle/config` with a `path` inside the subject app makes `bin/rails` work with **no `GEM_HOME` in
lain's environment at all** — the app's own bundler finds its gems — which sidesteps P9 (a sandbox
`GEM_HOME` reaching `exe/lain` and re-locking lain's `Gemfile.lock`) rather than guarding against it.
Prefer it to exporting `GEM_HOME` into the tmux server.

*(One incidental: gem installs on this box fire a global `ctags` post-install hook that emits several
`ctags: Warning: … TOML parser is broken` lines per gem. Harmless, but it pads any `bash` result that
installs a gem — keep it in mind when reading §2's tool-result sizes, and do not file it as lain
disclosing something odd.)*

---

## The subject

A blog with three features, stated to the model in one directive prompt:

1. **Posts** — title, body, published-at; index / show / create / update / destroy.
2. **Comments** — belonging to a post, with author name and body; created from the post's show page.
3. **Tags** — many-to-many with posts, and an index filtered by tag.

Plus: **a passing test for each feature**, in whatever framework the app was generated with.

**Definition of done:** `bin/rails test` (or `rspec`) exits 0 with at least one test per feature,
and the three routes resolve. The driver runs the suite — the model's claim that it passes is not
the grading instrument, exactly as in `bowling-ruby.md`.

This is deliberately more than a 3B-active MoE will finish. **That is fine and is not the
measurement.** The measurement is what the harness does across a long, file-heavy, failure-prone
run. Record how far it got; do not coax it past the mechanical escalation trigger.

## What to watch, in order of value

### 0. The precondition that decides whether §1 measures anything

**Drive this act with `--compact-strategy elide-tools+summarize-conversation`, and only over tools
that return REAL BYTES.** Both halves of that sentence are load-bearing, and the second is a trap
that has already cost this chunk real time.

```bash
lain chat --provider ollama --model qwen3-coder:30b \
     --compact-strategy elide-tools+summarize-conversation --summarizer-provider ollama
```

**Round 17 could not reach this act, and the two defects that stopped it are fixed as of
2026-09-14.** Session 1 stalled for good on F89: a `bash` result carrying one non-ASCII byte (a
test runner's `✅`) tore the ask after the command ran (F88), left an unanswered `tool_use` on the
chain, and every later derivation refused it (`derivation_refused … the tool_use "call_…" in
messages[28] is never answered`, `compaction stalled ctx 94%`). Now a result's bytes are made
committable before commit (valid UTF-8 is re-tagged; invalid bytes refuse by name), and a tear
answers every call before the next ask commits on top. **Re-check both before trusting §1:** a
`run_interrupted reason=torn` whose head is a `tool_use`, or any `derivation_refused` naming an
unanswered call, is F89 back. **Already-damaged journals are not healed** (the chunk's Open decision
3): do not resume round 17's first `rails-blog` session and expect it to compact — start fresh.

That pair is the one to reach for because the two strategies are **exact complements by
construction** — both ask one predicate which messages carry a tool block — so they partition a span
instead of fighting over it. Any other pairing may not; `elide+summarizing` resolves happily and then
raises `Overlap` at the first compacting turn, which is a legitimate thing to drive here once,
deliberately, since this is the only scenario that reaches a compacting turn at all.

**Why the tool results must be large, measured rather than assumed.** The elide half writes a
per-message attestation of about **230 bytes** — role, digest, byte count. Over `"ok"`-sized tool
results the attestation is *bigger than what it replaced*, so `shrinks?` is **false on every turn**;
it turns true around **2 KB** of tool result. The driver is the elide half, not the oracle half.

And a run that fails to shrink does not merely fail to demonstrate the strategy — **it pays for a
model call and throws it away, every turn.** The derivation asks the oracle first and checks whether
the result would shrink second, so a refused turn has already been billed. Measured on a three-turn
refused run:

```
oracle_answer => 4   context_derived => 3   compaction_decision => 3   compaction => 0
```

Four answers bought, none shipped. Read exactly that shape before trusting anything in §1:

```bash
ruby -rjson -e 'c=Hash.new(0); ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  c[r["type"]]+=1 if %w[compaction_decision compaction context_derived oracle_answer].include?(r["type"])}; p c' "$JOURNAL"
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="compaction_decision";
  puts "compacted=#{r["compacted"]} shrink_refused=#{r["would_not_shrink"]}"}' "$JOURNAL"
```

**`would_not_shrink: true` on every decision with `compaction => 0` is the signature of a scenario
that was too small, not of a broken strategy.** `rails new`, `bundle install`, `read_file` on a
schema and `glob '**/*.rb'` all clear 2 KB easily — which is exactly why this act lives here and not
in `bowling-ruby.md`, where it would produce that null every time.

### 1. Compaction, at last

Do this **early in the act, not last** — it is the point of the scenario.

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "#{r["ts"]} win=#{r["window_tokens"]} used=#{r["used_tokens"].inspect} prov=#{r["provenance"].inspect} sig=#{r["signals"].inspect}" \
    if r["type"]=="compaction_decision"}' "$JOURNAL"
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; puts r["type"]}' "$JOURNAL" | sort | uniq -c
```

Expected once occupancy climbs: `signals` stops being `[]`, a compaction is warranted, and
`.lain/state.json` `compactions` increments. Then:

- Does the summarizer tier that fires match the one the flags asked for
  (`--compact-strategy`, `--summarizer-provider`, `--summarizer-model`)?
- Does a compaction **rewrite history more than once** for one crossing? (Round 2's F-series found
  compaction firing on a *provisional* window and rewriting three times.)
- Does occupancy actually fall afterwards, and does the HUD's `ctx N%` follow it down?
- Does the prompt cache go cold at the rewrite, and is that visible?

**Then read what the composed strategy actually did to the history, which is the check nothing else
in this bench can make.** Pull the rewritten span out of the derived context and confirm the split:

- **tool-carrying messages became attestations** — one line each, of the shape
  `[<role> <digest> <bytes> bytes] …`, with the elision prose after it;
- **conversational turns survive verbatim and in position** — not summarized, not reordered;
- a **lone** conversational turn sitting between two tool runs is *retained*, not summarized. The
  strategy deliberately declines to pay a model call to turn one message into one message, so an
  `oracle_answer` for a single-message run is a defect, not thoroughness;
- the oracle was asked **once per claimed run**, not once per span — so the per-turn multiplier is
  N, not 1, and a session with many conversational stretches costs proportionally. Count
  `oracle_answer` records against the number of conversational runs in the span rather than against
  the number of compactions.

**What wrong looks like, in order of how easily it is missed:** an `Overlap` raise mid-turn (the two
selections have stopped being complements — that is the failure T7's shared predicate exists to make
impossible, so it is a serious finding, not a flake); attestations covering conversational messages
too (one predicate answered inconsistently); and the quiet one — `compaction => 0` with
`oracle_answer` climbing, which is §0's paid-and-discarded shape and means the act is measuring
nothing while spending on every turn.

### 1b. The cut is sticky, the history never un-compacts, and an over-window prompt is refused

**New 2026-09-14, and the part of this act round 17 most wanted.** Round 17 measured compaction
latching on a completed to-do step and then **un-compacting** — a `todo_write` that completed
nothing took the next request from 22 to **109** messages (F94). The fix keeps the Timeline
lossless and makes the *decision* sticky: a committed compaction records a **cut** (the source digest
it collapsed up to), the replacement spans that range turn after turn, and only a new signal over a
droppable span after the cut advances it. Drive, once a cut has committed *(predictions, not yet
driven — this is integration check 7 of the discharging chunk)*:

- **`todo_write` completing nothing does not un-compact.** The next `request_sent`'s message count is
  not greater than the previous one's plus the new turns. A jump back to the full history is F94.
- **One `compaction_cut` record per advance**, carrying the cut digest, the span endpoints and the
  replacement's summary text; every later `context_derived` names the same cut and span, and the
  replacement's bytes are identical across renders once its summary has landed.
  `plan_step_completion` fires on ONE decision per rising `todo_write`, not on every render after it.
- **`/rewind` below the cut retreats it.** The next request carries no replacement for the abandoned
  range and the next `context_derived` names no cut (or an earlier recorded one still on the chain).
- **`--resume` renders the recorded replacement without re-summarizing.** The first resumed request
  carries the same replacement bytes as the recording's last derived render, and no summarizer
  request precedes it.
- **An over-window prompt is refused, not truncated.** Lain now asks ollama not to truncate, so a
  prompt past the loaded context comes back refused with the server's own count. *Driven
  2026-09-14* against the built binary (a 160 KB prompt, 32,768-token context):
  `error: not answered: ollama refused this prompt at 164997 tokens against the 32768-token context
  it loaded, so no model saw it, and it was withdrawn. Nothing older can be compacted yet, so make
  room with /rewind past the turn that grew it, /unpin a pinned turn, or a narrower read.` — with one
  `window_pressure` record (`kind: over_window`, `source: ollama`, `prompt_tokens`,
  `window_tokens`) and `run_interrupted` carrying `reason: over_window`. When the refused render
  left something droppable, the tail reads `. Make room with compaction (that count is now the
  reading it measures), /rewind, /unpin a pinned turn, or a narrower read` instead *(prediction,
  not yet driven)*, and the refused count becomes the reading compaction fires on. Round 17's F90
  was the opposite: a 330 KB request silently truncated to 16,386 tokens, read as 50% then 16%
  occupancy, and a model that had lost its tools.

  **"`window_pressure` must be absent on every ordinary turn" is no longer the rule** — round 18
  turned this refusal into a **signal** the compaction path acts on rather than an outcome. A
  refusal on a stuck source now triggers the handoff below, so a long session may legitimately
  carry one `window_pressure` followed by a `compaction_cut` of `kind: handoff` and an **answered**
  ask. What is still a finding is a `window_pressure` with nothing after it, or an `input_tokens`
  that falls below the previous turn's with no record explaining it. Two fields to read while you
  are there: `stands_on` names the turn the reading is believed on, so a live view tags it the way
  the agent does rather than inferring it, and `spawn` names the child whose prompt it was (nil for
  the run's own ask) — a child's over-window refusal in a session with subagents is expected, not
  the parent's.

- **When no cut can make room, one handoff answers the ask.** This is the fallback round 18 added,
  and `rails-blog` is the scenario long enough to reach it. It fires only after the provider has
  refused a prompt whole **and** the source is stuck — nothing droppable, or the refused render
  already held the newest cut — and it spends exactly **one** summarizer call. Drive the session
  until it happens and read four things:

  1. one `compaction_cut` with `"kind": "handoff"`, superseding every cut that held;
  2. the ask **is answered** — the handoff is a fallback that keeps the question, not a refusal;
  3. the state document carries all five sections (`Goal`, `Progress`, `Files and decisions`,
     `Open todos`, `Next step`) and sits where the replaced history began, with the later ranges
     collapsing to empty content rather than to a second summary;
  4. what survives beside it is exactly the current ask, an unanswered `tool_use`/`tool_result`
     pair if there was one, and the pins — nothing else.

  Then `--resume` and confirm the first resumed request is **byte-identical** to the live one: a
  handoff is recorded like any other cut and replayed like one, with no second summarizer call.
  And nothing of it may reach project memory — grep the project's `store.ndjson` for a phrase from
  the document; a hit there is the one finding this check exists for.
- **Summaries no longer re-key the runner.** Round 17 measured every summarized tool result
  reloading ollama twice under `LAIN_NUM_BATCH=2048` (29.4 s against 1.6 s, F95). A secondary call on
  the chat's own model now carries the chat's `num_batch`/`num_ctx`, visible in its journaled
  `request_sent.extra`. *(Prediction, not yet driven.)* A ~30 s `provider_wait` per summary is F95
  back.

**Held replacements re-collapse, since round 18**, so the open decision this section used to
record — ten cuts under `summarize-conversation` rendering ten summaries — is closed and its old
expectation is now the finding. Once more than one cut is held, a signal with nothing newly
droppable commits one `collapse` cut over what they render between them, superseding them all.
Drive it: reach two held cuts, then keep going, and read the `compaction_cut` records —
`"kind": "collapse"` with at least two addresses in `supersedes`, the rendered prompt shrinking
rather than accumulating, and a collapse that would not shrink declined as `would_not_shrink`
like any other. Resume afterwards and confirm the render is byte-identical; replay refuses a
collapse naming a cut its file lacks, so a resumed session that renders the superseded summaries
again is the finding.

One open decision does still stand, so do not file it: a `/pin` on a turn inside a held range is
silently ignored.

### 2. Tool-result volume

Capture the size of the largest tool results in the session:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="turn";
  Array(r["content"]).each{|b| next unless b["type"]=="tool_result";
    puts b["content"].to_s.bytesize }}' "$JOURNAL" | sort -rn | head
```

`rails new` alone should produce a result orders of magnitude past anything bowling generates. Note
which tools produced the top ten, and whether any of them disclosed a cap. Today only `grep`,
`ast_search`, `web_fetch` and `ast_dump` bound at all, and only by cap-and-disclose.

**Round 8: this premise was NOT reached, even in the scenario built to reach it.** Under
`--minimal`, the largest single tool result across the whole session was **4,713 bytes**
(`rails new`), the total across 114 tool results was **40,306 bytes**, and **zero** results
disclosed a cap — nowhere near the bound-firing volume this section expects. **§1's volume came
from turn COUNT, not result SIZE**: compaction fired eleven times on a transcript built from many
small tool results, not from any single large one. Do not read "compaction fired" as evidence this
section's premise was exercised — it was §1's, not §2's, and §2's is still unreached. A non-minimal
app, or a directive that reads large generated files back, is what would actually drive this.

### 3. The approval gate under volume

A `rails new` run and a `bundle install` are both gated `bash`. Expect several approvals per turn —
which is the trigger shape for a second-approval wedge. **In a cockpit the chat pane no longer draws
a `[y/N]` for them** (since 2026-09-14): each parked call is one arrival line, and the answer is
`:LainApprove` in `lain://approval` or a deliberate `/approve` (`cockpit-surfaces.md` §5). Read
`b:lain_approval_calls` over RPC (`method.md`) before approving, and check every arrival line has
a row — a parked call with no row, or a row with no arrival line, is the wedge's new shape.

Check `.lain/config.toml` between acts. A model that talks you into "always" for `bash` in a Rails
tree has just pre-approved arbitrary shell for the rest of the session.

### 4. Session lifetime

This scenario will hit the model-call ceiling. Track it deliberately:

```bash
ruby -rjson -e 'n=0; ARGF.each_line{|l| r=JSON.parse(l) rescue next; n+=1 if r["type"]=="turn_usage"}; puts n' "$JOURNAL"
```

and check for `run_interrupted` records with nothing rendered. Restarting the session mid-scenario
is expected here; say in the findings which act boundary you restarted at, because it changes what
the compaction reading means.

### 5. What the broken cache cost, in dollars

`lain friction SESSION` gained a fourth analyzer this chunk, and **this is the only scenario that
can exercise it honestly**: `Provider::Mock` reports all-zero cache fields, so a mock-backed or
`--dry-run` reading passes while asserting nothing (`method.md`). It needs a real session against a
real endpoint, and it needs one that broke its prefix — which a long compacting run does by
construction.

```bash
lain friction "$JOURNAL"
```

Read the `cache_waste` line, and read it as a *pair of figures*, never as one:

    cache_waste: at most <N> tokens re-billed across <K> prefix break(s), <cost>; <M> tokens served
    from cache over <C> priced main-agent call(s), <saved>: look at what edits the prompt PREFIX
    mid-session -- a Workspace or reminder block that changes every turn, or compaction firing while
    the cache was still warm

Four things to check, and three of them are about honesty rather than arithmetic:

- **"at most" is load-bearing.** The figure is an upper bound: a call that both broke its prefix and
  appended new messages has its whole cache write counted. A report stating a bare figure has lost
  the error's direction.
- **A clean session says so explicitly.** With no prefix break the section must still appear —
  `cache_waste: none -- no prefix break was re-billed; …` — because an omitted section and a clean
  session are indistinguishable to a reader.
- **What the cache BOUGHT is always reported beside what it wasted.** A waste figure alone is an
  anti-metric by this repo's own rule: an agent that reads nothing wastes nothing. If the "tokens
  served from cache" half is missing, that is the finding — **except for a cacheless provider,
  since T11 (see below): there, a missing "tokens served from cache" half is correct output, not
  a defect to file.**
- **`/model` mid-session must not be charged as waste.** Drive one deliberately — a model switch is
  indistinguishable from a real prefix edit unless the journal is segmented per model, and `/model`
  is a normal move. The report must say so:

      <n> model switch(es) counted, not charged -- <reason>

  A waste figure that jumps by roughly a whole prefix at the switch is the metric inflating, which
  is the single most likely defect in this analyzer.

Two more, both expected rather than wrong: a local model is **unpriced**, so the dollars are absent
and the report says `dollar figures exclude qwen3-coder:30b -- no price recorded` rather than
printing a confident `$0.00`; and every figure covers the **main agent only**, since subagent turns
are outside the journaling middleware — the wording says `priced main-agent call(s)` for exactly
that reason, so do not reconcile it against a fleet's total.

**A third shape, since T11 (verified by its panel) — and it is the shape THIS scenario now
produces, not the `none -- no prefix break was re-billed` line quoted above.** `rails-blog` always
drives `qwen3-coder:30b` over ollama, which is exactly the cacheless provider F49 named: ollama has
no prompt caching at all, so the old two-shape reading (a break, or a clean `none`) computed a
confident `$0.00`/`none` over fields that were structurally never going to be non-zero. T11 closed
that by making the report say so directly instead of computing a zero. **Expect the report to name
the provider as not caching, and to quote no dollar figure at all** — not a bound of zero, and not
the `none -- no prefix break was re-billed` sentence this section used to expect. Read this as the
shape to look for when driving §5 today; a driver still expecting the two-shape table above will
read a correctly-working fix as a regression. **The exact wording above is descriptive, not a
literal quote** — `lib/lain/friction/cache_waste.rb` and `report.rb` do not carry T11's change on
this repo's `main` as of this note, so check the actual string `lain friction` prints once T11
lands rather than grepping for these words verbatim.

**Then grep the report for anything it must not contain.** It is built from journal records and may
carry digests, token counts and dollars — never message content, never a path. A report is pasted
into an issue; this is the check that keeps it safe to paste.

## What this scenario does NOT test

`--isolation worktree`. A Rails tree is the obvious place real-`git` isolation seams would show,
and no scenario drives them. Worth its own scenario when isolation backends matter.
