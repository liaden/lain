# Structural code search — ast-grep + tree-sitter tools

status: done
commit-mode: orchestrator-commits
language: ruby + rust
panel: Andrew Gallant, Raph Levien (Rust) · Sandi Metz, Jeremy Evans, Aaron Patterson (Ruby)

## Intent

Add the **structural** retrieval modality to lain's tool floor: an ast-grep-backed code-search tool
that matches by AST shape (not text), shipped as a search + inspect **pair** so the model can
self-correct patterns, plus a tree-sitter "default queries" tool for file outline and a local
symbol table. Seeds the pattern library from Joel's `~/.zsh/ag_helpers` catalog. This satisfies
M6's outstanding *"one Rust-implemented `Tool`"* `[planned]` item (ROADMAP.md:357) and delivers the
**structural** arm listed on the memory/retrieval axis (ROADMAP.md:50) and the deferred/searchable
arm of the **Tool-disclosure** axis (ROADMAP.md:48). Grounded in the spike on branch
`spike/ast-structural-search` and `references/ast-structural-search.md`.

## Grounding

Code state verified 2026-07-18 by three parallel Explore passes; spike verified the Rust library on
the same date.

- **Tool seam** (`lib/lain/tool.rb`, `lib/lain/tool/input.rb`, `lib/lain/tools/grep.rb`,
  `lib/lain/tools/read_file.rb`): a concrete tool subclasses `Lain::Tool`, declares a nested
  `Input < Tool::Input` with `field`s + `input_model Input`, and implements `#name`, `#description`,
  protected `#perform(input, invocation) -> Tool::Result.ok/error`. A tool **never** writes an
  `Effect` and never touches `Effect::Handler`/`Toolset` — `Effect::Handler::Live#dispatch`
  (`lib/lain/effect/handler/live.rb:67-79`) looks tools up by name in the injected toolset and
  converts any raise to `Result.error`. Read-only tools leave `requires_approval?` at its `false`
  default (ungated). `grep.rb` is the recursive-walk template (`Dir.glob` + `FNM_DOTMATCH`, skips
  `.git`, lazy cap at `MAX_MATCHES`, `file:line:text` output); `read_file.rb` the single-file one.
  Output discipline: return content via `Tool::Result`, never `$stdout` (AST-scanned by
  `spec/output_discipline_spec.rb`).
- **Registration is explicit, no global registry:** (1) `require_relative` in the unit index
  `lib/lain/tools.rb:12-26`; (2) `Lain::Tools::X.new` in `base_tools` at `exe/lain:392-398`
  (wrapped by `Wiring#build_toolset` at `:354-358`); (3) optional `only`-set lines in
  `lib/lain/role/catalog.rb`. All orchestrator-owned.
- **ext/lain binding** (`ext/lain/src/bm25.rs` + `ext/lain/src/lib.rs:1411-1524`): the house pattern
  is a **pure layer** (no magnus types, `#[cfg(test)]` unit tests, `thiserror` enum whose `Display`
  is the FFI message) plus a `#[cfg(not(test))] mod ffi` wrapper. Registration is one class block in
  `init` (`lib.rs:1520-1524`): `ext.define_class`, `define_error("…", lain_error)`,
  `define_singleton_method(function!(…))` / `define_method(method!(…))`. `Lain::Error` is fetched
  once with **no fallback** (`lib.rs:1515-1518`) — every `define_error` must pass `lain_error`.
  Crate-root `#![deny(clippy::print_stdout, clippy::print_stderr)]`. Gates: `cargo test`, `cargo
  clippy --all-targets -D warnings`, `cargo fmt --check`, `cargo deny check` (no wildcards — pin
  exact), `bundle exec rake compile`. Rust specs live in `spec/lain/rust/*_spec.rb` and mirror the
  pure-layer unit tests one-for-one; `spec/support/matchers/be_deeply_frozen.rb` exists.
