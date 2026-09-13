# Ollama Cloud (`https://ollama.com`) — measured against a live subscription

> ⚠️ **LLM-generated** (Claude, 2026-08-24) — but unlike its siblings in this directory, almost
> nothing here is synthesized from documentation. Every claim below was **measured on the wire**
> against a real paid Ollama Cloud subscription on **2026-08-24**, with the method and the request
> count stated. Where a claim is an inference from those measurements rather than a thing directly
> observed, it is marked **inferred**. Where a question was asked and the answer was *no*, the
> negative is written down as a result.

Method, in full, so a reader can judge the evidence and re-derive it:

- Host `https://ollama.com`, native endpoints (`/api/show`, `/api/chat`) — **not** the `/v1/...`
  OpenAI-compat surface, which is a different wire (`references/ollama/openai-compat.md`).
- Auth `Authorization: Bearer <key>` from `OLLAMA_API_KEY`.
- Two rounds. **2026-08-24, round 1** (recorded in the chunk's Execution log as Decision 6): two
  requests, `gpt-oss:20b-cloud`, 74 prompt + 8 eval tokens. **2026-08-24, round 2** (T12, this
  document): a seventeen-model `/api/show` sweep, a 401 probe, three concurrency bursts, a
  four-run determinism probe, and the live spec — roughly 90 requests, of which most performed no
  inference and the rest were capped at one to sixty output tokens. **2026-08-24, round 3**
  (review): the six `CLOUD_WINDOWS` rows round 2 did not probe, at zero inference cost — see
  "COVERAGE" below, and read every "seventeen" in this document as *round 2's* scope, not the
  table's.
- The live spec is `spec/integration/provider/ollama_cloud_spec.rb`, tagged `:ollama_cloud`,
  excluded by default, needing `LAIN_OLLAMA_CLOUD=1` **and** a key. It is opt-in and does not run
  in CI, which is why **this document, not that spec, is the record.**

---

## The three questions this chunk refused to assume

| # | Question | Answer |
|---|---|---|
| 1 | Does `/api/show` answer on the cloud host, and is its `context_length` the **served** window or a **trained maximum**? | **It answers (HTTP 200) on all 23 shipped cloud models — 17 probed by T12, the remaining 6 by review. The figure is a TRAINED MAXIMUM.** It must never become a denominator. |
| 2 | Does the native cloud path return rate-limit headers, under what names? | **Not on a 200. On a 429, YES — five of them**, and the vocabulary is *concurrency*-shaped, not token-bucket-shaped. |
| 3 | Is there any signal that input was prompt-cached? | **No.** Nothing cache-shaped exists on this wire, which settles the capability question regardless of what the backend does. |

---

## 1. `/api/show` — it answers, and it is the trained maximum

`POST https://ollama.com/api/show` with `{"model": "<name>"}` returns **HTTP 200** in ~0.1–0.3s.
This was the first of the three unknowns and the plan was right to refuse to assume it: an
endpoint whose whole meaning on a local server is "ask the daemon about a model file" had no
obvious reason to exist on a serverless host.

### The response is NARROWER than a local `/api/show`

Top-level keys, identical across all seventeen models measured:

```
capabilities   details   model_info   modified_at
```

A local server additionally returns `license`, `modelfile`, `parameters`, `template` and
`system`. **The cloud host returns none of those.** Anything reading them off a cloud response
gets `nil`, not an error.

`details.parameter_size` is also shaped differently: a raw digit string
(`"397000000000"`) where a local server writes a human label (`"397B"`). **Inferred**: the cloud
catalogue renders this field from a different source than the GGUF's own `general.parameter_count`
formatting path. Do not parse it as a label.

### The sweep — 2026-08-24

**COVERAGE, stated before the numbers, because an unstated scope is what turns "two rows are
wrong" into "the rest are fine".** `Lain::ContextWindow::CLOUD_WINDOWS` had **23 rows**. The T12
sweep below probed **17 of them**. The remaining **six were not probed by T12** and were swept
separately by review on the same day, at zero inference cost — that pass found a **third**
over-claiming row (below). So the table is now measured end to end, but it took two passes, and
this document would have implied otherwise had it not said which pass covered what.

The six T12 did **not** probe, all later covered by review:

`deepseek-v4-flash:0731-cloud` · `deepseek-v4-flash:preview-cloud` ·
`deepseek-v4-pro:0813-cloud` · `deepseek-v4-pro:preview-cloud` · `kimi-k2.7-code:cloud` ·
`gemma4:31b-cloud`

The gap was not random: the 17 were chosen as one representative tag per model family, which
silently assumed that dated and `preview` tags of the same family carry the same weights. **That
assumption is false**, and `deepseek-v4-pro:preview-cloud` is the counter-example — see below. A
future sweep should enumerate `CLOUD_WINDOWS.keys` rather than a hand-picked list.

Column 4 is the table **as T12 found it**; three of its rows have since been corrected (see "What
the table says now"). Column 5 is the ratio, i.e. **what would happen to the occupancy denominator
if `/api/show` were wired into `context_window_tokens`.**

| model | `/api/show` KV key | `/api/show` value | shipped table | show ÷ table |
|---|---|---|---|---|
| `gpt-oss:20b-cloud` | `gptoss.context_length` | 131,072 | 128,000 | 1.024x |
| `gpt-oss:120b-cloud` | `gptoss.context_length` | 131,072 | 128,000 | 1.024x |
| `qwen3.5:cloud` | `qwen3.5.context_length` | 262,144 | 256,000 | 1.024x |
| `qwen3.5:397b-cloud` | `qwen3.5.context_length` | 262,144 | 256,000 | 1.024x |
| `minimax-m3:cloud` | `minimax-m3.context_length` | 524,288 | 512,000 | 1.024x |
| `deepseek-v4-flash:cloud` | `deepseek4.context_length` | 1,048,576 | 1,000,000 | 1.049x |
| `deepseek-v4-pro:cloud` | `deepseek4.context_length` | 1,048,576 | 1,000,000 | 1.049x |
| `glm-5.2:cloud` | `glm5.2.context_length` | 1,000,000 | 976,000 | 1.025x |
| `glm-5.1:cloud` | `glm5.1.context_length` | 202,752 | 198,000 | 1.024x |
| `kimi-k3:cloud` | `kimi-k3.context_length` | 1,048,576 | 1,000,000 | 1.049x |
| `kimi-k2.6:cloud` | `kimi-k2.context_length` | 262,144 | 256,000 | 1.024x |
| `nemotron-3-ultra:cloud` | `.context_length` | 262,144 | 256,000 | 1.024x |
| `nemotron-3-super:cloud` | `nemotron_h_moe.context_length` | 262,144 | 256,000 | 1.024x |
| `gemma4:cloud` | `gemma4.context_length` | 262,144 | 256,000 | 1.024x |
| `mistral-large-3:675b-cloud` | `mistral3.context_length` | 262,144 | 256,000 | 1.024x |
| `minimax-m2.7:cloud` | `minimax-m2.context_length` | 196,608 | **200,000** | **0.983x** |
| `nemotron-3-nano:30b-cloud` | `nemotron-3-nano.context_length` | 262,144 | **1,000,000** | **0.262x** |

### Why this is a trained maximum and not a served window

Four independent structural arguments, none of which rests on the numbers being large:

1. **The key is GGUF KV metadata.** It lives inside `model_info` under
   `<general.architecture>.context_length`, alongside `<arch>.embedding_length` and
   `general.parameter_count`. That is the GGUF key-value namespace read out of the model file. It
   is not a runtime figure and there is no obvious way for a runtime figure to end up there.
2. **A serverless host has no runner whose `num_ctx` this could describe.** The only endpoint that
   ever states a *served* window is `GET /api/ps`, and it reports loaded runners — a concept this
   host does not expose at all (see §4).
3. **Sixteen of seventeen values are exact multiples of 1024** — 128Ki, 192Ki, 198Ki, 256Ki,
   512Ki, 1Mi. Serving limits get set to round decimal numbers by humans; architecture metadata
   gets set to binary ones by converters. The single exception, `glm-5.2:cloud` at a flat
   1,000,000, is a decimal literal that model's own config carries.
4. **`nemotron-3-ultra:cloud` reports `general.architecture` as the EMPTY STRING**, so its key is
   the malformed `.context_length`. A served-window field would not have an architecture prefix to
   get wrong. This is a metadata defect leaking through from the model file, and it is only
   possible because the field *is* file metadata.

**The ruling stands, and the sweep strengthens it:** this figure must never be wired into
`context_window_tokens`. `ollama.rb`'s `#context_window_tokens` and `#trained_context_tokens`
already exist as a documented pair for exactly this reason on the local arm — the local box's
qwen3-coder:30b reports 262,144 while its runner serves 32,768, an 8x over-estimate that silently
disables compaction (`references/ollama/api-show-and-context.md`). It **is** the correct source for
`trained_context_tokens`, whose only job is refusing a `--num-ctx` above what the weights allow.

### Three rows where the shipped table was the one that was wrong

This is the finding round 1's single-model measurement could not have produced, and it points the
opposite way from the rest of the table.

For most models the trained maximum sits 2.4–4.9% **above** the published table, which is the
expected relationship: Ollama publishes a decimal label ("128K" → 128,000) that floors the binary
truth (131,072), and the conservative floor is the right denominator.

For **three** models the trained maximum is **below** what the table claimed — two found by the
T12 sweep, the third by review's sweep of the six rows T12 missed:

- **`minimax-m2.7:cloud`** *(T12)* — trained 196,608 (192Ki), table 200,000. A 1.7% over-claim.
  **Inferred**: Ollama's page label "200K" was read as decimal 200,000 when the underlying figure
  is 192Ki.
- **`nemotron-3-nano:30b-cloud`** *(T12)* — trained 262,144 (256Ki), table **1,000,000**. A **3.8x
  over-claim**, and it sat in the table's "Ollama publishes 1M" group. This is the same order of
  error as the local arm's 8x qwen3-coder case, and in the same dangerous direction: an occupancy
  denominator 3.8x too large means `:approaching_window` compaction never fires.
- **`deepseek-v4-pro:preview-cloud`** *(review, not T12)* — trained 524,288 (512Ki), table
  **1,000,000**. A **1.9x over-claim**, confirmed on two reads. It is a genuinely different build
  from `deepseek-v4-pro:cloud` (`parameter_size` 1600000000000, `modified_at` 2026-04-24), which
  is precisely why the base tag's clean 1,048,576 did not cover it — and why probing one tag per
  family was the wrong sampling strategy.

**This does not make `/api/show` a denominator.** A trained maximum is an upper bound on a served
window, so when it falls *below* a published figure the published figure cannot be right either.
The table's own comment already anticipates going stale; this is that comment coming true within
two months.

### What the table says now — all three rows are FIXED

These are not outstanding follow-ups. All three are **corrected on `main`** — `e827ce7b` for the
two T12 found, `94fbdef2` for the one review found — so `CLOUD_WINDOWS` now carries:

| row | was | is |
|---|---|---|
| `minimax-m2.7:cloud` | 200,000 | **196,608** |
| `nemotron-3-nano:30b-cloud` | 1,000,000 | **262,144** |
| `deepseek-v4-pro:preview-cloud` | 1,000,000 | **524,288** |

each with its measurement in a comment beside it, and a guard pinning all nine measured ceilings.

Read those corrected rows for what they are: a **trained maximum is a hard ceiling, not a promise
about what any given request is served**. They are keyed rather than left to the 8,192 fallback
because a measured bound beats a guess, but nothing in this document establishes that the host
serves the full figure for any model.

### What lain actually does today: nothing

The hosted `Deployment#model_metadata?` returns `false`, so `Provider::Ollama#trained_context_tokens`
returns `nil` **before it reaches the transport** — no request is made. That predicate shipped
`false` because whether `/api/show` answered off-loopback was unverified at the time.

It answers. So the cloud arm currently performs **no `--num-ctx` refusal at all**: a
`--num-ctx 500000` against a 128k cloud model is accepted in silence, where the local arm would
refuse it. Flipping the predicate is a one-line change and is deliberately **not** part of T12,
whose job was to establish the evidence that would justify it. That evidence is this section, and
the gap is pinned by a live example in `ollama_cloud_spec.rb` so the follow-up has something to
turn red.

---

## 2. Rate limits — nothing on a 200, five headers on a 429

### On success: no rate-limit vocabulary at all

The complete header set on a 200, identical for `/api/show` and `/api/chat`:

```
alt-svc            content-length     content-type       date
server             set-cookie         traceparent        via
x-build-commit     x-build-time       x-cloud-trace-context
x-frame-options    x-request-id
```

No `ratelimit-*`, no `x-ratelimit-*`, no `retry-after`, no remaining or quota counter.

**Absence on success proved nothing**, and this is the trap worth recording: many APIs emit
rate-limit headers only on the refusal, so round 1 correctly stopped at "none on success; the 429
vocabulary is unknown" rather than concluding there was none. Round 2 forced a real 429 and the
caution was justified.

### Forcing a 429, and what it costs

A concurrent burst of **thirty `/api/show`** requests drew **zero** refusals — metadata is not
metered this way, or not at this width. A burst of **eight `/api/chat`** requests
(`num_predict: 1`) also drew zero. **Thirty-two concurrent `/api/chat`** drew **thirteen 429s
against nineteen 200s**, which is the number that makes the mechanism legible (below).

### The refusal — one captured response, verbatim

This is the finding that cost the quota, so here it is as it came off the wire rather than as a
summary. **One** of the thirteen refusals, complete and unedited except that the `set-cookie`
value is masked (it is a persistent per-client id, not a credential, but it identifies the
measuring machine and has no bearing on the finding):

```
HTTP/1.1 429 Too Many Requests
alt-svc: h3=":443"; ma=2592000
content-length: 41
content-type: application/json
date: Mon, 24 Aug 2026 17:11:49 GMT
retry-after: 10
server: Google Frontend
set-cookie: aid=<MASKED>; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax
traceparent: 00-fcc9c50a5b743f31553fbac17c04d615-35d27d33c6c339b0-00
via: 1.1 google
x-build-commit: 2f953fcbd5d0a8bd8abaa3bcc1ddf23fda26b04c
x-build-time: 2026-08-21T17:00:34-07:00
x-cloud-trace-context: fcc9c50a5b743f31553fbac17c04d615/3878299890450905520
x-frame-options: DENY
x-ratelimit-active: 4
x-ratelimit-max-concurrent: 4
x-ratelimit-queue-limit: 15
x-ratelimit-queued: 15
x-request-id: 0255a19a-91f3-47a8-8895-e5185a3d8460

{"error":"too many concurrent requests"}
```

**To re-derive this yourself**, the spec can force it — behind a second gate, because it
deliberately saturates the subscription so that other work against the same key is refused while
it runs:

```bash
LAIN_OLLAMA_CLOUD=1 LAIN_OLLAMA_CLOUD_SATURATE=1 OLLAMA_API_KEY=... \
  bundle exec rspec spec/integration/provider/ollama_cloud_spec.rb -e "concurrency-shaped headers"
```

Five headers appear that are **absent from every 200**:

| header | observed value | meaning |
|---|---|---|
| `retry-after` | `10`–`20`, **varying per response** | seconds, integer form — not an HTTP-date |
| `x-ratelimit-max-concurrent` | `4` | requests this plan may have **running** |
| `x-ratelimit-active` | `4` | requests running right now |
| `x-ratelimit-queue-limit` | `15` | requests the server will **queue** beyond the active ones |
| `x-ratelimit-queued` | `15` | requests queued right now |

There is **no `x-ratelimit-reset`, no `RateLimit-Reset`, and no remaining/limit pair.** The
vocabulary describes a **concurrency-and-queue admission gate**, not a token bucket over time.

**The arithmetic confirms the model exactly**: 4 active + 15 queued = **19 admitted**, and 19 + 13
refused = the 32 sent. The server runs four, queues fifteen, and refuses the twentieth onward.

The 429s came back in **0.22–0.29s** while the 200s took 0.6–1.9s — the refusal is issued at the
admission gate, not after waiting, so a refused request costs latency but no inference.

### What this means for lain, and it is good news

- **`RateLimitError` is in `Connection::MiddlewareStack#retry_exceptions`** (verified in source and
  pinned by a live example), so a 429 is **retried**, not surfaced on the first attempt. T12's
  escalation trigger on this point is satisfied and the vendored retry list needs no widening —
  which matters, because widening it would change *every* provider's behaviour.
- **`Retry-After` is honoured today with no configuration.** faraday-retry 2.4.0's
  `calculate_retry_after` defaults `rate_limit_retry_header` to `'Retry-After'`, and the retry
  middleware is registered **outside** the error middleware (`middleware_stack.rb:57` vs `:59`), so
  when `RateLimitError` propagates, `env[:response_headers]` is already populated and the header is
  read. An integer-seconds value falls through `DateTime.rfc2822`'s `Date::Error` (a subclass of
  `ArgumentError`, so it is caught) to `.to_f`. **Measured, not assumed.**
- **T7's decision to leave `rate_limit_reset_header` and `header_parser_block` nil is now
  positively correct, not merely defensible.** There is no reset header to name, and naming one
  would replace faraday-retry's working `Retry-After` default with a guess. The `header_parser_block`
  is likewise unnecessary because the value is plain integer seconds.
- **`Deployment::DEFAULT_ADMISSION_WIDTH = 1` is conservative.** This subscription's
  measured allowance is **4 concurrent plus 15 queued**. The default of 1 is still the right one to
  ship — its comment's reasoning ("the only default that is safe on every plan") is unaffected by
  one plan turning out to be wider — but an operator on this plan can raise
  `LAIN_OLLAMA_CLOUD_CONCURRENCY` to 4 with evidence behind the number.
- `x-request-id` is present on **every** response, success and failure alike, and is the one field
  worth journaling on a cloud error — it is what Ollama support could correlate against.

**Inferred, and worth stating as inference:** `x-ratelimit-max-concurrent: 4` is presumably
plan-dependent, and the values above describe *this* subscription on *this* date. The header
*names* are the durable finding; the numbers are a snapshot.

---

## 3. Prompt caching — no signal, and that settles it

A non-streaming `/api/chat` response carries exactly these top-level keys:

```
model   created_at   message   done   done_reason   total_duration
prompt_eval_count    eval_count
```

There is **no `cached_tokens`, no `cache_read`, no `prompt_cache_hit`, nothing cache-shaped.**

Note also what is **missing relative to a local server**: `load_duration`,
`prompt_eval_duration` and `eval_duration` are all absent — the cloud host sends `total_duration`
alone. Anything decoding cloud responses must not depend on the sibling duration fields.

The useful reframing, and it is stronger than a cache measurement would have been: **it does not
matter whether the backend caches.** Lain declares capabilities it can *demonstrate*, and there is
nothing on this wire to demonstrate one from. So `CacheProfile::NO_CACHING` and the absence of
`:prompt_caching` from `Deployment::CAPABILITIES` are correct **regardless of backend
behaviour**. Ollama's pricing page metering "cached input tokens" separately is suggestive and is
not evidence.

If Ollama later adds a cached-input field to this response, **that** is the trigger to revisit —
not a pricing-page line.

---

## 4. Everything else the wire said

### Authentication failure

A syntactically valid but wrong key on `/api/chat`:

```
HTTP/1.1 401
content-type: application/json

{"error":"Unauthorized"}
```

No `www-authenticate` header. The header set is otherwise **byte-identical to a 200's** — there is
no failure-specific field to key on except the status. Lain maps 401 to
`Provider::HTTP::UnauthorizedError` (`error_middleware.rb:51`) and surfaces it as
`Provider::Ollama::APIStatusError` with `status` lifted out, which is what keeps this off the
"An unknown error occurred" path.

The 401 is issued before any inference, so it costs nothing but a round trip.

### `/api/ps` has no cloud meaning

Not measured, because the hosted `Deployment#runner_status?` answers `false` before the request is
made, and that is the correct design: `/api/ps` lists **loaded runners**, a concept a serverless
host does not have. A rescue-based approach would spend a round trip per denominator lookup against
somebody's quota purely to rediscover a 404.

### `num_predict` works on the wire but is unreachable from a Request

`options.num_predict` is honoured by the cloud host — a capped request returns
`done_reason: "length"` with exactly that many eval tokens. But `num_predict` is **not** in
`Ollama::Encoding::SAMPLER_KEYS` (which holds only `temperature`, `seed`, `num_batch`, `num_ctx`),
and `Request#max_tokens` is carried for the neutral contract and **not sent**. So **there is no way
to cap output length through a `Lain::Request` on either ollama arm.** Harmless on a free local
server; on a metered one it means the caller cannot bound what a turn costs. Recorded as a finding,
not fixed here.

### `think: false` does not suppress reasoning on gpt-oss

`gpt-oss:20b-cloud` emits `message.thinking` regardless. With `think: false` and
`num_predict: 60`, **all sixty tokens went to the thinking channel and `message.content` came back
empty** — a completion that cost full price and returned nothing. `think: "low"` produces a short
trace (a single sentence) and leaves budget for content.

**Inferred:** gpt-oss is reasoning-native and its analysis channel is not optional, so `think` on
this model selects *effort*, not presence. Any cost model for this arm must count thinking tokens
as output tokens, because `eval_count` includes them.

### Determinism — **temperature 0 does NOT reproduce on the cloud arm**

This is the sharpest divergence from the local arm and the one most likely to mislead.

Method: `gpt-oss:20b-cloud`, `temperature: 0`, `seed: 42`, `think: "low"`, one identical prompt,
one warm-up run discarded, then three measured runs — deliberately the *same* protocol
`spec/integration/provider/ollama_spec.rb` uses to establish determinism locally, so the two
results are comparable.

Result: **three distinct completions out of the three measured runs.** Verbatim, labelled, with
the discarded warm-up shown so the count can be checked rather than taken on trust. Note that the
warm-up happens to coincide with measured run 2 — that is why an unlabelled dump of these four
lines looks like "three distinct of four" and is worth being explicit about:

```
WARM-UP (discarded)  eval_count=33
  content: "A compiler translates source code into machine code or an intermediate
            representation that a computer can execute."

measured 1          eval_count=40
  content: "A compiler translates source code written in a high-level language into
            machine code or an intermediate representation that a computer can execute."

measured 2          eval_count=33
  content: "A compiler translates source code into machine code or an intermediate
            representation that a computer can execute."

measured 3          eval_count=41
  content: "A compiler translates source code written in a high-level programming language
            into machine code or an intermediate representation that a computer can execute."
```

The three measured runs share a **34-character common prefix** and then diverge:

```
common:  "A compiler translates source code "
run 1 →  "written in a high-level language into machine code or an int…"
run 2 →  "into machine code or an intermediate representation that a c…"
run 3 →  "written in a high-level programming language into machine co…"
```

`thinking` was byte-identical across all four runs — `"Need one short sentence."` — and
`done_reason` was `stop` for all four, so no run was truncated. Only `content` diverged.

**Inferred cause, and the evidence is not clean on this point.** The natural hypothesis is that
Ollama Cloud batches requests across tenants and batch composition perturbs the argmax through
floating-point non-associativity — the same mechanism `references/ollama/api-chat.md` documents as
a *limit* on local determinism (issues #586/#5321), except that locally it is an edge case around
load generations while here it would be the ordinary case, since the batch a request lands in is
not something a caller controls or can warm up into.

**But this document's own evidence cuts against that explanation, and a reader should not have to
notice that unaided.** `thinking` is decoded first and is the longer-lived span; a batching
mechanism that perturbs the argmax has no reason to leave the thinking channel bit-exact across
four runs and then diverge only in the later channel. Something that reproduces one channel
exactly and not the next looks more like a sampling or routing difference *downstream* of the
reasoning pass — a different model replica, a different sampler seeding per channel, or
server-side non-determinism confined to the content decode. **No hypothesis here is established.**

**What IS established is the observation, and the conclusion below rests only on that**: identical
requests to this endpoint return different completions. The cause is open; the consequence is not.

**Consequences, and they bind:**

- **The cloud arm is not a reproducible bench arm.** Any experiment comparing context strategies
  across cloud runs is comparing samples, not points, and needs N > 1 and a variance treatment. The
  local arm's temperature-0 reproducibility does **not** transfer.
- **`ollama_cloud_spec.rb` has no determinism example, and this is deliberate rather than an
  omission.** Per T12's escalation trigger, the response to a live assertion that will not hold is
  to pin the invariant that is actually true and say so here — not to write the example and mark it
  pending. A false determinism claim poisons every bench conclusion built on this arm, which is
  exactly the failure `planning/specs/code-review-ollama-test-infra.md` T21 records. What the spec
  pins instead is the Response contract, which does hold.

### The tool-call path works

A real `Lain::Agent` turn with `EchoTool` against `gpt-oss:20b-cloud` calls the tool, lands the
result in exactly one user turn, matches every synthesized `tool_use_id`, and settles — run three
times, green three times, in ~1.9s per turn. Ollama's native wire has no tool-call id (correlation
is by `tool_name` only), so the provider synthesizes one; this is the only place that synthesis
crosses a real cloud wire.

**Stated as the live-model claim it is:** three green runs is evidence of a reliable path, not
proof of one. If this example ever goes flaky, the honest response is the same as for determinism —
weaken the claim here, do not mark the example pending.

### Server identity

`server: Google Frontend`, `via: 1.1 google`, with `x-build-commit` and `x-build-time`
(`2026-08-21T17:00:34-07:00` on the measurement date) identifying the Ollama build behind it. The
build is **not** the same as any local `ollama serve`, which is why the wire contract is worth
re-asserting against this host rather than assumed from local coverage.

---

## Open, and what would close it

| question | status | what would settle it |
|---|---|---|
| Is `x-ratelimit-max-concurrent` plan-dependent? | **inferred yes, unverified** | the same burst against a second subscription on a different plan |
| Were the three over-claiming `CLOUD_WINDOWS` rows a transcription error or a page change? | **unestablished** — but the rows themselves are FIXED (see "What the table says now"); only the *cause* is open | re-reading the three library pages against the measured ceilings |
| Do dated / `preview` tags diverge from their base tag on models other than `deepseek-v4-pro`? | **partly answered** — one divergence found in 23 rows | the sweep now covers every shipped row; the open part is whether NEW tags need re-probing rather than inheriting |
| Does a 429 ever carry a reset header under load shaped differently (quota rather than concurrency)? | **unestablished** | a burst sustained past a daily or hourly allowance, which costs real quota to reach |
| Does the streaming (`stream: true`) path carry the same headers? | **unmeasured** | one streamed request; expected identical, since the headers precede the body |
