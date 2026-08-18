# Scenario: bowling scoring (Ruby)

**The default subject.** Small enough to finish; genuinely non-trivial. Strikes and spares look
ahead one and two rolls, the tenth frame breaks its own rule, and a perfect game is 300 rather
than 30 × 10.

**What it exercises:** the whole authoring loop — context assembly, tool dispatch, the approval
gate, skill dispatch (`/create-plan`, `/execute-plan`, `/critique`), the summarizer tiers, and
whether the artifact at the end is worth having.

**Cost:** one to three sessions (see the session ceiling in `method.md`).

**Needs:** `bench.md` up. A git-initialised project directory seeded with at least one file under
`lib/` and one under `spec/` — an empty tree makes the model spend turns on redundant listings.

---

## The contract, and the grading instrument

**Definition of done: five oracles pass, under a spec file the DRIVER owns** — never the model's
own. That file is `planning/qa/oracles/bowling.rb`:

```bash
ruby planning/qa/oracles/bowling.rb <path-to-bowling.rb>   # exit 0 on 5/5
```

**It grades `Bowling.score(rolls_array)`** — a module function taking the whole roll array. Prompt
for exactly that. (Round 4 prompted for `Bowling::Game#roll/#score` from a stale prose description
and got `0/5` with five identical `NoMethodError`s, which reads like a model failure and is not
one.) A `Game` class underneath is fine and typical; the module function is what is graded.

Do not re-derive the oracles, and do not let the model near the file.

| game | score |
|---|---|
| all gutters | 0 |
| perfect (12 strikes) | 300 |
| all spares, 5 first ball | 150 |
| `1,4 4,5 6,4 5,5 10 0,1 7,3 6,4 10 2,8,6` | **133** |
| nine open frames then `10,10,10` in the tenth | **30** for the tenth, not 60 |

**Oracles 1–3 are not sufficient and must not be used alone**, and there are now two independent
demonstrations of why:

- A scorer that adds the next-two-rolls bonus to *every* frame — open frames included — scores 0,
  300 and 150 correctly and is wrong on every game containing an open frame.
- **Oracle 3 is degenerate for spare bonuses.** "All spares, 5 first ball" makes every roll a 5, so
  `rolls[frame+1]` and `rolls[frame+2]` are the same number and a spare-bonus off-by-one is
  invisible to it. Round 4's model shipped exactly that bug (`next_roll` returning the frame's own
  second roll) and passed oracles 1, 2, 3 **and 5**.

**Oracle 4 is the load-bearing one.** A 4/5 result is a real failure, not a rounding error.

## 1 — `/create-plan`

Exercises context assembly, the summarizer tiers and skill dispatch. Be directive; the model loops
on clarifying questions otherwise ("Do NOT ask any clarifying questions — you have everything you
need. Produce the plan document now.").

Watch for: `UndecodableAnswer` from the summarizer; whether the summarizer model stays the chat's
(a fall to a small local model evicts the resident one, ~11×); whether a declared summarizer is
consulted for small tool results.

**Declaring a summarizer has a step that is easy to miss and silently voids this act.** `/meta
summarizer …` writes `.lain/summarizers/<slug>.rb`, and **nothing loads that directory** — the
catalog's only path is the single file `.lain/summarizers.rb`. Skip the copy and the free tier never
fires, and the fix looks unshipped.

**Expect this act to fail on the model, not on lain.** Round 4 watched `qwen3-coder:30b` burn the
entire 25-iteration ceiling here without writing a file. That is a MODEL finding. Hand-write the
plan and continue — the seams the later acts test still need driving.

## 2 — `/execute-plan`, and the wedge

**The act that found the worst defect in round 1.**

- **The wedge needs the right grammar.** `Skill::Invocation` parses `/skill` as *inline* and
  `@role[/skill]` as a *fresh-context spawn*, and **only the second reproduces it.** Type literally
  `@researcher[/critique] <path>`. An inline `/execute-plan` does not exercise this.
  Expect the arrival note, a `human>` prompt, an answer taken, and a return to `you>`.
- A gated tool **inside** a spawn must reach the approval surface, and `/inbox` must still work.
- **Take one ordinary turn BEFORE typing the wedge.** A session whose only activity is a wedge
  journals no `turn` records at all — only `child_turn` — so `lain sessions` shows `0 turns` and
  there is nothing to fork at. Forking a `child_turn` digest refuses cleanly, which makes the next
  step unreachable rather than failing.
- Child turns must be journaled and every `causal_parents` digest must resolve — then **fork the
  session**, which is what proves it. Collect every `digest` and every `causal_parents` entry and
  assert the difference is empty.

**Note for `failure-injection.md`:** `causal_parents` only exist once a spawn has run. A session of
plain turns links via `parent`. Round 4's journals had no `causal_parents` at all.

## 3 — Grade it, then `/critique` it

Run the oracles. Then ask: are the model's own specs meaningful or vacuous? Does the code read like
something a person would keep?

**The plumbing can work perfectly and still produce something not worth having**, and only this step
can tell. Round 4's result was exactly that: every seam worked, and the artifact was wrong.

## Fallback

If the model cannot get there, **the trigger is mechanical** (`method.md`): three consecutive turns
producing neither a spec nor an implementation file, or any single turn over ten minutes. Drop to
FizzBuzz with a spec rather than redesigning mid-run.
