# Scenario: the epic tier, end to end

**What it exercises:** `lain epic status / queue / approve / deny / submit / add / split / merge /
land / finish`, `/implement-epic` and the `lain://status` buffer, `lain worktrees gc`, `Epic::Home`
(both `[epics] home` values), `Epic::Stage`'s boundary rule, `Epic::Scribe` as the one write path,
`Approval::Gate::Policies` and all four policies, `Approval::SignoffQueue` as a **fold** rather than
a file, and the `[epics]` / `[epics.gates]` / `[isolation]` / `[tests]` config refusals.

**The question it answers:** does a four-stage pipeline stay honest when nothing but a journal
remembers where it is — and does the driver that works it to a branch stay honest about which issue
failed and why? Every verdict here is a journaled `gate_decision`, every advance is a
`stage_transition`, and no command holds state between invocations, so two readers of the same
journals must agree by construction and a damaged record must **abort** rather than read as drained.

**Cost:** §0–§9 are deterministic and need no model at all **except §5d** (`adjudicated`), which
spawns a local role. §10 (the driver) runs a real model over real issues and is the expensive part;
drive it against a local model on a two-issue fixture.

**Needs:** a project directory and `git`. A throwaway GitHub repo for §12 (`finish`) only —
everything up to and including local landing pushes nothing. nvim and tmux for §11 only.

**This scenario has never been driven end to end.** Sections 0–9 were driven at the gate; §10–§13
are new with the epic loop closing, and are the ones most likely to find something.

---

## 0 — The subject: an epic the driver writes by hand

**Write it fresh per round, and write it yourself.** The tier reads markdown a human authored; a
model-authored epic makes "the status report named the wrong issue" a finding nobody can repeat.
Four issues is the minimum that exercises the graph (a blocker, a blocked, a discovered-from edge,
and one that is `abandoned` — which is the case §2 turns on). For §10 you want **two** issues that
can actually be implemented by a small model in a fixture project: keep them tiny and independent.

```bash
export QA_PROJ="$QA/epic-subject"; mkdir -p "$QA_PROJ"; cd "$QA_PROJ"
cat > .lain/config.toml <<'TOML'
[epics]
home = "xdg"
TOML
```

**The issues live INSIDE `epic.md`, in that document's own markdown grammar — NOT as
`issues/<id>.md` files with status frontmatter.** This paragraph said otherwise until round 13,
which hand-wrote the layout as described, got a silent **zero** issues out of a non-empty `epic.md`,
and then read `Epic::Document.parse_markdown` — `Graph.new(issues: Reader.new(source).issues)`,
parsed from the epic document, with everything above the first heading dropped as preamble. Write
`epic.md` to that grammar and verify the count in `lain epic status` before building anything on top
of it: a driver following the old wording gets `0/0 done` and `remaining: nothing -- every issue is
done`, which reads like a finished epic rather than an unparsed one.

**`lain epic status` prints the home it resolved**, so run it once with an empty home first and
write into the path it names rather than reconstructing `<state_home>/epics/<project_hash>/` by
hand. That path is a hash; a driver that guesses it writes a second epic nobody reads and then files
"status shows nothing" as a defect.

Runtime state is deliberately **absent** from that tree: an issue's status is the journal fold,
never a file. If a round finds a status file there, that is the finding.

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
  with an id the reader could not find anywhere on the page.

Run `lain epic status` twice and `diff` the two outputs. **It is documented read-only and
deterministic** — same home, same session files, same bytes. A diff is a finding.

### 2b — the mermaid rendering

```bash
lain epic status --mermaid
```

Renders the issue graph as mermaid flowchart source instead of the text report. Two things to check,
because both were bugs once: **node ids are injective** (two issues whose ids sanitize to the same
token must not collide into one node), and labels **escape** `&`, `<`, `>`, `"` and `#`. Paste the
output into any mermaid renderer and confirm it draws; a diagram that fails to parse is a finding
even though the command exited 0.

## 3 — `[epics.gates]`, refused at load and for every stage

Both sides of the mapping are closed sets. A typo in a stage name is the dangerous one: silently
dropping `reserch = "deferred"` leaves that stage `interactive`, and an unattended run then wedges
on a gate nobody is there to answer.

```bash
printf '[epics.gates]\nreserch = "deferred"\n'        # UnknownStages, naming the pipeline
printf '[epics.gates]\nresearch = "defered"\n'        # UnknownPolicies, naming the known set
printf '[epics]\ngates = "deferred"\n'                # NotATable -- note [epics], NOT [epics.gates]
```

