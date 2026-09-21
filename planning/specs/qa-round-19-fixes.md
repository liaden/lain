# QA round 19 fixes — the cap, the gate, the root, and two silent write-offs

status: ready
commit-mode: orchestrator-commits
language: ruby
panel: Ruby (Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson)

## Intent

Fix every HIGH, MED-HIGH and MEDIUM finding from
[`planning/qa-findings-round19-2026-09-21.md`](../qa-findings-round19-2026-09-21.md) that is
reachable from a `/` command, `lain up`, or a configured setting. Four HIGHs head the list: the
ollama arm never puts a generation cap on the wire; an in-root symlink under an ordinary name is
auto-approved with nobody asked; `lain chat --root` is silently ignored; and a detected
`malformed_response` is delivered to the parent as a successful result.

Three of these are instances of one house rule the codebase states and has not finished applying —
**a value that is already known is simply not passed to the one place that needs it** — and two are
instances of a second: **a refusal must arrive in the currency its reader rescues.** Where the
grounding found the same hole twice the plan closes the class rather than the instance: `ChainFold`
gets the same required-key helper as `MessageReplay`, and every `Backend.new` call site states its
root rather than only the one that was measured.

Out of scope by decision, each with its reason in **Open decisions**: `bench arms`'
iteration-ceiling abort (bench-only); a consumer for `Telemetry::TruncatedStream` (its two `kind`
readings must route differently, so a shared seam would be a base class extracted from a
coincidence); and scoping the session write-set across a rebind (T10 contains the symptom and names
what that costs).

**15 cards in 3 waves.** Panel-reviewed 2026-09-21; the review changed the plan substantially —
see the note at the end of **Grounding**.

## Grounding

Verified 2026-09-21 by four parallel read-only explorations of the main tree (worktrees under
`.claude/worktrees/` and `tmp/x86_64-linux/stage/` hold stale copies — ignore them when grepping).

**Where docs and code disagreed, and which won:**

- `planning/qa-findings-round19-2026-09-21.md` is a findings doc; **nothing enforces it**. Every
  claim below was re-verified against code.
- `spec/lain/seams/recorded_run_spec.rb:190` carries a comment asserting the encoder renders no
  `num_predict` and that `max_tokens` "bounds nothing on this arm". True today; **T1 makes it a
  false comment** and must correct it.
- `lib/lain/sensitivity.rb:29-35` justifies lexical classification because "a spurious match costs
  one prompt". That cost model is written for the read-refusal path and is **false** under
  `ComposedTerm`, which approves. Code won; the comment is corrected in T4.
- `spec/lain/project/root_defaults_spec.rb` is green and correct, and **cannot see** the `--root`
  defect: it scans parameter defaults, while `backend.rb:484` omits the keyword at a call site.
  Its own docstring declares two holes; this is a third.
- `README.md:144` hand-copies the state-machine arc that `docs/agent-state-machine.md` generates.
  Both go stale under T2.

**Key mechanism facts the cards depend on:**

- `Provider::Ollama::Encoding#encode` (`encoding.rb:64-67`) never reads `request.max_tokens`;
  `SAMPLER_KEYS` (`:35`) has no `num_predict`, which occurs **nowhere** in `lib/`. `options` is
  purely a projection of `Request#extra` through `SAMPLER_KEYS` (`#encode_options`, `:160-164`), so
  a cap sourced from `request.max_tokens` **cannot** be added by extending that constant —
  `CLI::Backend#sampler_extra` (`backend.rb:695`) reads it externally and keys on `extra.key?`.
  `#optional_fields` (`:74-78`) already takes the whole `request` and is the seam.
  `anthropic_encoding.rb:104-110` sends it unconditionally — an arm asymmetry, not a policy.
- `Telemetry::MalformedResponse` and `Telemetry::TruncatedStream` have **zero consumers** outside
  their producers. A prose tool call decodes to `StopReason::END_TURN`
  (`decoding.rb:153-161`), which `agent/loop_machine.rb:46` routes to the **healthy** arm.
  `StopReason` (`stop_reason.rb:17-33`) is closed and deliberately pinned to Anthropic's enum.
- `ComposedTerm#approvable?` (`composed_term.rb:381-384`) is a seven-predicate conjunction.
  `ordinary_words?` classifies the **literal word**; `confined?` and `plain_content?` both already
  `realpath` the same word in the same call. `Confinement#landing_of` (`board_build.rb:430`) is
  **already public** and already called by the content predicate. `Sensitivity`'s no-syscall
  contract is enforced by a runtime canary, a Ripper source audit, **and** an explicit pin reading
  "a symlink to a denied path is ordinary" (`sensitivity_spec.rb:854-965`).
- History is written at `stdin_pump.rb:308-312`, **two statements upstream of `InputRail`**, and
  persists `line` rather than the assembled `carried.partial + line` the rail receives. Only the
  in-process TTY pump writes it; the `lain input` socket and nvim's gesture rail never do — so
  history is both unfiltered and **incomplete**.
- `Backend.new` (`chat_launch.rb:207`) takes options + profile only, while `chat_launch.rb:225`
  already holds the resolved `#project`. `Wiring#root` (`wiring.rb:519-521`) is correct and
  documented "never `Dir.pwd`"; `Backend` is the one object on the chat path above it that reads disk.
- `Snapshot#relative` (`snapshot.rb:155-157`) relativizes with no containment check, so an
  out-of-root path becomes a `../…` key at **record** time. `/undo` addresses `@entries.last` only
  (`snapshot_log.rb:81-87`) and a blocked entry is never popped, so one bad key wedges every later turn.
- `Command::Stop#call` reads no state at all (`stop.rb`, returns `NOTHING_RUNNING` unconditionally).
  `Supervisor` has a total `#stop` (`supervisor.rb:157-164`), idempotent `Actor#stop`
  (`actor.rb:147-158`), and is **already on the command env** — `Undo#quiet!` (`undo.rb:126-133`)
  already enumerates it with exactly the predicate `/stop` needs.
