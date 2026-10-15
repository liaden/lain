# QA round 24 fixes: a command's paths, a child's place, and a window that refuses

status: draft
commit-mode: orchestrator-commits
language: ruby
panel: Ruby (Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson)

## Intent

Fix every finding in [`planning/qa-findings-round24-2026-10-15.md`](../qa-findings-round24-2026-10-15.md) rated
MEDIUM or higher: 2 HIGH, 7 MED-HIGH and 15 MEDIUM. Round 24's "not reached" items get no card, by the user's
ruling: they stay as round 25's coverage debts.

Most of the round's new defects come from 2 missing concepts. The new approval rungs (the judge, the deny memory)
read a `bash` call's path as its `cwd`, because nothing says which paths a command names. And every child is told
the human's checkout is its working directory, because the environment block is built once per session.

| Missing concept | Findings it closes | Cards |
|---|---|---|
| a walk below `/` is finite and names paths relative to its root | c24-4 | T1 |
| one reader names the paths a `bash` command touches, and every rung uses it | b24-2, c24-2, DENY-1 (a24-7, b24-4, b24-5, c24-8, d24-4), b24-3 | T2, T3, T4, T5 |
| the judge knows where it is and what was asked, and a human can see what it did | i24-2, d24-6, a24-8, f24-4, a24-3 | T6, T23, T24 |
| a project cannot rewrite an approval role, and the oracle cannot release a named shape | g24-5, c24-7 | T7, T8 |
| the detector knows the common password shapes | c24-1 | T9 |
| a child is told its own place, and kept there on every route | ENV-1 (h24-1, e24-7, g24-4), a24-6, e24-9, h24-6, h24-2 | T10, T11, T12, T13, T14 |
| compaction keeps an exchange whole and its attestations cheap | i24-1, i24-3 | T15, T16 |
| a reply that fills the window is cut, never shifted | i24-4 | T17 |
| the cockpit's live state follows every change | d24-7, f24-1, a24-1 | T18, T19, T20 |
| `lain land wait` knows whether anyone is landing | e24-1 (and e24-2, same files) | T21 |
| a note from the human is explained to the model | d24-3 | T22 |

**24 cards.** Roadmap line: `ROADMAP.md` item 58.

## Grounding

2026-10-15, at `9e65dab4`, after round 24 (`planning/qa-findings-round24-2026-10-15.md` and the 9 fork reports
under `~/tmp/lain-qa-2026-10-15-{a..i}/records/fork-report.md`). 4 Explore passes read the production paths; their
claims below were checked by hand where a card rests on them.

Checked by probe, not by reading:

- **`Shell::Parse` yields argv for commands the verdict abstains on.** Run on this tree:
  `cd x && cat .env` gives `[["cd","x"],["cat",".env"]]`; `ls ~/.cargo/registry/cache/*/ 2>/dev/null | head -5;
  echo ---` gives 3 stages with redirect target `/dev/null`; `cat < /etc/shadow` gives `[["cat"]]` with redirect
  target `/etc/shadow`; `for f in *.key; do cat $f; done` gives `[["cat","$f"]]` with `covered? == false`. Argv
  text keeps its quotes (`"\"$HOME/.ssh/id_rsa\""`). This is what makes T2 possible: `Shell::Verdict` drops the
  term on every abstain (`verdict.rb:241,275,279`), but the parse underneath it does not.
- **ollama 0.34.4 honours a top-level `shift: false`.** See Spike findings.
- **`Judged#judgeable?` reads only `PATH_FIELDS`** (`approval/judged.rb:95-100`; `sensitivity/policy.rb:85-96` maps
  `bash` to `"cwd"`).
- **`FileWalk#ancestors` never terminates for an absolute path** (`file_walk.rb:70-82`); fork `c` measured 103 MB to
  622 MB in 0.8 s.
- **`Environment.current` reads `project.cwd` once** (`prompt/environment.rb:20-24`), built in
  `cli/chat_launch.rb:240-243` and frozen into `Slots` (`prompt/slots.rb:167`).

Files read: `approval/{judged,judge,queue,escalation,secret_surface}.rb`, `middleware/{remembered_denials,
confine_to_scope}.rb`, `sensitivity/policy.rb`, `shell/{parse,term,verdict}.rb`, `prompt/{environment,slots}.rb`,
`role.rb`, `role/catalog.rb`, `skill/role_spawn.rb`, `tools/subagent.rb`, `cli/wiring/toolset_build.rb`,
`cli/tool_guard.rb`, `review/docent.rb`, `review/source/corpus.rb`, `cli/command/survey.rb`, `epic/home.rb`,
`context/pinned_messages.rb`, `compaction/{strategy/elide,summary_snapshot,scheduler}.rb`,
`provider/ollama/encoding.rb`, `frontend/{input_pane,stdin_pump,line_editor}.rb`, `session.rb`,
`tools/{write_file,edit_file}.rb`, `cli/land.rb`, `file_lock.rb`, `context/mailbox.rb`, `status_feed/fleet.rb`,
`credential_patterns.rb`, `sensitivity/regions.rb`, `file_walk.rb`.

**Where docs and code disagree:**

- `docs/commands.md:661-664` says a call touching a credential is never shown to the judge. Code shows it any `bash`
  call (b24-2). The doc wins; T3.
- `docs/commands.md` says a remembered deny holds "whatever the tool". Code keys it on `bash`'s `cwd` (DENY-1). The
  doc wins, narrowed to "a gated path"; T4.
- `role/catalog.rb`'s comment says the researcher's shell and writer "reach only its own kept lease". True only on
  the `subagent` tool's route (a24-6). The comment wins; T11.
- `epic-tier.md` §10c says nothing reaches the human's checkout. False on the `bash` route (ENV-1). The scenario
  wins; T10 and T12.
- `ROADMAP.md` item 57's label read "Planned" while its body and its plan file say done (`9e65dab4`). Corrected
  in the commit that adds item 58.

## Compatibility

`harness-vs-own-dev` (memory): lain is its own only consumer and needs no back-compat. Checked per surface:

