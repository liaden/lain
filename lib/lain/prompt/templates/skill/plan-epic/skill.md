---
description: Read an epic's approved research.md, decompose it into an issue graph, and write epic.md in the epic-markdown grammar for the epic_plan gate. Use after research-epic has been approved and before any issue is written up.
slots:
  - conventions
---
# plan-epic

Turn `research.md` into `epic.md`: the issues this epic is made of, and the edges between
them. You are cutting seams, not implementing them and not writing the issues up — that is
`create-epic-issues`.

<%= render("conventions") %>

## Phase 1 — Read the research

Read `research.md` from the epic home (`Epic::Home.resolve`, the only door). If it names open
questions that change how the work is cut, raise them now; do not decide them silently inside
a heading.

## Phase 2 — Cut the issues

One issue = one coherent piece of work someone can finish and hand back. If the title needs
"and", cut it in two. Prefer issues that can run in parallel: the graph is scheduled in waves,
and a chain of five is five waves.

Give each issue an id you will be happy to see for the life of the epic. An id is both a
grammar token and a filename, so it must satisfy the stricter of the two rules:
`/\A[a-z0-9][a-z0-9-]*\z/` — lowercase letters, digits and dashes, opening with a letter or a
digit. No underscores, no slashes, no capitals.

## Phase 3 — Write epic.md in the grammar

This is the grammar, by example. It parses, and it is byte-identical to what the emitter
writes back, so a document shaped like this survives every later edit unchanged:

````markdown
### [x] `export-schema` Pin the transcript export wire schema

The record shape every exporter writes and every reader expects. Fixed first, because the writer and the subcommand both encode it.

```gherkin
Scenario: an exported record survives a re-read
  Given a transcript record written by the exporter
  When the reader parses it back
  Then every field comes back byte-identical
```

### [~] `export-stream` Stream records to disk as they land

Writes each record as the session produces it rather than buffering the whole transcript, so a long run costs flat memory.

Blocks: `export-subcommand`
Related: `export-schema`

```gherkin
Scenario: a session larger than the write buffer still exports whole
  Given a session with more records than the write buffer holds
  When the exporter runs
  Then every record lands on disk and memory stays flat
```

### [ ] `export-subcommand` Expose the exporter as a subcommand

The user-facing door. One directory argument, and it refuses rather than overwrites an existing export.

Discovered from: `export-everything`

```gherkin
Scenario: the subcommand refuses to overwrite an existing export
  Given a directory that already holds an export
  When the subcommand runs against it
  Then it refuses and names the directory
```

### [!] `export-tarball` Ship the export as a single tarball

Dropped once the streaming writer landed — a directory of records is what the downstream tooling reads, and an archive would only be unpacked again.

Related: `export-stream`
````

What that example is showing:

- **The heading** is `### [<mark>] `<id>` <title>`, exactly three hashes. The marks are the
  four statuses an issue may CARRY: `[ ]` pending, `[~]` in_flight, `[x]` done, `[!]`
  abandoned. `ready` is NOT one of them — it is derived (pending, with every blocker done) and
  no author may write it.
- **The body** runs to the next `###` heading, and the last issue's body runs to end of file.
- **Free prose is the description, and it is meaning.** It moves the issue's digest. Prose
  ABOVE the first heading is preamble: yours to write, ignored by the parse, and dropped the
  next time the document is emitted. Do not keep anything there you need.
- **Link lines** start at the beginning of a line: `` Blocks: `a`, `b` ``, `` Related: `c` ``,
  `` Discovered from: `x` ``. Ids are backticked. `Blocks` and `Related` take a set;
  `Discovered from` takes exactly one id. One line per kind per issue.
- **Acceptance criteria** are at most one ```gherkin fence per issue, and the fence delimiters
  are part of what is stored — they round-trip verbatim. A criteria block with no `Scenario:`
  in it is refused.
- **A blank line separates every section**, and the emitter writes them in this order: heading,
  description, links, criteria.

What the grammar refuses, and why each refusal is a feature:

- **`Blocked by:` is not writable.** It is derived from the `blocks` edges of the issues that
  block an issue. Two sources of truth for one relation is exactly the drift this refuses.
- **A prose line wearing the link shape is refused, not demoted to prose.** Any line matching
  `Capitalized words: ` that is not a known kind fails loudly, naming the line. So do not open
  a description with `Dropped once the writer landed: ...` — rewrite it with a dash, as the
  abandoned issue above does.
- **`Blocks:` or `Related:` naming an id no heading declares is refused.** `Discovered from:`
  naming a vanished id is deliberately allowed — a split removes the issue its parts grew out
  of, and provenance has to outlive it.
- **Only a ```gherkin fence may sit in an issue body**, and only one of them.

Two orderings to expect: the emitter writes issues **sorted by id**, not in the order you typed
them, and edge sets are sorted and deduplicated. Neither is a change to your epic — both are
what makes two equal issue sets the same document.

Also: the `blocks` edges must form a DAG. A cycle is refused and the error names the path, so
you are told which edge to cut.

## Phase 4 — Check the shape before you gate it

Write through the epic home, then read it back and look at what came out — the graph answers
`ready` (pending with every blocker done) and `waves` (each wave a maximal set that can run in
parallel). If everything lands in one long chain, you cut the seams wrong; go back to Phase 2.

## Phase 5 — Request the epic_plan gate

Submit `epic.md` at the `epic_plan` stage. Under `interactive` a human answers; under
`hands_off` it approves itself audibly; under `deferred` it refuses now and parks the question
for a human to sign off later — the refusal is journaled as a real denial, no spike runs and
**no model is asked** on the way.

Under `adjudicated` the gate tries to answer itself first: a read-only spike gathers evidence
about the plan, journals it under its own content address, and a second model is asked for a
one-word verdict on it. A bare APPROVE or DENY settles the gate; anything less certain still
refuses and parks for a human, with that evidence attached to the parked item — or, when the
spike itself came back empty, the reason it did rather than evidence. Expect it to park; the
spike is there to make the morning review cheaper, not to sign off for you.

The `epic_plan` gate cannot open while this epic's `research` sign-offs are still parked. If
you are told the stage is blocked, that is the boundary rule, not a bug: drain the earlier
stage with `lain epic queue` and `lain epic approve DIGEST` / `lain epic deny DIGEST` first.

Structural changes after this point belong to `iterate-epic`, not to a second run of this
skill.
