# Themed review sweep — the uncommented lib files (T20)

> **Purpose.** Joel reviewed 31 lib files with 47 in-tree `# CODE REVIEW` comments; ~50 more got
> no eyes. This sweep runs those uncommented files through the SAME themes — delegate sites,
> validate-then-freeze drift, naming honesty, primitive obsession, endless-def consistency,
> `to_s`-human vs `inspect`-debug (Ruling 9, DegradedSet the reference), thread-safety of
> class-level state — so the review reflects Joel's standards, not generic lint. Each swept file
> is dispositioned exactly once below: **fixed** (mechanical, applied in place), **deferred**
> (real, proposed as an `R.*` entry), or **clean**. Scope is all of `lib/lain/**` except files
> owned by earlier cards (T5/T6/T8–T19) and `lib/lain/provider/http/**` (vendored: correctness
> findings only, never style).
>
> **Manual (Joel):** this doc only counts once you've read it — the sweep exists to surface what
> you skipped.

Swept against `main` @ the T17/T13/T11/T12/T14 merge state. Full suite green and RuboCop clean
after the mechanical fixes (see the completion note).

---

## 1. Mechanical fixes applied in place

Each ≤ ~10 lines; all covered by the existing suite staying green.

- **`usage.rb` — `Usage.zero` is now a frozen constant, not a memoized class ivar.** The
  `@zero ||= new(...)` shape rubocop-thread_safety flagged (T4's sibling finding) is replaced by
  `ZERO = new.freeze` with `def self.zero = ZERO`. Because a constant set INSIDE the
  `Data.define` block scopes to `Lain`, not `Usage` (the CLAUDE.md trap), the constant is added
  by **reopening** `class Usage` after the block. `Usage.zero`'s value is unchanged (`new(0,0,0,0)`),
  so no digest or journal byte moves; no spec pins object identity.
- **`price_book.rb` — `PriceBook.default` is now a deeply-frozen constant.** Same
  `@default ||= new(...)` → `DEFAULT = new(prices: DEFAULTS)` with `def self.default = DEFAULT`,
  answering the thread-safety comment the same way T6 answered `Workspace.empty`
  (`EMPTY = new.freeze`). Panel fix folded in (Patterson): a shallow `.freeze` on the constant
  left `@prices` — a fresh mutable Hash out of `transform_keys(&:to_s)` — writable through the
  shared singleton, corrupting `PriceBook.default` process-wide. The constructor now interns the
  keys and freezes the map and the instance (`@prices = prices.to_h { |k, p| [-k.to_s, p] }.freeze`
  then `freeze`; `Price` values are Data, frozen already), so `Ractor.shareable?(PriceBook.default)`
  holds and a red-first spec pins it (`be_deeply_frozen` + a mutate-through-singleton `FrozenError`
  repro). The instructive contrast: `Usage::ZERO` needed none of this — `Data.define` freezes
  recursively for free.
- **`context/base.rb` — `Context::Identity` is now frozen** (`Combinator.new.freeze`). It was the
  one combinator that was not, inconsistent with `Composed` (which freezes) and failing
  `Ractor.shareable?` for the monoid *unit*. The base carries no mutable state, so freezing is a
  pure win; the monoid/render-determinism specs stay green. (Coordinator mid-flight item 4 / brief.)
- **Naming-honesty YARD/comment refs** to the pre-T8 `Handler::…` constants, in files this sweep
  owns: `journal.rb` (`{Handler::Recorded.from_journal}` → `{Effect::Handler::Recorded…}`),
  `tool/invocation.rb` (`{Handler::Live}` → `{Effect::Handler::Live}`),
  `tools/memory_write.rb` (prose `Handler::Live` → `Effect::Handler::Live`).
- **`middleware/env.rb` — YARD ref** `{Lain::MessageEnvelope}` → `{Lain::Context::MessageEnvelope}`
  (the constant T16 will land under `Context::`). Coordinator mid-flight item 1.

## 2. Rename closeout (T8's deprecation aliases removed)

- Removed `Lain::Handler = Lain::Effect::Handler` (`effect/handler.rb`) and
  `Effect::Handler::Approving = Gate` (`effect/handler/gate.rb`).
- Migrated the straggler references the area cards didn't own, **before** dropping the aliases:
  `exe/lain` (3 constructor sites + 1 comment), `spec/lain/seams/tools_agent_spec.rb` (8 sites +
  a `describe` label), `spec/lain/tools/edit_file_spec.rb`, `spec/lain/tools/bash_spec.rb`
  (comment), and lib comment/YARD refs in `tool.rb`, `tool/input.rb`, `tool/contracts.rb`,
  `tools/bash.rb`, `frontend.rb`, `frontend/approval_policy.rb`.
- **`README.md`** (mine to edit): lines ~18/33/48/69 — `Handler::Approving` → `Effect::Handler::Gate`,
  `Handler::Live` → `Effect::Handler::Live`, `interpreted by a Handler` → `an Effect::Handler`,
  the built-table cell `Effect / Handler` → `Effect / Effect::Handler`.
- **Grep-gate: `grep -rn "Lain::Handler\b\|Handler::Approving" lib spec exe` returns ZERO.**
- Bare `Handler::Recorded`/`Handler::Live` as informal shorthand survives in a handful of comments
  inside *other cards'* files (`agent/tool_runner.rb`, `context/compact.rb`,
  `effect/handler/recorded.rb`, spec descriptions) — not gated, not naming a removed constant,
  and out of this card's edit scope; left as-is.

