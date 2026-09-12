# Simplify 05 — one file-path seam for the file tools, and the secret boundary on the schema

status: draft
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

The nine file-path tools each re-derive the same four-step `#perform` — resolve the model's path
against the session cwd, guard the path, do the work, turn a `SystemCallError` into a result — in
nine slightly different spellings, while the one shared helper that exists for exactly the first
step goes unused by all of them. This plan gives them one seam, deletes the tool that another tool
strictly dominates, and then moves the secret boundary's tool-coupling off two hand-maintained
tables and onto the input schema, where it cannot drift.

Delivers: one `Tool::FileTarget`; `code_outline` gone; one walk-cap for the two tools that cap
during a walk; one lazy-value helper; `Sensitivity::Policy` reading a field role instead of an
11-entry table; `WithholdSecretPaths` filtering structured rows instead of re-parsing text its own
tools just formatted.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`.

**The four duplications, measured.** All nine tools use the identical shape
`File.expand_path(<path>, session_of(invocation).worker_env.cwd)`. Six hold it in a private
`resolved_path` (`write_file.rb:93-95`, `edit_file.rb:124-126`, `grep.rb:235-237`,
`ast_search.rb:105-107`, `code_outline.rb:98-100`, `file_symbols.rb:107-109`); three inline it
(`read_file.rb:664`, `list_files.rb:68`, `glob.rb:103`). `code_outline.rb:97` and
`file_symbols.rb:106` carry the same comment saying so out loud: *"Same rule, same shape, as
{ReadFile} and {Grep#resolved_path}."* `glob.rb:103` additionally spells `input.path || "."`,
re-deriving a nil-arm the shared helper already has.

**The helper they all ignore.** `lib/lain/worker_env.rb:55-61` is `#resolve`, whose docstring reads
*"The ONE cwd-resolution rule both exec arms share ... extracted so the two transports cannot
drift."* Its only callers are `tools/bash.rb:280`, `tools/core_exec.rb:105`, `:137`,
`cli/wiring/board_build.rb:295`, and a throwaway construction at `session.rb:70`. **None of the
nine file tools is among them.**

**The guards.** Five `problem_with` methods across six files, in four wordings for the same three
checks. `code_outline.rb:102-108` and `file_symbols.rb:114-120` are byte-identical 7-line bodies.
`grep.rb:241-246` is a two-check prefix of `ast_search.rb:116-125`, which appends two input-shape
rules. Three spellings of the missing-path sentence exist — `"no such file: "` (read_file,
code_outline, file_symbols), `"no such directory: "` (list_files), `"no such file or directory: "`
(grep, ast_search) — and two of unreadable (`"file is not readable: "` vs `"not readable: "`).
`write_file.rb`, `edit_file.rb` and `glob.rb` have no `problem_with` at all.

**The rescues.** `rescue SystemCallError, IOError` → `"could not <verb> #{path}: #{e.message}"` at
`write_file.rb:85`, `edit_file.rb:115`, `read_file.rb:669`, with five verbs. `code_outline.rb:91`
and `file_symbols.rb:100` add `EncodingError` and carry the **identical 4-line comment** explaining
why. `list_files.rb:74` omits `IOError`. `grep.rb` and `ast_search.rb` rescue inside their walks
(`:118`, `:207`) with a `nil` body — a silent per-file skip — and their `#perform` rescues are
domain errors, not IO. `glob.rb` rescues nothing.

**The encoded read.** `File.read(path, encoding: Encoding::UTF_8)` with a **verbatim-identical
4-line comment** at `code_outline.rb:74-78`, `file_symbols.rb:88-92`, and the same argument in
different words at `ast_search.rb:196-201`.

**`code_outline` is dominated.** It is `ast_search` with its arguments fixed: two
`Structural::Patterns.fetch` calls for `:class_def` (`:122`) and `:method_def` (`:131`) over one
file. `file_symbols` answers the same question about the same file with a richer result — named
roles plus reference occurrences via `Structural::Queries.fetch(language, :symbols)` (`:130`) — and
needs no new parameter. Its own `DEFINITIONS_BOUND` docstring (`:18-38`) says *"Definitions take
{CodeOutline::BOUND}'s 200"*, and `:161-167` cites `{CodeOutline#render}` for the **sort-stability
measurement**, not merely for a number. Advertising sites: `read_file.rb:67-70`'s `STRUCTURAL`
constant (reached from `:544`, `:547`, `:85`), `sensitivity/policy.rb:75`, `mode/posture.rb:101`,
`tools.rb:34`, `cli/wiring/base_tools.rb:84`.

