# Scenario: the survey command

**What it exercises:** `/survey` and `lain survey` **as commands** — the parse, the refusals, the
ceilings at a scale no round has ever driven, the walk's admission decisions, the one-review-per-chat
guard, and the docent thread that is the only part of a survey that spends a model call.

**What it deliberately does NOT own:** the gesture rails. `<CR>`, `x` and its three refusals,
`:LainReviewVerdict`, the note rail's kinds and placement order, and the refusal-delivery rule all
belong to [`cockpit-surfaces.md`](cockpit-surfaces.md) §4 and §4b and are driven there, on a dummy
tree small enough to state in full. **That is the right subject for an anchor assertion and the
wrong one for everything below**, because every check here needs either a tree of real size or a
tree with something planted in it.

**Cost:** §1–§6 cost **nothing** — no model, and §1 needs no editor either. §7 spends four local
completions, which on this bench is time rather than money. **No step spends quota.**

**Needs:** the cockpit (`lain up`) for §2 onward; a checkout of lain itself as the surveyed tree for
§2; `mktemp -d` for §4's planted tree. §7 needs the **local** ollama bench up — see
[`bench.md`](../bench.md) for which of the two installs, the residency controls, and the `--num-ctx`
alignment that avoids a 27s reload. **Nothing here needs a remote provider**; §8 says why that is a
choice rather than an omission.

**Do not run this to answer "does `/survey` work".** Round 7's supplement settled that the
mechanics work. Run it to answer: *does it refuse honestly at a size nobody has driven, does the
walk admit and withhold the right paths, and is the model half reachable at all?*

**Standing gap this scenario exists to close:** the docent thread pane (`<leader>Lt`) has been
**owed since round 7** — dropped by rounds 8, 9 and 10. §7 is that debt. If a round can drive only
one section here, drive §7.

---

## 1. The command surface, with no editor and no model

`/survey`'s parse has four refusals and they are told apart on purpose. Drive them in a **headless**
chat (`lain chat`, no `--nvim`) — the no-editor refusal is the first thing on the path, so this
section needs nothing running:

```
you> /survey
you> /survey ./lib --scope
you> /survey ./lib --scope --unbounded
you> /survey ./lib --squash
you> /survey ./lib
```

Expected, in order:

- **no path** → the usage line, not an error. It must name all three flags and enumerate the scopes
  from the strategy registry: `--scope cumulative|commits|by_directory` (**re-measured round 11**;
  a scope that stops shipping must stop being advertised, so read the list against
  `Review::Partition::STRATEGIES`, which is `[Whole, ByCommit, ByDirectory]` keyed by
  `strategy.name` — the CLASS names and the SCOPE names differ, so read the registry, not the list).
- **`--scope` at end of line** → the *needs a value* sentence, **not** the unknown-flag one.
- **`--scope --unbounded`** → also *needs a value*, naming `--scope`. A survey at a scope called
  `--unbounded` is the defect this split exists to prevent.
- **`--squash`** → the *unknown flag* sentence. The two remedies are opposites (delete the word you
  got right vs. supply the word after it), which is why one sentence for both would be wrong.
- **a valid line, headless** → the no-editor refusal, which must name `lain up --nvim`, `lain chat
  --nvim <socket>` **and** `lain survey <path>` as the text alternative. It must **not** coalesce to
  a Null surface and draw nothing.

Then the one-shot, which needs no editor at all:

```bash
lain survey ./lib/lain/survey
lain survey open help      # the disambiguating verb, for a path colliding with a command name
```

Headline format is `surveying <root> at <scope> scope: <n> files`. **`lain survey` renders and
submits nothing** — it has no `--permissive`, because there is no verdict to judge. Confirm the
flag is refused rather than silently accepted.

## 2. The ceilings, at a size no round has driven