| Surface | Verdict | Evidence |
|---|---|---|
| `escalation` journal record fields | free to break | readers are specs, the bench and `RememberedDenials` (`grep -rn '"escalation"' lib/`); T24 adds a field, none removed |
| elision attestation text (`<role> <digest> <n> bytes`) | free to break | model-facing only; no parser in `lib/` (`grep -rn ' bytes"' lib/lain/compaction`); pinned by `elide_spec.rb` and `summary_snapshot_spec.rb` |
| `.lain/slots/role/<approval role>.md` | free to break | no consumer outside this repo (`grep -rln 'slots/role' ~/dev --include=*.md` finds only lain's docs and QA scenarios); user ruling 2026-10-15 to refuse |
| the ollama request body | free to break | wire format to a server lain does not ship |
| the in-session deny memory | free to break | held in memory per session, never persisted (`approval/queue.rb:431-436`) |
| `lain land wait` exit codes | free to break | callers are the chat handback (`ca360e2a`) and humans; T21 adds code 3, keeps 0, 2 and 130 |
| `Prompt::Environment` shape | free to break | internal `Data`; specs only |

No trade reports: nothing must be kept.

## Spike findings

| Question | Result | Evidence |
|---|---|---|
| Does ollama 0.34.4 stop at the window when the request carries `shift: false`, rather than silently shifting context? | Yes. Without it, a 1,024-token window produced 2,849 output tokens, `done_reason=stop`. With it, 994 output tokens on a 30-token prompt (1,024 total), `done_reason=length` | `qwen3:4b`, `num_ctx 1024`, `num_predict 3000`, `truncate:false`, `think:false`, "count to 2000"; run 2026-10-15 against `/mnt/nvme/opt/ollama-0.34.4`, server stopped after. No worktree was needed: the probe was 2 `curl` calls |

## Panel review

The Ruby panel traced `Shell::Named` from `exe/lain` to `Switchboard#judged` and returned REQUEST-CHANGES with 5
blockers, all applied:

- T10 named the launch cwd in segment 0 while promising a child would not see it. It now renders a child form of
  segment 0 and states the place in the role tail, and lists `subagent_spec.rb` and `role_spec.rb`.
- T4's region-release scenario reversed a pinned rule (a declined release is a no about regions, not the path) by a
  mechanism that could not deliver it. Dropped; the rule stays. `Queue` keeps no policy: the lookup gates.
- T2's `cd` handling would have named paths under the wrong directory for `||`, `;`, `|`, `&`, a subshell, `cd -`
  and `-C`. Each is now opaque, with scenarios.
- T2's snippet declared `Path` inside the `Data.define` block (the CLAUDE.md trap). Reopened.
- No consumer had `home`. T2 adds `Policy#home`.

Also applied: T3 and T4 name their real construction sites; T5 rebases `Triage` onto T2 instead of adding a second
word reader; T6 drops the human's request (no accessor; see Rejected options) and lists `judge_source.rb`; T24
waits for T4; T10's `:inherit` stop condition moved to `SiblingTemplate`; T1's memory criterion became a timeout;
T12 states that a `cd` out of the worktree is refused; T16's headline matches its 40%; and a section on what the
main session does when a stop condition fires.

## Shared files

Only the main session edits these. Cards hand back the diff.

- `docs/commands.md`: T3, T4, T5, T7, T8, T11, T12, T17, T21 each hand back the sentence that changes.
- `ARCHITECTURE.md`: T2 (the paths a command names, under "Triaging a bash command") and T10 (a child's environment).
- `.rubocop.yml`: any `Metrics/*` raise, in its own commit with its reason.
- `ROADMAP.md`: item 58's status as cards land.
- `planning/qa/scenarios/*.md`: corrected after the last card, per `qa-scenarios-track-features` (memory).

## Rejected options

- **Make every `bash` call unjudgeable.** It closes b24-2 at once, and the judge already defers 9 in 10. Rejected:
  it throws away the judge for the commands it can judge, and still leaves the deny memory and Triage without the
  words. T2 gives all 4 readers the same words.
- **Strip the cwd line from the environment block for everyone.** Keeps the cache trivially. Rejected: the main
  agent needs it, and the children need the right one, not none.
- **Re-render the main agent's environment on `/mode plan`.** The spike reminder already names the spike, and a
  changed system block breaks the cache on every flip. The main agent keeps the project block; g24-4's plan-scope
  half is covered by the reminder.
- **Bring `.lain/slots/**` under `lain trust`.** User ruling: refuse the approval roles by name instead (T7).
- **Show the oracle the detector's reason.** User ruling: the oracle may not approve a pattern hit (T8).
- **A token estimator in the compaction shrink test (i24-3).** The cost was the digest, not the test. T16 cuts the
  digest and pins occupancy; a stop condition reopens this if occupancy still does not fall.
- **Show the judge the human's request (i24-2).** Nothing on the gate's side holds it: no last-prompt accessor in
  `session.rb`, and the gate sees a `Session` and the call. Threading the timeline through the gate is its own
  change. T6 gives the judge its place instead, and stops its template asking about an unstated intent. If round 25
  still sees about 9 in 10 defers, this is the next lever.
- **Reserve `max_tokens` in the 90% trigger (i24-4).** At the 16,384 default it would compact at 50% of a 32k
  window. `shift: false` makes the overrun a named cut instead.

## When a stop condition fires

The implementer stops and reports the condition with its evidence. The main session decides in 1 of 3 ways: amend
the card in this file and re-dispatch, move the item to Open decisions and dispatch nothing that depends on it, or
ask the user. A fired stop condition is never worked around inside the card.

## Open decisions

None. 4 were decided on 2026-10-15: the HIGHs are in scope, "not reached" gets no card, an approval role's slot is
refused by name, and the oracle may not approve a pattern-detected region.

## Dependency graph

```mermaid
flowchart LR
  T2 --> T3
  T2 --> T4
  T3 --> T4
  T2 --> T5
  T2 --> T12
  T3 --> T6
  T6 --> T24
  T4 --> T24
  T10 --> T7
  T7 --> T22
  T10 --> T11
  T11 --> T12
  T12 --> T14
  T10 --> T13
  T18 --> T20
  T1
  T8
  T9
  T15
  T16
  T17
  T19
  T21
  T23
```

## Tasks

### T1: Walk a root of `/` to an end, and name its paths relative to it          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/file_walk.rb`, `lib/lain/tools/list_files.rb`, `lib/lain/survey/walk.rb`,
`spec/lain/file_walk_spec.rb`, `spec/lain/tools/list_files_spec.rb`, `spec/lain/tools/glob_spec.rb`
**Reuse:** `File.expand_path` already normalises `@root` (`file_walk.rb:39`); the 20,000-entry bound
**Shared-file wiring:** none
**Reachable from:** `Tools::Glob#listed` (`tools/glob.rb:171-178`) and `Tools::ListFiles#walked`
(`tools/list_files.rb:122-125`), both built by `CLI::Wiring::ToolsetBuild`

**Acceptance criteria**

```gherkin
Scenario: a walk of / stops at its entry bound
  Given a FileWalk over root "/" with an entry bound of 50
  When the relative tree is taken under a 5 second timeout
  Then it returns within the timeout
  And it returns at most 50 files, and no more directories than the files' distinct ancestors
  And every name is relative to "/", with no leading slash

Scenario: the glob tool with path / answers
  Given the glob tool built by the production wiring
  When it is called with path "/" and pattern "*.conf"
  Then it returns a bounded result naming entries relative to "/"

Scenario: list_files of / names its children without a doubled slash
  When list_files is called with path "/" and recursive true
  Then it returns a bounded listing, each entry relative to "/"

Scenario: a survey rooted at / names rows relative to it
  Given a survey walk rooted at "/" with a small bound
  Then no row's path starts with "/"
```
Spec file: `spec/lain/file_walk_spec.rb`, `spec/lain/tools/glob_spec.rb`, `spec/lain/tools/list_files_spec.rb`

**Stop and report if:**
- `spec/lain/file_walk_spec.rb`'s `#relative_tree` examples (line 240 on) depend on a trailing-slash prefix for a
  non-root path.
- A root-`/` survey refuses at `survey/walk.rb`'s ceiling before any row is named; then the survey scenario's spec
  uses a temporary root holding 1 file and asserts the prefix arithmetic on a root of `/` in the unit spec instead.

### T2: Name the paths a bash command touches          [risk: high]

**Depends on:** none
**Files:** `lib/lain/shell/named.rb` (new), `spec/lain/shell/named_spec.rb` (new), `lib/lain/sensitivity/policy.rb`,
`spec/lain/sensitivity/policy_spec.rb`
**Reuse:** `Shell::Parse#call` (stages, argv, redirects, separators, `covered?`, `broken?`); the argv unquoting
`Shell::Verdict` already does when it builds a `Shell::Term`; `Tool::FileTarget`'s `~` expansion
**Shared-file wiring:** `ARCHITECTURE.md`, "Triaging a bash command": 1 paragraph on the named paths and when a
command is opaque
**Reachable from:** consumed by T3 (`Approval::Judged`, built at `Switchboard#judged`, `cli/switchboard.rb:508-510`),
T4 (`Middleware::RememberedDenials`, built at `cli/tool_guard.rb:300`), T5 (`Approval::Escalation::Triage`, built
at `Switchboard#ladders` and `#plan_ladders`, `switchboard.rb:421,436`) and T12 (`Middleware::ConfineToScope`).
Each consumer takes `home:` from the `Sensitivity::Policy` it already holds, through the `Policy#home` reader this
card adds (`Policy`, `Policy::Confined` and `Policy::Null` all answer it; the value is the existing
`@anchors[:home]`, `policy.rb:272`)

**The `cd` rule.** A `cd` binds the stages after it only when its one argument is a literal directory and it is
joined to the next stage by `&&`. Every other `cd`, `pushd` or `popd` (bare, `-`, after `;`, `||`, `|` or `&`,
or inside a subshell) makes the rest of the command opaque, because naming a path under the wrong directory is a
bypass, not a false positive. A `-C <dir>` option (`git`, `make`, `tar`) makes its stage opaque for the same reason.

**Acceptance criteria**

```gherkin
Scenario: a sequence names each stage's paths against the directory it runs in
  Given the command "cd x && cat .env" and the cwd "/p"
  Then the named paths are "/p/x" and "/p/x/.env"
  And the command is not opaque

Scenario: a cd joined by anything but && makes the rest opaque
  Given each of "cd x || cat .env", "cd x; cat .env", "cd x | cat .env", "cd x & cat .env" and "(cd x); cat .env"
  Then each command is opaque

Scenario: a cd with no literal directory makes the rest opaque
  Given each of "cd && cat .env", "cd - && cat .env" and "pushd x && cat .env"
  Then each command is opaque

Scenario: a -C option makes its stage opaque
  Given the command "git -C ../other log"
  Then the command is opaque

Scenario: a program written as a path is named, a bare program is not
  Given the commands "/tmp/evil/cat f" and "cat f" in cwd "/p"
  Then the first names "/tmp/evil/cat" and "/p/f"
  And the second names only "/p/f"

Scenario: a redirect target is a named path and says it is written
  Given the command "echo hi > out.txt" and the cwd "/p"
  Then "/p/out.txt" is named as written

Scenario: an input redirect is a named path
  Given the command "cat < /etc/shadow"
  Then "/etc/shadow" is named as read

Scenario: a quoted word is unquoted, and an option's value is a path
  Given the command "head --file=/etc/shadow 'a b.txt'"
  Then the named paths include "/etc/shadow" and "/p/a b.txt"
  And "--file=/etc/shadow" itself is not named

Scenario: a glob names its fixed directory
  Given the command "ls ~/.cargo/registry/cache/*/" with HOME "/home/u"
  Then "/home/u/.cargo/registry/cache" is named

Scenario: an expansion makes the command opaque
  Given the command "cat \"$HOME/.ssh/id_rsa\""
  Then the command is opaque

Scenario: an uncovered or broken parse makes the command opaque
  Given the command "for f in *.key; do cat $f; done"
  Then the command is opaque

Scenario: a cd to a non-literal directory makes later stages opaque
  Given the command "cd $D && cat .env"
  Then the command is opaque

Scenario: /dev/null is not a named path
  Given the command "make 2>/dev/null"
  Then no path is named
```
Spec file: `spec/lain/shell/named_spec.rb`

**Interface**

```ruby
module Lain
  module Shell
    Named = Data.define(:paths, :opaque)

    # Reopened, not defined in the Data block: a constant there would land on
    # Lain::Shell (the CLAUDE.md trap).
    class Named
      Path = Data.define(:word, :resolved, :written)

      # @param command [String] the command as the model wrote it
      # @param cwd [String] absolute directory the call runs in
      # @param home [String] for `~`, from Sensitivity::Policy#home
      # @return [Named]
      def self.of(command, cwd:, home:) = ...

      def opaque? = opaque
      def written = paths.select(&:written)
    end
  end
end

# Sensitivity::Policy, Policy::Confined, Policy::Null
def home # => String, the existing @anchors[:home]
```

**Stop and report if:**
- `Shell::Parse::Stage` carries no link to the separator after it (`parse.rb:103,115,119`), so the `cd` rule cannot
  tell `&&` from `||`; report the seam rather than re-parse the source text.
- `Shell::Verdict`'s unquoting is not reachable without a `Term` (`verdict.rb:241`); report the seam rather than
  copy it.
- `grep password src` names `/p/password`, and T3's judged spec then parks an ordinary grep because `password`
  classifies as a secret name. That is the accepted cost of naming bare words; report it only if
  `spec/lain/seams/judged_approval_spec.rb` has a grep example that must stay judged.

### T3: Show the judge only a command whose named paths it may judge          [risk: high]

**Depends on:** T2
**Files:** `lib/lain/approval/judged.rb`, `spec/lain/approval/judged_spec.rb`,
`spec/lain/seams/judged_approval_spec.rb`
**Reuse:** `Judged#verdict_on` and `Policy#judge(...).oracle_approvable?` (`judged.rb:102-104`); the `UNJUDGEABLE`
abstain and its `escalation` record
**Shared-file wiring:** `docs/commands.md` "What each approval level does": `bash` joins the sentence on what never
reaches the judge, naming an opaque command
**Reachable from:** `Switchboard#judged` (`cli/switchboard.rb:508-510`) builds
`Approval::Judged.new(judge:, policy:, asking:, journal:)`, placed in the auto ladder by `judged_ladder` and
`plan_ladders`. `Judged` reads the call's cwd from `Session.cwd_of(context)` and `home` from `@policy.home` (T2)

**Acceptance criteria**

```gherkin
Scenario: a bash read of a credential never reaches the judge
  Given a chat under auto with a judge that would approve anything
  When the model calls bash "cat .env"
  Then the call parks for a human
  And the journal holds an escalation record with rung auto and reason unjudgeable
  And no judge child is spawned

Scenario: an opaque command never reaches the judge
  When the model calls bash "cat \"$HOME/.netrc\""
  Then the call parks for a human, unjudged

Scenario: an ordinary command still reaches the judge
  When the model calls bash "git log --oneline -5"
  Then the judge is asked

Scenario: a cd into a credential directory is judged by the named path
  When the model calls bash "cd secrets && ls"
  Then the call parks for a human, unjudged
```
Spec file: `spec/lain/approval/judged_spec.rb`, `spec/lain/seams/judged_approval_spec.rb`

**Stop and report if:**
- `spec/lain/approval/judged_spec.rb:168-180` (`bash("ls", "cwd" => "secrets")` parks) changes meaning; it should
  still park.
- A child's `Judged` is handed a `Policy::Confined` whose `home` differs from the chat's (`policy.rb:212-219`);
  a child's `~` must mean the same home as the main agent's.

### T4: Remember a human's deny by the gated paths a call named          [risk: high]

**Depends on:** T2; T3 (T3 also edits `spec/lain/seams/judged_approval_spec.rb`)
**Files:** `lib/lain/approval/queue.rb`, `lib/lain/middleware/remembered_denials.rb`,
`spec/lain/approval/queue_spec.rb`, `spec/lain/middleware/remembered_denials_spec.rb`,
`spec/lain/seams/judged_approval_spec.rb`
**Reuse:** `Queue#remember`, `Queue#denied` (`queue.rb:379,431-436`), `RememberedDenials#remembered` and `asked?`
(`remembered_denials.rb:62-70`), `Sensitivity::Policy#gates?`
**Shared-file wiring:** `docs/commands.md` "A deny you give is remembered": a deny is remembered by the paths the
call named, whatever the tool, and it refuses a later call only on a path that call is gated for
**Reachable from:** `Approval::Queue` is built at `Switchboard` (`cli/switchboard.rb:227`) and
`Middleware::RememberedDenials` at `cli/tool_guard.rb:300`

**The design.** `Queue` keeps no policy. It records a denied `bash` call by every path T2 names (or nothing, for an
opaque call), and a denied path tool by its path as today. `RememberedDenials` already gates at lookup: `asked?`
refuses only a call the policy would park. So "gated" is applied when a later call is checked, not when the deny
is stored, and `Queue.new(journal:, timeout:)` keeps its signature. A declined region release is still not
remembered: it is a no about a file's regions, not its path (`queue_spec.rb` near line 604 pins this, and it
stays).

**Blast radius, stated.** `Queue#denied` matches a path and everything under it. A deny of `ls /home/u` now
remembers `/home/u`, so every later gated read under it is refused for that requester. That is today's semantics
for a path tool, reached by more calls.

**Acceptance criteria**

```gherkin
Scenario: a denied cat holds against read_file
  Given a chat under ask
  When the human denies bash "cat .env"
  And the model then calls read_file ".env"
  Then the read is refused from memory with the human's reason
  And no approval is parked

Scenario: a denied read_file holds against cat
  When the human denies read_file ".env"
  And the model then calls bash "cat .env"
  Then the call is refused from memory

Scenario: a denied command does not deny its whole directory
  When the human denies bash "rm -rf build" with the reason "no deletes"
  And the model then calls read_file ".env"
  Then the read parks for a human
  And no remembered refusal is journaled

Scenario: an opaque denied command is not remembered
  When the human denies bash "cat \"$HOME/.netrc\""
  And the model then calls read_file "~/.netrc"
  Then the read parks for a human
```
Spec file: `spec/lain/approval/queue_spec.rb`, `spec/lain/middleware/remembered_denials_spec.rb`,
`spec/lain/seams/judged_approval_spec.rb`

**Stop and report if:**
- An example in `spec/lain/approval/queue_spec.rb:514-613` other than "remembers nothing for a call that names no
  path" changes meaning; that one becomes "names no path T2 can read", the rest must stay.
- `RememberedDenials#asked?` refuses a later call the policy would not park (its `gates?` test), so the first
  scenario's `read_file .env` is not refused; then the gate is not where this design assumes.

### T5: Refuse a named path that lands on a denied file, on the bash route          [risk: high]

**Depends on:** T2
**Files:** `lib/lain/approval/escalation.rb`, `lib/lain/cli/switchboard.rb`, `spec/lain/approval/escalation_spec.rb`,
`spec/lain/middleware/sensitivity_spec.rb`, `spec/lain/cli/switchboard_spec.rb`
**Reuse:** `Policy#judge` with `landed` (`policy.rb:321-326,~438`, via `Landing.of`), which already refuses the
6 link spellings for `read_file`; Triage's final-deny wording
**Shared-file wiring:** `docs/commands.md` "Account and sudo files are always refused": add "through a link, on
every tool"
**Reachable from:** `Switchboard#ladders` and `#plan_ladders` (`cli/switchboard.rb:421,436`) build `Triage`

**The design.** `Triage` is rebased onto T2, so the bash route has 1 word reader, not 2. Its own argv-word walk
(`PATHLIKE`, `BARE`, `MAX_NAMED`, `escalation.rb:473-640`) is replaced by `Shell::Named`, and each named path is
classified with its landing. The bare-word doctrine in the `PATHLIKE` comment (a bare word only abstains) is
kept as a rule on the classification, not on the reading: a named bare word whose landing is denied refuses,
and one whose written spelling alone is denied abstains, as today.

**Acceptance criteria**

```gherkin
Scenario: a link to /etc/shadow is refused on the bash route under every level
  Given a project holding "shadowlink" linked to "/etc/shadow"
  When the model calls bash "cat shadowlink" under ask, auto and bypass
  Then each call is refused finally, naming /etc/shadow
  And none parks

Scenario: a project's own etc/shadow is not that file
  Given a project file "etc/shadow"
  When the model calls bash "cat etc/shadow"
  Then the call is not refused as an account file

Scenario: the /proc/self/root alias is refused
  When the model calls bash "cat /proc/self/root/etc/sudoers"
  Then the call is refused finally
```
Spec file: `spec/lain/approval/escalation_spec.rb`, `spec/lain/middleware/sensitivity_spec.rb`

**Stop and report if:**
- `Switchboard` has no `Sensitivity::Policy` to hand `Triage` beside the per-call classifier factory it passes
  today (`board_build.rb:~266-330`); report which object owns the landing check.
- An existing `spec/lain/approval/escalation_spec.rb` example on `PATHLIKE` or `MAX_NAMED` changes its verdict
  after the rebase; list each one before rewriting it.

### T6: Tell the judge the project, the requester's place and what lies outside it          [risk: medium]

**Depends on:** T3
**Files:** `lib/lain/approval/judge.rb`, `lib/lain/approval/judged.rb`, `lib/lain/cli/wiring/judge_source.rb`,
`lib/lain/prompt/templates/role/auto_approver.md`, `spec/lain/approval/judge_spec.rb`,
`spec/lain/approval/judged_spec.rb`, `spec/lain/cli/wiring/judge_source_spec.rb`
**Reuse:** `Session.cwd_of(context)`, `Policy.base_of(context)` (`judged.rb:103`), `Queue.requester_for(context)`;
T3's named paths for `bash`; the role's existing template
**Shared-file wiring:** `docs/commands.md` "`auto` asks a judge first": name what the judge is shown
**Reachable from:** `Approval::Judged#call` -> `Approval::Judge#call` through `CLI::Wiring::JudgeSource#call`,
which forwards the keywords

The human's request is **not** in scope: nothing on the gate's side holds it (no last-prompt accessor in
`session.rb`), and threading the timeline through the gate is its own change. The template stops asking the judge
to weigh "the stated intent" it is never given.

**Acceptance criteria**

```gherkin
Scenario: the judge is shown where the call runs
  Given a researcher whose lease is "/state/leases/r1" in project "/p"
  When its bash call is put to the judge
  Then the judge's prompt names the project root "/p" and the working directory "/state/leases/r1"
  And it names the requester's role "researcher"

Scenario: the judge's role text asks only about what it is shown
  When the auto_approver's prompt is rendered
  Then it does not ask the judge to weigh a stated intent

Scenario: a listing outside the project is shown as outside
  When the main agent calls bash "ls ~/.cargo/registry" in project "/p"
  Then the judge's prompt names "/home/u/.cargo/registry" as outside the project root
```
Spec file: `spec/lain/approval/judge_spec.rb`, `spec/lain/approval/judged_spec.rb`

**Interface**

```ruby
# Approval::Judge
def call(requester:, tool:, input:, place:) # place: Judge::Place(root:, cwd:, role:, outside:)
```

**Stop and report if:**
- `Judge::DEFERRING` or another caller of `Judge#call` cannot supply `place:`
  (`grep -rn 'Judge.new\|judge.call' lib spec`); list each and add its spec to Files.
- The requester's role is not on `context` (only its requester label, `Queue.requester_for`); report rather than
  infer a role from the label.

### T7: Refuse a project's override of an approval role's prompt          [risk: medium]

**Depends on:** T10
**Files:** `lib/lain/prompt/slots.rb`, `lib/lain/role/catalog.rb`, `spec/lain/prompt/slots_spec.rb`
**Reuse:** the existing unknown-role refusal in `Slots.load` (`read_role_fills`)
**Shared-file wiring:** `docs/commands.md`, the slots section: `auto_approver`, `gate_adjudicator` and
`evidence_researcher` cannot be overridden, and why
**Reachable from:** `CLI::ChatLaunch` -> `CLI::Backend#library` -> `Skill::Library.load` -> `Prompt::Slots.load`

**Acceptance criteria**

```gherkin
Scenario: an approval role's slot refuses the launch by name
  Given a project with ".lain/slots/role/auto_approver.md"
  When "lain chat" is launched there
  Then it exits non-zero naming that file and saying the role decides approvals
  And no session file is written

Scenario: an ordinary role's slot still overrides
  Given a project with ".lain/slots/role/researcher.md"
  Then the researcher's prompt carries the project's text
```
Spec file: `spec/lain/prompt/slots_spec.rb`

**Stop and report if:**
- The approval roles are not named anywhere a `Role` can answer (`role/catalog.rb`); the card adds a catalog
  attribute rather than a list in `slots.rb`, and reports if that ripples into `spec/lain/role_spec.rb`.

### T8: Never let the secret oracle approve a region a named shape flagged          [risk: high]

**Depends on:** none
**Files:** `lib/lain/approval/secret_surface.rb`, `spec/lain/approval/secret_surface_spec.rb`
**Reuse:** `47902e7c`'s path-gate rule in `SecretSurface` (an approve the oracle may not give becomes a defer);
`Sensitivity::Regions::Region#detector` and `#entropy?` (`regions.rb:383,~429`)
**Shared-file wiring:** `docs/commands.md` "`--secret-oracle`": a pattern-detected region always reaches a human
**Reachable from:** `CLI::Wiring` builds `Approval::SecretSurface` under `--secret-oracle`

**Acceptance criteria**

```gherkin
Scenario: a ghp_ token in an ordinary-named file is not released by the oracle
  Given a chat with --secret-oracle whose oracle answers approve at 0.95
  When the model reads "notes/config.txt" holding a ghp_ token
  Then the release parks for a human
  And the journal records the oracle's approve as deferred by rule

Scenario: an entropy-only region may still be released by the oracle
  Given a file whose only flagged region is a high-entropy token
  When the oracle answers approve at 0.95
  Then the release is approved by the oracle
```
Spec file: `spec/lain/approval/secret_surface_spec.rb`

**Stop and report if:**
- `pending.outstanding.regions` do not carry `detector` at `SecretSurface` (`queue.rb:42-110` withholds the reason
  from the human preamble); the card reads the detector, not the reason, and must not show either to the oracle.

### T9: Detect the common password shapes the detector misses          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/sensitivity/regions.rb`, `spec/lain/sensitivity/regions_spec.rb`
**Reuse:** `ASSIGNMENTS` and `qualifies?` (`regions.rb:~244-250`); the content side, per the comment at
`credential_patterns.rb:~97-105` that new shapes belong there
**Shared-file wiring:** none
**Reachable from:** `Sensitivity::Regions`, run by `Middleware::RedactSecretReads` and the survey projection on every
read route

**Acceptance criteria**

```gherkin
Scenario: a quoted JSON or Python password key is a region
  Given files holding {"password": "hunter2xyz"} and {'password': 'hunter2xyz'}
  When each is read with read_file
  Then each value is masked

Scenario: a suffixed password key is a region
  Given a file holding "db_password: hunter2xyz"
  When it is read with read_file
  Then the value is masked

Scenario: URL credentials are a region
  Given a file holding "postgres://app:hunter2xyz@db.local/app"
  When it is read with read_file
  Then the password is masked and the host is not

Scenario: a mysql password flag is a region
  Given a file holding "mysql -u root -phunter2xyz"
  When it is read with read_file
  Then the value after -p is masked

Scenario: a bearer header is a region
  Given a file holding "Authorization: Bearer abcdef0123456789abcd"
  When it is read with read_file
  Then the token is masked

Scenario: ordinary lines are not regions
  Given a file holding "mkdir -p build", "gcc -pthread main.c", "https://example.com/path" and "password_policy: strict"
  When it is read with read_file
  Then nothing is masked
```
Spec file: `spec/lain/sensitivity/regions_spec.rb`

**Stop and report if:**
- A new shape has to enter `CredentialPatterns::WRITE`, which `spec/lain/credential_patterns_spec.rb:28-48` pins and
  `memory_write` refuses on; keep the shapes content-side.
- `password_policy: strict` masks under the yaml shape's value gate; report the false positive rather than widen
  the gate.

### T10: Tell each child its own working directory          [risk: high]

**Depends on:** none
**Files:** `lib/lain/prompt/environment.rb`, `lib/lain/prompt/slots.rb`, `lib/lain/role.rb`,
`lib/lain/tools/subagent.rb`, `spec/lain/prompt/environment_spec.rb`, `spec/lain/prompt/slots_spec.rb`,
`spec/lain/role_prelude_wiring_spec.rb`, `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/tools/subagent_spec.rb`,
`spec/lain/role_spec.rb`
**Reuse:** `Environment` is a `Data` (`with(cwd:)`); `ChildBuilder#build` already holds `worker_env`
(`subagent.rb:~1473`); `Role#child_context` (`role.rb:61-64`) renders segment 0 and the role tail
**Shared-file wiring:** `ARCHITECTURE.md`: a child's working directory is stated in its role tail, after the cache
breakpoint, so siblings still share segment 0
**Reachable from:** `Tools::Subagent::ChildBuilder#reshaped_context` (`subagent.rb:1693`), the one path every
child's context takes (researcher leases, worktree workers, epic workers via `RoleSpawn#within`, survey docents,
the judge)

