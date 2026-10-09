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
`CONSERVATIVE_FALLBACK` of 8,192 tagged `guessed`. **No window shows in the HUD or in `/status`
before the first turn** (round 22), so a status line read at launch proves nothing. Take one turn,
then read it from the journal: `window_tokens` and `provenance` on the turn's records.

This is worth a manual look because a `guessed` denominator does two things at once, and neither is
loud: it under-reports occupancy by ~16x, **and** it makes `Compaction::Source` decline
`:approaching_window` entirely, so window-pressure compaction silently stops existing.

**Known asymmetry, not a bug to report:** pass `--num-ctx` and the resolution drops back to
`guessed` regardless of the table, because `narrowest` returns nil only when *both* ceilings are
absent. Also: the cloud arm performs **no `--num-ctx` refusal at all**, because
the hosted `Deployment#model_metadata?` is `false`: `--num-ctx 999999999` on the cloud arm constructs,
as documented (round 22 drove it). Both are recorded follow-ups.

### 3b. A bare cloud model name finds its published window *(costs 1 completion per arm)*

The 2026-10-08 trial launched `--model glm-5.3` and the journal recorded `"window_tokens":8192,
"provenance":"guessed"`: every cloud row is keyed with a `:cloud` or `-cloud` tag, and the lookup looked for
a table key inside the name the user typed. ollama.com accepts both `glm-5.3` and `glm-5.3:cloud`. A guessed
8,192 window made the HUD read `ctx:~72%` at under 1% of the real use and kept window-pressure compaction off.

```bash
lain chat --provider ollama-cloud --model glm-5.3          # take one turn, then read the journal
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "window=#{r["window_tokens"]} prov=#{r["provenance"].inspect}" if r["type"]=="compaction_decision"}' "$JOURNAL"
```

1. **`glm-5.3` resolves to the `glm-5.3:cloud` row: 1,000,000 tokens, `published`.** Read the row in
   `CLOUD_WINDOWS` rather than trusting this figure, since the table moves.
2. **A size-tagged row is found from its bare name**: `--model gemma4:31b` reads 256,000, `published`.
3. **The longest key wins**: `--model glm-5.3-flash` resolves to the `glm-5.3-flash:cloud` row, not
   the `glm-5.3` one.
4. **A name in no row still guesses**: a made-up name reads `8192`, `guessed`.
5. **The lookup is cloud-arm only.** The same bare names on the local arm (`--provider ollama --model
   gpt-oss:20b`) stay `guessed` unless the resident model reports its own window, because a local tag that
   shares a name with a cloud row would otherwise be told an authoritative window it does not have.
   *Wrong looks like:* `window=8192 prov="guessed"` on the cloud arm with a bare name, or a local model
   reading `published` from a cloud row.
