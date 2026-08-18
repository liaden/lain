# QA round-3 defects, a test-hygiene pass, and the next QA round

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

## Intent

The 2026-08-18 manual QA run (`planning/qa-findings-round2-2026-08-18.md`) confirmed all seven
findings of the previous chunk fixed, and found nine more: F8–F16. Three are high severity, and
**one of those is a regression introduced by the previous chunk's own T12 fix** — a 30 s stalled-
stream timeout that kills the entire chat session with a raw backtrace whenever lain's own subagent
contends with its parent for a single-slot local server. This chunk fixes the eight findings the
interview put in scope, each behind a spec written red first; prunes specs that a targeted audit can
and prunes specs along three separate axes, because they are three different failures: assertions
that cannot fail (T11), methods made public only so a test can reach them (T12), and specs that run
the right machinery against the wrong subject (T14) -- the shape that once had `Gherkin::Criteria`'s
spec parsing lain's own planning documents. It ends by refreshing the QA plan and running round 4.

Two of the nine are deliberately not fixed here — see **Open decisions**.

## Execution log

Started 2026-08-18 by `/execute-plan` (orchestrator-commits).

**Staleness check — PASSED.** Re-verified the wave-1 anchors directly against the working tree:
`faraday_handlers.rb` (`:36` `StalledStreamError < HTTP::Error`, `:73-85` the THREE-places
paragraph, `:88` `VARIABLE`, `:124` `.current` reading a **thread** variable, `:137` `target:
Thread.current`, `:215` `@monitor ||=`, `:261-264` `@target.raise`); `stall_protection_spec.rb`
`:246-252`/`:257-259`/`:465-473`; `middleware_stack.rb` `:34`/`:46`/`:58-60`/`:109`/`:145-150`;
`configuration.rb` `:73` `request_timeout 300`, `:100` `:net_http`, `:139-169` `stream_stall_timeout=`;
`decorators.rb` `:18-26` ("a decision, not a gap"); `backend.rb` `:108-114`/`:137-142`/`:280`;
`backend_spec.rb` `:405-410`; `list_files.rb` `:24-29`/`:48`/`:55-61`, `glob.rb:75`, `grep.rb:275`,
and the two `content: ""` locks; `handover.rb:266-272`, `session.rb:355`/`:401-408`,
`handover_spec.rb:195`, `review_surface.rb:444-457`; `queue.rb:225`/`:293`, `policy_switch.rb:34`,
`switchboard.rb:130`, `approval_policy.rb:86-88` and the three literal-`"agent"` locks;
`prompt_composer.rb:381-384`/`:399-410`/`:420-424`, `run_clock.rb:82`. Every line cited by a wave-1
card is where the plan says it is; no card was invalidated.

**T11's fifth deletion is STRUCK — the card was wrong, proven by mutation (2026-08-18).**

T11 ordered five deletions. Four were correct. The fifth, `spec/lain/provider/anthropic_wire_spec.rb`,
must NOT be deleted, and the card's justification for it is false. Shadowing `RATE_LIMIT_RESET_HEADER`
on `Provider::Anthropic` and running the whole suite yields `13791 examples, 1 failure` -- and that one
failure IS the example the card ordered deleted. The siblings the card cited as covering it (`:32`,
`:36`, `:51-53`) all stay green. It is the only example in the suite that catches a class-level
constant shadow. Both the implementer and the reviewer reached this independently, by mutation.

A related card correction: for `cache_profile_spec.rb` only the tautological `X eq X` line was removed,
not the example. Coverage survives at `:54`/`:58`, NOT from sibling `:101` as the card assumed --
verified by mutation (`:101` stays green under `#==` non-Hash `super` -> `false`).

**A blind spot T14 and T12 inherit.** `spec_discipline_spec.rb` flags only `sole_raise_error` (127) and
`nested_expect` (13). **Neither category can see this chunk's recurring defect shape**: an `include`
assertion against prose the same change authored, which matches by construction and keeps matching for
unrelated reasons. Four such assertions were found this chunk, all in code written or edited DURING it,
two of them created BY fix rounds. Every one was caught by MUTATION; none by reading. A discipline
report that cannot see the shape will report the suite as clean of it.

**Wave 1 progress (2026-08-18).**

| card | implemented | review verdict | landed |
|---|---|---|---|
| T4 | yes | APPROVE | **`725efc36`** |
| T5 | yes (+fix round) | APPROVE-WITH-FIXES, fixed | pending re-review |
| T7 | yes (+fix round) | REQUEST-CHANGES, fixing | no |
| T9 | yes | APPROVE-WITH-FIXES, fixing | no |
| T10 | yes | REQUEST-CHANGES, fixing | no |
| T1 | yes | in review (high depth) | no |
| T3 | yes | in review | no |
| T8 | yes | in review | no |

Also landed: **`4c851d96`** `.rubocop.yml` excludes `planning/**/*.rb`. Not a card. The `ruby checks`
hook lints the whole TREE when any Ruby file is staged, so one unlinted scratch script under
`planning/` failed *every* commit in the repo. User chose the exclusion over editing the script.

**Two corrections to this plan's own Grounding, for T11/T12/T14 to absorb:**

1. The claim of "zero `xit`/`xdescribe`/`pending` anywhere" is **false**. Three genuine `pending`
   declarations exist (`role_prelude_wiring_spec.rb:149`, `supervisor_reactor_spec.rb:179`, `:457`).
   This weakens the argument that the mechanical audit categories are exhausted.
2. `lib/lain.rb` was named a shared orchestrator-owned file needing per-card wiring lines. **Two
   cards (T4, T5) found it needs no edit at all** -- a file with a sibling directory is that
   subtree's index and requires its own children, per CLAUDE.md's Requires rule. Treat remaining
   cards' `lib/lain.rb` claims as suspect rather than authoritative.

**The suite baseline is 13690, not the ~10865 CLAUDE.md records** -- it has grown ~26%. The
net-example-count justification in Integration checks must measure against 13690.

**Known flake, recorded by NAME** (line numbers drift; CLAUDE.md says so and they drifted again --
its recorded `:115`/`:175` are now `:141`/`:201`): `Lain::CLI::Up against a real tmux server`, the
examples "threads -- chat args into the spawned window's command, each argument shell-escaped" and
"--nvim cockpit splits the chat window into an nvim pane and a chat pane sharing one socket and one
cwd". Load-induced, not a regression. Concurrent agents each running a full suite is enough to
trigger it; example COUNT stays correct, which is how it is told apart from a dead worker.

**One absorbed divergence, documentation only.** The "manual QA round 4" section says "T1 and T2
both have to hold", and T1's first escalation trigger says "T2's shape changes too" -- but **there
is no T2**: it was the contention-throttling card cut on panel review (see Open decisions). Read
both as naming T1 alone. No card's scope changes.

## Grounding

Verified 2026-08-18 against the working tree by four parallel exploration passes plus direct reads.
Line numbers are from that tree.

**F10 — the mechanism, which the QA findings doc did not have.** Two independent gaps, and both
must close or the crash survives:

- `StalledStreamError` (`streaming/faraday_handlers.rb:36`) descends from `Provider::HTTP::Error`,
  which descends from `StandardError` — **not** from `Lain::Error`. So it matches none of the three
  rescues on the chat path: `Repl#dispatch` (`cli/repl.rb:201`), `Repl#respond` (`cli/repl.rb:308`),
  `exe/lain:845` — all three rescue `Lain::Error` only.
- `StallClock#fire` (`faraday_handlers.rb:261-264`) calls `@target.raise`, where `@target` defaults
  to `Thread.current` **captured at construction** (`:137`). But `agent.rb:206-211` records that the
  loop "always executes inside a fiber reactor", and `repl.rb:90`/`repl.rb:306`/`conductor.rb:85-87`
  run sibling fibers on one reactor thread. `Thread#raise` lands on whichever fiber is resumed, which
  is why the QA backtrace surfaced at `Repl#run:90` — the conversation-level `Sync`, **above** both
  rescues. The class doc's "exactly THREE places the async raise can land" (`:73-85`) is a
  thread-level argument and does not cover the fiber case.

The good news the grounding turned up: `stall_protection_spec.rb:465-473` already pins
`Provider::Ollama#complete` surfacing a stall as `Ollama::APIError` (a `Lain::Error`, via
`ErrorWrapping.under` at `ollama.rb:79`) **when the raise lands synchronously inside
`wrapping_errors`**. So the containment already works; only delivery is wrong. T1 is a targeting fix,
not a new rescue.

**F10's trigger is lain's own concurrency, and the mechanism is that the clock is scoped to the
wrong thing.** This was diagnosed wrongly twice — once in the QA findings, once in this plan's own
first draft — and the panel falsified both. The correct account:

`StallClock` installs itself in a **thread** variable (`faraday_handlers.rb:88` `VARIABLE`, set at
`:154-155`, read by `.current` at `:124`) while the unit of work is a **fiber**.
`Tools::Subagent#launch_actor` documents that "the fiber spawns on the current task"
(`tools/subagent.rb:159-161`), under the one chat-level `Sync` at `repl.rb:90`, and Faraday's
`:net_http` adapter under a fiber scheduler yields rather than blocking — so **parent and child
stream concurrently on one thread**. Therefore:

1. The second `#watch` **displaces** the first's clock; both streams then tick ONE clock through
   `StallClock.current`.
2. The displaced clock's `@last` freezes at displacement, so it fires one grace later **regardless
   of whether its own stream is healthy** — and its `@target` is the thread, so the raise lands in
   the reactor root at `repl.rb:90`. That is exactly the QA backtrace.
