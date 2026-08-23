# Scenario: memory, and the two passes that read a finished session

**What it exercises:** `memory_write` / `memory_read` and their shared ceiling, `Memory::Index`'s
content-addressed chain, `Memory::JournalMemoryRoot` (the `memory_root` record beside every
`turn_usage`), the memory manifest riding every Request through `Workspace`, `lain consolidate`,
`lain improve`, `improvement_write`, `lain improvements`, and `lain bench sweep` — the offline
five-arm retrieval eval.

**The question it answers:** does what a session learned come back, and does the record say where
it came from? Memory is the one subsystem where a silent no-op is indistinguishable from success:
an index that never records still answers every read with "no such id", and a consolidation pass
that spawns nothing still exits 0.

**Cost:** cheap to minutes. `bench sweep` and both `--dry-run` passes need **no model at all**. The
live `consolidate` and `improve` passes take one ollama spawn per completed lineage.

**Needs:** `bench.md` up for §4 and §5 only. A **finished** session with completed subagent
lineages — §3 says how to manufacture one cheaply, and without it both passes correctly do nothing
and the round learns nothing.

**What is deliberately NOT here, because it is not wired:** `Context::Recall` — push-recall into the
message tail. It is an opt-in pipeline stage; the default pipeline is `Reminder >> CacheBreakpoints`
with **no memory index to search**, and no chat path composes it. That is a bench axis awaiting a
sweep, not a live path with a gap in its coverage, and a scenario that "drove" it would be measuring
nothing. Recorded here so the next round does not go looking.

---

## 1 — The manifest is context, not a call

The first thing to establish, because it is the thing most easily assumed backwards: **there is no
tool that lists memory.** The manifest rides every Request through `Workspace`, so it is a fact
already in context. `memory_read` fetches the body behind a manifest line and nothing else.

Write three items, then read the journaled request:

```
you> remember, under id `toolchain`, that this box needs ruby 4.0.6 from mise
you> remember, under id `suite`, that the suite command is `bundle exec rake pspec`
you> remember, under id `tmpdir`, that TMPDIR must sit on the repo's filesystem
```

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  next unless r["type"]=="request"; puts r.to_json[/<workspace.{0,600}/m]}' "$JOURNAL" | tail -1
```

Expected: **one id and one description per item**, and **no bodies**. A manifest that carries bodies
turns every turn into a full memory dump and is a cost defect that nothing else here would catch.

Then confirm the model can act on it:

```
you> what do you remember about the suite?
```

It must issue a `memory_read` for `suite` rather than answering from the manifest line — the
description is a pointer, and a model answering from the pointer alone is a prompt problem worth
recording even though it is not a lain defect.

## 2 — The ceiling, on the write, and why

Both tools bound at **256 KiB**, and they are asserted equal rather than remembered. The ceiling is
on the **write**, and that placement is the design:

- a ceiling on the read alone would be an asymmetry with no way out — the write would accept a body
  its sibling then refused **forever**, and the model would be told to shorten bytes it can no
  longer see;
- on the write, "write less" and "split it across ids" are moves the model can actually make,
  because it still holds the bytes.

```
you> memory_write id `big`, description `too big`, body: <a 300 KiB body>
```

Expected refusal, naming the subject, the size and the ceiling, and offering **the two narrower
moves**: "write less — keep the body to what a later read actually needs" and "split it across
several ids, one subject each, so the manifest can point at the right one".

**Then the check that says the pair is really matched:** the write's ceiling being no higher than
the read's makes the read's ceiling *unreachable through the toolset*, which is what lets it be
described as a runaway guard. Confirm there is no accepted write that produces a refused read. If a
round finds one, the two constants have drifted and the read's refusal text — which tells the model
the item "predates the ceiling" — has become a lie.

Drive the read refusal directly anyway, by planting an oversized item in the index outside the
toolset. Its two narrower moves are different from the write's, and both had to be rewritten once
because neither of the first draft's survived being followed — one named a tool that does not exist,
the other was destructive **and** needed the very bytes the refusal withheld. Check the current
pair is followable.

## 3 — The root, the chain, and what a write does not destroy

**A write never destroys the item it supersedes.** So `memory_write` reports the **new root** rather
than "ok" — that root is the caller's only handle on what was readable before the write.

```
you> memory_write id `suite`, description `the suite command`, body: `bundle exec rake pspec, 21-27s`
```

Capture the root it reports. Then overwrite the same id and capture the second root. Both must
resolve:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "#{r["turn_digest"]}\t#{r["type"]}" if %w[turn_usage memory_root].include?(r["type"])}' "$JOURNAL"
```

Two properties, and the second is the one a casual read misses:

1. **Every `turn_usage` is followed by a `memory_root` naming the same turn digest.** The root is
   read from the recorder at the instant the record is written, never cached.
2. **`turn_usage` comes FIRST.** A reader scanning forward must see a turn before its snapshot —
   commit order all the way through. A `memory_root` preceding its `turn_usage` is the finding, and
   it makes every fold that pairs them silently off by one turn.

The Agent stays memory-blind by construction: it never sees `Memory::Index` or the `Recorder`, only
a journal that happens to also remember the root. Nothing outside can verify that directly; what it
CAN verify is the consequence — **no `memory_*` record carries an item body**. Grep the journal for
one of the bodies written above and confirm it appears only in the tool call and result, never in a
telemetry record.