- **Shareability nuance** (`ext/lain/CLAUDE.md`, `bm25.rs:11-31,87-98`): `frozen_shareable` is an
  *unchecked* promise — honored only via freeze-on-wrap + an interior-mutability audit + an
  `assert_sync` canary. **This plan's matcher is stateless** (parse per call, return an owned array),
  so it needs no `TypedData` wrapper and makes no shareability claim beyond freezing its return
  value — sidestepping the audit. If a stateful design is later wanted (cached grammars), the bm25
  recipe applies.
- **Spike facts carried in** (`references/ast-structural-search.md`, branch
  `spike/ast-structural-search`): `ast-grep-core = "=0.44.1"` matches an in-memory `&str` with no
  filesystem access, returns captures + byte ranges; `ast-grep-language` bundles ~26 tree-sitter
  grammars and exposes each `tree_sitter::Language` (reusable by a raw tree-sitter query pass — no
  second grammar dep). All MIT. Measured gotcha: `def $NAME(...)` silently matches methods but **not**
  singleton methods (`def self.x`) — a different CST node; hence the inspect half of the pair. `ag`'s
  `ragfnc` false-positives in comments/on `end` and misses paren'd calls that ast-grep catches.
- **Manifest/units** (`lib/lain.rb`, `lib/lain/tools.rb`): internal requires live only in `lain.rb`
  and unit indexes; leaf files carry none. The ext loads via one bare `require "lain/lain"`
  (`lib/lain.rb:57`); `Lain::Ext::*` is referenced **at call time** (as in `memory/bm25.rb:40`),
  never as a load-time constant, so a new `structural` unit can load before the tools unit despite
  the ext loading last. A new lib file + its index line + its spec must land in **one commit**,
  leaf-first (`CLAUDE.md:134-142`).

Docs vs code: none in conflict — ROADMAP already lists "structural" as an anticipated arm; this plan
realizes it. The spike updated the "rust-analyzer too old" finding (now 1.97.0) but the graph layer
is out of scope here.

## Orchestrator contract (plan-specific only)

Shared files (orchestrator-owned; cards touch these as one-line **wiring diffs**, never as scope):

- `ext/lain/Cargo.toml` — new dependency blocks (house-comment + exact-pin), from T1/T6.
- `deny.toml` — license allowances if `cargo deny` flags any new crate/grammar.
- `lib/lain.rb` — one manifest line for the new `structural` unit. Because the unit references
  `Lain::Ext::*` only at call time (never as a load-time constant, per `memory/bm25.rb:40`), its
  placement is free of the ext's load position; sit it among the tool-adjacent units.
- `lib/lain/structural.rb` — the new unit **index**, created and owned by the orchestrator; each
  card contributes a `require_relative "structural/<child>"` line as a wiring diff.
- `lib/lain/tools.rb` — index lines for new tools.
- `exe/lain` — `base_tools` list (`:392-398`); new `Lain::Tools::*.new` entries.
- `lib/lain/role/catalog.rb` — `only`-set additions. The exact existing roles are `dev`,
  `test_engineer`, `researcher`, `reviewer_sre`, `reviewer_security`, `reviewer_dba`, `court_clerk`
  (there is **no** bare `reviewer`). These four read-only tools belong in `dev`, `test_engineer`,
  `researcher`, and the three `reviewer_*` roles.
- `lain.gemspec` — **no glob change needed**: the gemspec packages via `git ls-files` (`:34-38`) and
  does not reject `lib/`, so any committed `lib/lain/structural/queries/**/*.scm` ships automatically.
  The only requirement is that T8 `git add`s the vendored `.scm` files.

Deviations from default process: none.

## Open decisions

None gating any card. (The grammar-trim question — depend on `ast-grep-language`'s full 26-grammar
set vs. the four `tree-sitter-*` crates directly — is resolved *within* T1 with a default and a
follow-up ticket, not left open.)

## Waves

- **Wave 1** (no unmet deps): T1, T2
- **Wave 2**: T3 (←T1), T6 (←T1, shared-file serialization on `lib.rs`/`Cargo.toml`)
- **Wave 3**: T4 (←T2, T3), T5 (←T1, T3), T7 (←T2, T3), T8 (←T6)