Every `/survey` ever driven has been over three or four files. `Bounds` refuses past **300 files**
or **30,000 rendered lines** (`review/bounds.rb:72,84`), and `#cumulative_advice` composes a remedy
naming a narrower scope **only when that scope actually fits** — reasoned code
(`bounds.rb:44-57`) that no human has read firing on a tree it was written for.

Measured over `git ls-files`. **`Survey::Walk` does NOT shell to plain `git ls-files` — it lists
UNTRACKED files too** (round 11: `planning/qa` listed 19 against `git ls-files`' 18, the extra being
an untracked file). The table below is unaffected — `lib` has zero untracked — but measure a tree
with `git ls-files --cached --others --exclude-standard` before trusting a count:

| target | files | lines | |
|---|---:|---:|---|
| `lib` | 742 | 161,963 | **over both** |
| `lib/lain/frontend` | 52 | 13,578 | fits |
| `lib/lain/review` | 45 | 10,722 | fits |
| `lib/lain/survey` | 9 | 1,343 | fits |

```
you> /survey ./lib
```

Check **four** things about the refusal, not one:

1. it is a clean `lain:` line, no backtrace, no modal;
2. it names **the measurement, the ceiling and the alternative** — a bare "too large" leaves the
   reader guessing which of three bounds fired;
3. the scope it advises is one `--scope` will actually accept over a **corpus** (§3 is where that
   goes wrong — a remedy naming `commits` here is a finding, because §3 shows a corpus refuses it);
4. **it refuses on the file count without walking the tree.** Time it. The decision is meant to be
   reached on a count alone; a multi-second refusal means something read hunks it had already
   decided not to present.

Then `--unbounded` over the same tree. It lifts two of the three ceilings. Whether 742 files at
162k lines is *usable* is a separate question from whether it is *permitted* — record the wall
time and what the sidebar does, and file the usability half separately from any correctness half.

**Do not drive `--unbounded` before the plain refusal.** The refusal is the check; lifting it first
spends the only chance to read it firing honestly.

## 3. The scope vocabulary, over a source that has no commits

A corpus is a walk. It has no old side, no base ref and no commits, so `commits` is a grouping it
structurally cannot answer — and the refusal for *inapplicable* is a different sentence from the
refusal for *misspelled*:

```
you> /survey ./lib/lain/survey --scope commits
you> /survey ./lib/lain/survey --scope commmits
you> /survey ./lib/lain/survey --scope by_directory
```

- **`commits`** → `scope :commits is not available for the corpus source -- it does not answer what
  that grouping reads.` and then **the scopes this source does present**, measured rather than
  listed: the sentence must not advertise a second grouping it would also refuse.
- **`commmits`** → the unknown-scope sentence, listing the **whole** registry.
- **`by_directory`** → opens, grouped by directory. Confirm the grouping is visible in the sidebar,
  not merely accepted. Round 11: it renders as `~927 lines  <dir>` group headers with the files
  nested under each — and the group header and the file rows use DIFFERENT path bases (F68), which
  is a finding rather than a reading error.

## 4. What the walk admits, and what it keeps out

**Never driven, anywhere.** `secret-boundary.md` drives the gate, the listing filter and the content
mask over `read_file`/`grep`/`list_files`. None of them is this: a survey **reads every file it
lists**, so admission is decided once, up front, in `Survey::Walk` — and the routing is **two-way,
not three**.

The rule that a driver will get wrong: **a gated file is LISTED, not withheld.** Only a *denied*
path is withheld. Withholding a gated file would make `/survey` stricter than the read path over the
same file, which projects it to its released regions instead of hiding it.

Plant a tree — outside the project, fresh per round:

