# Scenario: the merge coordinator

**What it exercises:** `lain land enqueue / wait / status / drain`, the drainer's drain lock and
batching, the verify worktree, the suite lock, a chat worker's queued handback, and `lain epic land`
sharing the same branch.

**Status:** first driven 2026-10-18 (round 26, fork m). The core question held: 3 enqueuers and 2 hand drains racing landed each entry once, no 2 verifies overlapped, the branch moved only by fast-forward or compare-and-swap, and `wait` told the truth. 9 predictions were corrected below.

**The question it answers:** does exactly one drainer land a branch, with one verify per batch, moving
the branch only by fast-forward to a commit that verify passed, and does `lain land wait` tell the
truth about every outcome?

**Cost:** minutes, no model, except §7 (a chat child), which needs a local model.
**Needs:** `git`, a throwaway repository, `lain` on `PATH`. Read `../method.md` first and build the run's sandbox with
`.claude/skills/manual-qa/scripts/qa-sandbox.sh` (XDG redirection, its own `TMPDIR`); every path below
lives under that sandbox's `$QA`.

---

## 0: The subject

A throwaway repository at `$QA/repo`, with `main` checked out in that main worktree and 2 linked
worktrees, each cut from `main` with its own commit touching a different file:

```bash
git -C $QA/repo worktree add -b qa-a $QA/a main
git -C $QA/repo worktree add -b qa-b $QA/b main
echo a > $QA/a/a.txt && git -C $QA/a add a.txt && git -C $QA/a commit -m a
echo b > $QA/b/b.txt && git -C $QA/b add b.txt && git -C $QA/b commit -m b
```

`$QA/repo/.lain/config.rb`:

```ruby
isolation verify: ["sh", "-c", "test ! -e BAD && date +%s%N >> $QA/verify-repo.log"],
          batch_cap: 4, verify_timeout: 60
```

