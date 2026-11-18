# qa-lain

Text-mode review commands and the offline bench and session readers (`bench`, `usage`, `friction`, `verify`), run from `bin/qa-lain` (the QA sandbox puts it on `PATH`). They are separate from `lain`.

## qa-lain review

Review a pull request or a branch. `qa-lain review 4821` takes a pull request number,
`qa-lain review feature/foo` a branch. It resolves the target, opens a round over the changeset,
and prints the round as text, with no editor involved. [`/review`](../users/commands.md#review) is the same round
drawn in the cockpit.

```bash
qa-lain review 4821
qa-lain review feature/foo --scope by_directory
qa-lain review feature/foo --base origin/main
qa-lain review open help                        # a branch actually named `help`
```

`open` is a disambiguating verb. Thor owns the first word, so a target named `help`
or `tree` would reach Thor's own command instead of the resolver; `qa-lain review open help` is the
way through. Every target that does not collide works without it.

| Flag | Default | What it does |
|---|---|---|
| `--scope` | unset (the round opens at `cumulative`) | `cumulative`, `commits`, or `by_directory`: which grouping the sidebar opens on. The enum is read off the registered partition strategies and is not written out in `bin/qa-lain`, so a scope the registry serves cannot be refused before the registry is asked. |
| `--base` | unset | Override the base ref the changeset is cut against. |

An unresolvable target is refused by name, and names the repository it looked in:
`head ref "does-not-exist-xyz" does not resolve to a commit in <root>`.

## qa-lain survey

Review a directory as it stands, with no pull request, no branch and no diff. `qa-lain survey ./docs`
walks the tree, opens a round over it, and prints the listing as text.
[`/survey`](../users/commands.md#survey) is the same round drawn in the cockpit.

```bash
qa-lain survey ./docs
qa-lain survey ./lib --unbounded
qa-lain survey open help                        # a directory actually named `help`
```

`open` is the same escape `qa-lain review` carries, for the same reason.

| Flag | Default | What it does |
|---|---|---|
| `--scope` | unset (the round opens at `cumulative`) | The same 3 registered strategies `qa-lain review` offers. A corpus does not answer all of them; see below. |
| `--unbounded` | `false` | Present the whole tree however large it is. It lifts the corpus file ceiling below; the separate `/critique` packing ceiling still holds. It does not lift the 20,000-entry walk bound: a root holding more entries is refused with the bound and the root named, and is never surveyed in part. |

`--permissive` is not a flag of this command. It chooses the rule a verdict is judged
under, and `qa-lain survey` renders a tree and submits nothing; the in-session
[`/survey`](../users/commands.md#survey) is where it lives. `qa-lain survey ./docs --permissive` answers
`Unknown switches "--permissive"`, naming the switch you typed.

A tree outside the project is judged by the names below its own root, so `secrets/prod` is masked whole in the corpus, the
notes and the briefs.

The docent that answers questions about the survey works inside the surveyed tree, and a read it makes
there meets the same name rule from that root.

Two refusals are worth seeing on paper first.

A scope the registry has but this source cannot answer is refused in prose, and names the
ones that would have worked:

```
scope commits is not available for the corpus source -- it does not answer what that grouping
reads. cumulative, by_directory do present this one
```

A scope that is not registered at all never reaches the source: Thor validates the enum ahead of
dispatch and answers `Expected '--scope' to be one of cumulative, commits, by_directory; got by_size`.

A tree over the file ceiling is refused before a single file is read:

```
this corpus is 742 files, over the ceiling of 300 -- survey a subdirectory instead, or raise
the ceiling with --unbounded
```

The decision is made from a file count alone, when the corpus is built, before any `--scope`
is applied. No scope lifts it: `--scope by_directory` groups the same file set and refuses
with the same sentence. The 2 remedies the refusal names are the only ones.
A directory whose name reads as a secret counts below the root of a survey of a tree outside the project, as it does below the project root and below a checkout.


## qa-lain usage

```bash
qa-lain usage SESSION
```

What a session spent, read offline from its `turn_usage` records: a table of `COMMAND`, `ROLE`, `INPUT` and `OUTPUT` tokens,
one row per command and role pair, sorted by those 2 columns. A turn is counted under the command current when it ran, and a
child takes the command current when it was spawned, so a skill's reviewers count toward that skill. A turn with no command
shows `-`. The approval judge's spend is shown as `auto_approver`, with a note under the table that it is not split by command.
Nothing is counted twice, and a session recorded before this record carried a command reads as before, under `-`. `SESSION` is a
selector as `lain export` takes it.

## qa-lain friction

Knob guidance from one session's friction signals. Offline, deterministic, no API key.

Reads the journal back and names the knobs the run was fighting: approval churn,
compaction thrash, iteration ceilings.

```bash
qa-lain friction SESSION
```

`SESSION` is a selector as `lain export` takes it. The compaction knobs it speaks to (`--compact-bytes`,
`--compact-cap`, `--compact-keep`, `--compact-strategy`) are described in
[the compaction page](../users/compaction.md).

## qa-lain bench variance

Report determinism, divergence, and distribution across recorded sessions. Offline.

The `qa-lain bench` commands read no user-level `config.rb`, so a bench arm does not change with the home directory.

```bash
qa-lain bench variance sessions/          # a directory
qa-lain bench variance a.ndjson b.ndjson  # explicit files
```

## qa-lain bench record

Record N live runs of a task file, one prompt per line. It spends real API money.

```bash
qa-lain bench record tasks.txt --out runs/ --n 10 --provider ollama --temperature 0
```

`--out` is required. `--n` defaults to `Bench::CLI::RECORD_DEFAULTS[:runs]`. Also takes
`--model`, `--max-tokens`, `--system`, `--provider`, `--api-base`, `--temperature`, `--seed`.

## qa-lain bench sweep

Deterministic retrieval eval over 5 arms, scoring recall@k over the gold corpus. Offline, no API.

`-k` / `--k` sets retrieval depth.

## qa-lain bench plan-sweep

Shape x density sweep over a fixture plan's scripted runs. Offline, deterministic.

Both `--plan` (fixture plan markdown) and `--runs` (scripted runs YAML) are required.

## qa-lain bench judge-scale

Compare the judge's answer shapes (`unit`, `binary`, `three`, `deduction`) on findings with known
labels. Per scale it prints n, accuracy, false findings that survived with the one-sided 95% upper
bound, and Brier. Brier is printed for `unit` only; the other scales' scores are not probabilities,
and the report says so. The fixture is synthetic.

```bash
qa-lain bench judge-scale --findings spec/fixtures/grader/findings/labelled.jsonl --recorded runs/  # offline
qa-lain bench judge-scale --findings labelled.jsonl --model qwen3:4b --scales unit,binary           # asks the model
```

`--recorded` is a directory holding one `<scale>.ndjson` of verdict records per scale. A live run
writes that directory (`--journal DIR`, default a timestamped one under `$XDG_STATE_HOME/lain/bench/`,
printed in the report), so it can be re-scored offline. A row whose label is not true or false is
refused naming its line. Also takes the model flags (`--model`, `--provider`, `--api-base`).

## qa-lain bench oracle-calibration

Score the secret oracle on 150 secret-bearing and 150 benign synthetic paths, each with a distinct
basename, 30 of the benign ones secret-adjacent (`.env.example`, `id_rsa.pub`, `token_spec.rb`). It
states wrong approves out of 150 secret paths with the one-sided 95% upper bound, the same bound
over distinct basenames, approves out of 150 benign paths and out of the hard negatives separately,
Brier over approve and deny answers only, the defers per label, and the count per verdict. It says
PASS only at 0 wrong approves. Confidence never enters the gate, and a set with no secret paths fails.

```bash
qa-lain bench oracle-calibration --recorded run.ndjson --oracle local   # offline, from oracle_answer records
qa-lain bench oracle-calibration --oracle local --model qwen3:4b        # asks the local ollama; journals every answer
qa-lain bench oracle-calibration --oracle cloud --model MODEL --gateway http://127.0.0.1:PORT
```

`--oracle` is `local` (default) or `cloud`; a recording is read at that tier's address. A live run
builds its judge through the chat's own secret-oracle wiring, so it is sampled and guarded as in a chat. It calibrates the default configuration and does not take the chat's ollama
runner options, such as num_ctx, num_batch or keep_alive from `LAIN_PROVIDER` and `LAIN_NUM_CTX`,
and writes its answers to `--journal PATH` (default a timestamped file under `$XDG_STATE_HOME/lain/bench/`,
printed in the report); give that file to `--recorded` to re-score it. `--gateway`
and `--model` follow `--secret-oracle cloud`: the gateway is proven first, its token is read from
its token file and never from the URL, and a cloud run needs both. `--paths` names another set of
the same shape (default `spec/fixtures/oracle/paths.yml`).

## qa-lain verify

`qa-lain verify SESSION` says whether a session's record chain holds, offline. It exits 1 only when
a record was edited, inserted or removed, or when the last line fails the `--tip` a previous run
printed. A file older than chaining and a crash tail are not tampering, so neither fails.

It also flags a `lain export --jsonl` file: the export drops a retreat line whose turn never landed,
so its chain links no longer close.