**The design.** A child's segment 0 is a child form of the system render: the environment block with its
working-directory line replaced by `Working directory: stated after your role instructions` (the same bytes for
every child, so siblings still share the cached prefix). The role tail, which sits after the breakpoint, starts
with `Working directory: <worker_env.cwd>`. The main agent's render is unchanged. So `Slots` gains a child
render, and `Role#child_context` and `Persona#child_context` take `worker_env:`. `Persona.new(role, slots)` keeps
its signature, so its constructors in `skill/role_spawn.rb:113` and `cli/wiring/toolset_build.rb:440` do not
change. `Persona::Null` answers `child_context` with the same keyword.

**Acceptance criteria**

```gherkin
Scenario: a researcher is told its lease
  Given a chat in project "/p" whose researcher leases "/state/leases/r1"
  When the researcher's first request is rendered
  Then its system text names "/state/leases/r1" as its working directory
  And it does not name "/p" as its working directory

Scenario: an epic worker is told its worktree
  Given an epic worker running in worktree "/w/issue-1"
  Then its system text names "/w/issue-1" as its working directory

Scenario: siblings still share the cached prefix
  Given 2 researchers with different leases
  Then their first system segment is byte-identical
  And only the role tail names each lease

Scenario: the main agent's system text is unchanged
  Then the main agent's system text names the launch cwd, as before
```
Spec file: `spec/lain/prompt/environment_spec.rb`, `spec/lain/role_prelude_wiring_spec.rb`,
`spec/lain/cli/chat_launch_spec.rb`