```bash
T="$(mktemp -d)/tree"; mkdir -p "$T"
printf 'ok\n' > "$T/plain.rb"
# The BODY must clear BOTH detector gates or this check passes for the WRONG REASON.
# `Sensitivity::Regions` needs BASE64_LENGTH >= 24 AND BASE64_ENTROPY >= 4.2 bits/char.
# Round 11 measured the old fixture (`MIIEowIBAAKCAQEA0000`) at 20 chars / 3.184 bits --
# under both -- so `Projection` masked only the BEGIN line and left the "key" in the clear,
# while `<redacted:1>` still appeared and a driver grepping for it ticked the box.
{ echo '-----BEGIN RSA PRIVATE KEY-----'
  for i in 1 2 3 4; do echo 'MIIEowIBAAKCAQEA0oPnQKvKz9dLmXqRtYuWvBnCxZaSdFgHjKlPoIuYtRe12345'; done
  echo '-----END RSA PRIVATE KEY-----'; } > "$T/deploy.pem"
printf 'x\0y\n' > "$T/blob.bin"
ln -s "$HOME/.ssh/id_rsa"      "$T/notes.txt"      # denied by its TARGET's name
ln -s /etc/hostname            "$T/elsewhere.conf" # resolves out of the surveyed tree
ln -s /nonexistent             "$T/broken"
git -C "$T" init -q && git -C "$T" add -A          # the walk lists through `git ls-files`
```

`/survey <abs path to $T>`, then read the banner's **disclosure block**. Expected:

| path | expected | why |
|---|---|---|
| `plain.rb` | listed | ordinary |
| `deploy.pem` | **listed**, content rendered `<redacted:1>` | gated, not denied — masked by `Projection` on region detection, not by the path verdict |
| `blob.bin` | withheld, `binary content` | a NUL in the first 8192 bytes |
| `notes.txt` | withheld, **without naming what it is** (`a protected path`) | a symlink is two names for one file; denial is tested **before** containment, so this must not be disclosed as a scope note. Round 11: naming it as a key would itself disclose what the denial hides — the assertion is that it is NOT disclosed as `outside` |
| `elsewhere.conf` | withheld, `outside` | resolves out of the tree the human pointed at |
| `broken` | absent, silently | a broken link is skipped, exactly as a file that vanished mid-walk is |

Then the disclosure's own rule, both directions:

- with something withheld: `withheld N paths, not surveyed:` and each path **indented**, one per
  line. A listing short by one with no word about why is the silent narrowing the whole secret
  boundary is written against.
- over `$T` with the planted files removed: **nothing at all**. A note on every ordinary survey is
  the noise the requirement was written against.

**The projection guarantee above is about the survey ARTIFACT** — the banner's disclosure block just
checked, the corpus digest, the journal, and anything a docent question sends to the model. Confirm
`<redacted:1>` there, not raw bytes, and that is the highest-severity finding this scenario can
produce if it goes wrong.

**Then open `deploy.pem`'s row anyway, and expect the raw key.** A corpus has no old side, so a
survey's row always opens on the diff's `new` slot — the buffer that opens is a REAL file buffer
read straight from disk (`review_diff.new_side`, `47_diff.lua:184-191`) — not a rendering this
survey produced. (This is specific to a survey's `new` slot, not "the note rail" in general: a
changeset review's note rail can also mark `old`, a `nofile` git-show buffer, not the file on
disk.) Seeing the raw key there is
**correct, not a leak**: `/survey` opens the raw file on purpose (round-11 ruling) because a survey
is a survey of project *state* and the human is opening their own file in their own editor
(`projection.rb:79-80`). **Do not re-file this as a leak** — it is only a finding if the *artifact*
checked in the paragraph above carries the raw key, not if the opened buffer does.

## 5. One review surface per chat

**DRIVE THIS BEFORE ANY SURVEY IS OPENED IN THE CHAT.** Round 11 (F67): a chat that has surveyed can
never open a changeset review again — not even after the survey is SETTLED by a verdict — and there
is no release command, so the first leg below is unreachable in a chat that has already surveyed.
The only exit is a fresh chat.

A chat holds one outbox and one set of gesture rails. The guard asks about the **kind**, not merely
`open?`:

```
you> /review <a local branch>
you> /survey ./lib/lain/survey     -- must REFUSE, naming the branch already open
you> /review-submit                -- over the survey, once one is open
```

