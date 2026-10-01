# Spec suite profiling: research

| | |
|---|---|
| Date | 2026-09-30, revised 2026-10-01 after 2 panel reviews |
| Git SHA | 764d4d9b (measured); tools landed in 50570ca4 |
| Branch | main |
| Prior research | `docs/spec-suite-performance.md` (2026-08-05) and the commit history of earlier speed and allocation work, read as a baseline. The mempalace search was declined in this session; the panel reviews supplied 1 result from it (see option 3). |
| Tools | committed: `bin/trace-pspec`, `bin/trace-summary`, `bin/trace-memleak`, `bin/memleak-summary`, `bin/strace-children`, `bin/with-ruby`, `bin/setup-profiling` (50570ca4); uncommitted: `bin/box-state` and fixes to the others |
| Raw data | `tmp/profiling-2026-09-30/` on the measuring box only (gitignored): passes 1 to 4, CI logs and findings, and `report-v1.md` and `report-v2.md` |

## Executive summary

**First, a correctness defect.** `spec/lain/frontend/input_pane_spec.rb` sends real SIGINT and SIGTERM to its own worker process. Under load, the signal can land in RSpec's own SIGINT handler, which stops that worker after its current file and prints a normal summary. About 1,000 examples are then skipped, and the run reports success. It happened in 2 of about 25 full runs here, and CI and `pre-commit` are exposed to it.

**The work.** The suite does about 1,100 worker-seconds of work:
- **Dev box:** a 101s wall at 12 workers, bounded by 1 file of 95s and by total work over 12 workers (92s), both at once.
- **CI:** the last run spent 459s in the suite and about 131s before it, on 4 vCPUs that were not CPU-bound.

**The costs:**
- **Waiting:** fixed sleeps, timeouts and polls, in specs and in `lib`.
- **Process creation:** forking a large Ruby parent costs about 147 worker-seconds at 12 workers, and more at 4, where workers grow to 400 to 575MB.
- **Child Ruby boots:** about 320 per run.

GC, Rust FFI, GVL contention, allocator choice, YJIT and environment isolation each move total work by 3% or less.

**Recommendation:**
- **Fix the truncation first.** It is small and makes every other number trustworthy.
- **Dev box:** then the waits (option 1).
- **CI:** then the build caches and a persisted runtime log (options 9 and 10), which are configuration only.
- **Both:** the `Shell::Out` migration (option 3) after that; it pays most in CI.

## Context

The goal was to find where suite time goes across 6 avenues: allocations, shelling out, setup and teardown, dead code, Ruby to Rust FFI, and inefficient `lib/` code. Nothing in `lib/` or `spec/` was changed; the brainstorm follows review.

**2 audiences, which rank the options differently:**

| | workers | nvim | tmux config | what binds the wall |
|---|---|---|---|---|
| dev box (this machine) | 12 (`LAIN_SPEC_WORKERS`) | mise shim | the user's own, with TPM plugins | the 95s file and total work / 12, about equally |
| CI (`.github/workflows/main.yml`) | 4 (`nproc` on `ubuntu-latest`) | release tarball, no shim | none | total work / 4, plus about 131s of setup |

**How it was measured:**
- **Pass 1:** an in-process probe (spawns, forks, sleeps, allocations and FFI per file, example and call site), plus 27 Sonnet audits of the 60 slowest files.
- **Pass 2:** memory (smaps, `malloc_trim`, bcc `memleak`), `perf`, `strace`, bpftrace kernel counters, a blocking probe, a 1,000-ask session with and without compaction, and randomized A/Bs.
- **Pass 3:** repeats after the first review.
- **Pass 4:** CI logs, a CI-shaped run, YJIT, environment isolation, a serial run with RSS, the truncation hunt, and box state.

**A/B method.** Every A/B runs each variant in fresh processes, interleaved, with a random-length `AB_PAD` variable (0 to 4,096 bytes) in the environment (Mytkowicz et al., ASPLOS 09), and reports a 95% t-interval.
- **Seeds:** passes 2 and 3 reused 1 shuffle seed, so round orders were not independent (in the Ruby-build A/B, `src_glibc` ran last in 4 of 5 rounds). Pass 4 draws a fresh seed per experiment and records it.