**Stop and report if:**
- `spec/lain/cli/chat_launch_spec.rb:531-550` (`researcher_system(backend)` includes the parent's block) cannot be
  rewritten to the new contract without losing what it guards.
- `SiblingTemplate` (`tool/spawn_policy.rb`) appends a sibling-invariant template to the factory's system text, and
  that template carries a working directory; then a sibling's text names 2 places, so report which one wins.
- `Telemetry::SlotFills` or `slots.digests` move for the main agent.

### T11: Give a researcher its kept lease on every route          [risk: high]

**Depends on:** T10
**Files:** `lib/lain/skill/role_spawn.rb`, `lib/lain/role/catalog.rb`, `lib/lain/cli/wiring/toolset_build.rb`,
`spec/lain/skill/role_spawn_spec.rb`, `spec/lain/seams/research_lease_spec.rb`
**Reuse:** `Tools::Subagent::Kept`, `Kept#lease_for`, `ToolGuard::Spawned#with(confined: true)` and `held_in`, as
`research_subagent` builds them (`toolset_build.rb:398-411`)
**Shared-file wiring:** `docs/commands.md`, researcher leases: `@researcher[/skill]` gets the same lease
**Reachable from:** `Middleware::SkillDispatch` -> `Skill::RoleSpawn#call` -> `#build_subagent`, built in
`CLI::Wiring::ToolsetBuild` (`role_spawn_seam`)

**Acceptance criteria**

```gherkin
Scenario: a skill-dispatched researcher writes only in its lease
  Given a chat in a git project
  When "@researcher[/critique] lib/x.rb" runs and the researcher calls write_file "CRITIQUE.md"
  Then the file lands in the researcher's kept lease
  And the project's working tree and HEAD are unchanged

Scenario: its write outside the lease is refused naming the lease
  When it calls write_file with an absolute path inside the project
  Then the call is refused, naming its lease

Scenario: its requester is named researcher
  Then the approval row and the journal name the requester "researcher", not "subagent"
```
Spec file: `spec/lain/seams/research_lease_spec.rb`, `spec/lain/skill/role_spawn_spec.rb`

**Stop and report if:**
- `spec/lain/middleware/skill_dispatch_spec.rb:170-205` uses a fake `RoleSpawn` and so cannot see the lease; the
  seam spec is where the real route is pinned.
- Another role on the skill route (`dev`, `test_engineer`) would also take a lease from the same attribute; only the
  researcher is in scope.

### T12: Confine a worktree child to its worktree          [risk: high]

**Depends on:** T2, T11
**Files:** `lib/lain/cli/tool_guard.rb`, `lib/lain/middleware/confine_to_scope.rb`,
`spec/lain/cli/tool_guard_spec.rb`, `spec/lain/middleware/confine_to_scope_spec.rb`,
`spec/lain/seams/child_worktree_approval_spec.rb`
**Reuse:** `ConfineToScope`'s `LEASE` wording and `Session::Confined#holds?` (`session.rb:~615-622`, with
`Landing.of`); `ToolGuard.held_in` (`tool_guard.rb:258-262`); T2's `Shell::Named#written` and the `cd` targets
**Shared-file wiring:** `docs/commands.md`, `--isolation worktree`: a worker's writes, redirects and `cd` stay in
its worktree
**Reachable from:** `ToolGuard::Spawned#call` -> `ToolGuard.child_stack(..., confined:)`, for every child whose
`worker_env` is a lease