Critical path: **T1 → T3 → T4** (the core search deliverable). Equal-length Rust chain: T1 → T6 → T8.

## Tasks

### T1 — ast-grep matcher binding in `ext/lain`          [wave 1] [risk: high]

**Depends on:** none
**Files:** create `ext/lain/src/astgrep.rs`; modify `ext/lain/src/lib.rs` (add `mod astgrep;`, the
`#[cfg(not(test))]` FFI wrapper, and the `init` class block); create `spec/lain/rust/astgrep_spec.rb`
**Reuse:** `ext/lain/src/bm25.rs` pure+FFI split verbatim as the template; `lookup_error` helper
(`lib.rs:1397-1468`); the `thiserror` enum→Display→FFI-message pattern; spike crate
`spike/astgrep-probe/src/main.rs` on branch `spike/ast-structural-search` for the exact
`ast_grep_core` API (`AstGrep::new(src, lang)` → `.root().find_all(pattern)` → `m.get_env().
get_match("NAME")` + `node.range()`).
**Shared-file wiring:** `ext/lain/Cargo.toml` dep block (orchestrator); `deny.toml` allowances if
`cargo deny` flags a grammar (orchestrator).

**Acceptance criteria:**

```gherkin
Scenario: a metavariable pattern matches in-memory source and returns captures + ranges
  Given the Ruby source "def total(x)\n  x\nend"
  When Lain::Ext::AstGrep.search(source, "ruby", "def $NAME($$$A)") is called
  Then it returns one match whose NAME capture is "total" with byte-range start/end (offsets only —
       byte→line/column conversion is the wrapper's job in T3, not the ext's)

Scenario: structural matching ignores comments and strings
  Given Ruby source where "save" appears in a comment and in a string literal, plus one real "record.save"
  When AstGrep.search(source, "ruby", "$RECV.save") is called
  Then only the real call site is returned (no comment/string matches)

Scenario: an unparseable pattern is a distinct, typed error — not zero matches
  When AstGrep.search(source, "ruby", "def (") is called with a malformed pattern
  Then it raises Lain::Ext::AstGrep::BadPattern (a subclass of Lain::Error)
  And a valid pattern with no matches returns an empty array instead

Scenario: dump exposes the CST for pattern debugging
  When Lain::Ext::AstGrep.dump("def self.x; end", "ruby") is called
  Then the returned tree text contains a "singleton_method" node

Scenario: the returned match collection is deeply frozen
  When AstGrep.search returns any result
  Then the result array is deeply frozen (be_deeply_frozen)
```
→ spec file: `spec/lain/rust/astgrep_spec.rb` (plus a `#[cfg(test)] mod tests` in `astgrep.rs`
mirroring these, run by `cargo test` with no Ruby VM)

**Escalation triggers:**
- If `ast_grep_core` 0.44.1's public API cannot build a pattern and iterate named captures over an
  in-memory `&str` **without** filesystem access — contradicting the spike — stop; the placement
  assumption (matcher in `ext/lain`) is void.
- If any reachable `ast_grep_core` type forces a stateful/`TypedData` wrapper AND holds interior
  mutability (`Cell`/`RefCell`/`OnceCell`), the `frozen_shareable` audit fails — stop and confirm
  the non-shareable fallback before proceeding.
- If `cargo deny` flags a bundled grammar's license against `deny.toml`, or the `.so` fails to link
  the grammars, stop — the grammar-set decision (below) escalates to the orchestrator.
- Grammar-set default: depend on `ast-grep-language` (spike-proven to compile, all ~26 grammars). Do
  **not** hand-trim to four grammars in this card; file it as the follow-up ticket. If the
  26-grammar compile-time/`.so`-size cost trips a gate, stop and escalate.
- Golden lock: the exact-pin (`= 0.44.1`) plus the search/dump specs mirrored in `cargo test` **are**
  the lock on `ast_grep_core`'s explicitly-unstable Rust surface (spike liability #1). Any future
  version bump must re-green them deliberately, behind the one adapter module — never silently.

