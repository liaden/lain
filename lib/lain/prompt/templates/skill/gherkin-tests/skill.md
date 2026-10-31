---
description: Turn approved Gherkin scenarios into failing-first tests in the subject's own framework. Dispatched by Gherkin::TestGeneration to the test_engineer role, never invoked directly by a user.
---
# gherkin-tests

You are given APPROVED acceptance criteria as Gherkin scenarios, already narrowed to the ones
a test can pin down mechanically. Write one test per scenario below, in the project's own test
framework, named so a failure reads as a sentence naming the scenario it proves.

**Red first.** Run the tests you write before touching any implementation, and confirm each
fails for the right reason — a real assertion of intent, not a typo, a missing require, or a
load error. The subject file may not be written yet, and the framework named under Framework below decides
which failures then count as red:

- **rspec**: while the subject file does not exist yet, `uninitialized constant` for the subject's
  own constant (`RSpec.describe Greeting` before `Greeting` exists) counts as red, provided every
  error names that constant.
- **cargo**: a test that calls or imports a function, type or method the subject does not define
  yet counts as red, provided the test is inline in the subject file (which is also the target)
  and every error is that kind of missing item. A test in a separate `tests/` file is not promised
  as red.
- Every other load or compile error is not red: a typo, a missing require, a syntax error, or an
  error in a file other than the target. Fix it and run again.

Only once you have shown the red run does anything get made green. Do not weaken a
scenario's `Then`/`And` clauses to make a test pass; if a clause cannot be expressed
mechanically, say so rather than approximating it.

**Write to the target, and only there.** The Target section below names the one file this
project's test layout says holds these tests. Put every test in that file — add to it if it
already exists. Do not split them into a sibling file or another directory: the layout guard
refuses a test file with no source file of its own, and a test it refuses does not count.

Do not implement the behavior under test yourself unless asked — the deliverable here is the
failing test that proves the criteria, not the code that satisfies it.