**Box state** (pass 4 adds `bin/box-state`, which every A/B checks before each sample):
- **This machine:** a Ryzen 7 3700X (8 cores, 16 threads), 15.9GB, 4GB swap (full).
- **Kernel knobs, unpinned throughout:** THP is `always` (GitHub's Ubuntu runners use `madvise`; measured below to make no difference); the CPU governor is `powersave` with `balance_performance`.
- **Co-tenant:** a mempalace job (`mempalace-probe`, 7h of CPU, 7.6GB peak) ran 06:01 to 13:10 on 2026-09-30.
  - Pass 1's baseline `pspec` (12:53:14 to 12:54:57, the 101s figure) overlapped it entirely.
  - The serial run (12:55 to 13:20) overlapped it for 15 of its 25 minutes.
  - Pass 1's parallel probed run (13:21 to 13:23), which most of pass 1's breakdown rests on, did not.
  - Passes 2 to 4 ran clear of mempalace jobs. In pass 4 the refresh timer was paused for the duration, at the user's choice.

**Caveats:**
- **The probe perturbs what it measures:** pass 1's probed run raised system CPU from 301s to 346s (15%).
- **3 kinds of status:** "measured" is a timed run or a kernel counter; "reproduced" is measured by 2 independent methods; "read" is a Sonnet audit's arithmetic from code and probe data.

## Measured

### Baseline and the wall

| | 2026-08-05 (performance doc) | 2026-09-30 / 10-01 |
|---|---|---|
| examples | 10,865 | 21,508 |
| `pspec` wall at 12 workers | 21 to 27s | 101s (with a co-tenant); 103 to 104s in pass 4's clean A/B baselines |
| total work (sum of workers' "Finished in") | | 1,094s [1,084, 1,105] (pass 4, 5 clean runs) |

**The bound:** wall is about `max(slowest file, total work / workers)`.
- **Dev box:** worker 1 holds `seams/plain_chat_prompt_guards_spec.rb` alone (95.3s); the binding worker in the probed run was worker 8 at 98.4s.
- **Fixing the floor file:** cutting it to about 30s leaves `(1,105 − 65) / 12` = about 87s per worker, so a wall near 90s.

**Concentration** (measured): 225 examples (1%) take 546s, half of all work. 2,027 take 1,026s (93%). The other 19,481 cost about 71s together.

### Where the work goes (pass 1 probe, perturbed run, 1,105 worker-seconds)

| category | seconds | split by caller | status |
|---|---|---|---|
| main-thread `sleep` | 451 | spec 315, spec/support 86, lib 50 | measured |
| Mixlib shellout, blocking | 292 | lib 136, spec 149, support 7 | measured (breakdown below) |
| Open3, blocking | 91 | spec 59, lib 31 | measured |
| in-process CPU (includes the fork syscall) | 290 | | measured |
| child-process CPU | 412 | | measured |
| remainder: wall minus sleep, shellout, Open3 and CPU, with fork counted once | 84 | | derived; v1's 169s double-counted fork and dropped negative examples |
| GC | 30 | | measured |
| GVL wait (pass 4, `gvltools`) | 32 (3.1%) | 8.2 of `status_feed_spec`'s 8.9s; `exec/local_spec` 5.5; `bench/sweep_spec` 4.2 | measured |
| Rust FFI | 12 | | measured |

**Blocking by thread** (pass 4 blocking probe, per call, overlapping fibers counted separately):

| thread | seconds | holds up examples? |
|---|---|---|
| plain main thread | 161 | directly |
| fibers | 209 | only when the example's own fiber waits |
| background threads | 989 | no; idle |

The background total is idle, not cost:
- **Named sites:** the floor files' reader threads (87s and 46s), `Channel`'s queue (34s), the nvim RPC thread (31s and 26s), `streaming_upstream`'s accept loop (34s).
- **Ruby's `Timeout` thread:** the single background thread `timeout.rb` keeps per process, parked between timeouts at `timeout.rb:97` (`Mutex#synchronize`, 371s across 56 files) and `timeout.rb:91` (`Queue#pop`, 311s across 31 files). Idle, not cost. This was confirmed in a second run with standard-library frames named.

### Process creation: fork, not the commands

The durable numbers are also in `docs/spec-suite-performance.md`.

| measurement | fork (Mixlib) | vfork (`Shell::Out`, `Process.spawn`) | status |
|---|---|---|---|
| 1 `git rev-parse`, parent at 98MB RSS | 7.7ms | 1.3ms | measured |
| the same, parent at 371MB RSS | 29.4ms | 1.3ms | measured |
| per git call in worker 8's files (strace, inflated evenly) | 21.2ms: clone 8.2, pre-exec 1.7, exec teardown 8.6, git 2.7 | 2.9ms | measured |
| parent's syscall over a `pspec` at 12 workers (kernel) | 9,740 forks, 74s, 7.6ms each | 12,813 vforks, 3.6s | reproduced (2 traced runs) |
| `execve` into git, including the copied address space's teardown (kernel) | 21,655 calls, 75.1s; about 73s of it in forked children | about 2s | reproduced |
| every git program, exec to exit (kernel) | 21,606 runs, 64s, 3.0ms each | | measured |

**The 292s of Mixlib blocking (12 workers):**

| part | seconds | source |
|---|---|---|
| parent's `clone` | 74 | kernel |
| `execve` teardown in forked children | about 73 | kernel (`@sys_ns[git, 59]`, less the vfork share) |
| child's Ruby work before `exec` | about 17 | strace, 1.7ms per fork |
| the commands running | about 42 | git 8,953 calls × 2.7ms, tmux 564 × 5.2ms, about 15s of long-lived children |
| Mixlib's Ruby-side work before `clone` and after `wait4` (object setup, pipes, output handling), plus the probe's perturbation | about 86 | remainder; reaping is not it: `bin/strace-children` puts exit-to-`wait4` at 0.40ms of a 13.56ms git call (3%) |

**Fork cost follows RSS:**
- **Across worker sizes:** `perf` puts `copy_page_range` and `__zap_vma_range` at about 20% of CPU in fork-heavy files, and copy-on-write faults at 0.4%. Per fork: 8.0, 10.9 and 14.0ms at worker RSS of 100, 200 and 300MB (12 workers).
- **At 4 workers** (CI-shaped run below): 9.2ms at 200 to 299MB, 16.7ms at 300 to 499MB, 19.9ms at 500 to 599MB; 14.8ms mean.
- **One process for every file:** the serial run forked at 33.9ms on average, and fork-heavy files ran 2.7 to 3.6 times faster in parallel than serially. For example, `github_pr_spec` took 79s serial against 24s parallel, `command/review_spec` 59s against 18s, and `shadow_git_spec` 25s against 7s. Only `exec/local_spec` (+4.1s) of files over 2s was more than 30% slower in parallel. Pass 4 repeated the serial run clear of any co-tenant, with RSS per file: 24m09s, 21,508 examples, sum of file walls 1,449s against 1,105s parallel, and 9,493 forks at 32.4ms each (308s). By RSS: 23.0ms at 400 to 599MB, 27.8ms at 600 to 799MB, 35.1ms at 800 to 999MB, which continues the parallel curve from 8ms at 100MB. CLAUDE.md's "serial is 13 times the wall" is mostly this: process size, not lost parallelism.
- **Disk sync is not a cost:** git issued 0 `fsync` or `fdatasync` calls in a whole run, and Ruby 539 `fsync` calls for 3.4s (kernel).

### Waiting

The largest category. Each row is 1 site; sizes overlap and do not add.

| site | seconds | lives in | status |
|---|---|---|---|
| `plain_chat_prompt_guards_spec`: 74 fixed settle sleeps (51.7s), 1 `sleep(6.0)` against a 2s grace, plus 38.2s of child boot CPU | 95 (whole file) | spec | measured |
| `input_pane_socket_spec`: 10.5s of fixed windows, plus 34.4s of child boot CPU | 64 (whole file) | spec | measured |
| stall monitor: polls every 1.0s (`faraday_handlers.rb:363`), and `stop` joins without waking it (`:350`) | 38 (22 on the main thread) | lib | reproduced |
| `Promise#await`, mostly `approval/gate.rb:537` waiting for an answer inside its window | 47 in fibers, 38 files | lib, driven by specs | measured |
| `child_worktree_approval_spec.rb:100`: 9 examples prove "parked" by waiting out a 2s timeout | 20 | spec | reproduced |
| `cli/up_spec` fixed 1.5s and 1s layout sleeps | about 11 | spec | read |
| Mixlib's `reap_errant_child`: TERM, then an unconditional `sleep 3` | 9 (3 examples) | gem, through lib and spec | measured |
| neovim `settled_mode` fixed 0.5s negative window | 8 | spec | read |
| `approval_view_spec` fake-editor examples wait out queue timeouts | about 6.5 | spec | read |
| `neovim_request_spec.rb:366`: the constant `TEARDOWN_GRACE` of 5s | 5 | lib constant | measured |

**Negative windows** are where a signal cannot replace the wait: the window is the assertion.

### Child Ruby processes

**The execve trace** (measured, 1 full `pspec`) counts 336 Ruby processes:

| final program | processes |
|---|---|
| `ruby -e` children | 102 |
| `rspec`: the 12 workers plus graded rspec children | 88 |
| `bin/` scripts | 80 |
| `lain` | 47 |
| QA sandbox scripts | 18 |
| `parallel_rspec` | 1 |

**Re-execs:** 71 of those processes exec Ruby twice, which is `bundle exec` re-exec'ing. `bundle exec ruby -e 1` takes 0.450s [0.444, 0.455] against 0.311s [0.308, 0.314] for `ruby -rbundler/setup -e 1` (10 interleaved runs each, both through `direnv`): 0.14s per re-exec, about 10 worker-seconds per run.

**Child CPU by file** (pass 1, measured), which is how much of each slow file is child boots:

| file | wall | child CPU | share |
|---|---|---|---|
| `seams/plain_chat_prompt_guards_spec.rb` | 95.3s | 38.2s | 40% |
| `seams/input_pane_socket_spec.rb` | 64.2s | 34.4s | 54% |
| `cli/wiring_spec.rb` | 23.1s | 15.4s | 66% |
| `cli/epic_driver/factory_spec.rb` | 29.6s | 13.8s | 47% |
| `review/source/github_pr_spec.rb` | 24.1s | 13.5s | 56% |
| `cli/up_spec.rb` | 50.6s | 11.8s | 23% |
| `review/deletability_spec.rb` | 16.3s | 11.1s | 68% |

The floor file is about 40% child boot and 55% settle sleeps.

**Which children could fork from the worker instead of exec'ing a new Ruby** (read):
- **Could fork:** only `cli/up_spec.rb:1110` and `support_headless_editor_spec.rb:82` and `:117`.
- **No child needed at all:** `command/meta_spec.rb`'s 6 children are `ruby -c` syntax checks that could run in-process.
- **Must exec:** everything else asserts on the boot itself (bundler, bootsnap, load path, signals) or needs a real PTY or tmux pane.

**A single boot:**

| boot | time |
|---|---|
| `require "lain"` under Bundler, no bootsnap | 1.09s |
| with a warm bootsnap cache | 0.63s |
| `exe/lain help`, no bootsnap, 10 runs | 1.27s |
| `exe/lain help`, warm cache | 0.95s |
| `exe/lain help`, cold cache (first run) | 1.86s |

**Bootsnap in spec children:** −19% on 2 child-heavy files (16 interleaved rounds, intervals apart).
- **Flake:** `tty_spec.rb:1552` hung 3 times in 24 with it and 0 in 24 without. It also failed once with no bootsnap at all, so the link is suggestive only.
- **The lost-examples run** under this variant is explained by the truncation below, not by bootsnap.
- **Cache integrity:** bootsnap writes both caches atomically (`mkstemp` then `rename`).

### The suite's environment

| variant | total work | status |
|---|---|---|
| nvim through mise's shim against `/usr/bin/nvim`, 5 runs each through `bin/with-ruby` | 1,070s [1,049, 1,091] against 1,014s [1,002, 1,025]: **57 worker-seconds**, wall unchanged (95s file) | measured |
| isolation: `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, `SHELL=/bin/sh`, an empty `XDG_CONFIG_HOME`, and a `tmux` wrapper adding `-f /dev/null`; 5 runs each | 1,091s [1,072, 1,111] against 1,094s [1,084, 1,105]: **no measurable difference** | measured |
| THP `madvise` against `always`, 3 runs each, switched per run | 1,051s [1,012, 1,090] against 1,059s [1,004, 1,114]: **no measurable difference**; the fork benchmark in the same session agrees (20.7ms against 20.6ms per Mixlib call at 371MB) | measured |

**Why isolation is still worth having, without a speed argument:**
- **Git config leaks in.** The user's global git config (`rerere.enabled=1`, `rerere.autoupdate=1`) reaches every fixture that runs its own `git init`, the hazard `seed_repo.rb:54-58` describes. Only `XDG_STATE_HOME` is isolated today (`spec/support/isolated_state_home.rb:12`).
- **tmux config leaks in.** `lib/lain/cli/up.rb:239` builds tmux commands with `-L` and no `-f`, so spec tmux servers load `~/.config/tmux` and its plugins: 5,867 plugin-script runs, 61 login shells and 52 starship prompts in 1 traced run. tmux-resurrect and tmux-continuum can save spec sessions into the user's state.
- **`XDG_CONFIG_HOME` alone does not stop tmux.** It falls back to `~/.config/tmux/tmux.conf`.
- **Process counts** (`bin/trace-pspec` with the isolation environment, against a normal traced run): zsh 207 → 1, starship 29 → 0, tmux execs 7,792 → 2,946 (the plugin scripts' calls are gone); git and nvim unchanged. bash rose 729 → 1,590 only because the test's `tmux` wrapper is a bash script.

### CI

From the run log of 36746030574 (2026-09-30), the last green run 32839603698 (2026-08-25), and a CI-shaped local run.

**The suite step:** 459s (16:43:38Z to 16:51:17Z), `parallel_rspec spec -n 4`, packed by file size. The Rakefile adds `--group-by runtime` only when `tmp/parallel_runtime_rspec.log` exists, and a fresh checkout has none.

**Before the suite, about 131s:**

| step | seconds | note |
|---|---|---|
| bundle install | 33 | missed because `Gemfile.lock` changed; saved this time |
| setup and toolchain | about 18 | |
| `rake compile` | 73 | **compiled `target/` is never cached**: `setup-ruby-and-rust` takes its cache key before `./target` exists, so it stores about 7MB of `~/.cargo/bin`, and the later save fails ("Unable to reserve"). The green run also compiled for 72s despite a "hit". This is upstream. |
| pre-commit job | about 227 | compiles the extension again (79s) |

The "Path Validation Error" warning is harmless: it is the action's early save, before anything is built.

**Estimated fixed cost per job:** about 101s with a Bundler hit, and about 35s if `target/` and the registry were cached (estimate). `main.yml` sets neither `timeout-minutes` nor `concurrency`.

**Packing** (`parallel_tests`' own grouper over the dev box's runtime log):

| workers | by file size (CI today) | by runtime |
|---|---|---|
| 4 | 364s | 264s |
| 8 | 184s | 132s |
| 12 | 133s | 97s |

**The CI-shaped run measured less than the grouper predicts:** 4 workers pinned to 2 SMT cores (`taskset -c 0,1,8,9`), packed by file size, finished at 284, 306, 306 and 329s, so file-size packing cost about 23s over a perfect split. The grouper's 100s uses runtimes from 12-worker runs, and at 4 workers the files' relative costs shift. So a persisted runtime log is worth about 23 to 45s of CI wall, not 100s.

**Not CPU-bound:** the same run used 781s of CPU over 333s of wall, 2.34 of 4 logical CPUs (234%). 460s of its 1,226 worker-seconds were sleep. More workers than vCPUs might help in CI, against growing fork cost. Untested.

**At 4 workers each process runs 3 times the files:** RSS reaches 397 to 575MB, forks cost 14.8ms on average, and total work rises to 1,226s from 1,094s at 12 workers.

**CI's 459s against 332s locally** puts the GitHub runner at about 1.38 times slower per unit of work than 2 of this box's cores.

### Memory, allocator, YJIT

**Worker RSS is mostly memory glibc freed and kept.** RSS reaches 140 to 360MB per worker at 12 workers while live Ruby objects are 21 to 57MB.
- **Worker 8:** `malloc_trim(0)` returned 100MB of 345MB (29%).
- **Who holds the rest** (bcc `memleak`, 1 reliable caller frame): Ruby's own `xmalloc`, `xcalloc` and `xrealloc` hold about 74MB, twice what `memsize_of_all` sees; `lain.so`, Nokogiri and Prism hold nothing outstanding; OpenSSL 0.8MB.

**Allocator and JIT A/Bs** (pass 2 to 4, measured):

| variant against its control | total work | system CPU | end RSS (12 workers summed) |
|---|---|---|---|
| jemalloc against glibc, both built from the same source with shared libruby (5 vs 4) | 977s vs 1,019s, −4.1% | 274s vs 302s | 2,717MB vs 3,320MB (1 sample each) |
| jemalloc build against the precompiled static Ruby in use (5 vs 5) | 977s vs 990s, within noise | 274s vs 289s | 2,717MB vs 3,395MB (1 sample each) |
| `MALLOC_TRIM_THRESHOLD_` + 2 arenas against glibc, 2 files (5 vs 5) | 21.06s vs 21.00s wall, within noise | | not measured |
| YJIT enabled in the worker after `require "lain"` (5 vs 5) | 1,097s [1,028, 1,166] vs 1,108s [1,072, 1,144], within noise | 349s vs 336s | **3,773MB vs 3,340MB, +13%** |

**Exclusion rule:** failed runs stay in every mean except the bootsnap A/B's 2 hung runs (28s timeouts, not the variant's speed). The `LD_PRELOAD` jemalloc A/B from pass 2 was confounded and is withdrawn.

### In-process CPU, FFI, dead code

- **Parsing all of `lib/`:** about 20 specs each parse it on their own; `root_defaults_spec` does it 7 times. About 12 to 20s (read).
- **`Fleet#tree`** is quadratic per spawn: 8.4s in a single 500-spawn example, and the main source of `status_feed_spec`'s GVL wait (measured).
- **Rust FFI:** 12s. `TreeSitter.query` compiles its query per call (about 2.6ms). Rust's `canonical_digest` is only 30% faster than Ruby's, and re-normalizing canonical data costs 88% of normalizing raw data (measured).
- **Dead code:** about 1.5 to 3s. The unwired Rust DAG is kept on purpose (`docs/rust-bindings.md` rule 5).
- **`Ext.blake3_hex` is not Ractor-safe:** documented at `lib/lain/review/hunk.rb:16-18` and pinned by `spec/lain/review/hunk_spec.rb:259-264`. A known, intended gap.

## Suite defects

| defect | evidence | effect | follow-up |
|---|---|---|---|
| **Silent truncation.** `input_pane_spec.rb` sends `Process.kill("INT", Process.pid)` (about `:474`) and `"TERM"` (about `:457`) to its own worker. If the signal is handled after the example's `around` hook restores RSpec's handlers, RSpec's SIGINT handler stops the worker. | Pass 4 run `075538-yjit_on`: worker 4's trail ends after `input_pane_spec.rb` with `:473` failed, then `exit via=SystemExit during=nil`, and its output contains "RSpec is shutting down and will print the summary report... Interrupt again to force quit". 20,414 of 21,508 examples ran. The pass 3 run that lost 1,211 examples had `input_pane_spec.rb` in the short worker's group (no trail then). | About 1,000 examples skipped, reported as success. 2 of about 25 full runs today. | Send the signal to a child process that runs the pane, or assert on the pane's trap without a real signal. |
| **Leaked editors.** 3 `nvim --embed -u NONE -n`, ppid 1, about 10 and 2.8 days old, alive now. Their environment shows `LAIN_SPEC_WORKERS=12`, `TEST_ENV_NUMBER=5` (2 of them) and a spec `XDG_STATE_HOME`; cwds are deleted `tmp/worktrees/T4` and `T15`. | `qa_sandbox_pane_resolution_spec.rb:126-127` starts `nvim -u NONE -n` in 2 panes. Its teardown (`:42-47`) kills the tmux server, which ends nvim's TUI client but leaves its `--embed` server, reparented to pid 1. | Memory and processes held indefinitely. | Kill the pane's process group, or the embed servers, in that teardown. |
| **`$TMPDIR` residue.** 43,571 `d2026*` mktmpdir directories (288MB; 2.8GB in the whole directory), oldest 2026-08-17. `spec/` has no `after(:suite)`. | read | Disk, and each `Dir.glob` over `$TMPDIR` gets slower. | A per-worker `after(:suite)` census (threads, fds, child pids, tmux servers, mktmpdir dirs), reporting first. |
| **Fixed windows flake under load.** `plain_chat_prompt_guards_spec.rb:601`, `tty_spec.rb:1552`, `supervisor_spec.rb:665` and `input_pane_spec.rb:473` failed under full-suite load and passed alone. | The first 2 are already in `docs/toolchain-traps.md`. | Red runs and retries. | Option 1. |

No Thor `.start` in `spec/` runs without `debug: true` or a `SystemExit` catch (read), so the CLAUDE.md `SystemExit` trap is not the truncation's cause.

## Application findings

These cost `lain`'s users, not only the suite.

| finding | size | follow-up |
|---|---|---|
| **Stall monitor join.** It polls every 1.0s, and `StallClock#stop` joins without waking it (`faraday_handlers.rb:350`, `:363`). | Every healthy streamed response waits up to 1s after its last byte. 38s of suite time. | Wake it on stop. |
| **Compaction re-derives the whole compacted lineage on every ask.** `HeldCut#outcome` → `Derivation#derive` is 43% of an ask, and `PinnedMessages` re-canonicalization is 31%. | 43ms per ask at ask 250 and 173ms at ask 1,000 (mock-driven, compacting about every 250 asks), about 2 to 15% of a 1 to 10s model round trip, growing with the session. | Cache the derived lineage between asks; a fast path for canonical messages in `Canonical.normalize`. |
| **`Fleet#tree` rebuild** (`status_feed/fleet.rb:162-174`) | Quadratic per spawn; 8.4s at 500 spawns. | Incremental update. |
| **Non-injectable constants:** `TEARDOWN_GRACE` (5s), `human_replies.rb` `TICK` and `IDLE_TICK`, `approval_surfaces.rb:141` `TICK`, the stall monitor's poll. | Every spec waits them out; users pay them as latency. | Constructor arguments with the same defaults. |
| **`TreeSitter.query` compiles its query per call** | 2.6ms per shell-command classification. | Cache compiled queries. |
| **Mixlib's 3s reap sleep** on a timed-out command | +3s per timeout. | Option 3. |
| **Bootsnap for `exe/lain`** | 0.95s warm against 1.27s; 1.86s on the first run after install. Bootsnap is a development and test gem today. | Only if boot time matters to users; needs a runtime dependency and a cache location. |

## Options

Seconds are worker-seconds unless stated. Sizes overlap where noted; rows do not add.

### 1. Waits: signals in place of fixed windows, and injectable intervals

**Covers:** the floor files' settle sleeps, `child_worktree_approval`'s 2s timeout, `cli/up`'s layout sleeps, queue timeouts, and in `lib` the stall monitor and the non-injectable constants.
- **Size:** 58s measured (stall monitor and `child_worktree`); roughly 100 to 200s more by audit arithmetic (read).
- **The only option that shortens the 95s file:** its settle sleeps are about 55% of it.
- **Lowers flake risk:** every load-dependent flake seen here waits on a fixed window.

### 2. Fewer, overlapped, or cheaper child boots

**Covers:** about 323 spec child Ruby processes per run.
- **Size:** 102 `ruby -e` and 47 `lain` boots at about 1.1s is about 160s of boot CPU. In the floor files boots are 40 to 54% of the wall.
- **Few can fork instead:** only 3 sites can fork from the worker; `meta_spec`'s 6 `ruby -c` checks need no child.
- **Bootsnap in children:** −19% on boot-heavy files; it may make `tty_spec.rb:1552`'s race more likely.

### 3. Finish the `Shell::Out` migration

- **Size at 12 workers:** about 147s, kernel-counted (74s clone + about 73s teardown). Up to about 100s more (pre-exec work and Mixlib's parent loop) is not claimed.
- **Size at 4 workers:** larger. Forks cost 14.8ms there against 10.8ms, so clone alone is about 141s.
- **Where:** 41% of the fork time is in `lib`, where every agent turn's git and tmux calls speed up.
- **A design change:** `Shell::Out` was deliberately minimal, "for callers only ever using Mixlib to get three values back" (mempalace, via the panel). The rest needs `cwd:`, `input:`, an `error!` equivalent, a timeout class, and changes to specs that double Mixlib by name.

### 4. Extend the copied-template fixture pattern

**Covers:** `SeedRepo`'s build-once, copy-per-example shape, for the files still building repositories per example:
- `cli/command/review_spec` (9.8s)
- the `epic_driver` specs (about 7s)
- `github_pr_spec`'s remote group (5.6s)
- `forge/promotion_spec` (4.2 to 5.6s)
- `local_landing_spec` (2.2 to 3.6s)

About 30s (read); the fork part overlaps option 3. `cli/wiring_spec` separately snapshots the whole checkout in 20 examples (about 17s) because `project:` defaults to the cwd. `test-prof`'s `let_it_be` and `before_all` do not fit: they are database-transaction tools.

### 5. Isolate the suite from the box it runs on

**Covers:** `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, `SHELL=/bin/sh`, an empty `XDG_CONFIG_HOME`, and `-f /dev/null` (or a spec-owned config) for spec tmux servers, applying to any box, not only this one.
- **Size:** no measurable speed change. The gain is correctness: no user git config in fixtures, no user tmux plugins or resurrect state in spec sessions.
- **nvim on this box:** the shim costs 57s of work. That is box configuration (real nvim ahead of the shim on PATH), never a hard-coded path in `spec/support`.

### 6. A jemalloc Ruby

Against the precompiled Ruby in use: total work within noise, system CPU about 5% lower, RSS lower on 1 sample. Needs a source-built Ruby on every box and in CI.

### 7. In-process CPU

A shared, memoized parse of `lib/` for the scan specs (about 12 to 20s, read), `Fleet#tree` (8.4s), and `deletability_spec`'s repo-root glob (3.8s).

### 8. Do nothing

101s here and about 590s per CI job (131s setup plus 459s suite), growing with every seam spec: examples doubled since August, and the wall quadrupled.

### 9. Fix the CI build caches (CI only)

**Covers:** cache `target/` and the cargo registry after the build, not before, either by working around `setup-ruby-and-rust`'s early save or with an explicit `actions/cache` step after `rake compile`; and keep the Bundler key stable.
- **Size:** fixed cost from about 131s to about 35s (estimate), per job, and per shard if option 11 is taken.
- **Also:** the pre-commit job's 79s compile goes with it.

### 10. Persist the runtime log in CI (CI only)

**Covers:** restore `tmp/parallel_runtime_rspec.log` with `actions/cache` (restore-keys from the default branch), or commit a snapshot refreshed by a job, so CI packs by runtime.
- **Size:** about 23s measured on the CI-shaped local run (perfect packing against file size), and up to 45s by the grouper's estimate at CI's shape.
- **Needed by option 11.**

### 11. Shard CI across runners (conditional)

**Covers:** `parallel_rspec --only-group` across a job matrix. It runs whole files, so it does not break the no-sharding rule, but it needs option 10's log or it packs by file size.
- **Price:** each shard pays the fixed cost.

| shards | fixed cost per job | wall (est.) | runner minutes |
|---|---|---|---|
| 2 | 131s today | 6.0 min | 12 |
| 4 | 131s today | 4.1 min | 16 |
| 2 | 35s with option 9 | 4.4 min | 9 |
| 4 | 35s with option 9 | 2.5 min | 10 |

Worth it only after options 9 and 10.

## Comparison

Rows overlap and do not add. CI wall effects divide worker-seconds by 4 and scale by the measured 1.38.

| | size (worker-s) | status | dev-box wall | CI wall per run | helps users | risk |
|---|---|---|---|---|---|---|
| fix the truncation | 0 (correctness) | measured | none | none | no | none; restores about 1,000 examples in affected runs |
| 1. waits | 58 measured + 100 to 200 read | mixed | **yes**, the only lever on the 95s file | about 20 to 90s | yes | low; negative windows stay |
| 2. child boots | about 160 of boot CPU | measured boots, read sharing | yes, in the floor files | yes | no | bootsnap variant may raise 1 flake |
| 3. `Shell::Out` | about 147 at 12 workers, more at 4 | measured (kernel) | about 12s once the floor file is fixed | about 60 to 80s | yes | design change |
| 4. templates | about 30 (+17 wiring) | read | small | about 10s | no | fixture drift |
| 5. isolation | none measured; nvim 57 on this box | measured | nvim only | none | no | none |
| 6. jemalloc Ruby | within noise vs precompiled | measured | no | no | memory only | a source build everywhere |
| 7. CPU | about 25 to 30 | mixed | no | about 10s | `Fleet#tree` | low |
| 9. CI caches | about 96s of setup per job | measured (logs) + estimate | no | **about 96s** | no | upstream action quirk |
| 10. runtime log in CI | packing, not work | measured locally | no | **about 23 to 45s** | no | stale log packs badly |
| 11. CI shards | none (more runners) | estimate | no | 2 shards about 5 min, 4 about 2.5 min (with option 9) | no | runner minutes |
| 8. nothing | 0 | | 101s | about 590s per job | no | grows |

## Recommendation

**Fix the truncation first.** It is small and local to 1 spec file, and until it is fixed any run, in CI or `pre-commit`, can pass having skipped a thousand examples.

**Dev box: option 1, the waits,** starting with the 2 floor files and the stall monitor.
- It is the only option that moves the dev-box wall while the 95s file sets it.
- It cuts total work, which CI's wall is made of.
- The stall-monitor fix removes up to 1s of latency from every streamed response.
- It removes the pattern behind the load-dependent flakes.

**CI: options 9 and 10 first**, the caches and the runtime log. They are configuration only, worth about 96s and about 23 to 45s per run, and option 11 depends on them.

**Both: option 3, `Shell::Out`, next.** It is the largest measured code item, it is worth more in CI than at 12 workers because forks get dearer as workers grow, and it speeds up `lain`'s own git and tmux calls. It needs a decision on `Shell::Out`'s scope first.

**Against the panel's expected shape** ("waits first on the dev box, packing and caches first in CI, `Shell::Out` next in both"), the data confirms it with 2 refinements:
- Packing is worth about 23 to 45s measured, not 100s.
- The truncation defect goes ahead of everything.

**Confidence:** high on the truncation, the CI fixed costs, and the order; fair on CI wall effects, which scale this box's work by an observed 1.38. Options 1, 2 and 4 rest partly on audit arithmetic.

## Proposed amendments

Not applied; they need a decision.

**`docs/spec-suite-performance.md`, "The wall is a MAX, not a sum":** retitle it "The wall is the larger of two terms", and open with:

> The wall is bounded by the slowest single file AND by total work divided by workers, whichever is larger. On this box at 12 workers both bind today: 1 file takes 95s and the rest average 92s per worker (2026-09-30). In CI at 4 workers, total work is the only term that matters, and setup adds about 131s. Do not shard a spec to game the packer: fix what makes the file slow, and the packer redistributes the rest.

**`CLAUDE.md`, Toolchain:**
- Replace "The wall is a MAX over files, not a sum -- so never shard a spec to game the packer" with "The wall is the larger of the slowest file and total work / workers; both bind here today, and only the second in CI. Never shard a spec to game the packer."
- Update the example count from 20,511 to 21,508.
- Add to "Check the example COUNT": "a worker that receives SIGINT stops after its current file and prints a normal summary; `input_pane_spec.rb` signals its own worker."

**A ratchet against re-growth:** `bin/runtime-census --check`, comparing the slowest file and total work against a committed snapshot, gating nothing, the same shape as `bin/spec-census`.

## Discarded options

- **Sharding slow files.** Forbidden, and it hides the cost.
- **More workers on the dev box, for now.** `runqlat` shows no CPU contention at 12 workers, but while the 95s file binds, workers cannot help. In CI, 4 vCPUs ran 234% busy, so oversubscribing could help there; it is untested, and fork cost grows with RSS.
- **YJIT in the worker.** No measurable change in total work; RSS +13%.
- **YJIT in children (`RUBYOPT=--yjit`).** Each child boot gets slower (1.08s against 0.88s).
- **Allocation work in `lib/` for suite speed.** GC is 2.7%; the memory is Ruby's VM and glibc's retention.
- **FFI changes for suite speed.** 1.1%. The tree-sitter cache stays as an application finding.
- **`GC.compact` before fork.** +1.9ms per fork, no RSS change.
- **`malloc_trim` in the suite.** It treats a symptom option 3 removes.
- **`MALLOC_ARENA_MAX=2` with a trim threshold.** Within noise on 2 files (n=5); RSS not measured.
- **Disk sync.** git issues no `fsync`; Ruby's 539 cost 3.4s.
- **Cold bootsnap in CI.** A fresh runner's cache is cold, and a cold boot is slower than none (about 3.0s against 1.9s per worker boot in CI's shape, about 4s per run).
- **A queue runner in place of static packing.** It removes the packing tail (about 13s at 12 workers), never the floor file; low value until the floor files are fixed.
- **Deleting the unwired Rust DAG.** 1.4s, and kept deliberately.
- **Mocking git.** The semantics under test are git's; the cost is fork.

## Open questions

- **The truncation's second instance:** the pass 3 run is consistent with it but had no trail. A run with the probe until it recurs on that worker would settle it.
- **Oversubscribing CI** (8 workers on 4 vCPUs): plausible, since the CI-shaped run left 40% of the CPUs idle, but untested.
- **THP** is answered: no difference on this box. An earlier comparison against the previous day's fork benchmark had suggested 30%; that was a difference between days, not modes, and is withdrawn.
- **Ruby's 74MB:** which VM structures. It needs DWARF-unwound `malloc` stacks.
- **A musl Ruby** was not built.
- **CI's absolute numbers** come from 1 run's log and a local imitation; 1 CI run with `/usr/bin/time -v` around the suite step would measure the runner directly.

## Sources

- **Tools:** `bin/trace-pspec`, `bin/trace-summary`, `bin/trace-memleak`, `bin/memleak-summary`, `bin/strace-children`, `bin/with-ruby`, `bin/setup-profiling` (50570ca4), and `bin/box-state` (uncommitted); usage and traps at the top of each, and in `docs/spec-suite-performance.md` "Tools for measuring it".
- **Data** (on the measuring box only, `tmp/profiling-2026-09-30/`):
  - `par_all.jsonl`, `serial.jsonl` (pass 1)
  - `pass2/`, `pass2/pass3/`
  - `pass4/` (`variants.jsonl` with every A/B run and its box state, `runs/` with each run's output and per-worker trails, `ci4/`, `blocking/`, `serial/`, `ci_findings.md`, `code_findings.md`)
  - `report-v1.md`, `report-v2.md`
- **CI:** runs 36746030574 and 32839603698 (`gh run view --log`).
- **Commits:** `1a70dd7f`, `3bc8907d` (`Shell::Out`); `c2cca32b`, `4723970b` (templates); `248ae333`, `2ce33076` (bootsnap); `4b0117b1` (Zeitwerk); `50570ca4` (the tools).
- **Papers:**
  - Mytkowicz, Diwan, Hauswirth and Sweeney, "Producing Wrong Data Without Doing Anything Obviously Wrong!", ASPLOS 09.
  - Curtsinger and Berger, "Stabilizer" (ASPLOS 13) and "Coz" (SOSP 15), via https://plasma-umass.org.
- **Panel reviews** of 2026-09-30 and 2026-10-01, with their mempalace result on `Shell::Out`'s scope, the CI run IDs, and the journal findings on mempalace jobs.
