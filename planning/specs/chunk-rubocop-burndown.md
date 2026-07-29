# RuboCop plugin burn-down

**Status:** planned, not started. The plugins and the TODO landed in `a89bfc5`.
**Prerequisite:** the concurrent session's spec edits are merged. This chunk rewrites spec
files broadly, so it conflicts with anything in flight.

## What landed already

`rubocop-rspec`, `rubocop-performance`, `rubocop-rake` and `rubocop-thread_safety`, wired via
`plugins:` in `.rubocop.yml`. Safe autocorrect ran to a fixed point (two passes: the reordering
cops introduce fresh `Layout` offenses as they move code). The remaining **5571** offenses went
to `.rubocop_todo.yml`. Suite verified independently: 6559 examples, 0 failures.

## The headline

**92% of the offense count is seven cops that are a policy question, not cleanup work.**

| | Offenses | Share |
|---|---:|---:|
| Policy decision (§4) | 5100 | 92% |
| Ruled false positive (§1) | 66 | 1% |
| Actual burn-down (§2, §3) | ~405 | 7% |

Reading "5571 offenses" as 5571 units of work is the trap here. `RSpec/ExampleLength` (1716) and
`RSpec/MultipleExpectations` (2610) are not defects; they are a description of how these specs are
written. They get decided once, in §4, and then stop appearing.

The genuinely useful cops are small: about 405 offenses across 25 cops.

---

## 1. Ruled false positive: `RSpec/IdenticalEqualityAssertion` (66)

**Decision: disable permanently in `.rubocop.yml`, with the reasoning inline. Not a TODO entry.**

The cop flags `expect(x).to eq(x)` as a probable flawed test. In this codebase that shape is
usually the *point*. Five sampled sites, all legitimate:

| Site | What it asserts |
|---|---|
| `spec/lain/arm/driver_spec.rb:57` | `driver.report == driver.report` — byte-identical reports across two calls |
| `spec/lain/bench/dry_replay_spec.rb:66` | `replay(over:) == replay(over:)` — determinism, named in the example string |
| `spec/lain/cli/backend_spec.rb:345` | `backend.eager` **identity** via `be` — memoized, built once per run |
| `spec/lain/actor_spec.rb:108` | `log.to_a == log.to_a` — the fold consumed nothing, log is append-only |
| `spec/lain/cache_profile_spec.rb:100` | `ANTHROPIC == ANTHROPIC` — `Data` equality semantics |

Purity, determinism, memoization and idempotence are the invariants this bench is built on, and
asserting them looks exactly like a tautology from the AST. The cop cannot tell the difference.

I initially argued this cop would surface the "green tests not testing their subject" pattern the
review panels keep finding. That was wrong, and worth recording: it flags the opposite. The cop
that actually serves that goal is `RSpec/NoExpectationExample` (§3).

Sampling was 5 of 66. If the burn-down wants certainty, read the other 61 before disabling —
but the five span five unrelated subsystems, so I'd bet on the pattern holding.

---

## 2. Wave A: production code

These touch `lib/`, run first, and are independent of the spec merge.

### A1 — Performance (37 offenses, 12 cops, one commit)

`Detect` 13, `CollectionLiteralInLoop` 4, `TimesMap` 4, `Sum` 3, `DeletePrefix` 2, `DeleteSuffix` 2,
`StringInclude` 2, `UnfreezeString` 2, `MapMethodChain` 2, `Count` 1, `MapCompact` 1,
`MethodObjectAsBlock` 1.

Mechanical, but most are marked **unsafe**-correctable, so this is `-A` **per cop** with the diff
read each time. Do not batch them behind one `-A`. `CollectionLiteralInLoop` and
`MethodObjectAsBlock` have no autocorrect and want a human.

The CLAUDE.md warning applies directly: `Style/RedundantSelfAssignment` would once have silently
discarded every turn. Read the diff.

### A2 — Thread safety (55 offenses, 3 cops, one commit)

`ClassInstanceVariable` 26 (12 `lib/` files), `NewThread` 37 (6 in `lib/`, 31 in specs),
`DirChdir` 23 (all specs).

The substantive one, and the reason I recommended the gem. Expect this to be an **audit that
mostly ends in documented exclusions**, not a refactor:

- `ClassInstanceVariable` in `tool.rb`, `tool/contracts.rb`, `provider/http/configuration.rb` is
  almost certainly class-level registry and memoized config, set at load time and read after. That
  is safe, and the exclusion should say so.
- `NewThread` in `frontend/neovim.rb`, `frontend/tty.rb`, `notify.rb` is deliberate supervised
  threading. It stays; the cop's value is that a *new* thread now has to be argued for.
- `DirChdir` is spec-only. `parallel_tests` forks processes, so `Dir.chdir` is process-local and
  not the hazard the cop assumes. Low priority, likely a permanent spec-wide exclusion.

The output of A2 is mostly prose. That is a fine outcome — the point is that each site got looked
at once and the verdict is written down.

---

## 3. Wave B: specs (after the merge)

### B1 — Doubles that do not verify (71 offenses, 4 cops, one commit)

`VerifiedDoubles` 48, `VerifiedDoubleReference` 13, `AnyInstance` 7, `StubbedMock` 3.