**Acceptance criteria**

```gherkin
Scenario: a worktree worker's absolute write into the parent checkout is refused
  Given a chat under --isolation worktree
  When a dev worker calls write_file "/p/notes.txt" in parent project "/p"
  Then the call is refused, naming the worker's worktree
  And "/p/notes.txt" does not exist

Scenario: a worker's cd into the parent checkout is refused
  When the worker calls bash "cd /p && cat > x.rb"
  Then the call is refused, naming the worktree

Scenario: a worker's cd into the parent checkout is refused even with no write
  When the worker calls bash "cd /p && ls"
  Then the call is refused, naming the worktree

Scenario: a worker's write inside its worktree still runs
  When the worker calls write_file "notes.txt"
  Then it lands in the worktree

Scenario: a worker's opaque command is left to the ladder
  When the worker calls bash "cd $D && ls"
  Then ConfineToScope does not refuse it, and the approval ladder decides it
```

A `cd` out of the worktree is refused whatever follows it, because every later stage then runs in the parent
checkout. Reads with a path tool stay as they are (parked as `outside_project`).
Spec file: `spec/lain/seams/child_worktree_approval_spec.rb`, `spec/lain/middleware/confine_to_scope_spec.rb`

**Stop and report if:**
- `Sensitivity::Policy#confined` prepending the human root (`policy.rb:345`) is what a worktree child's reads rely
  on (`child_worktree_approval_spec.rb:222-247` parks them); reads stay as they are, only writes and `cd` move.