(write the real `$QA` path in, since the verify command runs without your shell's variables.) Then
`cd $QA/repo && lain trust --yes`, and again after every config edit, since a changed config is
untrusted until then. Every verify appends one line to the log, so verifies are counted by `wc -l`.
A commit that adds a file named `BAD` is red.

The home directory `lain land status` reads is `<git-common-dir>/lain-coordinator/<branch>-<fp>/`, holding `drain.lock`, `drain.log`, `entries/` and `results/`. The verify tree and suite lock are under the state root: `worktrees/<hash>/verify/`, kept locked between runs, and `locks/suite.lock`.

## 1: Enqueue, then wait

```bash
cd $QA/a && lain land enqueue          # prints: queued <id> for main at position 1; a drainer is landing it
lain land wait <id> --branch main  # exit 0, "<id> landed at <sha>"
git -C $QA/repo log --oneline -1 main    # main holds a's commit
```

Expect: exit 0, `main` fast-forwarded (no merge commit), the verify log gains 1 line. Run `wait` again: it prints `<id> landed at <sha>` again, exit 0, no new verify line. `<id> was
already on main` appears only for a commit already on `main` when it was enqueued: enqueue `main`'s
own `HEAD` from the main worktree and wait on it.

Refusals, each exit 64: `lain land wait nonsense`; `wait` from a directory outside any repository;
in a bare clone. `lain land enqueue` on a detached main worktree is a plain error, exit 1, not 64. `lain land wait` with no id is Thor's usage error, exit 1.

## 2: A batch

Enqueue `c` with a verify that sleeps, and while it verifies enqueue `a` and `b`. They form 1 batch with 1 verify. Enqueued back to back, the first drainer takes `a` alone, because an enqueue takes about 1.3 s. Expect both to land under a single drainer; the verify log gains 1 line for the pair (1 verify per
batch), and `lain land status` between them shows `drain lock held by pid=... for Ns`. A second worker lands as a merge commit `Merge refs/lain/worker/<id> into main`; only a commit that already descends from main lands with no merge commit.

## 3: A red batch with bisection

Commit a `BAD` file in `a`, a clean change in `b`, and enqueue both. Expect `wait` on `a`'s id to exit
1 with `did not land` and the verify tail; `wait` on `b`'s to exit 0. `main` holds `b`'s commit and not
`a`'s. The verify of §0 writes only on a pass, so it cannot show the runs. `wait` on `a` reports `did not land: declined … the batch failed verification: <cmd> exited 1`. To see the runs, log at the start of the verify, before the test: 3 runs (batch, `a`, `b`). Main's history keeps nothing from the red worker.

## 4: A moved tip

While a batch's verify sleeps (change `verify` to `sleep 20; ...` and run `lain trust --yes` again), commit to `main` from the main
worktree. Expect the batch to be rebuilt (up to `rebuild_cap`) over the new tip, or, past the cap, the
entries to report the branch moved. Past the cap, `wait` exits 1 with `did not land: declined … the branch moved 2 times during verification`; main kept both human commits. Either way `main` never loses the human's commit.

## 5: `epic land` and the drainer take turns

With a drainer mid-verify, run `lain epic land <issue>` on an approved issue. Expect it to wait on the
drain lock, not to verify in parallel: 1 verify process at a time (`pgrep -af` the verify command).
Its output ends with `verification passed on <tip>` or `verification skipped: ...`. The drainer must be on `epic/<slug>` to share the drain lock; across branches only the suite lock serializes the verifies. Round 26 read this from the code only.

## 6: A killed drainer

Start a drainer with a slow verify, then `kill -9` the drainer's
pid from `lain land status`.

```bash
lain land status        # names the holder and how long
kill -9 <pid>
lain land status        # "no drainer running; a stale holder line from pid N was left"
lain land enqueue       # a new drainer starts and lands the stranded entry
```

Record: after `kill -9` of a drainer its verify child used to live on, and the next drainer's verify started in the same verify tree while it ran; the orphan then reported `pass` against the new candidate's HEAD (round 26, m26-1). Fixed (T78, T79, T80): the holder line gains `verify_pgid=<n> start=<ticks>`, and the next taker of the suite lock stops that group (TERM, then KILL) and says `stopped verify group <n>, left running by a dead suite lock holder`; a reused pid whose group is not a verify one is left alone, and a box with no `/proc` kills nothing and says so. Check `verify-all.log` for overlapping start lines. The queued entry is landed
by the next drainer, not lost; `wait` on the old id still reaches an answer.

Then the case where nobody comes. Kill the drainer, and do **not** enqueue again. Run `lain land wait <id> --branch main`
on a stranded id (no `--timeout`): once no live process has held the drain lock for 5 seconds it stops waiting
and prints ``<id> is queued and no drainer is landing it (stale holder line from pid N); run `lain land drain --branch main` to land it``,
exit 3 (not a hang, and not 2, which is only the timeout passing). Run the printed command: the entry lands and
a second `wait` exits 0. A drainer still booting can read as absent for those 5 seconds, so a `wait` run in the same instant as
the first `enqueue` may exit 3; running the printed command then is harmless, because the lock admits one drainer. With a
live drainer holding the lock (a slow verify), `wait` keeps waiting past 5 seconds and exits 0 or, with `--timeout`, 2.

Last, an unusable lock. `chmod 000 $QA/<the drain.lock path>` (the home directory `lain land status` reads is under
the repository's git common dir, see §0; find it with `find $QA -name drain.lock`). `lain land enqueue` and `lain land status` each refuse in one line
naming the file (`cannot use the lock <path>: ...`), with no backtrace and without saying a drainer is landing the entry. For
`enqueue`, a lock that is readable but not writable is refused the same way. The path appears once and the reason is the system's, `cannot use the lock <path>: Permission denied` (m26-6 fixed, T85). Restore the mode afterwards.

## 7: A chat child hands back

`lain chat --isolation worktree` with `@dev[/execute-plan] <task file>`, whose lease is a worktree (a bare `subagent` call spawns a researcher with a scratch lease that cannot commit). Expect the child to run `lint` over the changed files, and `check` only when a changed file is a test or has a mirrored test under a test layout in force, before its rebase, then answer `queued as <id>; lain land wait <id> --branch main`, and the
parent checkout, even with uncommitted edits in it, is never merged into. `lain land wait` on that id
exits 0 once landed. Observed in round 26: the reply was `[the worker's commits are on refs/lain/worker/dev-spawn.1-…, not yet on the branch -- queued as <id>; lain land wait <id> --branch main]` and `wait` exited 0; main fast-forwarded with the parent's uncommitted `seed.txt` edit intact.

## 8: Two repositories, one suite lock

Repeat §1 in 2 unrelated repositories at the same moment, each with its own log (`$QA/verify-repo1.log`, `$QA/verify-repo2.log`) and a verify that sleeps 10.
Expect the second verify to start only after the first finished (the log timestamps are at least 10s
apart; round 26 saw them 10.04 s apart). The waiter prints nothing about the suite lock, by design; the drain log now says `waiting on pid=<n> command=<argv> for <lock> (<path>)` once the wait runs long (m26-5 fixed, T84). Both land.

## Edges driven in round 26

- A timed-out verify kills its process group.
- Amending a branch and re-enqueuing lands the superseded commit (m26-2). Fixed (T81): the older entry completes as `declined` with detail `superseded by entry <id>`, and only the newer lands; a git error in the check skips it and logs the worker id.
- With an untrusted config, enqueue says a drainer is landing it and the drainer dies on trust (m26-3). Fixed (T82): `lain land` enqueue loads the config first and refuses an untrusted one before queueing.
- With no verify configured, `wait` says `landed at <sha>` with no word that nothing verified (m26-4). Fixed (T83): it adds `verification skipped: no verification is configured` after the landed line.
- The verify child sees 0 names matching TOKEN, KEY or SSH_AUTH.