**The walk cap, and a ruling that constrains this plan.** `grep.rb:45` `MAX_MATCHES = 200`, `:50`
`Found = Data.define(:rows, :capped)`, `:72-73` the `first(MAX_MATCHES + 1)` probe, `:263` the
trailer `"... capped at #{MAX_MATCHES} matches"`. `ast_search.rb:21` takes the same number "outright",
`:112-114` the same probe, `:243-245` the same trailer. **`tool/bounds.rb:57-66` settles that these
may NOT adopt `Bounds::Enumeration`** — `Enumeration#cap` derives its total from `rows.size` and so
needs the whole collection, while these two deliberately never scan the rest — and ends: *"Do not
unify the two formats, and do not add an unknown-total mode to make them fit."* So a shared cap
serves these two only, and `Enumeration` is out of scope.

**The lazy-value idiom.** `x.respond_to?(:call) ? x.call : x` verbatim at `ask_human.rb:440`,
`request_review.rb:336`, `tool_search.rb:91`, `subagent.rb:356`; `request_review.rb:317-320` names
it *"AskHuman's `parent:` idiom"*. Near-variants with different arity at `arm/driver.rb:186` and
`provider/http/configuration.rb:129`. A predicate over the same question at
`request_review.rb:449`. `algebra.rb:88` and `:246` are **deliberate non-uses with stated reasons** —
leave them.

