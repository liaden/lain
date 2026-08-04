# Working on Lain

Lain is an agent harness built as a **study bench**. The agent is the vehicle; the bench is
the deliverable. Optimize for making context strategies, tool designs, and orchestration
tactics swappable, observable, and comparable — not for making the agent good.

The approved design plan lives at `~/.claude/plans/jiggly-greeting-avalanche.md`. Read it
before making architectural decisions. It records *why*, including several conclusions that
cost real debugging to reach.

## Toolchain

The shell's default `ruby` is the wrong one (system 3.2.3). This project needs 4.0.6:

```bash
export PATH="$HOME/.rubies/ruby-4.0.6/bin:$PATH"
export LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib   # see "OpenSSL" below
```

**4.0.6 is a floor, not a preference.** 4.0.5 crashes the VM intermittently under
`rake pspec` — [Bug #22072](https://bugs.ruby-lang.org/issues/22072), `[BUG] should have cvar
cache entry`: `rb_cvar_set` builds a new `RCLASS_CVC_TBL` without copying the old contents, so
in a multi-Ractor process a later class-variable READ finds no cache entry and aborts. Our one
`Ractor.new` (`spec/lain/rust/fuzzy_spec.rb`) is enough to arm it. It surfaces at whatever cvar
gets read first — for us `i18n/config.rb:176`, which is a victim, not the cause. Fixed in 4.0.6,
along with two more Ractor crashes (#22075, #22084).

**Why `pspec` and not `rspec`.** The suite is subprocess-bound, not CPU-bound: 44s user against
92s *system*, because the isolation, forge and workspace specs drive real `git` and the frontend
specs drive real `nvim`/`tmux`. Those are the subjects under test, so the cost is not removable --
but it parallelises. Serial 155s; `rake pspec` ~19-30s.

**`spec_workers = physical - 1` is right, and the two reasons bind under different conditions.**
Measured on a Ryzen 7 3700X (8 physical, 16 logical, 15.9G): the suite peaks at **245MB per worker,
1.32GB total** for seven. On a QUIET box that is nowhere near binding and the ceiling is CORES --
best-of-3, **n=7 18.7s, n=10 21.0s, n=14 22.2s**, monotonically worse past the core count, so
raising the count buys nothing even with RAM to spare. On a WORKING box the memory note beside
`spec_workers` earns its place: `ollama` with a model resident is +3G or so, and this machine
already carries a 4.3G `mempalace` before any of that -- so the 1.32G is competing for a headroom
that moves. `LAIN_SPEC_WORKERS` exists for exactly that; drop it when the box is loaded. And
remember what a squeeze looks like: the OOM killer takes a worker and you get "fewer examples, 0
failures", which reads like a clean run.

Single runs vary by ±50% (the runtime log redistributes files every run), so take a best-of-N
before believing any timing here.

**What actually sets the wall time is ONE FILE, and no amount of parallelism touches it.**
`parallel_tests` packs whole FILES into groups, so the longest single file is a hard floor.
`spec/lain/isolation/worktree_handback_spec.rb` runs **14.5s alone** against a ~19s wall; the
counterfactual is decisive -- move it and `worker_handoff_spec.rb` aside, and wall drops
**19.9s -> 14.1s for 1.3% of the examples**. It also explains the CPU reading: `-n 7` averages
only **541% of a possible 800%**, because at the tail six workers are finished and one is still
grinding that file. That is why n=10 and n=14 measured *slower* -- extra workers add spawn
contention early and cannot shorten the tail.

**So the lever is splitting the long files, not adding workers.** The runtime log
(`tmp/parallel_runtime_rspec.log`) ranks them: worktree_handback 17.7s, worker_handoff 12.9s,
promotion 7.7s, neovim_request 5.8s. Split the top few by concern and packing can spread them; the
floor falls to whatever is longest afterwards.

**A preloader (spring/zeus-style fork-after-load) is not the answer**, and hyperthreading does not
rescue it either. Per-worker load is only **0.73-1.26s** -- a worker loads its own SLICE, not the
whole suite -- so fork-after-load saves ~1s of a wall that is floored at 14.5s by one file. COW
would genuinely help the loaded-box case (roughly half of the 1.32G), which is a memory argument,
not a speed one. Bootsnap already takes the cheap half: **1.7s warm vs 3.6s cold** for all 465
files, ~53% off, from a 33M iseq cache under `tmp/cache`. A cold cache is the likely explanation
for any surprisingly slow boot.

Things measured that do **not** help: `TMPDIR=/dev/shm` (-8.6%; the page cache already had it),
`core.fsync=none` (nothing -- git here is spawn-bound at ~5ms/spawn, not fsync-bound), and mocking
git (the `shell_out_factory` seam exists and the heavy specs already use it for *failure
injection*; the semantics under test are git's own, so a fake would test the fake).

The failure is easy to misread: `parallel_tests` reports only the examples that SURVIVED, so a
dead worker looks like "fewer examples, 0 failures, non-zero exit" — the same shape an OOM kill
produces. Check the example COUNT against a serial run before blaming memory.

**OpenSSL.** The installed 4.0.6 was configured against Homebrew's OpenSSL (3.6) but has no
RPATH, so at runtime it resolves the system `libcrypto.so.3` (3.0.13) and dies with
`version OPENSSL_3.4.0 not found`. `LD_LIBRARY_PATH` above is the workaround. The fix is to
rebuild against the system OpenSSL, which is what the runtime linker picks anyway:

```bash
rm -rf ~/.rubies/ruby-4.0.6
ruby-install ruby 4.0.6 -- --with-openssl-dir=/usr    # then: bundle install && rake compile
```

`bundle install` and `gem` write outside the repo, so they need the sandbox disabled.
`ruby-4.0.1` is also installed and is **unusable** for native gems — its `RbConfig` points at
a deleted Homebrew `gmkdir`/`ginstall`. Both it and the OpenSSL breakage above are the same
lesson: keep Homebrew out of the Ruby build.

```bash
bundle exec rake pspec         # THE suite command: ~30s. Plain `rspec` is the same 9452 examples
                               # SERIALLY and takes ~2m35s -- 5x slower, for no extra signal.
bundle exec rspec path/to/one_spec.rb   # one file, or one example: use this, not a bare `rspec`
bundle exec rspec              # :api_integration and :core excluded by default; measure the count,
                               # do not trust a number written down here
bundle exec rubocop -a         # safe autocorrect; see the warning below
bundle exec rake compile       # builds the Rust extension into lib/lain/lain.so
cargo test && cargo clippy --all-targets -- -D warnings
pre-commit run --all-files     # what the git hook runs
```

`:api_integration` specs hit the real API and cost money. They run only with **both**:

```bash
LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
```

`:core` specs need the compiled lain-core daemon (excluded by default, like `:api_integration`):

```bash
bundle exec rake core:build && bundle exec rspec --tag core
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
  forces it to be injected. `Provider::Mock` and `Effect::Handler::Mock` exist because the specs needed
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
- **Value objects are deeply frozen.** `Ractor.shareable?(event)` must stay `true` — it is the
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

## Requires

Internal requires are centralized, never scattered. `lib/lain.rb` is the load-order manifest:
it requires each unit (a top-level file, or a directory's index) in topological dependency
order, and that one ordered list is where a circular dependency has to show itself — scattered
`require` hides cycles behind idempotent early returns. A file `foo.rb` with a sibling `foo/`
directory is that subtree's index and requires `foo/*` itself, WHERE load order dictates
(`context.rb` needs its combinators before `Context::REQUIRES` evaluates, so they load at the
top; `effect/handler.rb`'s children subclass `Effect::Handler`, so they load after the class
body). Leaf files
carry **no** internal requires at all. External gem/stdlib requires (`json`, `faraday`) stay in
the leaf files that use them — they document real dependencies.

So: never add an internal `require_relative` to a leaf file. Add the new file to its unit's
index, and a new unit to `lain.rb` where its dependencies place it (a load-time `NameError`
means the entry is too early).

## Testing

Write specs alongside the code. Three levels, and the middle one is where this codebase's real
defects have lived:

- **unit** — one subject, collaborators doubled. The default, and 97.5% of the examples.
- **`:seam`** — two or more REAL components with no double between them, driving a real local
  resource (git, an editor, the compiled extension, a live fd). Costs nothing, touches no network,
  runs by DEFAULT. `spec/lain/seams/` is for seams belonging to no single subject; a seam with an
  obvious subject stays at its mirror path and carries the tag. **239 examples — 2.5% of the suite
  — but 54s of a 155s serial run**, which is what makes `--tag '~seam'` a useful inner loop.
- **`:api_integration`** — hits the live API, costs money, opt-in. Named for what it integrates
  WITH: calling both tiers "integration" hid the distinction that actually matters, which is that
  one of them can fail because somebody else's service is down.

Specs require nothing internal: `spec/spec_helper.rb` does `require "lain"` and `.rspec` loads
it everywhere. The corollary is a commit-grouping rule — see Committing.

## Committing

Commit directly on `main`, in logical chunks, with terse high-signal messages. No trailers.

**Commit in dependency order.** Because pre-commit stashes unstaged tracked changes and runs
the full suite against the staged tree, a commit whose staged files reference not-yet-committed
changes will fail. Commit the leaf first. If a hook fails, the files stay staged — `git reset`
before the next `git add`, or they get swept into the wrong commit.

**A new lib file, its index/manifest line, and its spec land in the SAME commit.** Specs load
through `lain.rb` (see Requires), so an unstaged manifest or index edit gets stashed to `HEAD`
while untracked specs still run — the spec's constant won't resolve and the unrelated commit
fails its hook.

## Architecture, in one breath

`Canonical` gives deterministic bytes, which serve turn hashing *and* prompt-cache stability —
one function, two invariants. `Event`/`Store`/`Timeline` form a lossless content-addressed
Merkle DAG, so `fork` is O(1) and `diverge_at` localizes a cache break. **There is no `Lain::Turn`**:
it was collapsed into `Lain::Event`, kind-tagged `:turn`, with a closed
`KINDS = %i[turn spawn message snapshot]` — one primitive, one content-addressing scheme, one Store.
`spec/lain/event_spec.rb` asserts no `Turn` constant remains. `Context#render` is a
**pure** function `(Timeline, Toolset, Workspace) → Request`; purity and cache-hit are the same
constraint. Tool calls are `Effect`s interpreted by an `Effect::Handler`; `Middleware` is the
Rack-idiom public API over that, and it is a property-tested monoid. Tools are capabilities, not
permissions. `Provider` is one round trip, never a loop — Lain owns the loop, because the loop
is the object of study.

`Workspace` is **sent, not stored**: it renders into the Request and is never appended to the
Timeline. Subagents get a *fresh* Timeline root whose `meta["spawned_from"]` names the parent's
head, so causal lineage survives while the child never inherits the parent's prompt.

## Rust, and which capabilities earn a binding

**Rust is here for its data model and for capabilities Ruby has no good answer to, not for
speed.** Ownership, cheap immutability, richer structures than Ruby's `Hash`/`Array`, and mature
crates with no Ruby equivalent are the reasons; a benchmark is how we *check* the reason, never
the reason itself. See `ext/lain/CLAUDE.md` before writing any Rust, and survey lib.rs/crates.io
before hand-rolling anything a crate already does well.

The placement rule is unchanged and is the one that actually binds: **anything async, I/O-bound,
or isolation-relevant lives out of process (`crates/lain-core`, msgpack-RPC over a Unix socket);
in-process work (`ext/lain`, magnus) must be pure, synchronous, and must not own the terminal.**
Driving an async runtime from inside an FFI call while holding the GVL is a known footgun, and an
"in-process sandbox" is not a sandbox. A crate that reaches for `isatty` or `NO_COLOR` owns the
terminal and fails this test — Ruby owns the stream, so colour arrives as a resolved argument.

Before binding, all five must hold. If any fails, keep it in Ruby.

1. **It is pure, synchronous work** — a data structure, a parser, a matcher — not IO, async, or
   confinement. Data structures are the original case, not the only one.
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
> mechanically, and `Ractor.shareable?(event)` must stay `true`. Porting `Event` or `Timeline` to a
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
- **A reopened class gets exactly ONE docstring, and it goes on the REOPEN.** The
  `Data.define` assignment above it stays bare. YARD keeps one docstring per namespace and
  **silently discards the rest**, so documenting both loses content with no warning at write
  time; `yard-lint`'s `Documentation/DuplicateNamespaceComment` is what catches it, at commit.
  RuboCop's `Style/Documentation` pulls the other way but does not conflict in practice: it
  fires on the `class` keyword, which the reopen satisfies, and never on the assignment. Two
  shapes both pass, so pick by whether the reopen carries behavior:

  ```ruby
  Anchor = Data.define(:path, :side) do   # bare: no comment above this line
    include Telemetry::Journalable
  end

  # One reviewable position: ... <- the docstring lives HERE
  class Anchor
    SIDES = Review::SIDES.map(&:to_sym).freeze
  end
  ```

  A reopen holding *only* a constant (`JOURNAL_TYPE` and nothing else) is a pure namespace, and
  `Style/Documentation` does not fire on it, so that shape may instead keep its docstring above
  the `Data.define` — but then any explanation of the reopen goes **inside** the class body,
  never above the `class` keyword, or it becomes the second docstring again.
  `lib/lain/review/records.rb` is the pure-namespace case, `lib/lain/review/anchor.rb` and
  `lib/lain/review/hunk.rb` the behavior-carrying one; both shapes are clean under
  `rubocop --only Style/Documentation` and under `yard-lint`, which is the pair to check when
  in doubt.
- **YARD reads `@word` at the start of a comment line as a tag**, so a prose reference to a
  keyword argument wraps into `Warnings/UnknownTag` and fails the commit. Write it inline
  (`the `compose:` note on {Neovim#initialize}`), not as the first token of a wrapped line.
- **Never name a `.toml` explicitly on a `rubocop` command line.** `rubocop -a lib/lain/prompt/default.toml`
  parses it as Ruby and "corrects" it — it silently stripped `format = ` from the prompt format.
  A bare `bundle exec rubocop` (and so `pre-commit run --all-files`) is safe: the default
  `Include` patterns do not match `.toml`. **An `Exclude` entry does not save you** — verified:
  `AllCops: Exclude` governs RuboCop's own file *discovery*, not a path a human hands it
  directly, so the file is still parsed when named. The only defence is not naming it.