### T2 — pattern catalog seeded from `ag_helpers`          [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/structural/patterns.rb`; create `spec/lain/structural/patterns_spec.rb`
**Reuse:** the query taxonomy in `references/ast-structural-search.md` (§ "Bonus: existing helpers")
and `~/.zsh/ag_helpers` — map each helper to ast-grep pattern template(s). Pure data + a lookup
method; no ext dependency, no I/O.
**Shared-file wiring:** orchestrator creates the `structural` unit index `lib/lain/structural.rb`
(with `require_relative "structural/patterns"`) and adds the unit's manifest line to `lib/lain.rb`.

**Acceptance criteria:**

```gherkin
Scenario: a named query resolves to concrete ast-grep patterns, including the singleton case
  When Patterns.fetch(:ruby, :method_def, name: "save") is called
  Then it returns both "def save($$$A)" and "def self.save($$$A)"

Scenario: the call-finder query yields receiver and receiverless forms
  When Patterns.fetch(:ruby, :method_call, name: "save") is called
  Then it returns a receiver form ("$RECV.save") and a bare-identifier form ("save")

Scenario: the catalog covers the mapped ag_helpers
  Then :method_def, :class_def, :subclass_of, :mixin, :instance_var, and :method_call are all defined for :ruby

Scenario: an unknown query name fails loudly
  When Patterns.fetch(:ruby, :nonsense) is called
  Then it raises a Lain error naming the unknown query (not returns nil)
```
→ spec file: `spec/lain/structural/patterns_spec.rb`

**Escalation triggers:**
- If a helper's intent cannot be expressed as an ast-grep pattern (only as a raw tree-sitter query),
  do **not** stretch the catalog — record it as belonging to the tree-sitter tool (T8) and note it.
- If reconciling the six helpers reveals two queries that differ only by a substring filter, unify
  them behind one query name with an argument rather than duplicating entries.

### T3 — matcher wrapper (Ruby domain object over the ext)          [wave 2] [risk: medium]

**Depends on:** T1
**Files:** create `lib/lain/structural/matcher.rb`; create `spec/lain/structural/matcher_spec.rb`
**Reuse:** `lib/lain/memory/bm25.rb` as the "Ruby wrapper over a raw `Lain::Ext::*` class" exemplar
(reference the ext at call time, freeze self). Return domain `Match` value objects
(`Data.define(:line, :byte_range, :captures)` or similar). **This wrapper is the single seam over the
unstable ext** — it owns BOTH `#match` (over `Ext::AstGrep.search`) and `#dump` (over
`Ext::AstGrep.dump`), and it is where byte→line/column conversion lives (the ext returns byte offsets
only). No other unit calls `Lain::Ext::AstGrep` directly, so a breaking ext bump touches this file
alone.
**Shared-file wiring:** `require_relative "structural/matcher"` in `lib/lain/structural.rb`
(orchestrator).

**Acceptance criteria:**

```gherkin
Scenario: the wrapper matches a pattern and returns domain Match objects with computed line numbers
  Given a source string and language and the pattern "def $NAME($$$A)"
  When Matcher.new.match(source:, language: :ruby, pattern:) is called
  Then it returns Match objects exposing line (computed from the ext's byte offset), byte_range,
       and a captures hash (NAME => "…")

Scenario: the wrapper exposes the CST via dump, insulating callers from the ext
  When Matcher.new.dump(source: "def self.x; end", language: :ruby) is called
  Then it returns the CST text (delegating to Ext::AstGrep.dump), and no caller references the ext directly

Scenario: a malformed pattern raises one typed Lain error (loud failure, not an error value)
  When match is called with an unparseable pattern
  Then it raises a typed Lain error, and Lain::Ext::AstGrep::BadPattern does not escape uncaught

Scenario: an unknown language is rejected before reaching the ext
  When match is called with language: :cobol
  Then it raises a Lain error naming the unsupported language
```
→ spec file: `spec/lain/structural/matcher_spec.rb`

**Escalation triggers:**
- Byte→line/column conversion lives **here** (the wrapper owns presentation); if a spec tries to push
  it into the ext (T1) and re-open T1's byte-offset-only contract, stop.