**CLAUDE.md diff (orchestrator-owned — reported, NOT edited):** three stale `Handler` mentions —

```
line ~71:  `Provider::Mock` and `Handler::Mock` exist because the specs needed
        →  `Provider::Mock` and `Effect::Handler::Mock` exist because the specs needed

line ~113: top; `handler.rb`'s children subclass `Handler`, so they load after the class body).
        →  top; `effect/handler.rb`'s children subclass `Effect::Handler`, so they load after the
           class body).

line ~149: constraint. Tool calls are `Effect`s interpreted by a `Handler`; `Middleware` is the
        →  constraint. Tool calls are `Effect`s interpreted by an `Effect::Handler`; `Middleware`
           is the
```

## 3. Two spec-less units gained direct specs

- **`spec/lain/bench/session/loader_spec.rb`** — pins `Session::Loader` directly (constructed from
  entries, not via `Session.load`): round-trips a recorded session (timeline head, baseline,
  toolset schema, context inputs, degraded set), accepts both raw NDJSON lines and parsed Hashes,
  skips foreign records, and raises `Corrupt` on turn/head/multiplicity/absent-header integrity
  violations.
- **`spec/lain/tool/contracts_spec.rb`** — pins `Tool::Contracts`: the read-before-write
  precondition raises `ContractViolation` when unmet and dispatches once satisfied, preconditions
  run before `#perform` (no dispatch on violation), postconditions raise after `#perform`, base
  contracts compose before a subclass's own, and a contract with no predicate block is refused.

Both green (20 examples).

---

## 4. Deferred findings (proposed `R.*` — orchestrator appends to `planning/remaining-work.md`)