**The secret boundary's tool coupling is four tables, not one place.**
`sensitivity/policy.rb:65` `PATH_FIELDS` (self-described as "the whole of what this class knows
about tools"), `middleware/redact_secret_reads.rb:68` `GUARDED_TOOLS` + `:76` `PATH_INPUT`,
`middleware/withhold_secret_paths.rb:171` `GUARDED_TOOLS`, `middleware/refuse_secret_writes.rb:26`
`GUARDED_TOOLS`; plus `at(input, field)` duplicated near-verbatim at `sensitivity/policy.rb:213`
and `withhold_secret_paths.rb:318`. **Of `PATH_FIELDS`' 11 entries, 9 are the identical string
`"path"`.**

**`WithholdSecretPaths` re-parses text its own tools formatted.** `grep.rb:262` joins rows to
`"file:line:text"`; `withhold_secret_paths.rb:143-160` then guesses where the path ends using
`LINE_NUMBER = /\A\d+\z/` and a `splits` heuristic, because a filename may contain a colon. It also
string-compares against tool-generated prose — `Tools::ListFiles.empty_message(base)` and
`Glob.no_matches_message(...)` at `:113`, `:120`, `:153` — a coupling its own comment at `:75-76`
complains about ("take HETEROGENEOUS arguments").

**Where docs and code disagreed.** CLAUDE.md's "Tier-1 `read_file`/`grep`/`glob`/`list_files` do not
check paths — the boundary is one place a reader can find" is true about the *tools* and, measured, not
quite true about the *boundary*: `Sensitivity::Policy::PATH_FIELDS`,
`RedactSecretReads::GUARDED_TOOLS` + `PATH_INPUT`, `WithholdSecretPaths::GUARDED_TOOLS` and
`RefuseSecretWrites::GUARDED_TOOLS` are four tables, with `at(input, field)` duplicated near-verbatim
across two of them.

**This plan no longer proposes to change that** — see Open decisions. ARCHITECTURE.md's position is that
the coupling *"cannot be abolished"* and belongs in data pinned by an allowlist-free spec, and that
position is load-bearing. The four-table count is recorded here as a finding, not as a task.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lib/lain/tools.rb`,
  `lib/lain/tool.rb`'s require block, `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`,
  `spec/support/tool_registry.rb`.
- `spec/support/tool_registry.rb` is shared because it enumerates every tool; T2's deletion needs a
  one-line removal there, handed back rather than edited in-card.
- This plan assumes **simplify-01-toolchain-and-rules has landed**: T1 and T6 both produce objects
  that would trip `Metrics/ClassLength` at its current `Max: 125`, and T1's mixin puts a method over
  the current `MethodLength: 10`. Do not start this plan before 01.

## Open decisions

- **The secret-boundary cards were cut, and the reason should not be lost.** An earlier draft carried two:
  declaring a `role: :path` on each tool's input field instead of `Sensitivity::Policy::PATH_FIELDS`, and
  having `WithholdSecretPaths` filter structured rows instead of re-parsing the text its own tools
  formatted.

  **The first reverses a rejection this repository has already written down, and the panel was right to
  refuse it.** `sensitivity/policy.rb:62-64` points at it by name — *"see ARCHITECTURE.md's 'The secret
  boundary' for why a `path`-shaped field sniffed off any input was rejected"* — and ARCHITECTURE.md gives
  the reason: the coupling *"cannot be abolished… so it is data in one place, pinned by a spec that fails
  BY NAME when a new path-taking tool ships. **That spec has no allowlist**: an earlier edition scoped out
  the three AST readers, which made a green suite state three bypasses as intended — and
  `ast_search path=.env pattern="$A = $B"` returns the captured values, byte-for-byte what `read_file`
  returns."*

  With a table plus a no-allowlist spec, a missing entry **reddens by name**. With a per-tool `role:`, a
  new tool that simply omits it is **silently ungated** — and the cut card's own AC asserted that silence
  was correct behaviour. That is the `ast_search path=.env` bypass class reopened by design.

  **If it is ever revisited**, it needs a card of its own that edits the rejection first, the way
  simplify-13's T3 edits the three rules that plan reverses. Reversing a documented rejection without
  citing it is how a rule becomes decorative.

  **The second (`WithholdSecretPaths` filtering rows) stands on its own merits** and was cut only because
  it depended on the first. `withhold_secret_paths.rb:143-160` really does guess where a path ends with a
  `LINE_NUMBER` regex because a filename may contain a colon, and really does string-compare against
  `ListFiles.empty_message` and `Glob.no_matches_message`. Worth its own plan; not worth smuggling in
  behind a schema change.

## Waves

Wave 1: T2, T4
Wave 2: T1 (←T2), T3
Critical path: T2 → T1

T2 precedes T1 deliberately: deleting `code_outline` first means the mixin converts eight tools, not
nine, and removes the byte-identical pair that would otherwise have to be reconciled twice.

## Tasks

### T1 — Give the file tools one path-resolution, guard and failure seam   [wave 2] [risk: medium]

**Depends on:** T2
**Files:** create `lib/lain/tool/file_target.rb`, `spec/lain/tool/file_target_spec.rb`; modify
`lib/lain/tools/write_file.rb`, `edit_file.rb`, `read_file.rb`, `list_files.rb`, `glob.rb`,
`grep.rb`, `ast_search.rb`, `file_symbols.rb`
**Reuse:** `Lain::WorkerEnv#resolve` (`lib/lain/worker_env.rb:55-61`) — the mixin must call it, not
re-derive it; `Tool#session_of` (`lib/lain/tool.rb:187-189`) is the existing seam for reaching the
session; `Tool::Result.error` for the failure shape
**Shared-file wiring:** `require_relative "tool/file_target"` in `lib/lain/tool.rb`'s require block,
after `tool/result` and before `tool/bounds`
**Reachable from:** inherited — each of the eight tools is already constructed at
`CLI::Wiring::BaseTools#build` (`lib/lain/cli/wiring/base_tools.rb:79-84`); the mixin is exercised
through them, and AC 4 drives one through that construction path rather than through a double

The mixin owns four things and nothing else: `#target(invocation, path)` resolving through
`WorkerEnv#resolve`; `#problem_with(path, expecting:)` returning one sentence or nil, with
`expecting:` selecting file/directory/either wording; `#failing(verb, path)` wrapping a block and
turning `SystemCallError`/`IOError` into `Tool::Result.error("could not #{verb} #{path}: ...")`; and
`#utf8_source(path)` carrying the encoding comment once.

Three shapes it must NOT absorb, each verified as a real difference rather than drift:
`grep`/`ast_search` rescue **inside their walks** with a `nil` body (a deliberate per-file skip,
`grep.rb:118`, `ast_search.rb:207`) — those stay; `code_outline`/`file_symbols`' extra
`EncodingError` arm rides along on the *structural* read, so `#failing` takes the extra classes as an
argument rather than hardcoding a set; and `glob`'s `input.path || "."` becomes `#resolve`'s nil-arm
rather than a separate branch.

**Acceptance criteria**

```gherkin
Scenario: a relative path resolves against the session's cwd, not the process cwd
  Given a session whose worker_env cwd is a directory other than Dir.pwd
  And a file named "inner.txt" inside that directory
  When read_file is invoked with the relative path "inner.txt"
  Then the content of that file is returned
  And no file of the same name beside the process cwd is read

Scenario: an absolute path is honored as given
  Given a session whose worker_env cwd is some other directory
  When read_file is invoked with an absolute path to an existing file
  Then that file's content is returned

Scenario: a missing target is refused with one sentence naming the path
  Given a session
  When list_files is invoked with a path that does not exist
  Then the result is an error whose message names the path
  And the message says no such directory

Scenario: a tool built the way production builds it resolves through the shared seam
  Given a toolset built by CLI::Wiring::BaseTools
  And a session whose worker_env cwd is a temporary directory holding "a.txt"
  When the read_file tool from that toolset is invoked with "a.txt"
  Then the file inside the temporary directory is read

Scenario: an unreadable target reports the verb the tool was performing
  Given an existing file whose permissions deny reading
  When write_file is invoked against it
  Then the result is an error whose message begins "could not write"
```
→ spec file: `spec/lain/tool/file_target_spec.rb` (AC 4 lives in
`spec/lain/cli/wiring/base_tools_spec.rb`)

**Escalation triggers**
- `grep.rb:22-37` documents a walk-order divergence between its Ruby and daemon arms, pinned by
  `spec/lain/core/grep_parity_spec.rb`. If routing `grep` through the mixin changes which paths it
  visits or their order, stop — the parity spec is the authority and this card is not allowed to
  change it.
- `read_file.rb:250` reads with an explicit byte cap and then `force_encoding`, and `:439` uses
  `File.foreach` with a limit; both cite `{Whole#capped}`. If `#utf8_source` would replace either,
  stop — those are bound reads, not plain reads.
- `withhold_secret_paths_spec.rb` and `sensitivity/filter_spec.rb` assert on tool output text. If
  unifying a `problem_with` wording changes a string either spec matches, stop and report which
  sentence and which spec before choosing a wording.
- If any of the eight tools turns out to resolve its path *before* validating input shape (so the
  order of refusals is observable), stop — `edit_file.rb:28-38` documents refusal ordering as
  load-bearing and T1 must not reorder it.

### T2 — Delete `code_outline` and move its measurements to `file_symbols`   [wave 1] [risk: low]

**Depends on:** none
**Files:** delete `lib/lain/tools/code_outline.rb`, `spec/lain/tools/code_outline_spec.rb`; modify
`lib/lain/tools/file_symbols.rb`, `lib/lain/tools/read_file.rb`,
`lib/lain/sensitivity/policy.rb`, `lib/lain/mode/posture.rb`,
`lib/lain/cli/wiring/base_tools.rb`, `spec/lain/tools/read_file_spec.rb`
**Reuse:** `Tools::FileSymbols` already answers the same question with a richer result and needs no
new parameter (`file_symbols.rb:130` `Structural::Queries.fetch(language, :symbols)`)
**Shared-file wiring:** remove `require_relative "tools/code_outline"` from `lib/lain/tools.rb:34`;
remove the `CodeOutline` entry from `spec/support/tool_registry.rb`
**Reachable from:** the removal is observable at `CLI::Wiring::BaseTools#build`
(`base_tools.rb:84`), which currently constructs `Tools::CodeOutline.new` and must stop; AC 3
asserts the built toolset no longer advertises it

The two justifications `file_symbols` currently borrows must survive as words in `file_symbols.rb`:
`:18-38`'s *"Definitions take {CodeOutline::BOUND}'s 200"* becomes the measurement itself (the 80-vs-135
definition counts it already quotes), and `:161-167`'s citation of `{CodeOutline#render}` for
sort-stability becomes the argument inline. Deleting the reference without moving the reason is the
failure mode this card exists to avoid.

