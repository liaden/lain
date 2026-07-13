# Working on Lain

Lain is an agent harness built as a **study bench**. The agent is the vehicle; the bench is
the deliverable. Optimize for making context strategies, tool designs, and orchestration
tactics swappable, observable, and comparable — not for making the agent good.

The approved design plan lives at `~/.claude/plans/jiggly-greeting-avalanche.md`. Read it
before making architectural decisions. It records *why*, including several conclusions that
cost real debugging to reach.

## Toolchain

The shell's default `ruby` is the wrong one (system 3.2.3). This project needs 4.0.5:

```bash
export PATH="$HOME/.rubies/ruby-4.0.5/bin:$PATH"
```

`bundle install` and `gem` write outside the repo, so they need the sandbox disabled.
`ruby-4.0.1` is also installed and is **unusable** for native gems — its `RbConfig` points at
a deleted Homebrew `gmkdir`/`ginstall`.

```bash
bundle exec rspec              # 297 examples; :integration excluded by default
bundle exec rubocop -a         # safe autocorrect; see the warning below
bundle exec rake compile       # builds the Rust extension into lib/lain/lain.so
cargo test && cargo clippy --all-targets -- -D warnings
pre-commit run --all-files     # what the git hook runs
```

Integration specs hit the real API and cost money. They run only with **both**:

```bash
LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
```

## RuboCop

Use `rubocop -a`. Do **not** reach for `-A` without reading the diff.

`-a` applies only cops marked `Safe: true`. `-A` also applies unsafe ones, and at least one of
those is actively dangerous here: `Style/RedundantSelfAssignment` (`Safe: false`) flagged
`@timeline = @timeline.append(...)` on the assumption that `append` mutates its receiver, as
`Array#append` does. Ours was pure. The "correction" would have discarded every turn with no
test failure. The method is now `Timeline#commit`, which both reads correctly and sidesteps
the cop.

**Never loosen a `Metrics/*` limit to make code pass.** Extract a collaborator with a real,
separate responsibility (see `Agent::Budget`, `Agent::ToolRunner`). Config that encodes a
*reasoned policy* is fine — `Metrics/ParameterLists: CountKeywordArgs: false`,
`Naming/BlockForwarding: explicit`.

## Code style

- **No `next`, `break`, or `redo`** unless genuinely unavoidable. `raise ... unless cond` beats
  `next if cond`; `select` then `each` beats `next unless`; `digest &&= step` beats
  `break if digest.nil?`.
- **`Enumerable` and `Enumerator` are the good abstractions.** A method that yields is a method
  that composes. Prefer `include Enumerable` over reimplementing `map`/`select`; return an
  `Enumerator` rather than materializing an Array a caller may not want; reach for
  `each_with_object` / `inject` before an accumulator you mutate by hand. `Enumerator::Lazy` is
  free streaming — it is how a Timeline walk stays O(1) in memory.
- **SOLID, read through Sandi Metz.** Small objects, one responsibility each; depend on messages,
  not on types; inject collaborators rather than construct them. `Agent::Budget` and
  `Agent::ToolRunner` exist because `Agent` was carrying two responsibilities that were not its
  own. When a `Metrics/*` cop trips, it is usually telling you an object is missing.
- **Null Object over `nil` checks.** `Sink::Null` is the exemplar: it satisfies the same duck as
  `Sink::IOAdapter` and sends the bytes nowhere, so no caller ever writes `if sink`. A `nil`
  guard repeated at three call sites is an object waiting to be named.
- **TDD is what finds the seam.** Writing the spec first is what makes a dependency visible and
  forces it to be injected. `Provider::Mock` and `Handler::Mock` exist because the specs needed
  them, not because the design anticipated them.
