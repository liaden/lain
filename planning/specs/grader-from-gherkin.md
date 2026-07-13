# Spec — Grader from Gherkin

> Status: `[exp]`, specced. Feeds `Grader::Fixture` (3c-5.3) and `Grader::Rubric` (3c-5.4), and the
> M5 test-engineer role. Companion to `ROADMAP.md` (M3c + M5). Unit IDs `GG-<n>`.

## What it is (corrected from the first framing)

Gherkin is **not** the grader and Lain does **not** run a Cucumber engine. Gherkin is a **transient,
human-approved, structured-English intermediate representation** that sits between requirements and
tests. It does two jobs:

1. **A planning sign-off artifact.** During `/research` + `/plan`, the human specifies requirements
   collaboratively and one of the artifacts is the Given/When/Then acceptance criteria, which the
   human **approves** before implementation. It is a gate, not a file format.
2. **A better prompt-scaffold for test generation.** Structured English (Given/When/Then) produces
   markedly better tests than freeform prompting (the user's empirical finding). The approved Gherkin
   is the scaffold from which the **actual tests are generated in the user's real framework** —
   rspec, minitest, pytest, jest, Capybara, whatever the project uses.

**The generated tests are the grader.** `Grader::Fixture` wraps the project's own test-harness run
(pass/fail). So "grader from Gherkin" is the pipeline: **requirements → (research/plan) →
human-approved Gherkin → framework-native tests → the project's test run as the deterministic
fixture.** Criteria that genuinely can't be mechanized fall back to `Grader::Rubric`.

There are **no literal `.feature` files** and no Cucumber runner: the Gherkin is transient scaffolding;
the durable artifact is the generated test in the project's suite (it *is* the user's TDD).

## Execution model — the user's framework, not ours

The acceptance criteria describe what the *user* is accomplishing with Lain in *their* TDD, so
execution binds to *their* test harness. Lain generates tests in the detected framework and runs them
via a **project test-adapter** (the same detect-and-drive posture as the `run`/`verify` skills);
`Grader::Fixture` maps the harness's pass/fail to a score. The framework is pluggable — Ruby/minitest
or rspec, JS/jest, Python/pytest, a Capybara feature test, etc.

## Units

- **GG-1 — Gherkin as a `/plan` sign-off artifact.** `/research` + `/plan` emit Given/When/Then
  acceptance criteria as a reviewable artifact; the human approves before implementation; approval is
  content-addressed. *Ties to:* plan-iteration / `COMMENT` slots. **Acceptance:** a plan run produces
  criteria the human signs off on; the approval + Gherkin digest are recorded.
- **GG-2 — Test generation from approved Gherkin (test-engineer role).** The M5 test-engineer turns
  approved Gherkin into runnable tests in the detected framework; a scenario with no mechanical form is
  flagged for Rubric instead. *Needs:* M5 role catalog, framework detection. **Acceptance:** given
  approved Gherkin + a framework, runnable tests are emitted; non-mechanical scenarios are flagged.
- **GG-3 — `Grader::Fixture` over the project test harness.** A pluggable test-adapter runs the target
  framework; pass/fail maps to the grader. *Builds on:* 3c-5.3, the tier-3/exec path. **Acceptance:**
  `Grader::Fixture` runs the generated suite over a `DryReplay`/`LiveReplay` output and scores
  deterministically; swapping rspec→pytest changes only the adapter.
- **GG-4 — Rubric fallback for fuzzy clauses.** Criteria that can't become a mechanical test route to
  `Grader::Rubric` (3c-5.4). **Acceptance:** a non-mechanical Then produces a rubric criterion with
  `#why`; the mechanical/fuzzy split is recorded.
- **GG-5 — Attestation.** The approved Gherkin, the generated tests, and the framework are
  content-addressed into the run, so grading is replayable and traceable to signed-off criteria.
  **Acceptance:** a run records which Gherkin digest it was graded against; dry-replay grades against
  the same snapshot.

## Audience

Primarily the **lain user**: it grades *their* TDD in *their* framework. But **Lain dogfoods** — the
lain dev grades Lain's own rspec suite through the same pipeline, so the machinery is validated on the
harness itself. "The project" here always means the lain user's project (which, when dogfooding, *is*
Lain).

## Relationship to other work

- **M5 test-engineer role** — GG-2 is that role's core output; this is the mechanism behind "the
  test-engineer produces graders."
- **`/research` + `/plan`** — GG-1 is a gate in that flow; the human-approval step connects to
  plan-iteration and the `COMMENT` annotation slots.
- **Project test-adapter** — shares the framework detect-and-drive machinery with the `run`/`verify`
  skills.
- **The experiment DSL is parked**, so Gherkin scenarios are planning artifacts, not inline DSL blocks.

## Open questions

- **Framework detection vs. explicit config** — how Lain knows it's pytest vs jest (probe files, or a
  project config). Likely reuse the `run`/`verify` detection.
- **Durable vs. transient** — the *Gherkin* is transient scaffolding; the *generated tests* land in the
  project's real suite (durable, they're the user's TDD). Confirm the boundary per project.
- **Autonomous runs** — how the GG-1 human-approval gate behaves when the loop runs unattended (a
  standing approval? a deferred sign-off queue?).
