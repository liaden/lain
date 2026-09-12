# Scenario: subagents, isolation, and where a command becomes a process

**What it exercises:** `Tools::Subagent` in **both** modes (`one_shot` and `actor`), the
`Supervisor` reactor that un-refuses a model-dispatched actor, `--isolation` (`none` / `worktree`)
and `Isolation::Worktree`'s real-`git` seams, `--exec` (`local` / `docker`) and `Exec::Docker`,
`lain watch`, and `lain chat --windows`.

**The question it answers:** when the loop stops being one process, does anything still tell the
truth? Three axes come apart here — who is running (a subagent), where its files are (isolation),
and where its commands become processes (exec) — and each is a flag that is easy to accept and hard
to observe. `--isolation worktree` is the only place the real-`git` seams live, and no scenario has
ever run it.

**Cost:** minutes. Subagent spawns are ollama turns; everything in §1, §4a and §5a is
launch-level and needs no model.

**Needs:** `git` (§3), `docker` on PATH (§4 only — skip it by name if absent, do not silently pass).
`bench.md` up. tmux for §6.

**One hard precondition, from `IsolationBackend`'s own doc:** `--isolation worktree` keys its
checkout root on the **repository**, and worker ids restart from 1 per process. Two concurrent
worktree runs of one project therefore target identical paths, and the second run's reap would
force-remove the first's **live** checkout. **One isolated run per project at a time** — check
nothing else is running before §3, the way `method.md` has the driver check for `parallel_rspec`.

---

## 1 — The flags refuse at LAUNCH, not at first use

Both resolvers refuse on cheap local facts up front, and both refuse for the same stated reason: a
bad flag is an operator mistake about the environment the run started in, and deferring it surfaces
mid-run, after a session record exists, as a git or docker error that buries what was actually
wrong.

```bash
run(){ out=$(timeout 60 lain chat --provider ollama --model qwen3-coder:30b "$@" < /dev/null 2>&1); echo "[$?] $*"; echo "$out" | tail -2; }
run --isolation worktre                 # Unknown, naming ["none", "worktree"]
run --isolation worktree                # from OUTSIDE a repository: NotARepository
run --exec dokcer                        # Unknown, naming local, docker
run --exec core                          # Unknown -- see the note below
run --exec docker                        # with no docker client on PATH: Unavailable
```

Expected wordings:

```
--isolation worktree needs a git repository to branch checkouts from, and <root> is not inside one up to <boundary> (<reason>); run it from a repository or use --isolation none
unknown isolation backend "worktre", expected one of ["none", "worktree"]
```

**`--exec core` being refused by name is correct, and is the interesting one.** `Exec::Core` is a
real backend of that seam and is deliberately not in `BACKENDS`: it needs a **started**
`Lain::Core::Client` and the Async reactor holding it, neither of which a flag can hand over. An
unresolvable name refused by name beats one resolved into a backend that dies at its first command.
So the check is that the refusal names `local, docker` and does **not** mention `core` as if it were
available. If a round finds `--exec core` accepted, the flag has grown a backend that cannot work.

**The probe is the CLIENT, not the daemon**, and the asymmetry is deliberate: an absent binary is a
flag the operator cannot have meant; an unreachable daemon is a machine that may come back, and
asking `docker info` at launch would make every chat's startup wait on a daemon socket. So verify
the negative too — **stop the docker daemon, leave the client on PATH, and confirm `lain chat
--exec docker` still starts.** A launch that hangs or refuses there has moved the probe, and the
cost is on every startup.

Also drive the compose refusal if the project declares services:

```
<the services DSL> declares compose services but there is no compose file in <root> (looked for <names>); add one, or drop the compose declaration
```

## 2 — `one_shot`, and the depth cap

The default mode. Cheap, and it is the control for everything after it.

```
you> spawn a subagent to count the ruby files under lib/ and report just the number
```