Expected: `[epics.gates] has no stages "reserch"; the pipeline is research -> epic_plan ->
issue_plan -> implementation`, and a policy refusal naming `interactive, hands_off, deferred,
adjudicated`. **Every unknown key is reported in one pass**, not just the first — put two typos in
and check both are named.

**Then the property that makes this worth doing at launch at all:** `Policies.for_all` resolves
EVERY stage's policy, not only the stage being submitted. `lain epic submit` builds the
adjudication pair whenever ANY stage is configured `adjudicated`, and builds no provider at all
otherwise. So configure `implementation = "adjudicated"`, unset the provider's API key, and submit
**`research`** — an entirely different stage. It must still refuse at wiring, before anything is
journaled, naming the missing key. Then set every stage `interactive` and submit again with the key
still unset: that must succeed, because a session with nothing to adjudicate never constructs a
provider.

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
lain epic submit issue_plan --issue export-stream
lain epic submit implementation --issue export-stream            # NeedsDigest
lain epic submit implementation --issue export-stream --digest sha256:...
lain epic submit reserch                             # UnknownStage
```

Exact refusals, and each **ends with the command that would work**:

```
the issue_plan stage gates one issue's work, and nothing named the issue -- lain epic submit issue_plan --issue ID
the implementation stage gates a changeset, and no artifact in the epic home addresses one -- lain epic submit implementation --issue ID --digest ADDRESS
```

**Nothing re-hashes a working tree to invent that digest**, and that is deliberate: a second opinion
on the same content is how two records of one thing start disagreeing.

### 4b — an implementation approval is scoped to its issue

**The implementation artifact digest composes the issue id.** Submit the same changeset digest for
two different issues and approve one: the other must still read as unapproved. An approval that
leaked across issues would let one issue's sign-off land another's code, and it is invisible on
screen because both rows show the same changeset.

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
experiment record a lie.

### 5c — `deferred`

Parks instead of deciding. Then §7's fold is what sees it.

### 5d — `adjudicated` — the one model call

Spawns a role over the artifact and settles the verdict, parking anything it is unsure about.

```bash
printf '[epics.gates]\nresearch = "adjudicated"\n' >> .lain/config.toml
lain epic submit research
```

Expected: a `gate_evidence` record for the spike, and a terminal `gate_decision` with `policy:
"adjudicated"`. **The uncertain branch is what to push on** — an adjudicated gate that never parks
anything is one that has stopped adjudicating. Drive it a second time against a deliberately
ambiguous artifact (a `research.md` holding one sentence and no acceptance criteria) and confirm it
parks rather than approving.

What §9 CAN check is that a second terminal verdict on the same address is refused. Drive `approve`
twice on one digest.

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
concurrent epics are the normal case. **Both halves, or this section tests nothing.**

## 7 — `queue`, `approve`, `deny`: draining is journaling

The queue is a **fold**, not a file: an artifact is parked exactly when a `deferred` decision has no
LATER terminal one for the same partition. So `approve`/`deny` append a terminal `gate_decision` and
let the next fold see the partition drained.

```bash
lain epic queue
lain epic approve <digest> --reason 'read it, it is fine'
lain epic queue                                   # the row is gone
lain epic deny <unknown-digest>                   # UnknownDigest, and it LISTS what IS parked
```

**The honest empty is the check nobody thinks to make.** The empty rendering must name the directory
it read **and what it understood there** — lines seen, records kept, lines it could parse nothing
from:

```bash
printf 'not json at all\n' > "$SESSIONS/junk.ndjson"
lain epic queue
```

A count of FILES cannot tell "nothing is parked" from "I understood none of this", and this is the
one screen a human reads specifically to decide that nothing is outstanding.

Finally, check `--reason` reaches the record, and that `answered_by` is `human` and `policy` is
`signoff` for both verbs.

## 8 — Editing the graph: `add`, `split`, `merge`

Restructuring is a command, not a hand edit, and each one is journaled as a `graph_revision`.

```bash
lain epic add late-discovery "Something the work turned up" --discovered-from=export-stream
lain epic split export-stream --into=export-stream-buffer,export-stream-writer
lain epic merge left-id right-id --as=merged-id --title="One issue instead of two"
```

What to check, because the edge rewrite is the whole point:

- after a **split**, every part carries the original's outbound edges, **every part's provenance is
  the split issue** even if it declared its own, and the original is gone from the graph while its
  id survives in `Discovered from:`;
- after a **merge**, the result carries both sides' edge sets minus the self-references the rewrite
  would otherwise create;
- after each, `lain epic status` shows a graph with **no dangling `Blocks:` edge**.

Then the trap that fails silently: **abandoning a blocker does not unblock what it blocked.** Mark a
blocker `[!]` and confirm its dependents are still not `ready`. Unblocking is an edge edit.

## 9 — The fold must abort, never read empty

`SignoffQueue.from_journal` raises on a record it cannot read whole, and **nothing in `EpicQueue`
rescues that**. The ergonomic response — an empty queue on failure — is maximally fail-open: an
empty queue reads as drained, drained opens the next stage, and the stage opens over work nobody
signed off.

Park something, then damage its `gate_decision` record — truncate the line mid-object, and
separately flip one byte of `artifact_digest`:

```bash
lain epic queue              # MUST refuse by name, exit 1, no backtrace
lain epic submit epic_plan   # and the boundary check must refuse too, not silently pass
```

The second command is the one that proves it. A queue that refuses on the read but a **boundary
check that quietly treats an unreadable partition as drained** is the same fail-open bug one layer
down, and it only shows if the round drives a submit after the damage.

Restore the journal afterwards and confirm both commands come back — a scenario that leaves the
subject broken cannot tell a fix from a corpse next round.

## 10 — The driver: `/implement-epic`

This is the new half, and it has never been driven. It needs the epic's issues **approved**, a
`[tests]` table (§13), and a `Subject:` line in each issue's plan.

### 10a — what an issue needs before it can start

Each issue is implemented from `plans/<id>.md` in the epic home, and that plan declares the one
source file its generated failing tests mirror:

```
Subject: lib/exporter/stream.rb
Level: unit
```

Drive each refusal — every one names the plan path:

- **no `Subject:` line at all** — refused, telling you to add one;
- **two `Subject:` lines** — refused as ambiguous rather than picking the first;
- **a non-canonical subject** (`/abs/path`, `../escape`, `a//b`, `trailing/`) — refused, and this one
  matters because a subject that escaped would write the generated test outside the checkout;
