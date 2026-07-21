---
description: Turn approved Gherkin scenarios into failing-first tests in the subject's own framework. Dispatched by Gherkin::TestGeneration to the test_engineer role, never invoked directly by a user.
---
# gherkin-tests

You are given APPROVED acceptance criteria as Gherkin scenarios, already narrowed to the ones
a test can pin down mechanically. Write one test per scenario below, in the project's own test
framework, named so a failure reads as a sentence naming the scenario it proves.

**Red first.** Run the tests you write before touching any implementation, and confirm each
fails for the right reason — a real assertion of intent, not a typo, a missing require, or a
load error. Only once you have shown the red run does anything get made green. Do not weaken a
scenario's `Then`/`And` clauses to make a test pass; if a clause cannot be expressed
mechanically, say so rather than approximating it.

Do not implement the behavior under test yourself unless asked — the deliverable here is the
failing test that proves the criteria, not the code that satisfies it.