Read the journal for the causal edges — this is the record round 5 produced 29 `child_turn` records
into and never saw rendered anywhere:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "#{r["type"]}\t#{(r["spawn_digest"]||r["parent"]||"")[0,12]}" if %w[spawn child_turn message].include?(r["type"])}' "$JOURNAL"
```

A `spawn` must precede its `child_turn`s, and every `child_turn` must name a `spawn` present in the
file. A dangling parent is `failure-injection.md` §3's damage, occurring naturally.

Then the depth cap: ask for a subagent that spawns a subagent that spawns a subagent. The refusal
**emits no event and touches no Store** — so check both halves. A depth refusal that journals a
`spawn` record has created a child that does not exist, and every later fold counts it.

**The subagent gets a FRESH root** whose `meta["spawned_from"]` names the parent's head. Confirm
both directions: the lineage survives (the field is there and resolves), and the child **never
inherits the parent's prompt**. Put a distinctive sentence in the parent's context — a `/btw`-worthy
aside, a memory item — and confirm it is absent from the child's request.

## 3 — `actor` mode, and `--isolation worktree`

This is the section the scenario exists for, and the question it used to open with is closed now.

**Leasing by a model-dispatched spawn is no longer open** — `--isolation`'s help text and
`CLI::Wiring` agree: the flag is resolved exactly once per launch (`Wiring#fleet_isolation`) and
that one backend is shared between the `Supervisor` an actor adopts onto and the
`Tools::Subagent::Leases` a **one-shot** dispatch holds through too (`Tools::Subagent#run_child`),
including a nested spawn (`Subagent#descend` carries the same seam down). So this section is not
about settling which of two claims is true; it is about **confirming a spawned child actually
leased**, and the checks below are how a driver does that rather than takes the claim on trust.

```bash
cd "$REPO"; lain chat --provider ollama --model qwen3-coder:30b --isolation worktree
```

```
you> spawn a long-lived actor subagent that watches for my next instruction, then tell me its handle
```

What to check, in order:

1. **Was the actor adopted at all, or refused?** The refusal is a specific one — a model-dispatched
   actor without a running Supervisor — and it emits no event, so a driver reading only the journal
   cannot tell a refusal from a spawn that never happened. Read the `tool_result`: an adopted launch
   carries **the actor's address (its `:spawn` digest), the stable name a caller tells it by**.
2. **`git worktree list` while the dispatch is live, and again once it settles.** Empty before,
   one checkout while the actor (or a plain one-shot spawn) holds its lease, empty again after
   release — that appear/disappear pair is the whole of what "actually leased" means to a driver
   watching from outside the process, and it is the check that catches a lease acquired but never
   reclaimed as cleanly as one never taken at all.
3. **The `isolation_lease` records.** They must name the concrete backend that actually isolated the
   worker (`Isolation::Worktree`) rather than a decorator over it — the journal wraps **nearest** the
   concrete backend, exactly **once**. A doubled lease record is the second-wrap bug, and it corrupts
   lease accounting silently. Confirm one acquire/release pair per dispatch, and that an ordinary
   one-shot `subagent` call the model made on its own — not only the adopted actor above — leaves the
   same pair, since both paths now lease from the one resolved backend.
4. **A nested spawn's checkout lands at a THIRD path.** Have the actor spawn a grandchild subagent
   and read `git worktree list` again: the grandchild's lease must be its own entry, distinct from
   both the human's own working tree and the parent actor's checkout — a grandchild sharing either
   would mean it escaped into a tree it was never leased.
5. **`--isolation none` produces an `Isolation::Null` and not a stack of pass-throughs.** By-need
   decoration is a legibility policy: what it buys is that an undecorated run stays identifiable.
   Check the two runs' records differ in shape, not just in a name field.

Then the reap, which is where the real-`git` seams are:

```bash
# kill the session hard, mid-lease
lain chat ... &  # then SIGKILL it while the actor holds a worktree
git worktree list                      # a leftover checkout
lain chat --isolation worktree ...     # the NEXT run must reap it before its own add
```

**Reaping a crashed run's leftovers before the next add is exactly the trade the repo-keyed root
buys**, and it is the only thing that stops the checkouts leaking forever. Confirm it happens, and
confirm it discards uncommitted work in the leftover (documented) rather than refusing.

Finally the loud case: `Refused` when `git worktree add` fails or the path is already leased. Create
the target path by hand before the acquire and check the refusal names the path and the worker id.

## 4 — `--exec docker`: where a command becomes a process

**A container is not a sandbox.** Nothing `--exec` resolves confines anything. What it selects is
where a command's toolchain comes from, never what it is permitted to do — the tier-3 approval gate
still runs, for every backend name. That is the first thing to verify, because it is the assumption
an operator will make:

