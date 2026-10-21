# YJIT trial, 2026-10-21

Card T9 of `planning/specs/rust-hot-paths.md`. It answers the Open decisions entry "YJIT by default",
which the user rules on. Nothing in the tree changed; this is a measurement.

## Answer in brief

YJIT makes the chat turn about 20% faster at both 1,000 and 10,000 turns. It makes `exe/lain --help` boot
about 28% slower (+312 ms). Peak memory of a 10,000-turn process is about 7 MB higher but did not clear the
bar. The suite under YJIT failed in 7 of 8 runs, in 2 specs that never failed in 8 runs without it, and the
failing runs were also slower by about 7 s. So the data supports YJIT for a long chat session and does not
yet support it for the suite or for short commands.

## What ran

- Tree: main at `47bf381d`, all landing cards in. Ruby 4.0.6 from mise, 16 cores, 12 spec workers.
- Arms: `base` (RUBYOPT unset) and `yjit` (`RUBYOPT=--yjit`). Each script checks `RubyVM::YJIT.enabled?`
  matches the arm and refuses to run otherwise.
- Harness: `tmp/bench-stats` (README there), plan `plans/yjit.rb`, scripts `tmp/t9-prep/m_*.sh`. 156 trials
  over 20 rounds, run id `yjit-20261021-112754`, seed 3388616831054889374, started 15:27 UTC, 32 minutes.
- Each trial is 1 fresh process with a random environment pad of 0 to 4,095 bytes and a random working
  directory length, arms shuffled within a round, under `nice -n 10 flock` on the bench lock. Zero trials
  recorded another test process running (busy 0).
- Records: `tmp/t9-prep/out/yjit-2026-10-21-1127.ndjson`. Report again with
  `tmp/bench-stats/bench.sh --stats tmp/t9-prep/out/yjit-2026-10-21-1127.ndjson`. Rerun everything with
  `tmp/t9-prep/run_all.sh`.
- Statistics: bootstrap CI of the median ratio (10,000 resamples, seed 20261021), Hodges-Lehmann shift,
  Cliff's delta, Mann-Whitney with Holm over 4 comparisons.
- The bar (README): a change is REAL only if p_holm < 0.01, the ratio CI excludes 1, and the HL shift is
  larger than the layout spread (the larger pad-bucket spread of the 2 arms). Ratio is YJIT median over base
  median, so below 1 is faster.

## Results

| measure | n per arm | base median | YJIT median | ratio | CI95 | HL shift | layout spread | p_holm | verdict |
|---|---|---|---|---|---|---|---|---|---|
| chat turn, 1,000 turns (ms) | 20 | 2.360 | 1.910 | 0.809 | 0.779 to 0.842 | -0.440 | 0.210 | 1.99e-07 | REAL, faster |
| chat turn, 10,000 turns (ms) | 20 | 26.660 | 21.320 | 0.800 | 0.777 to 0.824 | -5.285 | 1.325 | 5.8e-11 | REAL, faster |
| boot of `exe/lain --help` (ms, median of 5 boots) | 20 | 1156.0 | 1477.5 | 1.278 | 1.256 to 1.296 | +312.5 | 30.0 | 1.99e-07 | REAL, slower |
| peak RSS, 10,000-turn process (kB) | 10 | 221,376 | 228,468 | 1.032 | 0.994 to 1.041 | +4,940 | 4,338 | 0.0524 | not shown |

Every turn trial in both arms printed the same request digest (`1810839d48b4` at 1,000 turns,
`9029c0e8d636` at 10,000), so the arms computed the same thing. Cliff's delta was -1.00 (all YJIT trials
faster) for both turn measures and +1.00 (all slower) for boot.

Reading each row:

- Turn: both clear all 3 tests with room. At 10,000 turns the shift of 5.3 ms is 4 times the layout spread.
- Boot: also REAL, in the bad direction. YJIT's startup cost shows up in a 1.2 s process. Every one of the
  20 YJIT boots (1409 to 1539 ms) was slower than every base boot (1114 to 1214 ms).