- **a subject under no declared source root** — refused, naming the roots;
- **an unknown `Level:`** — refused, naming the levels `[tests]` declares.

A subject that does not exist yet is **fine** — a test written before its class is the normal case.

### 10b — startable means `in_flight`

**Approving the issue's plan is the one writer of the `pending -> in_flight` transition.** So:

- an issue whose plan is still `pending` is **reported and skipped**, never started;
- the run does not stall on it, and does not report it as failed.

Confirm both by leaving one of the two issues unapproved and driving the run.

### 10c — the run

```bash
lain chat --epic <slug> --windows
```

then at the `you>` prompt:

```
/implement-epic
/implement-epic --width 1
```

`--width` is the only flag it takes; it defaults to 2. Check that `--width 0`, `--width -1` and
`--width two` are each refused by name, and that an unknown flag is refused rather than read as an
argument.

What to watch for:

- **each issue runs in its own worktree**, cut from `epic/<slug>` and switched onto a lain-owned
  branch `lain/issue/<slug>/<id>`. Nothing reaches the human's checkout, and nothing reaches
  `epic/<slug>` before that issue's implementation gate;
- **the red step commits with `--no-verify`**, because the commit is red by design and a target
  project's own pre-commit hook would refuse exactly the state the step exists to record. Confirm
  the failing-test commit exists and that the tests in it actually fail;
- **generated tests that already pass are refused** — if the red step reports examples ran and none
  failed, nothing is committed, because tests that pass before any work check nothing;
- **a per-issue refusal stops that issue, never the run.** Break one issue deliberately (an
  unsatisfiable criterion) and confirm the other still lands;
- **Ctrl-C stops between issues**, not mid-merge. Work still in flight is reported as unsettled.

### 10d — the gate during an unattended run

At most **one** gate may be outstanding at a time, and a gate that is denied or times out must
**withdraw its question**. Drive a denial and then confirm the next issue's gate still opens: a
withdrawn question that was left outstanding killed the following gate, and it is invisible until
the second issue.

### 10e — retries

The attempt is derived from the anchors already in the repository. Stop a run mid-issue, then drive
`/implement-epic` again: the issue must **launch a new attempt** rather than being refused because
the first attempt's anchor still stands.

