# Releasing the GVL around Ext::AstGrep.search (T10)

Status: done. Phase 1 (build, correctness, crashes, unsafe) and phase 2 (timings) both taken. Nothing lands.
The route is the user's ruling (Open decisions in `planning/specs/rust-hot-paths.md`); the last section is that ruling.

Main was 47bf381d. The prototypes live in the spike worktree `tmp/worktrees/T10` (branch `spike/T10`), under
`planning/gvl-release-research-2026-10/`: `spike.diff` (Cargo.toml, astgrep.rs, lib.rs), `gvl_spike.rs` (all 3 routes,
94 lines), `correct.rb`, `behave.rb`, `async_off.rb`, `async_stop.rb`, `phase2_time.rb`.

The pure part is `astgrep::search_cancel(src, lang, pattern, &AtomicBool)`: the same as `search`, plus a cancel check
between matches. It is wired as `AstGrep.search_own`, `search_luc` and `search_offload`.

## Headline

- All 3 routes cut the main thread's p99 stall during a 500-file search from 25.5 ms to 1.09 ms (ratio 0.043). That
  is about 24 ms less, and it is the only large gain.
- No route cancels early. Cancel is about 4% faster (about 40 ms of 900+), because every route still waits for the
  whole call.
- Per-call cost on a real file is not distinguishable from today. On a tiny source only offload has a real cost, about
  1 microsecond on a 10 microsecond call.
- Unsafe: lucchetto 0 in repo text, own wrapper and offload 5 keywords each (about 45 lines).

## Phase 2: timings

Harness: `tmp/bench-stats` (README there), plan `plans/gvl.rb`, run `gvl-20261021-120010` (NDJSON in
`tmp/bench-stats/results/`). 320 trials, 20 per arm per measure, 1 fresh process each, with a random 0 to 4,095 byte
environment pad and a random cwd length, arm order shuffled per round, the arms nice'd 10 and holding the bench lock.
The box was not idle: load average 1.0 to 2.2 at the 1 minute mark (4.7 at the start, 2.7 at the end, 5 minute figures),
and no suite was running (busy count 0, no BUSY warnings). Every arm of every measure computed the same digest.