- If `Match` needs to carry the matched source text and that means re-reading the file, stop — the
  tool (T4), which already holds the file contents, should attach text, not the matcher.

### T4 — `ast_search` tool          [wave 3] [risk: medium]

**Depends on:** T2, T3
**Files:** create `lib/lain/tools/ast_search.rb`; create `spec/lain/tools/ast_search_spec.rb`
**Reuse:** `lib/lain/tools/grep.rb` for the recursive walk (`Dir.glob` + `FNM_DOTMATCH`, `.git`
skip, `MAX_MATCHES` lazy cap, `file:line:text` formatting); `Tool`/`Tool::Input` shape from
`read_file.rb`; `Structural::Matcher` (T3) and `Structural::Patterns` (T2). The directory walk stays
in **Ruby** deliberately — a synchronous `Dir.glob` is neither async nor isolation-relevant, so the
`ext/lain`/`lain-core` placement rule keeps it in Ruby (exactly as `grep.rb` does); only the pure
match crosses into the ext.
**Shared-file wiring:** index line in `lib/lain/tools.rb`; `Lain::Tools::AstSearch.new` in
`exe/lain` `base_tools`; `ast_search` added to the `dev`, `test_engineer`, `researcher`, and
`reviewer_*` `only`-sets in `lib/lain/role/catalog.rb` (all orchestrator diffs).

**Acceptance criteria:**

```gherkin
Scenario: searching a directory returns structural matches with file:line locations
  Given foo.rb defines "def total(items)" on line 3
  When ast_search(pattern: "def $NAME($$$A)", language: "ruby", path: ".") is called
  Then the result includes foo.rb:3 and the captured NAME

Scenario: a named query from the catalog is accepted in place of a raw pattern
  When ast_search(query: "method_call", name: "save", language: "ruby", path: ".") is called
  Then it finds receiver and receiverless call sites of save and excludes comments/strings

Scenario: an invalid pattern is an error Result, distinct from a valid pattern with no matches
  When ast_search is called with a malformed pattern
  Then it returns Tool::Result.error naming the bad pattern
  And a valid pattern that matches nothing returns Tool::Result.ok with an explicit "no matches" body

Scenario: results are capped and the cap is disclosed
  Given more matches than the cap
  Then the result states the output was truncated (no silent cap)
```
→ spec file: `spec/lain/tools/ast_search_spec.rb`

**Escalation triggers:**
- If a tool spec wants to shell out to the `ast-grep`/`sg` binary instead of calling
  `Structural::Matcher`, stop — that reintroduces a subprocess + runtime binary dependency the
  design explicitly rejects (spike verdict).
- If `read_file`/`grep` already record reads on the session and `ast_search` should too, mirror
  `read_file.rb`'s `session_of(invocation).record_read` — but confirm the read-set contract applies
  to a search tool before adding it (it may not; escalate if unsure rather than guess).

### T5 — `ast_inspect` tool (the reliability half of the pair)          [wave 3] [risk: medium]

**Depends on:** T3
**Files:** create `lib/lain/tools/ast_inspect.rb`; create `spec/lain/tools/ast_inspect_spec.rb`
**Reuse:** `Structural::Matcher` (T3) for **both** halves — `Matcher#dump` for the CST view and
`Matcher#match` for the match-count in `test_pattern`. The tool must **not** call `Lain::Ext::AstGrep`
directly (T3 is the only seam over the unstable ext). `Tool`/`Tool::Input` shape from `read_file.rb`.
**Shared-file wiring:** index line in `lib/lain/tools.rb`; `Lain::Tools::AstInspect.new` in
`exe/lain` `base_tools`; `only`-set lines in `lib/lain/role/catalog.rb` (orchestrator).

**Acceptance criteria:**

