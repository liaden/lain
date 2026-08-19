# Chunk — provider admission, and the surfaces that carry a pending item

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson
panel-reviewed: 2026-08-19 (6 blockers, 7 should-fixes, 5 nits — all discharged; see *What the panel changed*)

## Intent

Discharge QA round 6 (`planning/qa-findings-round6-2026-08-19.md`) and the procedure trial that
followed it, at the level of causes.

**One finding is an absent concept and the rest are bypassed ones.** Nothing in lain owns a
provider's *capacity*, so the harness puts two requests on a one-slot server and then reads the
silence it caused itself as a dead stream (F26). The others are places where the design's own answer
already exists and one caller does not use it: the command registry, whose
`#dispatch(text, env) { fallthrough }` already parameterises exactly the decision the reply prompt
re-implements as string equality (F27); the local-rescue convention every tool but two follows, whose
absence leaks a Ruby class name into text only a model reads (UX9); and `Up#create_session`, which
creates a tmux session and declines to say how big it is, so a fresh server yields an 80×24 cockpit
where the nvim RPC deadlocks.

Then the surfaces. `lain://inbox` and `lain://approval` already list every pending item correctly —
verified during grounding, and **not** what this chunk changes. What they cannot do is show an item's
*contents* without leaving the buffer: an approval row is one `input.inspect` line with no fold
surface at all, which is how a human ends up approving a command they did not read, against
`planning/qa/method.md`'s standing rule.

Roadmap line: the QA-discharge chunk following the causal-fold chunk, closing the first round that
reached provider concurrency and the pending-item surfaces.

## Grounding

Verified 2026-08-19 against the working tree by five parallel exploration passes, QA round 6, its
procedure trial, and a panel review that traced production wiring independently. **Where this section
contradicts the findings docs, this section won** — it did so four times, listed at the end.

**Provider capacity (F26).** `Oracle::Eager#fire` (`lib/lain/oracle/eager.rb:69-97`) spawns
`task.async(transient: true)` and returns immediately; reached from
`Effect::Handler::Summarizing::Observer#summarize` (`lib/lain/effect/handler/summarizing.rb:81-85`)
via `Agent::ToolRunner#observe_all` (`lib/lain/agent/tool_runner.rb:145-148`). The agent loop then
re-enters `call_model` (`lib/lain/agent.rb:473-478`). That ordering is the measured ~25 ms gap.

**Nothing bounds concurrency anywhere.** No production hits in `lib/` for `Semaphore`,
`max_concurrency`, `num_parallel`, `n_slots`. `Oracle::Model`'s doc (`lib/lain/oracle/model.rb:16-17`)
states the position: *"Overlapping N model calls is the CALLER's job"* — and no caller takes it.

**There are SIX provider construction sites on the chat path, not four, and one takes no injection.**
This is why admission belongs in the provider rather than in `Backend`. Five route through
`Backend#provider` (`lib/lain/cli/backend.rb:193-199`): the turn
(`cli/wiring/agent_build.rb:96,191`), every subagent (`cli/wiring.rb:475` →
`cli/wiring/toolset_build.rb:316`), the eager oracle (`backend.rb:386,546` →
`backend/summarizer.rb:42` → `#summarizer_provider`, `:205`), the span summarizer
(`backend/span_summarizer.rb:109`), and the window probes (`backend/window_book.rb:273`,
`backend/num_ctx.rb:93`). **The sixth does not:** `cli/wiring.rb:231` builds
`Approval::SecretSurface` whose `Oracle::SecretRead.tier` constructs
`Provider::Ollama.new` **bare, with no `api_base`** (`lib/lain/oracle/secret_read.rb:134`), resolving
to `DEFAULT_API_BASE = "http://localhost:11434"`
(`lib/lain/provider/ollama/transport.rb:32`) — the same one-slot endpoint. It runs on its own surface
fiber racing the human. **Taking a provider seam there is forbidden**: `secret_read.rb:19-38` records
that injecting a provider is the security defect the rung exists to prevent, and `:125-128` notes a
spec pinning its parameter list. So admission must be reachable *without* injection.