`read_file.rb:67-70`'s `STRUCTURAL` constant drops `code_outline` from its narrower-action list.
Note `spec/lain/tool/bounds_spec.rb:81,:117` use `"run code_outline"` as an **arbitrary fixture
string**, not a reference — they survive untouched.

**Acceptance criteria**

```gherkin
Scenario: the structural narrower action no longer names a tool that does not exist
  Given a file large enough to trip read_file's whole-artifact bound
  When read_file is invoked against it
  Then the refusal names file_symbols and ast_search as narrower actions
  And the refusal does not name code_outline

Scenario: file_symbols still answers the outline question for the same file
  Given a Ruby source file with two classes and four methods
  When file_symbols is invoked against it
  Then every class and method name appears in the result

Scenario: the production toolset no longer offers code_outline
  Given a toolset built by CLI::Wiring::BaseTools
  When its tool names are listed
  Then code_outline is absent
  And file_symbols is present
```
→ spec files: `spec/lain/tools/read_file_spec.rb`, `spec/lain/tools/file_symbols_spec.rb`,
`spec/lain/cli/wiring/base_tools_spec.rb`

**Escalation triggers**
- `spec/lain/tools/read_file_spec.rb:760` and `:782` match on `/code_outline|file_symbols|ast_search/`
  against the real `STRUCTURAL` constant. If either assertion cannot be satisfied by narrowing the
  regex — because some other refusal path also feeds it — stop and report the path.