```bash
lain chat --provider ollama --model qwen3-coder:30b --exec docker
```

```
you> run: rm -rf /tmp/should-still-be-gated
```

**It must still hit the approval gate.** A `--exec docker` session that auto-approves because "it is
in a container" is the defect this paragraph exists to catch, and it is the one a reasonable person
would call a feature.

Then the backend's own behaviour:

- `--exec-image` selects the image; the default is `alpine:latest`. Drive a command that exists in
  one image and not another (`bash --version` under `alpine` vs a debian image) and confirm the
  result differs. A `--exec-image` that changes nothing is a flag being read and dropped.
- **A pipe is refused, by name.** `docker run` takes one argv and a pipe needs a shell, so the
  backend has no way to serve one: `run: cat lib.rb | wc -l` must produce the named `Unsupported`
  refusal, not a shell error from inside the container and not a silent single-command run.
- **The timeout kills the client.** Drive `sleep 600` against the deadline and confirm the named
  `Timeout` rather than a hang. This is the same shape as `rust-cli.md`'s long-running-command
  section, one backend over.
- **A stopped daemon surfaces as a tool error**, named in the class doc rather than pretended away.
  Stop the daemon mid-session and confirm the model gets a legible tool error and the session
  survives. A session that dies because docker did is worse than the error.

And the control that makes the section mean anything: run the **same three commands** under
`--exec local` and diff the results. Different toolchains, same gate, same refusal vocabulary.

## 5 — `lain watch`

The one surface that renders a single actor's lineage, and it has never been driven.

```bash
lain watch                        # no selector -- EmptySelector
lain watch ''                     # same
lain watch zzzz                   # a prefix matching nothing
lain watch <spawn-digest-prefix>  # from §2 or §3
lain watch <prefix> --session <path>
```

`EmptySelector` must say what a selector is: `selector must be a spawn-digest prefix, got ""`. With
no sessions at all, `NoSession` must name the directory it read **and what it skipped** — the
honest-empty rule again, and here it additionally breaks the count down by kind (durable vs
`ephemeral (--btw)`). Point it at a state home holding only `--btw` sessions and confirm the message
distinguishes "nothing here" from "nothing durable here".

Then run it **against a live actor from §3, in a second terminal**, and check it is genuinely a
tail: new turns appear without a re-run, and it is **read-only** — the watched session's journal
must be byte-identical before and after, and nothing may appear in it attributable to the watcher.

```bash
sha256sum "$JOURNAL"    # before, and after the watch is closed
```

## 6 — `--windows`: one tmux window per spawn

```bash
lain chat --provider ollama --model qwen3-coder:30b --windows      # inside $TMUX
lain chat --provider ollama --model qwen3-coder:30b --windows --no-journal
```

The second must **refuse**: `--windows` runs `lain watch` per spawn and `lain watch` needs the
session journal, so the combination is incoherent and is documented as incompatible. A silent accept
produces windows that tail nothing.

Outside `$TMUX` it must also refuse, at launch, naming the requirement — not open zero windows and
say nothing.

Then, inside tmux, spawn two subagents and check:

- **one window per spawn**, named by the actor's handle rather than by an index (an index makes two
  concurrent spawns indistinguishable);
- a window whose actor **finished** says so rather than sitting on a dead tail;
- **closing a window does not kill the actor.** The window is an observer; if closing it stops the
  work, `lain watch`'s read-only claim is false in the one place it is easiest to break.

## 7 — What this scenario still cannot reach

- **`Exec::Core` and the `lain-core` daemon.** Not reachable from a flag by design (§1). Reaching it
  needs a driver that starts a client and calls the backend directly — a `bundle exec ruby`
  harness, not a chat — and `bundle exec rake core:build` first. There is no shipped tool that
  builds one: the tool that used to serve as that driver was deleted as unreachable. Named here
  because "no scenario covers it" should not read as "nothing covers it": the `:core`-tagged specs
  do, and what is missing is a human at the gate, not coverage.
- **Isolation under concurrency.** The one-run-per-project precondition above is a *precondition*,
  not a property under test. Whether two concurrent runs actually corrupt each other is a question
  this scenario deliberately does not ask, because asking it destroys the answer.
