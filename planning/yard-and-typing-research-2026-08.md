# YARD adoption and static typing: preliminary research

> ⚠️ LLM-generated research. Measurements are reproducible (commands given inline); the
> judgements are mine and want your review. 2026-08-04, against `main` @ `8cb1e8d`.

## The questions

1. How much of our Ruby comment mass would benefit from being replaced with YARD doc comments?
2. How much would we benefit from Sorbet or RBS typing? Can we reduce test count/overhead by
   adopting it? Default preference is to avoid Sorbet unless it is significantly beneficial.
3. (Added mid-research) Should we adopt `yard-rubocop`/`yard-lint`/`yard-rspec` to enforce
   proper YARD usage?

## Bottom line

1. **The premise is inverted — YARD is already adopted.** `yard` is in the `Gemfile`, 309 of
   541 `lib/` files carry tags, and `yard stats` reports **79.80% documented**. There is no
   migration to do. What is missing is *tooling and enforcement*, not comments.
2. **Neither Sorbet nor RBS would let us delete a meaningful number of tests.** Best estimate:
   **1–2% under Sorbet, under 1% under RBS/Steep**. Recommend abstaining from both. Your default
   preference holds, and it holds for RBS too.
3. **Yes to enforcement, but a specific one: `rubocop-yard`.** It found 72 offenses, 54
   autocorrectable, and plugs into the existing RuboCop/pre-commit setup with no new
   infrastructure. `yard-lint` is worth a one-off run for a defect it alone catches. `yard-rspec`
   is not relevant to this goal.

---

## Q1 — YARD

### It is already here

```
gem "yard", "~> 0.9"   # our doc comments are already YARD-shaped (@param, @return)
```

That `Gemfile` comment is accurate. Measured:

| Metric | Value |
|---|---|
| `lib/` files with ≥1 YARD tag | **309 / 541 (57%)** |
| `@param` / `@return` / `@raise` | 1,194 / 610 / 163 |
| `@yieldparam` / `@yieldreturn` / `@yield` | 9 / 6 / 3 |
| `yard stats` overall | **79.80% documented** |
| Undocumented methods | 802 of 3,227 |
| Undocumented constants | 300 of 785 |
| Attributes undocumented | **0 of 550** |

```bash
bundle exec yard stats --list-undoc lib
```

### The comment mass is larger than CLAUDE.md claims

`lib/` is **39,704 comment lines against 32,164 code lines — 55% comment, 1.23 lines of comment
per line of code.** Per-file, of 497 files over 30 lines: 244 sit at 40–60% comment, 161 at
60–80%, 6 above 80% (`core/transport.rb` 86%, `skill/library.rb` 84%, `bench/spawn_seam.rb` and
`compaction/boundary.rb` 82%).

CLAUDE.md says "Comments are minimal, and explain WHY." The second half is true and the first
half is not. **This is worth a decision independent of YARD** — either the codebase is
over-commented, or the rule as written no longer describes the house style and should be
rewritten to match what we actually do. I'd flag it rather than resolve it; the comments I
sampled are mostly good (measured allocation counts in `canonical.rb:65-93`, the
`stream_assembler.rb:8-22` note on why Anthropic content blocks stay keyed by index), and the
volume may simply be what a study bench should look like.

### What would actually benefit from conversion

Very little, and this is the important negative result. The comment population breaks down as:

- **~60–70% rationale/WHY** — invariants, cop false positives, wire-format quirks, measured
  performance shapes. YARD has no tag for these and they should stay as prose. Converting them
  would destroy the thing that makes them valuable.
- **~300–400 blocks purely descriptive** — the real conversion candidates. Best examples are
  `Session::Null` (`session.rb:283-356`) and `Session::Journaled` (`399-465`), which already
  carry bare `@return` tags and no prose, and `promise.rb:30-46`.
- **~1.5% organizational** — 541 `frozen_string_literal` lines, 38 rubocop directives, and
  exactly **one** TODO in the whole tree (`oracle/recorded.rb:118`). No section-banner comments
  at all.

So the answer to Q1 as asked is: **almost none.** The comments that aren't already YARD are
mostly the kind YARD can't express.

