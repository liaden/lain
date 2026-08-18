# Scenario: a small Rust CLI, one-shot

**Why this one exists:** it is the **fast smoke test**, and the only scenario whose subject is not
Ruby. Two things follow from that, and both are the point:

1. **A non-Ruby toolchain proves the tool layer is language-agnostic.** Every other scenario could
   pass while `bash`, `read_file` and `glob` quietly assume a Ruby tree.
2. **`cargo` gives a deterministic, machine-checked unhappy path for free.** A Rust compile error is
   a real failure with a precise message, arriving as a tool result the model must read and act on.
   Bowling has no equivalent — a wrong scorer still runs.

**Cost:** cheap — one session, often under ten turns. **Run this when the question is "does the loop
work end to end", before spending a session on a subject.**

**Needs:** `bench.md` up, and `cargo`:

```bash
cargo --version || echo "SKIP: no cargo"
```

---

## The subject

One directive prompt, no planning skill, no `/create-plan` — that is what "one-shot" means here, and
it deliberately avoids the orchestration scaffolds the local model cannot drive:

> Create a Rust CLI at `src/main.rs` in this crate. It reads lines from stdin and prints, to stdout,
> the N most frequent words with their counts, most frequent first, ties broken alphabetically.
> N comes from `-n <N>`, defaulting to 10. Words are lowercased and split on non-alphanumerics.
> Use only the standard library. Then add `#[test]` functions covering: an empty input, a tie, and
> the `-n` flag.

Seed the crate yourself before the run — `cargo init --name wordfreq` — so the first turn is about
the code, not about scaffolding.

**Definition of done, driver-run:**

```bash
cargo build 2>&1 | tail -5
cargo test  2>&1 | tail -5
printf 'the cat the dog the\n' | ./target/debug/wordfreq -n 2     # -> "the 3" then "cat 1"
```

The oracle is `cargo` itself, which is the nice property of this scenario: there is no grading
instrument to keep in sync with a prose description, and therefore no repeat of round 4's
`QA-DOC-1` API mismatch.

## The unhappy path is the point — drive it deliberately

Do not stop at a green build. **Break it and watch the loop recover:**

```bash
# after the model's code builds, the DRIVER introduces a real compile error
sed -i 's/fn main()/fn main(x: i32)/' src/main.rs
```

Then tell the model the build is broken and let it fix it. What to watch:

- **Does the compile error survive as a usable tool result?** `cargo build` writes errors to
  **stderr**, often with ANSI colour and multi-line spans. Confirm the model receives the diagnostic
  text, not an exit code with an empty body, and that colour codes do not corrupt the transcript.
- **Is a long `cargo` result bounded or disclosed?** A first compile of a fresh crate emits hundreds
  of lines. `bash` has a wall-clock timeout and no size bound.
- **Does the streamed output reach `lain://journal`?** That buffer renders `Telemetry::ToolOutput`
  only, so a `cargo` run is one of the few things that populates it. If it stays empty while
  `[call_… stdout]` lines appear in the chat pane, that is a finding.
- **Does a second gated `bash` in the same turn still get an approval prompt?** `cargo build` then
  `cargo test` in one turn is the exact two-gated-calls shape that wedges.

## Long-running-command behaviour

A cold `cargo build` on a fresh crate is the closest thing in the QA suite to a legitimately slow
tool call. Use it to check the parts of the run loop that only a slow call exercises:

- the stall clock does **not** fire on a healthy-but-slow tool (it arms on stream chunks from the
  *model*, not the tool — confirm that is still true);
- the HUD/prompt does not claim `idle` while the call is in flight;
- Ctrl-C during the call is survivable and the journal still parses afterwards (see
  `failure-injection.md`).

## Why it is a one-shot

The multi-step skills are covered by `bowling-ruby.md` and are the part the local model reliably
fails. Keeping this scenario to a single directive prompt means **a failure here is a lain finding
with very little else in the frame** — which is what makes it a good smoke test.