- `spec/lain/tools/parallel_commutation_spec.rb` and `parallel_safety_spec.rb` enumerate tools. If
  either derives its list from a source that still yields `CodeOutline` after the delete, stop:
  the enumeration is a second registry and needs its own decision.
- `spec/fixtures/vcr_cassettes/ollama_run_tool_loop.yml` mentions `code_outline`. If a cassette
  replay fails because a recorded tool schema no longer matches, stop — re-recording a cassette is
  out of this card's scope.
- If `mode/posture.rb:101`'s read-only tool list turns out to be asserted verbatim by a spec that
  also pins its length, stop and report before changing the count.

### T3 — One walk-cap for the two tools that cap during a walk   [wave 2] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/tool/bounds/walk_cap.rb`, `spec/lain/tool/bounds/walk_cap_spec.rb`;
modify `lib/lain/tools/grep.rb`, `lib/lain/tools/ast_search.rb`
**Reuse:** `grep.rb:50`'s `Found = Data.define(:rows, :capped)` is the shape to generalize;
`ast_search.rb:234-257`'s `ResultFormatter` already isolates the trailer
**Shared-file wiring:** `require_relative "tool/bounds/walk_cap"` in `lib/lain/tool.rb`'s require
block, after `tool/bounds`
**Reachable from:** inherited — `Tools::Grep` and `Tools::AstSearch` are constructed at
`base_tools.rb:79-84`; AC 3 drives `grep` through a real toolset

`WalkCap` owns the `limit + 1` probe, the `capped` boolean, and the trailer sentence
`"... capped at #{limit} matches"` — the *no-total* wording, which is the whole point of its being
separate from `Enumeration`.

**`Bounds::Enumeration` is explicitly out of scope.** `tool/bounds.rb:57-66` rules that these two
tools cannot use it and closes with *"Do not unify the two formats, and do not add an unknown-total
mode to make them fit."* This card must not touch `Enumeration`, must not give `WalkCap` a total,
and must leave the two trailers textually distinct.

**Acceptance criteria**

```gherkin
Scenario: a walk that exceeds the cap says so without naming a total
  Given a cap of 2
  And a lazy sequence of 5 matches
  When the cap is applied
  Then 2 rows come back
  And the trailer says capped at 2 matches
  And the trailer names no total

Scenario: a walk within the cap adds no trailer
  Given a cap of 5
  And a lazy sequence of 2 matches
  When the cap is applied
  Then 2 rows come back
  And no trailer is added

Scenario: grep from a real toolset still caps its output and says so
  Given a toolset built by CLI::Wiring::BaseTools
  And a directory containing more matching lines than grep's cap
  When the grep tool is invoked over it
  Then the content ends with a line saying the result was capped

Scenario: the cap pulls no more than one item past its limit
  Given a cap of 2
  And an enumerator that records how many items were taken from it
  When the cap is applied
  Then exactly 3 items were taken
```
→ spec file: `spec/lain/tool/bounds/walk_cap_spec.rb` (AC 3 in `spec/lain/tools/grep_spec.rb`)