```gherkin
Scenario: dump shows the CST so the model can see the real node kinds
  When ast_inspect(mode: "dump", code: "def self.x; end", language: "ruby") is called
  Then the result contains a readable tree naming "singleton_method"

Scenario: test_pattern reports whether a pattern matches given code, catching silent under-match
  Given code with one method and one singleton method
  When ast_inspect(mode: "test", pattern: "def $NAME($$$A)", code:, language: "ruby") is called
  Then the result reports 1 match and makes clear the singleton method was not matched
```
→ spec file: `spec/lain/tools/ast_inspect_spec.rb`

**Escalation triggers:**
- Default toward **two** tools (`ast_dump` + `test_pattern`) — that is the spike's recommendation and
  avoids the two-responsibility smell of one tool switching on a `mode` field. Ship the single
  `mode`-field tool only if the orchestrator explicitly prefers it; if in doubt, split (and this card
  then produces two leaf files + two specs, wired identically).

### T7 — `code_outline` tool (structure via ast-grep)          [wave 3] [risk: low]

**Depends on:** T2, T3
**Files:** create `lib/lain/tools/code_outline.rb`; create `spec/lain/tools/code_outline_spec.rb`
**Reuse:** `Structural::Patterns` (`:class_def`, `:module_def`, `:method_def`) + `Structural::Matcher`
— outline is a fixed set of catalog queries over one file, **not** a new mechanism.
**Shared-file wiring:** index line in `lib/lain/tools.rb`; `Lain::Tools::CodeOutline.new` in
`exe/lain` `base_tools`; `only`-set lines in `lib/lain/role/catalog.rb` (orchestrator).

**Acceptance criteria:**

```gherkin
Scenario: outline lists a file's classes/modules/methods with line numbers, nested by position
  Given a Ruby file with a module, a class inside it, and two methods
  When code_outline(path: "foo.rb", language: "ruby") is called
  Then the result lists the module, the class, and both methods with their line numbers
  And it does not report identifiers appearing in comments or strings
```
→ spec file: `spec/lain/tools/code_outline_spec.rb`

**Escalation triggers:**
- If nesting (class-within-module) cannot be reconstructed from flat ast-grep matches without a real
  scope walk, stop — that is the tree-sitter `locals` path (T8), not this card; ship a flat,
  line-ordered outline and record the nesting limitation rather than reaching for T8's binding.

### T6 — tree-sitter query binding in `ext/lain`          [wave 2] [risk: high]

**Depends on:** T1 — a **real** dependency, two ways: (a) T6 obtains each `tree_sitter::Language` from
the `ast-grep-language` crate that T1 adds to `Cargo.toml`, and (b) both cards edit
`ext/lain/src/lib.rs`, so they must not share a wave. Do not "parallelize because it's only a shared
file" — T6 needs T1's dependency to exist.
**Files:** create `ext/lain/src/treesitter.rs`; modify `ext/lain/src/lib.rs` (mod + FFI wrapper +
`init` class block); create `spec/lain/rust/treesitter_spec.rb`
**Reuse:** the grammars already linked by `ast-grep-language` (T1) — obtain each
`tree_sitter::Language` from it rather than adding new grammar deps; add only the `tree-sitter`
runtime crate (the query engine). Model the pure+FFI split on `bm25.rs` again.
**Shared-file wiring:** `ext/lain/Cargo.toml` — add the `tree-sitter` runtime dep (orchestrator);
`deny.toml` if flagged.

**Acceptance criteria:**

```gherkin
Scenario: a raw tree-sitter query runs against in-memory source and returns named captures with ranges
  Given Ruby source with a method definition
  When Lain::Ext::TreeSitter.query(source, "ruby", "(method name: (identifier) @name)") is called
  Then it returns a capture named "name" with the method's identifier text and byte range

Scenario: a malformed query is a distinct typed error
  When TreeSitter.query is called with an invalid S-expression
  Then it raises Lain::Ext::TreeSitter::BadQuery (a subclass of Lain::Error)

Scenario: the returned captures are deeply frozen
  Then the returned collection is be_deeply_frozen
```
→ spec file: `spec/lain/rust/treesitter_spec.rb` (+ `#[cfg(test)] mod tests` in `treesitter.rs`)