- **R.4 — `to_s`/`inspect` split across value objects (Ruling 9 sweep theme).** Five value
  objects alias `inspect` to a debug-shaped `to_s` (`#<Lain::Foo …>`), conflating the two exactly
  the way DegradedSet did before T5 split them: **`Request`** (`request.rb`), **`Turn`**
  (`turn.rb`), **`Toolset`** (`toolset.rb`), **`Provider`** (`provider.rb`, inherited by every
  backend), and **`Memory::Bm25`** (`bm25.rb`). The convention T5 set is `to_s` → the
  human-readable projection (DegradedSet's joined capability list), `inspect` → the class-tagged
  `#<…>` debug form. Deferred rather than fixed in place because (a) `Request` and `Turn` are the
  identity spine — a `to_s` that flows into an interpolated journal/error string is a byte-risk
  the sweep must not take unilaterally — and (b) applying the split to only the non-spine three
  would reintroduce the very inconsistency the theme exists to remove; one card should do all five
  uniformly with the interpolation audit. **Acceptance:** each of the five defines `to_s` as a
  human projection and `inspect` as the `#<…>` debug form (no `alias inspect to_s`); no journaled
  or digested byte changes (the spine two verified against a recorded journal/cassette).

## 5. Rejected theme applications (one line each)

- **`tool.rb` — `Tool#dig` vs `SchemaValidator#dig` duplication.** Deliberate cross-class (a
  `SchemaValidator` is not a `Tool`, so it cannot inherit); a mixin for two 4-line key-spelling
  helpers costs more indirection than it removes. The precedence match is documented at the site.
- **`turn.rb` — hand-rolled `normalize_role` guard vs T6's Guard-carrier.** It already
  validates-then-freezes in spirit (raises `InvalidRole` before `freeze`); it is spine and low-churn,
  and threading a throwaway carrier through a content-addressed constructor is risk without payoff.
- **`provider.rb` — `NotImplementedError` (stdlib) vs `Tool`'s `NotImplemented < Error`.** The
  stdlib class is not a `StandardError`, so a `rescue => e` won't swallow an unimplemented abstract
  method — which is the correct loud-failure behavior for an abstract-method stub. Left as-is.
- **`tool_runner`/`compact`/`recorded` comment shorthand `Handler::Live`** — informal prose in
  other cards' files, not a removed constant; out of edit scope, left.

## 6. Vendored — `lib/lain/provider/http/**` (29 files)

Correctness-only by policy. The fork is exercised end to end by `AnthropicRaw` (suite green) and
its byte-identity is proven against the SDK oracle by the dry differential; a light scan surfaced
no `rescue nil` / silent-swallow smells and no correctness defect. No findings. Upstream shape
preserved — untouched.

---

## Coverage — every swept file, dispositioned once

| File | Status |
|---|---|
| `usage.rb` | fixed (ZERO constant) |
| `price_book.rb` | fixed (DEFAULT constant) |
| `context/base.rb` | fixed (Identity frozen) — *T13 file, coordinator-assigned* |
| `middleware/env.rb` | fixed (YARD ref) — *T12 file, coordinator-assigned* |
| `effect/handler.rb`, `effect/handler/gate.rb` | fixed (aliases removed) — *T8 files, closeout* |
| `journal.rb` | fixed (YARD ref) |
| `tool/invocation.rb` | fixed (YARD ref) |
| `tools/memory_write.rb` | fixed (comment ref) |
| `request.rb` | deferred (R.4 to_s/inspect) — spine, otherwise exemplary |
| `turn.rb` | deferred (R.4 to_s/inspect) — spine, otherwise exemplary |
| `toolset.rb` | deferred (R.4 to_s/inspect) |
| `provider.rb` | deferred (R.4 to_s/inspect) |
| `memory/bm25.rb` | deferred (R.4 to_s/inspect) |
| `tool.rb` | clean (dig duplication rejected) |
| `store.rb`, `canonical.rb` | clean (spine) |
| `session.rb`, `compare.rb`, `error.rb` | clean |
| `capability.rb`, `capability/guard.rb` | clean |
| `tool/contracts.rb`, `tool/input.rb`, `tools.rb` | clean |
| `tools/read_file.rb`, `tools/list_files.rb`, `tools/memory_read.rb` | clean |
| `tools/edit_file.rb`, `tools/bash.rb`, `tools/todo_write.rb` | clean |
| `provider/mock.rb`, `provider/anthropic.rb`, `provider/anthropic_encoding.rb` | clean |
| `provider/anthropic_raw.rb`, `…/stream_assembler.rb`, `…/transport.rb` | clean |
| `memory.rb`, `memory/journal_memory_root.rb`, `ledger/index.rb` | clean |
| `grader.rb`, `grader/fixture.rb`, `grader/rubric.rb` | clean |
| `bench.rb`, `bench/cli.rb`, `bench/dry_replay.rb`, `bench/live_replay.rb` | clean |
| `bench/rewrites.rb`, `bench/session.rb`, `bench/session/loader.rb` | clean |
| `bench/speculative.rb`, `bench/variance.rb`, `bench/variance_fixtures.rb` | clean |
| `agent/accounting.rb`, `agent/transition_listener.rb` | clean |
| `frontend.rb`, `version.rb` | clean |
| `provider/http.rb` | clean (ours, not vendored: the subtree's require-order index, per the Requires policy; the header comment carries the zeitwerk WHY) |
| `provider/http/**` (29 files) | clean (vendored, correctness-only) |

### Notes on other cards' territory (not acted on)

- **`Context::Base` alias** (`context/base.rb:67`, `Base = Combinator`): still referenced by
  `spec/lain/context/base_spec.rb` and by `context/recall.rb`/`context/reminder.rb` (T16, not yet
  landed). Left in place — T16 owns dropping it once it migrates those two files.
- **`require "lain/context/base"`** in `spec/lain/context/{prune,cache_breakpoints,compact,reminder}_spec.rb`
  names the FILE (still present, loads clean), not the retired constant — harmless; those specs are
  T13/T16's, left untouched (coordinator mid-flight item 2).
- **`lib/lain/agent/budget.rb`** is excluded from the table without appearing on any card's Files
  line: T11's card gave it its direct spec (`spec/lain/agent/budget_spec.rb`), which makes the file
  T11-settled territory in substance even though only the spec was named — re-sweeping it here
  would second-guess a just-reviewed unit.