- **survey over a changeset review** → refuses, **naming the target already open**, and points at
  `lain survey <path>` for a text rendering outside the chat.
- **survey over a survey** → **rebinds**, does not refuse. That is how a human takes a second look
  at a tree, and it is `/review`'s documented behaviour for its own second call.
- **after any refusal, `/review` still works.** Nothing may be left held: the round is taken only
  after the draw returns, precisely so a ceiling raised mid-present does not lock the cockpit out
  for the rest of the session. Drive §2's ceiling refusal and then `/review` to prove it.
- **`/review-submit` over a survey** → `Outbox::Nowhere`'s sentence: a perfectly good review with
  nowhere to post. **Known and already filed as F56** — it names the survey and then reasons about
  *a branch*, the local-branch wording reused unchanged. Re-check, do not re-file.

## 6. `--permissive`, and what it does not buy

`/survey ./lib/lain/survey --permissive`. The flag resolves to `Policy::BlockersOnly`, **not**
`Permissive` — the partial-verdict refusal offers a way past unread **rows**, and an unanswered
blocker is not an unread row, it is somebody who read the work and said no.

So: with `--permissive`, `:LainReviewVerdict approve` over an unread changeset **lands**; over an
unanswered `blocker` it **still refuses**. Drive both legs. One leg alone cannot tell
`BlockersOnly` from `Permissive`, and shipping the wrong one is what the flag's own history is
about.

## 7. The thread pane — the model half *(local model; owed since round 7)*

Drive this on the **local** arm — `qwen3-coder:30b` through the `/mnt/nvme` ollama, launched with
the same `--num-ctx` `/api/ps` already reports. Every question here is a subagent spawn, and the
local arm makes that free, which is the whole reason the section sits where it does: the debt is
four rounds old and a metered arm is a second reason to defer it again.

Open a row, place a note (`<leader>Ln`), **hand it back with `<leader>LN` (`:LainNoteDone`)**, then
`<leader>Lt` on the anchored line. Type a question below the conversation and `:w`.

**The hand-back is load-bearing and was missing from this document until round 11 (F66).**
`:LainNote` draws a marker locally and NOTHING reaches Ruby — no journal record, no thread anchor —
so `:LainThread` answers `lain: no thread on this line` while the marker sits visibly on that line.
The anchor appears only after `:LainNoteDone`. Verify rather than assume:

```bash
$QA/nv.sh expr "string(get(b:,'lain_thread_anchors','<unset>'))"   # <unset> => the thread will refuse
```

1. **the answer renders in the thread pane**, not in the chat, and the chat's own turn loop is not
   stalled while it computes — an answer is a provider round trip handed to the reactor, and a
   docent computed inline would freeze `:LainReply` and every review gesture for seconds. Press a
   gesture *while the answer is outstanding* and confirm it still lands.
2. **a second `:w` with nothing new typed refuses in words.** The guard is keyed on `(anchor id,
   question text)` and holds while the first answer is outstanding. A duplicate here is a duplicate
   subagent, a duplicate provider call, real money and two answers in one pane.
3. **text typed after the answer still sends.**
4. **the exchange lands in the chat's own journal** and replays with it.
5. **the answerer names itself on the record** — the journalled role is what the answerer reports,
   never the `ROLE` constant. Journaling the constant made two genuinely different arms produce
   byte-identical records; an arm that cannot name itself must record as `anonymous_arm`.

**F31 is FIXED as of round 11** — the first re-drive since it was filed. The second `:w` refuses in
words (`lain: nothing has been typed under the conversation, so there is no question to ask -- write
it below the last message and :w again`), `:w` returns in **0s**, `nvim_get_mode()` does not block,
there is no `stack traceback:`, and the journal is unchanged. Round 7's shape was `error()` out of
the `BufWriteCmd`: traceback, `Press ENTER` modal, and two `nvim --server` calls timing out at 120s.
Re-check it here rather than assuming; if the RPC goes dark again that is the finding, and do not
spend the round debugging the harness.

