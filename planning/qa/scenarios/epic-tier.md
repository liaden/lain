# Scenario: the epic tier, without a forge

**What it exercises:** `lain epic status / queue / approve / deny / submit / land`,
`Epic::Home` (both `[epics] home` values), `Epic::Stage`'s boundary rule, `Epic::Scribe` as the one
write path, `Approval::Gate::Policies` and all four policies, `Approval::SignoffQueue` as a **fold**
rather than a file, and the `[epics]` / `[epics.gates]` config refusals.

**The question it answers:** does a four-stage pipeline stay honest when nothing but a journal
remembers where it is? Every verdict here is a journaled `gate_decision`, every advance is a
`stage_transition`, and no command holds state between invocations — so two readers of the same
journals must agree by construction, and a damaged record must **abort** rather than read as
drained.

**Cost:** cheap. Everything below is deterministic and needs no model at all **except §5d**
(`adjudicated`), which spawns a local role and is the one act that costs a model call.

**Needs:** a project directory, `git` for §1b only. `bench.md` up **only for §5d**. No nvim, no
tmux, no network — `lain epic land` is driven for its refusals alone (§8), because landing itself
needs a forge and this scenario deliberately stops at the gate.

**Why it is worth a scenario at all:** ~4,100 lines of the epic tier, and until this document
existed nothing in `planning/qa/` mentioned the word `epic`. Every claim about the stage boundary,
the four policies and the drain rested on specs alone.

---

## 0 — The subject: an epic the driver writes by hand

**Write it fresh per round, and write it yourself.** The tier reads markdown a human authored; a
model-authored epic makes "the status report named the wrong issue" a finding nobody can repeat.
Four issues is the minimum that exercises the graph (a blocker, a blocked, a discovered-from edge,
and one that is `abandoned` — which is the case §2 turns on).

```bash
export QA_PROJ="$QA/epic-subject"; mkdir -p "$QA_PROJ"; cd "$QA_PROJ"
cat > .lain/config.toml <<'TOML'
[epics]
home = "xdg"
TOML
```

Then create the home's layout — `research.md`, `epic.md`, `issues/<id>.md`, `plans/<id>.md` — under
the resolved home. **`lain epic status` prints the home it resolved**, so run it once with an empty
home first and write into the path it names rather than reconstructing
`<state_home>/epics/<project_hash>/` by hand. That path is a hash; a driver that guesses it writes a
second epic nobody reads and then files "status shows nothing" as a defect.

Runtime state is deliberately **absent** from that tree: an issue's status is the journal fold, never
a file. If a round finds a status file there, that is the finding.

## 1 — Where the home is, and the trap in `repo` mode

`[epics] home` takes exactly `"xdg"` or `"repo"` and nothing else.

```bash
# each of these must refuse at load, naming the config path, exit 1, no backtrace
printf '[epics]\nhome = "repo "\n'      > .lain/config.toml && lain epic status
printf '[epics]\nhoem = "repo"\n'       > .lain/config.toml && lain epic status
printf '[epics]\nhome = ["repo"]\n'     > .lain/config.toml && lain epic status
printf 'epics = "repo"\n'               > .lain/config.toml && lain epic status
```

Expected shapes: `[epics] must be a table, got String: "repo"`; `[epics] has no keys "hoem"; known
keys: home, gates`; and an invalid-home refusal naming the two legal values. **Every one names the
config file path first** — a refusal that says only "[epics] …" sends an operator hunting through
three possible config locations.

### 1b — the repo-mode trap, which is a real one

`home = "repo"` resolves under `<root>/.lain/epics/`, and **this repository's own `.gitignore`
holds `/.lain/`** — so the mode chosen specifically so a team can review an epic in a pull request
can produce a tree git will never show them. `Epic::Home` does not detect this (it is a pure path
calculator with no subprocess); `lain epic status` does, beside the line where it prints the home.

```bash
git init -q .; printf '/.lain/\n' > .gitignore
printf '[epics]\nhome = "repo"\n' > .lain/config.toml
lain epic status
```

**Expect a warning naming the ignored path.** Silence here is the defect — and it is the failure
mode that reads as success, because everything else works perfectly right up until the PR is empty.

## 2 — `status`, and the remaining-work rule

Three refusals and one report:

```bash
lain epic status no-such-epic     # UnknownEpic
lain epic status                  # with TWO epics in the home: Ambiguous, never a guess
chmod 000 "$HOME_DIR" && lain epic status   # UnreadableHome -- not "no epics yet"
```

`Ambiguous` matters more than it looks: picking the alphabetically-first would report on work the
caller never asked about, **in the one command whose entire job is telling the truth about which
work is where**.

Then the rule this section exists for. **Not done is remaining, and `done` is the only thing that
counts as done.** Mark one issue `abandoned` and one `done`, leaving a third blocked by the
abandoned one:

- the abandoned issue **must still appear** in the listing, and must still block what it blocked
  (`Epic::Graph#ready` satisfies a blocker only when it is `done`);
- **every id named in a `blocked by` annotation must be present in the listing above it.** An
  earlier draft treated `abandoned` as finished and produced a report that explained a blockage
  with an id the reader could not find anywhere on the page. That is the regression to look for,
  and it is invisible unless the fixture actually has an abandoned blocker in it.