3. `#unwatch(displaced)` assumes LIFO completion. Out-of-order completion leaves a stale clock
   installed, breaking the invariant `Streaming#flush_stream` depends on ("no active `#watch` means
   `.current` is `Null`").

**The decisive evidence is the QA run's own server log.** The crashed request received **zero**
bytes: it sat in ollama's queue for 69 s and was aborted with a 500. The clock arms on the first
body chunk, so **that request's own clock could never have armed**. Only a clock armed by the
*other*, actively-streaming request can produce "no bytes for 30.2 s" against it.

This is why the earlier "the loser's queue wait is charged to the upstream" story was wrong, and it
is why a card that only fixes *delivery* would leave F10 alive: an exception delivered precisely by
the wrong clock still kills the wrong turn.

**F15 — the numbers.** `middleware_stack.rb:58-60` sets `faraday.options.timeout = request_timeout`
and **nothing else** — there is no separate `open_timeout`, so an unroutable IP's `connect()` blocks
on the full 300 s (`configuration.rb:73`). `retry_options` (`:103-112`) adds `:post` to
`IDEMPOTENT_METHODS` at `:109`, `max_retries` is 3, and `Faraday::ConnectionFailed`/`Errno::ETIMEDOUT`
are both in `retry_exceptions` (`:145-150`). 4 × 300 s ≈ 20 min. The stall clock cannot help: it arms
on the **first body chunk** (`faraday_handlers.rb:215`, `@monitor ||= start_monitor` inside
`#suspend`, itself called only from the two `on_data` procs at `:304`/`:310`) — verified empirically
in QA, where a deliberate 27 s runner reload under `LAIN_STREAM_STALL_TIMEOUT=5` completed normally.

The blank screen has a separate, already-diagnosed cause: `ollama.rb:56-63` states that
`Frontend::Decorators.for` renders only `Telemetry::ToolOutput`, that `Telemetry::ProviderRetry` is
deliberately unrendered, and that making retries visible live "would be a second decorator, **which
is nobody's card yet**." T4 is that card. `decorators.rb:23-26` names the extension shape exactly.

**F14 — already predicted in a comment, and defended in the wrong place.** `ollama.rb:184-206`
describes the schemeless-typo failure precisely and adds a `NoMethodError` arm keyed on
`e.receiver.equal?(@transport)` — but **only to `#context_window_tokens`**, the launch probe.
`#complete` (`ollama.rb:141-143`) goes through `wrapping_errors`, which rescues `Provider::HTTP::Error`
and `Faraday::Error` only (`error_wrapping.rb:85-91`), so the first turn crashes. There is **no
`--api-base` validation anywhere in `lib/`**: `exe/lain:604` declares it `type: :string`,
`EnvDefaults.string` (`env_defaults.rb:45-48`) only strips whitespace, and it reaches
`Faraday.new(@provider.api_base)` at `middleware_stack.rb:46` unexamined. `window_book.rb:143-148`
writes down the assumption that fails: *"`--api-base "not a url"` raises `URI::InvalidURIError` …
so it escapes before any probe is sent"* — true for a non-URI, false for `localhost:11434`, which
parses as scheme `localhost` with opaque `11434`.

`Backend::Ceiling` (`cli/backend/ceiling.rb:26-40`) is the precedent: a flag-carrying refusal raised
from `Backend#initialize` (`cli/backend.rb:137-142`, which already calls `summarizer_name`,
`summarizer_max_tokens` and `num_ctx` eagerly so "the refusal cannot depend on which collaborator a
given run happens to build"). `--api-base` is simply absent from that list.

**F8 — the exact seam, and the one case that must not change.** `WindowBook#served`
(`window_book.rb:178`) is `[@backend.num_ctx, @backend.provider.context_window_tokens(model)].compact.min`.
`Ollama#context_window_tokens` answers **nil** when nothing is resident (`ollama.rb:164-169`: "nil is
the ORDINARY answer"), `.compact` drops it, and the operator's number becomes the whole book —
wrapped unconditionally in `Served`, whose `#resolve` (`:105-110`) returns `provenance: PROBED` with
no conditioning. `PROBED`'s own docstring (`context_window.rb:133`) is "the server said so, about the
runner resident right now."

The case that is **correct today and must survive**: `window_book_spec.rb:112` — provider answered
32,768, `--num-ctx 8_192`, result 8,192 tagged `PROBED`, with the comment "the smaller is still a
MEASURED ceiling on a runner that answered, so it keeps its authority." A fix that tags every
`--num-ctx` path non-probed breaks that, and it should not.

The case that **will** change: `backend_spec.rb:315` ("stands alone when the provider reports
nothing") asserts the number 16,384 and never the provenance. That is F8's configuration, and T6
changes its answer deliberately.

`authoritative?` is `provenance != GUESSED` (`context_window.rb:278`), and `Source#need_for`
(`compaction/source.rb:339`) is the single gate:
`resolution.authoritative? ? need : need.without(Need::ApproachingWindow::KIND)`.

**F11 — three tools, one shape, uneven disclosure.** `ListFiles#perform` (`tools/list_files.rb:48`),
`Glob#perform` (`tools/glob.rb:75`) and `Grep#format_matches` (`tools/grep.rb:275`) all produce
`Tool::Result.ok("")` for an empty result. `Tool::Result` has exactly two constructors
(`tool.rb:235`, `:242`) and `tool.rb:226-232` is explicit doctrine — "There is deliberately NO error
inference" — so the fix must live in the content string. `Glob` and `Grep` at least disclose the
behaviour in `#description`; `ListFiles#description` (`:24-29`) does not mention it at all.

The precedent is commit `6c3fffec`, and it is a precise template: a frozen identity sentinel
(`web_search.rb:47` `NOT_CONFIGURED`), a three-way branch with the **constant as the receiver** of
`.equal?` so a result cannot forge a match (`:81`), and two distinct sentences (`:98-105`) that name
the tool, echo the input, and read as non-retryable. Its spec (`web_search_spec.rb:36`, `:59`)
asserts distinguishability **in both directions**.

**F13 — the verdict rail has no return leg that speaks.** `46_sidebar.lua:193-197` `pcall`s the RPC
and, on success, falls off the end of the callback — no `vim.notify`, no `nvim_echo`. Contrast
`:LainReviewMark` (`:143-165`), whose acknowledgement is a **push** from the model side:
`Session#mark` (`review/session.rb:356`) → `Surface::Neovim#mark` (`review/surface/neovim.rb:275`) →
`@rpc.review_refused` → `65_review.lua:36-38`, which is where the `lain: ` prefix comes from.

**`Handover` holds no surface** (`review/handover.rb:238` — `session:, view:, baton:, docent:,
redraw:`), so the push cannot originate there. The rail this card copies is `Session#mark` →
`@surface.mark(...)` (`review/session.rb:355`), whose silent sibling is `Session#submit`
(`:401-408`) — **that is where the acknowledgement belongs**. The entry point is
`Review::Handover#wrote_verdict` (`review/handover.rb:266-272`) — the only gesture
method on that object that touches neither `@view`, `@docent` nor `@redraw`, while its siblings
`#mark` (`:341-346`) and `#open` (`:314-318`) both call `@redraw.present(@session)`. Its `nil` return
is load-bearing (nil = "taken", which is what lets the editor's command succeed), so an
acknowledgement cannot ride the return value.

Two specs positively pin today's silence and must be changed deliberately:
`handover_spec.rb:195` (`wrote_verdict` → `be_nil`) and `review_surface.rb:444-457`, whose law #5
comment says "**The five COMMANDS only; `#verdict` is exempt**". `review_view_spec.rb:1236` drives
the real `:LainReviewVerdict` against a headless nvim and asserts only `ok => true`. The assertion
style that would catch this — `nvim_exec2("messages")` — already exists at `neovim_spec.rb:686` and
`neovim_runtime_spec.rb:1045`, just never on the verdict success path.

**F12 — the rendering exists; the value is a constant.** `Telemetry::ApprovalPending`
(`telemetry/approval_pending.rb:50`) already carries `requester`, and
`Frontend::Neovim::ApprovalView#row_for` (`frontend/neovim/approval_view.rb:312-314`) already leads
with it, commented "with a fleet running, 'who is asking' is what separates two identical-looking
rows." But `Approval::Queue#initialize` (`approval/queue.rb:225`) defaults `requester: "agent"` and
`#admit` (`:293`) passes `@requester` — queue-level state, never per-call — and the **one**
`Approval::Queue.new` in `lib/` (`cli/switchboard.rb:130`) takes the default. So every actor journals
`"agent"`. The tty prompt (`frontend/approval_policy.rb:86-88`) does not render the requester at all.

The identity already exists on a neighbouring rail: `Tools::Subagent` takes `announces_as:`
(`tools/subagent.rb:72,76-77`) and hands it to `@seam.askers.enrol(handle, agent: @name)`
(`:625`), documented at `:580-583` as "what a human is TOLD is asking" — wired for the researcher at
`wiring/toolset_build.rb:325-331`. **`ask_human` knows who is asking; `approve` does not.**

**F9 — the label is accurate and the line is stale.** `RunClock#idle` (`run_clock.rb:82`) is
`@clock.call - @last_input_at` — seconds since the human last typed, not "the system is idle".
`PromptComposer`'s own doc says `#compose` is called "once per prompt today", so nothing recomposes
the line while a turn runs and the pane holds the pre-turn snapshot. Both halves showed in QA: at
t+3 s the pane read `idle 0s` while ollama was prefilling 4,339 tokens.

**Test hygiene — the prior art bounds the yield, and the interview reset the target.** A prior chunk
already shipped `spec/spec_discipline_spec.rb`, an 800-line Prism scanner, plus a one-time prune
(T16/T18). Its live report (`tmp/spec_discipline_report.txt`, 143 flagged) opens
"**THIS IS A READING LIST, NOT A DELETE LIST**" and records a 25-entry spot-check finding ~88 % of
flagged entries assert something real, "measured precision against 'structurally cannot fail' was
~12 %." An audit pass independently confirmed the mechanical categories are close to exhausted:
**zero** `xit`/`xdescribe`/`pending` anywhere; every `skip` is a runtime capability guard; **zero**
examples with no expectation (18 candidates all turned out to wrap `expect` in a project helper);
**zero** lib constants referenced only from `spec/`. It produced five evidence-named deletions (T11)
and no more. The interview therefore redirected the bulk of the effort to a different question —
public methods that are public only so a test can reach them (T12) — which no existing guard checks.

**A third test-hygiene category, with a shipped precedent and a post-mortem already written.**
`spec/lain/gherkin_spec.rb:427-436` records a misapplication that was found and fixed: a house-format
smoke check that parsed `planning/specs/*.md` used to live in the spec for `Gherkin::Criteria`. Its
epitaph is the clearest statement of the category in this repo --

> It asserted a property of the repository's contents rather than of this subject: prose became part
> of the test surface, so writing a plan doc could turn the whole suite red and block unrelated
> commits, and adding one moved the example count this repo reads to detect a truncated parallel run.
> **`Criteria`'s subject is the criteria a USER of lain writes; that lain's own planning documents use
> the same fenced blocks is a convenience, not the thing under test.**

The fix landed fully: `bin/lint-gherkin-docs` exists and is executable, wired at
`.pre-commit-config.yaml:104-108` as `gherkin-docs`, scoped to staged `planning/specs/*.md` only.
Right check, right layer.

**The line this draws, which T14 depends on.** Guards over lain's own artifacts are legitimate and
this repo defends them explicitly: `spec/output_discipline_spec.rb` parses every file in `lib/`,
`spec/docs_naming_spec.rb` catches prose still naming the deleted `Turn` class, and
`spec/lain/agent_state_machine_diagram_spec.rb` diffs a committed mermaid diagram against the live
machine -- the last two both cite output-discipline as the same posture. In each, the artifact **is**
the subject. The misapplication is different in kind: a spec whose subject is a capability built for
a USER of lain, fixtured with lain's own content, so it passes while saying nothing about the
purpose the capability exists to serve.

**One doc finding, out of scope but recorded.** `tmp/parallel_runtime_rspec.log` no longer matches
CLAUDE.md's "the wall is a MAX" table: `review/source/github_pr_spec.rb` is now the floor at
**21.34 s** (recorded: 11.9 s) while `isolation/worktree_handback_spec.rb` has fallen to 8.42 s from
the recorded 18.5 s. The cost is subject cost, not fixture waste — the file invokes
`it_behaves_like "a diff-bearing review changeset source"` twice against two genuinely different
producers. See **Open decisions**.

## The suite is a subject, not an asset

This chunk adds specs to ten cards and deletes specs in three, and the honest default assumption is
that **it makes the suite bigger without making it better**. Three manual QA rounds have now found
**11, then 7, then 9** defects, and every one of the 27 was green in a suite of ~10,865 examples.
A suite that size which cannot see 27 real defects is not a safety net that needs topping up; it is
an artifact with a measurable blind spot, and the blind spot is what this chunk is spending its
budget on.

Two things follow, and they bind every card.

**A red spec written to a wrong diagnosis goes green and proves nothing.** This is not hypothetical
here: the panel falsified this plan's own first account of F10 (queue wait charged to the upstream)
by observing that the crashed request received *zero* bytes and so could never have armed its own
clock. Specs written to that account would all have passed while F10 survived untouched. So an AC
that pins the *symptom* a QA round observed is worth more than one that pins the mechanism a card
believes in, and where a card asserts a mechanism, its escalation triggers name the existing spec or
comment that would contradict it.

**Growth is not progress, and the plan should be able to say which it got.** T11, T14 and T12 are
the three adversarial passes — assertions that cannot fail, specs aimed at the wrong subject,
visibility bent to let a test reach in — and they are deliberately sequenced ahead of nothing else,
so their findings cannot be diluted by the cards that add. Integration checks require the net
example-count delta to be **stated and justified**, not merely observed to be green.

What this chunk must NOT do is treat "we added tests" as evidence of anything. `spec_discipline`'s
own report already carries the lesson in one line — a mechanical list of suspicious assertions
measured **~12 % precision** against the intent it was built for, which is why T11 names five specs
by hand rather than working the flagged 143.

## Orchestrator contract (plan-specific only)


- Shared files (orchestrator-owned, wiring diffs only):
  - `lib/lain.rb` — load-order manifest
  - `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`
  - `.pre-commit-config.yaml` — T14 may propose hook entries; the orchestrator applies them
  - `CLAUDE.md` — T12 and T13 may propose text; the orchestrator applies it
- **`spec/support/shared_examples/review_surface.rb` is owned exclusively by T8.** It is a
  domain shared example rather than central wiring, and T8's change to it is substantive (a new
  evidence law), not a one-line diff. No other card may touch it.
- **`spec/spec_discipline_spec.rb` is owned exclusively by T12.** T11 deletes specs the scanner
  flags but does not change the scanner.
- **No card may relax a `Metrics/*` limit.** CLAUDE.md: extract a collaborator instead.

## Open decisions

- **Contention throttling was CUT from this chunk, on panel review.** A draft card added a
  per-endpoint admission gate that suspended the stall clock while a request waited for a slot. It
  was **inert**: `#suspend` is reachable only from the two `on_data` procs and
  `@monitor ||= start_monitor` lives inside it, so admission wait is entirely *pre-first-byte* and
  there is no armed clock to suspend. It also put "how many round trips may lain have in flight" in
  a Faraday middleware, when the object that owns the fleet is `Agent`/`Supervisor` —
  `agent.rb`'s `@dispatch_lock` is the correctly-placed expression of the same idea. **T1's
  fiber-scoped clock is expected to remove the symptom entirely.** If QA round 4 still shows
  contention killing turns, throttling returns as a measurement card beside `@dispatch_lock`, not in
  the provider layer. No card is gated on this.
- **F16 (a wedge-only session has no forkable head) is NOT fixed here.** `ForkPoint#recorded_digests`
  (`cli/fork_point.rb:74-77`) collects `SessionRecord::TURN_TYPE` only, so a session whose only
  activity was a `@role[/skill]` spawn journals `child_turn` records and offers no fork point. The
  refusal is already clean and names the session (`"no turn matching …"`, exit 1, no backtrace), so
  this is a coverage gap in the QA procedure rather than a defect. **T13 fixes it in the plan** by
  requiring one ordinary turn before the wedge. Whether a fork should be able to resolve a child
  digest is a real design question about what forking a lineage means, and it is not this chunk's.
- **"Guessing should be opt-in" (from the F8 interview) is recorded, not built.** T6 makes an
  unconfirmed `--num-ctx` fall back to the conservative book, and makes the book re-resolve once the
  provider can answer — which removes the motivation for a "trust my stated window" flag in the
  ordinary case, because the session self-corrects after the first turn. If a flag is still wanted
  once T6 is measured, it is a follow-up. **No card is gated on this.**
- **CLAUDE.md's spec-timing table is stale** (see Grounding). Re-measuring it is a measurement task
  with its own methodology (interleaved best-of-N against a loaded box) and does not belong inside a
  defect chunk. Recorded so the next reader does not trust the table.
- **T11 and T12 have no production construction site, by design** — they delete tests and narrow
  visibility. The reachability rule asks where a capability is built on the real path; for these two
  the answer is "nowhere, deliberately: they remove code rather than add it." Every other card names
  a real site.

## Waves

```
Wave 1: T1, T3, T4, T5, T7, T8, T9, T10    (no unmet deps)
Wave 2: T6 (←T5), T11 (←T8)
Wave 3: T14 (←T1..T11)
Wave 4: T12 (←T14)
Wave 5: T13 (←T12)
Critical path: T8 → T11 → T14 → T12 → T13
```

**The three audit cards are strictly sequential, and that is deliberate.** T11 (five named
deletions), T14 (wrong subject) and T12 (visibility) all rewrite spec files, and an audit that runs
while another audit is moving the same files reports on a tree neither of them will ship. They are
also ordered by widening scope: T11 names five specs, T14 works a fixed roster of capabilities, T12
sweeps `lib/`. Each hands the next a settled tree.

Both wave-2 placements are file serialization, not logic: **T6 follows T5 because both must edit
`spec/lain/cli/backend_spec.rb`** (T5 adds a construction-refusal example, T6 changes the answer of
the existing `:315`); T11 follows T8 because both edit `spec/lain/review/surface/neovim_spec.rb`.
T12 follows everything because a visibility audit that runs while nine cards are moving method
bodies will fight all of them.

**T1 is the card to start.** It is the severity-1 path, it is the one whose premise a sub-agent could
falsify (if `Fiber#raise` cannot reach the owning fiber from a monitor thread, T2's shape changes
too), and that news is worth having on day one.

## Tasks

### T1 — Scope the stall clock to the request it is watching, not to the thread   [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `lib/lain/provider/http/streaming/faraday_handlers.rb`; modify
`spec/lain/provider/http/stall_protection_spec.rb`; create
`spec/lain/seams/stall_under_reactor_spec.rb`
**Reuse:** `StallClock`'s existing `target:` keyword and `@mutex`/`@state` machinery
(`faraday_handlers.rb:137-148`) — the lifecycle is right, only its scoping and its delivery are
wrong; `ErrorWrapping.under(Lain::Error)` (`provider/ollama.rb:79`) and `wrapping_errors`
(`provider/error_wrapping.rb:85-91`), which already turn an `HTTP::Error` into a `Lain::Error`;
`Repl#respond`'s existing rescue (`cli/repl.rb:305-311`), which already fails a turn and keeps the
session — **this card adds no rescue anywhere**; `stall_protection_spec.rb:465-473`, which already
pins the synchronous case producing `Ollama::APIError`; `spec/support/streaming_upstream.rb`'s
`Stall` ending and per-connection scripting; `NetworkAccess.permit_loopback`
**Shared-file wiring:** none
**Reachable from:** `Connection::MiddlewareStack::StallProtection#call`
(`provider/http/connection/middleware_stack.rb:34`) → `StallClock.watching`, built by
`MiddlewareStack#build` for every provider Connection. Already on the real path; this card changes
what the clock belongs to and where its error lands, not whether it is constructed.

The clock is installed in a **thread** variable and raises into a **thread**, while the unit of work
is a **fiber** and parent and child stream concurrently on one reactor thread. Both halves are
wrong and both must change together — see Grounding for why fixing only delivery leaves F10 alive.

**Two changes, one responsibility: make the clock belong to its request.**

1. **Install it in fiber storage**, so two concurrent streams on one thread hold two clocks and
   neither displaces the other. `#unwatch`'s displaced-restore reasoning must then be re-argued for
   **non-LIFO** completion, which fiber scoping makes ordinary rather than exotic.
2. **Deliver to the owning fiber.** `Fiber#raise` **cannot** be used: it raises
   `FiberError: fiber called across threads`, and the monitor is a separate thread. The working
   primitive is **`Fiber.scheduler.fiber_interrupt(fiber, exception)`** — the standard
   `Fiber::Scheduler` hook, not an Async private, verified to deliver cross-thread on this
   toolchain. **`Fiber.scheduler` is nil on the monitor thread**, so capture both the scheduler and
   `Fiber.current` at `#watch` time, on the request's own thread. With no scheduler installed, fall
   back to `Thread#raise` — that is what keeps the synchronous path unchanged.

**`fiber_interrupt` is DEFERRED delivery, and that is a real hazard the card must close.** A
queued interrupt lands when the reactor next resumes that fiber, which may be after `#stop` has
won the mutex and `#unwatch`'s rescue has found nothing — landing instead in the fiber's *next*
tool call or *next* turn. A queued interrupt cannot be recalled, so **the fiber side must check a
disarm** (a token carried on the exception, or `@state` consulted at the delivery point) rather
than relying on the raise never being in flight.

**Acceptance criteria:**

```gherkin
Scenario: two concurrent streams on one reactor hold separate clocks
  Given two fibers on one reactor each streaming from its own fake upstream
  And the first upstream goes silent past the grace while the second streams healthily
  Then only the first fiber raises a stalled-stream error
  And the second fiber's stream completes with all its content

Scenario: a healthy stream is not killed by a sibling's clock
  Given two fibers on one reactor, the first streaming slowly but within the grace
  And the second having already finished
  Then the first fiber completes without a stalled-stream error

Scenario: a stall inside a reactor fails the turn instead of the session
  Given a chat turn running inside an Async reactor against a stalling upstream
  When the grace elapses
  Then the error surfaces as the provider's own API error type
  And it is a Lain::Error
  And the reactor's outer Sync does not see it

Scenario: a completed stream never delivers a late interrupt
  Given a stream that completes in the same moment its grace elapses
  When the fiber goes on to do further work
  Then that later work is not interrupted

Scenario: the synchronous path is unchanged
  Given a provider completing a stalling stream with no scheduler installed
  When the grace elapses
  Then it still raises the provider's API error naming the stall
```
→ spec file: `spec/lain/seams/stall_under_reactor_spec.rb`

```gherkin
Scenario: a stall is still not retried
  Given a stalling upstream and a live retry budget of three
  When the stream stalls
  Then exactly one connection was made

Scenario: the shipped grace and request timeout are unchanged
  When the shipped configuration is read
  Then the inter-chunk grace is still 30 seconds
  And the request timeout is still 300 seconds
```
→ spec file: `spec/lain/provider/http/stall_protection_spec.rb`

**Escalation triggers:**
- **`Fiber#raise` will fail cross-thread — that is expected, not a surprise.** Use
  `Fiber.scheduler.fiber_interrupt`. Escalate only if *that* proves unusable, because every other
  card that depends on F10 being closed depends on it.
- `faraday_handlers.rb:73-85` enumerates "exactly THREE places the async raise can land", and that
  enumeration is a **thread-level** argument that deferred fiber delivery invalidates. Rewrite the
  paragraph in the same commit; if you cannot state the new set, the disarm is not tight enough —
  stop.
- `stall_protection_spec.rb:246-252` asserts structurally that `retry_exceptions` contains nothing
  `StalledStreamError` is a subclass of, and `:257-259` pins its ancestry to `Provider::HTTP::Error`.
  Making it reachable by `wrapping_errors` must not change that ancestry — it would make the error
  retryable and multiply F15 by four.
- `faraday_handlers.rb:56-66` is a "⚠️ THE LOAD-BEARING ASSUMPTION" paragraph about adapters running
  `on_data` on another thread. The scheduler case breaks the same assumption from the other side and
  the paragraph does not cover it. If your change makes it wrong, fix it in the same commit.
- If fiber-scoped storage turns out to be unavailable or unsafe on this Ruby
  (`Fiber[]`/`Fiber.current.storage` vs the fiber-local `Thread.current[]`), **stop and escalate**
  rather than emulating it with a hash keyed by object id — a leak there is a slow memory bug in the
  hot path.

---

### T3 — Bound a connection that never opens, separately from one that never answers   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/provider/http/configuration.rb`; modify
`lib/lain/provider/http/connection/middleware_stack.rb`; create
`spec/lain/provider/http/connect_budget_spec.rb`
**Reuse:** `Configuration.option` (`configuration.rb:58-60`) and the callable-default idiom evaluated
per construction (`:112-117`); `stream_stall_timeout=`'s hand-written setter and `stall_seconds`
(`:139-169`) as the precedent for a knob that validates and names its env var;
`Ollama::Transport::PROBE_TIMEOUT_SECONDS = 2` (`provider/ollama/transport.rb:41`) and `probe_config`
(`:112-117`), which already prove a short budget is the right shape for "is anything there"
**Shared-file wiring:** none
**Reachable from:** `MiddlewareStack#setup_timeout`
(`provider/http/connection/middleware_stack.rb:58-60`), called by `#build` for every Connection.

`setup_timeout` sets one number for everything, so an unroutable address blocks `connect()` for the
full 300 s `request_timeout` and, with `:post` retryable and `ConnectionFailed` in the retry
allowlist, does it four times — ~20 minutes. A local model that thinks for six minutes is a real
shape (`ollama.rb:65-68`) and that is what the 300 s protects; **opening a TCP connection is not**.
Give the connect phase its own, much smaller budget.

**Acceptance criteria:**

```gherkin
Scenario: an unroutable endpoint refuses quickly
  Given a provider pointed at an address that accepts no connection
  When a turn is attempted
  Then it fails within a small multiple of the connect budget
  And it fails with the provider's own API error, not a raw backtrace
  And the message names the address it could not reach

Scenario: a slow first byte is still allowed
  Given an endpoint that accepts the connection and then says nothing for longer than the connect budget
  When a turn is attempted
  Then it is still waiting, bounded by the request timeout rather than the connect budget

Scenario: the request timeout is unchanged
  When the shipped configuration is read
  Then the request timeout is still 300 seconds
  And the connect budget is smaller than it

Scenario: the two budgets reach the built connection as different numbers
  Given a provider built the way the chat builds one
  When its Faraday connection is inspected
  Then its open timeout and its read timeout are not the same value
```
→ spec file: `spec/lain/provider/http/connect_budget_spec.rb`

**Escalation triggers:**
- If bounding connect requires removing `:post` from `retry_options[:methods]`
  (`middleware_stack.rb:109`), **stop** — that line is deliberate and changing it alters retry
  semantics for every provider, which is the orchestrator's call.
- `spec/lain/provider/ollama_spec.rb:729-739` asserts `/api/chat` makes exactly **4** attempts, and
  `:700-728` pins the probe's separate 1-attempt, 2-second budget. If this card changes either count,
  stop and escalate — the probe budget is a different card's contract.
- If Faraday's adapter does not honour a distinct `open_timeout` under `:net_http`
  (`configuration.rb:100`), stop rather than switching adapters. **Faraday derives one from the other
  when only one is set**, which is what the third scenario exists to pin — assert the BUILT
  connection, never the Configuration object.

---

### T4 — Render provider retries live, so a hung endpoint is not a blank screen   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/frontend/decorators/provider_retry.rb`; modify
`lib/lain/frontend/decorators.rb`; create `spec/lain/frontend/decorators/provider_retry_spec.rb`;
modify `spec/lain/frontend/decorators_spec.rb`
**Reuse:** `Frontend::Decorators.for` (`frontend/decorators.rb:28-30`) — its own doc at `:23-26` names
this exact extension ("when a second event type earns rendering, it gets its own decorator here and
one more clause below, and TTY does not change"); the existing `ToolOutput` decorator as the shape to
copy; `Telemetry::ProviderRetry`, already journaled on every arm by the previous chunk's `RetryTap`
**Shared-file wiring:** `lib/lain.rb` — one require line for the new decorator, beside the existing
decorators
**Reachable from:** `Frontend::Decorators.for` (`frontend/decorators.rb:28`), called by the frontend
Channel pump for every event, so a `ProviderRetry` event on the chat's channel renders as soon as this
clause exists. **Only half the events flow today, and this card must say which half.** `Wiring#run` passes the chat
channel to `AgentBuild.spooled_provider(backend, chronicle:, channel:)`
(`cli/wiring/agent_build.rb:96,170-171`), so the PARENT's retries reach the frontend. The toolset's
provider — the one every subagent streams through — is built at `cli/wiring.rb:468` **with no
`channel:`**, so it defaults to `Channel::Null` and a child's retries reach no frontend at all.
Rendering what arrives on the channel is this card; **wiring the child's provider to a channel is NOT
in scope**, and saying so is what stops the QA round-4 driver reading a silent subagent hang as this
card having failed.

`ollama.rb:56-63` states the gap in full: retries are now journaled, but "**the OPERATOR still sees
nothing** … a human watching F7a's hang still watches a blank screen … making it visible live would
be a second decorator, **which is nobody's card yet**." This is that card. It does not bound any
timeout — T3 does that — it makes the waiting legible while it happens.

**Acceptance criteria:**

```gherkin
Scenario: a retry is announced as it happens
  Given a chat whose provider emits a retry event
  When the frontend renders the channel
  Then a line naming the attempt is written to the sink

Scenario: it names which attempt, so repeated waiting is legible
  Given a provider emitting a second and third retry
  When each is rendered
  Then each line names its own attempt number

Scenario: it stays out of the journal's way
  Given the frontend renders a retry event
  Then nothing is written to stdout or stderr outside the frontend
```
→ spec file: `spec/lain/frontend/decorators/provider_retry_spec.rb`

```gherkin
Scenario: an unrendered event type is still skipped silently
  Given an event the frontend does not render
  When the decorator seam is asked for it
  Then it answers nothing
```
→ spec file: `spec/lain/frontend/decorators_spec.rb`

**Escalation triggers:**
- `spec/output_discipline_spec.rb` parses the AST of every file in `lib/` and fails on
  `puts`/`print`/`warn`/`$stdout`/`$stderr` outside `lib/lain/frontend/`. The new file is under
  `frontend/`, so it is legal — but it must still write through the injected sink, not a bare `puts`.
  If a sink is not reachable where the decorator renders, stop.
- `decorators.rb:18-22` records that `ProviderRetry` is unrendered as "a decision, not a gap." This
  card reverses that decision on the evidence of F15. If the reversal turns out to make ordinary
  hosted-provider turns noisy (Anthropic retries on ordinary 429s), stop and escalate — the answer may
  be to render only after the first retry, and that is a policy change worth naming.

---

### T5 — Refuse an `--api-base` that is not a usable HTTP endpoint, at construction   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/cli/backend/endpoint.rb`; modify `lib/lain/cli/backend.rb`; create
`spec/lain/cli/backend/endpoint_spec.rb`; modify `spec/lain/cli/backend_spec.rb`
**Reuse:** `Backend::Ceiling` (`cli/backend/ceiling.rb:26-40`) — the precedent in every respect: a
`Data.define(:flag, :value)` that carries the FLAG as a field so the refusal names itself, raising a
`Lain::Error` subclass; `Backend#initialize`'s eager-refusal list (`cli/backend.rb:137-142`) and the
reasoning at `:108-114` ("construction is the single path every command takes"); `Backend#num_ctx`
(`:280`) as the exact call shape (`@options[:x] && Endpoint.new(...).url`)
**Shared-file wiring:** `lib/lain.rb` — one require line for `cli/backend/endpoint.rb`, beside
`cli/backend/ceiling.rb`
**Reachable from:** `CLI::Backend#initialize` (`cli/backend.rb:137-142`), which every command
constructs — `chat`, `bench record`, `bench arms`. Add the call beside `num_ctx`.

`localhost:11434` is a **valid** URI (scheme `localhost`, opaque `11434`), so the `URI::InvalidURIError`
guard the codebase relies on never fires and Faraday dies on the first turn with
`undefined method 'end_with?' for nil`. Refuse at construction, by name, the way `--max-tokens` and
`--num-ctx` already do. The test is not "does `URI.parse` succeed" but "does this have an http/https
scheme and a host".

**Acceptance criteria:**

```gherkin
Scenario: a scheme-less base is refused by name
  When a backend is constructed with --api-base "localhost:11434"
  Then it raises naming --api-base and the value
  And the message says a scheme is required

Scenario: a base that is not a URI at all is refused the same way
  When a backend is constructed with --api-base "not a url"
  Then it raises naming --api-base rather than a URI parse error

Scenario: a non-HTTP scheme is refused
  When a backend is constructed with --api-base "ftp://example.com"
  Then it raises naming --api-base

Scenario: an ordinary base is accepted unchanged
  When a backend is constructed with --api-base "http://localhost:11434"
  Then the provider receives that base verbatim

Scenario: an unset base is not refused
  When a backend is constructed with no --api-base
  Then no refusal is raised
```
→ spec file: `spec/lain/cli/backend/endpoint_spec.rb`

```gherkin
Scenario: the refusal happens before any provider is built
  When a chat is launched with an unusable --api-base
  Then it exits non-zero with the named refusal and no backtrace
```
→ spec file: `spec/lain/cli/backend_spec.rb`

**Escalation triggers:**
- **`spec/lain/cli/backend_spec.rb:405-410` currently asserts that `--api-base "not a url"` degrades
  the window book to `CONSERVATIVE_FALLBACK` and that `backend.provider` raises `URI::InvalidURIError`.**
  This card makes construction refuse first, so that example changes. Update it deliberately and say
  so in the hand-back; do not delete it.
- `spec/lain/provider/ollama_spec.rb:545-564` pins that `Ollama#context_window_tokens` answers nil for
  a schemeless base. That is the probe's own defence and must keep passing — this card adds a refusal
  one layer up, it does not remove that one.
- `window_book.rb:143-148` and `provider/ollama.rb:184-206` are long comments asserting the old
  division of labour. If this card makes either wrong, fix the comment in the same commit.

---

### T6 — Refuse a `--num-ctx` the model cannot serve, and stop calling an unconfirmed one measured   [wave 2] [risk: medium]

**Depends on:** T5
**Files:** modify `lib/lain/cli/backend/window_book.rb`; modify `lib/lain/provider/ollama.rb`;
modify `lib/lain/provider.rb`; modify `spec/lain/cli/backend/window_book_spec.rb`; modify
`spec/lain/cli/backend_spec.rb`; modify `spec/lain/provider/ollama_spec.rb`; create
`spec/lain/seams/window_self_correction_spec.rb`
**Reuse:** `Backend::Ceiling` (`cli/backend/ceiling.rb:26-40`) and T5's `Backend::Endpoint` — the
flag-carrying-refusal shape this card's refusal copies; `Ollama::Transport`'s `probe_config`
(`provider/ollama/transport.rb:112-117`, `max_retries = 0`, `PROBE_TIMEOUT_SECONDS = 2`) — a bounded
launch probe already exists and this card must not invent a second budget; `ContextWindow.default`
(`context_window.rb:282,358`), the conservative book that already answers `GUESSED`;
`Compaction::Source#need_for` (`compaction/source.rb:339`), which already withholds
`approaching_window` from a guess and needs **no change**; `provider/ollama.rb:178-185`, which argues
this card's own thesis — the probe is "cheap enough to ask per turn" and "memoizing it is what makes
the stale-runner case permanent rather than momentary"
**Shared-file wiring:** none
**Reachable from:** `CLI::Backend#context_window` (`cli/backend.rb:263`) → `WindowBook#book`, the one
book three readers divide by (`StatusFeed`, `Compaction::Source`, `Agent#occupancy`); and
`Backend#initialize` (`cli/backend.rb:137-142`) for the refusal, beside `num_ctx` and T5's endpoint
check.

An operator's `--num-ctx` is a **request**, not a measurement. Today, with nothing resident, the
provider answers nil, `.compact` drops it, and the operator's number becomes the whole book tagged
`PROBED` — the tier whose docstring says "the server said so". Measured: `--num-ctx 999999` on a
model trained to 262,144 journaled `window=999999 provenance="probed"` while ollama served 262,144.

Three changes, and the first is the one that fixes the measured defect:

1. **Refuse a `--num-ctx` above what the model can serve**, by name, at construction. The trained
   maximum is the ceiling a request can never exceed, and it is knowable before any runner loads.
2. **A `--num-ctx` at or below trained is used as the denominator but tagged `GUESSED`**, not
   `PROBED`, until a server confirms it. The number is plausible, so discarding it would over-report
   4x on the ordinary `--num-ctx 32768` case; but nobody measured it, so it may not authorise a
   rewrite. `WindowResolution` already accepts any `(window_tokens, provenance)` pair — no new
   provenance value is needed.
3. **The book stops being a permanent answer**, so the first real `/api/ps` answer upgrades it to
   `PROBED`. **Name the re-resolution trigger and its owner**: "resolves lazily" is otherwise
   satisfiable by "probes on every call", which is exactly the three-readers-disagree failure
   `cli/backend.rb:257-260` exists to prevent and which QA round 3 verified as currently correct.
   `WindowBook` has no clock, no generation and no `Agent`, so the trigger comes from outside it.
   Sharing the memoized object stays; it is the *answer* that refreshes, not the identity.

**⚠️ The trap this card walks straight into, and must not fall in.** `provider/ollama.rb:146-158`
says the trained number **is never returned**, deliberately: `/api/show`'s
`model_info.<arch>.context_length` is the GGUF maximum (262,144) while a loaded runner serves
`min(trained, OLLAMA_CONTEXT_LENGTH, num_ctx)` (32,768 here), and *"divide occupancy by the trained
figure and it under-reports 8x, so compaction never fires"* — the failure this whole area exists to
prevent. So the trained maximum arrives through a **separate, differently-named** accessor whose
docstring says it is a **ceiling for refusing a flag, never a denominator**, and nothing may pass it
to `WindowResolution`. If the two ever merge, this card has reintroduced the bug it was written to
fix, one layer up.

**Degrade, do not refuse, when the ceiling is unknown.** Only ollama publishes a trained maximum;
`Provider`'s base answers nil (`provider.rb:77-79`). A provider that cannot say must not block a
launch — the refusal fires only when a ceiling is known **and** exceeded.

**Acceptance criteria:**

```gherkin
Scenario: a --num-ctx above the trained maximum is refused by name
  Given a model whose trained maximum is known
  When a backend is constructed with --num-ctx above it
  Then it raises naming --num-ctx, the value, and the maximum
  And no chat is started

Scenario: a --num-ctx at or below the trained maximum is accepted
  Given the same model
  When a backend is constructed with --num-ctx at the trained maximum
  Then no refusal is raised

Scenario: a provider that publishes no trained maximum does not block a launch
  Given a provider that cannot report a trained maximum
  When a backend is constructed with any --num-ctx
  Then no refusal is raised
```
→ spec file: `spec/lain/cli/backend_spec.rb`

```gherkin
Scenario: an unconfirmed --num-ctx is the denominator but is not authoritative
  Given no model is resident
  And --num-ctx names a plausible window
  When the window book is resolved for that model
  Then the window is the --num-ctx value
  And its provenance is guessed
  And it is not authoritative

Scenario: a --num-ctx that clamps a reported window keeps its authority
  Given the provider reports a served window larger than --num-ctx
  When the window book is resolved
  Then the window is the smaller --num-ctx value
  And its provenance is probed

Scenario: a reported window with no --num-ctx is probed
  Given the provider reports a served window and no --num-ctx is set
  When the window book is resolved
  Then the window is the reported one and its provenance is probed
```
→ spec file: `spec/lain/cli/backend/window_book_spec.rb`

```gherkin
Scenario: the trained maximum is never offered as a denominator
  Given a model whose trained maximum differs from its served window
  When the served window is asked for
  Then the trained maximum is not what is answered
```
→ spec file: `spec/lain/provider/ollama_spec.rb`

```gherkin
Scenario: the session self-corrects once the runner is resident
  Given a chat launched with --num-ctx while nothing is resident
  When the first resolution happens before the model is loaded
  Then the decision records the --num-ctx window as guessed
  And no history is rewritten
  When the model becomes resident and reports its served window
  Then a later resolution records that window as probed

Scenario: all three readers agree within one turn
  Given any turn
  When the prompt line, the published state and the compaction decision are compared
  Then they report the same window
```
→ spec file: `spec/lain/seams/window_self_correction_spec.rb`

**Escalation triggers:**
- **`spec/lain/cli/backend/window_book_spec.rb:112` ("keeps a num-ctx-limited window probed") must
  keep passing unchanged.** Its comment — "the smaller is still a MEASURED ceiling on a runner that
  answered, so it keeps its authority" — is the case this card must not break.
- **`spec/lain/cli/backend_spec.rb:315` ("stands alone when the provider reports nothing") asserts
  the number 16,384 and will change** — its provenance moves from probed to guessed. Expected;
  update it deliberately and report it.
- `spec/lain/compaction/source_spec.rb:599` constructs a `WindowBook::Served` **directly** with an
  arbitrary window and asserts the signal fires. That is a legitimate direct construction and must
  keep passing.
- **If the trained maximum can only be learned by adding an unbounded launch round trip, stop.**
  `provider/ollama.rb:208-211` measured the existing `/api/ps` probe at 2,002 ms against a black-holed
  host and calls that "the ceiling on what this method can cost a chat". A second probe must live
  inside a comparable budget or the refusal has bought a hang.
- If making the book refreshable lets two readers see different windows **within one turn**, stop
  and escalate — per-turn agreement is the invariant, not per-session immutability.

---

### T7 — Say when a listing found nothing, instead of returning an empty string   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/tools/list_files.rb`; modify `lib/lain/tools/glob.rb`; modify
`lib/lain/tools/grep.rb`; modify `spec/lain/tools/list_files_spec.rb`; modify
`spec/lain/tools/glob_spec.rb`; modify `spec/lain/tools/grep_spec.rb`
**Reuse:** `Tools::WebSearch`'s `not_configured_message`/`no_results_message`
(`tools/web_search.rb:98-105`) — the sentence template this card follows: name the tool, echo the
input, and read as non-retryable; `web_search_spec.rb:36` and `:59` as the assertion template
(distinguishability asserted in **both** directions); `ListFiles#problem_with`
(`tools/list_files.rb:55-61`) as the place a fourth branch does **not** go — an empty directory is a
success, not an error
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring::ToolsetBuild` constructs `ListFiles`, `Glob` and `Grep` into every
chat's toolset; a model calling any of them on an empty result gets the new content.

`Tool::Result` has exactly two constructors and `tool.rb:226-232` forbids inferring error from
content shape, so the fix is the **content string** — exactly where `web_search` put it. In QA a
model given `ok("")` for an empty `lib/` made four redundant `list_files` calls, one bogus
`web_fetch("http://localhost:3000/lib")`, and two escalations to the human, saying "I'm having
difficulty accessing the file structure."

Keep it an **ok** result. Keep the wording distinct from an error so the model does not retry.

**Acceptance criteria:**

```gherkin
Scenario: an empty directory says so
  Given a directory with no entries
  When list_files is called on it
  Then the result is ok
  And the content names the directory and says it is empty
  And the content is not the empty string

Scenario: an empty listing is distinguishable from a missing directory
  Given a directory that does not exist
  When list_files is called on it
  Then the result is an error naming the path
  And its content does not read as an empty directory
```
→ spec file: `spec/lain/tools/list_files_spec.rb`

```gherkin
Scenario: a glob that matches nothing says so
  Given a pattern matching no files
  When glob is called
  Then the result is ok and the content names the pattern and says there were no matches
```
→ spec file: `spec/lain/tools/glob_spec.rb`

```gherkin
Scenario: a grep that matches nothing says so
  Given a pattern present in no file
  When grep is called
  Then the result is ok and the content names the pattern and says there were no matches
```
→ spec file: `spec/lain/tools/grep_spec.rb`

**Escalation triggers:**
- **`spec/lain/tools/glob_spec.rb:34-39` and `spec/lain/tools/grep_spec.rb:63-71` deliberately pin
  `content: ""` today.** This card changes both on purpose. Update them; do not delete them, and do
  not leave one tool speaking and another silent — the inconsistency is half of what confused the
  model.
- `ListFiles#description` (`:24-29`) does not mention empty results while `Glob`'s and `Grep`'s do.
  The description the model sees and the content it receives must agree after this card.
- Several examples assert exact `Tool::Result` equality (`list_files_spec.rb:86,95,105`). If the new
  content changes a **non-empty** result's bytes, you have gone too far — only the empty case moves.

---

### T8 — Acknowledge a review hand-back, so a human can tell it landed   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/review/session.rb`; modify `lib/lain/review/handover.rb`; modify
`lib/lain/review/surface/neovim.rb`; modify
`lib/lain/review/surface/text.rb`; modify `lib/lain/review/surface/null.rb`; modify
`lib/lain/review/surface.rb`; modify `spec/support/shared_examples/review_surface.rb`; modify
`spec/lain/review/handover_spec.rb`; modify `spec/lain/review/surface/neovim_spec.rb`; modify
`spec/lain/frontend/neovim/review_view_spec.rb`
**Reuse:** `Surface::Neovim#mark`'s acknowledgement path (`review/surface/neovim.rb:275`) —
`MARKED` (`:194`) formatted and pushed through `@rpc.review_refused`, rendered by
`65_review.lua:36-38` with the `lain: ` prefix. That is the rail; a verdict acknowledgement rides the
same one. `Handover#mark` (`review/handover.rb:341-346`) and `#open` (`:314-318`) already call
collaborators after a successful write, which `#wrote_verdict` (`:266-272`) alone does not.
`neovim_spec.rb:686` and `neovim_runtime_spec.rb:1045` are the `nvim_exec2("messages")` assertion
style to copy.
**Shared-file wiring:** none — but note `spec/support/shared_examples/review_surface.rb` is owned
exclusively by this card (see Orchestrator contract)
**Reachable from:** `Frontend::Neovim#review_verdict_given` (`frontend/neovim.rb:411`) →
`Review::Handover#wrote_verdict` (`review/handover.rb:266`), reached from the real
`:LainReviewVerdict` command via `RpcThread`'s answered table
(`frontend/neovim/rpc_thread.rb:787-789`).

`:LainReviewVerdict approve` journals `review_verdict` correctly and prints **nothing** — not in
nvim, not in the chat pane. Every lesser gesture in this surface acknowledges itself; the one
terminal gesture does not. This is F4's successor risk: an operator who types the now-correct command
and sees no response reads it exactly as they read F4's broken one.

`#wrote_verdict`'s `nil` return is load-bearing (nil = "taken", which is what lets the editor's
command succeed), so the acknowledgement must be a **push**, like `#mark`'s — not a return value.
Add it to the port so every surface answers it, not just Neovim.

**Acceptance criteria:**

```gherkin
Scenario: a taken verdict is acknowledged to the human
  Given an open review in the editor
  When a verdict is written and accepted
  Then the surface is told the verdict landed
  And the acknowledgement names the verdict word

Scenario: the return value still says "taken"
  Given an open review
  When a verdict is written and accepted
  Then wrote_verdict answers nothing, so the editor's command succeeds

Scenario: a refused verdict is not acknowledged as taken
  Given a policy that refuses the verdict
  When it is written
  Then the refusal sentence is answered
  And no acknowledgement of a landed verdict is pushed
```
→ spec file: `spec/lain/review/handover_spec.rb`

```gherkin
Scenario: every surface answers the acknowledgement
  Given any review surface
  When it is told a verdict landed
  Then it accepts the message and records evidence of the verdict word
```
→ spec file: `spec/support/shared_examples/review_surface.rb`

```gherkin
Scenario: the acknowledgement reaches the editor's own message history
  Given a real headless editor with an open review
  When a verdict is handed back with :LainReviewVerdict approve
  Then the editor's messages include a line naming the verdict
```
→ spec file: `spec/lain/frontend/neovim/review_view_spec.rb`

**Escalation triggers:**
- **`spec/lain/review/handover_spec.rb:195` positively asserts `wrote_verdict` → `be_nil`, and its
  title says "which is how the editor's `:w` succeeds".** That example must keep passing — the
  acknowledgement is a push, not a return. If you find yourself changing it, the design is wrong.
- **`spec/support/shared_examples/review_surface.rb:444-457` explicitly exempts `#verdict` from law
  #5 ("The five COMMANDS only")**, and `review/surface/neovim.rb:74-91` names that exemption as the
  port's one open design hole while rejecting `Verdict::None` as a fix. Adding a **new** port message
  for the acknowledgement is not the same as un-exempting `#verdict`; if the two get conflated, stop.
- Adding a port message means every surface (`Neovim`, `Text`, `Null`, and any test double) must
  answer it, and `Surface.check!` will fail loudly until they do. That is the intended order — let it
  fail first.
- **Adding to the frozen `Surface::MESSAGES` hash trips `Surface.check!` for every double in the
  suite**, not only the three surfaces and the shared example. Budget for it; report the count.
- `frontend/neovim/rpc_thread.rb:702-721` argues that ANSWERED verbs are "exactly the gestures lain
  can REFUSE". This card does not move the verdict off the answered rail; it adds a push beside it.

---

### T9 — Say which actor is asking for an approval   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/approval/queue.rb`; modify `lib/lain/approval/policy_switch.rb`; modify
`lib/lain/frontend/approval_policy.rb`; modify `lib/lain/cli/wiring/toolset_build.rb`; modify `spec/lain/approval_spec.rb`; modify
`spec/lain/frontend/approval_policy_spec.rb`; modify
`spec/lain/frontend/neovim/approval_view_spec.rb`
**Reuse:** `Tools::Subagent`'s `announces_as:` (`tools/subagent.rb:72,76-77`) and its
`@seam.askers.enrol(handle, agent: @name)` (`:625`), documented at `:580-583` as "what a human is
TOLD is asking" — already wired for the researcher at `wiring/toolset_build.rb:325-331`. **The
identity exists; this card carries it one rail further.** `Telemetry::ApprovalPending`
(`telemetry/approval_pending.rb:50`) already has the `requester` field.
`Frontend::Neovim::ApprovalView#row_for` (`frontend/neovim/approval_view.rb:312-314`) already renders
it and already argues why (`:307-311`).
**Shared-file wiring:** none
**Reachable from:** `Approval::Queue.new` at `cli/switchboard.rb:130` — the **one** construction in
`lib/` — and `Approval::Queue#admit` (`approval/queue.rb:293`), which builds every `Pending`. The
child's name arrives via the toolset the subagent is built with
(`cli/wiring/toolset_build.rb:295,325-331`). **`Queue#adjudicate` discards the `context` it is
handed**, and a child's gate resolves the SAME policy through the board by design —
`LivePolicy#call(effect, context) = board.call.policy_switch.call(effect, context)`
(`cli/wiring/toolset_build.rb:85-87`) — so the requester rides that call, which puts
`lib/lain/approval/policy_switch.rb:34` on the path.

`requester` is queue-level state fixed at construction and defaulted to `"agent"`, and nothing ever
passes one, so with a fleet running the parent and the child journal identical records and render
identical prompts. `ask_human` already knows who is asking; `approve` does not. In QA this meant a
`bash` approval arrived while a researcher subagent was mid-conversation, and the only way to learn
it came from the *parent* was to read the spawn's `only:` list out of the journal.

Also render it on the **tty** prompt, which today shows tool and input only.

**Acceptance criteria:**

```gherkin
Scenario: a child's approval names the child
  Given a subagent that announces as a role
  When a gated tool inside that spawn is parked for approval
  Then the journaled pending names that role as the requester

Scenario: the parent's approval is still distinguishable
  Given the same session
  When a gated tool on the parent's own turn is parked
  Then the journaled pending does not name the child

Scenario: an unnamed requester still has a default
  Given a queue constructed with no requester
  When a tool is parked
  Then the pending carries the default requester rather than nothing
```
→ spec file: `spec/lain/approval_spec.rb`

```gherkin
Scenario: the terminal prompt says who is asking
  Given a pending from a named requester
  When the approval prompt is rendered
  Then it names the requester alongside the tool and its input
```
→ spec file: `spec/lain/frontend/approval_policy_spec.rb`

**Escalation triggers:**
- **`spec/lain/frontend/approval_policy_spec.rb:158` is a byte-exact lock**: "renders the ordinary
  prompt, byte for byte, when the pending discloses nothing." Adding the requester changes that
  string. Update it deliberately, and keep the secret-preamble examples (`:114-211`) passing
  unchanged — none of the region bytes may reach the prompt.
- **`spec/lain/frontend/neovim/approval_view_spec.rb:300`, `:329` and `:340` assert the literal
  `"agent"`**, including `eq("agent  bash(...)")`. A per-actor requester breaks all three. They are
  the specs that prove the editor row separates a fleet, so update them to assert *separation*, not
  the literal.
- `telemetry/approval_pending.rb:56-63` records that `outstanding` is ABSENT and must stay absent —
  the record must never carry the file or the region bytes. If threading identity tempts you to widen
  the record beyond `requester`, stop.
- If the child's name is not reachable where the `Pending` is built without passing the whole
  subagent down, **stop and escalate** — a queue that depends on `Tools::Subagent` is the wrong
  dependency direction.

---

### T10 — Stop the prompt line from claiming `idle` while a turn is running   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/frontend/prompt_composer.rb`; modify
`spec/lain/frontend/prompt_composer_spec.rb`
**Reuse:** `PromptComposer::RunState#to_h` (`frontend/prompt_composer.rb:381-384`) and its existing
absent-segment idiom — `#fleet` (`:407-410`), `#occupancy` (`:399-405`) and `#mode` (`:420-424`) all
answer `nil` when there is nothing to say, and the renderer elides a nil segment. A working state is
one more segment of the same kind. `RunClock#idle` (`run_clock.rb:82`) already answers what it
answers; this card does not change the clock.
**Shared-file wiring:** none
**Reachable from:** `Frontend::PromptComposer`, constructed in `cli/wiring` and called once per
prompt to build the `you>` line the operator reads.

`idle` is `@clock.call - @last_input_at` — "seconds since you last typed", not "the system is idle" —
and `#compose` runs once per prompt, so while a turn is in flight the pane holds the pre-turn line.
In QA the pane read `qwen3-coder:30b idle 0s` while ollama was prefilling 4,339 tokens, and the QA
plan's own driving rule ("retry until the status leaves `idle`") turned one prompt into **four
journaled turns**.

**The reachable case has to be named, or the AC pins nothing.** On the tty path `#compose` runs when
the REPL is about to read a line, so the agent is idle at compose time *by construction* — the QA
complaint is a stale rendered pane mid-turn, and this card's own third escalation trigger forbids the
redraw that would fix that. The case that is genuinely both in-flight and composed is the **`human>`
prompt while an `ask_human` is parked**: a turn is running, the composer runs, and today it says
`idle`. Write the ACs against that.

**Reuse the state that already exists.** `Agent::LoopMachine` declares
`awaiting_user / awaiting_model / awaiting_tools / awaiting_approval / stalled / done / failed`
(`lib/lain/agent/loop_machine.rb:70-76`) and generates a predicate per state, so "is a turn in
flight" is readable off the agent `RunState` already holds — no new mutable state, which is exactly
what the first escalation trigger demands.

The narrow, honest fix: **the word `idle` must not appear when the run is not idle.** A line that says
nothing about idleness is better than one that says the wrong thing; the segment is elidable exactly
like `fleet` and `mode`.

**Acceptance criteria:**

```gherkin
Scenario: an idle run reports how long it has been idle
  Given a run with no turn in flight
  When the prompt line is composed
  Then it reports the idle duration

Scenario: a parked question does not claim the run is idle
  Given a turn in flight whose ask_human is parked at the human prompt
  When the prompt line is composed
  Then the line does not contain the word idle

Scenario: the rest of the line is unchanged either way
  Given a turn in flight whose ask_human is parked
  When the prompt line is composed
  Then it still names the model and the occupancy
```
→ spec file: `spec/lain/frontend/prompt_composer_spec.rb`

**Escalation triggers:**
- `prompt_composer.rb`'s class doc argues `#compose` is **pure on the success path** and that a
  caller may call it as often as it likes. If knowing "a turn is in flight" requires the composer to
  reach for mutable run state it does not already hold, stop — the state should arrive as a
  collaborator, the way `status_feed` does.
- The same doc records that Reline fixes the prompt to ONE line and that a two-line rendering arrives
  mangled. Do not grow the line into two.
- If this card starts to require a redraw loop (repainting the line while a turn runs), **stop and
  escalate.** That is a bigger change than the defect warrants and it collides with
  `TTY::Countdown`'s ownership of the bottom line; eliding a wrong word is this card's whole scope.

---

### T11 — Delete five specs that cannot fail for the reason they claim   [wave 2] [risk: low]

**Depends on:** T8 — **and the dependency is semantic, not only file serialization.** T8 adds a port
message, so `neovim_spec.rb:448-457` will cover one more message than it did when this deletion was
reasoned. Fold `surface.verdict` into `:443` **after** T8's message exists, and judge whether the new
message wants folding too.
**Files:** modify `spec/lain/review/surface/neovim_spec.rb`; modify `spec/lain/isolation/null_spec.rb`;
modify `spec/lain/tool/invocation_spec.rb`; modify `spec/lain/cache_profile_spec.rb`; modify
`spec/lain/provider/anthropic_wire_spec.rb`
**Reuse:** `tmp/spec_discipline_report.txt` — regenerate with
`bundle exec rspec spec/spec_discipline_spec.rb -e "prints the counts"` — as the reading list, **not**
as a delete list; its banner and the 12 %-precision measurement are why this card names five specific
deletions rather than working the flagged 143
**Shared-file wiring:** none
**Reachable from:** deferred: test hygiene, removes code rather than adding it — see Open decisions

Each deletion below was individually read and justified; the card is deliberately short because an
audit found the mechanical categories close to exhausted (no `xit`, no `pending`, no rotting skips, no
lib constant kept alive only by a spec). **Delete exactly these; do not extrapolate.**

1. `spec/lain/review/surface/neovim_spec.rb:448-457` — "raises nothing at all, for the whole port".
   Five of its six calls are made verbatim by siblings twelve lines above (`:431`, `:436`, `:440`,
   `:444-445`) against the same subject, each with a real return-value assertion. **Fold
   `surface.verdict` into the `:443` example** rather than losing that one byte; `verdict` under a
   refusing-but-open inlet is already covered at `:403-407`.
2. `spec/lain/isolation/null_spec.rb:27-29` — "releases as a no-op that does not raise". Strictly
   subsumed by `:31-35`, which calls `release` twice and asserts `be(true)` then `be(false)`; if
   release raised, that example fails first and louder. No coverage lost.
3. `spec/lain/tool/invocation_spec.rb:12-15` — pushes to a `Channel::Null` and asserts no raise.
   `Channel::Null#push` is `lib/lain/channel.rb:177`, `def push(_event) = self` — no receiver, no
   branch. The example above it (`:4-10`) already asserts the channel **is** a `Channel::Null`, which
   is the claim. No coverage lost.
4. `spec/lain/cache_profile_spec.rb:100` — **the line only, not the example.** `expect(X).to eq(X)` on
   a frozen constant. Keep `:101`, which is the real half and is what the title claims.
5. `spec/lain/provider/anthropic_wire_spec.rb:43-46` — both left-hand sides resolve through ancestors
   to the same object as the right-hand side, so it is `X == X` twice; the two examples above
   (`:32`, `:36`) already pin the ancestry that makes it resolve, and `:51-53` pins the literal value
   from the module side.

**Acceptance criteria:**

```gherkin
Scenario: the suite still covers what the deletions claimed
  Given the five deletions are applied
  When the full suite runs
  Then it is green
  And the example count has fallen by exactly the number of examples deleted

Scenario: the one byte worth keeping is kept
  Given the detached-editor example that absorbed surface.verdict
  When it runs against a closed inlet
  Then it still exercises verdict alongside the other port messages
```
→ spec file: `spec/lain/review/surface/neovim_spec.rb`

**Escalation triggers:**
- **Check the example COUNT, not just the failure count** (CLAUDE.md): `parallel_tests` reports only
  surviving examples, so a dead worker and a deletion look alike. Compare against a serial run.
- If any deletion turns the suite red, the example was not vacuous — **restore it and report**, do
  not chase the failure.
- Deletion 4 is one line inside an example, and `CacheProfile` overrides `#==` to compare equal to a
  same-content Hash (`cache_profile_spec.rb:104-115`). If removing `:100` changes what `:101` means,
  stop.
- Do not delete anything from `tmp/spec_discipline_report.txt`'s flagged list on the strength of it
  being flagged. That list is ~12 % precise against this intent and the report says so.

---

### T14 — Check that a capability's spec exercises it for the purpose it exists to serve   [wave 3] [risk: medium]

**Depends on:** T1, T3, T4, T5, T6, T7, T8, T9, T10, T11
**Files:** the `spec/` files the audit names — **the hand-back must list them explicitly**; create
`spec/repo_as_fixture_spec.rb`; create `bin/lint-*` scripts only where a moved check earns one
**Reuse:** `spec/lain/gherkin_spec.rb:427-436` — the post-mortem that names this category and the
three symptoms to hunt by; `bin/lint-gherkin-docs` with its `.pre-commit-config.yaml:104-108` entry
(`files: '^planning/specs/.*\.md$'`, staged-only) as the **shipped destination pattern** for a check
that is worth keeping but does not belong in the suite; `spec/output_discipline_spec.rb`,
`spec/docs_naming_spec.rb` and `spec/lain/agent_state_machine_diagram_spec.rb` as the three
legitimate artifact-guards this card must NOT touch
**Shared-file wiring:** `.pre-commit-config.yaml` — one hook entry per moved check, in the shape
`gherkin-docs` already uses; the orchestrator applies them
**Reachable from:** deferred: test hygiene, moves and deletes checks rather than adding a capability
— see Open decisions

Lain builds capabilities **for a user working on their own application**: `Gherkin::Criteria` parses
criteria a user writes, `Skill::Catalog` loads skills a user's project defines, `Review::Source` and
`Survey` read a user's repository, `Plan::Document` and `Epic::Document` parse a user's documents,
and `Grader` scores a user's run. For every one of those, **lain's own repository is a tempting and
wrong fixture**: it is right there, it has the right shape, and a spec built on it passes forever
while saying nothing about the purpose the capability exists for. That is precisely what happened to
`Gherkin::Criteria` — see Grounding.

Work the roster above. For each capability ask one question: **does the fixture stand in for the
user's artifact, or is it lain's own?** Where it is lain's own, replace it with a synthetic fixture
that the spec owns. If the repo-content check has independent value — the Gherkin one did — **move
it to a `bin/lint-*` script under pre-commit rather than deleting it**, exactly as
`bin/lint-gherkin-docs` was moved.

**The mechanical half.** The post-mortem names a symptom that is checkable and is not checked
anywhere today: *"adding one moved the example count this repo reads to detect a truncated parallel
run."* A spec that generates examples from a scan of repository content makes the suite's example
count a function of how much content the repo has — which silently breaks the count comparison
CLAUDE.md tells every reader to use to detect a dead worker. Pin it.

**Acceptance criteria:**

```gherkin
Scenario: the example count does not depend on repository content
  Given the suite's example count
  When a planning document, a shipped skill, or a docs page is added
  Then the example count is unchanged

Scenario: no spec generates examples from a scan of repository content
  Given every spec file
  When it is scanned for example definitions built inside a loop over a repository directory
  Then none is found
```
→ spec file: `spec/repo_as_fixture_spec.rb`

```gherkin
Scenario: a user-facing capability is fixtured with a user-shaped artifact
  Given the spec for a capability that parses or walks a user's artifact
  When its fixtures are read
  Then they are synthetic artifacts the spec owns
  And it does not read lain's own planning documents, skills, or docs as the thing under test

Scenario: a moved check still runs
  Given a repository-content check that was worth keeping
  When it is moved out of the suite
  Then it runs from pre-commit over staged files
  And editing an unrelated document cannot turn the suite red
```
→ spec file: the capability's own spec, named per instance in the hand-back

**Escalation triggers:**
- **Three specs are legitimate artifact-guards and must not be touched**: `output_discipline_spec.rb`,
  `docs_naming_spec.rb`, `agent_state_machine_diagram_spec.rb`. In each, lain's own artifact **is**
  the subject and the repo defends the posture in comments. If the audit's rule would flag them, the
  rule is wrong — stop and re-cut it rather than adding an allowlist.
- `spec/lain/skill/shipped_skills_spec.rb` derives its roster from a directory scan **on purpose**
  (`:13-16`: a hand-maintained list "can only lag it -- a newly shipped skill would be unpinned by
  exactly the spec that exists to pin it, which is how `gherkin-tests` went unnoticed"). Its
  subject genuinely is *what lain ships*. It iterates inside one example, so the count is stable.
  **Do not convert it to a literal roster.**
- If a capability turns out to have **no** user-shaped fixture anywhere — only lain's own content —
  that is a coverage finding, not a fixture swap. **Stop and escalate**: writing the missing fixture
  may be a card of its own.
- If moving a check to pre-commit would make it never run in CI, stop — `bin/lint-gherkin-docs` is
  staged-file-scoped by design, and that trade was made deliberately for docs. It may not transfer.

---

### T12 — Make methods that are public only for a test private, and delete the test   [wave 4] [risk: medium]

**Depends on:** T14
**Files:** modify `spec/spec_discipline_spec.rb`; plus the `lib/` and `spec/` files the audit names —
**the hand-back must list them explicitly**
**Reuse:** `spec/spec_discipline_spec.rb`'s Prism scanner and its `SpecDisciplineReport` writer
(`:365-415`) — this card adds a shape to an existing mechanical guard rather than building a second
one; `spec/output_discipline_spec.rb` as the precedent for an AST guard that FAILS the suite (as
opposed to spec-discipline's report-only posture); `Review::Surface.check!`'s `private_only` check,
which already proves the codebase cares about the public/private split of a port
**Shared-file wiring:** `CLAUDE.md` — the orchestrator applies any wording this card proposes about
testing the public interface
**Reachable from:** deferred: test hygiene, narrows visibility rather than adding a capability — see
Open decisions

CLAUDE.md says specs drive design and that a `Metrics/*` complaint usually means an object is
missing; it does not yet say that a method made public **so a test can reach it** is a design smell
rather than a testing convenience. Most of this suite is LLM-written, which is exactly the
circumstance that produces this shape at scale.

Two deliverables, in this order:

1. **An audit.** Find methods in `lib/` that are public, are called from `spec/` but from nowhere
   else in `lib/`, and whose behaviour is already observable through a public caller. For each: make
   it private and delete or rewrite the spec that reached it directly. **Name every one in the
   hand-back with its call sites** — this is the evidence the orchestrator reviews.
2. **A guard**, so the next round is mechanical: extend `spec_discipline_spec.rb` with a shape that
   reports a `lib/` method referenced only from `spec/`. Keep it **report-only**, like the shapes
   beside it — the existing report's 12 %-precision lesson applies here too, and a ratchet that fails
   the suite on a heuristic will be worked around rather than heeded.

**Acceptance criteria:**

```gherkin
Scenario: a method public only for a test becomes private
  Given a lib method called from spec but from nowhere else in lib
  And its behaviour is observable through a public caller
  When the audit is applied
  Then the method is private
  And the spec that called it directly is deleted or rewritten against the public caller

Scenario: behaviour coverage survives the narrowing
  Given a method the audit narrowed
  Then the hand-back names the public caller's example, by file and line, that still covers it
  And that example fails when the narrowed method's behaviour is broken

Scenario: the guard reports the shape without failing the suite
  Given a lib method referenced only from spec
  When the discipline scanner runs
  Then it appears in the report
  And the suite still passes

Scenario: an ordinary public method is not reported
  Given a lib method called from other lib code
  Then it does not appear in the report
```
→ spec file: `spec/spec_discipline_spec.rb`

**Escalation triggers:**
- **A method reachable only from a spec may be dead code, not a testing seam.** Those are two
  different findings with opposite fixes (make private vs delete entirely). If the audit finds any,
  **stop and escalate** rather than guessing — deleting a capability is the orchestrator's call.
- **Three further shapes are legitimate and the audit will hit them first.** *Property-test law
  counterexamples* (`Algebra::Monoid#not_a_monoid`, `Algebra::Pure#not_pure`) exist to be called by a
  spec — that is their whole job. *Alternative constructors* (`Question::Answer.from_body`,
  `Approval::Gate.from_journal`, `Consolidation.from_records`) are public API by intent even when only
  a spec exercises them today. *Documented algebra predicates* (`Timeline#ancestor_of?`,
  `Timeline#dominates?`) are the DAG's public vocabulary. Narrowing any of these is a defect, not a
  cleanup.
- **Injected collaborators and Null Objects will look like this shape and are not it.** `Sink::Null`,
  `Provider::Mock`, `Effect::Handler::Mock` and the `shell_out_factory` seam exist because the specs
  needed them, and CLAUDE.md says so approvingly. If the guard reports them, the guard is wrong.
- A port's messages (`Review::Surface::MESSAGES`, `Tool`'s interface) are public **by contract** even
  when only a shared example calls them. Do not narrow a port.
- **The candidate population is ~74, not ~20** — measured at planning time by a Prism scan for public
  `def`s in `lib/` with zero references elsewhere in `lib/` and at least one in `spec/`. So a
  whole-tree sweep WILL blow any small bound and deliver a list instead of a change. **Scope the audit
  to one subtree** (`lib/lain/review/**` is the suggested first, being the largest cluster), make the
  guard the primary deliverable, and name the subtree in the hand-back so the next pass can continue.
  Escalate if even the subtree exceeds twenty.
- Do not change `spec_discipline_spec.rb`'s existing two shapes or its report-only posture.

---

### T13 — Rewrite the QA plan's expectations for the round this chunk enables   [wave 5] [risk: low]

**Depends on:** T12
**Files:** modify `planning/qa-manual-end-to-end.md`; modify `planning/README.md`
**Reuse:** `planning/qa-findings-round2-2026-08-18.md` — every finding's reproduction, verbatim;
`planning/qa-bowling-oracles.rb`, the committed driver-owned five-oracle grader the plan already
points at; the plan's existing per-act structure, which was rewritten against this round's evidence
and should be edited, not replaced
**Shared-file wiring:** none
**Reachable from:** deferred: documentation — it is the input to the manual pass named in
Integration checks, which is where this chunk is verified end to end.

The QA plan currently tells its next driver to expect the round-3 **defects**. After this chunk those
expectations are all wrong, and a stale expectation is worse than none: it reads as "not a known
issue" and sends the next reader hunting a regression that is not there. That failure mode is already
recorded in the plan itself, about flaky-spec line numbers.

For each of F8, F9, F10, F11, F12, F13, F14 and F15, replace "here is the defect" with **"here is what
correct now looks like, and here is the reproduction that must now fail differently."** Keep F16
described as a known gap with the Act 3 workaround (one ordinary turn before the wedge) already in
place. Add the two preconditions this round proved load-bearing and that no act currently captures:
`OLLAMA_NUM_PARALLEL` and `n_slots`.

**Acceptance criteria:**

```gherkin
Scenario: every fixed finding has a stated new expectation
  Given the QA plan after this card
  When it is read for F8 through F15
  Then each names what correct behaviour now looks like
  And each names the reproduction that must now fail differently

Scenario: the plan names its own findings document
  Given the QA plan after this card
  Then it links the round-3 findings and the round it produced

Scenario: the index entry says what actually landed
  Given planning/README.md already carries this chunk's row, written when the plan was emitted
  When the chunk has landed
  Then the row describes the outcome rather than the intent
  And it names anything the execution log records as deferred or changed
```
→ spec file: none — this card is documentation. Its verification is the Integration-checks manual
pass, which is driven from the document this card produces.

**Escalation triggers:**
- **If any card in this chunk landed a behaviour different from what its ACs describe, the plan text
  must follow the code, not the plan.** Read the execution log before writing an expectation, and
  flag any divergence to the orchestrator rather than documenting the intent.
- The QA plan is a living document with a stated premise ("every defect this has found so far lived
  in a seam that had specs on both sides"). This chunk adds specs on both sides of eight such seams.
  If that premise now looks false, say so in the document — it is the plan's own thesis and worth
  more than a tidy edit.
- Do not delete the round-3 findings document. It is the evidence for every expectation this card
  writes.

## Integration checks

Run after the last wave lands.

- `bundle exec rake pspec` — full suite green. **Check the example COUNT against a serial run**, not
  just the failure count: `parallel_tests` reports only surviving examples, so a dead worker and a
  passing run look alike. T11 and T12 both change the count deliberately, so record the expected
  delta before running.
- `bundle exec rubocop` — bare, never naming a `.toml` on the command line.
- `cargo test && cargo clippy --all-targets -- -D warnings` — untouched by this chunk, run anyway.
- `pre-commit run --all-files`. `shellcheck` is known-missing on this box and is the one expected
  failure; anything else is real.
- **State the net example-count delta, and justify it.** Record the count before and after, the
  number added per defect card, and the number removed by T11/T12/T14. A chunk that ends with a
  larger suite and no deletions has not done the adversarial half of its job, whatever the defect
  cards achieved. Growth is a number to explain, not a result to report.
- **Ask the question the three QA rounds keep answering badly:** for each of F8–F15, name the
  existing spec that *should* have caught it and say why it did not. Some will have no candidate at
  all — that absence is the finding, and it belongs in the round-4 findings document rather than in
  a card, because it is evidence about the suite rather than a change to it.
- **Regenerate the discipline report** and diff it against the copy taken at planning time

  (143 flagged / 130 `sole_raise_error` / 13 `nested_expect`): T11's five deletions and T12's audit
  should move it, and an unexplained move is a finding.
- **Replay without a model server:** run the previous chunk's `:vcr` examples with no ollama running.
  T3 and T6 both touch the launch path; a cassette that now needs a live server is a regression.

### Then: manual QA round 4 — the last portion of this chunk

**This is deliberately NOT a task card.** `/execute-plan` runs sub-agents in isolated worktrees, and a
QA round needs the real repository, a real tmux server, a real editor and a human at the approval
gate — which is the point of the exercise, not an accident of it. A worktree would also trip
CLAUDE.md's `rm .git` trap. So it is an orchestrator-and-human step, named here so it cannot silently
drop.

Run it from `planning/qa-manual-end-to-end.md` **as T13 leaves it**, and produce a dated findings
document beside the existing two. Priorities, in order:

1. **Act 2 with a subagent live, on a single-slot server** — the exact shape that killed the session.
   Confirm `OLLAMA_NUM_PARALLEL:1` first, then run `/create-plan`. T1 and T2 both have to hold, and
   this is the only place they are tested together against a real contended server.
2. **Act 8's two `--api-base` probes, driven as turns** (`--prompt`), not judged at launch: the
   scheme-less typo must refuse by name at construction (T5), and the unroutable address must fail
   quickly (T3) with the retries visible while it happens (T4).
3. **Act 1's four window cases including `--num-ctx` above the trained length** (T6), reading the
   journal's `provenance` field, and confirming a cold session self-corrects to `probed` after the
   runner is resident.
4. **Act 4's hand-back** (T8) — the gesture whose failure mode is that the human cannot tell it
   worked, which no green suite can demonstrate.
5. **Act 2's compaction-at-scale step**, which round 3 never reached because the session died first,
   and which remains the least-exercised path in the plan.

Success is not "nothing went wrong." It is that **every defect this round found behaves differently**,
that each knowingly-partial fix fails the way its documentation says, and that anything new is
recorded with a reproduction rather than a description. A round that finds nothing new did not push
hard enough — round 2 found eleven behind a green suite, round 3 found nine.