**Escalation triggers**
- `grep.rb:201` and `ast_search.rb:68-69` embed the cap number in the **model-facing tool
  description**. If extracting the constant changes either description's text, stop — a changed
  description is a changed prompt and needs the human's call.
- `grep.rb:149`'s daemon arm receives `capped` from the wire (`reply.fetch("capped")`) rather than
  computing it. `WalkCap` must accommodate a cap decided elsewhere; if it cannot without a second
  constructor, stop and report.
- AC 4 exists because the probe's whole purpose is not scanning the rest. If the shared cap takes
  more than `limit + 1`, that is a performance regression in a tier-1 tool — stop rather than
  accepting it.

### T4 — One lazy-value helper for the four verbatim thunk sites   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain.rb`'s `Lain` module body (see wiring note),
`lib/lain/tools/ask_human.rb`, `lib/lain/tools/request_review.rb`,
`lib/lain/tools/tool_search.rb`, `lib/lain/tools/subagent.rb`; create
`spec/lain/live_spec.rb`
**Reuse:** `request_review.rb:317-320` already names this "AskHuman's `parent:` idiom" — the comment
becomes the helper's docstring
**Shared-file wiring:** `Lain.live` is defined in `lib/lain/live.rb` with
`require_relative "live"` added to `lib/lain.rb` before the first unit that uses it (`tool`);
the orchestrator applies that line
**Reachable from:** inherited — all four call sites are on live paths
(`AskHuman#timeline`, `RequestReview#live`, `ToolSearch`'s toolset read, `Subagent`'s handle read);
AC 3 exercises one through `Tools::AskHuman` as wired by `CLI::Wiring::Askers`

Scope is the four **verbatim** sites only: `ask_human.rb:440`, `request_review.rb:336`,
`tool_search.rb:91`, `subagent.rb:356`. Explicitly out of scope: `arm/driver.rb:186` and
`provider/http/configuration.rb:129` (different arity), `request_review.rb:449`'s `thunk?`
predicate, and `algebra.rb:88`/`:246`, which are **deliberate non-uses with stated reasons**.

**Acceptance criteria**

```gherkin
Scenario: a callable is called
  Given a lambda returning 42
  When it is resolved through the helper
  Then 42 comes back

Scenario: a plain value is returned as-is
  Given the value 42
  When it is resolved through the helper
  Then 42 comes back

Scenario: an ask_human wired the way production wires it reads its timeline lazily
  Given AskHuman constructed by CLI::Wiring::Askers with a callable timeline source
  And the source has not been called yet
  When a question is asked
  Then the source is called at that point, not at construction
```
→ spec file: `spec/lain/live_spec.rb` (AC 3 in `spec/lain/cli/wiring/askers_spec.rb`)

**Escalation triggers**
- If `Tools::ToolSearch` is deleted by simplify-08-bench-reachability before this card runs, its
  site disappears — reduce scope to three sites rather than reintroducing the tool.
- `subagent.rb:356` resolves a *handle*, which may be a Promise rather than a plain callable. If
  `respond_to?(:call)` is true for a Promise there and the current code depends on that, stop: the
  helper would change when the promise settles.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, and **the example count equals or exceeds the pre-plan count minus
  the examples T2 deletes with `code_outline_spec.rb`**. Record both numbers in the final commit
  message — per CLAUDE.md a dead worker and an OOM kill both look like a pass, so the count is the
  check.
- `bundle exec rubocop` clean with no new `rubocop:disable`. If T1's mixin or T6's row types need
  one, that is an escalation, not a fix.
- `bundle exec rspec spec/lain/core/grep_parity_spec.rb --tag core` after `rake core:build` —
  T1 and T3 both touch `grep`, and this is the differential that proves the two arms still agree.
- `bundle exec rspec spec/lain/sensitivity spec/lain/middleware` as a focused boundary run, since
  T5 and T6 move where the boundary reads its coupling from.
- **Manual, human:** one `lain chat` session in which `read_file` is asked for a path under a
  `denied` pattern and then `grep` is asked to search a directory containing one. The secret
  boundary's behavior is the one thing in this plan whose failure is silent, and
  `planning/qa/scenarios/` has no scenario covering the four-table-to-schema change.
- Update `planning/qa/scenarios/` if T5 or T6 changes an observable refusal sentence — per the
  project's own rule, closing a chunk includes updating that enumeration.
