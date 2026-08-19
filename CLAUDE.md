# Working on Lain

Lain is an agent harness built as a **study bench**. The agent is the vehicle; the bench is
the deliverable. Optimize for making context strategies, tool designs, and orchestration
tactics swappable, observable, and comparable — not for making the agent good.

The approved design plan lives at `~/.claude/plans/jiggly-greeting-avalanche.md`. Read it
before making architectural decisions. It records *why*, including several conclusions that
cost real debugging to reach.

## Toolchain

The shell's default `ruby` is the wrong one. This project needs 4.0.6, and it comes from **mise**.
`.envrc` already exports the lot, so an interactive shell that has `cd`'d into the repo needs
nothing — direnv activates on entry and restores the previous environment on exit. Non-interactive
callers (agents, scripts, anything not sourcing the shell rc) either prefix with `direnv exec .` or
export it themselves:

```bash
eval "$(mise env -s bash ruby@4.0.6)"
export LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib   # see "OpenSSL" below
export TMPDIR="$HOME/tmp/lain"                          # see "TMPDIR" below
```

**Do NOT use `~/.rubies/ruby-4.0.6`.** It was built against a home-directory prefix that no longer
exists, so its compiled-in `$LOAD_PATH` is dead and every gem binstub shebang points at nothing:
`bundle` cannot start, and `rake pspec` cannot spawn a worker. Three separate agents lost hours to
this in one chunk, and — the part worth recording — **the obvious workaround is worse than the
breakage**. Forcing it up with `RUBYLIB` puts the stdlib *ahead* of the gems, which shadows the real
`cgi` gem with Ruby 4.0's stripped one and fails the vendored-SDK specs on `CGI.parse`. Two agents
then reported that as a Ruby 4.0 incompatibility and a third as a locked-gem problem. It was none of
those; it was the workaround. If the suite shows failures you did not cause, **check the interpreter
before believing them**.

**TMPDIR must be on the same filesystem as the repo.** `review/deletability_spec.rb` copies a
fixture tree with `cp -al`, and a hard link cannot cross a device. The default `/tmp` is tmpfs here
while `$HOME` is ext4, so all seven of its `BootWithout` examples fail in fixture setup with a bare
`Command failed with exit 1: cp` — which reads like a defect and is not one.

That one fixed path is also **shared mutable state between concurrent agents**, which is a newer
hazard now that an orchestrated chunk routinely has several worktrees running at once. The
isolation, forge, review and frontend specs drive real `git` and real `tmux` against fixture trees
under `$TMPDIR`, so two concurrent full-suite runs collide by construction. The shape is a
`.git/objects/maintenance.lock` ENOENT, a tmux cwd `realpath` miss, **a different example failing
each run**, and green the moment the other process exits. So: **a red `pspec` is not evidence until no other
`parallel_rspec` is live.** Same lesson as the two traps below about scratch filenames and reading
the tree mid-run — check the conditions before believing the failure.

**Ask that question with `pgrep`, not with `ps | grep`.** The obvious spelling over-counts and, worse,
never reaches zero when several agents poll at once: `ps aux | grep '[p]arallel_rspec'` also matches
the *shell command lines* of sibling agents running the same check, so two waiters block each other
forever. Measured: it reported 2 against 1 real run, the extra being a `zsh -c` wrapper. Match the
binary instead, which no wrapper's argv contains:

```bash
pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'   # 0 means genuinely quiet
```

Note a live `nvim`/`ollama` cockpit contends for the same fixtures without being a `parallel_rspec`
process at all, so a zero here is necessary and not sufficient.

**Wait on `pre-commit` too, and for a sharper reason than contention.** The hook **autostashes**
unstaged tracked changes before running the suite against the staged tree, and that stash is
repo-wide: a concurrent reader in another worktree sees its own unstaged edits vanish and reappear,
`git status` disagree with what it just wrote, and untracked-file visibility change under it. Two
agents hit this as a bare `NameError` on a constant they had just added. It is the "do not read the
tree while a suite run is in flight" trap one layer deeper -- it reaches `git status`, not only file
reads. `pgrep -f '[p]re-commit'` before believing a tree that looks wrong, and re-check once quiet.

