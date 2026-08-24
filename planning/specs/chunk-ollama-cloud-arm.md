# Somebody else's ollama: a cloud arm for the provider axis

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Add **Ollama Cloud** as a second ollama arm, alongside the local one, on the ROADMAP's
**Provider / model** axis (`ROADMAP.md:52` — "Anthropic vs. OpenAI-compatible vs. local (ollama)
vs. Bedrock"). Ollama sells subscription API access at `https://ollama.com/api` behind
`Authorization: Bearer $OLLAMA_API_KEY`, serving **the same native `/api/chat`** lain already
speaks — so the wire work is zero and the whole chunk is about the four things that stop being
true when the server stops being ours.

The bench case is the reason to do it at all. Today the ollama arm confounds four variables in
one: local, free, small model, no caching. A cloud arm holds the **encoder, decoder and wire
format byte-identical** and changes only hosted-ness and model class — a clean cut on the
provider axis that neither the Anthropic nor the Bedrock arm can give, because both change the
wire too.

The cost of the arm is that `Provider::Ollama`'s class docstring currently argues five deliberate
absences from the premise "free and local" (`ollama.rb:66-76`), and every one of them inverts.
This chunk closes four and records why the fifth stays open.

## Grounding

Verified against the working tree on **2026-08-24** by four parallel exploration passes plus
direct measurement. **Suite state at plan time: 15368 examples, 0 failures, 15 pending** — green.
Where a premise of the interview disagreed with the code, the code won; the corrections are
recorded below because the superseded version is the intuitive one and will otherwise be
re-proposed.

### What the external API actually offers (2026-08-24)

- **Same native surface.** `https://ollama.com/api` is the cloud base for the same endpoints
  (`https://docs.ollama.com/api`). `/api/chat`'s documented parameter list is
  `model, messages, tools, format, options, stream, think, keep_alive, logprobs, top_logprobs` —
  i.e. everything `Ollama::Encoding` already emits. **RubyLLM's `Ollama` provider could not reuse
  this**: it is an `OpenAI` subclass pinned to `/v1/...` (`references/ollama/rubyllm-ollama.md`),
  and its entire class body is `api_base` + a Bearer `headers` method. Lain's native path is what
  makes cloud a configuration change instead of a second provider.
- **Auth.** Key from `ollama.com/settings/keys`; `Authorization: Bearer <key>`.
- **Metering is concurrency + quota, not per-token dollars.** Free / Pro ($20) / Max ($100), with
  **1 / 3 / 10 concurrent models**, plus a rolling 5-hour session allowance and a weekly one,
  counted over input, *cached input*, and output tokens. No published RPM/TPM, no published
  per-model context ceilings.

**Unverified, and deliberately not assumed by any card** (T12 settles them against a live key):
whether `/api/show` and `/api/ps` answer on `ollama.com`; whether the native cloud path returns
rate-limit headers and under what names; whether cloud prompt-caches (the pricing page meters
"cached input" separately, which is suggestive and is not evidence).

### CORRECTION 1 — `Provider::Ollama.new` must keep meaning "loopback", so `deployment:` gets a default

The interview settled on `Provider::Ollama.new(deployment:)` **with no default**, so that no site
could construct an ambiguous arm. The tree refuses this, in two places that both matter:

1. `spec/lain/oracle/secret_read_spec.rb:121-127` asserts
   `expect(Lain::Provider::Ollama).to have_received(:new).with(no_args)` — the bare construction
   *is* the loopback guarantee, stated at `secret_read.rb:17-40`.
2. `spec/provider_construction_discipline_spec.rb` parses `lib/` with **Ripper and matches `.new`
   specifically**, precisely so that a constant read (`Provider::Ollama::DEFAULT_MODEL`) is not
   mistaken for a construction (`:19-23`). A factory call — `Provider::Ollama.local` — is
   invisible to it. Renaming the secret-read construction would therefore **delete** the static
   guard that is the strongest thing protecting that seam, while looking like a strengthening.

So: `deployment: Deployment::Local.new` is the **default**, the secret-read site is left
byte-identical, and the guarantee is pinned *forward* instead — T14 adds an example that the
default deployment is `Local` and resolves to `http://localhost:11434`. The factories
`.local`/`.cloud` still exist as the intention-revealing door for new callers.

The corollary is T11: the moment `lib/` contains a `Provider::Ollama.cloud(...)`, the Ripper
detector stops covering the file it is in. That gap must close **before** T8 introduces one.

### CORRECTION 2 — `LAIN_PROVIDER_CONCURRENCY` cannot express this, so `Admission` needs a declared width

`Admission.build` is three-way (`admission.rb:263-269`): a positive `LAIN_PROVIDER_CONCURRENCY`
wins in both directions, otherwise `Endpoint.local?` decides between `DEFAULT_WIDTH = 1` and the
unbounded `Null`. `ollama.com` is not local, so today a cloud arm gets `Null` — **unbounded
against a plan that permits 3 concurrent models.**

The env key looks like the escape hatch (`admission.rb:158-168` explicitly says a positive `N`
"gates a hosted one") and is not: it is a **single process-wide number**, so raising it to 3 for
the cloud endpoint also raises the local endpoint off `1` and re-opens F26, the one-slot-server
starvation the gate was built for. Ollama Cloud is the first endpoint in lain that is
**remote *and* hard-capacity-bounded**, and the local?/hosted dichotomy has no room for it. T4
adds a caller-*declared* width, third in precedence behind the env and ahead of locality.

### CORRECTION 3 — `CLI::Backend` is at its `ClassLength` cap, so `--cloud` cannot be handled there

Measured 2026-08-24: the `Backend` class body is **110 lines against `Metrics/ClassLength: Max:
110`** (`.rubocop.yml`), i.e. zero headroom; `bundle exec rubocop` is clean today only because it
is exactly at the limit. CLAUDE.md forbids loosening a `Metrics/*` limit. This is the same wall
`chunk-qa-round9` hit and recorded.

So T8 may not *add* to `Backend`. It replaces the body of the existing `when "ollama"` arm
(`backend.rb:199`) with a delegation to a new `CLI::Backend::OllamaTier` collaborator, net zero
lines — the established pattern of that directory (`endpoint.rb`, `num_ctx.rb`, `ceiling.rb`,
`summarizer.rb`, `span_summarizer.rb`, `window_book.rb` are all exactly this move).

### CORRECTION 4 — the window fix needs no provider change at all

`WindowBook::Source#book` (`window_book.rb:271-279`) returns the whole `ContextWindow.default`
book when the provider reports nil, and `ContextWindow#resolve` tags **a table hit `PUBLISHED`**
(`context_window.rb:334`), which `authoritative?` accepts. So publishing cloud model windows in
`ContextWindow::DEFAULTS` is sufficient, end to end, with no edit to `Provider::Ollama` — which
is what lets T5 run in wave 1 instead of queueing behind T2.

Without it, every cloud model falls to `CONSERVATIVE_FALLBACK = 8_192` tagged `GUESSED`, and
`Compaction::Source` then declines `:approaching_window` on it entirely (`compaction/source.rb:429`)
— so a 128k cloud model would both under-report occupancy ~16x *and* have its window-pressure
compaction silently switched off. That is `context_window.rb:88-104`'s measured damage case with
a bigger multiplier.

### The seams as they stand

- **Auth mechanism.** `Connection#post`/`#get` merge `@provider.headers` into every request
  (`http/connection.rb:85,94,106-108`). A provider adds auth by declaring a config option and
  overriding the **instance** method `#headers` — `Provider::HTTP::Providers::Bedrock:28-33` is
  the exact `Authorization: Bearer` precedent. `Ollama::Transport` overrides neither, registers
  only `ollama_api_base`, and hardcodes `local? = true` (`transport.rb:160-164`). No config option
  in the vendored slice has an ENV default (`http/configuration.rb`), and no card may add one —
  an ENV-resolved `ollama_api_base` is the one mechanism that could redirect the secret-read
  oracle off loopback without touching `secret_read.rb` at all.
- **The dead headers argument.** `Transport#sync_post`/`#stream` take a positional
  `headers = {}` that **no caller in `lib/`, `exe/` or `spec/` ever passes**, and where it merges
  the provider's own headers still win (`headers.merge(req.headers)`). It is vestigial parity with
  the Anthropic and Bedrock transports. Auth goes through `#headers`, not through it.
- **Probe endpoints.** `context_window_tokens` GETs `/api/ps` — a *loaded runner* concept with no
  meaning on a serverless host. `spec/support/ollama_probe.rb` registers a global WebMock stub for
  it against localhost; a cloud provider that probed would reach VCR's gate unstubbed.
- **Spool.** `spool:` is a keyword on `Provider::Anthropic` only (`anthropic.rb:92-93`), consumed
  as `RetryTap.new(spool:, channel:)`; `Spool::RotatingFrame` exists precisely so a retried stream
  does not concatenate two attempts into one complete-marked frame. `Ollama::RetryTap` takes
  `channel:` only.
- **Rate limits.** `rate_limit_reset_header` and `header_parser_block` are **generic
  Configuration knobs** (`http/configuration.rb:145-146`) forwarded by
  `MiddlewareStack#retry_callbacks` with `.compact`, so leaving them nil falls back to
  faraday-retry's own `RateLimit-Reset` handling rather than disabling it. Only
  `AnthropicWire#apply_rate_limit_backoff` sets them today, from a hardcoded module constant with
  no per-instance override.
- **Cost.** `Price` is four per-token fields and nothing else; there is **no** subscription or
  quota concept anywhere in `lib/`. `PriceBook::DEFAULT` has three Anthropic family rows and no
  fallback, so an ollama model id raises `UnknownModel`.
- **Tags.** The live-server tag is `:ollama` (`spec/support/ollama_tag.rb`), gated on
  `LAIN_OLLAMA=1` plus a `GET /api/tags` reachability probe **against localhost**, and it costs no
  money. A cloud tag cannot reuse it: it costs quota and needs a key, which is `:api_integration`'s
  posture (`spec/support/tags.rb`), not `:ollama`'s.
- **Construction discipline.** `spec/provider_construction_discipline_spec.rb` allowlists exactly
  two files, keyed by file **and class**, with a hard ceiling of `approved.keys.size <= 3` and
  `approved.values.sum(&:size) <= 6` (`:487`). This chunk lands at **3 keys / 5 entries** — at the
  key ceiling. Any card that needs a fourth file has hit the wall the ceiling exists to raise.

## Orchestrator contract (plan-specific only)

- **Shared files (orchestrator-owned, wiring diffs only):**
  - `lib/lain.rb` — load-order manifest.
  - `lib/lain/provider/ollama.rb` — **the require block only.** This file is unusual: it is both
    the `ollama/` subtree index and the `Provider::Ollama` class body. **Stated deviation from the
    normal rule:** T2 and T6 do list this path under **Files**, because the class body is ordinary
    card scope. Only the `require_relative` block at the top is orchestrator-owned; a card adding a
    file under `ollama/` hands back the require line and never edits that block itself. The two are
    far enough apart in the file that a wiring diff and a card diff do not collide.
  - `.rubocop.yml`, `spec/spec_helper.rb`.
- **`spec/support/**` is not orchestrator-owned** but is shared: T1, T9 and T12 each create their
  own file there and none edits another's.
- **Deviations:** T13 is docs-only — skip the panel review on it, and it is the one card whose
  ACs name no spec file (integration check 8 verifies it instead).

## Open decisions

None of these gates a card. Each is a deliberate deferral with its reason.

1. **Does Ollama Cloud prompt-cache?** The pricing page meters "cached input tokens" separately,
   which is suggestive and is not evidence, and the native `/api/chat` response carries only a
   flat `prompt_eval_count`. **Until T12 measures it, the cloud deployment declares
   `CacheProfile::NO_CACHING` and does not declare `:prompt_caching`** — declaring a capability the
   path cannot demonstrate is the exact lie `ollama.rb:44-54` refuses, in the one subsystem built
   to catch it. If T12 finds caching, the follow-up is a `CacheProfile` constant and one
   capability symbol, and it is out of this chunk.
2. **The `/api/usage` quota meter is out of scope.** It is undocumented, and lain has no
   non-per-token cost concept to land it in (`Price` is a four-term dot product). Building a
   `Quota` value object on an undocumented endpoint is speculative generality. T15 instead makes
   the arm **refuse to state a dollar figure it does not have**, which is the honest half and is
   testable today.
3. **Cloud concurrency is configured by environment, not by a flag.** The plan's width cannot be
   inferred from the API, and admission widths in lain are already env-configured
   (`LAIN_PROVIDER_CONCURRENCY`) rather than flagged. `Deployment::Cloud` defaults to **1** — safe
   on every plan including Free — and `LAIN_OLLAMA_CLOUD_CONCURRENCY` raises it. No Thor flag.
4. **`--cloud` is a boolean flag that exactly one provider reads.** That is the shape recent
   commits have been removing ("commands: stop projecting a switch no command reads", f63dae70).
   It is chosen anyway, and the difference that makes it acceptable is that this one **is** read,
   in one place, and **refuses loudly** when combined with a provider that ignores it (T8's AC 3).
   If the panel judges the smell to outweigh that, the fallback is `--provider ollama-cloud`, and
   only T8 changes.

## Waves

```
Wave 1: T1, T4, T5, T9, T11, T15          (no unmet deps)
Wave 2: T2 (<-T1,T4,T5), T3 (<-T1), T7 (<-T1)
Wave 3: T8 (<-T2,T3,T11), T10 (<-T2,T3), T14 (<-T2)
Wave 4: T6 (<-T2,T8), T12 (<-T8,T9)
Wave 5: T13 (<-all)
```

Critical path: **T1 -> T2 -> T8 -> T6 -> T13** (5 cards), tied with T1 -> T2 -> T8 -> T12 -> T13.

**T6 sits after T8, not beside it.** The spool has to be *forwarded* by `OllamaTier` to be
reachable rather than dormant, and that file does not exist until T8 creates it — which is also
why T6, not T8, owns the forwarding line and the AC that pins it.

## Tasks

### T1 — Give the two ollama deployments a name and a value object   [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/provider/ollama/deployment.rb` (subtree index),
`lib/lain/provider/ollama/deployment/local.rb`,
`lib/lain/provider/ollama/deployment/cloud.rb`,
`spec/support/shared_examples/ollama_deployment.rb`,
`spec/lain/provider/ollama/deployment/local_spec.rb`,
`spec/lain/provider/ollama/deployment/cloud_spec.rb`
**Reuse:** `Lain::CLI::Backend::Endpoint` (`cli/backend/endpoint.rb`) as the model for a
`Data.define` value object whose whole job is to refuse a bad value with a named error;
`Lain::CacheProfile::NO_CACHING`; `Lain::Sink::Null` as the two-implementations-no-base-class
idiom; `Provider::HTTP::Providers::Bedrock:28-33` for the Bearer header shape;
`spec/support/shared_examples/store_laws.rb` as the shape of a protocol shared example group.
**Shared-file wiring:** `require_relative "ollama/deployment"` in `lib/lain/provider/ollama.rb`,
placed **above** the existing `require_relative "ollama/transport"` (T2 and T3 both read it).
**Reachable from:** `Deployment::Local` — `CLI::Backend#provider -> Provider::Ollama.new`, via
T2's default. `Deployment::Cloud` — `CLI::Backend::OllamaTier#provider`, built in T8.

Two value objects answering one message set, with **no shared superclass** — they are told apart
by what they answer, not by what they inherit. The set:

`api_base`, `headers`, `local?`, `capabilities`, `cache_profile`, `request_timeout`,
`max_retries`, `runner_status?`, `admission_width`, `apply(config)`.

`Local` answers `http://localhost:11434`, `{}`, `true`, today's
`%i[streaming thinking structured_output]`, `NO_CACHING`, `300`, `3`, `true`, `nil` — i.e. every
value the arm has today, so `Local` is a pure restatement and changes no measurement. `Cloud`
answers `https://ollama.com`, a Bearer hash, `false`, the same capability list (see Open decision
1), `NO_CACHING`, a shorter timeout, `true` for retries, **`false` for `runner_status?`**, and an
`admission_width` of `1` overridable by `LAIN_OLLAMA_CLOUD_CONCURRENCY`.

`Cloud` refuses a nil/blank `api_key` at construction, in the `Endpoint`/`Ceiling` idiom — the
refusal must name the environment variable a human sets, not the keyword.

**Acceptance criteria:**

```gherkin
Scenario: a cloud deployment refuses to exist without a key
  Given no OLLAMA_API_KEY is set
  When Deployment::Cloud is constructed with a nil api_key
  Then it raises an error naming OLLAMA_API_KEY and how to obtain one
  And the same happens for an api_key that is only whitespace

Scenario: each deployment states the endpoint it will really dial
  When Deployment::Local and Deployment::Cloud are asked for their api_base
  Then Local answers Provider::Ollama::Transport::DEFAULT_API_BASE
  And Cloud answers "https://ollama.com"

Scenario: only the cloud deployment carries authorization
  When each deployment is asked for its headers
  Then Local answers an empty hash
  And Cloud answers a hash whose Authorization value is "Bearer " followed by the key
  And Cloud's inspect output does not contain the key

Scenario: only the local deployment claims a loaded-runner endpoint
  When each deployment is asked whether runner status is available
  Then Local answers true and Cloud answers false

Scenario: a deployment writes itself onto a provider configuration
  Given a fresh Provider::HTTP::Configuration
  When Deployment::Cloud#apply is called on it
  Then ollama_api_base, ollama_api_key and request_timeout read back the deployment's values

Scenario: a deployment is a value, not a mutable holder
  When either deployment is constructed
  Then Ractor.shareable? answers true for it
```
→ spec files: `spec/lain/provider/ollama/deployment/local_spec.rb`,
`spec/lain/provider/ollama/deployment/cloud_spec.rb`, and the shared group
`spec/support/shared_examples/ollama_deployment.rb` included by both.

**Escalation triggers:**
- `ollama_api_key` is not yet a registered `Configuration` option until T3 lands, so
  `Deployment::Cloud#apply` writing it will raise `NoMethodError` in wave 1. Register it **in this
  card**, at `deployment/cloud.rb`'s tail via
  `Lain::Provider::HTTP::Configuration.register_provider_options(%i[ollama_api_key])` — the call is
  idempotent (`configuration.rb:32-35`). If T3 then registers it a second time and the suite goes
  red, the idempotence claim is wrong; stop and confirm before deleting either call.
- `Configuration`'s generated setter blanks a whitespace-only String to `nil`
  (`configuration.rb:39-41`). If a blank key therefore reaches the wire as `Bearer ` rather than
  being refused, the refusal is in the wrong object; stop and confirm.
- If `Ractor.shareable?` is false because the headers Hash is rebuilt per call, do **not** relax
  the deep-freeze spec — CLAUDE.md pins it. Memoize the frozen hash instead.

---

### T2 — Make the provider ask its deployment instead of assuming it is local   [wave 2] [risk: high]

**Depends on:** T1, T4, T5
**Files:** `lib/lain/provider/ollama.rb`, `spec/lain/provider/ollama_spec.rb`
**Reuse:** the existing `build_config(api_base:)` (`ollama.rb:436-440`) — it keeps its shape and
gains a delegation; `Provider::Anthropic#build_config` (`anthropic.rb:157`) as the precedent for a
provider composing its own config; `Admitted`'s three existing collaborator methods
(`ollama.rb:354-364`).
**Shared-file wiring:** none (the require block is T1's wiring diff, already applied).
**Reachable from:** `CLI::Backend#provider` (`backend.rb:199`), unchanged by this card — every
existing ollama chat, bench arm, and summarizer tier reaches the new code path with the `Local`
default and must behave identically.

The hinge. `#initialize` gains `deployment: Deployment::Local.new` **with that default**
(Correction 1). `build_config` asks the deployment to `apply` itself and then lets an explicit
`api_base:` override the base — one keyword, one meaning: "the base this deployment resolves to".
`capabilities`, `cache_profile` and `resolved_endpoint` delegate to the deployment.
`context_window_tokens` answers `nil` **without making a request** when the deployment says there
is no runner status to read. `#admission_width` is added as `Admitted`'s optional fourth
collaborator, forwarding the deployment's.

The class docstring's "deliberately absent" list (`ollama.rb:66-76`) is rewritten: it currently
argues from "free and local" and is wrong for half the arms this class now serves.

**Acceptance criteria:**

```gherkin
Scenario: a bare provider is still the local one, byte for byte
  When Provider::Ollama.new is constructed with no arguments
  Then its resolved endpoint is "http://localhost:11434"
  And its capabilities are exactly streaming, thinking and structured_output
  And its cache profile is CacheProfile::NO_CACHING

Scenario: a cloud provider dials ollama.com without being told to
  When Provider::Ollama.cloud is constructed with an api_key and no api_base
  Then its resolved endpoint is "https://ollama.com"

Scenario: an explicit api_base still overrides, on either deployment
  When Provider::Ollama.cloud is constructed with an api_key and api_base "https://staging.example"
  Then its resolved endpoint is "https://staging.example"

Scenario: the cloud arm never asks for loaded-runner status
  Given a cloud provider over a transport that records every call
  When context_window_tokens is asked for any model
  Then it answers nil
  And the transport received no process_status call

Scenario: the local arm still probes and still reports a served window
  Given a local provider whose /api/ps reports a resident runner at 32768
  When context_window_tokens is asked for that model
  Then it answers 32768

Scenario: the cloud arm declares a bounded width to the admission gate
  When a cloud provider is asked for its admission width
  Then it answers 1
  And a local provider answers nil
```
→ spec file: `spec/lain/provider/ollama_spec.rb`

**Escalation triggers:**
- `spec/lain/provider/ollama_spec.rb:49-54` asserts the arm "claims exactly what it can
  demonstrate" against the `CAPABILITIES` **constant**. Turning `#capabilities` into a delegation
  may make that example assert nothing. Rewrite it to assert against the *instance* for both
  deployments — do not delete it; it is the anti-lying-capability pin.
- `spec/lain/provider/ollama_parity_spec.rb` builds `described_class.new(transport:)` with no
  deployment. If the parity group goes red, the `Local` default is not actually inert — stop, the
  premise of this card is wrong.
- Roughly ten spec sites construct `Provider::Ollama.new(api_base:)` or `(config:)` directly
  (`ollama_recorded_spec.rb:156`, `http/connect_budget_spec.rb:56`,
  `http/stall_protection_spec.rb:526`, `seams/stall_under_reactor_spec.rb:259,349`,
  `ollama_streaming_spec.rb:478,520`, `vcr_ollama_posture_spec.rb:157`,
  `backend/summarizer_spec.rb:123`, `integration/provider/ollama_spec.rb:16`). All must stay green
  **unchanged**. If any needs editing, the `api_base:` keyword's meaning has drifted — stop.
- If `Metrics/ClassLength` or `Metrics/MethodLength` trips on `Provider::Ollama`, extract a
  collaborator; do not loosen the cop and do not move logic into the deployment that is not about
  *where the server is*.

---

### T3 — Teach the transport to carry a key, and to stop claiming it is local   [wave 2] [risk: medium]

**Depends on:** T1
**Files:** `lib/lain/provider/ollama/transport.rb`, create
`spec/lain/provider/ollama/transport_spec.rb`
**Reuse:** `Provider::HTTP::Providers::Bedrock:28-42` — the `#headers` + `configuration_options`
shape, verbatim in structure; `Provider::Admission::Endpoint.local?`
(`provider/admission/endpoint.rb:112-120`) for the locality answer, so there is exactly one
definition of "local" in the codebase; the existing `#api_base` (`transport.rb:119-121`).
**Shared-file wiring:** none.
**Reachable from:** `Provider::Ollama#initialize` builds `Transport.new(@config, sink:)`
(`ollama.rb:148`), reached from `CLI::Backend#provider`.

Add `ollama_api_key` to `configuration_options`; override the instance method `#headers` to return
a Bearer hash when the config carries a key and `{}` when it does not. **Delete the class-level
`local? = true`** and answer it per instance from the base URL the transport will really dial — a
class predicate cannot describe an object whose endpoint is a constructor argument, and the
current one becomes a straightforward lie the moment a cloud config exists.

`spec/lain/provider/ollama/transport_spec.rb` does not exist today; the transport is tested inside
`ollama_spec.rb`. Create it at the mirrored path per CLAUDE.md and move nothing — the new examples
are new behaviour.

**Acceptance criteria:**

```gherkin
Scenario: no key configured, no authorization header
  Given a transport over a configuration with no ollama_api_key
  When it is asked for its headers
  Then the result is empty

Scenario: a configured key rides on every request, completion and probe alike
  Given a transport over a configuration carrying an ollama_api_key
  When a chat request and an /api/show probe are each made
  Then both carry an Authorization header of "Bearer " followed by the key

Scenario: locality is answered from the endpoint, not from the class
  Given one transport configured at http://localhost:11434 and another at https://ollama.com
  Then the first answers local? true and the second answers local? false

Scenario: the embedder transport sends no authorization by default
  Given an Embedder::Ollama transport built with no key
  When it makes an embed request
  Then the request carries no Authorization header
```
→ spec files: `spec/lain/provider/ollama/transport_spec.rb`, plus the embedder example in
`spec/lain/embedder/ollama_spec.rb`

**Escalation triggers:**
- `Embedder::Ollama::Transport` **subclasses this class** (`embedder/ollama.rb:45`) and so inherits
  both `#headers` and the new `#local?`. `spec/lain/embedder/ollama_spec.rb:110-111` asserts
  `local?` today. If it asserts on the **class** rather than an instance it will not compile after
  the class method is removed — update it to assert the instance, and confirm the embedder's own
  spec still pins that it sends no key.
- `spec/lain/provider/admission_spec.rb:586-599` pins
  `Transport.new(Configuration.new).api_base == DEFAULT_API_BASE`. That must stay true — a bare
  transport with an empty configuration is still local. If this card makes it false, the fallback
  has moved somewhere it should not have.
- Do **not** add `ollama_api_key` to `configuration_requirements`. It is a class-level list
  (`http/provider.rb:134-136`) consulted by `Connection#ensure_configured!`, so requiring it would
  refuse every **local** connection. The refusal belongs in `Deployment::Cloud` (T1), where it can
  be per-deployment and can name the env var.
- Do **not** revive the positional `headers = {}` argument on `#sync_post`/`#stream`. It is dead
  everywhere and the provider's own headers win over it anyway; a card that starts passing it has
  taken the wrong seam.

---

### T4 — Let a caller declare a width for an endpoint locality cannot classify   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/provider/admission.rb`, `lib/lain/provider/admitted.rb`,
`spec/lain/provider/admission_spec.rb`, `spec/lain/provider/admitted_spec.rb`
**Reuse:** the existing three-way `.build` (`admission.rb:263-269`) and `.width_from_env`
(`:296-307`) — the precedence rule is extended, not replaced; `Admission::Null` stays the answer
for an undeclared hosted endpoint.
**Shared-file wiring:** none.
**Reachable from:** `Provider::Ollama#admission_width` (T2) -> `Admitted#admitted` ->
`Admission.for`, reached on every cloud round trip from `CLI::Backend::OllamaTier` (T8).

`Admission.for(endpoint:, width: nil)`, with precedence **env > declared > locality**: an operator
who has said a number has still said it about this process, a caller who knows its server's
capacity is believed next, and only silence from both lets `Endpoint.local?` decide. `Admitted`
gains `#admission_width` with a `nil` default in the mixin, so `Provider::Anthropic` — which also
includes it — is untouched.

The registry memoizes per canonical endpoint and pins whatever the first resolution decided
(`admission.rb:171-190`). A declared width inherits that: **first declaration wins**, which is
consistent with how the env is already pinned, and must be documented as such rather than
discovered.

**Acceptance criteria:**

```gherkin
Scenario: a hosted endpoint with a declared width is gated at that width
  Given no LAIN_PROVIDER_CONCURRENCY is set
  When an admission is taken for "https://ollama.com" with a declared width of 3
  Then the gate's width is 3 and a fourth concurrent caller waits

Scenario: a hosted endpoint with no declared width is still unbounded
  Given no LAIN_PROVIDER_CONCURRENCY is set
  When an admission is taken for "https://api.anthropic.com" with no declared width
  Then the gate is the Null arm and its width is infinite

Scenario: a local endpoint ignores a declared width
  When an admission is taken for "http://localhost:11434" with a declared width of 3
  Then the gate's width is 1

Scenario: the operator still wins in both directions
  Given LAIN_PROVIDER_CONCURRENCY is "0"
  When an admission is taken for "https://ollama.com" with a declared width of 3
  Then the gate is the Null arm

Scenario: the first declaration for an endpoint is the one that stands
  When two admissions are taken for the same endpoint declaring 3 and then 10
  Then both callers share one gate whose width is 3
```
→ spec files: `spec/lain/provider/admission_spec.rb`, `spec/lain/provider/admitted_spec.rb`

**Escalation triggers:**
- A local endpoint ignoring a declared width is a deliberate asymmetry, not an oversight: F26 is
  a one-slot local server and no caller may talk itself out of that. If an AC seems to want the
  declared width to win locally, stop — that is re-opening F26.
- `spec/lain/provider/ollama_spec.rb:577-582`'s `without_admission` helper resets the
  process-global registry around examples and its comment says "THE RESETS ARE LOAD-BEARING". If
  adding a parameter to `.for` makes any example order-dependent, the memoization key has changed
  and the registry is now keyed on something it must not be — stop.
- `Admission.build` is `private_class_method`. Keep it private; a card that makes it public to
  test it has stopped testing behaviour.

---

### T5 — Publish the cloud models' context windows instead of guessing 8,192   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/context_window.rb`, `spec/lain/context_window_spec.rb`
**Reuse:** `ContextWindow::DEFAULTS` (`context_window.rb:60-71`) and its documented
exact-then-longest-family-token matching; `PUBLISHED` provenance (`:141`), which `#resolve` already
assigns to any table hit (`:334`) and which `WindowResolution#authoritative?` accepts.
**Shared-file wiring:** none.
**Reachable from:** `CLI::Backend#context_window -> WindowBook::Live -> WindowBook::Source#book`,
which returns `ContextWindow.default` whenever the provider reports nil (`window_book.rb:275`) —
so the table is consulted on the real path for every cloud model with no provider change at all
(Correction 4).

Add rows for the Ollama Cloud catalogue. Keys must be **exact model ids**, not a shared `"cloud"`
family token: a substring token would match anything containing the word, and `DEFAULTS` is a
table shared with the Anthropic arms. Each row's number is what Ollama publishes for that model,
recorded with the date it was read — the file already describes itself as "a SNAPSHOT of a moving
catalogue [that] has now gone stale twice" (`:60-71`) and a new section must not pretend
otherwise.

**Acceptance criteria:**

```gherkin
Scenario: a cloud model resolves to a published window, not the guess
  When the default context window book resolves a shipped ollama cloud model id
  Then the window is that model's published size
  And the provenance is PUBLISHED
  And the resolution is authoritative

Scenario: an unknown cloud-shaped id still falls back honestly
  When the book resolves "some-model-nobody-shipped:7b-cloud"
  Then the window is the conservative fallback of 8192
  And the provenance is GUESSED

Scenario: adding cloud rows does not move any Anthropic answer
  When the book resolves each key that existed before this card
  Then every window and provenance is unchanged

Scenario: a cloud arm's window survives the whole launch path
  Given a backend configured for a shipped cloud model with a provider reporting no served window
  When the backend's context window book resolves that model
  Then the resolution is authoritative rather than a guess
```
→ spec files: `spec/lain/context_window_spec.rb`, and the launch-path scenario in
`spec/lain/cli/backend/window_book_spec.rb`

**Escalation triggers:**
- If any cloud model id contains a substring that `matched_key` would resolve to an existing
  Anthropic family token (`opus`, `sonnet`, `fable`, `mythos`, `haiku`), the two tables have
  collided and the shared-table assumption is wrong — stop and confirm before adding the row.
- If the published figure for a model cannot be established from Ollama's own model library, do
  **not** guess a number: omit the row and let it fall to `GUESSED`. `context_window.rb:106-111`
  is explicit that a number answering for names it knows nothing about cannot be evidence.

---

### T6 — Give the metered arm a response WAL   [wave 4] [risk: high]

**Depends on:** T2, T8
**Files:** `lib/lain/provider/ollama.rb`, `lib/lain/provider/ollama/retry_tap.rb`,
`lib/lain/cli/backend/ollama_tier.rb`, `spec/lain/provider/ollama/retry_tap_spec.rb`,
`spec/lain/provider/ollama_streaming_spec.rb`, `spec/lain/cli/backend/ollama_tier_spec.rb`
**Reuse:** `Provider::Anthropic::RetryTap` (`provider/anthropic/retry_tap.rb:28-36`) — the
`spool:` keyword and `Spool::RotatingFrame.new(spool:, request_digest:)` per round trip;
`Provider::Spool::Null` as the default so a caller with no chronicle is unaffected;
`Provider::ResponseWal`'s existing frame duck (`append`, `close(complete:)`).
**Shared-file wiring:** none.
**Reachable from:** `CLI::Wiring::AgentBuild.spooled_provider` (`wiring/agent_build.rb:191-192`)
calls `backend.provider(spool: chronicle.spool, channel:)` -> `CLI::Backend#provider` ->
`OllamaTier#provider`. **This card owns the forwarding line in `OllamaTier`** — without it the WAL
is built and never handed a chronicle, which is exactly the dormant-capability shape, and it would
ship green because every spec here injects its own spool.

`ollama.rb:75` states the absence and its reason: "no response WAL, so nothing on this arm is
salvageable after a crash", which was tolerable while a lost round trip cost nothing. On a
quota-metered arm a lost round trip is **spent**. Add `spool:` to `Provider::Ollama#initialize`,
thread it into `Ollama::RetryTap`, and rotate the frame on each retry so a retried stream cannot
concatenate onto the attempt it replaced — the F7b splice, in the spool rather than the assembler.

**Acceptance criteria:**

```gherkin
Scenario: a completed cloud round trip leaves a salvageable frame
  Given a cloud provider built with a real response WAL
  When one non-streaming request completes
  Then the WAL holds exactly one frame for that request digest, marked complete

Scenario: a retried stream does not splice two attempts into one frame
  Given a streaming request whose first attempt is severed and retried
  When the retry completes
  Then the WAL holds two frames for that request digest
  And the first is marked incomplete and the second complete

Scenario: a provider with no spool is unaffected
  When Provider::Ollama.new is constructed with no spool
  Then no WAL file is created and the round trip's bytes are unchanged

Scenario: the run's chronicle reaches the cloud provider, not a Null spool
  Given a backend built for the cloud arm with a real chronicle
  When the wiring builds its spooled provider
  Then the provider it receives holds that chronicle's spool
  And a completed request leaves a frame in the chronicle's WAL file
```
→ spec files: `spec/lain/provider/ollama/retry_tap_spec.rb`,
`spec/lain/provider/ollama_streaming_spec.rb`, `spec/lain/cli/backend/ollama_tier_spec.rb`

**Escalation triggers:**
- The stream assembler's `reset` is already registered on the attempt as the retried-stream
  discard (`ollama.rb:427-434`, the F7b fix). A frame rotation registered on the **same** attempt
  must not displace it — `ollama.rb:480-505` records that `retry_block` composes via `then_call:`
  for exactly this reason and that `||=` re-introduced the splice once. If the discard stops
  firing, stop: F7b is back.
- `CLI::Chronicle#spool` is one file per **session**, shared by the main agent and every subagent
  (`chronicle.rb:180`). If two ollama providers over one spool produce interleaved frames rather
  than one buffered frame per fiber, the `BufferedFrame` fiber test is not covering this path —
  stop and confirm before serialising anything.
- If wiring `spool:` through `OllamaTier` cannot be done without adding lines to `CLI::Backend`,
  stop: Correction 3 says there are none to add. `Backend#provider` already accepts `spool:` and
  already ignores it on the ollama arm, so the change is inside `OllamaTier` and nowhere else.

---

### T7 — Give the cloud deployment a rate-limit posture   [wave 2] [risk: medium]

**Depends on:** T1
**Files:** `lib/lain/provider/ollama/deployment/cloud.rb`,
`spec/lain/provider/ollama/deployment/cloud_spec.rb`
**Reuse:** `AnthropicWire#apply_rate_limit_backoff` (`anthropic_wire.rb:68-72`) as the shape —
two Configuration fields and nothing else; `Provider::HTTP::Connection::MiddlewareStack#retry_callbacks`
(`http/connection/middleware_stack.rb:152-162`), which `.compact`s, so a nil knob **falls back to
faraday-retry's own `RateLimit-Reset` handling rather than disabling it**.
**Shared-file wiring:** none.
**Reachable from:** `Deployment::Cloud#apply` is called from `Provider::Ollama#build_config` (T2),
reached from `CLI::Backend::OllamaTier` (T8).

`ollama.rb:71-73` states the absence: "rate-limit backoff — a local server sends no
`anthropic-ratelimit-*` headers, so there is nothing to read." Against a plan with three
concurrent models and two rolling quotas, a 429 is the ordinary case.

**The header vocabulary is unverified** (T12 settles it), and this card must not invent one.
Leaving both knobs nil is a *decision* here, not an omission: it selects faraday-retry's standard
`RateLimit-Reset` handling. What this card owns is that the decision is **stated in the deployment
and pinned by a spec**, and that the cloud arm's retry envelope (`max_retries`, `request_timeout`)
is the deployment's rather than the local arm's six-minutes-of-thinking budget.

**Acceptance criteria:**

```gherkin
Scenario: the cloud deployment states a retry envelope of its own
  Given a fresh configuration
  When Deployment::Cloud#apply is called on it
  Then request_timeout and max_retries read back the cloud values
  And they differ from the local deployment's

Scenario: the rate-limit knobs are left to faraday-retry's default, deliberately
  When Deployment::Cloud#apply is called on a fresh configuration
  Then rate_limit_reset_header and header_parser_block are both nil

Scenario: the local deployment's envelope is unchanged
  When Deployment::Local#apply is called on a fresh configuration
  Then request_timeout is 300 and max_retries is 3
  And rate_limit_reset_header and header_parser_block are both nil
```
→ spec file: `spec/lain/provider/ollama/deployment/cloud_spec.rb` and its `Local` sibling

Observing an actual 429 belongs to **T12**, not here: a WebMock 429 verifies faraday-retry rather
than this card's code, and what the endpoint really sends is one of the three facts this plan
refuses to assume.

**Escalation triggers:**
- If shortening the cloud `request_timeout` makes any existing stall-protection spec red
  (`spec/lain/provider/http/stall_protection_spec.rb`, `spec/lain/seams/stall_under_reactor_spec.rb`),
  the stall clock's 30s grace is being measured against the wrong budget — stop, because those
  specs encode the F10 fix.
- If T12 later finds Ollama sends a differently-named reset header, that is a follow-up card, not
  a reason to guess a name here. `anthropic_wire.rb:35-43` records the same open question for
  Anthropic and resolves it by naming the follow-up rather than guessing.

---

### T8 — Reach the cloud arm from the command line   [wave 3] [risk: high]

**Depends on:** T2, T3, T11
**Files:** create `lib/lain/cli/backend/ollama_tier.rb`,
`spec/lain/cli/backend/ollama_tier_spec.rb`; modify `lib/lain/cli/backend.rb`, `exe/lain`,
`spec/lain/cli/backend_spec.rb`, `spec/provider_construction_discipline_spec.rb`
**Reuse:** `CLI::Backend::Endpoint`, `NumCtx`, `Ceiling`, `Summarizer` — the established pattern of
a `backend/` collaborator owning one flag's whole meaning; `CLI::EnvDefaults.string`/`.boolean`
for the Thor default slot; `CLI::Backend::MissingAPIKey` (`backend.rb:30`), the existing error for
"this provider needs a key and it is not set".
**Shared-file wiring:** none — `lib/lain/cli/backend.rb` already requires `backend/*`.
**Reachable from:** `exe/lain chat --provider ollama --cloud` -> `CLI::ChatLaunch` ->
`CLI::Backend#provider` (`backend.rb:199`) -> `OllamaTier#provider` -> `Provider::Ollama.cloud`.
This is the card that makes every other card in the chunk reachable; nothing here is deferred.

`OllamaTier` owns what `--cloud` means: which deployment, where the key comes from, and the
refusals. `CLI::Backend`'s `when "ollama"` arm becomes a **net-zero-line** delegation to it
(Correction 3 — there is no headroom to add a line).

Three refusals, all at construction, before the chronicle opens — the posture `#api_base` and
`#num_ctx` already take (`backend.rb:143-149`):

1. `--cloud` with `OLLAMA_API_KEY` unset -> `MissingAPIKey`, naming the variable and
   `ollama.com/settings/keys`.
2. `--cloud` with a provider that is not `ollama` -> a refusal naming both flags. A boolean flag
   nothing reads is the shape this repo has been deleting (Open decision 4); the refusal is what
   makes this one different.
3. `--cloud` with an `--api-base` that is not https -> a refusal. A subscription key sent over
   plaintext http is an exfiltrated key, and `Endpoint` validates shape only, by design.

**Acceptance criteria:**

```gherkin
Scenario: the cloud arm is reachable from the real launch path
  Given OLLAMA_API_KEY is set
  When a backend is built with provider "ollama" and the cloud flag
  Then the provider it builds resolves the endpoint "https://ollama.com"
  And that provider carries the run's journal

Scenario: the local arm is untouched by this card
  When a backend is built with provider "ollama" and no cloud flag
  Then the provider it builds resolves "http://localhost:11434"
  And its construction is byte-identical to the one before this card

Scenario: the cloud flag refuses a provider that would ignore it
  When a backend is built with provider "anthropic" and the cloud flag
  Then it raises before the chronicle opens, naming both --provider and --cloud

Scenario: the cloud flag refuses to run without a key
  Given OLLAMA_API_KEY is unset
  When a backend is built with provider "ollama" and the cloud flag
  Then it raises MissingAPIKey naming OLLAMA_API_KEY

Scenario: the cloud flag refuses a plaintext endpoint
  Given OLLAMA_API_KEY is set
  When a backend is built with the cloud flag and --api-base "http://ollama.example"
  Then it raises, naming the key as the reason https is required

Scenario: the default model differs by deployment
  When a cloud backend is built with no --model
  Then the model is the cloud default, not qwen3:4b

Scenario: a cloud backend's provider really is gated at the declared width
  Given a cloud backend built with no LAIN_PROVIDER_CONCURRENCY set
  When two of its round trips overlap against the cloud endpoint
  Then the second waits for the first rather than running beside it
  And a local backend's two round trips behave exactly as they did before this chunk
```
→ spec files: `spec/lain/cli/backend/ollama_tier_spec.rb`, `spec/lain/cli/backend_spec.rb`

**Escalation triggers:**
- **Measure `Metrics/ClassLength` on `CLI::Backend` before and after.** It is at 110/110. If the
  delegation adds even one line, extract further — do not loosen the cop, and do not put the new
  logic anywhere that makes `Backend` grow.
- The construction-discipline allowlist has a hard ceiling of three file keys and six entries
  (`provider_construction_discipline_spec.rb:487`). Moving `Provider::Ollama` out of
  `backend.rb` and into `ollama_tier.rb` with two entries lands at **3 keys / 5 entries** — at the
  key ceiling exactly. If a fourth file is needed, stop: the ceiling exists to force that
  conversation rather than absorb it.
- The allowlist is keyed by class as well as file, and the cloud entry must say in its own words
  that this is a *hosted* provider — the second `secret_read.rb` entry's whole point is that
  naming the class is what refuses a hosted one at the site that could introduce it.
- `--num-ctx` and `--num-batch` are ollama-server knobs. If they reach the cloud payload's
  `options` object and the endpoint rejects them, that is a real finding, not a wiring bug — stop
  and record it rather than silently stripping them.

---

### T9 — A tag for a spec that spends somebody's quota   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `spec/support/ollama_cloud_tag.rb`; modify `spec/network_posture_spec.rb`
**Reuse:** `spec/support/tags.rb`'s `:api_integration` gating idiom (two conditions: an opt-in env
var **and** a key present) and `ExampleNetwork.permit`, which moves both the WebMock and the VCR
switch; `spec/support/ollama_tag.rb` for the skip-not-fail reachability shape.
**Shared-file wiring:** none — `spec/spec_helper.rb` globs `support/**/*.rb` already.
**Reachable from:** T12's live seam is the only consumer; the tag itself is test infrastructure,
not a production capability.

`:ollama` is the wrong tag and reusing it would be a category error. Its own header says the
distinction: ":ollama examples cost no money" and it probes **localhost** for reachability. A
cloud example spends quota against somebody's subscription and needs a key — which is
`:api_integration`'s posture. Add `:ollama_cloud`, excluded by default, requiring
`LAIN_OLLAMA_CLOUD=1` **and** `OLLAMA_API_KEY`.

**Acceptance criteria:**

```gherkin
Scenario: cloud examples are excluded by default
  Given neither LAIN_OLLAMA_CLOUD nor OLLAMA_API_KEY is set
  When the suite runs
  Then every :ollama_cloud example is excluded
  And the suite reports why, as the :ollama tag already does

Scenario: the opt-in needs both halves
  Given LAIN_OLLAMA_CLOUD is "1" and OLLAMA_API_KEY is unset
  When the suite runs
  Then :ollama_cloud examples are still excluded

Scenario: an untagged example still cannot reach the network
  When an untagged example attempts an outbound request to ollama.com
  Then WebMock refuses it
```
→ spec file: `spec/network_posture_spec.rb` (which already holds the untagged offline-default
guards for `:ollama`, and its header explains why they live there rather than in the tag file)

**Escalation triggers:**
- If `filter_run_excluding` for the new tag interacts with the `:ollama` exclusion such that a
  local `:ollama` example starts skipping under `LAIN_OLLAMA=1`, the two tags are not independent
  — stop; that would silently drop the free arm's live coverage.
- Do not let a cloud example record a cassette carrying the key. `spec/support/vcr_configuration.rb`
  has a `before_record` redaction; confirm it covers an `Authorization` header before T12 records
  anything.

---

### T10 — Run the cloud arm through the seven correctness gates   [wave 3] [risk: low]

**Depends on:** T2, T3
**Files:** `spec/lain/provider/ollama_parity_spec.rb`
**Reuse:** `spec/support/shared_examples/provider_parity.rb` — the "a Lain::Provider" group that
Mock, Anthropic, Bedrock and local Ollama already satisfy; `OllamaWire.queue_transport`
(`spec/support/ollama_wire.rb`), which replays canned `Lain::Response`s through the **real** decode
path with no network.
**Shared-file wiring:** none.
**Reachable from:** this card verifies the arm T8 constructs; it builds no production capability of
its own.

The design plan's own gate: "a new backend cannot land half-working"
(`~/.claude/plans/jiggly-greeting-avalanche.md:336`). The cloud arm shares the local arm's encoder
and decoder, so the group should pass unchanged — which is exactly why it is worth running: if it
does not, the deployment split has leaked into the wire path, and that is the one thing this chunk
promised it would not do.

**Acceptance criteria:**

```gherkin
Scenario: the cloud deployment satisfies every provider gate the local one does
  When the "a Lain::Provider" shared group runs against a cloud-deployment provider
  Then all seven correctness gates pass
  And the declared capabilities are a subset of Provider::CAPABILITIES

Scenario: both deployments encode one request to identical bytes
  Given the same Lain::Request
  When a local provider and a cloud provider each encode it
  Then the two payloads are byte-identical
```
→ spec file: `spec/lain/provider/ollama_parity_spec.rb`

**Escalation triggers:**
- The byte-identical encode is the chunk's central claim and the bench's whole reason for the arm.
  If the two payloads differ **at all**, stop — something deployment-shaped has reached
  `Ollama::Encoding`, and the provider axis is no longer isolating one variable.

---

### T11 — Make the construction guard see a factory, not just `.new`   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `spec/provider_construction_discipline_spec.rb`
**Reuse:** the file's own Ripper walk and its `APPROVED` / `UNJOURNALED` tables; the header's
stated reason for parsing rather than grepping (`:16-23`).
**Shared-file wiring:** none.
**Reachable from:** this card guards T8's production construction site; it must land **before**
T8 introduces the first `Provider::Ollama.cloud` in `lib/`.

The detector matches `.new` on a provider constant, deliberately, so that a constant read is not
mistaken for a construction. A factory constructor is invisible to it — so the moment `lib/`
contains `Provider::Ollama.cloud(...)`, the file it lives in silently stops being covered by the
allowlist. Teach the walk that a call to a **provider-constructing factory** counts as a
construction.

The safe shape is a named list of factory selectors (`new`, `local`, `cloud`) rather than "any
method on a provider constant" — the latter would classify `Provider::Ollama::DEFAULT_MODEL` reads
and `Provider::Mock.new` exclusions incorrectly and is the false-positive direction the header
already worries about.

**Acceptance criteria:**

```gherkin
Scenario: a factory construction outside the allowlist fails the guard
  Given a source fixture calling Provider::Ollama.cloud in a file the allowlist does not name
  When the discipline walk runs over it
  Then it reports a violation naming that file and Provider::Ollama

Scenario: a constant read is still not a construction
  Given a source fixture reading Provider::Ollama::DEFAULT_MODEL
  When the walk runs over it
  Then it reports no violation

Scenario: a mention inside a comment is still not a construction
  Given a source fixture whose comment names Provider::Ollama.cloud
  When the walk runs over it
  Then it reports no violation

Scenario: the guard still covers every site it covered before
  When the walk runs over the real lib/ tree
  Then the two pre-existing approved constructions are still detected
```
→ spec file: `spec/provider_construction_discipline_spec.rb`

**Escalation triggers:**
- If the walk cannot distinguish `Provider::Ollama.cloud` from a same-named method on an unrelated
  receiver without resolving constants, stop and confirm the selector list rather than widening
  the match — a guard with false positives gets excused, and an excused guard is the failure mode
  the file's header names.

---

### T12 — Settle the three unverified cloud facts against a live key   [wave 4] [risk: medium]

**Depends on:** T8, T9
**Files:** create `spec/integration/provider/ollama_cloud_spec.rb`; modify
`references/ollama/INDEX.md`, create `references/ollama/cloud.md`
**Reuse:** `spec/integration/provider/ollama_spec.rb`'s four-layer shape (smoke, determinism, a
live `Lain::Agent` turn with `EchoTool`, a refusal); `MockRecording`'s `EchoTool`;
`spec/support/vcr_configuration.rb`'s `before_record` redaction.
**Shared-file wiring:** none.
**Reachable from:** verification of the arm T8 constructs. The **reference document is the
deliverable** — the spec is opt-in and will not run in CI.

Answer, on the wire, the three questions this plan refused to assume:

1. Does `/api/show` answer on `ollama.com`, and if so is its `context_length` the served window or
   a trained maximum? (Governs whether T5's table can ever be replaced by a probe.)
2. Does the native cloud path return rate-limit headers, under what names? (Governs T7's
   follow-up.)
3. Does it prompt-cache — is there any signal in the response that input was cached? (Governs
   Open decision 1.)

Record every answer in `references/ollama/cloud.md` in the house style of
`references/ollama/api-chat.md`: verbatim evidence, dated, with what is inferred marked as
inferred. A negative answer is a result and gets written down.

**Acceptance criteria:**

```gherkin
Scenario: a live cloud chat completes end to end
  Given LAIN_OLLAMA_CLOUD=1 and a valid OLLAMA_API_KEY
  When a cloud provider completes one non-streaming request
  Then a Response comes back with content and a stop reason

Scenario: a live cloud tool-call turn drives the real agent loop
  Given the same
  When a Lain::Agent runs one turn with EchoTool against a cloud model
  Then the tool is called and the turn ends

Scenario: an unauthenticated request is refused, loudly and legibly
  Given a cloud provider built with a syntactically valid but wrong key
  When it completes a request
  Then it raises a provider error whose message names the authentication failure

Scenario: a rate-limited request is retried rather than surfacing on the first attempt
  Given a cloud provider driven past its plan's concurrency allowance
  When a request receives a rate-limit refusal
  Then a provider retry is journaled naming the status
  And the header names the endpoint returned are recorded in the reference document

Scenario: the three open questions are answered in the reference corpus
  When references/ollama/cloud.md is read
  Then it states, with dated evidence, whether /api/show answers on the cloud host
  And whether rate-limit headers are returned and under what names
  And whether any cached-input signal appears in the response
```
→ spec file: `spec/integration/provider/ollama_cloud_spec.rb`

**Escalation triggers:**
- If `/api/show` on the cloud host returns a **trained maximum** rather than a served window, it
  must not be wired into `context_window_tokens` — `ollama.rb:239-260` and
  `provider.rb:81-106` both refuse that number as a denominator, and the 8x over-estimate they
  describe is the failure mode. Record it and stop.
- If any assertion is flaky against a live model, pin the invariant that is actually true and say
  so in `cloud.md`; do **not** mark the example pending. The `:ollama` tag's own history
  (`code-review-ollama-test-infra.md` T21) records that a false determinism claim poisons every
  bench conclusion built on it.
- Confirm `RateLimitError` is in `MiddlewareStack#retry_exceptions` before asserting the retry.
  If it is not, a rate-limit refusal raises on the first attempt, and widening the vendored retry
  list changes **every** provider's behaviour — stop and confirm rather than widening it.
- If the key is not available when this card runs, the reference document's four questions are
  **blocked, not skippable**. Stop and escalate rather than writing "unverified" into `cloud.md`
  and calling the card done.

---

### T13 — Say, in the places a reader looks, that ollama is now two arms   [wave 5] [risk: low]

**Depends on:** T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T14, T15
**Files:** `ARCHITECTURE.md`, `README.md`, `DEBUGGING_OLLAMA.md`, `ROADMAP.md`,
`planning/README.md`, `references/ollama/INDEX.md`
**Reuse:** the existing ollama sections in each; `ROADMAP.md`'s numbered-item format (items
30–36) and `planning/README.md`'s spec table.
**Shared-file wiring:** none.
**Reachable from:** documentation of shipped behaviour; builds no capability.

Also correct the two stale line references this plan's grounding found: `admission.rb:213` and
`spec/lain/provider/admission_spec.rb:429,534` all cite `oracle/secret_read.rb:134` for a
`def self.tier` that is now at line 140.

**Acceptance criteria:**

```gherkin
Scenario: the provider axis names both ollama arms
  When ROADMAP.md's swept-axes table is read
  Then the Provider / model row names local ollama and cloud ollama as distinct arms

Scenario: the operator instructions are complete enough to run the arm
  When README.md's provider section is read
  Then it states the flag, the environment variable, and where a key comes from

Scenario: the stale references are corrected
  When the three citations of oracle/secret_read.rb:134 are read
  Then each names the line def self.tier actually occupies
```
→ **no spec file, by design** — this card changes only prose. Stated deviation from the normal
rule that every AC names a spec file; verified by integration check 8 and by review.

**Escalation triggers:**
- If `ARCHITECTURE.md`'s provider section states the "one round trip, never a loop" contract in
  terms that assume a local ollama, the correction belongs here and not in a follow-up — it is the
  document a reader is pointed at first.

---

### T14 — Pin the loopback guarantee against the seam this chunk introduces   [wave 3] [risk: medium]

**Depends on:** T2
**Files:** `spec/lain/oracle/secret_read_spec.rb`, `spec/lain/provider/ollama_spec.rb`
**Reuse:** `secret_read_spec.rb`'s existing decorator-peeling `terminal` helper (`:25-53`) and the
`have_received(:new).with(no_args)` pin (`:121-127`); the module header's own statement of the
guarantee (`secret_read.rb:17-40`).
**Shared-file wiring:** none.
**Reachable from:** guards the production construction at `oracle/secret_read.rb:142`, which this
card deliberately leaves **unmodified**.

`lib/lain/oracle/secret_read.rb` is not edited by this chunk — that is the point (Correction 1).
What changes underneath it is that `Provider::Ollama.new` now has a `deployment:` keyword with a
default, and a default is exactly the kind of thing that can be changed later without anyone
noticing. So the guarantee moves from "no api_base is passed" to "the default deployment is the
local one", and gets a spec that says so in those words.

**Acceptance criteria:**

```gherkin
Scenario: a provider constructed with no arguments behaves as a loopback one
  When Provider::Ollama.new is constructed with no arguments
  And it completes one request
  Then the request went to http://localhost:11434
  And it carried no Authorization header

Scenario: the secret-read judge is still constructed with no arguments at all
  When Oracle::SecretRead.tier is built
  Then Provider::Ollama received new with no arguments
  And the provider that reached Oracle::Model resolves a loopback endpoint

Scenario: the secret-read judge cannot be pointed at the cloud
  When Oracle::SecretRead.tier is built with OLLAMA_API_KEY set in the environment
  Then the provider that reached Oracle::Model still resolves http://localhost:11434
  And it sends no Authorization header

Scenario: the tier still takes no seam that could move it
  When SecretRead.tier's parameter names are reflected on
  Then they are exactly model and journal
```
→ spec file: `spec/lain/oracle/secret_read_spec.rb`

**Escalation triggers:**
- The third scenario is the one that matters and it must be genuinely non-vacuous: if
  `OLLAMA_API_KEY` being set could **never** have affected the bare construction, say so and keep
  the example anyway as a regression pin — but if it **can**, an ENV default has been added
  somewhere in this chunk and that is a stop-the-line finding, not a spec to adjust.
- Do not add a keyword to `SecretRead.tier` to make any of this testable. The fourth scenario is
  the existing pin and it fails on any added keyword, by design.

---

### T15 — Refuse to quote a dollar figure this arm does not have   [wave 1] [risk: low]

**Depends on:** none
**Files:** `spec/lain/friction/report_spec.rb`, `spec/lain/ledger_spec.rb`,
`lib/lain/price_book.rb` (comment only, if the behaviour is already correct)
**Reuse:** `Friction::Report#figure_phrase` (`friction/report.rb:317-335`), which already
"withholds a dollar figure that has nothing priceable behind it";
`CLI::Backend::COMPACTION_PRICES` (`backend.rb:111-112`), the existing zero-fallback book that
proves the crash is real elsewhere; `PriceBook`'s own reasoning that "a guessed row is worse than
a loud refusal" (`price_book.rb:70-75`).
**Shared-file wiring:** none.
**Reachable from:** `lain friction` over a session recorded on an ollama arm — the existing
production path, exercised with an ollama model id.

Ollama Cloud is billed by subscription: the marginal per-token dollar cost is **zero** and the
real currency is quota. lain has no quota concept and this chunk does not invent one (Open
decision 2). What it must do is make sure the arm neither **fabricates** a dollar figure nor
**crashes** trying to produce one — and today it is unclear which happens, because
`PriceBook::DEFAULT` has no ollama row and no fallback, so `#price` raises `UnknownModel`, while
`Friction::Report` claims to withhold gracefully.

Establish which it is. If the withholding already works, this card is two characterisation specs
and a comment recording the ruling. If it raises, fix it — and the fix is withholding, **not** a
zero row in the shared `DEFAULTS` table, which would state a price for the local arm too.

**Acceptance criteria:**

```gherkin
Scenario: a friction report over an ollama session states tokens and no dollars
  Given a recorded session whose payments name an ollama model
  When lain friction reports on it
  Then the report states token figures
  And it states no dollar figure
  And it does not raise

Scenario: the shared price table still refuses an unknown model loudly
  When PriceBook::DEFAULT is asked to price an ollama model directly
  Then it raises UnknownModel naming the model
```
→ spec files: `spec/lain/friction/report_spec.rb`, `spec/lain/ledger_spec.rb`

**Escalation triggers:**
- If making the report withhold requires giving `PriceBook::DEFAULT` a fallback, **stop**. A
  fallback on the shared default book silently prices every unknown Anthropic model too, which is
  the exact failure `price_book.rb:60-75` records for `claude-fable-5` and `claude-mythos-5`. The
  withholding belongs at the report, where the caller knows it is asking about an unpriceable arm.
- If a session on an ollama arm turns out to raise on `lain friction` **today**, that is a
  pre-existing defect this card discovered rather than caused. Record it as a finding with its
  reproduction before fixing it.

---

## Integration checks

After the last wave:

1. `bundle exec rake pspec` — **15368 examples plus this chunk's additions, 0 failures, 15
   pending.** Check the example **count**, not just the failure count: `parallel_tests` reports
   only the examples that survived.
2. `bundle exec rubocop` (bare — never naming a config file on the command line) and
   `bundle exec rake compile` clean. **Explicitly re-measure `Metrics/ClassLength` on
   `CLI::Backend`**, which entered this chunk at 110/110.
3. `pre-commit run --all-files`.
4. `bundle exec rake spec:flakes` — 16 whole-suite runs in random orders. T4 changes a
   process-global memoized registry and T9 adds a tag that alters suite-wide exclusion; both are
   order-sensitive by construction. Record any new flake **by name**, never by line number.
5. **Local arm, live and unchanged:** `LAIN_OLLAMA=1 bundle exec rspec spec/integration/provider/ollama_spec.rb`
   with `ollama serve` up and `qwen3:4b` pulled. This is the regression check that matters most —
   the whole chunk claims the local arm is untouched.
6. **Cloud arm, live (human, needs a key):**
   `LAIN_OLLAMA_CLOUD=1 OLLAMA_API_KEY=... bundle exec rspec spec/integration/provider/ollama_cloud_spec.rb`,
   then an interactive `exe/lain chat --provider ollama --cloud`. Confirm by eye that the
   status line reports an **authoritative** window rather than 8,192, and that a tool-calling turn
   completes.
7. **Byte-identity spot check (human):** encode one identical `Request` through both deployments
   and diff the payloads. This is the chunk's central claim and deserves one manual confirmation
   outside its own spec.
8. **Docs check (T13, which has no spec):** `ROADMAP.md`'s provider-axis row names both ollama
   arms; `README.md` names the flag, the env var, and where a key comes from; the three stale
   `oracle/secret_read.rb:134` citations name the right line.
9. **A manual QA scenario** for the cloud arm added under `planning/qa/scenarios/`, in the shape
   `planning/qa/README.md` describes — the arm is not exercised by any default-on suite, so
   without a scenario it has no standing verification at all.

## Execution log

Appended during `/execute-plan`. Records decisions taken against the plan as written, so a
reader of the history does not have to reconstruct them from card diffs.

### Card status — ALL LANDED

| card | wave | commit |
|---|---|---|
| T15 | 1 | `afb1967a` — closed as "already correct"; characterisation only |
| T5 | 1 | `e77b57bd` — 23 cloud windows |
| T9 | 1 | `8369aa67` — tag + host-scoped probe stubs |
| T11 | 1 | `62008649` — factory selectors + singleton pin |
| T1 | 1 | `60e72693` — absorbed T7; two probe predicates |
| T4 | 1 | `0568fbf5` — declared width, supersession gated four ways |
| T3 | 2 | `939cb317` — bearer on the wire; control-char refusal |
| T2 | 2 | `2c33e429` — the provider asks its deployment |
| T10 | 3 | `135bfbc9` — cloud arm through the parity gates |
| T14 | 3 | `55752c86` — the loopback guarantee, pinned forward |
| T8 | 3 | `4ae438a4` — `--provider ollama-cloud`, reachable |
| T12 | 4 | `0383b810` — the wire settled, `references/ollama/cloud.md` |
| T6 | 4 | `31f2a1c8` — response WAL, frames carrying bytes |
| T13 | 5 | `ce6580ba` — both arms documented, determinism caveat |
| T7 | — | folded into T1 |

Four commits belong to no card, all defects review found rather than a failing suite:
`4d1d389f` (a differ walking ivars rendered the live bearer into rspec output), `fd5cfa29` (a
comment claiming a guard a returned Hash escapes), `e827ce7b` + `94fbdef2` (three `CLOUD_WINDOWS`
rows over-claiming against their trained maxima, one by 3.8x), plus `79bdcdfd` (the local arm's
open temperature-0 defect, named).

**Integration checks: all nine pass.** Suite **15749 / 0 failures / 15 pending**, identical across
five seeds. Bare rubocop clean at 1387 files; `CLI::Backend` at 109/110, *below* its pre-chunk
baseline. `pre-commit run --all-files` green. Local arm live: 3/4, the fourth a pre-existing
known-red. **Cloud arm live: 7/7 against a real key.** Byte-identical encode confirmed by hand.

Check 4 was run as five seeded full-suite passes rather than `rake spec:flakes`, which exits 1 on
every invocation for reasons unrelated to this chunk (`docs/toolchain-traps.md`).

### What this chunk actually cost, and what it bought

Thirteen cards, **every one needing at least one fix round; exactly one approved unchanged (T10)**.
The panel found what green suites did not, and the findings clustered into two shapes:

**A guarantee stated in prose and enforced by nothing** — seven instances, six caught by mutation.
See the table below.

**A spec that runs a different code path than its name claims** — T6's `stream: true` default meant
three examples named "non-streaming" were streaming, and AC 1 had zero real coverage. **Mutation
cannot catch this**: a mutant only reports on paths some example already drives.

Four credential-leak paths were closed, none of which a suite could have failed on: `pretty_print`
un-redacted, a mixed-state Configuration pairing one deployment's base with another's key, an
interior CR/LF escaping every rescue with the key in the message, and a differ walking instance
variables. The pattern across all four: redaction had been applied to the **printers** and the
leaks came through the **walkers**.

### Decision 1 — the arm is selected by `--provider ollama-cloud`, not by `--cloud`

**Supersedes Open decision 4.** The panel overturned it on an argument the plan did not consider:
`lain bench arms` and `lain bench record` build their `CLI::Backend` from *closed literal maps*
(`ARMS_FLAGS`, `exe/lain:496`; `RECORD_FLAGS`, `exe/lain:424`), neither of which carries a
`:cloud` key. A boolean `--cloud` is therefore **silently dropped by the bench**, which sweeps the
local arm instead — and the Intent's stated reason for the whole chunk is the bench case.

`--provider ollama-cloud` costs one entry in `Backend::PROVIDERS` and is forwarded by both flag
maps for free. Consequences for T8: its AC 3 (the cross-flag refusal) **disappears**, and with it
the fifth eager call in `Backend#initialize` that AC 3 would have required — which is what
Correction 3's 110/110 `Metrics/ClassLength` budget could not have absorbed. T8 still owes the
`MissingAPIKey` refusal, the https refusal, and the per-deployment default model.

### Decision 2 — T7 is folded into T1

T7's Files are `deployment/cloud.rb` and its spec, both **created by T1**, and its content
(`request_timeout`, `max_retries`, `#apply`) is already inside T1's declared message set. A wave-2
card that adds nothing to a wave-1 card's file is scheduling overhead and a merge hazard. T1 took
its three ACs.

One correction to T7's rationale, verified against faraday-retry 2.4.0 (`Gemfile.lock:129`): the
`.compact` in `MiddlewareStack#retry_callbacks` is **inert**. faraday-retry coalesces nil to its
default at read time (`middleware.rb:221`), so passing nil is byte-identical to omitting the key.
T7's ACs asserting `nil == nil` on a fresh Configuration would have pinned nothing; the decision
is recorded as a comment in `Deployment::Cloud` instead.

### Decision 3 — `/api/show` is a second probe the plan missed, and T1 gates it

`CLI::Backend#initialize` (`backend.rb:143-148`) eagerly calls `num_ctx`; `NumCtx#tokens`
(`backend/num_ctx.rb:73`) is `@value && refuse_above_trained(...)` → `trained_maximum` (`:91-97`)
→ `provider.trained_context_tokens` → `Ollama::Transport#model_details`, a **POST to `/api/show`**.
So `--num-ctx N` on a cloud arm dials `https://ollama.com/api/show` at launch, before the
chronicle opens — an endpoint the Grounding **explicitly refuses to assume answers**.

T2's `runner_status?` gates only `/api/ps`. T1 gained a second predicate for model metadata, false
on `Cloud`. The two are kept separate deliberately: `/api/ps` is a loaded runner, `/api/show` is
the weights' trained maximum.

### Decision 4 — the probe stubs are host-unscoped, and T9 owns the fix

The Grounding's claim that "a cloud provider that probed would reach VCR's gate unstubbed" is
**false**. `spec/support/ollama_probe.rb` registers `stub_request(:get, %r{/api/ps})` and
`stub_request(:post, %r{/api/show})` — regexes over the whole normalized URI, **not host-scoped** —
so a probe to `ollama.com` is matched and answered. The one mechanism meant to make an accidental
cloud probe loud is what silences it, and T9's AC 3 is not true today for those two paths.

`spec/support/ollama_probe.rb` added to T9's Files. The stubs must scope to the local base
(honouring `OLLAMA_API_BASE`), keep the match-time cassette-yielding predicate, and move no
existing measurement.

### Decision 5 — T15 lands as characterisation, not as a change

The panel argued for cutting T15 on the grounds that both ACs were already green. They were:
`lain friction` over an ollama session withholds gracefully via
`cache_waste.rb:500-503` → `:366` → `report.rb:326`/`:301`, and `PriceBook::DEFAULT` still raises
`UnknownModel` naming the model. That is a planning critique, not a reason to discard finished,
correct work: the card converts an unverified assumption into a pin, at the cost of six examples,
one comment and **zero production change**. It lands.

### CORRECTION 3's premise about `spool:` was FALSE (found by T6)

Correction 3 and T6's card both assert that `Backend#provider` "already accepts `spool:` and
already ignores it on the ollama arm, so the change is inside `OllamaTier` and nowhere else."

It did not. It **bound** `spool:` and dropped it, so without a one-keyword change at the call site
the WAL never reached the arm at all — and exactly **1 of 297 examples** noticed. T6 measured this
and made the change, correctly, outside its stated Files list. Recorded here so a later card does
not inherit the premise; the escalation trigger forbade *adding lines*, and a keyword on an
existing call adds none.

### Follow-ups owed, none blocking this chunk

1. **`Provider::Anthropic`'s transport closes its frame only on the success path.**
   `ResponseWal::BufferedFrame#close` is the sole route to `flush_buffered`, so an unclosed
   buffered frame is not an incomplete record — it is **no record**. Anthropic is the arm most
   likely to have a subagent holding the streaming slot. The two transports now disagree about
   termination, with the ollama side carrying a comment explaining why the other is wrong. That
   asymmetry wants a card, not a comment.
2. **`Cloud#model_metadata?` is `false`, so the cloud arm performs no `--num-ctx` refusal**, even
   though `/api/show` is now measured to answer. A one-line flip, with `references/ollama/cloud.md`
   as its grounding and a live example already pinned so it has something to turn red.
3. **`num_predict` is unreachable from a `Request`** — there is no way to cap output cost on
   *either* ollama arm. `max_tokens` on a Context is decorative here, which bit T12's own spec.
4. **`rake spec:flakes` exits 1 on every invocation** — `bin/spec-flakes` rewrites `$HOME`/`XDG_*`
   per forked run, colliding deterministically with six examples. It cannot serve as a gate until
   its isolation stops fighting the specs that assert on the variable it rewrites.
5. **A `references/ollama/` catalogue snapshot**, so the next window refresh is a diff rather than
   a re-sweep.

### A second defect shape, distinct from the prose-guarantee one (found by T6's panel)

**A spec that runs a different code path than its name claims.** `Request` defaults `stream: true`,
so every T6 example omitting `stream:` ran the STREAMING path — including three named
"non-streaming". AC 1 had zero real coverage: stripping `wal_frame:` from the sync context wrote a
**zero-byte frame marked complete** while 296 of 297 examples stayed green.

**Mutation testing cannot catch this**, and that is the point worth carrying forward: a mutant only
reports on paths some example already drives, so it proves what the code does and never that a spec
exercises the path its name claims. The fingerprint was in the evidence — the mutant meant to prove
the sync path had been measured against a mutation of *both* paths, so its failure count did not
match its name.

### Correction to the allowlist arithmetic (bears on T8)

`APPROVED` is `{path => {constant => reason}}` and normalizes every spelling of a class to one
constant string, so two constructions of `Provider::Ollama` in one file collapse to **one entry**.
The plan's "3 keys / 5 entries" is wrong: moving `Provider::Ollama` out of `backend.rb` into
`ollama_tier.rb` lands at **3 keys / 4 entries**, against ceilings of 3 and 6. T8's escalation
trigger demanding a distinct cloud entry "in its own words" describes a row that is not
representable — drop it. The key ceiling is still reached exactly, so the conversation that
ceiling exists to force still happens.

### Decision 6 — the three unverified cloud facts are measured, not assumed

Settled 2026-08-24 against a live key, two requests, `gpt-oss:20b-cloud`. Full evidence and the
exact header set are recorded for T12; the rulings that follow:

- **`/api/show` answers on `ollama.com`** (HTTP 200) but returns `gptoss.context_length: 131072` —
  128Ki of GGUF **architecture metadata**, i.e. the trained maximum, not a served window. This is
  the case T12's escalation trigger names, and the ruling stands: it must never become a
  denominator. It IS the right source for `trained_context_tokens`, which exists to refuse a
  `--num-ctx` above what the weights allow. **T5's table is vindicated and cannot be replaced by a
  probe** — the probe says 131,072, the published label says "128K", T5 recorded 128,000, and the
  conservative figure is the correct one to denominate with.
- **No rate-limit headers on a 200**, on either endpoint. Stated precisely: absence on success does
  **not** prove absence on a 429, and forcing a real 429 remains T12's job. What it settles is that
  T7's nil knobs need no follow-up card to name a header. `x-request-id` is present on every
  response and is the field worth journaling on a cloud error.
- **No cached-input signal** in the native response — only `prompt_eval_count`, `eval_count` and
  durations. So it does not matter whether the backend caches: lain declares capabilities it can
  *demonstrate*, and there is nothing on this wire to demonstrate one from. `NO_CACHING` and the
  absence of `:prompt_caching` are correct regardless, which closes Open decision 1 more cheaply
  than a cache measurement would have.

**Recorded, deliberately not acted on:** `Cloud#model_metadata?` ships `false` because `/api/show`
was unverified. It answers, so the cloud arm currently gives **no `--num-ctx` refusal** at all.
Flipping it is a one-line follow-up once T12 establishes it across models with a spec — one manual
request for one model, mid-wave, against a value object a sibling card was building on, is not the
evidence standard for changing shipped behaviour.

### Decision 7 — `resolved_endpoint` does NOT delegate to the deployment

T2's card lists `resolved_endpoint` alongside `capabilities` and `cache_profile` as delegating.
That is wrong and was not done: delegating it would make an explicit `api_base:` unobservable and
break the 46 existing construction sites the card itself insists must stay green. It keeps reading
`@config`. Recorded so a later reader does not "restore" it.

### Other stale citations found (bear on T13)

- The Provider / model axis is `ROADMAP.md:50`, not `:52`. (My first note here said `:52` was
  Orchestration; it is not — `:51` is Orchestration and `:52` is Decorrelation. Caught by T13.)
- There is no `WindowBook::Source`; the method is `WindowBook#book`
  (`cli/backend/window_book.rb:271-280`), consumed by `WindowBook::Live`.
- `context_window.rb:334` is the `GUESSED` branch; the `PUBLISHED` table hit is `:332`.
- T2's "roughly ten spec sites" list names three files that do not exist
  (`spec/lain/provider/vcr_ollama_posture_spec.rb`, `spec/lain/backend/summarizer_spec.rb`,
  `spec/lain/integration/provider/ollama_spec.rb`) and omits
  `spec/lain/provider/admission_spec.rb`, which holds ~11 such constructions and is the file most
  exposed to both T2 and T4. Regenerate the list before T2 runs.

### Operational note for every remaining card

A fresh worktree has **no compiled Rust extension** — `bundle exec rake compile` is required
before any spec loads.
