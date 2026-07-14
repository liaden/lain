# Review resolution, Ollama local provider, and test-infrastructure upgrade

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Three streams, one plan. (1) Resolve Joel's 47 in-tree `# CODE REVIEW` comments (2026-07-14,
preserved verbatim at `planning/reviews/2026-07-14-joel-code-review.patch`) — the comments are
**prompts, not directives**: each card implements, or rejects with the reasoning recorded as an
improved WHY comment or an `R.*` entry in `planning/remaining-work.md`. (2) Add a native-API
`Provider::Ollama` so the bench gains a free, local, temperature-0 arm — both a determinism
oracle for tests and an exploration target (ROADMAP "Provider / model" axis; also groundwork for
future async local-model tool-result summarization). (3) Upgrade the spec suite: `super_diff` +
`shoulda-matchers`, custom matchers under `spec/support/matchers/`, and a themed review sweep of
the ~60 lib files the comments did not reach.

## Grounding

Verified 2026-07-14 against `main` @ 251e7e9 (working tree dirty with the review comments):

- **The review diff**: 33 files, 47 comments, plus Joel's own edits (endless defs in
  `channel.rb`/`context.rb`/`handler.rb`, `{ effect:, context: }` shorthand in `tool_runner.rb`,
  `rescue NoMethodError` duck-typed `==` in `content_addressed.rb`/`degraded_set.rb`, one
  de-indented comment in `agent.rb:36`). Preserved at
  `planning/reviews/2026-07-14-joel-code-review.patch`; Wave 0 commits that patch and resets the
  tree, so **cards read the patch, not the working tree**, for comment text.
- **Provider seam**: `Lain::Provider` duck is `capabilities` / `encode(request)` /
  `complete(request)` (`lib/lain/provider.rb`); `supports?`/`require!` provided. Backends:
  `Anthropic` (SDK oracle), `AnthropicRaw` (vendored-fork transport), `Mock`. The vendored fork
  (`lib/lain/provider/http/`, ruby_llm 1.16.0 @ 2cf34b9) is **Anthropic-only** — the plan doc's
  openai/ollama shim vendoring was trimmed out; `Registry`/`Configuration.register_provider_options`
  extension seams are intact. `AnthropicRaw` is the model to copy: a neutral `Lain::Provider`
  reusing only the fork's `Configuration` + `Connection` (Faraday + faraday-retry) via a
  `Transport` subclass, encoding with Lain's own mixin.
- **Request/Response**: `Request = Data.define(:model, :system, :tools, :messages, :max_tokens,
  :stream, :reasoning, :extra)` — **no temperature field**; provider-specific params ride `extra`
  (excluded from `cache_payload`/digest identity). `Response#content` is the full ordered block
  list, string-keyed, `tool_use.input` **must be a parsed Hash**. `StopReason.normalize` maps
  unknown wire values to `:unknown`; enum is `:end_turn :tool_use :max_tokens :stop_sequence
  :pause_turn :refusal`.
- **`exe/lain`**: Thor CLI, provider hardcoded to `Provider::Anthropic.new` in `build_agent`;
  `--model`/`--max_tokens` flags exist, no `--provider`, no `--temperature`.
- **Spec infra**: `spec/spec_helper.rb` glob-requires `spec/support/**/*.rb` (sorted; the
  vcr-before-webmock load-order note is deliberate). Tags `:integration`/`:live`/`:vcr`/`:spike`
  gated in `spec/support/tags.rb` via `LAIN_*` env vars + `NetworkAccess.permit`. **Zero custom
  matchers exist**; no matcher gems (rspec 3.13, webmock 3.26, vcr 6.4, rantly 3.0, simplecov).
  Shared example groups: `"a Lain::Provider"` (provider_parity.rb, the seven gates), `"a monoid"`,
  `"a Regular value"`, `"a content-addressed store"`, `"canonical determinism"`,
  `"a memory search index"`, `"a meet semilattice under ancestry"`.
- **Matcher payoff counts**: 31× `Ractor.shareable?` assertions, 51× frozen checks, ~48×
  `raise_error(ArgumentError, /…/)`, 122× `stop_reason` assertions, ~354 digest-equality lines,
  ~79 NDJSON-parse lines.
- **Spec-less units** (basename-matched): `agent/budget`, `agent/loop_machine`,
  `agent/model_caller`, `agent/tool_runner`, `workspace`, `effect`, `tool/contracts`,
  `bench/session/loader` (agent internals are partially covered via `agent_spec.rb`).
- **Docs-vs-code disagreements**: the design plan (`jiggly-greeting-avalanche.md`) says the
  openai protocol + ollama shim were in the vendoring scope — code says only anthropic landed;
  **code wins**, and the user chose Ollama's *native* API over completing that vendoring.
  `planning/remaining-work.md` `R.2` already covers the `Workspace::OPENING_TAG` provenance
  question Joel's comment re-raises — cards cross-reference rather than duplicate.
- **Ollama model choice**: qwen3 small (`qwen3:4b` default) — confirmed current best small
  tool-calling family via 2026 rankings (web-checked 2026-07-14), configurable everywhere.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `Gemfile`, `Gemfile.lock`, `.rubocop.yml`, `CLAUDE.md`, `spec/spec_helper.rb`,
  `.pre-commit-config.yaml`.
- **Wave 0 (orchestrator, before any card):**
  1. Commit `planning/reviews/2026-07-14-joel-code-review.patch` + this plan + its ROADMAP line.
  2. `git checkout -- lib spec` — the review comments and Joel's edits are now preserved in the
     patch; cards **re-apply his edits from the patch** deliberately (T5 rules on the `==`
     edits; T8 handler.rb endless defs; T11 the agent.rb comment de-indent; T12 the
     `{ effect:, context: }` shorthand; T13 context.rb's endless `requires`; T14 the
     `Channel::Null` endless defs). Confirm `git status` is clean before cutting worktrees.
  3. Gemfile `:test` group: add `super_diff` and `shoulda-matchers`; `bundle install`
     (sandbox disabled, PATH per CLAUDE.md).
- **Between waves 1→2**: apply T4's reported `.rubocop.yml` diff (hash-shorthand cop config,
  rubocop-thread_safety verdict) and any `Gemfile` addition it recommends, then — if the
  shorthand recommendation is `always` — run `bundle exec rubocop -a` (Style/HashSyntax is
  `Safe: true`) so the whole non-vendored tree converges in one orchestrator commit; T12
  depends on the applied config.
- **Wave-2 watched file**: `spec/support/shared_examples/provider_parity.rb` is a de facto
  shared file between T11 (Agent constructor work — `parity_agent` calls `Agent.new` kwargs
  directly) and T15 (adds a new consumer of the group). Neither card may edit it without the
  orchestrator relaying the change to the other; check it at both merges.
- If T6 runs long: its `Workspace.empty`/`policy.rb` pieces are severable housekeeping — the
  binding deliverable T11–T14 and T9 wait on is only the guard/Freezable/AS-require verdict.
- Ruby for every card/hook shell: `export PATH="$HOME/.rubies/ruby-4.0.5/bin:$PATH"`.
- The conventions' *direction* is already ruled (see Rulings): T5 executes ruling 1; T6
  delivers the validate-then-freeze implementation pattern, the Freezable verdict, the
  exception-class ruling, and the AS-require idiom — that report is **binding on later
  cards**; the orchestrator relays it into dependent briefs and folds any CLAUDE.md addition
  itself.
- New lib *units* (T15's `provider/ollama.rb` subtree) get their `lib/lain.rb` manifest line from
  the orchestrator; subtree-internal requires belong to the unit's own index file (cards may edit
  `lib/lain/provider/ollama.rb` as that subtree's index — but note `provider/ollama.rb` sits
  under the `provider.rb` unit, so the actual wiring is one require line in `lib/lain/provider.rb`,
  which is *not* orchestrator-owned; T15 owns that line).
- The `R.*` findings ledger in `planning/remaining-work.md` is shared across many cards: cards
  **report** their proposed `R.*` entries in their completion notes; the orchestrator appends
  them (single writer, no merge conflicts).
- Deviations from the default process: T1 and T4 are document-deliverable cards with no
  red-green step (orchestrator read-through replaces it); T20's findings doc likewise, though
  its mechanical fixes and two new spec files follow normal TDD.

## Rulings (2026-07-14 walkthrough with Joel — these are DECIDED, cards implement them)

1. **Equality**: keep `is_a?(self.class)` in `ContentAddressed`/`DegradedSet` `==`; revert the
   `rescue NoMethodError` edits; `==`/`eql?`/`hash` agree (drop nothing from `hash`). (T5)
2. **Constructor guards**: **validate-then-freeze everywhere** — ActiveModel::Validations with
   `validate!` (or equivalent raising path) *before* `freeze`, replacing hand-rolled guard
   clauses at the commented sites. T6 delivers the implementation pattern (see its card for the
   `@errors`-ivar / Ractor-shareable trap and the exception-class ruling it must make).
