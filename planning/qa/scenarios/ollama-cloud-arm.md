# Scenario: somebody else's ollama

**What it exercises:** `--provider ollama-cloud` — the hosted ollama arm added 2026-08-24. The
encoder, decoder and wire format are **byte-identical** to the local arm (pinned by
`spec/lain/provider/ollama_parity_spec.rb` and re-checked by hand at merge), so everything this
scenario can find lives in the four things that stop being true when the server stops being ours:
**auth on the wire, a published window instead of a guess, an admission gate against a metered
plan, and a response WAL for a round trip somebody paid for.**

**Cost:** spends real quota against a subscription. Budget **under ten completions** for the whole
scenario; every step below says whether it costs one. Steps 1–4 cost **nothing** and are where the
launch-level refusals live — run them even if you are not paying today.

**Needs:** `OLLAMA_API_KEY` exported (create one at `ollama.com/settings/keys`). `LAIN_OLLAMA_CLOUD=1`
only for the opt-in spec tier, **not** for the cockpit steps. Note that exporting
`LAIN_OLLAMA_CLOUD=1` moves the suite's pending count from 15 to 16 — `network_posture_spec` skips
its own offline-default guard once you have opted in, which is correct and reads as a discrepancy
if you do not expect it.

**Do not run this to answer "does the cloud work".** Run it to answer: *does the arm refuse
correctly before it spends anything, does it denominate honestly, and is a paid round trip
recoverable after a crash?*

---

## 1. The refusals, before a single token is spent

```bash
env -u OLLAMA_API_KEY LAIN_PREFLIGHT=1 lain chat --provider ollama-cloud
LAIN_PREFLIGHT=1 lain chat --provider ollama-cloud --api-base http://ollama.example
LAIN_PREFLIGHT=1 lain chat --provider ollama --summarizer-provider ollama-cloud --api-base http://127.0.0.1:11434
```

The first two refuse **at construction, before the chronicle opens**, in one clean line with no
backtrace. Read the messages, do not just check the exit code — the whole point is that they are
actionable at 3am:

- the missing-key refusal names `OLLAMA_API_KEY`, **where to get one**, **which flag asked for it**,
  and the tmux-environment hint (a key exported in your shell is not in the environment a tmux
  server started elsewhere hands its panes — this is the modal `lain up` failure);
- the plaintext refusal says *why* https is required, in the arm's own terms: a subscription key
  sent in plaintext is an exfiltrated key;
- **the third does not refuse at all — it constructs.** A non-chat tier resolves its OWN
  deployment's base (`https://ollama.com` for the cloud arm) rather than inheriting `--api-base`
  (`ollama_tier.rb:238`), so the plaintext `http://127.0.0.1:11434` named there belongs to the
  *chat* arm (plain `ollama`) and never reaches the cloud summarizer. §2 drives this same property
  deliberately. An earlier version of this document expected a flag-naming refusal here; that
  prediction does not hold against the code.

**False pass to watch for:** `LAIN_PREFLIGHT=1` exiting 0 while a real run would refuse. Preflight
must refuse a **subset** of what chat refuses, never less — that gap is what makes `lain up` open a
pane that dies.

## 2. The key never reaches a host it did not choose

```bash
LAIN_PREFLIGHT=1 lain chat --provider ollama --api-base http://gpu.internal:11434 --summarizer-provider ollama-cloud
```

Constructs. The interesting part is where the bearer went: the cloud summarizer must resolve
`https://ollama.com`, **not** `gpu.internal`. `--api-base` there names the *local* arm the operator
is chatting with, and an arm that inherits it ships the subscription key to a third-party host.

Conversely `--provider anthropic --api-base https://proxy.example --summarizer-provider ollama-cloud`
**should** send the key to `proxy.example` — that is the only ollama-shaped arm in the command, so
the base can only have meant it, and a proxy in front of `ollama.com` is a real deployment.

## 3. The window is published, not guessed

```bash
lain chat --provider ollama-cloud     # then read the status line
```

The cloud default model resolves **128,000 tokens, `published`, authoritative** — not the
`CONSERVATIVE_FALLBACK` of 8,192 tagged `guessed`. Confirm by eye in the status line.

This is worth a manual look because a `guessed` denominator does two things at once, and neither is
loud: it under-reports occupancy by ~16x, **and** it makes `Compaction::Source` decline
`:approaching_window` entirely, so window-pressure compaction silently stops existing.

**Known asymmetry, not a bug to report:** pass `--num-ctx` and the resolution drops back to
`guessed` regardless of the table, because `narrowest` returns nil only when *both* ceilings are
absent. Also: the cloud arm performs **no `--num-ctx` refusal at all**, because
the hosted `Deployment#model_metadata?` is `false`. Both are recorded follow-ups.

## 4. Windows come from the weights, not the library page

If you are adding or refreshing a row in `ContextWindow::CLOUD_WINDOWS`, the published label is
evidence and `/api/show`'s `context_length` is the **bound**. Three rows shipped over-claiming
against their trained maxima — one by **3.8x** — because a library page said "1M" and the weights
said 262,144. Enumerate `CLOUD_WINDOWS.keys`; do **not** sample one tag per model family, because
dated and `preview` tags are genuinely different builds. That assumption is exactly what hid the
third row.