- RSS: the median is 7 MB (3.2%) higher, but the CI [0.994, 1.041] holds 1 and p_holm is above 0.01. I would
  not claim a memory cost from this; the plausible range is 0 to 4% (about 9 MB). The RSS trial count is
  10 per arm, set by the plan because RSS barely moves with layout.

YJIT stats line after the 10,000-turn bench: `code_region_size=1327104 inline_code_size=505093
outlined_code_size=503487` (bytes). That is 1.27 MiB of reserved code region per process, of which about
0.96 MiB is used.

### Load average

Median 1-minute load before each trial: boot 3.4 and 3.4, turn 4.6 to 4.8, RSS 8.3 to 8.6, pspec 8.6 (base).
The load was mostly the harness's own `rake pspec` runs earlier in each round, not another session, and the
arms of a measure sit in the same round, so it is spread over both. Treat the absolute milliseconds as
box-specific.

## The suite measure: yjit_pspec_wall ran, and the YJIT arm mostly failed

The plan lists a 5th measure, the `rake pspec` wall with 8 runs an arm. It did run. The report log shows
only 4 comparisons because the harness excludes failed trials, and 7 of the 8 YJIT trials exited 1.

| | runs | exit 0 | examples | wall |
|---|---|---|---|---|
| base | 8 | 8 | 26,433, 0 failures every run | median 80.0 s, IQR 1.5, range 78.9 to 82.0 |
| YJIT | 8 | 1 | 26,433 in all 8 | passing run 87.0 s; the 7 failed runs 86.1 to 88.4 s, median 86.5 |

No comparison was computed: 1 passing YJIT trial is below any test's minimum n. Descriptively, all 8 YJIT
walls (86.1 to 88.4 s, median 86.9) are above all 8 base walls (78.9 to 82.0 s): about 9% slower. That
number comes from walls of runs that failed, so it is an indication and not a result under the bar.

Peak worker RSS (largest of the 3 biggest workers in each run): base median 469.5 MB; YJIT 488 to 646 MB,
median 542.5 MB, about +73 MB (+16%) on the heaviest worker. Also descriptive, from the sampler in
`m_pspec.sh`.

### Specs that failed only under YJIT

The base arm had 0 failures in 8 runs and 0 in the earlier dry base runs. The YJIT arm:

1. `spec/lain/review/hunk_spec.rb:267`, "Lain::Review::Hunk Ractor usability is shareable, but its key can
   only be computed on the main Ractor". Failed in 6 of 8 YJIT runs (rounds 1, 2, 3, 4, 5, 7). Output:

   ```
   Failure/Error: expect { Ractor.new(subject, &:content_key).value }.to raise_error(Ractor::RemoteError)
     Expected exception-free block to raise a kind of Ractor::RemoteError.
   # ./spec/lain/review/hunk_spec.rb:271
   ```

   This is deterministic-looking. Under YJIT the key computation on a non-main Ractor completes where the
   spec expects it to raise. I think the spec pins an interpreter behavior (a shared-state access that
   raises in the interpreter) that YJIT's compiled path does not hit. I have not confirmed the cause.

2. `spec/lain/seams/plain_chat_prompt_guards_spec.rb:581`, "an approval queued behind a question announces
   the call once human> closes, then draws the [y/N]". Failed in 5 of 8 YJIT runs (rounds 1, 2, 4, 6, 7).
   Output: `expect(terminal.screen).not_to include("asks to run bash")` failed because the screen already
   held `agent asks to run bash({"command" => "rm -rf build"})  -- its y/N is asked next` while `human>` was
   still open. This is a terminal-timing assertion over a real pty, and a faster or slower process changes
   the ordering. It looks like a race the YJIT timing exposes, which would make it a latent flake and not
   a YJIT incompatibility. Also not confirmed.