3. **MessageEnvelope**: adopted, predecided — read-only whole value, idempotent `wrap`, `to_h`
   returns the ORIGINAL hash object; no `Message::Serializer` (wire encoding stays the
   Provider's). (T16)
4. **Handler → Effect namespace**: rename `Lain::Handler` → `Lain::Effect::Handler` (Joel also
   accepts `Effect::Executor`; Handler-under-namespace is the default), `Approving` →
   **`Gate`**. Old constants stay as deprecation aliases until T20 removes them. (T8, T20)
5. **Agent#transition**: **machine-native** — LoopMachine declares one event per normalized
   stop_reason (+ `:unknown`); `transition` fires the reason directly; `state_machines`'
   InvalidTransition is the loud gate-6 path. (T11)
6. **Middleware env**: **Env whole-value now** (not hash-plus-docs) — same wrap/`to_h`
   philosophy as MessageEnvelope, wrapped at the Stack boundary so callers keep passing
   hashes. (T12)
7. **Channel**: named destructive `drain`, no Enumerable; DropOldest stays hand-rolled with the
   WHY. (T14)
8. **Spec requires**: centralize only the *universal* stdlib requires (appearing across many
   spec files — count-driven, e.g. `stringio`/`tmpdir`/`json`) into spec_helper via
   orchestrator wiring; rarer ones stay in their leaf specs. (T7)
9. **Small items**: all eleven dispositions accepted as listed in the cards, plus: frontend
   **decorators** are the sanctioned home for render ergonomics (T19 evaluates), and the
   `to_s`-human / `inspect`-debug split becomes a sweep theme with DegradedSet as the
   reference (T20). Singletons stay unenforced by preference, not just by argument.

## Open decisions

None blocking. Deferred explicitly, not gating any card:

- The exception class raised by validate-then-freeze (`ActiveModel::ValidationError` vs
  re-raising `ArgumentError`) — T6 rules once, as part of its reported convention; ~48
  existing `raise_error(ArgumentError, /…/)` spec sites move with whatever it picks (each
  area card updates its own sites; T20 sweeps stragglers).

- Whether `temperature` ever becomes a first-class `Request` field (bench-identity question);
  T18 threads it through `extra` and carries an escalation trigger.
- Ollama `:thinking` capability (qwen3 emits `message.thinking` under `think: true`) — out of
  scope; noted for a follow-up `R.*` entry by T15.

## Waves

Wave 1: T1, T2, T3, T4, T5, T6, T7, T8, T10   (no unmet deps)
Wave 2: T9 (←T6), T11 (←T6,T7), T12 (←T4,T6,T8), T13 (←T6), T14 (←T6), T15 (←T1)
Wave 3: T16 (←T13), T17 (←T15), T18 (←T15), T19 (←T14)
Wave 4: T20 (←T11,T12,T13,T14), T21 (←T17,T18)
Wave 5: T22 (←T2, and last so it sweeps a settled suite)

Critical path: T1 → T15 → T17 → T21 (the longest dependency chain; T22 has only T2 as a dep
but is *placed* last so it sweeps a settled suite)

## Tasks

### T1 — Build the Ollama reference corpus          [wave 1] [risk: low] ✅ landed

**Depends on:** none
**Files:** create `references/ollama/INDEX.md`, `references/ollama/api-chat.md`,
`references/ollama/openai-compat.md` (brief, for contrast), `references/ollama/rubyllm-ollama.md`
**Reuse:** `references/` conventions (see existing `references/` INDEX style);
`references/repos/` for source checkouts if needed
**Shared-file wiring:** none

Fetch and distill: Ollama's `/api/chat` reference (message shape, `tools`, `tool_calls`,
`options` incl. `temperature`/`seed`/`num_ctx`, `think`, `keep_alive`, `done_reason` values,
`prompt_eval_count`/`eval_count`), its **streaming framing** (newline-delimited JSON, not SSE),
and RubyLLM's ollama provider (an OpenAI-subclass shim — capture what it maps and what it
ignores, as the contrast that justifies our native path). Any synthesized prose carries the
repo's ⚠️ LLM-generated label (file header + INDEX entry); verbatim API excerpts cite their URL
and retrieval date. Must explicitly confirm or correct these load-bearing beliefs T15/T17 build
on: (a) streamed `/api/chat` responses are NDJSON lines; (b) `tool_calls[].function.arguments`
arrives as a **parsed object**, not a JSON string; (c) `done_reason` stays `"stop"` on tool-call
turns, so `:tool_use` must be derived from the presence of `tool_calls`; (d) `seed` +
`temperature: 0` is the determinism recipe and its known limits.

**Acceptance criteria** (docs card — no specs; verified by orchestrator read-through):

```gherkin
Scenario: the corpus answers the implementer's wire questions
  Given references/ollama/INDEX.md
  When T15's implementer reads only the corpus
  Then beliefs (a)-(d) above are each explicitly confirmed, corrected, or marked unverifiable
  And every synthesized file carries the ⚠️ LLM-generated header label
```
→ spec file: none (docs-only card; orchestrator review replaces the red-green step)

**Escalation triggers:**
- Belief (a) is wrong (Ollama streams SSE or something else) — T17's whole design shifts; stop
  and tell the orchestrator before T15 is briefed.
- The current Ollama API has materially diverged from RubyLLM 1.16.0's assumptions (renamed
  fields, removed endpoints) — flag which, so T15 doesn't copy a stale mapping.

### T2 — Define custom matchers in spec/support/matchers/   [wave 1] [risk: low] ✅ landed

**Depends on:** none
**Files:** create `spec/support/matchers/be_ractor_shareable.rb`,
`spec/support/matchers/have_same_digest_as.rb`, `spec/support/matchers/stop_with.rb`,
`spec/support/matchers/journal_matchers.rb`, `spec/support/matchers/be_deeply_frozen.rb`;
create `spec/support_matchers_spec.rb` (specs for the matchers themselves)
**Reuse:** `RSpec::Matchers.define` DSL; existing idioms to encode — `Ractor.shareable?(x)`
(31 sites), digest equality (`a.digest == b.digest`), `stop_reason` eq (122 sites), NDJSON
parse-then-assert (`io.string.each_line.map { JSON.parse(_1) }`, ~79 lines)
**Shared-file wiring:** none (`spec/support/**/*.rb` glob already loads new files)

Note the spec path: `spec/support_matchers_spec.rb` sits deliberately OUTSIDE `spec/support/`
— a `_spec.rb` file inside the support glob gets **double-registered** (the glob `require`s it,
then RSpec's own file discovery `load`s it again, with no `$LOADED_FEATURES` dedupe), silently
running every example twice; do not "tidy" it inward. (Corrected 2026-07-14 by T2's panel
review: the original "runs zero examples" claim here was empirically false.) Matchers, each with a `failure_message` that names *what* diverged (digest hex prefixes, the
unparseable NDJSON line verbatim, the offending unfrozen object path): `be_ractor_shareable`;
`have_same_digest_as(other)` (+ negated message); `stop_with(:tool_use)` for Response;
`include_journal_record(type, **attrs)` / `be_valid_ndjson` over an IO/String journal;
`be_deeply_frozen` (frozen + `Ractor.shareable?` composed — the "value object" check as one
assertion). Define only these five files; adoption across the suite is T22, **not** this card.

**Acceptance criteria:**

```gherkin
Scenario: matchers pass and fail with diagnostic messages
  Given each matcher applied to a known-good and a known-bad subject
  When the known-bad expectation fails
  Then the failure message names the divergence (not just "expected true, got false")
```
→ spec file: `spec/support_matchers_spec.rb`

```gherkin
Scenario: journal matcher reads both IO and String
  Given a StringIO journal with two NDJSON records
  When include_journal_record("turn_usage") is asserted against io and io.string
  Then both forms match, and a torn line makes be_valid_ndjson fail naming that line
```
→ spec file: `spec/support_matchers_spec.rb`

**Escalation triggers:**
- A matcher needs library-internal state (e.g. reaching into `Response#raw`) to produce its
  message — that's a missing public reader on the lib side; report it rather than reaching in.
- `spec/support` load order breaks (matcher file sorting before rspec config) — the glob's
  sorted-order contract is documented in spec_helper; do not add an explicit require.

### T3 — Configure super_diff and shoulda-matchers        [wave 1] [risk: low] ✅ landed

**Depends on:** none (Wave 0 adds the gems)
**Files:** create `spec/support/super_diff.rb`, `spec/support/shoulda_matchers.rb`; modify
`spec/lain/tool/input_spec.rb` (or the spec that pins `Tool::Input` validations — locate it)
**Reuse:** `spec/support/` one-concern-per-file convention; `Lain::Tool::Input` is already
ActiveModel, so `shoulda-matchers` applies today without waiting on T6's verdict
**Shared-file wiring:** none (gems land in Wave 0; report the exact version constraints chosen
back to the orchestrator for the Gemfile)

super_diff: require + rspec integration, defaults tuned so string-keyed content-block hashes
diff structurally. shoulda-matchers: `config.integrate` with `:rspec` + `:active_model` only
(no Rails). Demonstrate value in one place each: convert a handful of `Tool::Input` validation
examples to `validate_presence_of`-style matchers, and leave one deliberately-rich hash
assertion in a comment-documented example showing the super_diff output shape.

**Acceptance criteria:**

```gherkin
Scenario: shoulda-matchers pin Tool::Input validation shape
  Given a Tool::Input subclass with a required attribute
  When its spec uses shoulda's validation matchers
  Then the spec is green and fails with a shoulda message if the validation is removed
```
→ spec file: `spec/lain/tool/input_spec.rb` (or located equivalent)

```gherkin
Scenario: the suite still passes wholesale under super_diff
  Given super_diff is integrated
  When bundle exec rspec runs
  Then all examples pass (super_diff changes failure OUTPUT only, never matching semantics)
```
→ spec file: whole suite (no new file)

**Escalation triggers:**
- super_diff conflicts with rantly's property-test output or `disable_monkey_patching!` — do not
  patch around it; report, we would rather drop the gem than fork its config.
- shoulda-matchers demands `activesupport` railtie behavior absent in plain ActiveModel — same:
  report before working around.

### T4 — Evaluate rubocop config: hash shorthand + thread_safety   [wave 1] [risk: low] ✅ landed (Part 2 BLOCKED-ON-DISCUSSION → Joel; PriceBook.default/Usage.zero siblings → T20 brief + R.*)

**Depends on:** none
**Files:** create `planning/reviews/rubocop-config-report.md` (report only — **no lib edits, no
.rubocop.yml edits**; the orchestrator applies the diff between waves)
**Reuse:** `.rubocop.yml` current config; CLAUDE.md's "config that encodes a reasoned policy is
fine" rule
**Shared-file wiring:** the report's proposed `.rubocop.yml` diff + (if adopted)
`gem "rubocop-thread_safety"` Gemfile line — both applied by the orchestrator

Two questions from the comments. (1) Joel wrote `{ effect:, context: }` in `tool_runner.rb` and
asked for cop support: evaluate `Style/HashSyntax` `EnforcedShorthandSyntax` (`always` vs
`either_consistent`) against the whole tree — count the offenses each setting creates and
recommend one, with the autocorrect surface enumerated. (2) The `Workspace.empty` `@empty ||=`
comment asked for thread-safety linting: evaluate `rubocop-thread_safety` — run it against
`lib/`, list every offense with a keep/fix/exclude verdict (the DropOldest mutex and Store
Monitor are *deliberate*; the plugin must not fight the design). Recommend adopt/reject with
reasons. Do not fix offenses here — the owning area cards do (T6 owns `Workspace.empty`).

**Acceptance criteria:**

```gherkin
Scenario: the report is mechanically applicable
  Given planning/reviews/rubocop-config-report.md
  When the orchestrator applies its .rubocop.yml diff verbatim, followed by the report's
       prescribed `rubocop -a` pass if the shorthand recommendation demands one
  Then bundle exec rubocop reports zero offenses outside lib/lain/provider/http/**
```
→ spec file: none (report card; the applied config is verified by the pre-commit hook)

**Escalation triggers:**
- `EnforcedShorthandSyntax: always` autocorrect would rewrite the vendored
  `lib/lain/provider/http/**` — vendored files keep upstream shape; the config needs an exclude,
  say so explicitly in the report.
- rubocop-thread_safety flags more than ~10 sites — that's a design conversation, not a lint
  sweep; stop at the inventory and mark the report BLOCKED-ON-DISCUSSION.

### T5 — Settle the equality convention (ContentAddressed, DegradedSet)  [wave 1] [risk: medium] ✅ landed

**Depends on:** none
**Files:** modify `lib/lain/content_addressed.rb`, `lib/lain/capability/degraded_set.rb`;
modify/create `spec/lain/content_addressed_spec.rb`, `spec/lain/capability/degraded_set_spec.rb`
**Reuse:** the `"a Regular value"` shared group (`spec/support/shared_examples/regular.rb`) —
equality is one of its laws; extend it rather than writing parallel examples
**Shared-file wiring:** none

Joel edited both `==` methods to duck-type via `rescue NoMethodError`. Push back with the
concrete defects and settle a convention: (1) `rescue NoMethodError` around `digest ==
other.digest` swallows a NoMethodError raised *inside* a broken `other.digest`, turning a bug
into silent `false` — the loud-failure premise inverted; (2) `DegradedSet#hash` still includes
`self.class` while its `==` no longer checks class, so two objects can be `==` with different
hashes — breaking Hash/Set membership, which is exactly where DegradedSet gets compared
(`Compare` refuses mismatched degraded sets). **Ruling 1 decides it: keep `is_a?(self.class)`** — revert both `rescue NoMethodError` edits.
The supporting evidence goes into the WHY comment at the module top: the rescue swallows
NoMethodError raised *inside* a broken `other.digest` (loud-failure inverted), and
`spec/lain/content_addressed_spec.rb`'s "does not equate instances of different classes
sharing a digest" example pins the cross-class-collision rationale (an Item vs a Node with
colliding digests must not collapse into one value). `==`/`eql?`/`hash` must agree — the
comment states the contract, and the convention is reported to the orchestrator as binding on
T20's sweep. Also in this card's
files: degraded_set.rb's remaining comments — `delegate :empty?` per convention, and the
`to_s`-should-be-human / `inspect`-is-debug preference (resolve: `to_s` → the joined
capability list, `inspect` keeps the class-tagged form; adjust the spec that pins them).