## 4 — `lain consolidate`: the court-clerk pass

Needs a session with **completed subagent lineages**, so manufacture one first:

```
you> spawn a subagent to count the ruby files under lib/ and report the number
you> spawn a subagent to name the three largest files under lib/
you> /quit
```

Then, dry first — and `--dry-run` is not a flag that changes what the method means, it selects a
different method entirely, so treat the two outputs as two reports rather than one report with a
switch:

```bash
lain consolidate <session> --dry-run
```

**Under `--dry-run` the provider is `Provider::Unreachable`.** No API key is fetched and nothing can
quietly reach a model. Verify the negative: unset every provider credential in the environment and
confirm the dry report still runs. A dry run that refuses on a missing key is reaching for a provider
it promised not to.

It must name the lineages that WOULD be clerked. Then the live pass, local:

```bash
lain consolidate <session> --provider ollama --model qwen3-coder:30b
```

Check the three resolutions `lain consolidate` accepts — an explicit path, a bare filename, and a
prefix — and confirm they are **not** `lain chat --resume`'s three, which are a different contract.
A driver who assumes they are the same will file a false defect the first time a selector that
resumes fine fails to consolidate.

Then the outcome: new memory items, written through the recorder, with a new root. Read them back
with `memory_read` in a **fresh** session to prove the chain survived the process that wrote it.
That round trip is the whole point of the pass, and it is the only check that distinguishes "the
pass ran" from "the pass persisted anything".

## 5 — `lain improve`, `improvement_write`, `lain improvements`

The dogfood queue, and it is **cross-project** — which is what makes its filters load-bearing rather
than convenience.

```bash
lain improve <session> --dry-run
lain improve <session> --provider ollama --model qwen3-coder:30b
lain improvements
lain improvements --kind knob
lain improvements --kind bug
lain improvements --project <12-hex-char hash>
lain improvements --project .                       # a path, resolved the same way
lain improvements --kind nonsense                   # must refuse, naming the four kinds
```

The four kinds are `knob`, `bug`, `missing-feature`, `doc`. **Check the two `--project` spellings
resolve to the same set** — a hash and a path that disagree means one of them is not being resolved
"the same way", and the failure is silent because both produce a plausible listing.

The honest-empty rule applies here as it does to `lain epic queue` (`epic-tier.md` §7): an empty
report must name **the path it read**, so "nothing has been recorded" cannot be confused with "I
read the wrong directory". Point it at an empty state home and check.

Also drive `improvement_write` directly from a live session, since it is the only writer:

```
you> record a dogfood note, kind `knob`, about the summarizer's max_tokens default
```

and confirm it appears in `lain improvements` from a **different project directory**. That
cross-project visibility is the feature; a note only visible from the project that wrote it is the
defect, and it cannot be seen from inside one project.

## 6 — `lain bench sweep`: the offline retrieval eval

Five arms — manifest, bm25, vector, hybrid, graph — ranked by recall@k with a tokens-on-recall
column. **Zero network by construction**: the vector arm reads committed fixture embeddings, never a
live embedder.

```bash
lain bench sweep
lain bench sweep -k 1
lain bench sweep -k 20
lain bench sweep -k 0        # must refuse
lain bench sweep -k -3       # must refuse
```

Deterministic, so run it twice and `diff`. Then the two refusals that exist because a silent version
of either would lie:

- **`StaleEmbeddings`** — the committed embeddings were recorded under a different model than the
  sweep asks for. A silent stale fixture measures the wrong model's geometry. The refusal must name
  **both** ids. Provoke it by asking for a model the fixture was not recorded under.
- **a missing corpus or embeddings path** — a packaging mistake, named rather than surfacing as a
  bare `ArgumentError`. The gold corpus ships **with the gem** (`lib/lain/bench/corpus/`) rather
  than under `spec/`, precisely so a sweep in an installed gem still has them; move one aside and
  check the refusal says which file.

**What to read in the report:** recall must be ordered, and the ordering is the finding. If the
manifest arm — the cheapest, a plain description match — ties or beats bm25, vector and hybrid, the
sweep is not discriminating and the ranking is noise. Record the actual numbers each round; a
ranking that changes between rounds with no code change means the eval is not deterministic, which
is the one thing it claims to be.

The tokens-on-recall column is a **second metric's mean riding beside the first metric's
distribution** — recall is the headline, tokens is what that recall cost. An arm that wins on recall
while costing 10× the tokens has not won, and nothing in the ranking says so. Read both columns.

## 7 — What this scenario cannot answer

State it in the findings rather than leaving it implied:

- **Whether memory earns its tokens.** That is `bench sweep`'s question offline and a live sweep's
  question in production, and no live sweep exists. The manifest costs tokens on **every** request;
  nothing here measures that cost against what it buys.
- **Whether recall would help.** See the note at the top — `Context::Recall` is unwired.
- **Cost and latency of the two passes.** Neither `consolidate` nor `improve` reports wall-clock or
  tokens, so "the pass works" and "the pass is affordable" stay unseparated. Time them by hand and
  record the numbers; that is the only way this gap starts closing.
