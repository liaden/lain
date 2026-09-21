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

**The precondition this section used to state is corrected by round 17.** It said
`--isolation worktree` keys checkouts on the worker id, that ids restart per process, and that a
second run's reap would force-remove the first's live checkout. Round 17 measured otherwise:
**leases land at random-id paths** (`…/worktrees/<repo hash>/<random id>`), so two runs do not
target one path and there is no reap-before-add. Keep one isolated run per project anyway — it is
what keeps `git worktree list` readable — but do not drive a collision this section no longer
predicts.

**And the chat's `subagent` tool is ONE-SHOT only** (round 17): actor mode is wired for the epic
orchestrator alone, so every check below that needs a model-dispatched actor — §3's adoption,
nested-spawn-at-a-third-path and the depth cap, §5's live-actor tail — has **no chat path**. Mark
those *unreachable from chat* in the findings rather than dropping them silently; `epic-tier.md`
§10 is where an actor runs.

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
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next
  next unless %w[message child_turn].include?(r["type"])
  puts "#{r["type"]}/#{r["kind"]}\t#{r["digest"].to_s[0,19]}\tcauses=#{Array(r["causal_parents"]).map{|d| d[0,19]}}"}' "$JOURNAL"
```

**There is no `spawn` record type** — a spawn is a `message` record of `kind: spawn`, its completion
a `message` of `kind: message`, and each child turn a `child_turn` record. (The reduction here used
to grep a `spawn` type and printed nothing.) A spawn must precede its `child_turn`s, and every
completion must cite its spawn among its `causal_parents`. A dangling edge is `failure-injection.md`
§3's damage, occurring naturally.

**Two parallel spawns doing different work take different addresses** since 2026-09-14: a one-shot
spawn's body carries `task`, a digest of its prompt, beside `prefix`, `posture`, `only` and
`spawned_from`. Round 17 journaled two identical `message kind=spawn` records for two different
prompts in one turn (F97), and `--windows` and `lain watch` collapsed the twins. Ask for two
subagents with different prompts in one message and confirm two distinct spawn digests. **Two spawns
of an IDENTICAL prompt from one head still share one address, by decision** (the discharging chunk's
Open decision 5) — do not file that. *(Prediction, not yet driven.)*

**A child that fails, is stopped, or is refused a lease leaves a record that retires it**, new in
round 18. Before it, only a child that finished wrote a completion, so a crashed one left a
`:spawn` with nothing beside it: the fleet count never came down and every lineage reader waited
forever. Now the completion `:message` carries a `lifecycle` of `settled`, `stopped` or `failed`,
and a failed one also names the error's **class** — and carries **no** `result` key at all, which
is what keeps it out of every finished-work reader:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next
  next unless r["type"]=="message" && r.dig("payload","lifecycle")
  puts "#{r["payload"]["lifecycle"]}\t#{r["payload"]["error"]}"}' "$JOURNAL"
```

Three things to drive:

1. **Every `:spawn` has a completion.** Count them. A spawn with none is the regression.
2. **A killed child retires.** Ask for a spawn, `/stop` the ask while it runs, and read
   `lifecycle`. The fleet count in the HUD must come back down.
3. **A lease refused before the spawn leaves neither record.** The lease is taken *before* the
   `:spawn` is written, so a refusal there must not leave a spawn with no child — that ordering
   is the fix, and a lone `:spawn` from a refused lease is the old bug.
4. **A one-shot child whose only output was a prose tool call fails rather than answering.** Ask
   for a subagent whose model responds with a bare tool-call envelope instead of an answer: the
   completion carries `lifecycle: failed`, `error: Lain::Tools::Subagent::MalformedAnswer`, and no
   `result` key — the parent's tool call comes back `error: the child's turn was a tool call
   written as prose, not an answer`, not delivered as though it were the child's findings.

A write that cannot land is itself journaled, as `ending_not_recorded` naming the spawn and which
record was lost, rather than dropped silently.

Then the depth cap: ask for a subagent that spawns a subagent that spawns a subagent. The refusal
**emits no event and touches no Store** — so check both halves. A depth refusal that journals a
spawn has created a child that does not exist, and every later fold counts it. **Unreachable from
chat as of round 17** (a one-shot child's toolset does not spawn); record it so.

**The subagent's chain starts at a FRESH root, and its lineage lives beside the chain, never in
turn `meta`.** This paragraph used to say the child's root carries `meta["spawned_from"]`; that
shape was never written in production, and every lineage reader that walked it found nothing (round
17's F98). The `:spawn` message's payload names the parent's head as `spawned_from`, the completion
`message` names the spawn and the child's final turn, and the session file holds each child turn as
a `child_turn` record. Confirm both directions: the lineage survives (the spawn's `spawned_from`
resolves to a parent turn), and the child **never inherits the parent's prompt**. Put a distinctive sentence in the parent's context — a `/btw`-worthy
aside, a memory item — and confirm it is absent from the child's request.

## 3 — `actor` mode, and `--isolation worktree`

This is the section the scenario exists for, and the question it used to open with is closed now.

**Leasing by a model-dispatched spawn is no longer open** — `--isolation`'s help text and
`CLI::Wiring` agree: the flag is resolved exactly once per launch (`Wiring#fleet_isolation`) and
that one backend is shared between the `Supervisor` an actor adopts onto and the
`Isolation::Leases` a **one-shot** dispatch holds through too (`Tools::Subagent#run_child`),
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
3. **The `isolation_lease` records — which reach the session file only since 2026-09-14.** Round 17
   watched a lease appear and disappear in `git worktree list` in a session holding **zero**
   `isolation_lease` records: they went to the chat's display channel and were dropped (F92). A zero
   here is that defect back. They must name the concrete backend that actually isolated the
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