**Acceptance criteria:**

```gherkin
Scenario: equality never swallows a broken collaborator
  Given an object whose #digest method itself raises NoMethodError internally
  When it is compared against a ContentAddressed value
  Then the comparison raises rather than silently returning false
```
→ spec file: `spec/lain/content_addressed_spec.rb`

```gherkin
Scenario: eql?/hash contract holds for every == pair
  Given any two values the settled == deems equal
  When their hashes are compared and they are used as Hash keys
  Then hashes are equal and the second lookup hits the first entry
```
→ spec file: `spec/lain/capability/degraded_set_spec.rb` (+ the extended "a Regular value" group)

**Escalation triggers:**
- `spec/lain/content_addressed_spec.rb`'s impostor example (different class, same digest, must
  NOT be ==) is the decisive pinned evidence — if the chosen resolution requires rewriting
  that example or its rationale comment, that is a deliberate invariant change: stop and
  confirm with the orchestrator first.
- `Timeline#diverge_at`/`Store` lookups rely on digest-keyed Hash behavior — if any spec there
  goes red, the hash contract changed in a way the DAG feels; stop.

### T6 — Settle the constructor-guard convention (validations vs guards vs Freezable) [wave 1] [risk: medium] ✅ landed

**Depends on:** none
**Files:** modify `lib/lain/event.rb`, `lib/lain/workspace.rb`, `lib/lain/capability/policy.rb`;
modify `spec/lain/event_spec.rb`, create `spec/lain/workspace_spec.rb`, modify
`spec/lain/capability/policy_spec.rb` (locate exact name)
**Reuse:** `Lain::Tool::Input` (`lib/lain/tool/input.rb`) as the existing ActiveModel exemplar
and its shape-not-safety comment; CLAUDE.md traps (`presence: true` rejects `false`;
`ActiveModel::Naming` raises on anonymous classes)
**Shared-file wiring:** if a `require "active_support"` needs to move up the manifest, report
the one-line `lib/lain.rb` diff; any CLAUDE.md convention line is orchestrator-applied

**The convention is decided (Ruling 2): validate-then-freeze, everywhere the comments asked.**
This card's job is the *implementation pattern*, proven on `Event`'s five subclasses and
`Workspace`, then reported as binding. The traps the pattern must clear: (a) `validate!`
materializes `@errors` — an `ActiveModel::Errors` holding a back-reference to the instance; if
it survives to `freeze`, `Ractor.shareable?` goes red (that spec is the acceptance test).
Candidate shapes: `validate!` then `remove_instance_variable(:@errors)` then `freeze`; or a
class-level companion validator (validate a plain attributes carrier before construction) —
pick whichever keeps shareability AND reads at the call site. (b) If Events are `Data.define`
subclasses, the instance may already be frozen inside/after `initialize` — the companion-
validator shape is the fallback there; if NEITHER shape works for Data classes, escalate with
the evidence rather than silently reverting to guards. (c) The exception-class ruling (Open
decisions): `validate!` raises `ActiveModel::ValidationError`, existing specs assert
`ArgumentError` with message regexes — pick one surface, keep messages as diagnostic as the
hand-rolled ones (`message:` options can preserve them), and state the ruling in the
convention report. The card also: decides the `Freezable` concern (`prepend` + post-initialize
`freeze`) as the natural companion — with validate-then-freeze adopted, a shared concern that
does `validate! → scrub → freeze` in one place is now pulling real weight; fixes
`Workspace.empty`'s `@empty ||=` memoization (constant `EMPTY = new.freeze` — the race is
benign since instances are frozen-equivalent, but the constant is cleaner and answers the
thread-safety comment); resolves `workspace.rb`'s OPENING_TAG comment by pointing at the
existing `R.2` finding; answer `policy.rb`'s "one clean line" comment with the
verdict; and resolve `event.rb`'s `journal_type` comment ("use ActiveSupport instead") —
`String#underscore` from `active_support/core_ext/string` does replace the hand-rolled gsub,
adopt it iff the AS-require convention this card sets makes it cheap, else WHY-comment the
hand-rolled form (it is the journal discriminator: its output is pinned by recorded journals,
so whichever form wins must produce identical strings — spec that). Report the convention (including how AS core_ext requires are loaded, honoring the
`require "active_support"`-first trap) — binding on T11–T14, T20.

**Acceptance criteria:**

```gherkin
Scenario: invalid event construction still fails loudly and early
  Given each Event subclass's documented invalid input (nil digest, non-bool stream, zero count)
  When construction is attempted
  Then it raises with a message naming the attribute, and valid instances stay deeply frozen
```
→ spec file: `spec/lain/event_spec.rb`

```gherkin
Scenario: Workspace.empty is a shared frozen value
  Given two calls to Workspace.empty from anywhere
  When compared by identity
  Then they are the same frozen, Ractor-shareable object and reminders is empty
```
→ spec file: `spec/lain/workspace_spec.rb`

```gherkin
Scenario: validation replaces the guard without losing loudness or shareability
  Given each converted class's documented invalid input
  When construction is attempted
  Then it raises the convention's chosen exception naming the attribute,
  And every VALID instance stays deeply frozen and Ractor-shareable (no @errors residue)
```
→ spec file: `spec/lain/event_spec.rb` (+ shoulda validation matchers now applicable per T3)