### The one real gap: generated attributes are invisible

**Zero `@!attribute` tags exist**, against:

- **343 `Data.define` call sites across 179 files (33% of all files)** — the dominant value-object idiom
- 158 `attr_reader`/`attr_accessor`/`attr_writer`
- 17 files using ActiveModel; `Tool::Input.field` (`tool/input.rb:90`) generates reader/writer/cast
  methods for every declared field across 42 files, 31 of them tools

YARD does not introspect `Data.define` members. So the 550 "attributes" it reports as 100%
documented are the `attr_*` ones it can see; every `Data.define` field in the codebase is
undocumented and *invisible to the coverage number*. The 79.8% is therefore optimistic.

**This is the highest-value YARD work available** and it is not "replace comments" — it is
"document the value objects that were never documented."

---

## Q3 — enforcement tooling

I installed these into a throwaway `GEM_HOME` and ran them against `lib/`. Nothing was added to
the `Gemfile`.

### `rubocop-yard` (1.3.0) — **ADOPTED, landed in `61bba95`**

> Outcome: wired into `plugins:` (so it rides the existing `rake check` pre-commit hook with
> no new wiring), all 74 offenses fixed by hand, suite green at 9,454 examples.
>
> **`AutoCorrect: false` on `YARD/MismatchName` was the one config decision, and it matters.**
> The cop's repair for an undocumented argument writes `@param name [Object]` with no
> description, in the opposite tag order to its own neighbours, appended out of parameter
> order. That is ~60 content-free tags that would have raised `yard stats` coverage without
> documenting anything. Detection is valuable; the repair is a sentence a human writes.
>
> Also learned: **the cop reports only the FIRST undocumented parameter per docstring**, so
> each fix reveals the next. The true offense count was ~120, not the 74 first reported.



```
541 files inspected, 72 offenses detected, 54 offenses autocorrectable

69  YARD/MismatchName   [Safe Correctable]
2   YARD/TagTypeSyntax
1   YARD/MeaninglessTag [Safe Correctable]
```

Six cops: `MeaninglessTag`, `TagTypeSyntax`, `CollectionStyle`, `CollectionType`, `MismatchName`,
`TagTypePosition`. The signal is `MismatchName` — **69 places where a `@param` name no longer
matches the parameter it documents.** That is doc/code drift already in the tree, it is a real
defect class, and it's *safe*-autocorrectable, so `rubocop -a` handles it (this is the good case
for `-a`; the CLAUDE.md warning is about `-A`).

Cost: one `plugins:` line in `.rubocop.yml`, one `Gemfile` entry. It rides the existing
pre-commit hook. 72 offenses is a single sitting.

### `yard-lint` (1.10.2) — **ADOPTED as a `--staged` pre-commit hook, landed in `08aafee`**

