# Bedrock provider — Anthropic models via AWS Bedrock (Mantle)

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Add AWS Bedrock as a provider arm so Joel's work account (a Bedrock API key / bearer token) can
drive Lain against Anthropic models. This extends the provider axis in `ROADMAP.md` ("Anthropic
vs. OpenAI-compatible vs. local") with a fourth arm, and resolves the design plan's open question
("Do we ever want `bedrock`?") — the two objections recorded there (no key, a second 1,107-line
wire protocol) are both gone: a key exists, and the Bedrock **Mantle** endpoint speaks the plain
Anthropic Messages API over SSE, so no new wire protocol is needed. Mirroring the repo's own
Anthropic pattern: `Provider::Bedrock` (official SDK, the correctness oracle) plus
`Provider::BedrockRaw` (the forked Faraday transport, the default path), validated by the same
dry-diff / parity / live-differential strategy.

## Grounding

Verified 2026-07-15 against `main` @ 485fde2 and the installed toolchain.

- **`anthropic` gem 1.55.0 (installed, gemspec `~> 1.55`) ships `Anthropic::BedrockMantleClient`**
  (`lib/anthropic/bedrock_mantle.rb` → `Helpers::Bedrock::MantleClient < Anthropic::Client`).
  It exposes the same `.messages` resource; only `/v1/messages` is supported (`.models`,
  `.completions` raise `NotImplementedError`). Base URL derives
  `https://bedrock-mantle.{region}.api.aws/anthropic` from `aws_region:` (default
  `ENV["AWS_REGION"]` then `AWS_DEFAULT_REGION`); overridable via `ANTHROPIC_BEDROCK_MANTLE_BASE_URL`.
- **Auth precedence** (documented in the gem, `helpers/bedrock/mantle_client.rb`): explicit
  `api_key:` → explicit AWS creds → `aws_profile:` → **`AWS_BEARER_TOKEN_BEDROCK` env** (then
  `ANTHROPIC_AWS_API_KEY`) → default AWS chain. Bearer/API-key mode sends
  `Authorization: Bearer` (`use_bearer_auth: true`) and **does not touch SigV4**; SigV4 mode
  lazily `require`s `aws-sdk-core` (`helpers/aws_auth.rb:48`). ~~**Joel's credential is the bearer
  token, so no new gem dependency is added.**~~ **CORRECTION (2026-07-15, T2 escalation):** the
  `require("aws-sdk-core")` at `helpers/aws_auth.rb` is **unconditional** — it runs before
  `@use_sig_v4` is computed, so constructing `BedrockMantleClient` in *any* auth mode (bearer
  included) raises without the gem. rubygems.org has no newer release (1.55.0, 2026-07-02, is
  latest). **Orchestrator decision:** add `aws-sdk-core ~> 3` to the gemspec to satisfy the
  eager require; bearer mode still never exercises SigV4 at runtime, and SigV4 *support* stays
  out of scope. Repro + gem-source excerpt: T2's `.handback-T2.md`. SigV4 is out of scope; an
  escalation trigger covers the case where bearer mode unexpectedly loads `aws-sdk-core` —
  **that trigger fired and was resolved as above.**
- **Bedrock model IDs carry an `anthropic.` prefix** (`anthropic.claude-opus-4-8`).
  `PriceBook` matches on the `"opus"`/`"sonnet"`/`"haiku"` substring with a longest-token
  tie-break (`lib/lain/price_book.rb:107-108`), so prefixed IDs resolve without changes.
- **The Provider duck** (`lib/lain/provider.rb:23-74`): override `#capabilities`, `#encode`,
  `#complete`; `CAPABILITIES` universe at lines 28-37. The canonical contract is
  `spec/support/shared_examples/provider_parity.rb` (`"a Lain::Provider"`, seven gates driven
  through a real `Agent`).
- **Templates**: `lib/lain/provider/anthropic.rb` (SDK provider: `AnthropicEncoding` mixin,
  `DEFAULT_MODEL`, error wrapping, streaming-default `#dispatch` via `accumulated_message`,
  `#parse_input` for the streaming raw-String trap); `lib/lain/provider/anthropic_raw.rb`
  (forked transport: `#wire_payload` rewrites `system_:` → `:system` and adds `:stream`;
  retry → `Event::ProviderRetry`); `lib/lain/provider/ollama.rb` (a second registered HTTP
  backend). Vendored HTTP backends subclass `Provider::HTTP::Provider`, register a slug
  (`http/providers/anthropic.rb:73`), declare `configuration_options` /
  `configuration_requirements`; `Configuration.register_provider_options`
  (`http/configuration.rb:49`) extends config without editing it, and `#inspect` auto-redacts
  ivars ending `_key`/`_secret`/`_token`/`_id`.
- **Mantle wire shape = Anthropic Messages API**: model **stays in the body** (unlike legacy
  bedrock-runtime `InvokeModel`, which moves it to the URL and uses AWS event-stream framing —
  that path is *not* used here), streaming is ordinary SSE, prompt caching uses the same
  `cache_control` blocks. `AnthropicEncoding` and `StreamAssembler` are reused as-is.
- **Bedrock feature mask** (claude-api skill `shared/platform-availability.md`, 2026-06-24):
  messages/streaming/tools ✅, prompt caching ✅, structured outputs/strict tools ✅,
  adaptive+extended thinking ✅, parallel tool use ✅ — so `CAPABILITIES` matches
  `Provider::Anthropic`'s `%i[streaming prompt_caching strict_tools thinking parallel_tool_use]`.
  Not on Bedrock (irrelevant to current capabilities): batches, files, models API, fast mode,
  task budgets, server-side fallbacks. Known quirk to record, not model: forced `tool_choice`
  on Sonnet 5 requires `thinking: {type: "disabled"}` on Bedrock only.
- **Spec infrastructure**: `spec/support/tags.rb` gates `:integration`/`:live` on
  `LAIN_INTEGRATION`/`LAIN_LIVE` **and a nonempty `ANTHROPIC_API_KEY`** — a Bedrock live spec
  would be skipped by that gate, so Bedrock gets its own tag. `spec/support/ollama_tag.rb` is
  the exact per-provider precedent (own env switch, `NetworkAccess.permit`, skip-not-fail
  preflight, untagged offline-default regression examples). VCR filters secrets in
  `spec/support/vcr_configuration.rb`; `VCR.configure` is additive, so a new support file can
  register the bearer-token filter.
- **Seam facts the panel review pinned (2026-07-15)**: `Configuration.register_provider_options`
  registers options with a **nil** default and its lambda-default `option` method is private —
  the vendored config layer deliberately does **not** read provider env vars (see
  `spec/support/ollama_tag.rb`'s note); env-var defaulting lives at the provider layer
  (`AnthropicRaw#build_config`) or inside the SDK client. `AnthropicRaw::Transport` is
  `class Transport < Provider::HTTP::Providers::Anthropic`
  (`lib/lain/provider/anthropic_raw/transport.rb:18`) — hard-bound by inheritance, so BedrockRaw
  needs its own Transport file. `StreamAssembler` is namespaced under `AnthropicRaw`; this plan
  has BedrockRaw reference `AnthropicRaw::StreamAssembler` explicitly (accepted coupling —
  promote to `Provider::StreamAssembler` only when a third raw arm needs it, not before).
  The provider-parity shared example group's header notes it deliberately does not yet run
  against `Provider::Anthropic` (the SDK oracle) — only transport-level providers have a
  replay harness (`AnthropicSSE.queue_transport`); the Bedrock SDK oracle inherits that same
  posture. There is no spec for the vendored `Providers::Anthropic` backend; the real spec
  templates are `spec/lain/provider/http/provider_spec.rb` (a `.register` example with
  providers-hash save/restore hygiene) and `spec/lain/provider/ollama_spec.rb`.
- **Known duplication, accepted**: after T2/T3 the `APIError`/`APIStatusError` pair exists in
  four near-identical copies (Anthropic, AnthropicRaw, Bedrock, BedrockRaw). Ship it copied;
  extract a shared collaborator only if a `Metrics/*` cop forces it (and then per T2/T3's
  escalation triggers, since `Provider::Anthropic` is pinned as the oracle).
- **Doc/code disagreement**: the design plan (`~/.claude/plans/jiggly-greeting-avalanche.md`,
  "What we take" + Open questions) says **skip bedrock** — that referred to vendoring RubyLLM's
  legacy `bedrock` wire protocol. Superseded here by the Mantle client + the work key; the code
  wins. The plan's open-questions bullet gets updated at integration time (orchestrator).

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb` (no change expected),
  `lib/lain/provider.rb` (index — two require lines), `lib/lain/provider/http.rb` (index — one
  require line), `lain.gemspec` / `Gemfile` / `Gemfile.lock` (~~no change expected~~ **changed
  2026-07-15**: `aws-sdk-core ~> 3` added per the Grounding correction — the Mantle client's
  eager require; any card wanting a *further* new gem must escalate), `.rubocop.yml`,
  `spec/spec_helper.rb`, `CLAUDE.md`, `ROADMAP.md`,
  `~/.claude/plans/jiggly-greeting-avalanche.md`.
- Per CLAUDE.md, a new lib file, its index line, and its spec land in the **same commit** — the
  orchestrator applies each card's index wiring as part of that card's commit, not separately.
- Secrets discipline: the work bearer token lives only in the gitignored `.env`
  (`AWS_BEARER_TOKEN_BEDROCK`, `AWS_REGION`). **No `LAIN_RECORD=1` run against Bedrock until
  T4's VCR filter is merged and its spec is green** — a cassette is committed YAML and a leaked
  work credential is unrevocable-by-us.

## Open decisions

None gating. Deferred (recorded here so they aren't re-litigated):

- Recorded `:vcr` cassettes for `BedrockRaw` (the analog of remaining-work P.1) wait until the
  first live run happens with the filter in place — see Integration checks.
- SigV4 support (and the `aws-sdk-core` dependency) is deliberately out of scope until a
  credential that needs it exists.

## Waves

Wave 1: T1, T2   (no unmet deps)
Wave 2: T3 (←T1, T2), T5 (←T2)
Wave 3: T4 (←T2, T3)
Critical path: T1 → T3 → T4 (tied by T2 → T3 → T4; both length 3)

## Tasks

### T1 — Add the vendored-transport Bedrock backend          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/http/providers/bedrock.rb` (create),
`spec/lain/provider/http/providers/bedrock_spec.rb` (create)
**Reuse:** `lib/lain/provider/http/providers/anthropic.rb` (subclass it — payload rendering and
chunk parsing are inherited; override only endpoint + auth), `Provider::HTTP::Provider.register`
(`http/provider.rb`), `Configuration.register_provider_options` (`http/configuration.rb:49`).
Spec templates: `spec/lain/provider/http/provider_spec.rb` (copy its `.register` example's
providers-hash save/restore hygiene) and `spec/lain/provider/ollama_spec.rb` — there is **no**
existing spec for the vendored anthropic backend to mirror.
**Shared-file wiring:** `require_relative "http/providers/bedrock"` appended in
`lib/lain/provider/http.rb` (after the anthropic line).

**Acceptance criteria:**

```gherkin
Scenario: backend registration and endpoint derivation
  Given a Configuration with bedrock_api_key "tok" and bedrock_region "us-east-1"
  When the :bedrock HTTP provider is resolved and asked for its api_base
  Then it returns "https://bedrock-mantle.us-east-1.api.aws/anthropic"
  And an explicit bedrock_api_base on the Configuration overrides the derived URL
```

```gherkin
Scenario: bearer auth headers, not x-api-key
  Given a resolved :bedrock HTTP provider with bedrock_api_key "tok"
  When headers are built
  Then they include "Authorization" => "Bearer tok" and "anthropic-version" => "2023-06-01"
  And they do not include "x-api-key"
```

```gherkin
Scenario: the secret never appears in inspect output
  Given a Configuration with bedrock_api_key "tok"
  When the Configuration is inspected
  Then the output does not contain "tok"
```

Note: **no env-var reading at this layer.** `Configuration` deliberately has no ENV defaults
for provider options (see Grounding; `ollama_tag.rb` documents the same for ollama). ENV
defaulting is T3's `build_config` (raw arm) and the Mantle client itself (SDK arm, T2).

```gherkin
Scenario: missing configuration fails loudly
  Given a Configuration with no bedrock_api_key
  When the :bedrock provider's configuration requirements are checked
  Then a configuration error names bedrock_api_key (and bedrock_region when unset)
```
→ spec file: `spec/lain/provider/http/providers/bedrock_spec.rb`

**Escalation triggers:**
- The vendored `Providers::Anthropic`'s `#headers`/`#api_base` cannot be overridden in a subclass
  without copying rendering/parsing code — stop; the fallback (a header hook in the vendored base
  class) edits vendored files whose provenance headers the orchestrator curates.
- `Connection` joins paths in a way that drops or doubles the `/anthropic` suffix of the Mantle
  base URL — stop before working around it in the subclass.
- Any impulse to reach for `aws-sdk-core`/SigV4 — out of scope by decision; escalate instead.

### T2 — Add Provider::Bedrock, the SDK Mantle oracle          [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/provider/bedrock.rb` (create), `spec/lain/provider/bedrock_spec.rb` (create)
**Reuse:** `lib/lain/provider/anthropic.rb` (mirror: `include AnthropicEncoding`, error wrapping,
streaming-default `#dispatch` via `accumulated_message`, `#parse_input`, `#build_usage`);
`spec/lain/provider/anthropic_spec.rb` (the `client_returning` double and the over-the-wire
webmock+SSE example — note it stubs one message; T2's ACs need nothing more).
**Shared-file wiring:** `require_relative "provider/bedrock"` in `lib/lain/provider.rb`'s
manifest tail (after `provider/anthropic`).

**Acceptance criteria:**

```gherkin
Scenario: provider contract subset
  Given Provider::Bedrock constructed with a doubled client
  Then #capabilities is exactly [:streaming, :prompt_caching, :strict_tools, :thinking,
       :parallel_tool_use] (the literal list, not another provider's constant)
  And #encode is deterministic for the same Request
  And its DEFAULT_MODEL is "anthropic.claude-opus-4-8"
```

Note: the seven-gate `"a Lain::Provider"` group does **not** run here — it has no SDK-message
replay harness, and the group's own header records that the Anthropic SDK oracle isn't gated
either (the seam is waiting). T3's parity spec carries the gates for the Bedrock arm, through
the real streaming parse.

```gherkin
Scenario: default client is the Mantle client
  Given no injected client
  When Provider::Bedrock.new(api_key: "tok", aws_region: "us-east-1") is constructed
  Then its client is an Anthropic::BedrockMantleClient
  And constructing and completing in bearer mode raises nothing about aws-sdk-core
```

```gherkin
Scenario: over the wire (webmock)
  Given Provider::Bedrock.new(api_key: "tok", aws_region: "us-east-1")
  When #complete runs against a stubbed SSE response
  Then the request is a POST to https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages
  And it carries an Authorization Bearer header and the model in the JSON body
  And the Response retains every content block with tool_use input parsed to a Hash
```

```gherkin
Scenario: errors and prices
  Given the client raises Anthropic::Errors::APIStatusError
  Then #complete wraps it in Provider::Bedrock::APIStatusError preserving status
  And PriceBook::DEFAULT resolves "anthropic.claude-opus-4-8" to the opus price row
```
→ spec file: `spec/lain/provider/bedrock_spec.rb`

**Escalation triggers:**
- `BedrockMantleClient` in bearer/API-key mode attempts `require "aws-sdk-core"` anyway — stop;
  that reopens the gemspec decision recorded in the Orchestrator contract.
- The existing spec suite's env hygiene (webmock posture, `ANTHROPIC_API_KEY` handling in
  `anthropic_spec.rb`) conflicts with `AWS_BEARER_TOKEN_BEDROCK`/`AWS_REGION` leaking from the
  developer's shell into examples — stop and agree an env-stubbing convention rather than
  inventing one locally.
- If mirroring `Provider::Anthropic` produces near-duplicate code that a `Metrics/*` cop flags,
  extract a shared collaborator — but if the extraction changes `Provider::Anthropic`'s public
  surface, stop first (it is the oracle other specs pin against).

### T3 — Add Provider::BedrockRaw on the forked transport          [wave 2] [risk: medium]

**Depends on:** T1, T2
**Files:** `lib/lain/provider/bedrock_raw.rb` (create — also the index that requires its
`bedrock_raw/` subtree, per the Requires policy),
`lib/lain/provider/bedrock_raw/transport.rb` (create — `Transport <
Provider::HTTP::Providers::Bedrock`; the anthropic Transport is hard-bound by inheritance to
the anthropic backend at `anthropic_raw/transport.rb:18` and does not transfer),
`spec/lain/provider/bedrock_raw_spec.rb` (create),
`spec/lain/provider/bedrock_raw_parity_spec.rb` (create)
**Reuse:** `lib/lain/provider/anthropic_raw.rb` (the shape: config build with ENV fallbacks,
`#wire_payload`, stream/sync dispatch, `#normalize_tool_input`, retry journaling);
`lib/lain/provider/anthropic_raw/transport.rb` (mirror for the new Transport — do **not**
modify it); `AnthropicRaw::StreamAssembler` referenced by explicit constant (decided —
see Grounding; do not promote the namespace); `AnthropicSSE.queue_transport`
(`spec/support/anthropic_sse.rb`); `spec/lain/provider/anthropic_raw_parity_spec.rb` (copy the
seven-gate inclusion); `spec/lain/provider/anthropic_raw_spec.rb` as the unit-spec template.
**Shared-file wiring:** `require_relative "provider/bedrock_raw"` in `lib/lain/provider.rb`'s
manifest tail (after `provider/anthropic_raw`).

**Acceptance criteria:**

```gherkin
Scenario: seven-gate parity through the real streaming parse
  Given Provider::BedrockRaw over an AnthropicSSE queue transport
  Then it passes the "a Lain::Provider" shared examples
```
→ spec file: `spec/lain/provider/bedrock_raw_parity_spec.rb`

```gherkin
Scenario: wire payload shape
  Given a Request with a system prompt, tools, and cache markers
  When Provider::BedrockRaw builds its wire payload
  Then the payload keeps model in the body, rewrites system_ to system, and sets stream
```

```gherkin
Scenario: the real Connection reaches the Mantle endpoint intact (webmock, offline)
  Given Provider::BedrockRaw with a REAL Transport (no injected queue) and
        bedrock_api_key "tok" / bedrock_region "us-east-1"
  When #complete runs against a webmock-stubbed SSE response
  Then the request is a POST to
       https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages
       (the /anthropic path suffix survives Connection's URL join — the named join trap)
  And it carries an Authorization Bearer header and no x-api-key
```

```gherkin
Scenario: DEFAULT_MODEL and encode parity with the oracle
  Given the same Request
  Then BedrockRaw#encode equals Provider::Bedrock#encode
  And Provider::BedrockRaw::DEFAULT_MODEL is "anthropic.claude-opus-4-8"
```

```gherkin
Scenario: env fallbacks live at the provider layer
  Given AWS_BEARER_TOKEN_BEDROCK and AWS_REGION set (stubbed) and no explicit kwargs
  When Provider::BedrockRaw builds its config
  Then bedrock_api_key and bedrock_region come from those variables
  (mirrors AnthropicRaw#build_config's ENV.fetch — NOT a Configuration-layer default)
```

```gherkin
Scenario: retries are journaled
  Given a transport that yields one retryable failure then success
  When #complete runs
  Then exactly one Event::ProviderRetry lands on the channel
```
→ spec file: `spec/lain/provider/bedrock_raw_spec.rb`

**Escalation triggers:**
- Sharing with `AnthropicRaw` requires changing `AnthropicRaw`'s public surface or its specs —
  stop; `anthropic_raw_parity_spec.rb`, `anthropic_raw_recorded_spec.rb`, and the bench CLI pin
  that class.
- The Mantle SSE stream uses event names/shapes `StreamAssembler` does not recognize (only a
  live run can prove this; the unit layer assumes Anthropic-shaped SSE) — record the assumption,
  don't code around a hypothetical.
- The encode-parity AC fails because the two providers need *different* payloads — that breaks
  this plan's core premise (one wire shape); stop immediately.

### T4 — Gate and write the Bedrock live specs          [wave 3] [risk: low]

**Depends on:** T2, T3
**Files:** `spec/support/bedrock_tag.rb` (create),
`spec/integration/provider/bedrock_spec.rb` (create)
**Reuse:** `spec/support/ollama_tag.rb` (mirror the whole idiom: env switch, `NetworkAccess.permit`
around, skip-not-fail preflight, untagged offline-default regression examples, the before(:suite)
skip message); `spec/support/tags.rb` (the `:integration` posture being mirrored);
`spec/integration/provider/anthropic_spec.rb` (the two-example shape: plain text + tool round
trip, tiny max_tokens); `spec/lain/provider/anthropic_raw_recorded_spec.rb` (the live
differential shape).

**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: offline by default
  Given LAIN_BEDROCK is unset
  Then :bedrock examples are excluded from the default run
  And an untagged regression example proves the exclusion filter is active
  And an untagged example proves an unpermitted Bedrock-host request is blocked
```

```gherkin
Scenario: gate requires the credential (pin the reason function, not the harness)
  Given a missing_credential_reason function mirroring OllamaTestServer.unreachable_reason
  When AWS_BEARER_TOKEN_BEDROCK is empty or the region is unresolvable (stubbed env)
  Then it returns a human skip reason naming the missing variable
  And it returns nil when both are present
  (the before-hook skips on a non-nil reason, exactly like the :ollama tag)
```

```gherkin
Scenario: cassette hygiene precedes any recording (behavioral, tmpdir)
  Given a VCR cassette recorded into a tmpdir against a webmock-permitted request
        whose Authorization header carries the (stubbed) bearer-token value
  When the cassette YAML is read back
  Then it contains the placeholder (e.g. "<AWS_BEARER_TOKEN_BEDROCK>") and not the token
```

```gherkin
Scenario: live round trips and the differential (runs only under LAIN_BEDROCK=1)
  Given real credentials
  Then Provider::Bedrock completes a plain-text and a tool-use Request (tiny max_tokens)
  And Provider::BedrockRaw completes the same Requests
  And for one identical Request both providers return an equivalent Lain::Response
```
→ spec file: `spec/integration/provider/bedrock_spec.rb` (gate + hygiene examples in
`spec/support/bedrock_tag.rb`)

**Escalation triggers:**
- A second `VCR.configure` block (in `bedrock_tag.rb`) does not compose with
  `vcr_configuration.rb`'s — stop and hand the orchestrator a one-line filter diff for
  `vcr_configuration.rb` instead of editing it yourself.
- The live differential shows non-equivalent Responses (block order, usage fields, stop reason)
  — do not normalize away the difference in the spec; stop and report which field diverged.
- Any temptation to run `LAIN_RECORD=1` to debug — forbidden until the filter AC is green
  (Orchestrator contract, secrets discipline).

### T5 — Wire --provider bedrock into the CLI          [wave 2] [risk: low]

**Depends on:** T2
**Files:** `exe/lain` (modify), `spec/lain/cli_spec.rb` (modify)
**Reuse:** the existing `PROVIDERS` list / `#provider` / `#default_model` branches in `exe/lain`
(`Backend`, lines ~23-64) and however `spec/lain/cli_spec.rb` fakes the anthropic/ollama branches.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: provider selection
  Given exe/lain invoked with --provider bedrock
  Then the Backend constructs a Lain::Provider::Bedrock
  And with --model unset the Context model is "anthropic.claude-opus-4-8"
```

```gherkin
Scenario: help text names the new arm
  Given exe/lain --help output
  Then the --provider description lists bedrock alongside anthropic and ollama
  And the --api-base description still scopes itself to ollama
```

```gherkin
Scenario: unknown provider unchanged
  Given --provider gemini
  Then the existing rejection behavior is unchanged
```
→ spec file: `spec/lain/cli_spec.rb`

Note: the Bedrock arm is **env-configured** (`AWS_BEARER_TOKEN_BEDROCK`, `AWS_REGION` via the
Mantle client's own defaults) — do not add `--region`/`--bedrock-*` flags.

**Escalation triggers:**
- `cli_spec.rb` constructs the real provider (which would read `AWS_BEARER_TOKEN_BEDROCK` /
  `AWS_REGION` from the developer's shell or fail without them) — stop and match however the
  existing branches isolate from env rather than adding ad-hoc stubbing.
- `#provider`'s case statement growth trips a `Metrics/*` cop — extract a provider registry
  collaborator; if that refactor touches the ollama/anthropic branches' behavior, stop first.

## Integration checks

After the last wave, on `main`:

1. `bundle exec rspec` — full default suite green (no `:bedrock`, `:integration`, `:live`
   examples run; the offline-default regression examples from T4 do run).
2. `bundle exec rubocop` — zero offenses at default metrics.
3. `pre-commit run --all-files` green (includes cargo checks; no Rust touched, must stay 6/6).
4. **Manual (Joel):** put the work credential in the gitignored `.env`
   (`AWS_BEARER_TOKEN_BEDROCK=...`, `AWS_REGION=...`), then run
   `LAIN_BEDROCK=1 bundle exec rspec spec/integration/provider/bedrock_spec.rb` — the live round
   trips and the SDK-vs-raw differential must pass against the real endpoint. This is the
   plan's end-to-end proof; everything before it is stubs and parity.
5. **Manual (Joel), optional follow-up:** once step 4 has passed and the T4 filter is proven,
   record `:vcr` cassettes for `BedrockRaw` with `LAIN_RECORD=1` (synthetic prompts only) —
   the Bedrock analog of remaining-work P.1. Inspect the cassette for the token placeholder
   before committing.
6. **Orchestrator docs pass:** ROADMAP.md provider-axis row gains the Bedrock arm with a link to
   this spec; `~/.claude/plans/jiggly-greeting-avalanche.md` Open questions — the
   "Do we ever want `gemini` / `bedrock`?" bullet gets a dated resolution note (bedrock: yes,
   via the SDK's Mantle client + bearer token; gemini: still open).
7. One smoke run by hand: `exe/lain --provider bedrock` completes a trivial prompt end-to-end
   (same credentials as step 4).