- **ActiveSupport is welcome where it earns its place.** `ActiveSupport::Concern` is the right
  way to extract orthogonal behavior into a named, separately-testable module. Judge each core
  extension on whether it preserves **loud failure**: `StringInquirer` was rejected for
  `.settled?` because `method_missing` makes a typo (`.setled?`) return `false` in silence, and
  this state machine's premise is that unknown values fail loudly. (Trap: `require
  "active_support/core_ext"` raises unless `require "active_support"` comes first.)
- **Tool input goes through `Tool::Input`** (ActiveModel). One declaration yields both the JSON
  Schema the model sees and the local validation, so they cannot drift, and you get type
  coercion for free. Those validations check **shape, not safety** — read the comment at the
  top of `lib/lain/tool/input.rb` before adding a validator that sounds like a security
  control. It is not one.
- **Comments are minimal, and explain WHY.** Idiomatic Ruby that the community would recognize
  needs no gloss. If a reader cannot tell *what* the code does, that is a defect in the code:
  extract a named method or a named variable until it reads. Only when the mess is *forced* — a
  wire-format quirk, a cop's false positive, a performance shape — write a comment that says
  both what it does and why it has to be ugly. Match `lib/lain/timeline.rb` and
  `lib/lain/canonical.rb`.
- **Value objects are deeply frozen.** `Ractor.shareable?(turn)` must stay `true` — it is the
  mechanical statement of "no reachable mutable state", and it broke once because
  `Symbol#to_s` and string interpolation both return *mutable* Strings. There is a spec.

## Output discipline

Only the frontend may touch `$stdout`/`$stderr`. Everything else writes to an injected
`Lain::Sink` or pushes attributed events onto a `Lain::Channel`. `spec/output_discipline_spec.rb`
parses the AST of every file in `lib/` and fails on `puts`/`print`/`warn`/`$stdout`/`$stderr`
outside `lib/lain/frontend/`. The Rust extension denies `clippy::print_stdout` and
`clippy::print_stderr` at the crate root.

This is not fussiness: the Journal is NDJSON, it is the experiment record, and one stray
warning interleaved into it makes `JSON.parse` fail on that line. We found this the hard way.

## Testing

Write specs alongside the code — unit specs plus lightweight `:integration` specs that hit the
live API.

**Each spec must `require` its own subject** (`require "lain/agent"`), not rely on `lain.rb`
wiring. `pre-commit` stashes tracked-but-unstaged changes before running hooks, so a spec that
depends on `lain.rb` will fail during an unrelated commit when `lain.rb` is stashed back to
`HEAD`. Specs that load themselves are immune.

## Committing

Commit directly on `main`, in logical chunks, with terse high-signal messages. No trailers.

**Commit in dependency order.** Because pre-commit stashes unstaged tracked changes and runs
the full suite against the staged tree, a commit whose staged files reference not-yet-committed
changes will fail. Commit the leaf first. If a hook fails, the files stay staged — `git reset`
before the next `git add`, or they get swept into the wrong commit.

## Architecture, in one breath

`Canonical` gives deterministic bytes, which serve turn hashing *and* prompt-cache stability —
one function, two invariants. `Turn`/`Store`/`Timeline` form a lossless content-addressed
Merkle DAG, so `fork` is O(1) and `diverge_at` localizes a cache break. `Context#render` is a
**pure** function `(Timeline, Toolset, Workspace) → Request`; purity and cache-hit are the same
constraint. Tool calls are `Effect`s interpreted by a `Handler`; `Middleware` is the Rack-idiom
public API over that, and it is a property-tested monoid. Tools are capabilities, not
permissions. `Provider` is one round trip, never a loop — Lain owns the loop, because the loop
is the object of study.

`Workspace` is **sent, not stored**: it renders into the Request and is never appended to the
Timeline. Subagents get a *fresh* Timeline root whose `meta["spawned_from"]` names the parent's
head, so causal lineage survives while the child never inherits the parent's prompt.

## Rust, and which data structures earn a binding

**Rust is here for its data model, not for speed.** Ownership, cheap immutability, and richer
structures than Ruby's `Hash`/`Array` are the reason; a benchmark is how we *check* the reason,
never the reason itself. See `ext/lain/CLAUDE.md` before writing any Rust.

The placement rule: **anything async, I/O-bound, or isolation-relevant lives out of process
(`crates/lain-core`, msgpack-RPC over a Unix socket); data-structure work lives in-process
(`ext/lain`, magnus, pure and synchronous).** Driving an async runtime from inside an FFI call
while holding the GVL is a known footgun, and an "in-process sandbox" is not a sandbox.