- An epic worker's `epic_write` into the epic home is refused; it is special-cased in `ConfineToScope::CONFINED`
  and must stay allowed.

### T13: Name a docent's file relative to the docent's own root          [risk: medium]

**Depends on:** T10 (its seam specs read the docent's first request, whose system text T10 changes)
**Files:** `lib/lain/review/docent.rb`, `lib/lain/cli/command/survey.rb`, `spec/lain/seams/docent_outside_root_spec.rb`,
`spec/lain/seams/survey_subdirectory_spec.rb`
**Reuse:** `Review::Source::Corpus::Prefix.between`; `Command::Survey#worker_env_at` (`survey.rb:~310`)
**Shared-file wiring:** none
**Reachable from:** `Command::Survey#docent_of` -> `Review::Docent#brief`

**Acceptance criteria**

```gherkin
Scenario: a docent on a subdirectory survey reads the file the note is on
  Given "/survey ./sub" and a note on "sub/hello.rb" line 2
  When the docent is asked to read the file
  Then its brief names "hello.rb" relative to its root "/p/sub"
  And its read_file of that name returns the file

Scenario: a docent on a survey outside the root reads the file
  Given "/survey /q/tree" and a note on "lib/calc.rb"
  Then the docent's read of the briefed path returns the file, unparked
```
Spec file: `spec/lain/seams/docent_outside_root_spec.rb`, `spec/lain/seams/survey_subdirectory_spec.rb`

**Stop and report if:**
- The human-facing corpus and note paths change: `Command::Survey`'s comment (`survey.rb:246-255`) keeps them
  relative to the chat cwd on purpose; only the brief moves.

### T14: Let an epic's children read the epic's own home          [risk: medium]

**Depends on:** T12
**Files:** `lib/lain/cli/tool_guard.rb`, `spec/lain/cli/tool_guard_spec.rb`, `spec/lain/seams/child_read_scope_spec.rb`
**Reuse:** `ToolGuard.confined(inputs, worker_env)`'s `roots:` (`tool_guard.rb:~268`); `Epic::Home.container`
(`epic/home.rb:77-87`)
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicDriver::IssueActor` -> `Lanes#over(worker_env, branch)` -> `role_spawn.within` ->
`ToolGuard.confined`

**Acceptance criteria**

```gherkin
Scenario: an issue orchestrator reads its own plan without parking
  Given an epic under epics_home :xdg
  When the issue orchestrator calls read_file on "plans/<id>.md" in its epic home
  Then the read returns the plan and nothing parks

Scenario: another epic's home is still outside
  When the same child reads a plan in a different epic's home
  Then the read parks as outside_project
```
Spec file: `spec/lain/seams/child_read_scope_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`

**Stop and report if:**
- The epic home is not reachable from `ToolGuard.confined`'s inputs for an epic child; report where it would have
  to be threaded rather than add a global.

### T15: Keep a pinned prompt and its answer together          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/context/pinned_messages.rb`, `spec/lain/context/pinned_messages_spec.rb`,
`spec/lain/compaction/source_spec.rb`
**Reuse:** `PinnedMessages#matched`/`paired` (`pinned_messages.rb:~110-150`), which already close a pin over a
tool_use/tool_result pair
**Shared-file wiring:** none
**Reachable from:** `Compaction::Source#decide` builds `Head` with `pins:` (`source.rb:629-631`); `PinCuts`
(`derived.rb:366-411`) and `Context::Compact` read the same pin set

**Acceptance criteria**

```gherkin
Scenario: a pinned first prompt keeps its answer through a cut
  Given a session under summarize-conversation whose first prompt is pinned
  And enough later turns to trigger a compaction
  When the cut is derived
  Then the first prompt and the assistant reply that answered it both survive verbatim
  And the summary covers only later messages

Scenario: pinning an answer keeps its prompt
  Given a pin on an assistant reply
  Then the user prompt it answered is held with it
```
Spec file: `spec/lain/context/pinned_messages_spec.rb`, `spec/lain/compaction/source_spec.rb`

**Stop and report if:**
- `Head` and `Context::Compact` disagree on the pin set after the change (`Head`'s class docs require they agree).
- The reply is a tool_use whose result is far below it; the existing pair closure must carry it, and the card
  reports if the 2 closures interact.

### T16: Attest an elided message with a short digest          [risk: low]

**Depends on:** none
**Files:** `lib/lain/compaction/strategy/elide.rb`, `lib/lain/compaction/summary_snapshot.rb`,
`spec/lain/compaction/strategy/elide_spec.rb`, `spec/lain/compaction/summary_snapshot_spec.rb`
**Reuse:** the shared attestation format (`elide.rb:89-92`, `summary_snapshot.rb:~243`)
**Shared-file wiring:** none
**Reachable from:** `Compaction::Strategy::Elide`, selected by `--compact-strategy` and composed strategies

**Acceptance criteria**

```gherkin
Scenario: an attestation carries a 12-character digest
  When a message is elided
  Then its attestation reads "<role> <12 hex> <n> bytes"

Scenario: 176 attestations cost at most 40% of what they did
  Given 176 elided messages
  Then their attestation text is at most 40% of its byte size before the change
```
Spec file: `spec/lain/compaction/strategy/elide_spec.rb`, `spec/lain/compaction/summary_snapshot_spec.rb`

**Stop and report if:**
- Anything outside the 2 strategies parses the digest back (the Explore pass found nothing:
  `grep -rn ' bytes"' lib/lain/compaction`); a reader would need the full digest.

### T17: Stop a reply at the window instead of shifting context          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/ollama/encoding.rb`, `spec/lain/provider/ollama/encoding_spec.rb`,
`lib/lain/cli/repl/ask.rb`, `spec/lain/cli/repl/ask_spec.rb`
**Reuse:** the `truncate: false` line and its comment (`encoding.rb:72-83`); `RAISE_MAX_TOKENS` (`repl/ask.rb:93`)
**Shared-file wiring:** `docs/commands.md`, the ollama provider: lain sends `shift: false`, and a reply that fills
the window is cut and says so
**Reachable from:** `Provider::Ollama` encodes every request through `Encoding#encode`

**Acceptance criteria**

```gherkin
Scenario: every ollama request forbids a context shift
  When any request is encoded for ollama
  Then the body carries shift false beside truncate false

Scenario: a cut at the window names the window, not --max-tokens
  Given a reply stopped with done_reason length after fewer output tokens than max_tokens
  Then the person is told the context window filled
  And the line does not tell them to raise --max-tokens
```
Spec file: `spec/lain/provider/ollama/encoding_spec.rb`, `spec/lain/cli/repl/ask_spec.rb`

**Stop and report if:**
- The stop reason reaching `Repl::Ask` does not carry the output token count, so the 2 cuts cannot be told apart;
  report the seam in `provider/ollama/stream_assembler.rb`.
- `spec/lain/cli/repl/ask_spec.rb` does not exist; name the spec that pins `RAISE_MAX_TOKENS` instead.

### T18: Redraw a header whose row count changed          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/input_pane.rb`, `spec/lain/frontend/input_pane_spec.rb`,
`spec/lain/seams/input_pane_socket_spec.rb`
**Reuse:** `rewrite`, `headed`, `@adopted`/`retracted`, `forget_rows` (`input_pane.rb:~275-336,436`)
**Shared-file wiring:** none
**Reachable from:** `InputPane#received` -> `idle`/`headed`/`restyled` and `prompted`/`reheaded`, run by
`InputPane.open(...).run` from `exe/lain`

**Acceptance criteria**

```gherkin
Scenario: a spawn's fleet row redraws the header during an ask
  Given an input pane showing a 1-row header with no draft typed
  When the chat publishes a 2-row header because a child spawned
  Then the pane shows the 2-row header in place of the old one
  And exactly 2 header rows are on screen

Scenario: a header that shrinks leaves no stale row
  When the header goes from 2 rows to 1
  Then exactly 1 header row is on screen

Scenario: a draft is never clobbered
  Given the human has typed "abc" and not sent it
  When the header changes row count
  Then "abc" is still on the input row
  And the new header is drawn at the next prompt
```
Spec file: `spec/lain/frontend/input_pane_spec.rb`, `spec/lain/seams/input_pane_socket_spec.rb`

**Stop and report if:**
- `spec/lain/frontend/input_pane_spec.rb:438-451` ("leaves a header of a different row count for the next
  prompt") must be rewritten; it is the guard this card replaces, and the draft case keeps its intent.
- The cooked-mode cursor save and restore cannot walk back a different count without reading the screen.

### T19: Report a file as written only when its write succeeded          [risk: low]

**Depends on:** none
**Files:** `lib/lain/session.rb`, `spec/lain/session_spec.rb`, `spec/lain/agent/tool_delivery_spec.rb`
**Reuse:** `Session#record_write` and `@writes` (`session.rb:~311-315`); `PreImages#written`
**Shared-file wiring:** none
**Reachable from:** `Agent::ToolDelivery#report_writes` -> `Session#round_writes`

**Acceptance criteria**

```gherkin
Scenario: a write that fails is not reported
  When the model calls write_file "newdir/x.txt" and the directory is missing
  Then the tool result is an error
  And the round reports no written file

Scenario: an edit that fails is not reported
  When edit_file fails to write
  Then the round reports no written file

Scenario: a write that succeeds is reported
  When write_file "x.txt" succeeds
  Then the round reports "x.txt"
```
Spec file: `spec/lain/session_spec.rb`, `spec/lain/agent/tool_delivery_spec.rb`

**Stop and report if:**
- `Workspace::Snapshot` (via `ToolDelivery#settle`) depends on a pre-image for a path that was never written; read
  `snapshot_log.rb` and report before changing what `pre_images` holds.

### T20: Make a rebound approval key work at the input pane's prompts          [risk: medium]

**Depends on:** T18
**Files:** `lib/lain/frontend/stdin_pump.rb`, `lib/lain/frontend/line_editor.rb`, `lib/lain/frontend/input_pane.rb`,
`spec/lain/seams/approval_cycle_key_spec.rb`
**Reuse:** `StdinPump.bind_cycle`, `LineEditor::Registry#bind` and `verify_routing`
(`line_editor.rb:~445-460`); `user_binds` in the seam spec (line 135)
**Shared-file wiring:** none
**Reachable from:** `exe/lain` -> `InputPane.open(path:)` -> `StdinPump.new(..., cycle_key:)` -> `#start` ->
`bind_cycle`

**Acceptance criteria**

```gherkin
Scenario: a rebound key cycles the level at an idle pane prompt
  Given a user config with keys approval_cycle "C-x", trusted
  And a cockpit's input pane at an idle "you>"
  When the human presses C-x
  Then the session's approval level changes and a mode_switch is journaled

Scenario: the rebound key works at command>
  Given a call parked and the pane at "command>"
  When the human presses C-x
  Then the approval level changes

Scenario: Shift+Tab no longer cycles once rebound
  When the human presses Shift+Tab at "you>"
  Then the approval level is unchanged
```
Spec file: `spec/lain/seams/approval_cycle_key_spec.rb`

**Stop and report if:**
- The first scenario passes before any change. Then the cause is in how the pane process resolves the user config
  (`InputPane.open` uses `Paths.new`, `pane_command.rb` forwards only `PANE_ENV`); reproduce in a real tmux pane
  and report what the pane's `Config.keys` returns.
- `bind_cycle` returns early on `LineEditor.bound?` for a stale handler.

### T21: Tell `lain land wait` and `enqueue` whether a drainer is landing          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/land.rb`, `lib/lain/file_lock.rb`, `spec/lain/cli/land_spec.rb`, `spec/lain/file_lock_spec.rb`
**Reuse:** `Land::ALIVE`, `Land#holder_line` (`land.rb:18,~206`), `FileLock#holder` and `#claimed`
(`file_lock.rb:50,~88-93`), `Spawner::BY_HAND`
**Shared-file wiring:** `docs/commands.md`, `lain land wait`: exit 3 when no drainer is landing, with the command
to run
**Reachable from:** `CLI::Land#enqueue`, `#wait` and `#status`, dispatched by `lain land`

**Acceptance criteria**

```gherkin
Scenario: wait with no drainer says so
  Given a queued entry and no live drainer holding the lock for 5 seconds
  When "lain land wait <id>" runs
  Then it prints the "lain land drain --branch <b>" command
  And it exits 3

Scenario: wait over a killed drainer says so
  Given a drainer killed with SIGKILL, leaving its holder line
  Then "lain land wait" exits 3 naming the dead pid

Scenario: enqueue over an unopenable lock refuses by name
  Given a drain.lock the user cannot open
  When "lain land enqueue" runs
  Then it does not say "a drainer is landing it"
  And it names the lock file it cannot open

Scenario: status over an unreadable lock names it
  When "lain land status" runs over that lock
  Then it prints one line naming the file, with no backtrace
```
Spec file: `spec/lain/cli/land_spec.rb`, `spec/lain/file_lock_spec.rb`

**Stop and report if:**
- Telling a live drainer from none needs a `FileLock#try` from `wait`; `holder_line`'s comment (`land.rb:~200`) warns
  against trying the lock from `status`. Read `Drain#call`'s retry and report before probing.

### T22: Explain a mailbox block in every agent's system text          [risk: low]

**Depends on:** T7
**Files:** `lib/lain/prompt/templates/system.md.erb`, `spec/lain/prompt/slots_spec.rb`
**Reuse:** the `<mailbox>` format (`context/mailbox.rb:~121-143`): `<from> | <text>`
**Shared-file wiring:** none
**Reachable from:** `Prompt::Slots#render("system")`, segment 0 of every agent and child

**Acceptance criteria**

```gherkin
Scenario: the system text says what a mailbox block is
  When the main agent's system text is rendered
  Then it says a <mailbox> block holds messages delivered between turns
  And it says "human" is the person at the keyboard, "lain" is the harness, and any other sender is an agent

Scenario: a child's system text says the same
  Then a researcher's first segment carries the same sentence
```
Spec file: `spec/lain/prompt/slots_spec.rb`

**Stop and report if:**
- `spec/lain/cli/chat_launch_spec.rb` or `spec/lain/cli/backend_spec.rb` pin the system text byte for byte; list them
  and add them to Files.

### T23: Keep a finished judge out of the fleet's ended rows          [risk: low]

**Depends on:** none
**Files:** `lib/lain/status_feed/fleet.rb`, `spec/lain/status_feed/fleet_spec.rb`
**Reuse:** `StatusFeed::Fleet::ENDED_SHOWN` (`fleet.rb:66,194`); the `:spawn` record's role name
**Shared-file wiring:** none
**Reachable from:** `StatusFeed#observe` -> `Fleet`, read by `lain://status` and the input pane's header

**Acceptance criteria**

```gherkin
Scenario: 10 finished judges do not push out a finished researcher
  Given 1 finished researcher and then 10 finished auto_approver children
  Then the fleet's ended rows still show the researcher
  And no ended auto_approver row is shown

Scenario: a judge that is running is shown
  Given an auto_approver child running
  Then the fleet shows its row
```
Spec file: `spec/lain/status_feed/fleet_spec.rb`

**Stop and report if:**
- `spec/lain/status_feed/fleet_spec.rb:432-438,465` pin a judge row among the ended ones.

### T24: Show a human what the judge decided          [risk: medium]

**Depends on:** T6; T4 (both may edit `spec/lain/approval/queue_spec.rb`)
**Files:** `lib/lain/approval/judged.rb`, `lib/lain/frontend/neovim/approval_view.rb`,
`lib/lain/frontend/approval_policy.rb`, `spec/lain/approval/judged_spec.rb`,
`spec/lain/frontend/neovim/approval_view_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`
**Reuse:** `Telemetry::FilesWritten` and `frontend/decorators/files_written.rb` as the shape for a stamped transcript
line; the `escalation` record `Judged#record` already writes
**Shared-file wiring:** none
**Reachable from:** `Approval::Judged#call` under `--approval auto`; the chat transcript and `lain://approval`

**Acceptance criteria**

```gherkin
Scenario: a judge approve leaves a line in the transcript
  Given a chat under auto
  When the judge approves bash "git log --oneline -5"
  Then the transcript shows one stamped line naming the call and that the judge approved it

Scenario: a judge defer is marked on the parked row
  When the judge defers a call and it parks
  Then the lain://approval row and the plain-chat prompt say the judge deferred it

Scenario: an ask-level park is not marked
  Given a chat under ask
  When a call parks
  Then its row does not mention a judge
```
Spec file: `spec/lain/approval/judged_spec.rb`, `spec/lain/frontend/neovim/approval_view_spec.rb`,
`spec/lain/frontend/approval_policy_spec.rb`

**Stop and report if:**
- A parked `Queue::Pending` has no field the judge's defer can set; adding one changes `Pending`'s value shape,
  pinned in `spec/lain/approval/queue_spec.rb`, so add it to Files and report.
- Output discipline: the line must reach the transcript through a `Sink` or `Channel`, never `$stdout`
  (`spec/output_discipline_spec.rb`).

## Integration checks

1. `bundle exec rake pspec` green, and the example count at or above the count before the first card (CLAUDE.md:
   a dead worker reads as a pass).
2. `bundle exec rubocop`, `cargo clippy --all-targets -- -D warnings`, `pre-commit run --all-files`.
3. `bin/zeitwerk-census --check`, `bin/comment-census --check-tickets`, `bin/spec-census --check`. T2 adds
   `lib/lain/shell/named.rb`; the census must place it.
4. The main session applies every Shared-file diff, then corrects the QA scenarios each card touched:
   `shell-term-approval.md`, `shell-terms.md`, `secret-boundary.md`, `subagents-and-backends.md`, `epic-tier.md`
   §10c, `survey.md` §4, `rails-blog.md` §1b, `cockpit-surfaces.md` §0 and §7, `merge-coordinator.md`,
   `prompt-slots-and-roles.md`, and `greenfield-epic.md`.
5. **Manual, owed by the next QA round (round 25):** re-drive each round-24 finding this plan closes from its
   reproduction in the findings file, c24-4 under a memory cap first. Then the user's ruling stands: the "not
   reached" sections are that round's coverage debts.

## Execution log