## 11 — The `lain://status` buffer

Needs the nvim cockpit. The attach protocol is **15**; a mismatch warns and keeps going rather than
failing the attach.

```bash
lain up --nvim        # then, in the chat pane, lain chat --epic <slug>
```

In nvim, open `lain://status`. Expect: the epic slug, a progress summary, one line per issue with
its mark and state (a pending issue reads `pending, ready` or `pending, blocked by ...`), a
```mermaid fence holding the graph, and a `## fleet` section listing what is running.

Three checks:

- **without `--epic`** it says no epic is mounted rather than drawing an empty graph;
- it **re-reads from disk** when a turn completes, so a transition written by a *different* `lain`
  process shows up after the next turn — drive `lain epic approve` in another terminal and confirm
  the buffer catches up;
- a **fold failure is drawn into the buffer, not raised**: a raise here would kill the drain thread
  and freeze every other buffer. Corrupt a session file and confirm the buffer says so while the
  rest of the cockpit keeps working.

## 12 — Landing, and then finishing

**Landing is local and pushes nothing.** This is the part the old version of this scenario could not
drive.

```bash
lain epic land                       # NeedsArguments, ending in the command that works
lain epic land export-stream         # lands one approved issue onto epic/<slug>
lain epic land --resume export-stream
```

`lain epic land` takes an **issue id, never a commit**. The SHA argument is gone: the commit it
lands is the one anchored when the implementation gate approved it — found, not named. So confirm
there is no way to type a commit at it, and that an issue whose implementation was never approved
refuses **before any forge intent is journaled**.

Two more:

- **an unapproved plan refuses**, even when the implementation is approved — an implementation parked
  before its plan was edited can still be approved from the queue, so landing re-checks the plan;
- **`nothing_to_do`** counts as landed only when this issue's own merge is already journaled.

Then the one command that needs a forge, against a **throwaway** GitHub repo:

```bash
lain epic finish
```

Takes an epic whose every issue is done to `main` as one pull request, then deletes its remote
branch. Check that a re-run over an already-`MERGED` PR reads as done rather than opening a second,
and that moving the `epic/<slug>` tip and finishing again is treated as a **new** finish.

**Known gap, and not a finding:** a merge whose handback record never reached the journal refuses
both `land` and `--resume`, and there is no command to adopt it. If you hit it, record it; it is a
recorded follow-up.

## 13 — Test layout, and worktree GC

### 13a — `[tests]` is opt-in

**With no `[tests]` table, nothing is refused.** Confirm that first, because it is the default every
target project starts in: drive a write to a badly-placed test file and check it goes through, with
one `test_layout_absent` record journaled to say the guard ran with nothing to enforce.

Then declare a layout and re-drive:

```toml
[tests]
preset = "rspec"
```

- a child's write to a **split sibling** of the mirrored path is refused, and the refusal **names the
  right path**;
- a test-named file **outside every level root** is refused as stray;
- a file whose level is wrong for the root it sits in is refused;
- **a refusal never names a path the guard itself would refuse** — that would send the author to a
  second refusal;
- `:no_source` (a test written before its class) is **let through at write time** with a journal
  note, and **refused at land time**. Drive both halves;
- an `edit_file` that changes a test's subject passes at write time and is caught at land time.

Also drive the refusals: an unknown key in `[tests]`, a `[tests]` table with no `preset`, and a
preset that is not one of `rspec`, `minitest`, `pytest`, `cargo`.

### 13b — `lain worktrees gc`

```bash
lain worktrees gc
```

- after merging an epic to `main`, gc **reaps the anchors** and deletes the merged `epic/<slug>`;
- a **dirty** checkout is kept, not removed;
- a lease whose owning process is still alive is kept;
- a lock whose reason gc cannot read means **keep**;
- a stray claim file keeps the tree;
- a second concurrent `gc` does nothing and says so.

Then the launch-gated run: remove the stamp under `$XDG_STATE_HOME/lain/gc/` and start `lain` — it
must spawn exactly **one** detached gc run and renew the stamp. Start `lain` twice in quick
succession with a stale stamp and confirm only one run starts.

### 13c — `[isolation]`

Drive the refusals, each naming the key and what would have been legal: `retain_days = 0`,
`rebase_retries = -1`, `diff_algorithm = "histogram "`, `conflict_style = "zdiff"`, and an unknown
key. Then set `rebase_retries = 0` and confirm worker self-sync is genuinely off.