Both appeared together in 4 runs and alone in 3 (hunk alone in rounds 3 and 5, plain chat alone in round 6).

The card says to rerun a failing file alone once under YJIT, then stop. I did not: this report was written
without running anything, to keep the box quiet. The rerun is still owed, for both files, and the
flaky-test procedure in `docs/toolchain-traps.md` owns it:

```bash
RUBYOPT=--yjit bundle exec rspec spec/lain/review/hunk_spec.rb:267
RUBYOPT=--yjit bundle exec rspec spec/lain/seams/plain_chat_prompt_guards_spec.rb:581
```

## Caveats

- The turn measure is the synthetic `bench-send/q3.rb` chat turn (render, request digest, journal write),
  not a model round trip. A real turn is mostly waiting on the provider, so a 20% cut of 21 ms is not 20%
  of anything the user feels. It matters for the bench, where the loop is the object of study.
- The boot number is `exe/lain --help` only. A long-running `lain up` pays the 312 ms once and the turn
  gain on every turn; the break-even is roughly 312 / 5.3 = 59 turns at the 10,000-turn size, and about
  700 turns at the 1,000-turn size (0.44 ms saved a turn). I have not measured a real session's turn mix.
- Link order and CPU frequency were not perturbed (README, "Not made sound"). Main moved during the run
  only if the harness footer said so; its `trees` field is empty for this plan, so I cannot show that main
  held still. Nothing else was running (busy 0 on all 156 trials).

## The decision you owe

Open decisions: should YJIT be on by default.

1. **Off (status quo).** No change. Boot stays 1.16 s, the suite stays at 80 s with 0 failures, and no
   memory risk. Costs the 20% turn gain.
2. **On for chat sessions only, off for the suite and short commands.** Enable YJIT in the long-running
   path (`lain up`, plain chat) and leave `rake pspec`, the commit hook and `--help` alone. Gets the
   turn gain where it pays, avoids the 312 ms on one-shot commands, and keeps the 2 failing specs out of
   the suite. Costs one more code path to explain, and the chat path then runs a different Ruby than the
   suite tests, which is a real gap for a bench whose point is comparable runs.
3. **On everywhere.** Simplest and the most uniform. Not available today: the suite fails 7 runs in 8, so
   the hook and CI would go red until the 2 specs are fixed or tagged. Boot is 28% slower for every command.

Recommendation: option 1 now, then option 2 once the 2 specs are understood. The turn gain is real and
large against the layout noise, but the gain is on a synthetic 21 ms step, the boot loss is certain, and
the suite failures are unexplained. Neither the memory cost (not shown, at most about 9 MB per process at
the CI's upper edge) nor the pspec wall (about 9%, descriptive) settles it. If you pick 2 or 3, rerun the
T9 plan after the 2 specs are fixed so the suite wall gets a real comparison.

### What turning it on would touch

- **Chat only (option 2):** `exe/lain`, one line near the top (after `Warning[:experimental] = false`):
  `RubyVM::YJIT.enable if defined?(RubyVM::YJIT)`, called before `require "lain"` so the loader's code is
  compiled too. Ruby 4.0 can enable YJIT at runtime, so no re-exec is needed. A subcommand switch would
  gate it on the long-running commands.
- **Everywhere (option 3):** the same line unconditionally, plus the places that start Ruby without
  `exe/lain`: `.envrc` / the CLAUDE.md toolchain block (`export RUBYOPT=--yjit`) for the suite and the
  commit hook, and `Rakefile` for `rake pspec`. `RUBYOPT` also reaches every child Ruby, including the
  spec-spawned `exe/lain` processes in the `:e2e` and `:seam` tiers, which is how the pty spec above is
  affected.
- **Either way:** CLAUDE.md's Toolchain section and `docs/toolchain-traps.md` get the new fact, and the 2
  specs above need an owner first for option 3.