> Outcome: `.yard-lint.yml` configured down to defect-only, hook added with `types: [ruby]`,
> exit codes verified in both directions (1 on a defective file, 0 on a clean one — a gate that
> cannot fail is worth nothing).
>
> **It immediately found something rubocop-yard structurally cannot see.** Twelve
> `Warnings/UnknownParameterName` hits looked like false positives ("unknown parameter name:
> `need` — did you mean `need`?") and were not: `Compaction::Source` had an `attr_reader :eager`
> sitting between its constructor docstring and `def initialize`, so **all eleven `@param` tags
> were attached to the attr_reader** and the constructor was undocumented. `Oracle::Model` had
> the same defect on `attr_reader :model`. Moving the readers above the docstrings put the tags
> back — and rubocop-yard, which had been unable to see the docstring at all while it hung off a
> reader, then found `Oracle::Model` documenting one of its five parameters.
>
> That is the argument for running both: rubocop-yard reads one file's AST and asks whether a
> docstring agrees with the method under it; yard-lint asks what YARD actually *built*.

### the measurement that justified it — 114 offenses, not 3,471

Re-measured with the coverage-policy validators disabled and `Tags/TagGroupSeparator` (324
offenses, pure unmade house style) dropped:

| Validator | Count | Verdict |
|---|---|---|
| **`Documentation/DuplicateNamespaceComment`** | **58** | **real defects — content loss, see below** |
| `Tags/OptionTags` | 24 | methods taking an options hash with no `@option` |
| `Warnings/UnknownParameterName` | 12 | overlaps rubocop-yard, counted per tag not per method |
| `Tags/Order`, `Tags/InformalNotation` | 4 each | minor |
| `Documentation/MarkdownSyntax` | 4 | minor |
| `Warnings/UnknownTag` | 4 | prose using `@word` (`@root`, `@bm25`) — false positives |
| rest | 4 | noise |

It also ships **`Documentation/OrphanedDocComment`**, which mechanically catches the
`RenderInlet#initialize` bug found by hand above — a docstring separated from its method by an
intervening constant, so the `@param` tags document the constant.

`--staged` mode makes it a natural pre-commit hook: only files a commit touches are checked, so
the 58 legacy defects do not have to be cleared before the gate goes in. A draft config lives in
this session's scratchpad.

Original full-default measurement, for the record — 3,471 offenses, dominated by coverage policy:

| Cop | Count | Verdict |
|---|---|---|
| `Documentation/UndocumentedObjects` | 1,774 | policy — demands 100% coverage |
| `Documentation/UndocumentedMethodArguments` | 1,532 | policy — same |
| **`Documentation/DuplicateNamespaceComment`** | **58** | **real defect, see below** |
| `Documentation/UndocumentedOptions` | 33 | minor |
| `Tags/OptionTags` | 25 | minor |
| `Warnings/UnknownParameterName` | 24 | subset of rubocop-yard's 69 |
| everything else | 25 | noise |

> **FIXED in `f2fb5d8`, and it was worse than the note below says.** YARD keeps the **LAST**
> docstring, not an arbitrary one — so for all 58 the published documentation *was* the
> mechanical reopen note, and the real class documentation was what got discarded.
> `Lain::Usage` published the CLAUDE.md trap note instead of the monoid explanation.
>
> Three things worth keeping from the fix:
> - **Nothing can sit above a reopen.** Prose, `:nodoc:`, even a `rubocop:disable` directive all
>   become the docstring and destroy the real one — each checked against the registry, not
>   assumed. That is why `Style/Documentation` needed an `AllowedConstants` list rather than
>   inline suppressions: the usual escape hatch does not exist here.
> - **`AllowedConstants` matches the bare name repo-wide**, so generically-named reopens
>   (`Input` 24 files, `Report` 10, `Decision`/`Outcome` 7 each) carry their documentation on
>   the reopen instead of being exempted.
> - **A `Data.define` assignment is a `casgn` the cop never inspects**, but a class split for
>   `Metrics/ClassLength` has two real `class` keywords, so one of them must go bare.

**`DuplicateNamespaceComment` is the find of this whole exercise, and only `yard-lint` catches
it.** When two files both open `module Lain` and each has a comment above it, YARD attaches both
docstrings to the `Lain` namespace and **silently keeps one, discarding the other**. Verified
case:

- `lib/lain.rb:90-91` — the canonical description: *"An agent harness built as a study bench:
  context strategies, tool designs, and orchestration tactics are swappable, observable, and
  comparable."*
- `lib/lain/provider/http/providers/anthropic.rb:22-24` — a note about why `module Lain` nesting
  is kept open to satisfy `Style/OneClassPerFile`
- `lib/lain/provider/http/providers/bedrock.rb:10-14` — a note about `ensure_configured!` and
  absent ENV defaults

All three are attached to `Lain`. Two get thrown away, and which one survives is not something
we control. **The top-level description of the library is currently at risk of being replaced by
a comment about a RuboCop cop.** 58 namespaces are affected.

This is a *comment-placement* bug that plain RuboCop cannot see, and it is invisible without a
YARD-aware tool. Worth fixing; not worth a permanent 3,471-offense gate.

### `yard-rspec` (0.1) — **investigated and rejected**

The appeal was "specs become documentation, so the docs cannot rot." It does not deliver that,
for a structural reason worth stating: it is a YARD **handler**, so it statically parses `it`
strings out of the source and pastes them into the docs. **It never runs anything.** A stale
spec description becomes a stale doc that now looks authoritative — it enforces nothing.

Empirically, on top of that: `s.date = "2009-09-15"`, one release ever, `rubygems_version 1.3.5`,
and its own README opens *"This plugin **demonstrates** how RSpec tests can be embedded…"* — a
proof-of-concept for YARD's plugin API by YARD's own author, not a product. It does still load on
YARD 0.9 (`RUBY19` is defined) and it does attach on our `RSpec.describe` form, but
inconsistently: a single lib+spec pair attached 7 examples, while a 12-pair batch covering 347
`it` blocks attached **0**.

**`yard-doctest` (0.1.17) is the tool that actually delivers the goal** — it *executes* `@example`
blocks as tests, so a documented example that stops being true fails the run. We have **zero**
`@example` tags today, so there is nothing to run yet; adding them is the prerequisite. Flagged as
the agreed follow-up after `rubocop-yard` and `yard-lint`.

Also considered: `yardstick` (coverage thresholds — redundant with `yard stats`).

### Also missing, trivially

No `.yardopts`, no `rake doc` task. Docs have never been built or published. One file fixes that.

---

## Q2 — Sorbet and RBS

### Can we delete tests? No.

The suite is 9,450 examples across 468 spec files. Grep for type-shaped assertions looks
promising and then collapses under inspection:

| Raw pattern | Hits | What sampling found |
|---|---|---|
| `raise_error(ArgumentError` | 428 | **~6% are type checks.** The rest are *value* rules — `k: -1` "must be positive" (`context/recall_spec.rb:116`), `count: 0` (`telemetry_spec.rb:128`), illegal state transitions (`epic/records_spec.rb:39`). No type system expresses "positive" or "legal transition". |
| `be_a(` | 396 | mostly one assertion among several, not the whole test |
| "nil" in description | ~200 | semantics of *absence*, not type presence — "raises rather than returning nil for an absent capability" (`toolset_spec.rb:49`), "nil when no compaction has ever been observed — absence, not zero" (`run_clock_spec.rb:120`) |
| `raise_error(TypeError` | 16 | the genuine ones |
| `raise_error(NoMethodError` | 15 | mostly constructor privacy |

Naively ~1,100 examples look type-shaped (12%). **Realistically 60–120 examples (0.6–1.3%)** are
truly subsumable.

Two structural reasons the number is so low:

1. **Our type checks guard boundaries a Ruby type checker cannot see through.** `tool/input.rb`
   validates malformed **LLM tool-call JSON**; `Mode::Switch` guards `JSON.generate`/journal
   replay; the Rust FFI guards (`spec/lain/rust/*_spec.rb`) guard the magnus boundary. Sorbet and
   RBS type Ruby-to-Ruby call sites. Data arriving from a model, a journal, or Rust is `untyped`
   at the door either way, so the runtime check and its test both have to stay.
2. **The suite's real content is laws.** ~1,852 lines of Rantly-backed shared examples included
   at ~84 sites (monoid, `Regular`, `MeetSemilattice`, homomorphism, provider parity) generating
   500+ examples; plus digest stability, `Ractor.shareable?` (`value_object_shareability_spec.rb`
   sweeps 250+ classes), cache-hit semantics, and the git/nvim/subprocess seams. **Associativity
   is not a type.**

**RBS/Steep would delete even fewer than Sorbet — plausibly zero** — because static-only checking
adds no runtime protection, so every one of those tests still has to run.

### Adoption cost, if we ever wanted the docs value anyway

~5,643 `def` sites and 2,359 class/module declarations across 541 files ⇒ **10,000–15,000 lines of
`.rbs`/`.rbi`**, and autogeneration chokes on exactly our hot spots: 343 `Data.define` sites, the
ActiveModel `attribute` DSL, `method_missing` (3), `define_method` (7). The 7–8 magnus-backed
`Ext::*` classes have **no Ruby source at all** — hand-written stubs either way, a wash between
the two.

`sig/lain.rbs` is a 4-line `bundle gem` scaffold, never filled in. `rbs 4.0.3` in `Gemfile.lock`
is transitive via `rdoc`. There is zero prior investment; this is greenfield.

### Sorbet specifically: two real objections beyond cost

1. **Ractor.** `sorbet-runtime` wraps methods and `T::Struct` instances carry decorator-managed
   prop metadata. We assert `Ractor.shareable?` mechanically across 250+ value classes, and
   `Compaction::Scheduler`/`WorkerEnv` call `Ractor.make_shareable` on live objects in production
   paths. `T::Struct` is a competing value-object model to our 343 `Data.define` sites whose whole
   point is shareability. Adopting sigs without switching to `T::Struct` still leaves every
   `Data.define` field untyped — so we'd pay the cost and not get the benefit.
2. **Nominal vs structural.** Our house style is "depend on messages, not on types," and there
   are **159 files carrying `@param foo [#method]` duck-type docs** (`journal.rb:48`
   `@param clock [#call]`; `approval/gate.rb:284` `@param asker [#ask]`). `Sink::Null`,
   `Provider::Mock`, `Effect::Handler::Mock`, `Channel::Null`, `Isolation::Null` are all
   substituted for real collaborators. Sorbet is primarily nominal; expressing this means either
   `T.untyped` everywhere or retrofitting formal interface modules onto every real/Mock/Null trio.

If we ever did type this codebase, **RBS is the better fit** — zero runtime footprint (so no
Ractor interaction at all), and RBS `interface` types are structural, which is precisely the
shape of those 159 duck-typed seams. But that's an argument about *which* to pick, and the
test-deletion premise doesn't survive either way.

### Recommendation

**Abstain from both.** Your default preference against Sorbet holds, and the evidence extends it
to RBS. The value proposition would be documentation and refactoring confidence — and we already
have a documentation system at 79.8% coverage that we haven't finished wiring up. Spending the
effort there dominates.

---

## Proposed work, in order

1. ~~**Add `rubocop-yard`**~~ — **DONE, `61bba95`.** 74 offenses fixed, autocorrect disabled with
   the reason recorded in `.rubocop.yml`.
2. ~~**Add `yard-lint` as a `--staged` pre-commit hook**~~ — **DONE, `08aafee`**, with two
   orphaned-docstring defects fixed on the way in.
3. ~~**Fix the 58 `DuplicateNamespaceComment` cases**~~ — **DONE, `f2fb5d8`.** All 58 verified to
   publish real documentation (yardoc into a scratch db, docstring read back for every path).
   What it cost and what was learned is below.
4. **`yard-doctest`** — the "documentation that cannot rot" mechanism, and the only one of the
   three that actually executes anything. Needs `@example` tags first; we have zero. Agreed
   follow-up.
5. **`@!attribute` for `Data.define` value objects**, biggest-first. This is the actual
   documentation gap and the only place where "write more YARD" is the right answer.
6. **Add `.yardopts` + a `rake doc` task.** Docs have never been built.
7. **Decide the comment-ratio question.** 55% comment is either the house style or a problem;
   CLAUDE.md currently claims something that isn't true either way.
8. Not now: Sorbet, RBS, `yard-rspec`.

## Reproducing

```bash
export PATH="$HOME/.rubies/ruby-4.0.6/bin:$PATH"
export LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib

bundle exec yard stats --list-undoc lib          # 79.80% documented

# comment/code ratio
find lib -name '*.rb' -print0 | xargs -0 awk '
  /^[[:space:]]*$/{b++;next} /^[[:space:]]*#/{c++;next} {k++}
  END{printf "comment %d code %d = %.1f%%\n", c, k, 100*c/(c+k)}'

# linters, in a throwaway GEM_HOME so the Gemfile is untouched
gem install --no-document yard-lint rubocop-yard
yard-lint lib
rubocop --only YARD lib                          # with rubocop-yard in plugins:
```

## References

- `yard stats` / `yard-lint` / `rubocop-yard` output, this repo, 2026-08-04
- `lib/lain/tool/input.rb:15-40` — why wire-boundary validation is not a type-system problem
- `spec/value_object_shareability_spec.rb` — the shareability sweep Sorbet would have to survive
- `CLAUDE.md` — comment policy, RuboCop `-a` vs `-A`, the Ractor/4.0.6 history
- Ruby Bug [#22072](https://bugs.ruby-lang.org/issues/22072) — why we pin 4.0.6