**Escalation triggers:**
- If `ast-grep-language` does not expose the underlying `tree_sitter::Language` for reuse, stop
  before adding a parallel set of `tree-sitter-*` grammar deps — that doubles the grammar tax and
  changes the dependency story; escalate.
- If the installed `tree-sitter` runtime version is ABI-incompatible with the grammar versions
  `ast-grep-language` pins, stop — a grammar/runtime ABI mismatch is the known breakage; escalate
  rather than force-bump.

### T8 — `file_symbols` tool (local symbol table via `locals.scm`)          [wave 3] [risk: medium]

**Depends on:** T6
**Files:** create `lib/lain/structural/queries.rb` (the `.scm` loader); vendor query files under
`lib/lain/structural/queries/<lang>/locals.scm` for ruby/rust/typescript/python; create
`lib/lain/tools/file_symbols.rb`; create `spec/lain/structural/queries_spec.rb` and
`spec/lain/tools/file_symbols_spec.rb`
**Reuse:** `Lain::Ext::TreeSitter.query` (T6); nvim-treesitter's `locals.scm` files (Apache-2.0) as
the vendored queries — verified working in the spike (branch `spike/ast-structural-search`,
`ts_query.lua`). Each vendored file carries a provenance header (source repo + Apache-2.0).
**Shared-file wiring:** `require_relative "structural/queries"` in `lib/lain/structural.rb`; index
line in `lib/lain/tools.rb`; `Lain::Tools::FileSymbols.new` in `exe/lain` `base_tools`; `only`-set
lines in `lib/lain/role/catalog.rb` (`dev`, `test_engineer`, `researcher`, `reviewer_*`). The vendored
`.scm` files ship via `git ls-files` once committed — no `lain.gemspec` change (all orchestrator diffs).

**Acceptance criteria:**

```gherkin
Scenario: file_symbols returns definitions and references with roles from a locals query
  Given a Ruby file defining a module, a class, and a method that references a local variable
  When file_symbols(path: "foo.rb", language: "ruby") is called
  Then the result lists the definition of the module/class/method with roles (definition.namespace/type/function)
  And it lists the reference occurrences of the local variable

Scenario: vendored query files declare their provenance and license
  Then each lib/lain/structural/queries/<lang>/locals.scm begins with a header naming nvim-treesitter and Apache-2.0
```
→ spec files: `spec/lain/structural/queries_spec.rb`, `spec/lain/tools/file_symbols_spec.rb`

**Escalation triggers:**
- If a vendored `locals.scm` uses grammar node names that differ from the grammar version
  `ast-grep-language` pins (a query that fails to compile against our grammar), stop — do not silently
  drop captures; escalate so the query is pinned to a matching grammar or trimmed.
- If bundling Apache-2.0 query files into an MIT gem needs a `NOTICE`/attribution the gemspec doesn't
  carry, stop and hand the licensing wiring to the orchestrator rather than committing unattributed
  third-party files.

## Integration checks

Run after the last wave; name each so nothing silently drops:

- **Rust:** `cargo test` (pure-layer unit tests for both bindings green, no regression), `cargo
  clippy --all-targets -- -D warnings`, `cargo fmt -- --check`, `cargo deny check` (both new dep
  blocks pinned exact, licenses clear), `bundle exec rake compile` builds `lib/lain/lain.so`.
- **Ruby:** full `bundle exec rspec` (default excludes `:integration`), including
  `spec/output_discipline_spec.rb` (no tool touches `$stdout`) and the new `spec/lain/rust/*` +
  `spec/lain/structural/*` + `spec/lain/tools/*` specs; `bundle exec rubocop` clean at default
  metrics; `spec/lain/rust/astgrep_spec.rb` and `treesitter_spec.rb` assert `be_deeply_frozen`.
- **Registration smoke:** the four new tools appear in `exe/lain`'s built toolset and in the intended
  role `only`-sets; `Toolset#to_schema` still sorts deterministically (no `DuplicateTool`).