**`rake compile` needs `clang`** (bindgen wants `libclang`). Switching interpreters invalidates
`rb-sys`'s build fingerprint and forces a rebuild, which is usually when its absence surfaces.

**4.0.6 is a floor, not a preference.** 4.0.5 crashes the VM intermittently under
`rake pspec` — [Bug #22072](https://bugs.ruby-lang.org/issues/22072), `[BUG] should have cvar
cache entry`: `rb_cvar_set` builds a new `RCLASS_CVC_TBL` without copying the old contents, so
in a multi-Ractor process a later class-variable READ finds no cache entry and aborts. Our one
`Ractor.new` (`spec/lain/rust/fuzzy_spec.rb`) is enough to arm it. It surfaces at whatever cvar
gets read first — for us `i18n/config.rb:176`, which is a victim, not the cause. Fixed in 4.0.6,
along with two more Ractor crashes (#22075, #22084).

**Why `pspec` and not `rspec`.** The suite is subprocess-bound, not CPU-bound: **57s user against
119s *system*** (2026-08-05, 10865 examples), because the isolation, forge, review and frontend
specs drive real `git` and real `nvim`/`tmux`. Those are the subjects under test, so the cost is
not removable -- but it parallelises. Serial **197s**; `rake pspec` **21-27s**. That 1:2 user-to-
system ratio has held while the suite doubled in size, which is the mechanical statement of
"the work is spawning, not computing".

### What binds, and why more workers than cores helps

**Neither cores nor memory is the ceiling. Kernel spawn cost is.** Measured 2026-08-05 on a
Ryzen 7 3700X (8 physical, 16 logical, 15.9G) by sampling `/proc/stat`, `/proc/pressure` and
`/proc/*/smaps_rollup` across whole runs:

| workers | wall | peak RSS | min MemAvailable | swap growth | user | sys | **idle** |
|---|---|---|---|---|---|---|---|
| 7 | 31.2s | 1340MB | 7956MB | **0** | 20.8% | 26.5% | **52.6%** |
| 10 | 25.1s | 1745MB | 7436MB | **0** | 28.2% | 30.1% | 41.6% |
| 12 | 21.6s | 2016MB | 7369MB | **0** | 35.2% | 36.9% | 27.6% |

Read the idle column first. **At `physical - 1` the box is half idle**, because a worker blocked
in `git` is not holding a core -- so cores cannot be the ceiling, and adding workers past the core
count is how the idle gets used. What the marginal worker buys as saturation approaches is
**system** time, not throughput: user and sys climb together, and mid-run at n=11 `vmstat` reads
40% user against 58-61% sys. That is fork/exec in the kernel, and it is what eventually stops the
count from paying.

**Memory is not close to binding**, on a quiet box or a working one. Swap grew by *zero* at every
count, `/proc/pressure/memory` full avg300 stayed at **0.35%**, and MemAvailable never fell below
6.9G -- including a deliberately loaded repeat (a resident `ollama` model, a live `nvim`/`tmux`
cockpit, another agent running specs, `mempalace`), which came out 6-8% slower at every count with
the ordering unchanged. Note that a resident model's several GB are **VRAM**, not the system
memory this argument is about; the real system-memory contributors are `mempalace`'s ~4.2G and
whatever editor tooling is up.

An earlier edition of this section concluded the opposite -- "the ceiling is CORES", so
`spec_workers = physical - 1` -- from a monotonic best-of-3. That was a CPU-bound argument applied
to an I/O-bound suite, and the 52.6%-idle reading is what falsifies it. Keep the reading rather
than the rule: if a future change makes this suite compute rather than spawn, idle will vanish at
a lower count and cores will start to bind for real.

**Measured optimum on this box: 10-14 workers, and `physical - 1` is the worst count tried.**
Interleaved best-of-4 (counts cycled round-robin, never blocked), all runs at 10865 examples:

| n | 7 | 9 | 10 | 12 | 14 |
|---|---|---|---|---|---|
| best | 30.0s | 25.1s | 23.9s | 22.0s | 21.1s |
| median | 31.8s | 26.5s | 25.0s | **24.4s** | **24.4s** |

Every n=7 rep was slower than the *median* of every other count. The gains flatten at 12-14 --
identical medians, because by then the wall has reached the single-file floor below and there is
nothing left for a worker to shorten. `LAIN_SPEC_WORKERS=12` is a good default **on this box**;
the `Rakefile` default stays lower on purpose, because these are one machine's numbers and the
failure mode of guessing high is silent (see the OOM note below).

**Interleave the counts and take a best-of-N; a blocked sweep will lie to you.** Single runs vary
by ±50% -- the runtime log redistributes files every run -- and this machine also carries a
long-running `mempalace-refresh` (observed activating for 3h39m in one stretch) which executes a
sequence of short-lived children, each pinning a core at ~99% with ~4.2G resident. Their spacing
follows the workload, not a period, so repetition alone cannot average it out. A *blocked* sweep
(all reps of one count, then the next) measured **25.8-40.0s within n=9** and **24.4-39.9s within
n=11** -- spreads wider than any difference between counts. Every number in this section was taken
with that load present.

### The wall is a MAX, not a sum

`parallel_tests` packs whole FILES into groups, so **the longest single file is a hard floor** and
no worker count touches it. This is the trap in reading any speed-up here: total serial work can
fall a long way while the wall barely moves, because removing one file from the floor merely
exposes the one behind it. 2026-08-05 took ~15s out of the serial total and the floor fell by
under a second, because the top two files were effectively tied.

Ranked from `tmp/parallel_runtime_rspec.log`, 2026-08-05 -- a snapshot, not a fixture:

| file | contended | note |
|---|---|---|
| `isolation/worktree_handback_spec.rb` | 18.5s | the floor; 68% of its git spawns are the SUBJECT's |
| `isolation/worker_handoff_spec.rb` | 15.4s | never profiled |
| `review/source/github_pr_spec.rb` | 11.9s | 9.6s -> 6.5s serial after fixture reuse |
| `review/deletability_spec.rb` | 9.7s | no subprocesses at all; CPU and load |
| `forge/promotion_spec.rb` | 9.4s | |
| `review/source/local_branch_spec.rb` | 5.9s | 16.2s -> 4.1s serial after fixture reuse |

Even if both isolation files fell, `deletability` and `promotion` at ~9.5s become the next floor.
There is no version of this line of work where fixture reuse alone gets the wall under ~9s.

### Profile first, and read the answer as a signpost

Every slow spec file splits its cost between **fixture setup** and **the subject's own work**, and
that ratio decides what to do. Measure it -- attributing each subprocess to the nearest frame under
`lib/` or `spec/` takes about thirty lines and settles in one run what inspection argues about.

- **Cost in the FIXTURE -> reuse the fixture.** `review/source/local_branch_spec.rb` was **12.68s
  of 14.64s of git time in the SPEC's own setup** -- 1347 spawns against the subject's 233 -- being
  re-done per example for a repository that is a constant. **16.19s -> 4.06s**, 1587 spawns -> 381,
  no assertion touched.
- **Cost in the SUBJECT -> that is an APPLICATION finding, and it is the more valuable one.** A
  spec is a harness; making it faster helps whoever runs it. Making the *subject* spawn fewer
  subprocesses helps everyone who runs `lain`, and the spec gets faster for free.
  `isolation/worktree_handback_spec.rb` spends **796 of its 1163 spawns inside the subject** --
  about 11 `git` invocations per example -- and `Review::Source::LocalBranch` spends ~4 per
  changeset, three of them in the constructor (two `rev-parse --verify`, one `merge-base`). At
  ~5ms a spawn that is latency a user feels on every review.

  So "this file is as fast as its subject allows" is the right answer to *"should I shard the spec
  file?"* -- it is **not** the place to stop. It is a pointer at the application. Note the design
  tension before batching, though: `LocalBranch` resolves base and head separately so each refusal
  can name its own role, and one `rev-parse` for both would trade that for a spawn.

**Do not shard a spec to game the packer.** One spec file per code file at the mirrored path is
how a reader finds the spec for a subject without searching, and carving it up trades that for
wall-clock the profiler has usually just said was not in the spec's control.

The shape that works -- four implementations now, in `SeedRepo`, `DivergedRepo`, `ChangesetRepo`
and `GithubPrFixture` -- is: build the repository **once per process** and **copy** it, rather than
`init` + commits per example. A fresh `git init` repo holds no absolute paths, so a copy IS the
repo rather than a reconstruction of one, and its oids are identical in every copy. That is what
lets the template hand over the shas an example used to capture by building them itself. Worktrees
added *during* an example DO record absolute paths, so a template is only ever the seed, never a
repo an example has touched. Measured: **27.1ms to build, 3.5ms to copy**. Across this chunk's
three files: **33.1s -> 13.2s serial**.

A template moves a fixture one step away from the group that needs it, and that is worth one
guard: `DivergedRepo` asserts its rich changeset still contains the binary, the non-ASCII path and
the merge, because the port contract SKIPS its binary example when there is no binary -- so a
template that silently stopped producing one would delete coverage and stay green.

Things measured that do **not** help: `TMPDIR=/dev/shm` (-8.6%; the page cache already had it),
`core.fsync=none` (nothing -- git here is spawn-bound at ~5ms/spawn, not fsync-bound), and mocking
git (the `shell_out_factory` seam exists and the heavy specs already use it for *failure
injection*; the semantics under test are git's own, so a fake would test the fake).

### Allocations and GC are a BOOT cost, not a per-example one

Worth knowing before optimising for them, because the intuition points the wrong way here.
`GC.stat` deltas around whole spec files (2026-08-05):

| file | objects | GC time | share of wall |
|---|---|---|---|
| `review/source/github_pr_spec.rb` | 479K | 83ms | ~1% |
| `review/source/local_branch_spec.rb` | 278K | 73ms | ~2% |
| `review/changeset_spec.rb` | 197K | 43ms | ~2% |
| `review/deletability_spec.rb` (no subprocesses at all) | 1021K | **32ms** | ~0.5% |

That last row is the one to be careful with: a million objects for sixteen examples looks alarming
and costs 32ms. **91% of them come from one call path in the spec's own `TreeSweep` helper**
(`Pathname#relative_path_from`, itself 73.5%), which is test code, not `lib/` -- so it is worth
tidying and worth nobody's optimisation budget.

**`require "lain"` alone allocates 701K objects and spends 90ms in GC**, which is more than any of
those files spends running its examples -- 3.6x `changeset_spec`'s 77 examples, at twice the GC.
So allocation cost in this suite is paid **once per worker at boot**, multiplied by the worker
count, and shows up as RSS rather than as time: ~80MB of each worker's ~150MB is the loaded
library. Chasing per-example allocations is chasing under 2% of the wall. (The `SecureRandom.uuid`
figure from the anchor work does not transfer either: `changeset_spec` mints **484** uuids at
3.8µs each, 2ms total. 80,190 was one large real changeset, not a spec run.)

**A preloader (spring/zeus-style fork-after-load) is still not the answer for SPEED**, and
hyperthreading does not rescue it. Per-worker load is only **0.73-1.26s** -- a worker loads its own
SLICE, not the whole suite -- against a wall floored by one file. But the allocation numbers above
sharpen the memory half of the case: COW would share those 701K boot objects instead of
re-allocating them per worker, which is roughly half of peak RSS. That is a memory argument, and it
is the one that would matter on a smaller box. Bootsnap already takes the cheap half: **1.7s warm
vs 3.6s cold** for all 465 files, ~53% off, from a 33M iseq cache under `tmp/cache`. A cold cache
is the likely explanation for any surprisingly slow boot. Note the hazard is Ruby-specific --
bootsnap keys an entry on (mtime-seconds, size), so two same-size edits in the same second collide;
content-hashed caches (`sccache`, cargo fingerprints, swc) have no such failure mode.

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
bundle exec rake pspec         # THE suite command: 21-27s. Plain `rspec` is the same 10865 examples
                               # SERIALLY and takes ~3m17s -- 8x slower, for no extra signal.
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

### Hunting flakes: `rake spec:flakes`

`bundle exec rake spec:flakes` runs the WHOLE suite 16 times (4 concurrent lanes × 4 runs;
`rake 'spec:flakes[8]'` or `LAIN_FLAKE_LANES`/`LAIN_FLAKE_RUNS` to change that), each in its own
random order, and reports which examples disagreed with themselves — separating those from the
ones that failed in *every* run, which are broken specs and not flakes. Tens of minutes; it is a
hunt, not a gate, and nothing in `check` or the pre-commit hook calls it.

Deliberately **not** `pspec`. `parallel_rspec` packs whole FILES into groups, so a worker there
sees a slice — which cannot find leakage between two examples that never met. The parallelism
here is across RUNS, and each run is the whole suite in one process.

`bin/spec-flakes` is a **spork**: it pays `require "spec_helper"` once (1.8s, ~700K objects) and
every run is a `fork` of that, so COW shares the loaded library instead of re-allocating it. The
preload line sits AFTER spec_helper and BEFORE the spec files on purpose — preloading spec files
would hand all 16 runs one copy of every file's load-time fixture (`diff_mode_spec`'s
`SocketTmpdir.persistent` directory, and the `at_exit` that deletes it) and the tool would
manufacture the flakes it went looking for.

Two things it had to correct, both worth knowing before writing any other out-of-band suite runner:
each run gets its own `TMPDIR` and XDG tree (four concurrent suites collide on the shared ones by
construction — the TMPDIR note above, four lanes deep), and each run sets `$PROGRAM_NAME` to
rspec's own argv-zero. That second one is not cosmetic: `Configuration#files_or_directories_to_run=`
appends the `spec` default path only when `$0` basenames to `rspec` (without it the hunt loads no
spec files and reports a confident green over zero examples), and `CLI::Up::PreFlight` expands a
relative executable to an absolute path while `up_spec`'s spy compares the raw `$PROGRAM_NAME` —
10 examples failed in every run, from the harness rather than from the suite.

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

**`Project` splits root from cwd**, and they are different questions: **root** is the authority
boundary (what `.lain/` governs, what a pre-approval may speak for), **cwd** is where a relative
path resolves. A monorepo session runs with cwd deep in a subtree and root at the repo top, and
`$HOME` can never be *inferred* as a root — `lain up ~` says it explicitly or it does not happen.

**The secret boundary is three places, not one, and the split is forced.** A path classifier
answers before a file is opened; a region detector cannot answer until it has the bytes. So:
**gate on the effect** (`Sensitivity::Policy`, read by `Effect::Handler::Sensitivity` and `Gate`),
**filter on the result** (`Middleware::WithholdSecretPaths`, so `grep`/`glob`/`list_files` stop
enumerating a denied path), and **mask on the content** (`Middleware::RedactSecretReads`, which
parks a pending and releases by region). **Tier-1 tools keep their doctrine: `read_file`, `grep`,
`glob` and `list_files` do not check paths.** That is deliberate — the boundary is one place a
reader can find, not a check scattered through every tool.

**One classifier, and disagreement is unrepresentable.** `Sensitivity::Policy` builds its own
`Filter` in `#initialize` (before it freezes — a lazy one raises `FrozenError` at its first
caller, mid-run), and nothing exposes the classifier, so there is exactly one `Filter.new` in
`lib/`. A gate that refuses a read while the listing enumerates the same path cannot be
constructed, rather than being merely untested.

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
- **`rm .git` before running anything in a COPY of a linked worktree.** A linked worktree's `.git`
  is not a directory, it is a one-line pointer file (`gitdir: /path/to/lain/.git/worktrees/<name>`).
  So `cp -a` of a worktree gives you a copy whose git admin data is still the **original's**, and the
  isolation and forge specs — which drive real `git` against the repo they find — then operate on the
  linked worktree's admin directory rather than the copy's. Observed 2026-08-04: one full-suite run
  from such a copy **deleted the entire copy**. Nothing warns you; the pointer file looks inert.
  Copying a worktree for mutation, bisect or spike work is otherwise reasonable, so the rule is just:
  delete the pointer first, or copy from a real clone.
- **A class named for a top-level constant SHADOWS it for everything lexically inside the
  enclosing namespace.** Defining `Effect::Handler::Sensitivity` made `gate.rb`'s bare
  `Sensitivity::Policy` resolve to `Handler::Sensitivity::Policy` and die — for every caller
  omitting the keyword, i.e. most of them. `Module.nesting` order is not something anyone reasons
  about until it bites; root-qualify (`::Lain::Sensitivity`) at such a site.
- **`pre-commit` exports `GIT_INDEX_FILE` into every hook**, so a spec fixture that shells to
  `git` without scrubbing builds against *lain's* index. It passes in every normal run and fails
  only at commit time. Thirteen examples in one card were exposed; only the one that *commits*
  failed loudly. Scrub the wider set, not just `GIT_DIR` — a command-line `--git-dir` already
  beats that one, while `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_CONFIG_*`
  are the ones that actually redirect git.
- **Mutation harnesses lie by default here, and same-size mutants are the NORM.** `20`→`10`,
  `<=`→`<` and `min_by`→`max_by` are all byte-identical in length, so they collide with
  bootsnap's `(mtime-seconds, size)` iseq key and run against **stale bytecode** while `git diff`
  reads clean. Stamp a unique mtime per write (`File.utime`); assert each mutant applied exactly
  once and still parses; score on the failure COUNT, never a string prefix (`start_with?("4")`
  relabels everything once the example count crosses a digit boundary); use literal fixtures and
  exclude the subject from any corpus that scans it. **Wrap the run in `ensure`** — two agents in
  one chunk died mid-run leaving a live mutant in the tree, caught by re-reading the file rather
  than by any test. And **never park the harness in `spec/support/`**: `spec_helper.rb` globs
  `support/**/*.rb`, so it loads in every worker of every run — one defined `Object#run` globally
  and called `Dir.chdir` at load.

  **And make the harness refuse to score when it measured nothing — refusing a MISSING count is
  only half of it.** Learned twice in one day, 2026-08-19. First half: a run invoked outside its
  toolchain wrapper printed every structural line it was built to print — "mutant applied",
  "restored", "identical: yes" — while every `rspec` line came back EMPTY, because the interpreter
  was wrong. Structure without measurements reads as a pass at a glance, and the blank `examples`
  fields were the only tell. Second half, found when that very guard let its own author through: a
  mutant that broke class *definition* made rspec load nothing and print a perfectly real
  `0 examples, 0 failures`, which satisfies "a count line was produced" and still measures nothing.
  **A mutant that does not load is not a surviving mutant, it is an unrun one**, and it scores as a
  kill unless the harness says otherwise. Third door, and it subsumes the other two: a count line
  that is real, non-zero and **SHORT**. A `SystemExit` or a load-order truncation yields
  `22 examples, 0 failures` where the baseline was 32, which reads as *"the mutant survived"* rather
  than *"half the file never ran"* — the same truncation trap recorded above, wearing a mutation
  harness. **So the rule is not "a count was produced" but "the count EQUALS the baseline count"**;
  capture the baseline once before mutating and compare against it every run. This is the stale-bytecode
  confident-green above, arriving through two more doors — and the same shape as a script that
  asserts its anchor EXISTS without asserting its edit APPLIED, which is how this very paragraph
  failed to land the first time it was written.
- **A generic filename in a shared scratchpad is shared mutable state between concurrent agents.**
  One agent's `run.sh` toolchain wrapper was overwritten by another and silently repointed at a
  *different worktree*; commands kept running and kept passing, against someone else's checkout.
  The measurement it produced — four mutants all "caught" — was taken against unedited files and
  proved nothing, and it surfaced only when a substring replacement failed on a file that had just
  been read. Name scratch files uniquely, and have a runner refuse to start unless a file it owns is
  present (`test -f .handback-T<id>.md || exit 1`). The failure mode is not a crash; it is a
  confident green from the wrong tree.
- **Do not read the tree while a suite run is in flight.** Under `rake pspec` a read can return
  content without edits that are already on disk. Twice in one task this looked exactly like the
  live-mutant signature above; `git status` and a re-read after the run exited confirmed disk was
  correct both times. Re-check after the run, not during.
- **`ls-files` truncates against the PROCESS directory**, so a home-repo surface read from a
  subdirectory is both short and rejoins to the wrong file. `-C <dir>` is the fix; `--full-name`
  is not sufficient.
- **A `SystemExit` inside an example truncates the run and still reports "0 failures".** Thor
  turns a refusal into `exit(1)` and RSpec does not rescue `SystemExit` inside an example — one
  regression took a file from 32 examples to 22 while reporting a clean pass, and the truncation
  point moved with the seed. Under `parallel_rspec` that is indistinguishable from the OOM-kill
  shape above. Pass `debug: true` to any Thor `.start` in a spec, and check the example COUNT.
- **The known load-induced flakes, by name** (2026-08-18; all pass in isolation, all driven by real
  `git`/`tmux`/`nvim` under a loaded box — see the TMPDIR note above before believing any of them):
  `Lain::Frontend::Neovim ... re-attach is idempotent: no duplicate commands, and
  motions/syntax still work`; `Lain::Frontend::Neovim the review thread pane following the cursor
  does not re-place the diff on every further move once it is back`; and
  `isolation/worktree_handback_spec`'s `Dir.mktmpdir` teardown racing git maintenance.

  Added 2026-08-19, and it is a SECOND example in that same file rather than the teardown shape
  above -- which is why the entry above was not enough to recognise it:
  `Lain::Isolation::Worktree::Handback a conflicted path git would otherwise quote names
  "we\nird.txt" as it is on disk, and can conclude it`. Reproduced deliberately (2 of 2 full
  `rake pspec` runs at 14490 examples, 11 `nvim` processes live from other worktrees; run 2 red,
  green in isolation). It surfaced during a chunk that never touched isolation, and cost a card an
  unexplained red it recorded rather than smoothed over -- the cheapest possible outcome, but only
  because the count reconciled (+5, exactly the examples that card added) so truncation was ruled
  out first.

  **The `up_spec` entries are RETIRED as of 2026-08-18 -- both had real causes and both are fixed.**
  Recording that here because a stale "known flake" is worse than none: it reads "not a regression"
  to the next person who sees them red. `threads -- chat args ...` and `leaves the global theme
  untouched ...` were **independent witnesses** of one production defect -- `keep_failed_pane` wrote
  `remain-on-exit` as the LAST thing `configure_session` did, four tmux calls after the pane was
  already running chat, so the fastest crashes died into a window with no option yet and took the
  server with them (9 losses in 20 forced repeats; 0 after). They failed as a RAISE with
  distinguishable messages, `no server running` and `no such session: lain`, which is how the two
  were told apart. `--nvim cockpit splits ...` was a *different* defect: a lossy `split` that made a
  dead pane's cwd read back as the pane's own command string. `leaves the global theme untouched`
  additionally had a second cause -- a scratch `-L` server still sources the user's `tmux.conf`,
  whose background `tpm` rewrites global `status-right` at 300-500ms -- now pinned with
  `-f File::NULL`.

  A live demonstration of why this list is by NAME rather than by line: `buffers_spec.rb:329` was
  recorded by line in an earlier chunk, and one card in this one moved that same example to `:417`
  by adding 88 lines above it.

- **Record a flaky spec by NAME, never by line number.** The four first recorded as
  `cli/up_spec.rb:115`/`:175` drifted within days — one chunk grew that file by 454 lines and the
  live failure moved to `:166`. A stale line number is worse than no list: it reads as "not a
  known flake" and sends the next reader hunting a regression that is not there.
- **Never name a `.toml` explicitly on a `rubocop` command line.** `rubocop -a lib/lain/prompt/default.toml`
  parses it as Ruby and "corrects" it — it silently stripped `format = ` from the prompt format.
  A bare `bundle exec rubocop` (and so `pre-commit run --all-files`) is safe: the default
  `Include` patterns do not match `.toml`. **An `Exclude` entry does not save you** — verified:
  `AllCops: Exclude` governs RuboCop's own file *discovery*, not a path a human hands it
  directly, so the file is still parsed when named. The only defence is not naming it.