Run `lain epic status` twice and `diff` the two outputs. **It is documented read-only and
deterministic** — same home, same session files, same bytes. A diff is a finding.

## 3 — `[epics.gates]`, refused at load and for every stage

Both sides of the mapping are closed sets. A typo in a stage name is the dangerous one: silently
dropping `reserch = "deferred"` leaves that stage `interactive`, and an unattended run then wedges
on a gate nobody is there to answer.

```bash
printf '[epics.gates]\nreserch = "deferred"\n'        # UnknownStages, naming the pipeline
printf '[epics.gates]\nresearch = "defered"\n'        # UnknownPolicies, naming the known set
printf '[epics]\ngates = "deferred"\n'                # NotATable -- note [epics], NOT [epics.gates]:
```

Expected: `[epics.gates] has no stages "reserch"; the pipeline is research -> epic_plan ->
issue_plan -> implementation`, and a policy refusal naming `interactive, hands_off, deferred,
adjudicated`. **Every unknown key is reported in one pass**, not just the first — put two typos in
and check both are named.

**Then the property that makes this worth doing at launch at all:** `Policies.for_all` resolves
EVERY stage's policy, not only the stage being submitted. So configure `implementation =
"adjudicated"` in a session with no `role_spawn` seam and submit **`research`** — an entirely
different stage. It must still refuse at wiring:

```
epic stage "implementation" is configured for the "adjudicated" gate policy, but this session is
missing role_spawn, brief
```

A run that submits `research` happily and only discovers the broken `implementation` wiring at 3am
on the overnight gate is the regression. This check is the whole reason `for_all` exists, and it
cannot be seen by submitting the stage you configured.

## 4 — `submit`, and which artifact each stage names

Two stages submit the epic's own documents and need nothing but the home. Two are about one issue,
and `implementation` has **no document in the home at all** — it gates a changeset digest.

```bash
lain epic submit research
lain epic submit epic_plan
lain epic submit issue_plan                          # NeedsIssue
lain epic submit issue_plan --issue I-2
lain epic submit implementation --issue I-2          # NeedsDigest
lain epic submit implementation --issue I-2 --digest sha256:...
lain epic submit reserch                             # UnknownStage
```

Exact refusals, and each **ends with the command that would work**:

```
the issue_plan stage gates one issue's work, and nothing named the issue -- lain epic submit issue_plan --issue ID
the implementation stage gates a changeset, and no artifact in the epic home addresses one -- lain epic submit implementation --issue ID --digest ADDRESS
```

**Nothing re-hashes a working tree to invent that digest**, and that is deliberate: a second opinion
on the same content is how two records of one thing start disagreeing. If a round finds `submit
implementation` succeeding with no `--digest`, the boundary has moved and §8's guarantee is gone
with it.

## 5 — The four policies

One epic, one stage, re-run under each `[epics.gates]` value. Read the journaled `gate_decision`
after each and check **both** `answered_by` (who decided) and `policy` (how) — they are independent
axes and a surface that collapses them cannot tell a human's approval from a 4B model's.

```bash
peek(){ ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "#{r["policy"]}\t#{r["answered_by"]}\t#{r["approved"]}\t#{r["stage"]}" if r["type"]=="gate_decision"}' "$JOURNAL"; }
```

### 5a — `interactive` (the default)

A `y/N` prompt on the streams the command was handed. `y`, `yes` and `approve` are affirmative;
**everything else including EOF is a refusal**, which is the fail-closed default.

```bash
printf 'y\n'  | lain epic submit research
printf 'n\n'  | lain epic submit research
printf ''     | lain epic submit research      # EOF -> denied
```

Then the case that used to print a backtrace: **a non-interactive session configured `interactive`**.
`Prompt.on` judges BOTH streams, so a half-wired session must refuse by name rather than reach
`nil.write` from inside the reactor.

```bash
lain epic submit research < /dev/null > /dev/null   # neither stream a tty
```

Expect a named `Lain::Error` through the exe's mapping — one clean line, exit 1, **no backtrace**. A
`NoMethodError` here is the round's finding.

### 5b — `hands_off`

Approves without asking. Check the record says so: `policy` is `hands_off` and `answered_by` is
**not** `human`. A `hands_off` decision that journals `answered_by: "human"` makes the whole
experiment record a lie, and it is exactly the kind of thing that is invisible on screen.

### 5c — `deferred`

Parks instead of deciding. Then §7's fold is what sees it.

### 5d — `adjudicated` — the one model call

Spawns a role over the artifact and settles the verdict, parking anything it is unsure about.
Configure it, submit, and read the journal:

```bash
printf '[epics.gates]\nresearch = "adjudicated"\n' >> .lain/config.toml
lain epic submit research
```

Expected: a `gate_evidence` record for the spike, and a terminal `gate_decision` with `policy:
"adjudicated"`. **The uncertain branch is what to push on** — an adjudicated gate that never parks
anything is one that has stopped adjudicating. Drive it a second time against a deliberately
ambiguous artifact (a `research.md` holding one sentence and no acceptance criteria) and confirm it
parks rather than approving.

**The invariant this policy carries and nothing downstream can check:** its journal, the gate's
journal and the decisions read back must be ONE stream. A read pointed elsewhere answers "nothing
was decided" forever — a terminal-verdict guard that never fires, with nothing failing to say so.
There is no way to check that from outside the process; what §9 CAN check is that a second terminal
verdict on the same address is refused. Drive `approve` twice on one digest.

## 6 — The stage boundary, which is the ruling this tier turns on

**A stage's gates may only open when every EARLIER stage's sign-off partition is drained.** Deferring
is allowed to accumulate *within* a stage — that is what deferring is for — but it may never cross a
boundary, or an epic reaches implementation on a plan nobody signed off.

```bash
printf '[epics.gates]\nresearch = "deferred"\n' > .lain/config.toml
lain epic submit research          # parks
lain epic submit epic_plan         # MUST refuse: StageBlocked
```

Then the half that proves the key is a **pair** and not a global:

```bash
# a SECOND epic in the same home, its research untouched
lain epic submit epic_plan other-epic     # MUST proceed -- partitions are (epic_slug, stage)
```

A global drain would let one epic's unreviewed research block every other epic's planning, and
concurrent epics are the normal case. **Both halves, or this section tests nothing** — a boundary
that refuses everything passes the first check and is useless.

## 7 — `queue`, `approve`, `deny`: draining is journaling

The queue is a **fold**, not a file: an artifact is parked exactly when a `deferred` decision has no
LATER terminal one for the same `(artifact_digest, epic_slug, stage)`. So `approve`/`deny` append a
terminal `gate_decision` and let the next fold see the partition drained.

```bash
lain epic queue
lain epic approve <digest> --reason 'read it, it is fine'
lain epic queue                                   # the row is gone
lain epic deny <unknown-digest>                   # UnknownDigest, and it LISTS what IS parked
```

`UnknownDigest` listing the near-miss is not politeness: the digest is 71 characters and the one
thing a reader needs is what they typed set beside what is actually there.

**The honest empty is the check nobody thinks to make.** The empty rendering must name the directory
it read **and what it understood there** — lines seen, records kept, lines it could parse nothing
from. Point the queue at a session dir holding one unparseable file and confirm the empty listing
distinguishes "nothing is parked" from "I understood none of this":

```bash
printf 'not json at all\n' > "$SESSIONS/junk.ndjson"
lain epic queue
```

A count of FILES cannot tell those apart, and this is the one screen a human reads specifically to
decide that nothing is outstanding.

Finally, check `--reason` reaches the record, and that `answered_by` is `human` and `policy` is
`signoff` for both verbs.

## 8 — `land`, at the gate and no further

Landing needs a forge. Everything before the first forge intent does not, and that is what this
scenario drives:

```bash
lain epic land                                  # NeedsArguments: "... -- lain epic land ISSUE_ID SHA [SLUG]"
lain epic land I-2 $(git rev-parse HEAD)         # NotApproved -- nothing approved this sha
lain epic land I-2 HEAD                          # refused: not a full object name
lain epic land I-2 abc1234                       # refused: an abbreviation is not an anchor
lain epic land --resume I-9                      # NothingToResume
lain epic land --resume I-2 slug-a slug-b        # "accepts at most one slug"
```

**The `NotApproved` case is the one that matters, and it is structural rather than checked.** No
record binds an approved implementation to a commit — the binding is the HASH. So a sha nobody
approved rebuilds to an address the registry has never seen, and the run refuses **before the first
intent**. Landing an unapproved commit is unrepresentable here, not merely detected. Verify the
journal holds **no forge intent at all** after each refusal above; an intent written before the gate
answered is the finding, and it is one a screen-reading driver will miss entirely.

`--resume` deliberately takes **no sha** — it derives one from the journaled promote intent, which
by construction carries the sha the gate cleared. Accepting one would let a human resume a landing
onto a different commit than the one that was approved. Confirm `lain epic land --resume I-2 <sha>`
treats that second positional as a **slug**, per the exe's own comment, rather than as a sha.

## 9 — The fold must abort, never read empty

`SignoffQueue.from_journal` raises on a record it cannot read whole, and **nothing in `EpicQueue`
rescues that**. The ergonomic response — an empty queue on failure — is maximally fail-open: an
empty queue reads as drained, drained opens the next stage, and the stage opens over work nobody
signed off.

Park something, then damage its `gate_decision` record the way `failure-injection.md` §2 damages a
turn — truncate the line mid-object, and separately flip one byte of `artifact_digest`:

```bash
lain epic queue        # MUST refuse by name, exit 1, no backtrace
lain epic submit epic_plan   # and the boundary check must refuse too, not silently pass
```

The second command is the one that proves it. A queue that refuses on the read but a **boundary
check that quietly treats an unreadable partition as drained** is the same fail-open bug one layer
down, and it only shows if the round drives a submit after the damage rather than stopping at the
listing.

Restore the journal afterwards and confirm both commands come back — a scenario that leaves the
subject broken cannot tell a fix from a corpse next round.