**There is no per-tier `api_base`.** `exe/lain:416` declares one `--api-base` ("ollama provider
only"); `backend.rb:322` reads the single `@options[:api_base]` and `#summarizer_provider` delegates
to the same `#provider`. So a key of "api_base" is both unconstructable as a *difference* and wrong
where it matters: `--provider anthropic --summarizer-provider ollama` gives `api_base == nil` on both
sides, which would serialise a hosted turn behind a local summary. **The key must be the resolved
endpoint**, which each provider already computes for itself.

**The stall clock is correct and must not change.** It arms on the first tick and not before —
`@monitor ||= start_monitor` inside `#suspend`
(`lib/lain/provider/http/streaming/faraday_handlers.rb:397`), reached from `#receiving` (`:346-351`),
called per body chunk. `@suspensions` (`:295,396,404,461`) counts the *consumer's* processing.
Grace is `stream_stall_timeout`, 30 s (`lib/lain/provider/http/configuration.rb:132`);
pre-first-byte silence is bounded only by `request_timeout`, 300 s (`:73`), as `:86-90` states
independently for a server that accepts and sends nothing. Its premise (`configuration.rb:112-124`)
is *"once tokens are flowing, a 30s gap … means the stream is dead rather than slow"* — true unless
we put another request in front of it. QA confirmed the first-byte exemption by holding the first
byte 40 s through a proxy: no stall. **Admission must therefore wrap `Provider#complete` and nothing
below it** — `Provider::Ollama#complete` (`lib/lain/provider/ollama.rb:140-142`) encloses the whole
stream, and `#watch` is entered inside it, so a waiting request has no clock installed at all.

**A queued request would otherwise be unbounded, and the holder's ceiling is 20 minutes, not 300 s.**
`Async::Semaphore#acquire` has no timeout and `#wait` loops unconditionally. Meanwhile faraday-retry
is installed *inside* the connection (`provider/http/connection/middleware_stack.rb:141`,
`retry_exceptions` `:176-179`) and `:64-70` records the consequence explicitly: `request_timeout`
**four times**, because `:post` is in the retry methods. So one hung endpoint can hold for ~20 min.
This is why admission takes a deadline and an off switch rather than blocking forever.

**The reply prompt (F27).** `HumanReplies::Reply#read` (`lib/lain/cli/human_replies.rb:967-972`) is
`return [line, item] unless line.strip == "/inbox"` — a bare literal. `Command::Registry` is never
referenced in `human_replies.rb`. The registry's seam is already right:
`Registry#dispatch(text, env)` (`lib/lain/cli/command/registry.rb:46-49`) runs or yields;
`#command_invocation` (`:111-114`) requires an `inline?` parse of a registered name.
`Skill::Invocation::INLINE` (`lib/lain/skill/invocation.rb:69`) is anchored at both ends — **one
command per line, no splitting anywhere.**

**But `/inbox` at the reply prompt is NOT a session command and must stay item-scoped.**
`Reply#for`'s docstring (`human_replies.rb:930-941`) records that draining *the oldest* set instead of
the parked one was a defect and was fixed: *"the prose answer NAMES the questions it answers, so the
wrong set received a reply naming another set's ids and the set the human actually read stayed
pending."* `Command::Inbox#call` (`lib/lain/cli/command/inbox.rb:37-40`) reaches
`drain_at_prompt` → `Reply#at_prompt` (`:361`) → `drained(answering: @inbox.oldest)` — **the head of
the list**. Routing `/inbox` through the registry therefore *reintroduces a fixed bug*.
`Command::Inbox#serves_replies?` (`inbox.rb:27`) exists precisely because a loop started around it
would race the drain for one stdin — so it is also the honest predicate for "this is a reply
surface, not a session command".

**Commands returning a Repl action cannot work in the reply loop.** `Command::Quit#call` returns the
symbol `:quit` (`lib/lain/cli/command/quit.rb:17`), acted on at the `you>` layer.
`AnswerLoop#exchange` (`human_replies.rb:621-630`) discards everything but `(answer, item)` and wraps
its body in `rescue StandardError`; there is no action channel out of the reply loop.

**Tool error text (UX9).** `Effect::Handler::Live#dispatch` (`lib/lain/effect/handler/live.rb:67-79`)
ends `rescue StandardError => e; Tool::Result.error("#{e.class}: #{e.message}")` at `:78`.
`ContractViolation` (`lib/lain/tool.rb:31`, message at `lib/lain/tool/contracts.rb:88,95`) and
`InvalidInput` are the only two a tool subclass structurally cannot rescue, because `Tool#call`
(`lib/lain/tool.rb:134-144`) raises them around `#perform`. Every other refusal rescues locally
(`run_skill.rb:84-96`, `write_file.rb:91-92`, `bash.rb:188-195`, `web_fetch.rb:358-387`) or is
returned rather than raised (`lib/lain/tool/bounds.rb:166-189`); `bounds.rb:78-82` names this exact
hazard and routes around it by hand. **No spec pins the class-prefixed wire string.**
`spec/lain/effect/handler_spec.rb:84` pins `/precondition failed/` in the content;
`contracts_spec.rb:29,59` and `tool_spec.rb:162` pin the `precondition failed for X:` **label** on the
raw exception — the label survives, only the class prefix goes. **`Live`'s only outlet is `@channel`
(`live.rb:31-34,68`), and production passes `LiveViews.tool_output(channel, views)`
(`cli/wiring/agent_build.rb:49-50`), described there as going to the TTY and editor and
*"never to the journal"*** — so the class name cannot be journaled from this seam.

**Session geometry.** `Up#create_session` (`lib/lain/cli/up.rb:735-741`) issues `new-session -d -s …`
at `:738` with **no `-x`/`-y`**; nothing in `up.rb` or `up/cockpit.rb` sets `default-size` or resizes,
and `configure_session` (`:834-840`) sets only status options. A fresh server therefore takes tmux's
80×24 default. **No spec asserts the geometry `Up` requests** (`up_spec.rb`'s `-x 80 -y 24` at `:376`,
`:422` is the spec's own scaffolding). Reproduced in the trial: 80×24, 40×24 panes, nvim RPC hung
until killed. Note tmux's default `window-size latest` means `-x/-y` governs while the session is
**detached** — which is exactly when nvim boots.

> **CORRECTION — 2026-08-19, review panel, and it weakens this card's premise.** Two claims above do
> not survive checking. (a) The *causal* half — "nvim RPC hung" *because* of 40×24 — does **not**
> reproduce: on nvim 0.12.4 a `nvim --clean --listen` in a real 40×24 tmux pane serves RPC and answers
> `&columns` immediately, and four `botright vsplit`s (the plugin's own layout primitive,
> `init.lua:191`) succeed at 40 columns with no `E36`. So "40×24 is below nvim's usable minimum" and
> "that is why the RPC never answered" are both unestablished. T6's widening remains correct on its
> own merits — a 40-column editor pane is not a usable cockpit — but **it may not have fixed the hang
> QA round 6 met, and the root cause of that hang is now an OPEN question.** A later round must not
> read this chunk as having closed it. (b) The invariant is "true at **creation**", not "true while
> detached": the first attach by an 80×24 client shrinks the window and detaching does **not** restore
> the stated geometry, because `window-size latest` keeps the last client's size. Harmless for
> `lain up`, which creates, splits and boots nvim before anything attaches.

**Desktop consent.** `Notify.for` (`lib/lain/notify.rb:184-193`) gates on
`consented?(desktop) && on_path?(command)`, reading `LAIN_DESKTOP` directly via `ENV.fetch` with a
hard `OVERRIDE` (`:160`). `PANE_ENV` (`lib/lain/cli/up/pane_command.rb:29-34`) is scoped by its doc
(`:24-28`) to *"every name `{EnvDefaults}` reads, and only those"*, is an allowlist for a stated
reason (`:134-138`), and is **mechanically pinned** by `spec/lain/cli/up_spec.rb:723-733`. A
counterpart list already exists — `PaneCommand.scrubbed` (`:36-68`). **`lain up PATH -- --no-desktop`
already works**: trailing argv is Shellwords-joined into the pane command (`:74-76`).

**The pending surfaces.** `InboxView#render` (`lib/lain/frontend/neovim/inbox_view.rb:299-304`) and
`ApprovalView#lines_of` (`lib/lain/frontend/neovim/approval_view.rb:359-363`) already list **every**
pending item and re-render the shorter set when one is answered;
`approval_view_spec.rb:311-322` pins two simultaneous rows. **Addressing is by POSITION, in two
independent places, and both break under a multi-line item.** Ruby: `ApprovalView#row_at`
(`approval_view.rb:321-324`) is `@renderings.fetch(generation)[index - 1]`. Lua: `render` passes
`parked.size` as `rows` (`approval_view.rb:347`), stored as `b:lain_approval_rows`
(`runtime/62_approval.lua:90`), and `:124` sends **nothing** for a line beyond it — `:71-75` states
that silence is deliberate. `lain://approval` is absent from `RECORD_START`
(`runtime/05_records.lua:42-58`) so it has no fold surface at all; `INBOX` is present but every fold
spans one line. **And the inbox's one-line row is load-bearing**: `inbox_view.rb:317-325` says it is
folded onto one line *"for the sharper of that fold's two reasons: `{Renderings}` indexes digests by
POSITION, so a two-line row would send `<CR>` to a set the human did not choose"*, with
`RenderQueue#checked_lines` as the transport backstop that *"refuses rather than repairs"*.
`runtime/70_inbox.lua:69` gates `<CR>` on the same `RECORD_START[INBOX]` predicate T12 must extend.

**Where grounding overturned the findings docs.**

1. `PANE_ENV` is not a hand-maintained drifting list — it is pinned by a drift spec, and
   `LAIN_DESKTOP` sits outside it deliberately.
2. F24's *buffer* multiplicity is spec-proven; only the **notifier** half is unverified.
3. "Journal the oracle's request" collides with `chronicle.rb:182-189`; the telemetry here is a
   *wait* record instead.
4. The findings' fix-shape for F26 said a spec against "a one-slot fake provider" would pin it. It
   would not pin the sixth construction site, which takes no injection at all — the panel found it by
   tracing production wiring, and it is why admission moved into the provider.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`.
- **`exe/lain` is orchestrator-owned for this chunk.** T7 and T11 each need a line in it, and it is
  the file `up_spec.rb:723-733` scans; a card editing it directly can redden that drift spec for
  reasons unrelated to its own work.
- Never name a `.toml` on a `rubocop` command line (CLAUDE.md); a bare `bundle exec rubocop` is safe.

## Open decisions

1. **FG1 is deliberately not fixed in code.** `lain chat --prompt` continues to exit 0 when the ask
   fails: `--prompt` is a REPL *seed* (`lib/lain/cli/repl.rb:55-58`), not a batch mode. Ruled
   2026-08-19 — the non-interactive case does not justify new CLI surface. T11 records it and corrects
   the docs implying `$?` is meaningful. Reopen only with a named consumer.
2. **T8 builds test-only machinery and is deliberately unreachable from production.** The local model
   cannot produce two simultaneous pendings, so the notifier's fan-out is otherwise untestable.
3. **Default admission width is 1 per resolved endpoint, not probed.** Reading a server's real
   parallelism is out of scope: it is a provider-specific probe on a path that must stay synchronous,
   and 1 is correct for every local server this bench has run. **`LAIN_PROVIDER_CONCURRENCY=0`
   selects the Null admission** and is the documented escape hatch for a session admission has
   wedged; `provider/http/configuration.rb:127-131` is the house pattern for an env-only off switch.
4. **The eager oracle never waits.** It uses a non-blocking try-acquire: if the endpoint is busy the
   summary is **skipped**, not queued. This preserves `Oracle::Eager`'s stated contract
   (`eager.rb:45-47`, *"the turn that produced `text` never waits on the oracle"*) and avoids the
   worse degradation — a queued fire reaped at teardown burns its digest for the whole session
   (`eager.rb:73-74`, `agent/tool_runner.rb:115-120`) and `Compaction::SummarySnapshot` reads
   absent-as-miss, so nothing would raise. A skipped summary is a miss the record already models.
5. **`/inbox` stays item-scoped at the reply prompt and is NOT dispatched through the registry.** It
   is a reply surface, not a session command; dispatching it reintroduces the defect
   `human_replies.rb:930-941` records as fixed. T4 expresses the exception through
   `Registry#serves_replies?` (`registry.rb:68-72`) rather than a string literal.
6. **Commands that return a Repl action are out of scope at `human>` and are refused by name.**
   `Command::Quit#call` returns `:quit` (`command/quit.rb:17`) and the reply loop has no action
   channel (`human_replies.rb:621-630`). Building one is a separate chunk. T4 refuses such commands
   with the existing `@tty.render_error` shape rather than silently doing nothing.
7. **An unexpected tool error's Ruby class is lost from the model-facing text and is not journaled.**
   `Live`'s only outlet is a view channel that explicitly never reaches the journal
   (`cli/wiring/agent_build.rb:49-50`). Ruled acceptable: the message survives, and giving `Live` a
   journal seam is a larger change than UX9 warrants.
8. **T10 and T11 are documentation and driver tooling and build no product capability.** Their
   criteria are verified by the integration checks and by `pre-commit`, not by a spec file.

## Waves

```
Wave 1: T1, T4, T5, T6, T8, T9, T10, T11   (no unmet deps)
Wave 2: T2 (←T1), T3 (←T1), T7 (←T6, file-sequenced), T12 (←T9)
```

Critical path: **T1 → T2** — length 2. (It was 3 before the panel; reshaping T3 as a decorator over
the admission object rather than over `Backend`'s wiring took it off the chain.)

Three sequencing edges are about files rather than logic, and each is stated on its card: **T7 ← T6**
(both edit `spec/lain/cli/up_spec.rb`), **T12 ← T9** (both edit
`lib/lain/frontend/neovim/runtime/05_records.lua`, and T9 establishes the identity-addressing pattern
T12 follows), and **T3 ← T1** (T3 modifies `lib/lain/provider/admission.rb`, which T1 creates).

## Tasks

### T1 — Build a provider admission gate [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/provider/admission.rb`; modify `lib/lain/provider.rb`; create
`spec/lain/provider/admission_spec.rb`
**Reuse:** ~~`Async::Semaphore` (already bundled) — **use the block form `#acquire { }`**~~
**SUPERSEDED — orchestrator ruling 2026-08-19, see the amendment below.** `Lain::Sink::Null` is the Null-Object exemplar for the unbounded case.
`provider/http/configuration.rb:127-131` is the house pattern for an env-only off switch.
**Named `Admission`, not `Lease`**, deliberately: `Isolation::Lease`
(`lib/lain/isolation/lease.rb`) is a resource handle with an idempotent-loud `#release` and different
semantics, and two leases with two release contracts in one codebase is a trap.
**Shared-file wiring:** none. `lib/lain/provider.rb` is the `provider/` subtree's own index and
requires its children (CLAUDE.md), so this is **not** an orchestrator-owned file.
**Reachable from:** T2 — `Provider::Ollama#complete` (`lib/lain/provider/ollama.rb:140-142`) and the
Anthropic arm.


> **AMENDMENT — T1 escalation ruled 2026-08-19 (orchestrator). `Async::Semaphore` is withdrawn;
> build option A.**
>
> The card's escalation trigger 2 (*cross-thread reactors*) **fires**, and the implementer measured it
> rather than arguing it. `Provider#complete` — the method T2 makes acquire — is reachable from a
> second OS thread on the real `--nvim` path: `cli/repl.rb:135` wires a real `ResendBridge` →
> `frontend/neovim.rb:351` `Thread.new { resend_loop }` → `resend_bridge.rb:156` `@agent.run` →
> `agent.rb:240` `Sync { }`, which **spins up a second reactor on that thread** because there is none
> to join. The codebase already states this at `agent.rb:234-236`: *"the {CLI::ResendBridge} runs on
> the Neovim resend-worker thread while a user prompt runs #ask on the conductor's reactor"*.
> `Agent#dispatch_lock` (a `Monitor`) excludes a concurrent `#ask` but **not** the eager oracle
> (`transient: true`, outlives the turn), the span summarizer, the window probes, or
> `Approval::SecretSurface`'s fiber — all on the conductor's reactor. So two reactors on two threads
> genuinely reach one endpoint's admission.
>
> Measured cost of shipping the mandated primitive anyway — three failures, and the first is the worst:
> the `FiberError: fiber called across threads` lands in the **releasing** fiber (the agent's *turn*,
> killed by an unrelated resend, with a message naming nothing in `lib/`); the waiting thread is still
> parked after a 5 s join, permanently wedging `resend_loop`'s blocking-pop consumer; and
> `Semaphore#release` decrements `@count` *before* `node.resume`, so the raise leaves the gate at 0
> with a node still parked — **it silently stops gating**, which would return F26 wearing a different
> face.
>
> **Ruling: option A — a `Mutex`-guarded counter for cross-thread correctness, plus a
> `task.sleep(interval)` poll bounded by the acquire deadline.** Keep the block form's `ensure`, so
> trigger 1 (cancellation) stays discharged — the implementer verified `Task#stop`/`Async::Stop` and
> `StandardError` all release, and that finding stands and need not be re-litigated.
> **`ConditionVariable#wait` is forbidden**: it blocks the whole reactor thread, which is exactly the
> failure `cli/repl/approval_surfaces.rb:56-62` records (*"being a thread-blocking read — freezes the
> whole reactor, so the queue's fail-closed timer could never fire"*).
> **Reuse `Approval::QueueSurface::DEFAULT_POLL_INTERVAL` (0.05, `queue_surface.rb:40`) rather than a
> new magic number** — `Notify::POLL_INTERVAL` (`notify.rb:131-134`) already reuses it, and that is
> the house pattern for this exact interval.
>
> Options rejected, recorded so they are not revisited: **B** (confine admission to the conductor's
> reactor, resend bypasses) leaves F26 live on the very cockpit configuration QA round 6 was run
> against; **C** (serialize at `Backend`) is already rejected by this chunk's own Grounding — six
> construction sites, one of which takes no injection by security mandate; **D** (ship the semaphore)
> turns an unrelated resend into a turn-killing `FiberError`. A fifth option — route resends onto the
> conductor's reactor so no second one exists — is a real architecture question and a **separate
> chunk**, not this card's to take.
>
> **All eight ACs stand verbatim** (they are written in terms of fibers, which still holds), plus one
> added: *two acquirers on two reactors on two threads do not corrupt the gate*. The escalation's
> cross-thread repro becomes a spec in that AC — a probe that found a defect does not stay a probe.
> The deadline shape the implementer solved in passing is kept: bound the **wait**, never the round
> trip (`Provider#complete` is legitimately minutes, `provider/http/configuration.rb:86-90`).

**Acceptance criteria:**

```gherkin
Scenario: a second caller waits rather than overlapping
  Given an admission of width one for an endpoint
  When two fibers each enter it around a round trip
  Then the second fiber's block does not begin until the first has returned

Scenario: admission is released when the block raises
  Given an admission of width one
  And a fiber whose block raises inside it
  When another fiber enters afterwards
  Then it is admitted rather than waiting forever

Scenario: admission is released when the fiber is cancelled
  Given an admission of width one held by a fiber
  When that fiber is stopped rather than raising a StandardError
  Then another fiber is still admitted afterwards

Scenario: a non-blocking caller is turned away rather than queued
  Given an admission of width one that is currently held
  When a caller tries to enter without waiting
  Then it is refused immediately
  And its block never runs

Scenario: waiting is bounded and refuses by name
  Given an admission of width one held past the acquire deadline
  When another caller waits for it
  Then it is refused with a message naming the endpoint and the deadline

Scenario: two endpoints do not contend
  Given admissions for two different resolved endpoints
  When a caller holds the first
  Then a caller entering the second is admitted immediately

Scenario: the off switch admits everyone
  Given LAIN_PROVIDER_CONCURRENCY is "0"
  When three fibers enter the same endpoint's admission concurrently
  Then all three run concurrently and none waits

Scenario: the wait is measured
  Given an admission of width one held for a known interval
  When a second caller is admitted after waiting
  Then it reports a wait, and the first caller reports none
```
→ spec file: `spec/lain/provider/admission_spec.rb`

**Escalation triggers:**
- **Cancellation, not just raising.** `Async::Stop`, `Async::Cancel` and `Interrupt` are `< Exception`,
  so `rescue StandardError` does not see them; `lib/lain/isolation/worker_handoff.rb:27-34` writes this
  lesson out for the isolation lease in the same fan-out shape. If the block form of `#acquire` does
  not cover cancellation, stop — a bare acquire/release pair is not an acceptable substitute.
- **Cross-thread reactors.** `Async::Semaphore` is not thread-safe (`@count` is unsynchronised and
  `FiberNode#resume` uses the releasing thread's scheduler), while `lib/` runs reactors on several
  threads (`frontend/tty.rb:137`, `frontend/neovim.rb:350-351`,
  `frontend/neovim/rpc_thread.rb:1030`). If any acquirer is reached from a thread other than the one
  running the agent's reactor — stop and report.
- A registry keyed by endpoint implies process-global state. If that cannot be made safe under
  `Ractor.shareable?` expectations elsewhere in the codebase, stop rather than weakening the key.

---

### T2 — Admit at the provider, so every construction site is covered [wave 2] [risk: high]

**Depends on:** T1
**Files:** modify `lib/lain/provider/ollama.rb`; modify `lib/lain/provider/anthropic.rb`; modify
`spec/lain/provider/admission_spec.rb`
**Reuse:** each provider already resolves its own endpoint —
`Ollama::Transport::DEFAULT_API_BASE` (`lib/lain/provider/ollama/transport.rb:32`) — which is why the
key is the *resolved* endpoint and not `@options[:api_base]`. `Provider::Ollama#complete`
(`lib/lain/provider/ollama.rb:140-142`) already encloses the whole stream, and is the correct
boundary.
**Shared-file wiring:** none
**Reachable from:** `Provider::Ollama#complete` — **every** provider round trip in the process,
including `Oracle::SecretRead`'s bare `Provider::Ollama.new` (`lib/lain/oracle/secret_read.rb:134`),
which takes no injection and which `Backend#provider` never sees.

**Why the provider and not `Backend`:** there are six construction sites (see Grounding) and one of
them structurally cannot accept an injected collaborator. Admission keyed by resolved endpoint inside
the provider makes the enumeration unnecessary — capacity is a property of the server, not of who
built the client.

**Acceptance criteria:**

```gherkin
Scenario: two round trips to one endpoint never overlap
  Given two providers built independently against the same resolved endpoint
  When a round trip is in flight through the first
  And a round trip is started through the second
  Then the two are never in flight at the same time

Scenario: a provider built with no api_base still contends with a configured one
  Given a provider built with no api_base
  And a provider built explicitly against that same default endpoint
  When both attempt a round trip
  Then the two are never in flight at the same time

Scenario: a hosted endpoint is not serialised behind a local one
  Given a provider against a hosted endpoint and a provider against localhost
  When a round trip is in flight through the local provider
  Then a round trip through the hosted provider begins immediately

Scenario: admission wraps the completion and not the stream
  Given an admitted round trip that is streaming
  When a second caller is waiting for admission
  Then the waiting caller has no stall clock installed
```
→ spec file: `spec/lain/provider/admission_spec.rb`

**Escalation triggers:**
- **The render path.** `Compaction::Strategy::Summarizing#asked`
  (`lib/lain/compaction/strategy/summarizing.rb:212`) does `@oracle.ask(...).await` inside
  `Agent#render_request` (`agent.rb:491-495`). If admission is ever taken *above* `#complete` — around
  `call_model` (`agent.rb:477-481`) or in `ModelCaller` — that `.await` re-enters a non-reentrant
  gate from inside the held region and the session hangs forever. Stop if the seam drifts upward.
- `spec/lain/seams/stall_under_reactor_spec.rb:123` asserts two concurrent streams both progress.
  Serialising per endpoint may break it. That spec pins a real property (sibling clocks do not
  cross-contaminate) — stop and confirm whether it should move to two endpoints rather than be relaxed.
- Any provider is found that does not route its round trip through `#complete` — that is a seventh
  site this card does not cover. Report it.

---

### T3 — Journal an admission wait, through a decorator [wave 2] [risk: medium]

**Depends on:** T1
**Files:** create `lib/lain/provider/admission/journal.rb`; create
`lib/lain/telemetry/provider_wait.rb`; modify `lib/lain/telemetry.rb`; modify
`lib/lain/provider/admission.rb`; create `spec/lain/telemetry/provider_wait_spec.rb`
**Reuse:** **`Telemetry::IsolationLease` (`lib/lain/telemetry/isolation_lease.rb`) and
`Isolation::Journal` (`lib/lain/isolation/journal.rb`) are the precedent**, not `OracleAnswer`:
a lease-lifecycle record with a `Guards` carrier and a closed `kind` enum, emitted by a
Journal-duck **decorator** that wraps any backend's acquire/release. Following it means the admission
object never learns about journaling. `telemetry.rb:37-42` is where the `Guards` live. Follow
CLAUDE.md's reopen-and-docstring rule for `Data.define`.
**Shared-file wiring:** none — `telemetry.rb` is its subtree's index and requires its own children.
**Reachable from:** T2's providers construct admission through this decorator when a journal is
available; with none, the undecorated admission is used and nothing is emitted.

**Acceptance criteria:**

```gherkin
Scenario: a caller that waited says so
  Given a decorated admission of width one already held
  When a second caller waits and is then admitted
  Then a provider_wait record is journaled naming the resolved endpoint and the seconds waited

Scenario: a caller that did not wait journals nothing
  Given an idle decorated admission
  When a caller is admitted without waiting
  Then no provider_wait record is journaled

Scenario: a refused wait is journaled as a refusal
  Given a decorated admission held past the acquire deadline
  When a caller waits and is refused
  Then the record names the refusal rather than reporting a completed wait

Scenario: the record is shareable
  Given a provider_wait record
  Then it is Ractor.shareable?
```
→ spec file: `spec/lain/telemetry/provider_wait_spec.rb`

**Escalation triggers:**
- Emitting per-admission proves noisy in an ordinary session (every turn waits a little). Stop and
  confirm a threshold rather than inventing one — thousands of records nobody reads is worse than none.
- The decorator cannot wrap without the admission object exposing its internals. That would mean the
  seam is wrong: stop rather than widening `Admission`'s public surface to suit its logger.

---

### T4 — Dispatch a session command at the reply prompt [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/cli/human_replies.rb`; modify `spec/lain/cli/human_replies_spec.rb`
**Reuse:** `Registry#dispatch(text, env)` (`lib/lain/cli/command/registry.rb:46-49`) already takes the
fallthrough as a block. `Registry#serves_replies?` (`:68-72`) is the existing predicate for "this is a
reply surface" and is how `/inbox` keeps its item-scoped detour without a string literal.
The refusal shape is `@tty.render_error` as used at `human_replies.rb:354-359`.
**Shared-file wiring:** none
**Reachable from:** `HumanReplies::Reply#read` (`lib/lain/cli/human_replies.rb:967-972`), reached on
the real path from `Repl#dispatch` (`lib/lain/cli/repl.rb:199`) → `LineScope#serve`
(`lib/lain/cli/repl/line_scope.rb:97`) → `AnswerLoop#exchange` (`human_replies.rb:621-630`).

**Acceptance criteria:**

```gherkin
Scenario: a registered command runs instead of answering the question
  Given a parked question
  When the human types "/ruby 1 + 1" at the reply prompt
  Then the command is dispatched
  And no message record carrying that text as an answer is written

Scenario: the question stays parked while a command runs
  Given a parked question
  When the human types a registered command at the reply prompt
  Then the question is still awaiting a reply afterwards

Scenario: /inbox still answers the set the loop is parked on
  Given two parked question sets
  And the reply loop is parked on the newer one
  When the human types "/inbox" at the reply prompt
  Then the set the loop is parked on is the one answered
  And the older set stays pending

Scenario: a command that would return a Repl action is refused by name
  Given a parked question
  When the human types "/quit" at the reply prompt
  Then a refusal naming the command is rendered
  And the question is still awaiting a reply
  And the session is still running

Scenario: prose still answers the question
  Given a parked question
  When the human types "go left"
  Then the answer delivered to the asker is "go left"

Scenario: an unregistered slash word is still an answer
  Given a parked question
  When the human types "/not-a-command"
  Then the answer delivered to the asker is "/not-a-command"
```
→ spec file: `spec/lain/cli/human_replies_spec.rb`

**Escalation triggers:**
- Any change makes `/inbox` at the reply prompt drain for `@inbox.oldest` rather than the parked item.
  `human_replies.rb:930-941` records that substitution as a fixed defect whose symptom is a reply
  naming another set's ids — stop; the item-scoped drain is not negotiable.
- Dispatching `/inbox` through `Registry` from inside `Reply#read` starts a reply loop inside a reply
  read, which is the race `Command::Inbox#serves_replies?` (`inbox.rb:27`) exists to prevent. If the
  `serves_replies?` predicate does not cleanly keep it out of dispatch, stop.
- The registry needs an `env` the reply loop cannot honestly supply. Stop rather than fabricating a
  partial one — commands behaving differently at the two prompts is the defect restated.

---

### T5 — Stop leaking a Ruby class name into text only the model reads [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/effect/handler/live.rb`; modify `spec/lain/effect/handler_spec.rb`;
modify `spec/lain/tool/result_block_spec.rb` *(orchestrator scope expansion, 2026-08-19: that file
pins the OLD class-prefixed wire text as committed-record fixtures — a literal string and two
`PRE_RESULT_LENS_DIGESTS` entries — and breaks as a direct, correct consequence of this card. The
implementer swept the suite and found it to be the only collateral file; the other five
`"<Class>: msg"` hits never route through `Effect::Handler::Live`.)*
**Reuse:** `Tool::Bounds` (`lib/lain/tool/bounds.rb:78-82`) documents this exact hazard.
*(Correction, 2026-08-19, found during implementation: the second half of this note was wrong. The
card claimed `Bounds` "routes around it by returning rather than raising" and that T5 "removes the
reason that workaround exists" — but `bounds.rb`'s text does **not** ground `Artifact#refusal`'s
return-vs-raise design in the class-prefix hazard; that design is justified structurally, by the
`size:`-only signature. So T5 removes nothing there. Whether `Artifact`'s return-based design should
be reconsidered on its own merits is a real and still-open question, and deliberately not settled by
this card.)*
`Tools::RunSkill#perform` (`lib/lain/tools/run_skill.rb:84-96`) is the clean shape.
**Shared-file wiring:** none
**Reachable from:** `Effect::Handler::Live#dispatch` (`lib/lain/effect/handler/live.rb:67-79`) — the
one place every tool call's error becomes a `tool_result`.

**Acceptance criteria:**

```gherkin
Scenario: a contract refusal reaches the model as its sentence alone
  Given a tool whose precondition fails
  When the handler dispatches a call to it
  Then the error result contains the precondition's own sentence
  And it does not contain "Lain::Tool::ContractViolation"

Scenario: an invalid input refusal is equally clean
  Given a tool call whose input fails validation
  When the handler dispatches it
  Then the error result does not name a Ruby class

Scenario: an unexpected error still reaches the model as a usable sentence
  Given a tool that raises an error outside the harness's own vocabulary
  When the handler dispatches a call to it
  Then the error result carries the message
  And it names no Ruby class
```
→ spec file: `spec/lain/effect/handler_spec.rb`

**Escalation triggers:**
- Any change reddens `spec/lain/tool/contracts_spec.rb:29`, `:59`, or `spec/lain/tool_spec.rb:162` —
  those pin the `precondition failed for X:` **label**, which must survive. Only the class prefix goes.
- A reviewer asks for the class to be journaled instead. It cannot be from this seam: `Live`'s only
  outlet is a view channel that `cli/wiring/agent_build.rb:49-50` states goes to the TTY and editor
  and *"never to the journal"*. That is Open decision 7 — do not widen this card to add a journal seam.

---

### T6 — Size the tmux session `lain up` creates [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/cli/up.rb`; modify `spec/lain/cli/up_spec.rb`
**Reuse:** `Up#create_session` (`lib/lain/cli/up.rb:735-741`) already builds the `new-session` argv;
`@tmux.act` is the seam every tmux call goes through; `configure_session` (`:834-840`) is the
established place for session-wide options.
**Shared-file wiring:** none
**Reachable from:** `CLI::Up#create_session` — the only place `lain up` creates a session.

**Acceptance criteria:**

```gherkin
Scenario: a created session is wide enough for the cockpit
  Given no existing tmux session on the socket
  When lain up creates one
  Then the new-session request states a width of at least 200 and a height of at least 50

Scenario: an existing session is not resized under an attached human
  Given a tmux session that already exists on the socket
  When lain up attaches to it
  Then no resize is requested

Scenario: the geometry holds while the session is detached
  Given lain up has created a session and nothing has attached to it
  When a further pane is opened in it
  Then that pane is sized from the stated geometry rather than tmux's 80x24 default
```
→ spec file: `spec/lain/cli/up_spec.rb`

**Escalation triggers:**
- Setting `default-size` **globally** would alter the human's own tmux server when `lain up` runs
  against their default socket rather than a scratch `-L`. That is worse than the defect being fixed —
  stop and confirm session-local vs global before shipping.
- An existing example asserts geometry is *absent* from `Up`'s `new-session` — stop; something depends
  on the inherited size. (Updating an example that pins the exact argv is expected and fine.)

---

### T7 — Carry the desktop consent into a cockpit pane [wave 2] [risk: medium]

**Depends on:** T6 — not a logical dependency: both cards edit `spec/lain/cli/up_spec.rb`, so they are
sequenced rather than run in one wave against the same file.
**Files:** modify `lib/lain/cli/up/pane_command.rb`; modify `spec/lain/cli/up_spec.rb`
**Reuse:** `PaneCommand.scrubbed` (`lib/lain/cli/up/pane_command.rb:36-68`) is the existing precedent
for a **second, separately-justified** name list beside `PANE_ENV`, and its comment explains the shape.
`Notify.for`'s `OVERRIDE` (`lib/lain/notify.rb:160,193`) defines the value grammar.
**Shared-file wiring:** none expected. **If `exe/lain` must change, hand the orchestrator a one-line
diff** — that file is scanned by the drift spec below.
**Reachable from:** `PaneCommand.call` (`lib/lain/cli/up/pane_command.rb:74-76`) — the exports preamble
of every pane `lain up` spawns.

**Acceptance criteria:**

```gherkin
Scenario: a muted shell mutes the cockpit it launches
  Given LAIN_DESKTOP is "0" in the environment lain up runs in
  When the chat pane command is built
  Then the pane's exports carry LAIN_DESKTOP=0

Scenario: an unset consent exports nothing
  Given LAIN_DESKTOP is unset
  When the chat pane command is built
  Then the pane's exports mention no desktop name

Scenario: PANE_ENV still describes exactly what EnvDefaults reads
  Given the names EnvDefaults reads in exe/lain
  Then PANE_ENV matches them exactly
  And the desktop name is carried by a separate list with its own stated reason

Scenario: no secret is ever exported
  Given an environment holding an API key
  When the pane command is built
  Then its exports are empty of that key
```
→ spec file: `spec/lain/cli/up_spec.rb`

**Escalation triggers:**
- Adding the desktop name **to `PANE_ENV` itself** reddens `spec/lain/cli/up_spec.rb:723-733` by
  construction — that spec re-scans `exe/lain` for `EnvDefaults.string|numeric` and asserts an exact
  match. If the design pulls that way, stop: the `EnvDefaults` doctrine
  (`lib/lain/cli/env_defaults.rb:17-30`, *"the environment may never say what lain is allowed to do"*)
  is a deliberate boundary and crossing it is not this card's call.
- Routing `LAIN_DESKTOP` through `EnvDefaults` to make it fit would demote its hard force-true/false
  `OVERRIDE` to an unset-flag default and silently change existing behaviour. Stop.

---

### T8 — A fixture that parks several approvals at once [wave 1] [risk: low]

**Depends on:** none
**Files:** create `spec/support/parked_approvals.rb`; modify `spec/lain/notify_spec.rb`
**Reuse:** `spec/lain/frontend/neovim/approval_view_spec.rb:311-322` already parks two pendings and is
the working shape to lift; `Approval::Queue#each` (`lib/lain/approval/queue.rb:288`) observes without
draining; `Notify::Null` (`lib/lain/notify.rb:802-806`) is the degrade path. The spec goes in
`notify_spec.rb` at the mirrored path — `lib/lain/notify.rb` is a leaf with no sibling directory, and
CLAUDE.md forbids sharding a spec to game the packer.
**Shared-file wiring:** none. The support file must be **inert on load** — a bare module, no
top-level side effects, no `Dir.chdir`, no methods on `Object`: `spec_helper.rb` globs
`support/**/*.rb` into every worker of every run, and CLAUDE.md records a harness that broke exactly
this way.
**Reachable from:** **deferred: test-only** (Open decision 2). The notifier it exercises is already
wired at `lib/lain/cli/wiring.rb:354`.

**Acceptance criteria:**

```gherkin
Scenario: several approvals park together
  Given three gated tool calls parked at once
  When the queue is observed without draining
  Then three undecided pendings are listed

Scenario: the notifier raises one notification per parked approval
  Given three parked approvals and a recording notifier
  When the notifier sweeps
  Then three notifications are raised before any of them is answered

Scenario: answering one leaves the others raised
  Given three parked approvals that have each been notified
  When one is decided through another surface
  Then that one's notification is withdrawn
  And the other two remain raised
```
→ spec file: `spec/lain/notify_spec.rb`

**Escalation triggers:**
- The fixture needs a real `dunstify` to assert anything — stop. `Notify` must be exercised through a
  recording double; `spec/lain/notify_spec.rb:1220-1238` keeps the real-binary example opt-in behind a
  tag, and this fixture must run by default.
- Parking three approvals requires driving a real Agent turn — that makes this a seam test with a
  model in it. Stop and confirm; the point is a fixture cheap enough for any future round to use.

---

### T9 — Give `lain://approval` a foldable record, addressed by identity [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim/approval_view.rb`; modify
`lib/lain/frontend/neovim/runtime/62_approval.lua`; modify
`lib/lain/frontend/neovim/runtime/05_records.lua`; modify
`spec/lain/frontend/neovim/approval_view_spec.rb`
**Reuse:** `runtime/10_folds.lua` already installs folds, sets `foldminlines = 0` (`:105-108`) and
computes `foldtext` (`05_records.lua:186-193`) — this card adds a boundary, not machinery.
`QUESTION`'s open-first-close-rest rule (`10_folds.lua:67-83`) is the precedent for a list at rest.
`runtime/45_views.lua:26-38` already preserves fold state on unchanged leading lines.
**Shared-file wiring:** none
**Reachable from:** `ApprovalView#lines_of` (`lib/lain/frontend/neovim/approval_view.rb:359-363`),
driven live by `Surfaces` on the real path.

**The addressing change is specified here, not discovered.** Position-addressing breaks in **two**
independent places once an item spans more than one line, and both must change together:

1. **Ruby** — `ApprovalView#row_at` (`approval_view.rb:321-324`) is
   `@renderings.fetch(generation)[index - 1]`.
2. **Lua** — `render` passes `parked.size` as `rows` (`approval_view.rb:347`), stored as
   `b:lain_approval_rows` (`runtime/62_approval.lua:90`); `:124` sends **nothing** when the cursor
   line exceeds it, and `:71-75` states that silence is deliberate.

The card posts a **line→item map** alongside `lines`/`gen`/`rows` and resolves a keypress through it,
so any line of an item answers that item. A cursor on a continuation line must never be inert and must
never answer a neighbour.

**Acceptance criteria:**

```gherkin
Scenario: an approval row can be opened to its full command
  Given a parked approval whose command is longer than one screen line
  When the approval view renders
  Then the item's first line summarises it
  And the full command text is present in the item's remaining lines

Scenario: the list stays quiet at rest
  Given three parked approvals
  When the approval view renders
  Then each item contributes a summary line
  And the items are closed by default

Scenario: an approval row can be collapsed
  Given a rendered approval whose item spans several lines
  When a fold is closed on that item
  Then only its summary line remains visible

Scenario: the summary line answers its own item
  Given three parked approvals
  When the human approves from the summary line of the third
  Then the third approval is the one decided

Scenario: a continuation line answers its own item and is never inert
  Given three parked approvals whose items each span several lines
  When the human approves from a continuation line of the third
  Then the third approval is the one decided
  And the keypress is not silently ignored
```
→ spec file: `spec/lain/frontend/neovim/approval_view_spec.rb`

**Escalation triggers:**
- `approval_view_spec.rb:135-146` pins *"answers the row the cursor is on, not the first one"*. It must
  still pass under identity addressing. If satisfying it requires keeping position addressing, stop —
  the card's premise is wrong.
- The line→item map cannot be posted over the existing RPC payload without widening the transport
  contract. Stop and report rather than inventing a second channel: a wrong row approved is the worst
  outcome this card can produce.

---

### T12 — Give `lain://inbox` a foldable record, and stop indexing by position [wave 2] [risk: high]

**Depends on:** T9 — both edit `lib/lain/frontend/neovim/runtime/05_records.lua`, and T9 establishes
the identity-addressing pattern this card follows.
**Files:** modify `lib/lain/frontend/neovim/inbox_view.rb`; modify
`lib/lain/frontend/neovim/runtime/70_inbox.lua`; modify
`spec/lain/frontend/neovim/inbox_view_spec.rb`
**Reuse:** T9's line→item map and the fold boundary it adds to `05_records.lua`.
**Shared-file wiring:** none
**Reachable from:** `InboxView#render` (`lib/lain/frontend/neovim/inbox_view.rb:299-304`).

**This card deliberately overrules a documented decision, and the reason must be read first.**
`inbox_view.rb:317-325` states that a question is folded onto one line *"for the sharper of that
fold's two reasons: `{Renderings}` indexes digests by POSITION, so a two-line row would send `<CR>`
to a set the human did not choose"*, with `RenderQueue#checked_lines` as the transport backstop that
*"refuses rather than repairs"*. **The one-line row is therefore a consequence of position indexing,
not a display preference.** This card is legitimate only if it removes the cause: `Renderings` must
address by identity before the row may grow. `runtime/70_inbox.lua:69` gates `<CR>` on the same
`RECORD_START[INBOX]` predicate, so both halves move together. Update that docstring as part of the
card — leaving it in place would leave the next reader a rule the code no longer follows.

**Acceptance criteria:**

```gherkin
Scenario: an inbox question can be read without leaving the buffer
  Given a pending question whose text is longer than the announcement headline
  When the inbox view renders
  Then the full question text is present under that item's summary line

Scenario: opening a set from any of its lines opens that set
  Given three pending question sets whose items each span several lines
  When the human opens from a continuation line of the second
  Then the second set is the one opened

Scenario: answering one item leaves the others addressable
  Given three pending sets
  When one is answered
  Then opening each remaining item still opens that item

Scenario: the list stays quiet at rest
  Given three pending sets
  Then each contributes a summary line
  And the items are closed by default
```
→ spec file: `spec/lain/frontend/neovim/inbox_view_spec.rb`

**Escalation triggers:**
- `Renderings` cannot address by identity without changing what `RenderQueue#checked_lines` guards.
  That backstop *"refuses rather than repairs"* by design — stop rather than relaxing it; a refusing
  backstop is what makes a mis-addressed `<CR>` impossible rather than merely unlikely.
- The full question text is not reachable from the event body the view holds — it is summarised
  upstream by `Tools::AskHuman::Announcement` (`lib/lain/tools/ask_human.rb:285-296`, set at `:591`).
  Stop rather than widening the announcement: that payload has other readers.

---

### T10 — Let a QA round see what a text read cannot [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `planning/qa/method.md`; modify `.claude/skills/manual-qa/scripts/qa-sandbox.sh`;
modify `planning/qa/scenarios/cockpit-surfaces.md`
**Reuse:** the sandbox script already emits `peek.sh`, `nv.sh` and `proxy.rb`; `tmux capture-pane -e`
preserves attributes where `-p` strips them; fold state is readable over the existing RPC seam.
**Shared-file wiring:** none
**Reachable from:** **deferred: process documentation and driver tooling** (Open decision 8).

**Acceptance criteria:**

```gherkin
Scenario: the driver can read attributes, not just text
  Given a cockpit pane rendering coloured output
  When the driver captures the pane with attributes preserved
  Then the capture contains escape sequences the plain capture omits

Scenario: fold state is readable over RPC
  Given a buffer with folds installed
  When the driver asks nvim for the fold state of a line
  Then it receives the level and whether the fold is closed

Scenario: the method says which checks need a real terminal
  Given the standing method
  Then it names the properties no text read can verify
  And it says how to capture them
```
→ spec file: none — documentation and shell tooling; verified by the integration checks.

**Escalation triggers:**
- `capture-pane -e` output proves unreadable enough that a driver will not use it — say so in the
  method rather than shipping a recipe nobody follows.
- A screenshot step needs a tool absent from this box — record the dependency explicitly, the way
  `bench.md` records `dunstify`, rather than assuming it.

---

### T11 — Record the round-6 residue [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `planning/qa-findings-round6-2026-08-19.md`; modify
`planning/qa/scenarios/session-and-window.md`; modify `planning/README.md`
**Reuse:** the findings file's "Withdrawn" section is the established place for a disproved
suspicion; `planning/README.md`'s specs table is the index convention.
**Shared-file wiring:** **`exe/lain`'s `--prompt` description** — hand the orchestrator a one-line
diff saying it seeds the first question and does not affect exit status.
**Reachable from:** **deferred: documentation** (Open decision 8).

**Acceptance criteria:**

```gherkin
Scenario: the exit-status decision is recorded where a reader will find it
  Given the round-6 findings
  Then FG1 states that --prompt is a REPL seed and its exit status is not a signal
  And it names what would reopen the decision

Scenario: a scenario no longer implies $? is meaningful for a failed ask
  Given the session-and-window scenario
  Then its --prompt probes are judged by rendered text and the journal

Scenario: the chunk is findable from the index
  Given planning/README.md
  Then it carries a row pointing at this chunk spec
```
→ spec file: none — documentation.

**Escalation triggers:**
- A scenario step depends on `$?` for a **launch-level** refusal — those genuinely do exit nonzero
  (`exe/lain:843-847` maps `Lain::Error` to `Thor::Error`). Do not blanket-edit: the split is
  construction-refuses-nonzero versus ask-fails-zero, and flattening it makes the docs wrong the other
  way.

## Integration checks

1. `bundle exec rake pspec`. **Check the example COUNT against a serial run** — CLAUDE.md records that
   a dead worker and an OOM kill both present as "fewer examples, 0 failures, non-zero exit".
2. `bundle exec rubocop` (bare — never naming a `.toml`) and `pre-commit run --all-files`.
3. `cargo test && cargo clippy --all-targets -- -D warnings`.
4. **The F26 seam, end to end, with the instrument that found it.** Start `$QA/proxy.rb`, launch a
   cockpit through it, drive a turn whose tool result summons the oracle. Assert from the proxy log
   that **no two `/api/chat` requests are in flight at once**, and from the pane that no
   `stalled stream` appears. A spec against a fake provider cannot prove this.
5. **The sixth construction site.** Run with `--secret-oracle` active and confirm from the same proxy
   log that its requests are admitted through the same gate — this is the site `Backend#provider`
   never sees, and the only end-to-end check that T2's placement was right.
6. **A manual `human>` pass.** Spawn a subagent, park a question, confirm `/ruby`, `/mode` and
   `/status` each render and leave the question parked; `/quit` is refused by name; `/inbox` answers
   the parked set and not the oldest; prose still answers.
7. **A real-terminal cockpit pass (human, not agent).** Park two approvals using T8's shape and
   confirm by eye that each row folds open to its full command and closed to its summary — and that
   `y` on a continuation line answers that item. This is what T10 exists to make possible.
8. Confirm `~/.local/state/lain` gained nothing during any sandboxed run.

## What the panel changed

Panel review 2026-08-19 returned **6 blockers, 7 should-fixes, 5 nits** and a verdict of *do not
execute*. All were verified against the code before acting; all are discharged.

- **B1 — a sixth provider, built where no card looked.** `oracle/secret_read.rb:134` constructs a bare
  `Provider::Ollama.new` on the chat path, and taking a seam there is forbidden by `:19-38`. The old
  T2 wired admission into `Backend` and would have halted on its own escalation trigger with no legal
  move. **Admission moved into the provider, keyed by resolved endpoint** — which covers all six sites
  without enumerating any of them.
- **B2 — the old key was unconstructable and wrong.** There is no per-tier `api_base`
  (`exe/lain:416`), and `--provider anthropic --summarizer-provider ollama` gives `nil` on both sides,
  which would have serialised a hosted turn behind a local summary. Dissolved by B1's fix; the ACs are
  rewritten against configurations that exist.
- **B3 — the queue wait was unbounded, and the holder's ceiling is 20 minutes, not 300 s.**
  `Async::Semaphore#acquire` has no timeout, and faraday-retry makes `request_timeout` apply four times
  (`middleware_stack.rb:64-70`). Admission now takes an acquire deadline, refuses by name, and gains
  `LAIN_PROVIDER_CONCURRENCY=0` as an off switch (Open decision 3).
- **B4 — serialising inverted `Oracle::Eager`'s contract.** A queued fire reaped at teardown burns its
  digest for the session (`eager.rb:73-74`, `tool_runner.rb:115-120`) and degrades silently. **The
  oracle now uses a non-blocking try-acquire and is skipped when the endpoint is busy** (Open decision
  4), which preserves *"the turn never waits"* exactly. The old AC pinning oracle-after-turn ordering
  is replaced by mutual exclusion, which is what the code can actually guarantee.
- **B5 — T9 undid a decision whose docstring names the harm.** `inbox_view.rb:317-325` says the
  one-line row exists *because* `Renderings` indexes by position. Addressing now changes **up front**
  via a line→item map; `62_approval.lua` and `70_inbox.lua` joined the file lists; and the card split
  into **T9 (approval)** and **T12 (inbox)**, the latter carrying the removal of position indexing and
  an instruction to update the docstring it overrules.
- **B6 — T4 reintroduced a fixed defect.** `/inbox` at the reply prompt is item-scoped for a recorded
  reason (`human_replies.rb:930-941`); dispatching it through the registry drains `@inbox.oldest`.
  `/inbox` now stays out of dispatch via `serves_replies?`, and an AC pins *parked, not oldest*.
- **S3** — `/quit` returns `:quit` with nowhere to go in the reply loop; action-returning commands are
  refused by name (Open decision 6) rather than silently doing nothing.
- **S4** — T5's "journal the class" AC contradicted its own trigger: `Live`'s channel *"never"* reaches
  the journal (`agent_build.rb:49-50`). AC dropped, ruled in Open decision 7.
- **S5** — T1's require belongs in `lib/lain/provider.rb`, its subtree index, not `lib/lain.rb`;
  T1 no longer touches a shared file.
- **S6** — T1's triggers now cover cancellation (`Async::Stop` is `< Exception`) and cross-thread
  reactors, with the block form of `#acquire` mandated.
- **S7** — T3 reshaped around `Telemetry::IsolationLease` + `Isolation::Journal` as a decorator, so the
  admission object never learns about journaling; **moved off the critical path into wave 2**.
- **S1/S2** — the admission seam is now named explicitly (wrapping `#complete`, with the render-path
  deadlock spelled out as a trigger); the missing live surface is recorded as the operator-visible gap
  a future card should close, with `Frontend::Decorators::ProviderRetry` (`backend.rb:170-178`) as its
  precedent.
- **N1–N5** — T8's spec moved to the mirrored `notify_spec.rb`; T6's AC says *while detached*; the
  object is `Provider::Admission`, not a second `Lease`; the off switch is documented; the
  file-collision claim now names T2/T3 as well.

**Critical path shortened from 3 to 2**, and the chunk gained parallelism rather than losing it —
which the panel noted is the usual sign the seams were in the wrong place to begin with.