Then the crash, which is where the real-`git` seams are:

```bash
# kill the session hard, mid-lease
lain chat ... &  # then SIGKILL it while a one-shot child holds a worktree
git worktree list                      # a leftover checkout
lain worktrees gc                      # what happens to it
```

**Corrected by round 17: nothing reaps a crashed lease before the next add, and gc KEEPS a dirty
one.** Leases are random-id paths, so the next run adds beside the leftover rather than over it, and
`lain worktrees gc` reports `kept worktree <path>: uncommitted changes; retained until <date>` — a
dirty crashed checkout is retained for 7 days (`[isolation] retain_days`), never discarded. That is
the design: nothing a worker made is thrown away unasked.

**Since 2026-09-14 a retained checkout also lets go of its branch.** Round 17's epic driver could
not retry an issue because the retained dirty lease still had `lain/issue/<slug>/<id>` checked out
(F99). A retained or moved-aside checkout now anchors its HEAD and **detaches** it; the files stay.
Check `git -C <retained path> symbolic-ref -q HEAD` exits non-zero and `git switch <that branch>`
works in a fresh worktree. And gc no longer calls a fresh checkout "landed" just because its HEAD is
reachable from `main`: a checkout still at the commit lain cut it at is kept as `nothing has landed
since it was cut; retained until <date>`. *(Prediction, not yet driven: strings read from
`isolation/gc.rb`.)*

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
- **A pipe runs, through `sh -c` inside the container.** This bullet used to expect a named
  `Unsupported` refusal; that was replaced when the term arm learned to fall back to the model's own
  string (`shell-terms.md` §7 drives it, and its `shell_arm` record reads
  `"verdict":"allow","arm":"string"`). Round 17 ran `cat lib/b/b.rb | wc -l` under `--exec docker`
  at exit 0, and the `--exec` help now says so (*driven 2026-09-14*: "`docker` takes one argv, so a
  pipeline it cannot reconstruct falls back to the model's own string, run as `sh -c` INSIDE the
  container").
- **The timeout kills the client AND ends its container.** Drive `sleep 600` against the deadline
  and confirm the named `Timeout` rather than a hang. This is the same shape as `rust-cli.md`'s
  long-running-command section, one backend over. **Round 18 added the second half**, which is
  the one to drive now: every `docker run` carries `--init` (so PID 1 relays signals even where
  the image's entrypoint will not) and a `--name` of the shape `lain-<pid>-<entropy>-<n>`, and a
  timeout runs `docker kill` then `docker rm -f` against that name under a **5-second cleanup
  budget of its own**, separate from the command's timeout, so a black-holed daemon cannot turn a
  bounded timeout into an unbounded hang.

  ```bash
  docker ps -a --format '{{.Names}}' | grep '^lain-' || echo "clean"
  ```

  Take it before and after, and use a process that **ignores TERM** (`trap '' TERM; sleep 600`)
  so the check is about the kill rather than about the process being polite. Nothing `lain-*` may
  be left behind. If cleanup could not *confirm* the stop, the `Timeout`'s message says so —
  `container <name> may still be running -- cleanup could not confirm it stopped` — and that
  sentence beside an actually-clean `docker ps -a` is correct, not a finding: it reports the
  confirmation failing, not the container surviving. A leftover container **with** no such
  sentence is the finding.
- **A stopped daemon surfaces as a tool error**, named in the class doc rather than pretended away.
  Stop the daemon mid-session and confirm the model gets a legible tool error and the session
  survives. A session that dies because docker did is worse than the error. **On this box `docker`
  is podman's emulation, which has no daemon to stop** (round 17) — say so rather than marking the
  bullet passed.

And the control that makes the section mean anything: run the **same three commands** under
`--exec local` and diff the results. Different toolchains, same gate, same refusal vocabulary.

## 5 — `lain watch`

The one surface that renders a single spawn's lineage. Round 17 drove it over one-shot spawns (a
live actor has no chat path, see the top of this file).

```bash
lain watch                        # no selector -- EmptySelector
lain watch ''                     # same
lain watch zzzz                   # a prefix matching nothing
lain watch <spawn-digest-prefix>  # from §2 or §3
lain watch <prefix> --session <path>
```

**A bare hex prefix works since 2026-09-14**, as it does for `/pin`, `/rewind` and `--fork`; round
17 found only the `blake3:` spelling matched (F119). *Driven 2026-09-14* against a recorded chat
session: `lain watch bfc36418ae69 --session <file>` rendered
`[blake3:bfc36418ae69 spawn] fresh/schema spawned from blake3:ff9ca1f05f4a` and its completion, the
same as the full digest. **A no-match names the file it searched**: `lain watch zzzz --session
<file>` → `no spawn matched selector "zzzz" in <file's basename>`, exit 1.

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
say nothing. Round 17 found it launched silently (F118). *Driven 2026-09-14*, `env -u TMUX lain chat
--windows`, exit 1:

    --windows opens panes in the tmux session this process is already inside, and $TMUX is not set -- start tmux first, or drop --windows

`lain up`'s own pre-flight, run from a shell outside tmux, must **not** refuse the same flag — the
chat it launches will be inside the session `lain up` creates.

Then, inside tmux, spawn two subagents and check:

- **one window per spawn**, named by the spawn's digest (round 17: `subagent-a6bd8454`) rather than
  by an index. Two concurrent spawns of **different** prompts must now open **two** windows — round
  17's F97 opened one for both — and the HUD's `fleet` must count two until each completes.
  *(Prediction, not yet driven.)*
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