**Escalation triggers:**
- `Ractor.shareable?` spec goes red on any Event after the change and neither the scrub nor
  the companion-validator shape cures it — that spec is the acceptance test; stop with the
  evidence (the ruling may need a Data-class exception, but that's Joel's call, not the card's).
- The `Freezable` `prepend` breaks `Data.define` subclasses (Data's initialize is special) —
  don't force it; scope the concern to plain classes and say so in the convention report.

### T7 — Spec hygiene: probes to spec/support, requires ruling   [wave 1] [risk: low] ✅ landed

**Depends on:** none
**Files:** modify `spec/lain/agent_spec.rb`, `spec/lain/agent_turn_middleware_spec.rb`;
create `spec/support/probes.rb`
**Reuse:** `spec/support/mock_recording.rb` (EchoTool/BoomTool already live there — probes join
that family, same file style)
**Shared-file wiring:** the spec_helper require line(s) for the universal stdlib set
(orchestrator applies)

Three comments. (1) Move `ContextProbe` out of `agent_spec.rb` into `spec/support/probes.rb`
(alongside a relocated turn-middleware probe class if it generalizes; if the middleware probe
stays local because it closes over example state, document that instead). (2) Replace the
`Dir.mktmpdir { |dir| @tmpdir = dir and example.run }` `and`-sequencing with the house style.
(3) The requires comment — **Ruling 8: centralize only the universal ones.** Count stdlib
requires across `spec/`; any appearing in many files (expect `stringio`, `tmpdir`, likely
`json`) moves to one spec_helper require (orchestrator wiring), and this card strips those
lines from the leaves; anything rarer stays in its leaf per the lib-side policy. State the
threshold used in the completion note.

**Acceptance criteria:**

```gherkin
Scenario: ContextProbe is reusable across spec files
  Given ContextProbe defined in spec/support/probes.rb
  When agent_spec runs alongside any other spec using it
  Then all examples pass and no spec file defines a top-level probe class anymore
```
→ spec file: `spec/lain/agent_spec.rb` (existing examples stay green — that IS the assertion)

**Escalation triggers:**
- `ContextProbe` at top-level scope collides under the support glob with another constant or
  leaks state between randomized examples — namespace it (`LainSpec::ContextProbe`) and note it.
- Moving the probe changes any `Ractor`/frozen assertion outcome in agent_spec — the probe was
  load-bearing in place; stop and report.

### T8 — Move Handler under Effect:: and rename Approving to Gate  [wave 1] [risk: medium] ✅ landed

**Depends on:** none
**Files:** git-mv `lib/lain/handler.rb` → `lib/lain/effect/handler.rb`, `lib/lain/handler/{live,
recorded,mock}.rb` → `lib/lain/effect/handler/`, `lib/lain/handler/approving.rb` →
`lib/lain/effect/handler/gate.rb`; modify `lib/lain/effect.rb` (becomes the subtree index);
git-mv `spec/lain/handler_spec.rb` → `spec/lain/effect/handler_spec.rb` (+ sibling handler
specs — locate); create `spec/lain/effect_spec.rb`
**Reuse:** `Effect` classes (`lib/lain/effect.rb`); `Handler::Mock` must keep satisfying the
same duck under its new constant
**Shared-file wiring:** `lib/lain.rb` manifest lines (handler unit folds into the effect unit)
and CLAUDE.md/README mentions — orchestrator applies both at merge

**Ruling 4 decides the naming question**: `Lain::Handler` → `Lain::Effect::Handler` (the
namespace kills the EventHandler ambiguity while keeping the algebra term; `Effect::Executor`
is Joel-approved as an alternative if `Effect::Handler` reads redundant in situ — implementer's
taste call, made once), subclasses `Effect::Handler::{Live,Recorded,Mock}`, and `Approving` →
**`Effect::Handler::Gate`** (it IS a gate). **Alias protocol** (this is what keeps wave 1
conflict-free): old constants stay as deprecation-aliased assignments (`Lain::Handler =
Lain::Effect::Handler`; `Effect::Handler::Approving = Gate`) so every untouched file keeps
compiling; this card updates only ITS files plus `spec/support/mock_recording.rb` if it names
Handler constants; later cards update references in *their* files (T11 agent.rb, T12
model_caller/tool_runner, T18 exe/lain, T19 frontend); **T20 removes the aliases** and grep-
gates the old names to zero. The mechanical wins land in the same card: predicate methods
`Effect::ToolCall#tool_call?` / `Effect::Approval#approval?` (base returns false — Null-Object
posture, no `respond_to?`), `Live#handles?` reads `effect.tool_call? || effect.approval?`;
`Live#perform` / `Recorded#handles?` keep their `case` **over class** where it is genuine
dispatch on a closed set (write the WHY: the effect signature is the algebra's closed
vocabulary; a `rescue NoMethodError` else-arm was considered and rejected for silent-failure
reasons — same verdict as T5). Re-apply Joel's `handler.rb` endless-def edits from the patch
(the working tree was reset in Wave 0). `effect_spec.rb`
finally gives the spec-less `effect.rb` direct coverage (predicates, frozen-ness, tool_use_id).

**Acceptance criteria:**

```gherkin
Scenario: effect predicates replace class checks at the reading sites
  Given an Effect::ToolCall, an Effect::Approval wrapping it, and a bare Effect
  When tool_call?/approval? are asked of each
  Then they answer true/false with no respond_to? or rescue anywhere in the call path
```
→ spec file: `spec/lain/effect_spec.rb`

```gherkin
Scenario: an unknown effect still fails loudly
  Given a Handler::Live handed an effect class it does not interpret
  When call is invoked
  Then Handler::UnhandledEffect (or the existing loud path) raises — never a silent no-op
```
→ spec file: `spec/lain/handler_spec.rb`

**Escalation triggers:**
- The rename leaks into journal record shapes (`"handler"`-derived strings in NDJSON, e.g. via
  `journal_type` or any class-name-derived discriminator) — recorded journals must replay
  unchanged; if a journaled string moves, stop.
- `Handler::Mock` or `Recorded.from_journal` can't express the predicate change without
  reaching into internals — the seam is wrong, report instead of forcing.
- The alias breaks `is_a?`/case-dispatch anywhere (aliased constants are the SAME class, so
  they shouldn't — but if any spec distinguishes them, that spec was testing names, not
  behavior; note it rather than deleting silently).

### T9 — Memory-area comment resolution          [wave 2] [risk: low]

**Depends on:** T6
**Files:** modify `lib/lain/memory/index.rb`, `lib/lain/memory/item.rb`,
`lib/lain/memory/manifest.rb`, `lib/lain/memory/recorder.rb`; modify
`spec/lain/memory/index_spec.rb`, create/modify `spec/lain/memory/item_spec.rb`
**Reuse:** `delegate` per T6's AS-require convention (the reason for the wave-2 placement);
`"a memory search index"` shared group must stay green
**Shared-file wiring:** none

Four files, five comments. `item.rb`: make `BLANK`/newline constants `private_constant`, expose
the behavior as a class-level predicate (`Item.blank_id?` or similar), and unit-test the Unicode
edge (NBSP-only id) directly — the comment's actual ask. `recorder.rb`: `delegate :root,
:fetch, to: :index` (per T6 convention); answer the singleton/enforcement comment in a WHY
comment — the Recorder is deliberately *not* a singleton (two Recorders over one Store is a
legitimate bench arm), the real invariant is "the Agent wires exactly one", which is a wiring
fact not a class-level constraint. `manifest.rb`: answer the entries-duplicate-the-index comment
— Manifest's `@entries`/`@lines` are a *render cache* sorted by a different key (id vs walk
order) with LWW already resolved; consolidating would re-sort per render; write the WHY.
`index.rb`: answer the "rust merkle crate?" comment against CLAUDE.md's five binding rules
(per-session, not hot per-turn; fails rules 2–4) — WHY comment pointing at the table.

**Acceptance criteria:**

```gherkin
Scenario: blank-id rejection is directly pinned including Unicode blanks
  Given an id of " " (NBSP only)
  When Item construction (or the exposed predicate) evaluates it
  Then it is rejected as blank, and BLANK is not reachable as Memory::Item::BLANK
```
→ spec file: `spec/lain/memory/item_spec.rb`

```gherkin
Scenario: Recorder keeps satisfying the bare-Index duck after delegation
  Given Tools::MemoryRead constructed with a Recorder
  When a write then a read happen through it
  Then the read sees the write — same behavior as before the refactor
```
→ spec file: `spec/lain/memory/index_spec.rb` (existing examples; extend if the duck is unpinned)

**Escalation triggers:**
- `private_constant` breaks an existing spec that referenced `Item::BLANK` directly — that spec
  was testing structure, not behavior; rewrite it via the predicate, but note it.
- Delegation changes `Recorder`'s method arity/visibility in a way `MemoryRead`'s contract spec
  notices — the duck was tighter than documented; stop.

### T10 — Values comment redress: StopReason, Timeline, Ledger  [wave 1] [risk: low] ✅ landed

**Depends on:** none
**Files:** modify `lib/lain/response.rb`, `lib/lain/timeline.rb`, `lib/lain/ledger.rb`;
modify `spec/lain/ledger_spec.rb`
**Reuse:** existing comment voice in `timeline.rb`/`canonical.rb` (CLAUDE.md names them the
exemplars)
**Shared-file wiring:** none

Comment-redress card — the resolutions are mostly *better comments*, per the interview. (1)
`response.rb`: the ":unknown is a pre-state-machine holdover?" comment is wrong in an
instructive way — `:unknown` is what lets the state machine branch *explicitly* on unrecognized
wire values (gate 6 totality); rewrite the module comment so the next reader doesn't re-raise
the question. (2) `timeline.rb`: answer "is this like a Range?" in one sentence in the class
comment (it is a persistent chain handle over a shared Store — closer to a git ref than a
Range; Range implies bounded enumeration over a receiver that owns its elements). (3)
`ledger.rb`: rename private `priced(turn, entry)` → `turn_cost` (the comment's suggestion is
simply right); answer "namespace under Journal?" with the WHY — Ledger *consumes* journals but
belongs to pricing/accounting; nesting it under Journal would invert the dependency direction
(Journal must not know its readers).

**Acceptance criteria:**

```gherkin
Scenario: ledger behavior is unchanged by the rename
  Given the existing ledger_spec examples including the unknown-model rescue path
  When the suite runs after the rename
  Then every example passes unmodified except mechanical method-name references
```
→ spec file: `spec/lain/ledger_spec.rb`

**Escalation triggers:**
- `priced` turns out to be called outside `ledger.rb` (grep first) — it wasn't private in
  practice; widen the card's file list only after confirming with the orchestrator.
- Any rewritten comment contradicts the design plan's stated reasoning — the plan doc wins;
  quote it rather than paraphrasing from memory.

### T11 — Agent core: constructor shape, transition, LoopMachine   [wave 2] [risk: medium]

**Depends on:** T6, T7
**Files:** modify `lib/lain/agent.rb`, `lib/lain/agent/loop_machine.rb`; modify
`spec/lain/agent_spec.rb`, `spec/lain/agent_state_machine_spec.rb` (locate exact name), create
`spec/lain/agent/budget_spec.rb`
**Reuse:** `Agent::Budget`, `Agent::Accounting` (the existing extracted collaborators — the
constructor question is whether more of these exist); `ContextProbe` from `spec/support/probes.rb`
(T7); T6's guard convention
**Shared-file wiring:** none expected; if a new collaborator file is created, report its
`lib/lain.rb` (or `agent.rb`-index) require line

Five comments. (1) `delegate :usage, to: :accounting` per convention (also fix the de-indented
comment above it, preserved in the patch). (2) The A-LOT-of-constructor-args comment: the
honest answer is that several args are already encapsulated (Budget, Accounting) and the rest
split into two duck groups — *collaborators* (provider/toolset/context/handler/middleware) and
*run state* (timeline/workspace/session/journal); evaluate ONE extraction (e.g. an
`Agent::Wiring`/keyword-args carrier) and adopt it only if it removes `seed_run_state` rather
than adding a layer; otherwise keep and write the WHY. (3) `seed_run_state` + "avoid stateful
assignment": these ivars are set once at construction — if (2)'s extraction lands, this method
dissolves; that is the preferred resolution over cosmetic tweaks. (4) `build_tool_runner`'s
`handler || Handler::Live.new(...)`: make the default explicit at the signature
(`handler: nil` → resolved in one obvious place) or keep with a WHY — nil-tolerant default
construction is exactly what the Null-Object rule frowns at; prefer a named default. (5) The
`transition` case: **Ruling 5 — machine-native.** LoopMachine declares one event per
normalized stop_reason plus `:unknown`; `transition` fires the reason directly (verify the
gem's dynamic-firing API — `send("#{reason}!")` is the documented bang path and raises
`StateMachines::InvalidTransition` on illegality, which is the loud gate-6 arm; `fire_event`
variants exist too). The safety argument to encode in the WHY comment: `StopReason.normalize`
closes the wire's open enum BEFORE firing, so the machine's event list is a total function of
the normalized vocabulary — and a totality spec pins that mechanically (below). The accepted
tradeoff (machine event names coupled to StopReason's vocabulary) is deliberate; cross-reference
`response.rb`'s rewritten comment (T10). (6) LoopMachine's "ActiveModel with
state machines?" and naming: document why `state_machines` (not AM::StateMachine, which doesn't
exist as such) was adopted and why the module extraction is genuine (the DSL block constant +
rubocop-length reasoning is already in the comment — sharpen it), and rename only if a better
name survives the panel (e.g. keep, or `Agent::Machine`); `budget_spec.rb` closes the spec-less
gap on `Budget`.

**Acceptance criteria:**

```gherkin
Scenario: Agent's public surface is unchanged by the constructor work
  Given every existing agent_spec example (including session threading via ContextProbe)
  When the suite runs
  Then all pass with no example-body edits beyond construction-site mechanics
```
→ spec file: `spec/lain/agent_spec.rb`

```gherkin
Scenario: Budget is pinned directly
  Given a Budget at its iteration ceiling
  When the loop asks it to admit one more turn
  Then it refuses, and the refusal reason is inspectable
```
→ spec file: `spec/lain/agent/budget_spec.rb`

```gherkin
Scenario: an unrecognized stop_reason still lands in a legal state
  Given a Response whose stop_reason normalized to :unknown
  When transition fires it
  Then the machine reaches its failure/legal state loudly (gate 6), never NoMethodError
```
→ spec file: `spec/lain/agent_state_machine_spec.rb`

```gherkin
Scenario: the machine's event list is total over the normalized vocabulary
  Given StopReason::KNOWN plus :unknown
  When each symbol is checked against LoopMachine's declared events
  Then every one has a declared event (the drift guard: adding a StopReason without a
       machine event fails THIS spec, not a live run)
```
→ spec file: `spec/lain/agent_state_machine_spec.rb`

**Escalation triggers:**
- The seven correctness-gate specs constrain constructor shape more than expected (gates
  reference `Agent.new` kwargs directly) — an extraction that forces gate-spec rewrites is too
  big for this card; stop and split.
- `state_machines` gem behavior (callbacks, `value:` symbols) breaks under any LoopMachine
  rename — the drift-guard/mermaid follow-up in the roadmap depends on this module's shape; stop.

### T12 — Middleware Env whole-value + agent collaborators    [wave 2] [risk: high]

**Depends on:** T4, T6, T8
**Files:** create `lib/lain/middleware/env.rb`; modify `lib/lain/middleware.rb`,
`lib/lain/middleware/journal_requests.rb`, `lib/lain/middleware/refuse_secret_writes.rb`,
`lib/lain/agent/model_caller.rb`, `lib/lain/agent/tool_runner.rb`, `lib/lain/effect/handler.rb`
(`#to_app`, at its post-T8 path); create `spec/lain/middleware/env_spec.rb`,
`spec/lain/agent/model_caller_spec.rb`, `spec/lain/agent/tool_runner_spec.rb`; modify
`spec/lain/middleware_spec.rb`, `spec/lain/agent_turn_middleware_spec.rb`,
`spec/lain/repl_middleware_spec.rb`
**Reuse:** `Middleware::Base#downstream`; `Effect::Handler::Mock`; the `"a monoid"` shared
group — its laws must hold over Env; T16's MessageEnvelope contract (same wrap/`to_h`
philosophy — this card and T16 should converge on one idiom, coordinate via the orchestrator)
**Shared-file wiring:** none

**Ruling 6: Env whole-value, now.** `Middleware::Env` — idempotent `Env.wrap(hash_or_env)`,
Hash-duck surface middleware actually use (`fetch`, `[]`, `merge` returning a new Env, `to_h`),
per-phase reader sugar where it pays (`env.request`, `env.response`, `env.effect`,
`env.result`). The deployment trick that keeps churn low: **wrap at the Stack boundary** —
`Middleware::Stack#call` wraps its input once, so every caller (agent, exe/lain's repl
dispatch, specs) keeps passing plain hashes and existing third-party-style middleware that
treats env as a hash duck keeps working; `Handler#to_app` returns `env.merge(result: ...)`
which is now an Env. The monoid property tests move to run over Env — associativity and
pass-through identity are the acceptance bar for the merge semantics (if Env#merge diverges
from Hash#merge observably, the laws catch it). The per-phase key contract gets documented at
`env.rb`'s top and pinned by specs — the docs half of the original plan survives inside the
whole value. Also in this card: `model_caller.rb`'s `env =` naming fixed by the readers
(`@middleware.call(...).response` reads correctly); re-apply Joel's `{ effect:, context: }`
shorthand from the patch (per T4's now-applied config) and sweep `model_caller.rb` for the
same; new unit specs close the spec-less gap on both agent collaborators (tool_runner: gate-2
single-user-turn assembly + the raw-String input pass-through note; model_caller: env in/out
contract).

**Acceptance criteria:**

```gherkin
Scenario: the env contract is pinned per phase, through Env
  Given a probe middleware on the model phase and one on the tool phase
  When a run passes through each
  Then each probe receives an Env (wrapped at the Stack boundary from the caller's hash),
       the model env exposes :request in and :response out, the tool env :effect/:context in
       and :result out — exactly the documented keys
```
→ spec file: `spec/lain/agent/model_caller_spec.rb`, `spec/lain/agent/tool_runner_spec.rb`

```gherkin
Scenario: the middleware monoid laws hold over Env
  Given the "a monoid" shared group parameterized over Env-carrying stacks
  When the property tests run
  Then associativity and pass-through identity hold, and wrap is idempotent
       (Env.wrap(Env.wrap(h)).to_h preserves h's entries)
```
→ spec file: `spec/lain/middleware/env_spec.rb`

```gherkin
Scenario: tool results assemble into one user turn
  Given a Response bearing two tool_use blocks
  When ToolRunner performs them
  Then both tool_results land in a single user message, order preserved (gate 2)
```
→ spec file: `spec/lain/agent/tool_runner_spec.rb`

**Escalation triggers:**
- Writing the env-contract doc reveals a phase whose keys are *not* consistent across call
  sites (e.g. turn middleware sees :settled sometimes) — that's a real bug, not a docs task;
  report before papering over it.
- Any middleware in the tree mutates env in place (relying on Hash identity across the chain)
  rather than merging — Env's functional merge would silently drop that mutation; grep for
  `env[`-assignment first, and if found, stop and report before wrapping.
- The repl phase (exe/lain's dispatch — T18's file, untouchable here) passes something the
  Stack-boundary wrap can't absorb transparently — do not edit exe/lain; report the seam to
  the orchestrator for T18's brief.
- This card visibly exceeds one hand-off (Env + laws + two collaborators + two journal
  middlewares) — the pre-agreed split point is Env+laws+to_app first, collaborator adoption
  second; ask the orchestrator to split rather than rushing the laws.

### T13 — Context combinator structure          [wave 2] [risk: medium]

**Depends on:** T6
**Files:** modify `lib/lain/context.rb`, `lib/lain/context/base.rb`, `lib/lain/context/prune.rb`,
`lib/lain/context/compact.rb`, `lib/lain/context/cache_breakpoints.rb`; modify
`spec/lain/context_spec.rb`, `spec/lain/context/prune_spec.rb`,
`spec/lain/context/cache_breakpoints_spec.rb`
**Reuse:** the `"a monoid"` shared group (associativity/identity laws must pass unchanged);
`Context::Compact` (uncommented but same family — keep consistent)
**Shared-file wiring:** none

Six comments. (1) `base.rb` naming ("category-theory-esque deserves better than Base";
"replace Base with Identity?"): weigh `Combinator` as the class name with `Identity = new` kept
as the unit — Base-the-name says nothing, and Joel is right that instantiable-Base-as-identity
is the actual design; whatever wins, the class comment states the algebra (endomorphism monoid
on the message list) in one sentence. Instantiable-base *is* the Null-Object here — if renaming,
`Identity` stays a constant of the new name. (2) "`>>` returns Composed — wrong area?": push
back; `a >> b` constructing `Composed` is precisely `Proc#>>`'s own idiom, write the one-line
WHY. (3) "module/Concern instead of class?": no — identity needs an *instance* and composition
needs state (`Composed` holds two); WHY comment. (4) `prune.rb`'s duplicated `requires`: the default
**already exists on Base** (`base.rb`, with a comment) — the work is *deleting the redundant
copies*, which live in `prune.rb` and `compact.rb` here, and in `recall.rb`/`reminder.rb`
(T16's files — leave those; T16's brief inherits the deletion). (5) Constructor guards in `prune.rb`/`cache_breakpoints.rb`
per T6's convention. (6) `context.rb`: re-apply Joel's endless `requires` from the patch; the `cache_marked_system`
"branching on type is a smell" comment — resolve by normalizing `system` to block form **once at
construction** (`Context.new`) so render never type-branches; verify purity/digest stability
(same inputs → same bytes) is preserved by the existing render determinism specs.

**Acceptance criteria:**

```gherkin
Scenario: combinator laws survive the restructure
  Given the monoid shared group over the (possibly renamed) combinator family
  When the property tests run
  Then associativity and identity hold, and Identity remains the unit by that name
```
→ spec file: `spec/lain/context/*` (existing law consumers, green unchanged)

```gherkin
Scenario: render output is byte-identical across the refactor
  Given a fixed Timeline/Toolset/Workspace triple and a String system prompt
  When render runs before and after the system normalization
  Then the two Requests have equal digests
```
→ spec file: `spec/lain/context_spec.rb`

If the `Combinator` rename wins, it **certainly** reaches `recall.rb`/`reminder.rb` (they
subclass Base) — the protocol is: rename this card's own subtree and leave
`Base = Combinator` as a compatibility alias so T16's files stay green untouched; T16 finishes
its two files and drops the alias.

**Escalation triggers:**
- The rename ripples beyond the `context/` subtree + its specs (some other unit names the
  constant) — hand the sweep list to the orchestrator instead of widening the card.
- Normalizing system at construction changes any committed digest in a recorded
  journal/cassette fixture — cache identity moved; stop immediately (this is R.1 territory).
- `Context#system` is a public reader that `Bench::Session` serializes into recorded session
  files — if normalization changes the *reader's* shape (String → blocks) and not just
  render's output, check the `Session`/`Loader` round trip (spec-less until T20, so nothing
  goes red on its own) and report before committing; normalizing inside the render path
  instead of the stored value is the fallback.

### T14 — Channel and Sink: delegation, Null style, buffer honesty  [wave 2] [risk: low]

**Depends on:** T6
**Files:** modify `lib/lain/channel.rb`, `lib/lain/channel/drop_oldest.rb`, `lib/lain/sink.rb`;
modify `spec/lain/channel_spec.rb`, `spec/lain/sink_spec.rb` (locate exact names)
**Reuse:** T6's guard + delegate conventions; `SizedQueue` semantics notes in CLAUDE.md traps
**Shared-file wiring:** none

Five comments. (1) `delegate :closed?, :size, to: :queue` — but note `@queue` needs a reader or
`to: :@queue` style per convention. (2) Re-apply Joel's endless-def edits on `Channel::Null` from the patch. (3)
Capacity guard per T6. (4) `drop_oldest.rb`'s "prefer a library" comment: answer with the WHY —
the design plan explicitly rejected `concurrent-ruby-edge` (Channel lives there, unstable API)
and a plain `SizedQueue` cannot express evict-then-push atomically; cite both in the comment,
and note `Async::LimitedQueue` as the M5-concurrency-choice revisit. (5) `sink.rb`'s
painter's-algorithm worry: `print` builds one small buffer per call and pushes one event — no
quadratic re-append exists; verify by reading `write`/`puts`/`print` allocation shape, unify
`print` with `write` if they truly duplicate (the comment's other half), and answer with a WHY
comment; add a spec pinning that N `print` calls emit N events (no hidden accumulation). This
card also adds `Channel#each` **if** it can be honest — `each` on a consuming queue destroys;
if kept, it must be documented as draining (`pop`-until-closed) for T19's TTY loop to consume;
if that reads as a lie, the resolution is a named `drain { |event| }` instead.

**Acceptance criteria:**

```gherkin
Scenario: delegation preserves closed-channel semantics
  Given a closed Channel with one buffered event
  When closed?/size/pop are called
  Then answers match the pre-refactor behavior exactly (pop drains, then nil)
```
→ spec file: `spec/lain/channel_spec.rb`

```gherkin
Scenario: sink emits one attributed event per write-family call
  Given an IOAdapter over a recording channel
  When write/puts/print are each called N times
  Then exactly N events arrive per method, each carrying the tool_use_id
```
→ spec file: `spec/lain/sink_spec.rb`

**Escalation triggers:**
- The Journal's synchronous-write path shares any code this card touches — the
  lossless-Journal/lossy-Channel split is a design invariant; if an edit could make the Journal
  drop or reorder, stop.
- `drain`/`each` semantics interact with the frontend thread's only-exit contract
  (`render_until_closed`) — if the TTY spec (T19's dependency) can't express its exit condition
  over the new API, the API is wrong; coordinate with the orchestrator before T19 is briefed.

### T15 — Provider::Ollama, native API, non-streaming    [wave 2] [risk: high]

**Depends on:** T1
**Files:** create `lib/lain/provider/ollama.rb` (subtree index), `lib/lain/provider/ollama/encoding.rb`,
`lib/lain/provider/ollama/transport.rb`; create `spec/lain/provider/ollama_spec.rb`,
`spec/lain/provider/ollama_parity_spec.rb`
**Reuse:** `Provider::AnthropicRaw` as the structural template (neutral provider + `Transport`
over the fork's `Configuration`/`Connection`); `AnthropicEncoding` as the encoding-mixin
pattern; `StopReason.normalize`; `Usage`; the `"a Lain::Provider"` shared group
(`provider_parity.rb`) with its `provider_factory` parameterization; `references/ollama/` (T1)
**Shared-file wiring:** one require line in `lib/lain/provider.rb` (T15 owns it — that index is
not orchestrator-owned); report any new `Configuration` option registrations

Native `/api/chat`, non-streaming first (`stream: false`; streaming is T17). Encode: `Request` →
`{model:, messages:, tools:, stream: false, options: {temperature:, seed:, num_ctx:}}` — strip
`"cache" => true` markers (no prompt caching; the capability gap is the *policy's* job to
surface, the encoder just must not leak the key onto the wire), translate `Toolset#to_schema`'s
Anthropic-shaped `{name, description, input_schema}` into `{type: "function", function: {name,
description, parameters}}`, map `system` to a leading system message. Decode: `message.content`
→ text block; `message.tool_calls` → `tool_use` blocks with **parsed-Hash input** (verify
against T1's belief (b); synthesize `tool_use` ids — Ollama has none — deterministically,
e.g. index-based, and document that in a WHY comment); `done_reason` mapping `"stop"` →
`:end_turn`, `"length"` → `:max_tokens`, else `StopReason.normalize`; **presence of tool_calls
forces `:tool_use`** (belief (c)); `prompt_eval_count`/`eval_count` → `Usage`. Capabilities:
**`%i[]` — empty** until T17 delivers streaming; declaring `:streaming` here would be a lying
capability in the one subsystem built to catch lying capabilities. The parity group's Context
defaults `stream: true`, so encode must **ignore `request.stream` and always send
`stream: false`**, with a WHY comment naming T17 as the resolver; no `prompt_caching`/
`thinking`/`strict_tools` either — the `:degrade` policy journals the gaps (that's the bench
working as designed). Config: `ollama_api_base` (default
`http://localhost:11434`), no api-key requirement (`local?` → true on the transport), default
model constant `DEFAULT_MODEL = "qwen3:4b"`. Temperature/seed arrive via `Request#extra` —
document the key names the encoder honors. Unit specs stub HTTP via WebMock (network stays
blocked); parity spec runs the seven gates through the shared group with stubbed responses,
mirroring `anthropic_raw_parity_spec.rb`'s factory shape. Propose an `R.*` entry for the
deferred `:thinking` capability (qwen3 `think:` mode).

**Acceptance criteria:**

```gherkin
Scenario: a tool-call round trip normalizes to the Lain contract
  Given a stubbed /api/chat response bearing one tool_calls entry with object arguments
  When complete runs
  Then the Response has one tool_use block whose input is a Hash (never a JSON String),
       a synthesized stable id, and stop_reason :tool_use despite done_reason "stop"
```
→ spec file: `spec/lain/provider/ollama_spec.rb`

```gherkin
Scenario: cache markers never reach the wire
  Given a Request whose system blocks carry "cache" => true
  When encode runs twice
  Then neither payload contains a "cache" key anywhere, and the two payloads are
       byte-identical (encoding is pure)
```
→ spec file: `spec/lain/provider/ollama_spec.rb`

```gherkin
Scenario: a stream-true Request still completes, non-streaming
  Given a Request with stream: true (the Context default the parity group produces)
  When complete runs against a stubbed non-streaming body
  Then the wire payload said stream: false and a full Response comes back
```
→ spec file: `spec/lain/provider/ollama_spec.rb`

```gherkin
Scenario: provider parity gates hold
  Given the "a Lain::Provider" shared group with an Ollama factory over stubbed responses
  When the seven gates run
  Then all pass
```
→ spec file: `spec/lain/provider/ollama_parity_spec.rb`

**Escalation triggers:**
- T1's corpus contradicts a belief this card builds on (arguments-as-string, done_reason
  vocabulary) — re-read the corpus before coding; if the contradiction survives, stop and
  re-brief.
- The parity shared group assumes a capability Ollama lacks (e.g. a gate exercises cache
  markers end-to-end) — do NOT weaken the shared group; escalate so the group grows a
  capability-conditional section deliberately, with the orchestrator.
- Synthesized tool_use ids collide with gate-2's result-matching (ToolRunner keys on
  tool_use_id) — the id scheme must be unique per response; if per-turn uniqueness is not
  enough, stop.

### T16 — MessageEnvelope for Recall/Reminder        [wave 3] [risk: high]

**Depends on:** T13
**Files:** modify `lib/lain/context/recall.rb`, `lib/lain/context/reminder.rb`; create
`lib/lain/context/message_envelope.rb`, `spec/lain/context/message_envelope_spec.rb`; modify
`spec/lain/context/recall_spec.rb`, `spec/lain/context/reminder_spec.rb`
**Reuse:** `Canonical.normalize` (string-keyed hash is the canonical message form — any view
must be a READ view over it, never a replacement); T13's (possibly renamed) combinator base;
`Workspace::OPENING_TAG` / the `R.2` structural-provenance finding
**Shared-file wiring:** none (a new file's require goes in `context.rb`'s index — card-editable)

The primitive-obsession comments (`message["role"]`, `real_text_blocks` "should live on a
Message", `workspace_tagged?` "on Message or Workspace"). **Ruling 3 decides the shape:
`MessageEnvelope`, adopted** — a read-only whole value over the canonical hash (which stays
the pipeline primitive: `Canonical`/digests/purity depend on the string-keyed shape).
Contract, per the walkthrough (Avdi Grimm's conversion-at-the-boundary + Sandi Metz's
single-responsibility warnings): `MessageEnvelope.wrap(hash_or_envelope)` is **idempotent**;
`#to_h` returns the **original hash object** (never a rebuilt copy — digest stability by
construction); surface is questions only (`user?`, `real_text_blocks`, `workspace_tagged?`,
`query_text`) — no mutation API, no rendering, and equality/digest never route through it
(Canonical owns identity on the raw hash); **no `Message::Serializer`** — wire encoding stays
the Provider's responsibility, one owner. Combinator-internal: envelopes in the bodies,
hashes at the combinator boundary. Allocation guidance (not a gate): one envelope per message,
zero per-block allocations — render runs every turn. Lives at
`lib/lain/context/message_envelope.rb`; if a Provider ever wants it, that's an escalation, not
a move.
`workspace_tagged?` stays cross-referenced to `R.2` (string-prefix matching is a known accepted
tradeoff pending structural provenance — do not fix R.2 here). Two inherited items: delete the
redundant `requires` copies in both files (the default lives on the base — T13 did prune/compact)
and drop T13's `Base = Combinator` alias if the rename landed. And answer `reminder.rb`'s "why
does Reminder get the workspace injected but Recall doesn't?" — a real design question:
Reminder renders workspace *content* (needs the object), Recall only needs the tag constant to
*exclude* workspace blocks; write that WHY at the constructor, or if the asymmetry turns out
false in code, escalate rather than paper over it. Whichever way it lands, the
tail-merge in both `#call`s (`rest + [{ "role" => ..., "content" => last["content"] + ... }]`)
gets one shared, named construction — the actual duplication the comments circle.

**Acceptance criteria:**

```gherkin
Scenario: recall and reminder output is byte-identical across the refactor
  Given the existing recall/reminder spec fixtures (hits present, empty, workspace-tagged tail)
  When call runs after the refactor
  Then output message arrays are == to the pre-refactor arrays (digest-stable)
```
→ spec file: `spec/lain/context/recall_spec.rb`, `spec/lain/context/reminder_spec.rb`

```gherkin
Scenario: purity holds
  Given identical inputs
  When call runs twice
  Then results are equal and the input arrays are not mutated
```
→ spec file: `spec/lain/context/recall_spec.rb`

```gherkin
Scenario: the envelope's boundary contract
  Given a canonical message hash h
  When MessageEnvelope.wrap(h) and wrap(wrap(h)) are taken
  Then both are the same envelope semantics, to_h returns h ITSELF (equal?, not just ==),
       and the envelope exposes no mutating method
```
→ spec file: `spec/lain/context/message_envelope_spec.rb`

**Escalation triggers:**
- The envelope wants to live outside `context/` (e.g. Provider encoding would also benefit) —
  scope creep into the render spine; stop, that's a plan-level decision.
- Any change to `derive_query`'s extraction rule breaks the pinned bench-card rule the comment
  at `workspace_tagged?` references — that rule is pinned deliberately; behavior must not move.

### T17 — Ollama streaming: NDJSON accumulation        [wave 3] [risk: high]

**Depends on:** T15
**Files:** create `lib/lain/provider/ollama/stream_assembler.rb`; modify
`lib/lain/provider/ollama.rb` (index + `stream: true` path), `lib/lain/provider/ollama/transport.rb`;
create `spec/lain/provider/ollama_streaming_spec.rb`
**Reuse:** `AnthropicRaw::StreamAssembler` as the shape template; the fork's Faraday `on_data`
hooks (`streaming/faraday_handlers.rb`) — but NOT its SSE parser (`event_stream_parser` does not
apply: Ollama frames NDJSON lines, per T1 belief (a)); the design plan's chunk-boundary lesson
(deliberately-split chunks are the bug class VCR can't catch)
**Shared-file wiring:** none

Streamed `/api/chat` emits one JSON object per line; content arrives incrementally in
`message.content` fragments, `tool_calls` typically on discrete lines, the final line carries
`done: true` + `done_reason` + counts. The assembler must: buffer bytes across chunk boundaries
(a line split across two reads reassembles — the `input_json_delta` lesson transposed),
concatenate content fragments in order, collect tool_calls, and produce the same `Lain::Response`
the non-streaming path yields. The acceptance oracle is **path parity**: same canned exchange
through both paths → equal Responses (this is the dry analogue of the SDK-oracle differential).
This card also closes T15's deliberate gaps: `complete` starts honoring `request.stream`, the
capability set gains `:streaming`, and T15's "always stream: false" WHY comment comes out.

**Acceptance criteria:**

```gherkin
Scenario: chunk boundaries cannot corrupt a line
  Given a canned NDJSON stream split at deliberately awkward byte offsets (mid-line, mid-UTF-8)
  When the assembler consumes the chunk sequence
  Then the assembled Response equals the one from the unsplit stream
```
→ spec file: `spec/lain/provider/ollama_streaming_spec.rb`

```gherkin
Scenario: streaming and non-streaming agree
  Given the same canned exchange served as a stubbed stream and as a stubbed single body
  When complete runs with stream: true and stream: false
  Then the two Responses are equal (content blocks, stop_reason, usage)
```
→ spec file: `spec/lain/provider/ollama_streaming_spec.rb`

**Escalation triggers:**
- Real Ollama interleaves `thinking` fragments into the stream for qwen3 even without
  `think: true` — the assembler would silently drop them; if T1's corpus shows this, surface it
  before writing the drop.
- Faraday's `on_data` chunking through the vendored Connection behaves differently for
  non-SSE bodies (no `event_stream_parser` in the stack) — if the fork's middleware stack
  can't serve raw NDJSON chunks, the Transport needs its own adapter path; that's a design
  change, escalate.

### T18 — exe/lain provider selection and temperature    [wave 3] [risk: medium]

**Depends on:** T15
**Files:** modify `exe/lain`, `lib/lain/context.rb`, `spec/lain/context_spec.rb` (the
`extra:` passthrough lands on T13's restructured file — wave ordering guarantees no race);
create/modify `spec/lain/cli_spec.rb` (locate the existing exe/CLI spec if any; else create)
**Reuse:** Thor option idiom already in `exe/lain`; `Provider::Anthropic::DEFAULT_MODEL` /
`Provider::Ollama::DEFAULT_MODEL`; `Request#extra` as the temperature route (grounding: no
first-class field exists)
**Shared-file wiring:** none

`--provider anthropic|ollama` (default anthropic), `--api-base` (ollama only), `--temperature`
and `--seed` (threaded via `Context` → `Request#extra`; grounding verified `Context.new` lacks
an `extra:` passthrough today — add exactly that passthrough, keeping `render` pure). `--model` default becomes
provider-dependent. Unknown provider name fails loudly with the valid set (match
`Capability::Policy.for`'s error voice).

**Acceptance criteria:**

```gherkin
Scenario: provider selection constructs the named backend
  Given exe/lain invoked with --provider ollama --api-base http://localhost:11434
  When build_agent runs (unit-tested at the CLI class seam, no network)
  Then the Agent holds a Provider::Ollama with that base and the qwen3 default model
```
→ spec file: `spec/lain/cli_spec.rb`

```gherkin
Scenario: temperature reaches the wire payload but not the cache identity
  Given --temperature 0 --seed 7
  When the Context renders and Ollama encodes
  Then the payload carries options.temperature 0 and options.seed 7,
       and Request#cache_payload is identical to the flagless render
```
→ spec file: `spec/lain/cli_spec.rb`

**Escalation triggers:**
- Temperature-in-`extra` means two runs at different temperatures share a Request digest — if
  any Bench/Compare spec keys runs by request digest such that this aliases two arms, that is
  the moment `temperature` earns first-class `Request` membership; stop and escalate (this is
  the plan's named deferred decision).
- `bench record` (`Lain::Bench::CLI`) constructs its own provider — if wiring selection there
  doubles this card, do only `exe/lain` and report the bench CLI as a follow-up line.

### T19 — Frontend readability: TTY and ApprovalPolicy    [wave 3] [risk: medium]

**Depends on:** T14
**Files:** modify `lib/lain/frontend/tty.rb`, `lib/lain/frontend/approval_policy.rb`; modify
their specs (locate: `spec/lain/frontend/*_spec.rb`)
**Reuse:** T14's `drain`/`each` verdict on Channel; `Pastel`; the output-discipline guard spec
(frontend is the ONE place `$stdout` is legal — keep it that way)
**Shared-file wiring:** none

Six comments. (1) `render_until_closed` consumes T14's drain API instead of the hand-rolled
pop-loop. (2) `render` naming/dispatch: today it filters one event type — restructure so the
method does what its name says. Per the walkthrough ruling, the sanctioned shape for your
Renderable instinct is **decorators living IN the frontend**: e.g. a per-event-type decorator
(`Frontend::Decorators::ToolOutput.new(event).render(pastel)`) that owns color/format for its
event, with `render` dispatching event-type → decorator. That gives the "bundle the
presentation with the thing presented" ergonomics WITHOUT a `Renderable` include on lib value
objects — which would move presentation into `lib/` non-frontend classes, the
output-discipline inverse; the WHY comment states that boundary, colors stay frontend-owned.
Evaluate decorator-per-type vs a single dispatch method by how many event types the TTY
actually renders today (one-armed dispatch may not earn a decorator family yet — say so if
not, and leave the seam named). (3)
`AFFIRMATIVE` → `private_constant`. (4) `!answer.nil? && …` → keep the fail-closed shape but
lose the double negative (note: `answer&.strip&.match?(AFFIRMATIVE) || false` or AS
`present?` — either, per T6's AS posture; EOF/nil must still deny — that's the load-bearing
part, pin it). (5) The ApprovalPolicy naming/split comment ("policy vs UserPrompt"): evaluate
the split — a pure decision object + a prompt object that owns the terminal I/O; adopt if it
lets the policy be unit-tested without IO doubles, else document. (6) The "how much TTY do we
need vs irb/reline" comment: answer as a WHY note pointing at the design plan's M1b/M4
interface section (TTY-first-then-Neovim is decided there); no re-litigating in code comments.

**Acceptance criteria:**

```gherkin
Scenario: EOF and garbage still deny (fail closed)
  Given approval prompts answered with EOF, "", "n", and "Y"
  When the policy decides
  Then only "Y"/"y"/"yes" approve; everything else denies
```
→ spec file: `spec/lain/frontend/approval_policy_spec.rb` (locate exact name)

```gherkin
Scenario: the frontend drains to close and renders only its events
  Given a channel carrying one ToolOutput and one unrelated event, then closed
  When the render loop runs
  Then ToolOutput renders, the other is ignored, and the loop exits on close
```
→ spec file: `spec/lain/frontend/tty_spec.rb` (locate exact name)

**Escalation triggers:**
- Any refactor makes a non-frontend file mention Pastel/colors — output-discipline inverse
  violation; the guard spec won't catch presentation-knowledge leaks, so self-police and stop.
- The policy/prompt split changes `Handler::Approving`'s constructor contract — that file is
  T8's (wave 1, already merged) — coordinate through the orchestrator rather than editing it.

### T20 — Themed review sweep of the uncommented files    [wave 4] [risk: medium]

**Depends on:** T11, T12, T13, T14
**Files:** create `planning/reviews/2026-07-14-sweep-findings.md`; small mechanical fixes
in-place across swept files (each fix ≤ ~10 lines; anything larger becomes a finding);
create `spec/lain/bench/session/loader_spec.rb`, `spec/lain/tool/contracts_spec.rb` (the two
remaining spec-less units nobody else claimed)
**Reuse:** the settled conventions (T5 equality, T6 guards/Freezable/AS, T12 env contract,
T13 combinator shape); Joel's 47 comments as the theme catalogue (the patch file)
**Shared-file wiring:** proposed `R.*` entries reported to the orchestrator (single writer)

Joel reviewed 31 lib files; ~60 got no eyes. Sweep them **through the lens of his themes** —
delegate sites, validate-then-freeze convention drift, naming honesty, primitive obsession,
endless-def consistency, `to_s`-human vs `inspect`-debug (Ruling 9: DegradedSet's split is the
reference — sweep every class where the two are aliased or conflated), thread-safety of
class-level state — so the review reflects his standards, not generic lint. Two rename
closeouts ride along: **remove T8's deprecation aliases** (`Lain::Handler`,
`Effect::Handler::Approving`) after updating any straggler references the area cards didn't
own, and grep-gate the old constants to zero. Scope: all of `lib/lain/**` EXCEPT files owned by earlier
cards and EXCEPT `lib/lain/provider/http/**` (vendored: upstream shape is preserved by policy —
sweep it for **correctness findings only**, never style). Priority order (size × centrality):
`tool.rb` (353), `middleware.rb` (237), `journal.rb` (195), `request.rb` (191), `toolset.rb`,
`session.rb`, `tools/*`, `bench/*`, `grader/*`, `canonical.rb`, `store.rb`, `turn.rb`,
`usage.rb`, `price_book.rb`. Output triage per finding: (a) mechanical → fix in place now;
(b) real but deferred → proposed `R.*` entry with acceptance criterion; (c) rejected theme
application → one line saying why. The findings doc mirrors the R-section voice in
`planning/remaining-work.md`.

**Acceptance criteria:**

```gherkin
Scenario: every swept file is dispositioned
  Given the findings doc
  When cross-checked against the lib file list minus owned/vendored files
  Then every file appears exactly once with fixed/deferred/clean status
```
→ spec file: none (doc deliverable) — mechanical fixes are covered by the existing suite green

```gherkin
Scenario: the last spec-less units gain direct specs
  Given bench/session/loader and tool/contracts
  When their new unit specs run
  Then loader round-trips a recorded session and contracts enforce read-before-write
```
→ spec file: `spec/lain/bench/session/loader_spec.rb`, `spec/lain/tool/contracts_spec.rb`

**Escalation triggers:**
- A "mechanical" fix in `canonical.rb`, `turn.rb`, `store.rb`, or `request.rb` would change any
  digest — those four ARE the identity spine; nothing that moves a byte there is mechanical;
  finding-only, never fix in place.
- More than ~5 findings cluster in one file (likely `tool.rb` at 353 lines) — that file wants
  its own card next plan; cap the in-place fixes there and say so.

### T21 — Ollama live-gated specs and determinism probe    [wave 4] [risk: medium]

**Depends on:** T17, T18
**Files:** create `spec/integration/provider/ollama_spec.rb`, `spec/support/ollama_tag.rb`;
create `docs/ollama.md` (how to run: install, `ollama pull qwen3:4b`, env vars)
**Reuse:** `spec/support/tags.rb`'s gating idiom (`LAIN_INTEGRATION` pattern) — add `:ollama`
the same way (`LAIN_OLLAMA=1`; plus a reachability pre-check that *skips with a message*, not
fails, when the server is down); `NetworkAccess.permit` for the localhost hole;
`MockRecording`'s EchoTool for the end-to-end run
**Shared-file wiring:** none (tag file is support-glob loaded)

Three layers: (1) smoke — `/api/chat` round trip, Response contract holds against the real
server; (2) determinism probe — same prompt, `temperature: 0`, fixed `seed`, N=3 runs,
assert identical text (this is the "local determinism oracle" the whole stream exists for;
if qwen3:4b is *not* reproducible under seed+temp0, the spec pins whatever IS true and the doc
records it honestly — a false determinism claim poisons every bench conclusion built on it);
(3) end-to-end — a real `Agent` + EchoTool tool-call turn against qwen3:4b, gates 2/4/5
observable. WebMock must stay closed for everything untagged.

**Acceptance criteria:**

```gherkin
Scenario: untagged runs never touch the server
  Given LAIN_OLLAMA unset
  When bundle exec rspec runs
  Then ollama examples are excluded with the skip message, and WebMock blocked no localhost call
```
→ spec file: `spec/support/ollama_tag.rb` (guard examples, mirroring network_access.rb's style)

```gherkin
Scenario: temperature-0 determinism is measured, not assumed
  Given LAIN_OLLAMA=1 and a running server with qwen3:4b pulled
  When the same seeded request runs three times
  Then the three response texts are identical (or the spec pins the documented weaker invariant)
```
→ spec file: `spec/integration/provider/ollama_spec.rb`

```gherkin
Scenario: a live tool-call turn round-trips through the Agent
  Given an Agent over Provider::Ollama with EchoTool
  When one task runs
  Then the tool is called, its result lands in one user turn, and the run settles
```
→ spec file: `spec/integration/provider/ollama_spec.rb`

**Escalation triggers:**
- qwen3:4b won't produce a tool call for the canned prompt reliably — do not loosen the
  assertion into flakiness; try the prompt shapes from T1's corpus, then escalate with the
  transcript (model choice may need to move to qwen3:8b — that's Joel's call).
- Seeded runs differ across invocations — see (2): pin the true invariant and flag it
  prominently in docs/ollama.md and the completion note; do NOT mark the spec pending.

### T22 — Matcher adoption sweep across the suite      [wave 5] [risk: low]

**Depends on:** T2 (and sequenced last so every other card's specs are settled)
**Files:** modify spec files suite-wide (the 31 `Ractor.shareable?` sites, 51 frozen checks,
122 `stop_reason` assertions, digest-equality and NDJSON sites) — spec files only, zero lib
edits
**Reuse:** T2's matchers; T3's super_diff (already live)
**Shared-file wiring:** none

Mechanical adoption: each recurring idiom becomes its matcher where the rewrite is
strictly-clearer; sites where the raw form carries extra meaning (e.g. a deliberate
`shareable?` false-assertion in the tautology-regression spec) stay. One idiom per commit
group so a revert is surgical.

**Acceptance criteria:**

```gherkin
Scenario: the sweep changes zero behavior
  Given the full suite before and after
  When bundle exec rspec runs after each idiom's sweep
  Then example counts and outcomes are identical, only expectation syntax changed
```
→ spec file: whole suite

**Escalation triggers:**
- A rewrite makes a previously-passing example fail — the matcher and the site disagree on
  semantics (e.g. deep vs shallow frozen); the matcher may be wrong, stop and check T2's
  definitions before continuing the sweep.
- Property-test bodies (rantly blocks) resist matcher syntax — leave them; do not thread
  matchers into `property_of` blocks.

## Integration checks

After the last wave, on the merged tree:

1. `bundle exec rspec` — full suite green (560+ examples plus this plan's additions), zero
   pending except any deliberately-documented `:ollama`-gated skip.
2. `bundle exec rubocop` — zero offenses at default metrics under the T4-updated config.
3. `spec/output_discipline_spec.rb` green (T19's frontend work is the risk surface).
4. `bundle exec rake compile && cargo test && cargo clippy --all-targets -- -D warnings` —
   Rust untouched by this plan; still must be green (worktrees compile independently).
5. `pre-commit run --all-files`.
6. Grep gate: `grep -rn "CODE REVIEW" lib spec` returns **nothing** — every comment resolved,
   removed, or converted to a WHY comment / `R.*` entry. Likewise the rename closeout:
   `grep -rn "Lain::Handler\b\|Handler::Approving" lib spec exe` returns nothing (aliases
   removed by T20; `Effect::Handler` is the only spelling left).
7. `planning/remaining-work.md` carries the new `R.*` entries the cards reported (orchestrator
   folds; verify none were dropped against the cards' completion notes).
8. **Manual (Joel):** with Ollama running and `qwen3:4b` pulled —
   `LAIN_OLLAMA=1 bundle exec rspec spec/integration/provider/ollama_spec.rb`, then an
   interactive `exe/lain --provider ollama --temperature 0` session to *feel* the exploration
   arm work.
9. **Manual (Joel):** read `planning/reviews/2026-07-14-sweep-findings.md` — the sweep exists
   to surface what you skipped; it only counts once you've read it.