- **Manual end-to-end (human pass):** drive `ast_search` over lain's own `lib/` with a call-finding
  query (e.g. `method_call name: commit`) and confirm it is precise where the spike's `ag ragfnc`
  baseline was not (no comment/string false positives; catches paren'd + multi-line calls). Confirm
  `ast_inspect test_pattern` reports the singleton-method under-match. This is the spike's headline
  result, re-verified against the shipped tool — owed to the human, not automatable here.
- **Follow-up ticket (not this chunk):** evaluate trimming the ext from `ast-grep-language`'s ~26
  grammars to the four `tree-sitter-*` targets, measuring `.so` size + compile-time delta against the
  spike's baseline (clean build 9.63 s / 70 crates).

## Shipped — 2026-07-18

Executed via `/execute-plan` on `main` (the spike branch `spike/ast-structural-search` was kept as
throwaway reference and **not** merged; the full design rationale, the probes, and
`references/ast-structural-search.md` live there). All 8 cards landed; the full suite is green
(2773 examples, 0 failures) and both high-risk Rust FFI cards passed an adversarial-panel review.

| Card | What landed | Commit |
|---|---|---|
| T2 | `Structural::Patterns` catalog | `720d32d` |
| T1 | `Ext::AstGrep` matcher binding | `9314f6d` |
| T3 | `Structural::Matcher` (the single seam over the ext) | `f1b6e00` |
| T5 | `ast_dump` + `test_pattern` (the inspect pair — **split into two tools**) | `cb64a84` |
| T6 | `Ext::TreeSitter` raw-query binding | `728f629` |
| T4 | `ast_search` tool | `1b37c10` |
| T7 | `code_outline` tool | `7ad0995` |
| T8 | `file_symbols` tool + hand-authored role queries | `e727fbb` |

Panel catches (each a silent-`[]`-on-a-typo defect — the exact failure the search+inspect pair
exists to prevent): T1's `has_error()` missed top-level-ERROR patterns (`)`, `def`, `class`); T6's
`query` returned `[]` for a capture-less query. Both fixed with a guard + red-green specs before
landing. Manual end-to-end re-verified against lain's own `lib/` (`ast_search method_call name:
commit` — 11 real hits, zero comment/string false positives; `test_pattern` shows the
singleton-method under-match; `file_symbols` role tables for ruby + rust).

### Deliberately deferred (decided with the owner during execution)

- **Role-catalog wiring.** The plan's `lib/lain/role/catalog.rb` only-set additions (the 5 tools into
  `dev`/`test_engineer`/`researcher`/`reviewer_{sre,security,dba}`) are **not** applied. Adding them
  breaks 17 specs coupled to exact role tool-sets **and byte-identical prompt-cache tool blocks**
  (`role_spec`, `role_spawn_spec`, `role_prelude_wiring_spec`, `skill_dispatch_spec`, `backend_spec`,
  `subagent_spec`). The 5 tools ship in `exe/lain` `base_tools` (the main agent has them); attenuated
  role access is a **follow-up** that must regenerate those prompt-cache expectations deliberately,
  not blind-edit them.
- **Python `file_symbols`.** T8 ships hand-authored MIT role queries for **ruby / typescript / rust**
  only; `file_symbols(language: "python")` fails loudly. Python was the owner's lowest priority — a
  follow-up authors its `queries/python/symbols.scm` the same TDD way.

### Follow-up tickets (not this chunk)

- **`method_call` catalog over-reports.** The `:method_call` query runs a receiver form (`$RECV.x`)
  AND a bare form (`x`), so a receiver call is reported twice and the bare form also matches the
  method's own `def x` name. Precise (no false positives) but redundant — add a dedup / smarter merge.
- **Paren-less `def` misses.** `:method_def`'s `"def $NAME($$$A)"` only matches parenthesized defs;
  `def foo` (no parens) is missed. `ag`'s `ragfn` matched both — restore parity with a paren-less
  template.
- **Grammar trim.** Evaluate trimming `ast-grep-language`'s ~26 grammars to the four targets
  (`.so` size + compile-time delta).
- **Pre-existing flaky spec.** `spec/lain/tools/subagent_concurrency_spec.rb:113` intermittently fails
  under the parallel commit hook (passes in isolation); unrelated to this chunk.