- `InputPane` caches the whole last frame in `@drawn` (`input_pane.rb:208`) and reads it only for
  dedupe. It already runs a `TICK = 0.1` loop (`:275-288`). `prompt_composer.rb:260-264` forbids a
  WINCH trap (`Signal.trap` replaces Reline's) and `:251-259` forbids polling `TTY::Screen` (forks).
- `up.rb:1031` raises `ChatDied` on the line **before** `@input_corpse&.call` at `:1036`, so the
  "so this cockpit has no keyboard" sentence (`:1187-1190`) is unreachable when both panes die.
- `Backend#compaction_header` (`backend.rb:475`) is literally one key. `SessionRecord` already has
  the only-when-named idiom (`session_record.rb:73-80`).

**What the panel review changed (2026-09-21).** The draft would have shipped a green suite over a
dormant feature, which is the failure this process exists to catch:

- **T2 was unimplementable as drafted.** `Response#initialize` runs `StopReason.normalize`
  (`response.rb:21`), which rewrites anything outside `KNOWN` to `UNKNOWN` — so a `MALFORMED` added
  to `ALL` alone would be silently discarded while the turn still failed, and the card's own
  acceptance criteria would have passed. The card now settles the `KNOWN`/`ALL` tiering first, adds
  `response.rb` to its files, and carries an AC clause that fails on the broken path.
- **`Telemetry::TruncatedStream` was cut from T2** (Open decision 5), on its own documentation.
- **T2's `request_digest` addition was dropped**: threading the Request into `#build_response` is
  forbidden in writing at `decoding.rb:63-67`.
- **T10's "the omission is journaled" had no production writer** — `snapshot.rb:8-9` reads "Nothing
  here journals" and its constructor takes no sink. The card now includes `snapshot_slot.rb`, where
  the journal already is, and puts the containment at the `Scope` seam the class's own docstring
  names rather than one layer below it. Its `Undo#reverted` half became **T19**.
- **T6 was under-declared.** `Backend.new` has **four** call sites in `lib/`, not one, and
  `cli/consolidate.rb:75` was a live same-wave conflict with T16.
- **A standalone rename card was folded into T7 and a whole wave disappeared.** The collisions it
  cited existed because it existed; carried in the card whose claim it makes true, it costs nothing.
- **T8's dependency on T7 was fabricated** (zero file overlap) and T4 was folded into T3.

## Orchestrator contract (plan-specific only)

- **Shared files (orchestrator-owned, wiring diffs only):** `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`, `exe/lain`, `README.md`, `CLAUDE.md`, `ARCHITECTURE.md`.
  **No card is expected to need `exe/lain`** — verified: `ChatLaunch.new` (`:1125`) already passes
  `**project_override`, so T6's change is entirely inside `ChatLaunch`/`Backend`, and `launch_plan`
  (`:1206`) is untouched by T8. If a card finds it needs a line there, that is a wiring diff and a
  signal the seam moved — hand it back rather than editing.
  `README.md` is shared because T2's state-machine arc and T5's rename may both touch it;
  `CLAUDE.md`/`ARCHITECTURE.md` because T5 renames a constant their prose names.
- **`docs/agent-state-machine.md` is GENERATED** (`spec/lain/agent_state_machine_diagram_spec.rb:16`
  fails on drift). T2 regenerates it and hands back the README arc as a wiring diff.
- **Specs must be loadable in isolation** — `spec/spec_helper.rb` does `require "lain"` and
  pre-commit stashes unstaged tracked changes, so a new lib file and its spec land in the **same**
  commit (CLAUDE.md, "Committing").
- **No inline `rubocop:disable`.** A tripped `Metrics/*` limit means extract a collaborator or raise
  the limit in `.rubocop.yml` in its own commit, with the reason there.
- **A tripped `Metrics/*` limit is a HAND-BACK, and no card may resolve it alone.** `.rubocop.yml` is
  orchestrator-owned, so raising a ceiling is a wiring diff plus its own commit; extracting a
  collaborator may be in the card's scope, but choosing between the two is not. Three files in this
  plan are the candidates — `cli/up.rb` (1,317 lines, T8), `frontend/input_pane.rb` (412, T17) and
  `approval/composed_term.rb` (427, T3) — all passing today against
  `Metrics/ClassLength: Max: 300` (`.rubocop.yml:190-191`), so all have headroom or are comment-dense.

## Open decisions

1. **`bench arms`' iteration-ceiling abort (Fp-3) is deliberately NOT fixed here.** One task hitting
   the per-ask ceiling aborts the whole run and discards completed grades. It is real, but it is
   reachable only from `lain bench arms` — no `/` command, no `lain up`, no config. Deferred to a
   bench chunk. No card depends on it.
2. **`Paths#project_hash` keys sessions/status/epics/worktrees off `Dir.pwd`** (`paths.rb:251`), so
   `--root` does not move a session's *storage* even after T6. `root_defaults_spec.rb` already
   records this as "a KNOWN DEFECT… ticketed separately" — it needs a session-migration plan, not a
   keying change. **T6 fixes what `--root` governs (slots, skills, completion), not where sessions
   land**, and T6's AC says so explicitly. Out of scope; named here so the remaining half is visible.
3. **`lain help` prints 39 lines**, 27 of them Thor expanding five subcommand namespaces inline.
   Not a defect and not in this plan. Recorded because the audience split it implies — chat operator
   vs bench researcher — is a design question deserving its own chunk. There are **no QA-only
   commands** in `exe/lain`; `bin/` is already the unshipped dev drawer (`gemspec:40-41`).
5. **`Telemetry::TruncatedStream` is NOT given a consumer here**, though it has the same
   zero-consumer shape as `MalformedResponse`. Its `kind` carries two readings that route
   differently — `:unterminated` (the prose is a fragment) and `:counts_absent`, where its own doc
   says "a terminal frame DID arrive, so the prose is whole", which is not a failure at all — and
   `truncated_stream.rb:66-72` argues that refusing a content-bearing body "would trade a silent
   accounting bug for a lost answer, which is the worse defect", calling hardening the readers
   "separate work". A seam whose two users must behave differently is not a seam. T2 builds the
   consumer for `MalformedResponse` and documents it as the place a second producer would plug in.
   **The debt stays visible here:** `TruncatedStream` still reports to nobody.
6. **The root cause under T10 is NOT fixed: the session write-set is cumulative across a scope
   rebind.** `Session#rescope` (`session.rb:86-89`) swaps `@scope` and nothing else, while
   `SnapshotSlot#rebind` (`snapshot_slot.rb:121-131`) moves the root — so the recorder's root moves
   under a write set that does not. T10 contains the symptom at the `Scope` and names the symmetric
   consequence (home-root writes are dropped from a plan-scope snapshot). Scoping the write-set
   itself is follow-up work because `Session#writes` is also read by `written?`
   (`session.rb:296-298`) and the memory and status surfaces.

**Nothing in this list gates a card.** Each is a recorded boundary, not a pending question; T12's
design choice (a required `compaction:` member on `Bench::Session::Recording`, on
`session.rb:125-132`'s argument that a comparability axis must carry no default) is **settled**, and
its risks live in that card's escalation triggers rather than here.

## Waves

```
Wave 1: T1, T3, T6, T8, T9, T10, T13, T14, T17, T19
Wave 2: T2 (←T1), T7, T11, T16
Wave 3: T18 (←T2, T3)
```

Critical path: **T1 → T2 → T18**, three cards deep, and the plan runs in exactly three waves.

**Why the wave-2 cards are there, since only T2 has a dependency.** T7 carries the
`InputRail` → `Intake` rename, which touches 13 `lib/` files including `cli/wiring.rb` (T6),
`cli/command/stop.rb` (T9) and `frontend/input_pane.rb` (T17) — so it cannot run beside them. That
constraint follows the rename wherever it lives; an earlier draft gave it a card and a wave of its
own, which manufactured the collision it was then serialized to avoid, and paid a quarter of the
plan's wall for a change that fixes no finding. Carrying it in T7 costs nothing extra: T7 has to
open `input_rail.rb` regardless, and the rename lands in the same commit as the claim it makes true.
T11 is held off `cli/backend.rb` (T6) and `bench/session.rb` (T13); T16 off `cli/consolidate.rb`,
which T6 now edits because `Backend.new` is called there.

## Tasks

### T1 — Put the generation cap on the ollama wire   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/ollama/encoding.rb`,
`spec/lain/provider/ollama/encoding_spec.rb`, `spec/lain/provider/ollama_spec.rb`,
`spec/support/shared_examples/provider_parity.rb`, `spec/lain/seams/recorded_run_spec.rb`
**Reuse:** `#optional_fields` (`encoding.rb:74-78`) already takes the whole `request`;
`anthropic_encoding.rb:104-110` is the reference arm; `provider_parity.rb`'s `sample_request`
already carries `max_tokens: 8`.
**Shared-file wiring:** none
**Reachable from:** `CLI::Backend#context` → `Context#render` → `Provider::Ollama#complete`. Every
`lain chat`/`lain up` turn on the default provider. `--max_tokens` / `$LAIN_MAX_TOKENS` are declared
at `exe/lain:443-447` and reach this today as a journaled value that is never sent.

**Do NOT add `num_predict` to `SAMPLER_KEYS`** — `CLI::Backend#sampler_extra` (`backend.rb:695`)
reads that constant externally and keys on `extra.key?`, which `max_tokens` can never satisfy.
Merge it in `#optional_fields` instead.

**Two written rationales are falsified by this card and both must be rewritten**, not just the first:
`encoding.rb:31-34` ("a request nobody tuned renders with no `options` object at all"), and
`backend.rb:688-692`, which makes the parallel claim that an encoder-side default "would put an
`options` object on every ollama request in the process". After this card that is exactly what
happens, deliberately — because a cap is not a tuning knob the operator opted into, it is a bound
every request has always declared and never sent.

**Acceptance criteria:**

```gherkin
Scenario: the cap reaches the wire
  Given a Request with max_tokens 4096 and no sampler knobs in extra
  When the ollama encoder encodes it
  Then the encoded body's options carry num_predict 4096

Scenario: the cap does not displace a tuned knob
  Given a Request with max_tokens 4096 and num_batch 2048 in extra
  When the ollama encoder encodes it
  Then the encoded body's options carry both num_predict 4096 and num_batch 2048

Scenario: every provider arm puts the cap somewhere on the wire
  Given the shared provider contract's sample request, which declares a max_tokens
  When each arm encodes it
  Then the encoded body carries that cap under the arm's own spelling
```
→ spec files: `spec/lain/provider/ollama/encoding_spec.rb`,
`spec/support/shared_examples/provider_parity.rb`

**Escalation triggers:**
- **Five specs assert the opposite and must be rewritten deliberately, not patched around:**
  `encoding_spec.rb:119-124` ("emits no options key at all when no sampler key is present",
  defended by an in-file comment), `:48-54`, `:72-78`, `:105-117`; and `ollama_spec.rb:449-452`,
  `:455-457`, `:463-466` (`expect(encoded[:options]).to be_nil`). If any of these reads as a
  contract a caller depends on rather than a snapshot of today's bytes — stop and confirm.
- `spec/lain/seams/recorded_run_spec.rb:190`'s comment becomes false. Correct it in this card.
- If `CLI::Backend#sampler_extra` turns out to compact a `num_predict` key into `extra`, the merge
  would double-write — stop and confirm before changing `SAMPLER_KEYS`.

---

### T2 — Fail a turn whose only output was a malformed tool call   [wave 2] [risk: high]

**Depends on:** T1
**Files:** `lib/lain/stop_reason.rb`, `lib/lain/response.rb`, `lib/lain/agent/loop_machine.rb`,
`lib/lain/agent.rb`, `lib/lain/provider/ollama/decoding.rb`,
`lib/lain/telemetry/malformed_response.rb`, `docs/agent-state-machine.md`, and their mirrored specs.
**Reuse:** `Tools::Subagent#undeliverable` (`subagent.rb:572-580`) is the house idiom — a
nil-or-reason predicate over a Response feeding a named refusal. `Repl::Outcome::SETTLED`
(`outcome.rb:36-40`) is an allow-list, so a `:failed` arm yields a non-zero exit for free.
`Lineage#ended` (`lineage.rb:108-114`) already writes `lifecycle: failed` with **no** `"result"`,
and `Fleet#state_of` (`fleet.rb:178-182`) already renders that as `failed`. **Nothing new is needed
on the subagent or fleet side.**
**Shared-file wiring:** `README.md:144`'s hand-written arc `SR -->|"max_tokens · refusal"| FAIL`
gains the new reason — hand the orchestrator that one-line diff.
**Reachable from:** `Provider::Ollama::Decoding#decode_stop_reason` (`decoding.rb:153-161`) →
`Response#initialize` (`response.rb:16-25`) → `Agent#transition`'s
`__send__(:"#{response.stop_reason}!")` (`agent.rb:599-604`) → the `LoopMachine` event
(`loop_machine.rb:41-49`) → `FAILURE_REASONS` (`agent.rb:54-56`). Every link is in the file list
above; nothing is constructed that production does not already build.

**SETTLE THE ENUM'S TIERING BEFORE WRITING ANY CODE — this decides whether the card works at all.**
`Response#initialize` runs `stop_reason: StopReason.normalize(stop_reason)` (`response.rb:21`), and
`normalize` returns `UNKNOWN` for anything outside `KNOWN` (`stop_reason.rb:29-32`). So a naive
addition **fails silently in the worst way**: with `MALFORMED` in `ALL` only, `Response` rewrites it
to `:unknown`, the turn still lands in `:failed`, and this card's first two acceptance criteria pass
while the reason never existed and the journal reads "unrecognized stop_reason from provider".

The ruling this card implements: **`KNOWN` is the WIRE vocabulary — what a provider can send — and
`ALL` is the MACHINE vocabulary, every reason the loop can route.** `MALFORMED` is lain's own reading
of a wire response, not a value any provider emits, so it joins `ALL` and **not** `KNOWN`, and
`Response` must stop routing an already-typed reason through `normalize`. Say that in
`stop_reason.rb`'s own prose, because today's comment (`:5-10`) claims the whole module is Anthropic's
enum, and after this card it is not.

**Do NOT reuse `StopReason::REFUSAL`.** `REFUSAL` means the model declined; a prose tool call is the
model trying and failing to be parsed. Collapsing them makes
`FAILURE_REASONS[REFUSAL] = "model refused to continue"` a lie on half its occurrences and makes a
safety refusal indistinguishable from a parse failure in the one line a reader greps for.

**Do NOT thread the Request into `#build_response` for a join key.** `decoding.rb:63-67` forecloses
it in writing — "`#build_response` is handed the body and not the Request, and reaching for one would
put this decision above the provider that owns its model family's failure modes". `MalformedResponse`
therefore ships **without** a `request_digest`, unlike its siblings. That is a deliberate asymmetry;
record it on the record's own docstring so the next reader does not "fix" it.

**`Telemetry::TruncatedStream` is deliberately NOT folded in** — see Open decisions 5.

The detector still **reports and does not repair**: no call is reconstructed and none is executed.
What changes is that the turn is refused by name instead of landing on the healthy arm.

**Acceptance criteria:**

```gherkin
Scenario: a prose tool call fails the turn under its own name
  Given an ollama response whose content is a closed <function=...> envelope and no tool_calls
  When the agent transitions on it
  Then the run lands in the failed state and its failure reason names a malformed response
  And that reason is not the unrecognized-stop-reason diagnostic
  And the journal still carries the malformed_response record with its tool name and excerpt

Scenario: a child whose only output was a malformed envelope does not answer its parent
  Given a one-shot subagent whose response is a prose tool call
  When the spawn completes
  Then its completion message carries lifecycle failed and no result key
  And the fleet surface renders that child as failed

Scenario: an ordinary answer is untouched
  Given an ollama response of plain prose carrying no envelope
  When the agent transitions on it
  Then the run settles normally and no malformed_response is journaled
```
→ spec files: `spec/lain/provider/ollama_spec.rb`, `spec/lain/agent/loop_machine_spec.rb`,
`spec/lain/stop_reason_spec.rb`, `spec/lain/tools/subagent/lineage_spec.rb`

**AC 1's second clause is the one that matters.** Without it the scenario passes against the broken
`normalize` path described above — which is precisely how this card was going to ship green over a
dormant feature before review caught it.

**Escalation triggers:**
- **This reverses a documented decision, not a bug.** `spec/lain/provider/ollama_spec.rb:356-365`
  asserts the turn is "otherwise unchanged -- same text, same stop reason", and the rationale is
  echoed at four sites citing **"Open decision 3"** (`decoding.rb:86-96`,
  `telemetry/malformed_response.rb:22-36`, `ollama_spec.rb:304-307`). Rewrite all four **into the
  reason in words** — those citations are the banned ticket shape under CLAUDE.md's comment rule, so
  removing them is required rather than optional. If the reversal looks wrong once you are in the
  code, **stop and escalate rather than half-doing it.**
- **`spec/lain/provider/anthropic_reference_spec.rb:229-235` iterates `StopReason::KNOWN`** and
  asserts the Anthropic provider normalizes each member. If `MALFORMED` ends up in `KNOWN` this
  example passes *mechanically* while asserting Anthropic can emit a reason it cannot — a green
  example over a false claim. If you cannot keep `MALFORMED` out of `KNOWN`, **stop**.
- Three further drift guards will demand accompanying edits and are **not** contradictions:
  `agent_state_machine_spec.rb:93` (every `ALL` member needs a LoopMachine event), `:105`
  (every `:failed`-targeting event needs a `FAILURE_REASONS` entry),
  `agent_state_machine_diagram_spec.rb:16` (regenerate the doc).
- `status_feed/spawn_lifecycle.rb:70-80` derives `finished?` from the mere presence of a `"result"`
  key and asks the next writer not to break that. Writing a `"result"` on any failure path
  contradicts it — stop and confirm.
- If removing `normalize` from `Response#initialize` reds callers that rely on it coercing a raw
  provider string, **stop**: the coercion must move to the providers, not disappear.

---

### T3 — Classify what a word resolves to, not just what it says   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/approval/composed_term.rb`,
`spec/lain/approval/composed_term_spec.rb`
**Reuse:** `Confinement#landing_of` (`board_build.rb:430`) is already public, already resolves
"the path the kernel will open", and is already called by `Content#releasable?` (`:477`).
`#unexempted?` (`composed_term.rb:399`) is the existing verdict test. The header at
`composed_term.rb:28-36` documents the extension shape: "one more `&&` plus one more method".
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring::BoardBuild#approving` (`board_build.rb:147-149`) builds
`ComposedTerm` into the approval ladder for every `lain up` / `lain chat` session. This is the rung
that approves a shell command with no human.

Add a **ninth** predicate that classifies each word's **landing** — the header's numbered list at `composed_term.rb:14-21` already enumerates eight, and that list is part of the diff. No new syscall class is
introduced: `confined?` and `plain_content?` already resolve the same word in the same call.

**THE FIX DOES NOT GO IN `Lain::Sensitivity`.** The classifier's no-syscall contract is the reason
the caller resolves. See the escalation trigger.

**Acceptance criteria:**

```gherkin
Scenario: an in-root symlink under an ordinary name is not auto-approved
  Given a project holding a gated file and an ordinary-named symlink to it inside the root
  When the rule judges a bash term reading the symlink
  Then it abstains rather than approving

Scenario: an ordinary file that is not a link is still approved
  Given a project holding an ordinary world-readable file with unremarkable contents
  When the rule judges a bash term reading it
  Then it approves, as it does today

Scenario: a word that resolves nowhere does not approve
  Given a term naming a path whose prefix cannot be resolved
  When the rule judges it
  Then it abstains rather than raising
```
→ spec file: `spec/lain/approval/composed_term_spec.rb`

**Escalation triggers:**
- **Putting `realpath` inside `Lain::Sensitivity` breaks ~10 examples across three groups** and is
  the wrong seam: a runtime canary stubbing `File.realpath`/`symlink?`/`stat` with the refusal
  "the classifier must not touch the filesystem" (`sensitivity_spec.rb:23, 32-50, 854-912`), a
  Ripper source audit (`:914-941`), and an explicit behavioural pin "reads the name it was given,
  so a symlink to a denied path is ordinary" (`:944-965`). **If the fix drifts toward `Sensitivity`,
  stop.**
- `composed_term_spec.rb:35-37` builds the **real** `BoardBuild::Classifiers`, not a double. A
  factory-level change is exercised here for free — and can fail here for reasons outside this card.
- A project checked out under a symlinked path has a realpath'd root whose lexical root differs; a
  `/`-anchored project rule could miss. Add one example; if it cannot be made to pass, escalate.

---

### T6 — Make `--root` govern what `.lain/` governs   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/backend.rb`, `lib/lain/cli/chat_launch.rb`, `lib/lain/cli/wiring.rb`,
**and every other `Backend.new` call site** — `lib/lain/cli/improve.rb:172`,
`lib/lain/cli/consolidate.rb:75`, `lib/lain/cli/epic_submit.rb:422` — plus
`spec/lain/project/root_defaults_spec.rb` and the mirrored backend/wiring specs. There are ~10
further construction sites in `spec/` (`cli_spec.rb:77,129`, `provider/journaled_spec.rb:122`,
`oracle/secret_read_spec.rb:82,83,354`, `tools/subagent_gate_spec.rb:422`,
`cli/compaction_mount_spec.rb:51`, `arm_spec.rb:300`, `provider/admitted_spec.rb:287`).
**Re-measure with `grep -rn 'Backend\.new' lib spec` before starting.**
**Reuse:** `Wiring#root` (`wiring.rb:519-521`) is the existing, correct, documented root reader.
`ChatLaunch#project` (`chat_launch.rb:225`) already holds the resolved `Project`.
`Skill::Library.load(root:)` (`library.rb:36`) already takes the keyword.
**Shared-file wiring:** none
**Reachable from:** `exe/lain:1125` `ChatLaunch.new(options, profile:, **project_override)` →
`ChatLaunch#backend` (`chat_launch.rb:207`) → `Backend#library` (`backend.rb:484`). Exercised by
`lain chat --root PATH` and `lain up PATH`.

Pass the resolved root into `Backend` and on to `Skill::Library.load`, and to
`Completion::Sources.new` where `Frontend::TTY` is built (`tty.rb:112`, defaults `Dir.pwd`).

**Thread it as a REQUIRED keyword, and update all four call sites.** An optional keyword defaulting
to `Dir.pwd` would leave the defect class intact verbatim — and the widened guard this card also
builds would then flag the new default it just introduced. Required means every caller states its
root, which is the property that makes the next one impossible to get wrong. The three sites beyond
`chat_launch.rb` each already have a project or a root in scope; if one does not, that is a finding
in its own right — **stop and say so** rather than defaulting it.

**Widen `root_defaults_spec.rb` from "parameter defaults" to also flag a call site that omits the
keyword on an allowlisted root-defaulting method.** That guard is what would have caught this and
will catch the next one; its ALLOWED entries for `skill/library.rb`, `skill/catalog.rb` and
`prompt/slots.rb` should **stay** — they are legitimate library-usability defaults.

**Scope note for the AC writer:** `--root` does **not** move where sessions are stored.
`Paths#project_hash` keys off `Dir.pwd` (`paths.rb:251`) and is a separately-ticketed defect needing
a migration (Open decision 2). Do not write an AC claiming otherwise.

**Acceptance criteria:**

```gherkin
Scenario: a project's system slot reaches the model from outside its directory
  Given a project whose .lain/slots/system.md overrides the system prompt
  When a chat is launched from a different working directory with --root naming it
  Then the session header's system prompt carries that override

Scenario: a typo'd slot filename still refuses by name from outside
  Given a project whose .lain/slots holds a file no slot name matches
  When a chat is launched from elsewhere with --root naming it
  Then the launch refuses naming the unknown slot

Scenario: the guard sees a constant-receiver call that drops the keyword
  Given a call such as Skill::Library.load with no root: argument
  When the root-defaults guard runs over lib/
  Then it names that call site
```
→ spec files: `spec/lain/cli/backend_spec.rb`, `spec/lain/project/root_defaults_spec.rb`

**Escalation triggers:**
- `Backend`'s docstring (`backend.rb:477-483`) says the library lives there **because** `Wiring`
  "cannot be handed a library it would then have to load itself". If threading a root into `Backend`
  reads as inverting that layering, stop and confirm the direction.
- `cli_spec.rb:414` and `:429` are the only executable `--root` assertions and are **not** vacuous
  (they use a mktmpdir that can never equal the cwd). They pin `Wiring#fleet_isolation`; if they go
  red, the root is reaching the wrong consumer.
- If widening the guard reds more than a handful of pre-existing call sites, **stop** — that is a
  backlog, not this card, and the guard should land with a named allowlist rather than a mass edit.
- **The guard can only see CONSTANT receivers, and the card must say so.** `root_defaults_spec.rb`
  is a Ripper scan; its own docstring (`:19-25, :40-51`) names indirection as a hole it cannot cover,
  because resolving `@library.load` needs to know what the name is bound to. Scope AC 3 to
  constant-qualified receivers and record the limit the way the existing spec records its own — an
  AC satisfied by a fixture while the real next defect arrives through an ivar is worse than no AC.

---

### T7 — Make the Intake the one place a human line arrives   [wave 2] [risk: high]

**Depends on:** none
**Files:** `lib/lain/frontend/input_rail.rb` → `lib/lain/frontend/intake.rb` (and its spec to the
mirrored path), `lib/lain/frontend/stdin_pump.rb`, `lib/lain/frontend/tty.rb`,
`lib/lain/middleware/refuse_secret_writes.rb`, plus the **12 other `lib/` files and 12 spec files**
that name the old constant. Measured 2026-09-21; in `lib/` they are `cli/command/stop.rb`,
`cli/conductor.rb`, `cli/human_replies.rb`, `cli/input_socket.rb`, `cli/prompt_breaker.rb`,
`cli/shutdown.rb`, `cli/signals.rb`, `cli/wiring.rb`, `frontend/approval_policy.rb`,
`frontend/input_pane.rb`, `frontend/stdin_pump.rb`, `frontend/tty.rb`. **Re-measure before starting.**
**Reuse:** `CredentialPatterns.for(:write)` (`credential_patterns.rb:73-76`) is already the table
chosen for "a user's own prose" and is deliberately narrower than `:content`
(`refuse_secret_writes.rb:32-34`). `Frontend::TTY::History` (`tty.rb:493-534`) is the existing
append-only 0600 writer — inject it downward rather than reimplementing. The rail is **already**
constructed with the screen (`wiring.rb:295`, `InputRail.new(screen: tty)`; `input_pane.rb:63`), so
injecting a collaborator costs nothing at the wiring layer. `Sink::Null` is the Null Object
precedent for the classifier's default. Zeitwerk resolves the renamed constant from its path — no
manifest, no index entry, nothing to register.
**Shared-file wiring:** `CLAUDE.md:285-288` and `ARCHITECTURE.md`'s rail passages name the constant
in prose; hand the orchestrator those diffs. Same for `README.md` if it matches.
**Reachable from:** `CLI::Conductor#route` (`conductor.rb:165`) and `CLI::Wiring` (`wiring.rb:295`)
construct it for every `lain chat`/`lain up`; `StdinPump#typed` (`stdin_pump.rb:308-312`) is the
current history write site being moved.

**One card, one claim: every human line arrives in one place — and so does its record.** The rename
rides here rather than in a card of its own precisely because this is where it earns its keep: the
object becomes the thing its name says in the same commit that makes CLAUDE.md's sentence true.
A separate rename card would have manufactured collisions with three other cards while fixing no
finding.

Today history is written **two statements upstream of the rail**, persists the fragment rather than
the assembled `carried.partial + line`, and is fed by only one of three producers — so
`CLAUDE.md:285`'s claim is not true of history. Moving persistence behind the Intake makes it true,
covers the `lain input` socket and nvim's gesture rail, sees the whole line, and gives the credential
check one home.

Keep the existing `[y/N]`/`human>` exclusion (`draw.prompt.answer?`, and the rail's own `ANSWERS`).

**`"nothing was written"` (`refuse_secret_writes.rb:135`) is true of the memory store and false of
the session.** Narrow the sentence to name the store it means.

**A known contention this card WIDENS, to be stated rather than discovered:** `tty.rb:488-495`
already records that the history file is "shared by every session of every project and `lain up` puts
several chat panes on it at once". Adding the `lain input` process as a writer makes that merge
worse in the direction of the pane next door. Append-only 0600 keeps it safe, not correct. **Scoping
the recall is explicitly out of scope** — the same docstring says it is "a path argument at one call
site", and it is not this card's subject.

**Acceptance criteria:**

```gherkin
Scenario: a credential typed at the prompt is not persisted
  Given a chat whose history file is empty
  When a human types a line matching a write-tier credential pattern at you>
  Then the ask still runs and the history file does not contain that line

Scenario: an ordinary line is persisted whole
  Given a chat whose prompt carries a partial line already
  When a human completes that line and submits it
  Then the history file holds the assembled line, not the fragment

Scenario: a line typed into the input pane is persisted too
  Given a cockpit whose human types through the lain input socket
  When an ordinary line is submitted
  Then it reaches the history file

Scenario: the constant resolves at its mirrored path
  Given lib/lain/frontend/intake.rb
  When the loader eager-loads lib/
  Then Lain::Frontend::Intake is defined and no InputRail constant remains anywhere in lib/
```
→ spec files: `spec/lain/frontend/intake_spec.rb`, `spec/lain/frontend/stdin_pump_spec.rb`,
`spec/lain/frontend/tty_spec.rb`

**Escalation triggers:**
- `tty_spec.rb:337/346/350/357` pin append/0600/no-truncate semantics and `TTY#remember` as the
  write API. They must keep passing for ordinary lines; if the move forces a change to what
  `remember` means, **stop and confirm** — the 0600-at-open() property has no chmod window and must
  not acquire one.
- `refuse_secret_writes_spec.rb:294` pins the sentence verbatim. Changing the wording is deliberate;
  changing its *scope claim* is the point.
- `Intake` must not become a file-handling object. It owns prompt arbitration; if persistence drags
  IO into it, extract the writer and inject it (CLAUDE.md, SRP) rather than growing the class.
- `InputRail::Line` and `InputRail::Signal` are nested value objects named across several files and
  specs. `grep` for the **string**, not just the constant, or the rename is incomplete.
- `bin/zeitwerk-census` must still report 0 in every tier, and its shuffled pass only SAMPLES the
  order space — run it more than once and record the seed. A boot-order defect is invisible to the
  suite.
- `tty_spec.rb:350` uses the fixture `"secret-adjacent line"`, which matches no write-tier pattern
  today. If a pattern widening makes it match, that example breaks for an unrelated reason.

---

### T8 — Report the input pane's corpse when the chat pane dies too   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/up.rb`, `spec/lain/cli/up_spec.rb`
**Reuse:** Both corpses, both nouns and both consequences already exist and are already correct
(`up.rb:1184-1190`). `PaneCorpse#call` (`:604-611`) is idempotent and bounded by `GRACE = 0.15`.
**Shared-file wiring:** none
**Reachable from:** `exe/lain:1206` `launch_plan(nested: ENV.key?("TMUX"))` — every `lain up`.

`raise ChatDied` at `up.rb:1031` runs **before** `@input_corpse&.call` at `:1036`, so the sentence
"so this cockpit has no keyboard" is unreachable when both panes die — and the advice the operator
does get sends them back into a keyboard-less session.

Probe the chat **first** (ordering is load-bearing, see triggers), then the input pane, then decide.
The input pane is spawned earlier, so its grace is already partly spent and it only ever waits less.

**Acceptance criteria:**

```gherkin
Scenario: both panes die and the operator is told about both
  Given a cockpit whose chat pane and input pane both die at once
  When lain up decides whether to attach
  Then it refuses naming the chat's death and also says the cockpit has no keyboard

Scenario: only the input pane dies
  Given a cockpit whose chat pane lives and whose input pane dies
  When lain up decides whether to attach
  Then it attaches and says the cockpit has no keyboard, as it does today

Scenario: both panes live
  Given a healthy cockpit
  When lain up decides whether to attach
  Then its messages carry no corpse sentence at all
```
→ spec file: `spec/lain/cli/up_spec.rb`

**Escalation triggers:**
- `up_spec.rb:406-425` asserts `eq` on `plan.messages`. The input sentence **must stay conditional**
  (nil splats to nothing) or that example reds for the right reason in the wrong place.
- **Probe order matters to existing examples.** `up_spec.rb:1246-1251` and `:1286-1293` use
  `calls.find` (first match) and expect the **chat** pane's id; the fake factory answers
  `dead: "1 1"` to every `display-message`, so reversing the probe order breaks both.
- If carrying two sentences on one `ChatDied` reads worse than a distinct error class, raise it —
  `exe/lain:1214` flattens any `Lain::Error` to `Thor::Error`, so either shape works.

---

### T9 — Stop the fleet when `/stop` is typed with children running   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/command/stop.rb`, `spec/lain/cli/command/stop_spec.rb`
**Reuse:** `Undo#quiet!` (`undo.rb:126-133`) already writes the exact predicate —
`env.supervisor.each.select { |worker| worker.state == :running }`. `Supervisor#stop`
(`supervisor.rb:157-164`) and `Actor#stop` (`actor.rb:147-158`) are total and idempotent;
`Actor#stop` lands a final attributed `:message` so the child Timeline is left whole.
**Shared-file wiring:** none
**Reachable from:** `CLI::Command::Surface#assemble_env` (`surface.rb:124-128`) constructs the
command Env with `supervisor:` for **every** chat — verified 2026-09-21 — and `/stop` is in the
shipped registry (`surface_spec.rb:187-190`). So nothing needs wiring: the collaborator is already
passed on the real path, `Undo` already reads it (`undo.rb:128`), and `Stop#call(_args, _env)`
simply ignores the env it is handed. **This card changes a reader, not a construction site**, which
is why its AC can exercise production directly rather than an injected double.

An adopted actor is a **sibling of every ask**, not a captive of one (`supervisor.rb:7-14`), so the
parent's `@supervising` is false while the fleet still runs — `/stop` at `you>` answers
"no ask is running" beside a fleet row reading `running`.

**Leave the rail's `glimpse.kind != :you` conjunct alone** (`intake.rb`, ex-`input_rail.rb:210-212`).
Lifting at `you>` would drop the line into a sink with no run behind it. The fix belongs on the
other side of that branch, in the command.

**Acceptance criteria:**

```gherkin
Scenario: /stop with a running child stops it
  Given a session with one running subagent and no ask in flight
  When the human types /stop
  Then the child is stopped and the answer names what was stopped

Scenario: /stop with nothing running is unchanged
  Given a session with no ask in flight and an empty fleet
  When the human types /stop
  Then it answers that no ask is running

Scenario: the session survives stopping the fleet
  Given a session whose fleet was just stopped
  When the human asks something next
  Then the ask runs normally on the same session
```
→ spec file: `spec/lain/cli/command/stop_spec.rb`

**Escalation triggers:**
- **`stop_spec.rb:15-20` passes `nil` for `env`** and asserts `NOTHING_RUNNING` for every argument.
  The moment `Stop#call` reads `env.supervisor` it raises `NoMethodError`. Rewrite it with a
  fleet-less env double — this is a contradiction, not a drift guard.
- `conductor_spec.rb:299-317` pins the conductor's idle routing (`conductor.rb:476`), which shares
  the `NOTHING_RUNNING` string. If the fix touches `Conductor#no_ask_running` as well as the
  command, that example constrains it — prefer the command-only change.
- Round 19 saw one unreproduced case of `/stop` journaling `run_interrupted` and the loop continuing
  (recorded **inconclusive**, two reproductions failed). If you can reproduce it while building this
  card, **escalate** — it may be a second defect in `Shutdown#stop_ask`, not this one.

---

### T10 — Stop capturing write paths that escape the snapshot root   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/workspace/snapshot.rb` (the `Scope` classes), `lib/lain/agent/snapshot_slot.rb`,
`spec/lain/workspace/snapshot_spec.rb`, `spec/lain/agent/snapshot_slot_spec.rb`
**Reuse:** `Scope#paths(write_set:, root:)` (`snapshot.rb:100`) **already receives both operands** —
the write set and the root — so the containment test needs no new information. `SnapshotSlot#degrade`
(`snapshot_slot.rb:148-155`) is the existing writer of `SnapshotDegraded` to both `@journal` and
`@channel`, and is the only object in this path that can journal anything.
**Shared-file wiring:** none
**Reachable from:** `Agent::ToolDelivery#deliver` (`tool_delivery.rb:88`) takes a snapshot every turn
of every `lain chat`/`lain up`; `Workspace::Snapshot.new` is constructed at
`snapshot_slot.rb:157` and `:163`, which is where the journal is already in scope.

Under `plan` scope the session write-set is cumulative (`session.rb:288-306`, and `#rescope` at
`:86-89` swaps only `@scope`) while the slot root rebinds (`switchboard.rb:638-651`), so a path
outside the current root reaches `#relative` (`snapshot.rb:155-157`) and is silently keyed `../…`.
`Revert` then — correctly — classifies it `outside_root`, and since `/undo` addresses
`@entries.last` only (`snapshot_log.rb:81-87`) and never pops a blocked entry, one such key wedges
every later turn.

**Put the containment in the `Scope`, not in `#relative`.** `snapshot.rb:10-15` states that "WHICH
paths are captured is the injected `Scope`'s to say — its note rides every payload's
`snapshot_scope`, so the record names the policy that made it". A filter below the Scope leaves that
note naming a policy that no longer made the map.

**This reverses a documented decision and must say so, the way T2 does.** `snapshot.rb:26-28`
currently reads: "Relativization is LEXICAL … **a path outside the root keys by its honest `../`
form rather than being hidden.**" This card hides it. Rewrite that sentence with the reason: an
honest `../` key is only honest to a reader who can act on it, and `/undo` cannot — it can only
refuse, permanently, over a path the human never chose to write.

**Name the symmetric consequence in the card's own prose.** The filter cuts both ways: while inside
plan scope, home-root paths the session wrote *earlier* are dropped from the snapshot too. That is
a real narrowing of what a plan-scope snapshot covers, and it is the reason T19 exists rather than a
thing to discover later.

**Acceptance criteria:**

```gherkin
Scenario: a write outside the snapshot root is not captured
  Given a session whose cumulative write set holds a path outside the current snapshot root
  When a snapshot is taken
  Then that path contributes no entry to the snapshot

Scenario: the omission is recorded where a reader can see it
  Given the same snapshot
  When it is taken through the slot that owns the journal
  Then a record naming how many paths were dropped reaches the journal

Scenario: /undo is not wedged by a plan-scope turn
  Given a session that wrote inside a plan-scope spike and then left plan scope
  When the human types /undo
  Then it reverts the newest reversible turn rather than refusing over an out-of-root key
```
→ spec files: `spec/lain/workspace/snapshot_spec.rb`, `spec/lain/agent/snapshot_slot_spec.rb`

**AC 2 is why `snapshot_slot.rb` is in the file list.** `Workspace::Snapshot` cannot journal — its
own note says so (`snapshot.rb:8-9`: "Nothing here journals") and its constructor takes
`observer:`, `root:`, `scope:` and no sink. An AC asserting the omission is journaled would
otherwise pass against a double in `snapshot_spec.rb` while every real turn dropped the path in
silence.

**Escalation triggers:**
- `revert_spec.rb:135-137` and `snapshot_log_spec.rb:304` pin `outside_root` as a **classification**
  and must keep passing — this fix is upstream of them. If either reds, the guard landed too low.
- **The root cause is NOT fixed here and the trigger for noticing it is exact:** if a home-root write
  made *before* a scope flip goes missing from a plan-scope snapshot, that is the symmetric drop
  above, it is expected, and it is T19's and Open decision 6's problem — **not** a reason to change
  `Session#writes` inside this card. `Session#writes` is also read by `written?`
  (`session.rb:296-298`) and the memory and status surfaces.
- If the `Scope` cannot express the test because `WriteSet#paths` ignores `root:` by contract
  (`"root is unused -- this scope keys nothing"`), that contract is what this card changes — but say
  so in its note, since the note rides every payload.

---

### T19 — Undo against the root its snapshot recorded   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/command/undo.rb`, `spec/lain/cli/command/undo_spec.rb`
**Reuse:** every snapshot payload already carries its own `"root"` (`snapshot_log.rb:144-149` keys
pre-images against `event.body["root"]`), so the correct root is already on the record being undone.
**Shared-file wiring:** none
**Reachable from:** `CLI::Command::Undo#call` — the `/undo` command in the shipped registry
(`surface_spec.rb:187-190`), constructed for every chat by `Surface#builtins`.

`Undo#reverted` (`undo.rb:91-96`) builds `Revert.new(root: env.snapshots.root)` — the slot's
**current** root, not the root the snapshot being undone was recorded under. After a scope flip
those differ, so undoing a plan-scope turn from the checkout resolves spike-relative keys against
the checkout: it writes to the wrong file **with no refusal at all**.

Separated from T10 deliberately: different file, different root cause, and — as round 19's findings
say — arguably the worse of the two, because T10's symptom is a loud wedge and this one is silent.

**Acceptance criteria:**

```gherkin
Scenario: an undo addresses the root its snapshot recorded
  Given a snapshot recorded under one root and a slot now bound to another
  When that snapshot is undone
  Then the revert addresses the recorded root and never writes under the current one

Scenario: an undo whose recorded root is gone refuses rather than guessing
  Given a snapshot whose recorded root no longer exists
  When it is undone
  Then it refuses naming that root, and /undo skip still advances past it
```
→ spec file: `spec/lain/cli/command/undo_spec.rb`

**Escalation triggers:**
- `undo_spec.rb` builds its slot with a fixed root and never flips scope, so **nothing currently
  pins this interaction**. New fixtures here are load-bearing; if a scope flip cannot be driven from
  a spec, say so rather than asserting around it.
- If the recorded root turns out to be absent from older payloads, this card needs a defaulting rule
  and that rule is a decision — stop and confirm rather than silently falling back to the slot's.

---

### T11 — Record the compaction arm, and refuse to compare across arms   [wave 2] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/backend.rb`, `lib/lain/bench/session.rb`,
`lib/lain/bench/session/loader.rb`, `lib/lain/bench/variance.rb`, and their mirrored specs.
**Reuse:** `SessionRecord#context_pipeline` (`session_record.rb:73-80`) is the only-when-named idiom
to copy verbatim. `Telemetry::Compaction::EAGER_CONTROL_ARM` (`compaction.rb:165`) is the name a
reader normalizes absence to, and `Collapse` already does that normalization (`source.rb:124-141`).
`Variance#guard_pipelines!` (`variance.rb:129-141`) is the shape the new guard sits beside, called
from the constructor at `:51`.
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring` (`wiring.rb:397`) merges `backend.compaction_header` into the
session header for every `lain chat`/`lain up`; `Bench::Session::Loader#recording`
(`loader.rb:73-83`) is the **single** construction site that must pass the new member, and
`Bench::CLI` reaches the guard through `lain bench variance`.

**The header key is `"compact_strategy"`.** Naming it here rather than leaving it to the implementer
is what lets the write and the read land together: they are different files in different directions,
so once the key is fixed there is no reason to serialize them.

`compaction_header` (`backend.rb:475`) is literally `{ "compact_fallback" => compact_fallback }`,
while the strategy name is known — `--compact-strategy` reaches `SpanSummarizer.resolve`
(`span_summarizer.rb:60`) and travels verbatim onto every `compaction_cut`. And `bench variance`
guards context pipelines with no equivalent for strategy, so two recordings under different arms
compare as if identical, reporting the arm difference as the model's variance.

**Absence must stay distinguishable from `"summarizing"`:** an unset flag means the run's own eager
tool-result tier, the control arm every flagged run is measured against
(`compaction_strategy.rb:113-125`). No key when unset; readers normalize absence to the eager arm.

**Do NOT copy the pipeline guard's stages-not-names rule.** An unset pipeline and `default` send the
same bytes; `nil` and `"summarizing"` are genuinely different arms. Compare names verbatim after
normalizing absence. Order is significant in a `+`-composition — do not sort.

`Recording` grows a required `compaction:` member, on `session.rb:125-132`'s own argument that a
comparability axis carries no default.

**Acceptance criteria:**

```gherkin
Scenario: a named strategy is recorded
  Given a chat launched with a compaction strategy named
  When its session header is written
  Then the header carries that strategy name exactly as typed

Scenario: an unset strategy writes no key
  Given a chat launched with no compaction strategy named
  When its session header is written
  Then the header carries no compaction strategy key at all

Scenario: two different arms refuse to be compared
  Given two recordings whose headers name different compaction strategies
  When bench variance reads them
  Then it refuses naming both arms and reports no table

Scenario: an unset arm and an explicit eager arm compare
  Given one recording with no strategy key and one naming the eager control arm
  When bench variance reads them
  Then it reports, because both ran the same arm
```
→ spec files: `spec/lain/cli/backend_spec.rb`, `spec/lain/session_record_spec.rb`,
`spec/lain/bench/variance_spec.rb`, `spec/lain/bench/session/loader_spec.rb`

**Escalation triggers:**
- `backend_spec.rb:1407-1411` asserts `eq("compact_fallback" => "handoff")`. It survives **only** if
  an unset strategy writes no key. If you find yourself relaxing that `eq`, the fix is wrong.
- `spec/lain/bench/session_spec.rb:69-91` subtracts a known key list from `header.keys` so "a new
  kwarg cannot be dropped in silence". `"compact_strategy"` must join the subtraction at `:82-83`.
- `variance_spec.rb:240-243` ("compares a recording named default with an unset one") pins the
  stages-not-names rule **for pipelines**. Writing the strategy guard by copying it yields a green
  example over a wrong guard — assert the strategy case directly.
- Adding a required member to `Recording` reds its construction sites. There is exactly **one** in
  `lib/` (`loader.rb:75`) — verified. If you find more than a handful, stop: the member belongs
  elsewhere.

---

### T13 — Make a damaged record refuse in the currency its readers rescue   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/bench/session.rb`, `lib/lain/bench/session/message_replay.rb`,
`lib/lain/bench/session/chain_fold.rb`, and mirrored specs.
**Reuse:** `MemoryReplay` (`memory_replay.rb:211-219`) is the existing precedent — `rescue KeyError,
ArgumentError => e` re-raised as `Corrupt`, leaning on `e.message` rather than re-reading the record.
`Bench::Session::Corrupt` (`session.rb:65`) is the shared namespace both replays already use.
**The helper lives in `lib/lain/bench/session.rb`**, beside `Corrupt` itself — that file is the
namespace's index and already holds the error both replays raise, so no new file is created and
CLAUDE.md's same-commit rule does not come into play. If the implementer judges it wants its own
path (`lib/lain/bench/session/required_keys.rb`), that is a new lib file and it needs its own spec at
its mirrored path **in the same commit** — say so and hand it back rather than deciding silently.
**Shared-file wiring:** none
**Reachable from:** `/fork` (a registered `/` command), `lain chat --resume`, and `bench variance`
— all three rescue `Corrupt` (`cli/resume.rb:173,199`, `bench/cli.rb:569-570`,
`supervisor/restart.rb:122-123`) and none rescues `KeyError`.

`MessageReplay#rebuilt` (`message_replay.rb:213-224`) bare-`fetch`es five keys; a missing one escapes
every door as a raw `KeyError` with 19 frames. `KeyError` is no `Lain::Error`, so `exe/lain`'s rescue
misses it. **`ChainFold` has the identical hole** (`:130`, `:152`, `:167`, `:182`) and its rescue
clause re-reads `record.fetch("role")` *inside the handler*, so a `role`-less record raises from the
handler.

The class already made this argument once, for one field: `message_replay.rb:140-145` explains why
`causal_parents` is defaulted rather than fetched. **Promote it to a shared helper** and apply it to
both replays — the argument has now been written longhand at five sites.

**Acceptance criteria:**

```gherkin
Scenario: a message record missing a required key refuses by name
  Given a session journal holding a message record with no correlation key
  When a fork of that session is attempted
  Then it refuses as corrupt naming the record and the missing key, with no backtrace

Scenario: a turn record missing its role refuses by name
  Given a session journal holding a turn record with no role key
  When a resume of that session is attempted
  Then it refuses as corrupt naming the record, with no backtrace

Scenario: a healthy session is unaffected
  Given an undamaged session that spawned a subagent
  When it is forked and resumed
  Then both succeed
```
→ spec files: `spec/lain/bench/session/message_replay_spec.rb`,
`spec/lain/bench/session/chain_fold_spec.rb`

**Escalation triggers:**
- **`causal_parents` and `render_parent` must stay `[]`-read.** `message_replay_spec.rb:232-238`
  pins that an absent `causal_parents` is the empty set, and `:130-134`/`:140-145` document why.
  Extending the required-key rule to either contradicts a deliberate fix.
- `#labelled` (`message_replay.rb:211`) bare-fetches `kind` as its own fallback, so a wrapper that
  names the record can re-raise `KeyError` from the handler. Make it total — but
  `message_replay_spec.rb:163-175` asserts the refusal `not_to include("(turn)")`, so the fallback
  string must not be `"turn"`.
- Every existing `Corrupt` assertion is `include`-based on substrings like `"message record N"` and
  `"(child_turn)"`. If the new sentence drops one of those substrings, examples red for a cosmetic
  reason — preserve them.

---

### T14 — Say why a compaction held no summaries   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/compaction/source.rb`, `spec/lain/compaction/source_spec.rb`
**Reuse:** `CompactionDecision` (`telemetry/`) is the existing record; `record(...)`
(`source.rb:760-767`) is the single build site. `Compaction::SummarySnapshot`'s doc
(`summary_snapshot.rb:39-44`) already states the ambiguity in prose.
**Shared-file wiring:** none
**Reachable from:** `Compaction::Source` builds a `compaction_decision` every turn of every
`lain chat`/`lain up` session.

`summary_hits`/`summary_misses` is three-way ambiguous — under-threshold, in-flight and failed all
count as a miss — while the codebase calls that pair "the bench's read on whether the fires are
landing at all". A healthy compaction can read `hits=0 misses=8` purely because
`MODEL_THRESHOLD_BYTES` made nothing eligible, which is indistinguishable from a dead summarizer.

**Additive only.** Record why there were no hits; do not change what `hits`/`misses` count.

**Acceptance criteria:**

```gherkin
Scenario: a compaction where nothing was eligible says so
  Given a compaction whose every candidate block is under the summarizer threshold
  When its decision is recorded
  Then the record distinguishes "nothing was eligible" from "summaries were attempted and missed"

Scenario: a compaction whose summarizer answered says so
  Given a compaction where a summary was held for a dropped block
  When its decision is recorded
  Then the record reports the hit and reports no eligibility refusal
```
→ spec file: `spec/lain/compaction/source_spec.rb`

**Escalation triggers:**
- `summary_snapshot.rb:39-44` documents the snapshot's own inability to tell "never summarized" from
  "still in flight". If the eligibility reason cannot be answered at the **policy** level either
  (`source.rb:756-758` says the record's counts are the policy's, not the snapshot's), say so and
  escalate rather than inventing a distinction the code cannot make.
- If a new field needs `SummarySnapshot` to gain a syscall, a clock, or a back-reference to the
  oracle, **stop** — that is a redesign, not this card.

---

### T16 — Say when a consolidate pass stored nothing   [wave 2] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/consolidation.rb`, `lib/lain/cli/consolidate.rb`,
`spec/lain/consolidation_spec.rb`, `spec/lain/cli/consolidate_spec.rb`
**Reuse:** `Memory::Recorder` exposes `attr_reader :index, :loaded` (`recorder.rb:45`), so the pass
can compare the recorder's index across the run directly — **that is the seam, not the journal.**
The `memory_root` record journalled per clerk turn (`consolidation.rb:113-117`: "a refusal or a mask
writes no memory, so neither has a root to pair") is corroborating evidence a reader can check, but
building a journal reader to answer a question the recorder answers in an attribute would be the
long way round.
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `consolidate` → `CLI::Consolidate#rendered` (`consolidate.rb:129-134`).
Load-bearing for `lain up`: CLAUDE.md states all durable memory lives in one `Memory::ProjectStore`
per project "so a fresh chat sees what earlier chats and `lain consolidate` wrote", so a barren pass
silently degrades every later session.

`rendered` branches only on `outcomes.empty?`, so a pass whose clerk explored instead of writing
reports `"ran a court_clerk pass over N lineage(s)"` and exits 0 over a store that did not move.
`Outcome = Data.define(:spawn, :result)` (`consolidation.rb:30`) carries the clerk's **text**, never
whether anything was stored.

Carry the recorder's movement on the `Outcome` and report it. A pass that clerked lineages and wrote
nothing must say so distinctly from one that wrote.

**Acceptance criteria:**

```gherkin
Scenario: a pass that stored nothing says so
  Given a session with completed lineages whose clerk writes no memory
  When lain consolidate runs over it
  Then the report says the pass stored nothing rather than reporting a successful pass

Scenario: a pass that stored memories reports them
  Given a session with completed lineages whose clerk writes memories
  When lain consolidate runs over it
  Then the report names how many lineages were clerked and that memories were written

Scenario: no lineages at all is unchanged
  Given a session with no completed subagent lineages
  When lain consolidate runs over it
  Then it reports that none were found, as it does today
```
→ spec files: `spec/lain/consolidation_spec.rb`, `spec/lain/cli/consolidate_spec.rb`

**Escalation triggers:**
- **Round 19's F134 verdict was "half fixed": it finds lineages but stores nothing.** If, once you
  can see the movement, the clerk turns out never to write on this model, that is a *second* defect
  (the prompt or the toolset), not this card — **stop and escalate** rather than making the report
  honest about a pass that should have worked.
- The exit status is part of the contract. If "stored nothing" should exit non-zero, that is a
  behaviour change a caller may depend on — confirm before changing it; the AC above deliberately
  only constrains the words.
- Round 19's Fm-2 (the clerk path not detecting a prose tool call) **folds into T2**, not here: the
  clerk asks through the same Provider, so T2's stop-reason change reaches it. If it does not, say so.

---

### T17 — Repaint the input pane's HUD after a layout change   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/input_pane.rb`, `spec/lain/frontend/input_pane_spec.rb`,
`spec/lain/seams/input_pane_socket_spec.rb`
**Reuse:** the pane **already caches the whole last frame** in `@drawn` (`input_pane.rb:208`) and
already runs a `TICK = 0.1` loop that knows whether the human is mid-edit (`:275-288`, `#report_touch`).
`over_the_prompt` (`:241-245`) is the one writer and must stay the one writer.
**But `stop_drawing` + `prompted` is NOT a reusable redraw path, and assuming it is will cost you an
afternoon:** `stop_drawing` resets `@drawn` to `NOTHING_DRAWN` (`:262`), so "redraw from `@drawn`"
after calling it redraws nothing — capture the frame first; and `prompted` early-returns on
`drawing_already?` (`:205`, `:215-219`), which is true exactly in the resize case, where the frame is
byte-identical and only the geometry moved. **This card needs a third entry point** — a
geometry-triggered repaint that bypasses the dedupe — not the two-method reuse it would be natural
to reach for.
**Shared-file wiring:** none
**Reachable from:** `CLI::Up` builds the input pane for every `lain up`; `exe/lain` `input` runs it.

Squeeze a cockpit window below 13 rows and restore it: the `window-layout-changed` hook returns the
pane to its 6-row floor, but the HUD header is gone and never returns until the next ask completes,
while the status feed carries the correct string throughout. `SEAT_INPUT` (`up.rb:322-325`) is a
bare `resize-pane` and tells nothing to repaint; the chat-side `@sent` latch
(`input_socket.rb:380-386`) suppresses an identical frame and `drawing_already?` (`:215-219`) would
drop it anyway.

**Do it pane-locally.** No protocol change, no round trip. Poll `IO#winsize` — an ioctl on the pane's
own tty — from the existing TICK loop, edge-triggered on a geometry change, and redraw from `@drawn`.

**Two prior decisions constrain this and must not be violated:**
`prompt_composer.rb:260-264` forbids trapping WINCH (`Signal.trap` **replaces** rather than chains,
so it would break Reline's editor redraw); `:251-259` forbids polling `TTY::Screen` (it forks —
measured 200 subprocess spawns per 100 reads).

**Acceptance criteria:**

```gherkin
Scenario: the HUD returns after the pane is resized
  Given an input pane showing a HUD above its prompt
  When the pane's geometry changes and settles
  Then the HUD is drawn again without the human typing anything

Scenario: a half-typed line is not disturbed
  Given an input pane whose human has typed a partial line
  When the pane's geometry changes
  Then nothing is redrawn over that line until it is submitted or cleared

Scenario: an unchanged pane is not repainted
  Given an input pane whose geometry does not change
  When time passes with a fleet running
  Then the pane redraws nothing
```
→ spec files: `spec/lain/frontend/input_pane_spec.rb`, `spec/lain/seams/input_pane_socket_spec.rb`

**Escalation triggers:**
- **`spec/lain/seams/input_pane_socket_spec.rb:262` ("redraws nothing while only the clock moves
  under a running fleet") kills any unconditional periodic redraw** — it measured seven redraws in
  eight seconds as the defect. The poll must be edge-triggered on geometry, never on the tick.
- `input_pane_spec.rb:122-129` asserts the literal `CLEAR_ROW` bytes precede the header. A redraw
  that bypasses `over_the_prompt` loses them.
- If `IO#winsize` raises on the pane's tty under tmux (it should not), **do not** fall back to
  `TTY::Screen` or a WINCH trap — both are foreclosed above. Escalate instead.

---

### T18 — Re-drive the round-19 cockpit findings against the fixed tree   [wave 3] [risk: low]

**Depends on:** T2, T3
**Files:** `planning/qa-findings-round19-2026-09-21.md` (verdict column only)
**Reuse:** `.claude/skills/manual-qa/` and `planning/qa/scenarios/`. The bench helpers were fixed in
`d5d08b87` — `drive.sh`/`peek.sh` now resolve a stock cockpit, so no pin is needed.
**Shared-file wiring:** none
**Reachable from:** n/a — this card builds no capability; it verifies, against the real binary, the
production paths every other card wired. That is its whole subject.

A manual pass is the only thing that drives two real components against each other with a human at
the gate — and every defect this plan fixes was found that way, not by the suite.

**Drive, at minimum:** `session-and-window` §6 (the cap now on the wire), `cockpit-surfaces` §0 (the
HUD row after a resize, which T17 fixed), `cockpit-surfaces` §5 (the
approval ladder, unchanged), `secret-boundary` §4/§5 (the symlink now abstaining),
`bowling-ruby` §2 (a malformed child now failing rather than answering), and `repl-commands` (`/stop`
with a live fleet, `/undo` after a plan-scope write).

**Acceptance criteria:**

```gherkin
Scenario: the four HIGHs are each proved fixed by a capture, not by prose
  Given the fixed tree and a manual QA pass over the named scenarios
  When the findings file is updated
  Then the generation cap carries a captured request body showing the cap on the wire
  And the symlink finding carries a captured abstain from the approval rule
  And the malformed-response finding carries a captured child completion reading lifecycle failed
  And the --root finding carries a session header showing the project's own system slot

Scenario: every other finding this plan claims to fix carries a verdict
  Given the same pass
  When the findings file is updated
  Then each remaining finding reads FIXED with its evidence, or names why it could not be driven
```
→ spec file: none — this is the human pass named in Integration checks.

**Escalation triggers:**
- **A fix that changed the failure mode without improving it is a finding**, not a pass (method.md's
  standing rule: one round turned a >400s hang into a hard crash). Record *differently* vs *better*.
- If the ollama slot is contended, **no wall-clock figure is a measurement** — round 19 measured
  4-8 minute waits against a resident model. Say so rather than quoting a number.
- If a fixed defect reappears one route past the fix — the shape round 18 and 19 both saw — that is
  a new finding for the next round, not a failure of this card.

## Integration checks

After the last wave:

1. `bundle exec rake pspec` — the whole suite, 12 workers. **Check the example COUNT, not just the
   failure count** (`parallel_tests` reports only survivors; a dead worker looks like a pass).
   Confirm nothing else is running first: `pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'`
   reads 0, and the pre-commit pattern too.
2. `bundle exec rubocop` — bare, never naming a `.toml`. **`-a` only**; `-A` is banned here.
3. `bin/zeitwerk-census` — every tier 0, after T7's rename. The shuffled pass SAMPLES the order
   space, so run it more than once and record the seed.
4. `bin/comment-census --check-tickets --check-load-order` — T4 and T2 both add prose.
5. `bundle exec rake compile && cargo test && cargo clippy --all-targets -- -D warnings` — no card
   touches Rust, so this is a regression check only.
6. **Regenerate `docs/agent-state-machine.md`** and confirm `README.md:144`'s hand-written arc
   matches (T2).
7. **The manual pass, T18** — the only check that drives the approval gate with a human at it.
8. Confirm `git status --porcelain` on the checkout is clean apart from the intended diff, and that
   no `.lain/` was written into the repo (`.gitignore:22` hides it from `git status`).