**Highest-value spec group.** An unverified `double(:thing, call: x)` keeps passing after the real
method's signature changes — the failure mode is a green suite over a broken interface. Converting
to `instance_double(Lain::Thing)` makes the double fail when the contract moves.

This is exactly the "green tests not testing their subject" pattern, unlike §1.

Do it by hand, or expect churn: `instance_double` will reject stubs for methods that do not exist,
and every rejection is a finding worth reading rather than papering over.

### B2 — Examples that assert weakly (38 offenses, 5 cops, one commit)

`MessageSpies` 18, `NoExpectationExample` 13, `ExpectActual` 3, `RepeatedExample` 2,
`IteratedExpectation` 2.

`NoExpectationExample` (13) is the one to read first — an example with no expectation passes
unconditionally. Some will be legitimate "does not raise" smoke tests, which want an explicit
`expect { ... }.not_to raise_error`. `RepeatedExample` (2) means two examples in a group are
byte-identical, so one is dead.

### B3 — Mechanical spec modernization (97 offenses, 5 cops, one commit)

`DescribedClass` 44, `IncludeExamples` 44, `ReceiveMessages` 4, `ExpectChange` 3, `BeEq` 2.

All autocorrectable, all unsafe-flagged, all low-judgment. `IncludeExamples` is the RSpec 4
migration (`include_examples` → `it_behaves_like`) and is worth doing for that reason alone.
One `-A` pass over these five, one suite run, done.

### B4 — Naming and file layout (76 offenses, 7 cops, one commit)

`SpecFilePathFormat` 26, `MultipleDescribes` 19, `ContextWording` 18, `IndexedLet` 8,
`DescribeMethod` 2, `SpecFilePathSuffix` 1, `Rake/Desc` 1.

Renames files, so land it last — it maximizes conflict with anything in flight. `SpecFilePathFormat`
wants `spec/support_vsock_availability_spec.rb` to match its described subject; check whether the
described subject or the filename is the thing that is actually wrong.

---

## 4. Policy decisions, not burn-down (5100 offenses, 7 cops)

These need one ruling each and then a permanent, commented entry in `.rubocop.yml` — moved out of
the TODO so the TODO stops lying about being a work queue.

| Cop | Count | The question |
|---|---:|---|
| `MultipleExpectations` | 2610 | Currently `Max: 22`. House style is clearly multi-expectation examples. |
| `ExampleLength` | 1716 | Currently `Max: 46`. |
| `InstanceVariable` | 341 | Specs using `@ivar` over `let`. Large refactor, thin payoff. |
| `MultipleMemoizedHelpers` | 309 | Currently `Max: 14`. |
| `LeakyLocalVariable` | 63 | **Unsampled.** Could be real. Read 5 before ruling. |
| `DescribeClass` | 54 | Probably `output_discipline_spec.rb` and friends, which describe a *property*, not a class. Legitimate. |
| `NestedGroups` | 7 | Currently `Max: 5`-ish. Trivial either way. |

The precedent is already in `.rubocop.yml`: `Metrics/BlockLength` is excluded for specs because
"the cop measures the DSL, not complexity." `ExampleLength` and `MultipleExpectations` are the same
argument wearing a different name, and CLAUDE.md's "never loosen a `Metrics/*` limit" is about
`lib/` objects — where a tripped cop means a missing collaborator. It does not transfer to counting
`expect` calls in a spec.

My read: disable `ExampleLength`, `MultipleExpectations`, `MultipleMemoizedHelpers` and
`InstanceVariable` for `spec/**` with a comment giving that reasoning. Sample `LeakyLocalVariable`
before deciding. That is one commit, and it removes 92% of the number.

---

## Ordering

```
A1 Performance ──┐
                 ├── independent of the merge, do now
A2 ThreadSafety ─┘

        ⟨concurrent session merges⟩

B1 VerifiedDoubles ── B2 WeakAssertions ── B3 Mechanical ── B4 Naming/layout

§1 + §4 config rulings: any time; doing them first makes `rubocop` output legible
```

`§1` and `§4` first is tempting and probably right — a TODO that admits what it is not going to fix
makes the remaining 405 visible.

## Verification, per commit

1. `bundle exec rubocop` clean (the TODO shrinks by exactly the cops addressed).
2. `bundle exec rspec` — compare the example **count** against 6559, not just the failure count.
   A dead `parallel_tests` worker looks like "fewer examples, 0 failures" (CLAUDE.md).
3. Remove the burned-down cop's block from `.rubocop_todo.yml` by hand rather than regenerating,
   so an unrelated regression cannot slip in under a regenerated baseline.

## Open item from `a89bfc5`

`--auto-gen-only-exclude --exclude-limit 20` blanket-**disabled** seven cops that exceeded the
limit instead of listing their files: `InstanceVariable`, `IdenticalEqualityAssertion`,
`LeakyLocalVariable`, `DescribeClass`, `IncludeExamples`, `NewThread`, `SpecFilePathFormat`.

Four of those are §4 policy calls and one is §1, so their disable is arguably correct — but it
should be *stated* in `.rubocop.yml`, not an artifact of a flag. `NewThread` and `IncludeExamples`
are real work and need re-scoping to file lists. One regeneration at a higher exclude limit, or
hand-editing those two blocks, both work.