Before binding a structure, all five must hold. If any fails, keep it in Ruby.

1. **It is a data-structure problem**, not IO, async, or confinement.
2. **Ruby's object model makes it asymptotically worse.** A persistent map with structural
   sharing forks in O(1); `Hash#dup` is O(n). That gap is the argument. "Rust is faster" is not.
3. **It is hot per-turn**, not per-session. Per-session work is never worth a boundary.
4. **The boundary is crossed in batches, not per element.** Conversion cost dominates almost
   every naive binding; a per-node FFI call in a DAG walk loses to plain Ruby.
5. **It survives the same tests.** `Timeline` ships as pure Ruby first, and the `Regular` /
   `MeetSemilattice` property tests must pass unchanged against **both** implementations. That
   is how we know a port is correct, and it is why the Ruby version is not deleted.

Structures that plausibly qualify, and what they buy:

| Structure | Crate | Why here |
|---|---|---|
| Persistent map / vector (HAMT, RRB) | `im` / `rpds` | Structural sharing *between versions* is what will make speculative `fork` cheap without polluting the shared Store. **Latent today** — the current O(1) `fork` comes from the handle + content-addressing, not the HAMT; the binding earns rule #2 once speculative branching snapshots the map (see `ext/lain/Cargo.toml`). |
| Content-addressed hashing | `blake3` | `Canonical` bytes → digest. One hash, two invariants. |
| Insertion-ordered map | `indexmap` | Deterministic iteration is exactly `Canonical.dump`'s sorted-key stability. |
| Interned digests | `lasso` | Digests are short, repeated, and compared constantly; interning turns comparison into an integer test. |
| Roaring bitmap | `roaring` | Usage must aggregate over **unique reachable digests** — a set problem. Naive summing over a branched Timeline double-counts the shared prefix. |
| Causal DAG | `petgraph` | `meet`, `diverge_at`, and `spawned_from` lineage are graph queries. |
| In-memory BM25 | `bm25` (crate) | **Shipped** (`Lain::Ext::Bm25`): pure in-memory data-structure work, so it lives in-process — unlike `tantivy`, which is disk-backed/I/O-shaped and stays out of process. Deterministic (fxhash, no parallelism feature); equal-score ties break by build-batch insertion order. |
| Vector / graph index | `tantivy`, `usearch`, `petgraph` | Memory retrieval (M6) — these are I/O-shaped, so they live **out** of process. |

> ⚠️ **A magnus-wrapped object is not `Ractor.shareable?` for free.** Deep immutability is spec'd
> mechanically, and `Ractor.shareable?(turn)` must stay `true`. Porting `Turn` or `Timeline` to a
> Rust-backed `TypedData` object will break that spec unless shareability is established
> deliberately. Treat the spec as the acceptance test for the port, not as an obstacle to it.

## Known traps (verified, not remembered)

- Anthropic's stream accumulator is `accumulated_message`, **not** `get_final_message`. The
  stream is single-pass and `accumulated_message` mutates its snapshot.
- On the **streaming** path with raw-hash tool schemas, `tool_use.input` arrives as a raw JSON
  **String**. `Provider::Anthropic` parses it; nothing above the Provider may see it.
- The system keyword is `system_:` (trailing underscore). Content-block `.type` is a **Symbol**.
- `:model_context_window_exceeded` and `:compaction` are **Beta-only** stop reasons. The
  non-beta enum is `:end_turn :max_tokens :stop_sequence :tool_use :pause_turn :refusal`, and it
  is non-exhaustive — always have an `else`.
- Anthropic's minimum cacheable prefix is 4096 tokens. A short system prompt silently will not
  cache, with no error.
- `require "active_support/core_ext"` fails unless `require "active_support"` comes first.
- Constants and nested classes defined **inside a `Data.define(...) do ... end` block** are
  lexically scoped to the enclosing module, not the Data class. Reopen the class after the
  block instead (see `Request::SYSTEM_PREFIX`).
