# Scenario: session start, the served window, and occupancy

**What it exercises:** `WindowBook`, `Middleware::ResolveWindow`, `Backend::NumCtx`,
`Backend::Endpoint`, the `provenance` tag, `compaction_decision`, `.lain/state.json`, the HUD's
`ctx N%`, and the `options` asymmetry on the ollama wire.

**Cost:** cheap. Most of it is launch-level and needs no model call at all. **Run it first** — it
is the fastest way to tell whether the bench is honest before spending a session on a subject.

**Needs:** `bench.md` up. A project directory. No nvim required.

---

## 1 — Launch-level refusals (no model call, no cockpit)

Every one of these must refuse **by name at construction**, exit 1, and print no backtrace.
`< /dev/null` is the vehicle: the refusal fires before stdin is ever read.

```bash
run(){ out=$(timeout 90 lain chat --provider ollama --model qwen3-coder:30b "$@" < /dev/null 2>&1); echo "[$? ] $*"; echo "$out" | tail -3; }
run --num-ctx 0
run --num-ctx -5
run --num-ctx 999999                 # above the trained maximum
run --num-ctx 262144                 # AT the trained maximum: must be accepted
run --api-base localhost:11434       # the scheme-less typo a human actually makes
run --api-base 'http://'
run --api-base 'http:///x'
run --api-base 'not a uri at all'
run --api-base ''                    # an unset $OLLAMA_HOST
```

Expected shapes (round 4, all passing):

- `--num-ctx must be positive, got 0`
- `--num-ctx 999999 is above the model's trained maximum of 262144; no runner can serve a window larger than the weights were trained for`
- `--api-base "localhost:11434" has no host; a scheme is required, e.g. http://localhost:11434`
- `--api-base "not a uri at all" is not a usable URL`

**The trained maximum must arrive with NOTHING resident** — it rides `/api/show` on the same 2s
probe connection as `/api/ps`, and only when `--num-ctx` is set. Verify residency is empty first, or
this proves nothing.

## 2 — Connect timeout against a blackhole

```bash
time lain chat --provider ollama --model qwen3-coder:30b \
     --api-base http://10.255.255.1:11434 --prompt 'say hi' < /dev/null
LAIN_CONNECT_TIMEOUT=1 <same>
```

Expected: ~26s at the default 5s connect timeout, ~8s at 1s — **not** the ~20 minutes
(`request_timeout` 300s × 4 attempts) this used to take. Retries must render **live** on screen
(`[retry] attempt N, retrying in Xs -- Faraday::ConnectionFailed`), not journal-only.

Count the attempts with a counting TCP listener (see `method.md`) rather than trusting the rendered
ordinals — round 4's F16 is exactly that gap.

## 3 — Cold start, then warm, in ONE session

Launch cold (nothing resident), drive one trivial turn, then drive a second.

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "window=#{r["window_tokens"]} used=#{r["used_tokens"].inspect} prov=#{r["provenance"].inspect} sig=#{r["signals"].inspect}" \
    if r["type"]=="compaction_decision"}' "$JOURNAL"
```

Expected, and this is the interesting part:

| turn | residency | window | provenance | signals |
|---|---|---|---|---|
| 1 | cold | fallback (8192) | `guessed` | `[]` — a guess may never authorise a rewrite |
| 2 | resident (turn 1 loaded it) | 32768 | `probed` | as warranted |

**The window must RE-RESOLVE mid-session.** Before round 3's T6 the book was resolved once at launch
and memoized, so it stayed at the fallback for the whole session. A window that never moves off 8192
is that regression returning.

`--num-ctx N` alone resolves a served window **with no server involved**, so it should give an
honest denominator with nothing resident. That is the operator lever; it is otherwise untested.

## 4 — The three readers must agree

Journal `compaction_decision`, `.lain/state.json` `occupancy`, and the HUD's `ctx N%`.
*Disagreement between them is the real failure;* a uniformly wrong number is the known one.

Cross-check the denominator too: `compaction_decision.used_tokens` should equal the matching
`turn_usage.usage.input_tokens` (round 4: both 4515, exactly). Note the token counts are **nested
under `usage`**, not top-level — reading the wrong path makes them look absent.

## 5 — `capability_degraded`

Count the lines in the journal: expect **exactly one**, and expect **nothing on screen** — nothing
renders it, so a driver watching the display will otherwise file a false defect.

```json
{"type":"capability_degraded","capability":"prompt_caching","requirer":"Lain::Context","provider":"Lain::Provider::Ollama"}
```

## 6 — The `options` asymmetry on the wire

The contract is that lain sends **only what was asked for**:

```bash
# with the knob set
LAIN_NUM_BATCH=2048 lain chat ... --prompt hi      # -> extra={"num_batch" => 2048}
# with neither knob
env -u LAIN_NUM_BATCH lain chat ... --prompt hi    # -> extra={}   (NO options key at all)
```

Read it off both the `session` record and every `request_sent`. The `env -u` is required — the
flag's default is `EnvDefaults.numeric("LAIN_NUM_BATCH")`, which `bench.md` exports.

## What this scenario does not cover

The **compaction path at scale** — filling the context until a compaction actually fires. Rounds 3
and 4 both failed to reach it (round 3 died to F10, round 4 to F21's session ceiling), which makes
it the least-exercised path in the whole QA suite. When the session ceiling is fixed, do it here and
early, not behind the destructive probes.