Bar for `REAL` (README): p_holm < 0.01, the bootstrap CI of the ratio excludes 1, and |HL shift| exceeds the layout
spread (the larger arm's pad-bucket spread). Holm runs over 12 comparisons. Ratio is treatment median over `search`
median, below 1 is faster.

Command for all of it: `tmp/bench-stats/bench.sh plans/gvl.rb`. Report again from the file with
`tmp/bench-stats/bench.sh --stats tmp/bench-stats/results/gvl-20261021-120010.ndjson`.

### Main thread tick, p99 gap between 1 ms sleeps while a thread searches 500 files (ms)

| arm | median | ratio vs search | CI95 | HL shift | Cliff | p_holm | verdict |
|---|---|---|---|---|---|---|---|
| search (today) | 25.457 | | | | | | |
| search_luc | 1.088 | 0.043 | [0.041, 0.044] | -24.34 | -1.00 | 1.7e-10 | REAL |
| search_own | 1.083 | 0.043 | [0.041, 0.043] | -24.36 | -1.00 | 1.7e-10 | REAL |
| search_offload | 1.092 | 0.043 | [0.041, 0.043] | -24.36 | -1.00 | 6.8e-07 | REAL |

The 3 routes are the same to within 0.01 ms, and every route trial (60 of 60) sat below every `search` trial (Cliff
-1.00). Layout spread is 1.27 ms for `search` and under 0.04 for the others, so the 24 ms shift clears the layout guard
by 19 times. A 1 ms sleep floors at about 1.08 ms, so the routes leave the main thread unstalled.

### Per-call cost

File source, median ms per call:

| arm | median | ratio | CI95 | HL shift | p_holm | verdict |
|---|---|---|---|---|---|---|
| search | 0.678 | | | | | |
| search_luc | 0.673 | 0.992 | [0.954, 1.019] | -0.007 | 0.489 | not shown |
| search_own | 0.673 | 0.992 | [0.956, 1.019] | -0.006 | 0.489 | not shown |
| search_offload | 0.664 | 0.980 | [0.945, 1.015] | -0.011 | 0.297 | not shown |

All 3 CIs hold 1, and the shifts (0.006 to 0.011 ms) are under the 0.044 ms layout spread. No cost on a file.

Tiny source (`def a(x); end`), median ms per call (the harness prints 3 decimals, so every arm reads 0.010):

| arm | ratio | CI95 | HL shift | Cliff | p_holm | verdict |
|---|---|---|---|---|---|---|
| search_luc | 1.058 | [1.026, 1.095] | +0.000 | +0.77 | 1.6e-04 | not shown |
| search_own | 1.047 | [1.016, 1.089] | +0.000 | +0.74 | 2.1e-04 | not shown |
| search_offload | 1.084 | [1.042, 1.100] | +0.001 | +0.82 | 5.5e-05 | REAL |

The effect is about 0.5 to 1 microsecond a call. Luc and own pass p_holm and the CI test but not the layout guard
(shift 0.0004 ms against a spread of 0.0005 to 0.0007 ms), so I read them as a small possible cost that the harness
cannot separate from layout. Offload clears all 3. The ratios all have CIs above 1, so I would not call the cost for
luc and own zero either; it is at most 9% of a call that costs 10 microseconds.

### Cancel wait, `Thread#kill` 50 ms into a whole-tree search, then join (ms, timed from when the kill was meant to land)

| arm | median | ratio | CI95 | HL shift | Cliff | p_holm | verdict |
|---|---|---|---|---|---|---|---|
| search | 944.9 | | | | | | |
| search_luc | 908.1 | 0.961 | [0.947, 0.987] | -40.7 | -0.79 | 3.7e-05 | REAL |
| search_own | 906.2 | 0.959 | [0.938, 0.985] | -40.3 | -0.76 | 5.8e-05 | REAL |
| search_offload | 909.5 | 0.963 | [0.949, 0.988] | -39.5 | -0.78 | 5.5e-05 | REAL |

The difference is real by the README bar (layout spread 38.1 ms for `search`, shift 39.5 to 40.7 ms, a margin of
1.4 to 2.6 ms, so the clearance is thin). But 905 of 945 ms means every route ran the whole call before the kill landed.
The 40 ms is not an early cancel. My reading is that it is the main thread getting its 50 ms wake-up on time once the
GVL is free, which `search` cannot do. I did not test that.

This matches the phase 1 reason: parse and pattern build run first and are not interruptible (ast-grep-core exposes no
progress callback), and the cancel flag is checked only between matches. A kill 50 ms in waits out the parse on all
3 routes. lucchetto has no unblocking function at all.

### Not remeasured in phase 2

The Async reactor case (a call made on the reactor thread with `ASYNC_SCHEDULER_WORKER_POOL=true`) is not in
`plans/gvl.rb`. The phase 1 numbers stand, taken on a loaded box: reactor ticks during the call were 0 / 0 / 0 for
search / search_own / search_offload with the pool unset, and 0 / 0 / 1222 with the pool on. Rerun with
`ASYNC_SCHEDULER_WORKER_POOL=true bundle exec ruby planning/gvl-release-research-2026-10/phase2_time.rb reactor 500`
in the worktree if the offload route is chosen.

## Phase 1: build, correctness, crashes (summary)

Build:

| route | builds | notes |
|---|---|---|
| lucchetto 0.4.0 | yes, clippy `-D warnings` clean | resolves to the locked rb-sys 0.9.130 and magnus 0.9.1; Cargo.lock adds lucchetto, lucchetto-macros, paste 1.0.15, static_assertions 1.1.0. `cargo deny check`: error `unmaintained` for `paste`, warning no license field on both lucchetto crates (a LICENSE file says MIT). |
| own wrapper | yes | needs `rb-sys = "=0.9.130"` as a direct dep (already locked) and magnus feature `rb-sys` |
| rb_nogvl OFFLOAD_SAFE | yes | same code as own, flag 0x4 |

Correctness: `bundle exec ruby planning/gvl-release-research-2026-10/correct.rb` printed `files=953 patterns=4
total_matches=11522 all 3 routes equal` (every `lib/**/*.rb`, 4 patterns, `==` against today's `search`). BadPattern and
ArgumentError raise the same classes on all 3. The GVL is really released on all 3: a second Ruby thread counted about
1.5e8 increments during one whole-tree call, against 0 during today's `search`.

Crashes and hazards:

- lucchetto as shipped aborts the VM on a panic: `AstGrep.search_luc("x","ruby","__PANIC__")` gives "panic in a
  function that cannot unwind", exit 134, with the Ruby C backtrace. It has no `catch_unwind`. A `catch_unwind` in our
  own function body fixes it (done in the prototype; then RuntimeError, VM alive). Without that line this route is out.
- own and offload catch the panic inside `run_job` and raise RuntimeError "search panicked". The default panic hook
  still prints to stderr, which is a stray line in the cockpit (output discipline); a `panic::set_hook` would be needed.
- `Thread#kill` and `Thread#raise` land when the call returns. The own wrapper runs the call under
  `magnus::rb_sys::protect` so the Rust frame unwinds normally. No crash in kill or raise tests on any route. A
  `Thread#raise` into a thread inside the call arrives as IOError on own and lucchetto.
- lucchetto's `GvlSafe` is a marker trait; a `Result<Vec<Match>, _>` return needed a one-line `impl GvlSafe` newtype, so
  its safety check is advisory.

Async (Ruby 4.0.6, async 2.46.0, io-event 1.22.1):

- `Async::Scheduler` defines `blocking_operation_wait` only when built with a worker pool, and the default pool is on
  only if `ASYNC_SCHEDULER_WORKER_POOL` is the string `true`. Lain sets neither (`grep worker_pool lib` is empty). With no
  pool, `RB_NOGVL_OFFLOAD_SAFE` behaves as route 2 and the reactor is held.
- `Tool::Offload` calls from a fresh `Thread`, which has no scheduler, so the flag changes nothing there. Route 3 helps
  only if the call is made on the reactor thread directly (replacing `Offload`) with the pool on.
- With the pool, `task.stop` returns in about 1 ms but the child fiber's `ensure` runs only after the whole call ends.
- The call runs on a pool thread, so the thread-local `PATTERNS` cache is cold per worker thread.

## Unsafe the repo would own, and the rules

| route | `unsafe` keywords in repo text | lines |
|---|---|---|
| lucchetto | 0 (the macro expands unsafe in our crate) | about 12 for the wrapper, plus a `catch_unwind` we must remember |
| own wrapper | 5: 2 `unsafe extern "C" fn`, 2 deref blocks, 1 `rb_nogvl` call, each with a SAFETY comment | about 45 of the 94 |
| rb_nogvl OFFLOAD_SAFE | same 5 (shared code, flag differs) | +1 line |

`ext/lain/CLAUDE.md` says do not hand-roll new unsafe, reach for a crate, and the crate has 15 existing `unsafe {`
blocks. Route 1 follows that on the letter but the crate is unmaintained since 2023, pulls `paste` (a `cargo deny`
error) and omits `catch_unwind` and an unblocking function. Routes 2 and 3 break the rule. The fiber rule holds on all 3:
every Ruby argument is read and copied before the call, Ruby objects are built after, and nothing in the region touches
a VALUE.

## The 5 binding tests (docs/rust-bindings.md)

`AstGrep.search` already passes them as a binding. The question here is whether a GVL release changes the answer.

| test | all 3 routes | route-specific |
|---|---|---|
| 1 pure, synchronous | yes; the pure part is unchanged | offload moves the call to a pool thread, so it is no longer called on the caller's thread |
| 2 Ruby's object model makes it worse | no new case; the gain is a stall, not an asymptotic gap | n/a |
| 3 hot per turn | yes, a search tool call runs per turn | n/a |
| 4 batches | yes, 1 crossing per source; unchanged | n/a |
| 5 corpus and mutation gate | `correct.rb` (11,522 matches) is a differential check, not the frozen corpus; a new cancel path needs a `cargo-mutants` baseline update | own and offload add about 45 lines of unsafe to mutate and test; lucchetto adds about 12 |

Test 2 is the weak one. The stall is real (24 ms p99) but it comes from the GVL, not from Ruby's object model, so the
case for any route rests on responsiveness, which `rust-bindings.md` says a benchmark checks but never justifies. I read
that as a reason to take the smallest route or none.

## The decision the user owes

Which route, or none. No card depends on it.

1. **None.** Keep `search` as is. Cost: the main thread stalls about 25 ms at p99 while a 500-file search runs. No new
   unsafe, dependency or cargo-deny change. Right if the stall is not felt in the cockpit.
2. **lucchetto.** Gets the full 24 ms gain with 0 unsafe keywords in the repo and about 12 lines. Costs: an unmaintained
   crate (2023), `paste` in Cargo.lock with a `cargo deny` error that needs a named exception in its own commit, a
   mandatory `catch_unwind` that nothing enforces, and no unblocking function, so early cancel can never come from this
   route (it would need a swap to option 3). Meets the "reach for a crate" rule on the letter.
3. **Own wrapper over `rb_thread_call_without_gvl`.** Same gain. About 45 lines and 5 unsafe keywords in the repo,
   which breaks the no-hand-rolled-unsafe rule and needs the user to waive it. Gives an unblocking function and a
   cancel flag, but cancel is worthless until the parse can be interrupted, which ast-grep-core does not allow. No
   dependency risk.
4. **`rb_nogvl` with `RB_NOGVL_OFFLOAD_SAFE`.** Same cost as option 3, plus a real 1 microsecond per call, plus an
   unmade change: `Tool::Offload` would have to be replaced by a call on the reactor thread, and Lain would have to set
   `ASYNC_SCHEDULER_WORKER_POOL=true`. Without both, it measures the same as option 3 and the flag does nothing. Only
   route with a reactor-side win, and it was not remeasured on the quiet box.

## Recommendation

Option 2 if the stall matters, otherwise option 1. The 3 routes tie on the only gain that exists (0.043 of today's
p99), none improves cancel, and per-call cost on a file is flat, so the choice is the cheapest cost to the repo. That is
lucchetto: no unsafe text, 12 lines, and the rule met on the letter. It must ship with the `catch_unwind` line, a
spec that the panic does not abort the VM, a `deny.toml` exception for `paste` in its own commit saying why, and a
`cargo-mutants` baseline update. If early cancel ever becomes a goal, that is a separate decision that needs the parse
interruptible first, and it would move to option 3. I would not take option 4: it needs two changes outside the
bindings and its payoff is untested on a quiet box.

I am not sure whether 25 ms p99 is felt in the cockpit; that is the call the user owes.

## Follow-up: early cancel, and the ruling (2026-10-21)

The user wanted the GVL released now, because future tools moved to Rust will need the same thing, and asked whether cancel could be made early without unsafe code. The follow-up below answers that. "The parse is not interruptible" above is wrong: tree-sitter 0.27 has a safe progress callback, and ast-grep-core 0.45.3 exposes enough to parse with our own parser. The user ruled to allow 1 unsafe block (the `rb_nogvl` call), and card T17 in `planning/specs/rust-hot-paths.md` carries it out.


Date 2026-10-21. Versions locked in Cargo.lock: magnus 0.9.1, rb-sys 0.9.130, ast-grep-core 0.45.3, tree-sitter 0.27.0.
Prototype: `tmp/cancel-proto/` (crate `src/lib.rs`, 109 lines; harness `time.rb`).

### 1. Safe GVL release in a crate

- magnus 0.9.1 and latest 0.9.3 (2026-10-16): no GVL API. `lib.rs` lists `rb_nogvl` and `rb_thread_call_without_gvl`
  in its "not wrapped" comment block (lines 1127 and 1521, same in 0.9.3).
- magnus PR 171 "Add functions for modifying GVL" (open, https://github.com/matsadler/magnus/pull/171), issue 129
  (open, https://github.com/matsadler/magnus/issues/129): `Ruby::without_gvl(F: Send + FnOnce)`. It passes
  `None` as the unblocking function and has no `catch_unwind`. So even if merged it gives a safe release with no cancel and
  no panic guard. Not released.
- rb-sys 0.9.130: raw `rb_nogvl` and `rb_thread_call_without_gvl` bindings only.
- lucchetto 0.4.0 (2023-10-10): `None` unblocking function, no `catch_unwind` (phase 1 finding).
- Hand-rolled copies elsewhere, none with an unblocking function: wasmtime-rb `nogvl.rs`
  (https://github.com/bytecodealliance/wasmtime-rb/blob/main/ext/src/helpers/nogvl.rs), oxidize-rb docs recipe
  (https://oxidize-rb.org/docs/development-approaches/).
- Not found by web search: any maintained crate with an unblocking function. Searches are not exhaustive.

### 2. Early cancel inside the libraries

- tree-sitter 0.27.0 (what ast-grep-language 0.45.3 resolves): `Parser::parse_with_options(..., Some(ParseOptions::new()
  .progress_callback(|state| ControlFlow::Break(())))`. Safe API. The old `set_cancellation_flag` is gone; ast-grep's
  docs still mention it.
- ast-grep-core 0.45.3 does not expose it: `parse_lang` and its thread-local `PARSER_CACHE` are private, `Root` is a private
  name. But `AstGrep::doc(doc)` is public and `StrDoc { src, lang, tree }` has public fields, so we parse with our own
  `Parser` and build the doc ourselves. No fork needed.
- Matching is `root().dfs()` plus `pattern.match_node(node)` (`MatcherExt`, public). We own the loop, so the flag is checked
  every 64 nodes. `find_all` can only be interrupted between matches (phase 1 boundary). Same 8037 matches as `find_all`.
- Ruby side: `Thread#kill`, `Thread#raise` and `Async` stop reach a thread inside a nogvl call only through the unblocking
  function. Without one they land after the call returns.

### 3. Least-unsafe design

GVL released with `rb_nogvl`, unblocking function stores into an `AtomicBool`, parse progress callback and a node-loop check
read it, `catch_unwind` around the pure search, `magnus::rb_sys::protect` around the call so a kill unwinds cleanly.

Trick that removes the pointer derefs: the `void*` carries a slot INDEX (a safe `usize as *mut c_void` cast). Two callbacks
are plain safe `extern "C" fn`s that index `static CANCEL: [AtomicBool; 64]` and `static JOBS: [Mutex<Slot>; 64]`. A
`TAKEN` array hands out slots with `compare_exchange`. Cost: a fixed concurrency cap (64 searches at once, else an error).

Unsafe count: 1 `unsafe` block, 1 line, the `rb_nogvl` FFI call itself. A call into a C function declared by rb-sys is
`unsafe fn`, and nothing in 0.9.x wraps it. The earlier own-wrapper spike had 5 keywords; this has 1. If magnus PR 171 lands
with an unblocking function parameter, the count goes to 0. Pointer derefs, the actual hazard, are 0.

Hazards left (not unsafe, still real): a poisoned `JOBS` mutex `unwrap()` inside the `extern "C" fn` would abort the VM, so
use `lock().unwrap_or_else(PoisonError::into_inner)`; the panic hook still prints to stderr (set a hook); the parser cache
(`Parser::new` per call in the prototype) must be rebuilt as a thread-local to keep per-call cost.

### 4. Measurement

Command (T10 root, quiet box, load 1.2, `nice -n 10 flock /home/tara/tmp/lain/bench.lock`):
`bundle exec ruby tmp/cancel-proto/time.rb`. Same shape as phase2 cancel: kill a thread 50 ms into a whole-tree
(7,839,567 byte, `lib/**/*.rb` joined) search, join, time from the intended kill. 5 runs each.

| check boundary | median ms | runs |
|---|---|---|
| parse progress callback and every 64 nodes | 2 | 2, 2, 2, 3, 2 |
| between matches only (phase 1 boundary) | 889 | 868, 897, 818, 889, 889 |
| none | 993 | 996, 993, 943, 966, 997 |

Kill at 5 ms (inside the parse): median 0 ms (7, 0, 0, 0, 7). `Thread#raise` into the call gave IOError and the VM stayed
alive. Pure Rust split: 932 ms total, 820 ms of it is the parse, so the parse callback is what makes early cancel possible
at all; 889 against 907 reproduces the old result. Match counts equal `Lain::Ext::AstGrep.search` (8037).

### Unverified

- A real per-file search (about 15 KB) finishes in under 1 ms; the 2 ms win matters for big inputs and whole-tree loops,
  and I did not measure per-call cost of the new path (own parser, no cache) against `search`.
- Tool::Offload integration, Async reactor `task.stop` (needs the worker pool), and the stray-stderr panic hook.
- A panic inside the prototype was not exercised; `catch_unwind` is present, as in the phase 1 spike.
- Progress callback granularity on pathological grammars (it is called per parse step, not per byte).
- Slot cap behaviour under 64 concurrent calls; `cargo-mutants`/clippy/`cargo deny` were not run on the prototype.