6. **The HUD agrees.** `ctx` is `used / window` with no `~` mark once the window is published (compute it
   from the journal's first turn and read the HUD row). `greenfield-epic.md` §2 drives this on the full
   journey; this step is the same check taken alone.

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

## 6. Width, the launch notice and the 429 *(§6a costs nothing; §6b costs real quota or needs a stub)*

The plan's grounding took "1 / 3 / 10 concurrent models" from the pricing page. **The wire says
otherwise:** a 429 carries `x-ratelimit-max-concurrent: 4` and `x-ratelimit-queue-limit: 15`, plus
`retry-after` in integer seconds, and **no reset header**, which is why lain leaves
`rate_limit_reset_header` nil and lets faraday-retry honour `Retry-After` on its own. Only a 429 carries
the headers, so a session's real plan limit is learned on a refusal.

The hosted `Deployment` declares an admission width of **3** by default (it was 1 until 2026-10-08, when the
trial's serialized subagents showed 1 was below what a paid plan allows), raised or lowered by
`LAIN_OLLAMA_CLOUD_CONCURRENCY`. `LAIN_PROVIDER_CONCURRENCY` overrides it, and `0` there means unbounded.
An earlier version of this section said the default was 1; a driver reading that sentence anywhere else
(the README still does until the docs card lands) has the stale one.

### 6a. The launch says how many requests will run at once

```bash
lain chat --provider ollama-cloud                                   # read the startup lines
LAIN_OLLAMA_CLOUD_CONCURRENCY=1 lain chat --provider ollama-cloud
LAIN_PROVIDER_CONCURRENCY=2 lain chat --provider ollama-cloud
LAIN_PROVIDER_CONCURRENCY=0 lain chat --provider ollama-cloud
lain chat --provider ollama                                         # the local arm
```

1. Default: `ollama-cloud runs up to 3 cloud requests at once; set LAIN_OLLAMA_CLOUD_CONCURRENCY to change
   it. It narrows on a concurrency refusal from the server.`
2. With the cloud variable at 1 the line says `up to 1`. With `LAIN_PROVIDER_CONCURRENCY=2` it says `up to 2` and
   names **that** variable, because that one is in force. With `0` it reads `ollama-cloud runs with no limit on
   cloud requests; LAIN_PROVIDER_CONCURRENCY=0 set that.`
3. The local arm prints no such line, and `OLLAMA_API_KEY`'s value appears in no startup line.
   *Wrong looks like:* a notice naming a width other than the one a fan-out then uses, or the line missing from a cockpit's
   chat pane.

### 6b. A concurrency 429 narrows the endpoint, and the journal says so *(costs real quota, or a stub)*

Two ways to force it, and say which you used:

- **A plan whose limit is below the width.** On a plan with `max-concurrent` of 1 (a Free key), ask for a fan-out
  of 3 subagents. The first refusal names the limit and the endpoint narrows. The reviewer's stub probe saw
  2 of 3 requests fail after their retries on a plan with no server queue, with later requests running at the
  narrowed width; whether a real Free plan has a server queue is **unprobed**, so record what you see.
- **A stub endpoint.** An https server (the arm refuses a plaintext base) that answers the first requests with
  429, the header `x-ratelimit-max-concurrent: 1`, `retry-after: 1`, and a body saying too many concurrent
  requests, then 200. Trust its certificate with `SSL_CERT_FILE`, pass `--api-base https://127.0.0.1:<port>`.
  No such stub is checked in. Copy the response shape from `spec/lain/provider/ollama/retry_tap_spec.rb` (the webmock example near line 355): status 429, body `{"error":"too many concurrent requests"}`, headers `x-ratelimit-max-concurrent: 1` (the spec's refusal helper also sends `x-ratelimit-active`, `x-ratelimit-queue-limit` and `x-ratelimit-queued`), then a 200 with `{}`. The same file's `slow down` and `context length exceeded` bodies, with no concurrency header, are the other-reason 429s of item 5.

Read the journal:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next
  puts r.slice("type","endpoint","from_width","to_width","max_concurrent","active","queue_limit","queued").to_json \
    if %w[admission_narrowed provider_retry].include?(r["type"])}' "$JOURNAL"
```

1. **One `admission_narrowed` record** with `from_width: 3`, `to_width: 1` and the header values as sent
   (`nil` where a header was absent), written once per refusal that moved the width.
2. **The retried request is sent once by faraday-retry**, not twice: the stub's request count for that call
   is the original plus 1 retry, with a `provider_retry` record per retry.
3. **Narrowing never widens.** A later 429 reporting `max-concurrent: 3` leaves the width at 1 and writes no
   second record.
4. **An explicit setting is the ceiling.** With `LAIN_OLLAMA_CLOUD_CONCURRENCY=2` and a server reporting
   3, the width stays 2.
5. **A 429 for another reason is not concurrency.** A 429 whose headers carry no `max-concurrent` (or a
   context-length body) leaves the width alone and raises as before.
6. **`LAIN_PROVIDER_CONCURRENCY=0` ignores it**: a concurrency 429 raises nothing new and admission stays
   unbounded.
7. **After the retries are spent** (5) the request fails with the 429 named, as it did before.
   *Wrong looks like:* a width that stays 3 after a refusal that named 1, a narrowing record on every retry,
   or a width that grows back.

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
