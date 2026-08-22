# Spec-suite performance

Everything here is a *measurement*, not a rule. It lives out of `CLAUDE.md` because it is
long, box-specific, and only needed when someone is about to change how the suite runs.
Read it before proposing a worker count, sharding a spec file, or optimising allocations —
each of those has already been tried here and the answer was counter-intuitive.

Headline rules, restated in `CLAUDE.md`:

- `bundle exec rake pspec` is THE suite command.
- `LAIN_SPEC_WORKERS=12` is the measured optimum **on this box**; `physical - 1` is the worst
  count tried.
- The wall is a MAX over files, not a sum — sharding a spec to game the packer is forbidden.
- Allocation cost is a per-worker BOOT cost, not a per-example one.

## Why `pspec` and not `rspec`

The suite is subprocess-bound, not CPU-bound: **57s user against
119s *system*** (2026-08-05, 10865 examples), because the isolation, forge, review and frontend
specs drive real `git` and real `nvim`/`tmux`. Those are the subjects under test, so the cost is
not removable -- but it parallelises. Serial **197s**; `rake pspec` **21-27s**. That 1:2 user-to-
system ratio has held while the suite doubled in size, which is the mechanical statement of
"the work is spawning, not computing".

## What binds, and why more workers than cores helps

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

## The wall is a MAX, not a sum

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

## Profile first, and read the answer as a signpost

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

## Allocations and GC are a BOOT cost, not a per-example one

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


## Appendix: how `rake spec:flakes` is built

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
construction — the TMPDIR note in `docs/toolchain-traps.md`, four lanes deep), and each run sets `$PROGRAM_NAME` to
rspec's own argv-zero. That second one is not cosmetic: `Configuration#files_or_directories_to_run=`
appends the `spec` default path only when `$0` basenames to `rspec` (without it the hunt loads no
spec files and reports a confident green over zero examples), and `CLI::Up::PreFlight` expands a
relative executable to an absolute path while `up_spec`'s spy compares the raw `$PROGRAM_NAME` —
10 examples failed in every run, from the harness rather than from the suite.