**A row can also go stale the other way: the tag is retired.** Round 17 found two (`deepseek-v4-flash:preview-cloud`
and `deepseek-v4-pro:preview-cloud`) whose `/api/show` answers "was retired at …" (F126), and removed them on
2026-09-14. **Round 20 found five more** (I-1): `glm-5.1:cloud`, `qwen3.5:cloud`, `qwen3.5:397b-cloud`,
`deepseek-v4-flash:cloud` and `deepseek-v4-flash:0731-cloud` still claimed a `published` window. They are
gone, so:

- **Do not trust a row count written in this document.** It said **21** until round 20 counted **24** in
  the table. Read it: `/ruby Lain::ContextWindow::CLOUD_WINDOWS.size` (19 on 2026-09-30) and enumerate
  `.keys`. A stale count here is a scenario defect.
- **Every shipped key must be live.** With `LAIN_OLLAMA_CLOUD=1` and `OLLAMA_API_KEY`, send each key to
  `/api/show` (the opt-in `spec/integration/provider/ollama_cloud_spec.rb` tier does exactly this); **none
  may answer 410**. A 410 for a key in the table is I-1 back, and the check is the enumeration, not one
  sampled tag per family.
- **A retired tag is not a published window.** `ContextWindow` resolving `glm-5.1:cloud` reads
  `guessed`, not `198,000 published`, and `serves?` answers not served.
- **A 410 is a retirement, not a generic error.** Send a chat to a retired tag (or point the arm at a
  stub answering 410 with `glm-5.1 was retired at 2026-09-25`): the error reads `Model retired: <the
  host's message>`, is **not retried** (no 4 empty aborted frames as in §5's 500 case), and the session is
  not left half-written. A 410 that is retried 4 times or shown as a bare HTTP error is the regression.

§3's 128,000-token published window was confirmed by round 17.

**And the wire, since the same round-20 forks read it:** the captured request body carries
`options={"num_predict"=>4096,"num_batch"=>2048}` and `truncate=false` (a `--max-tokens 40` chat stopped at 40 on
ollama.com), and `--max-tokens 0` refuses at construction. A body without `num_predict` is the round-19 defect
(no generation cap on the ollama wire) back.

**A prose tool call, or a stop on `max_tokens` before any text, is shown as an error** (round 20's A-2 and
I-2: on the main-chat path a model that wrote `<function=write_file>...` as prose, or hit `max_tokens`
before saying anything, was shown as an ordinary answer or as nothing). Drive `--max-tokens 40` on a prompt
that needs more: the pane must read `error: model hit max_tokens before finishing`, and with some text
first the text prints and then the same error line. **Catches A-2 returning:** an empty answer with no error
line. A `<function=` reply reads `error: ` plus the malformed reason, never the raw envelope as the answer
(`malformed_response kind=prose_tool_call` is journaled), and a `--non-interactive` ask ends unfinished.

## 5. One real turn, and the WAL behind it *(costs ~2 completions)*

```bash
lain chat --provider ollama-cloud
```

Ask for something that calls a tool. Confirm the turn completes and the tool is called. Then, with
the session's journal path in hand, look at its WAL: a completed round trip must leave **one frame
marked complete carrying the response bytes** — not an empty frame, and not one never terminated.

An empty-but-complete frame is the failure mode this arm's WAL was built to prevent, and it is
invisible to a frame **count**. Read the bytes.

**Expected and normal:** a *failed* round trip leaves one empty aborted frame per attempt — four
for a retried 500. That is the retry envelope working, not corruption.

## 6. Saturation and the 429 *(costs real quota — skip unless you are testing this specifically)*

The plan's grounding took "1 / 3 / 10 concurrent models" from the pricing page. **The wire says
otherwise:** a 429 carries `x-ratelimit-max-concurrent: 4` and `x-ratelimit-queue-limit: 15`, plus
`retry-after` in integer seconds — and **no reset header**, which is why lain leaves
`rate_limit_reset_header` nil and lets faraday-retry honour `Retry-After` on its own.

The hosted `Deployment` declares an admission width of **1** by default, raised by
`LAIN_OLLAMA_CLOUD_CONCURRENCY`. That is deliberately below the plan's real capacity: safe on every
tier, and a caller who knows better can say so.

## 7. What this arm is NOT for

**Neither ollama arm is a determinism-comparable bench arm on this machine.** The cloud arm gives
three distinct completions from three warm same-seed runs at temperature 0 — measured, expected,
no cause established (`references/ollama/cloud.md`). The **local** arm currently fails the same
check, which is an open defect measured on both sides of the ollama-cloud chunk and named in
`docs/toolchain-traps.md`.

So: use this arm to sweep the **provider axis**, where it is the cleanest cut available — the wire
is held byte-identical and only hosted-ness and model class move. Do **not** draw a variance or
reproducibility conclusion from it without re-establishing determinism first. A `bench variance`
number taken from either arm today is measuring the server, not the change.