**Expect trouble at 3 instead, and it is F64.** If the local model PARKS A CLARIFYING QUESTION rather
than answering — which `qwen3-coder:30b` did on the second question of a thread — the pane stalls at
`(thinking -- the answer will replace this line)` forever, `docent_answered` never lands, and three
surfaces disagree: `lain://inbox` renders the question and offers `:LainReply`, the HUD reads
`fleet 1`, and `:LainReply` itself refuses saying the inbox line is stale. Typing a NEW question into
the thread still works, so the damage is one orphaned exchange — but the orphan is permanent and
replays with the conversation. Check for it before reading a stall as a hang:

```bash
ruby -rjson -e 'File.foreach(ARGV[0]){|l| r=(JSON.parse(l) rescue next)
  next unless r["type"]=="message" && r.dig("payload","asked_by")
  puts "PARKED by #{r["payload"]["asked_by"]}: #{r["payload"]["question"].to_s[0,120]}"}' "$LAIN_QA_JOURNAL"

**Also expect the model-facing tool path to refuse.** `tools/request_review.rb` still builds a
`Handover` with no `docent:` and answers `Handover::Unattended::NO_DOCENT`. Deliberate, documented,
1 of 3 construction sites — not a new finding.

## 8. Why this runs on the local arm, and what that costs

**Deliberate: every model call in this scenario is local.** §7 is four rounds overdue, and the one
thing that would defer it a fifth time is a section that spends quota. `qwen3-coder:30b` on the
bench answers a docent question as well as this scenario needs — the checks in §7 are about
*where the answer renders, whether a duplicate is refused, and what the record says about who
answered*, and not one of them reads the answer's quality.

Two things the local arm makes you responsible for, both recorded in
[`bench.md`](../bench.md) and neither a finding:

- **Residency.** A cold runner adds ~27s of silence, and a `--num-ctx` that differs from what
  `/api/ps` reports forces a reload. Check `/api/ps` before §7 and launch with the same number, or
  a slow first answer reads like a stalled reactor.
- **The local arm is not reproducible.** It has an open temperature-0 defect, so two identical
  docent questions can answer differently. §7 asserts on the *refusal* of a duplicate, never on two
  answers matching — an assertion that compared answer text would be measuring the server.

**The metered questions are somebody else's scenario.** Admission width, the response WAL, the
published window and the 429 headers belong to [`ollama-cloud-arm.md`](ollama-cloud-arm.md), which
owns them for every command rather than for this one. Running §7 a second time under `--provider
ollama-cloud` is a reasonable thing to do once §1–§7 are green **and** is not part of this
scenario's cost line: nothing above changes, because the encoder, decoder and wire format are
byte-identical between the arms by construction.

## What wrong looks like

| symptom | where it actually is |
|---|---|
| `/survey ./lib` takes seconds to refuse | the decision read hunks it had already decided not to present — the file count is meant to settle it alone |
| the ceiling's remedy advises `--scope commits` | `cumulative_advice` is composing from the registry rather than from what this *source* supports; §3 refuses the very scope §2 recommended |
| a `.pem` is withheld rather than listed-and-masked | the walk is routing gated as denied — three-way where the contract is two-way, and stricter than `read_file` over the same file |
| a symlink to `~/.ssh/id_rsa` is disclosed as `outside` | containment was tested before denial; the disclosure names the scope instead of the secret |
| the disclosure block is absent on a tree with a binary in it | withholding without saying so is the silent narrowing, and it looks exactly like a short tree |
| `/review` refuses after a survey hit a ceiling | a round was held before the draw returned; the cockpit is locked out over a survey nobody saw |
| a refusal arrives with `stack traceback:` | §4's delivery rule in `cockpit-surfaces.md`, one rail over — always a finding regardless of how good the sentence is |
