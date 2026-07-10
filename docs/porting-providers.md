# Porting a provider from `ruby_llm`

This is the pattern the `vendor` branch used to fork Anthropic out of
`ruby_llm` 1.16.0 (commit `2cf34b9`), written so openai/gemini/bedrock/the
OpenAI-compatible shims can be ported the same way later without rediscovering
it. Read `lib/lain/provider/http/VENDOR.md` for the file map and
`~/.claude/plans/jiggly-greeting-avalanche.md` ("Transport: fork RubyLLM's
HTTP layer") for why we fork at all.

Every claim below was checked against the actual `ruby_llm` 1.16.0 source
(cloned locally, tag `1.16.0`, commit `2cf34b9`), not remembered.

## The shape: four wire protocols, nine configurations

`openai` (1,090 lines) is the base class for eight others; `gemini` (1,350)
and `bedrock` (1,107) are standalone; `anthropic` (755, this branch) is the
fourth. `azure`, `deepseek`, `gpustack`, `mistral`, `ollama`, `openrouter`,
`perplexity`, `xai` all subclass `OpenAI` directly (verified:
`class DeepSeek < OpenAI`) and are mostly `api_base`/`headers`/pricing —
`deepseek.rb` is 20 lines. `vertexai` wraps `Gemini`.

Practically: porting `openai` is the second real port (a new wire protocol,
same weight as this branch); everything `< OpenAI` after that is closer to
"one new row in a table" than a new provider.

## The eleven leak sites, and the pattern used for each

| # | Site | Pattern | Reusable for the next provider? |
|---|---|---|---|
| 1 | `connection.rb`'s `RubyLLM.logger` | `Logging::SinkLogger` wraps an injected `Lain::Sink`, exposing exactly the duck `Faraday::Response::Logger`'s formatter needs (`#debug`/`#info`/`#warn`/`#error`/`#fatal`, block form, plus `#debug?`). `Connection#initialize` takes `sink:`/`log_level:` keywords with `Sink::Null`/`:info` defaults. | Yes, unconditionally — `connection.rb` is provider-generic already; nothing here is Anthropic-specific. |
| 2 | `stream_accumulator.rb`'s `RubyLLM.logger.debug{} if RubyLLM.config.log_stream_debug` | Same idea, but `StreamAccumulator#initialize` takes `sink:`/`debug:` directly rather than reading a `Configuration` singleton — this class already took no other global state, and reading one `Configuration.log_stream_debug` would have been the sole exception. | Yes — `StreamAccumulator` is provider-generic upstream too. |
| 3 | `connection.rb`'s `RubyLLM.instrument` | Kept as a seam: `Connection#initialize` takes `instrumenter:` (`#call(name, payload) { }`), defaulting to a no-op (`Connection::NULL_INSTRUMENTER`) that just yields. Do NOT wire `ActiveSupport::Notifications` here — that is the `journal` branch's job, and the payload shape (`provider:`, `method:`, `url:`, `status:`) is already generic. | Yes, no change needed. |
| 4 | `connection.rb`'s `RubyLLM.configure` | Not a call — a heredoc string inside `ensure_configured!`'s error message. Just reword; verify no other file has the same cosmetic reference. | Check per-provider; cosmetic only. |
| 5 | `provider.rb`'s `Configuration.register_provider_options` | **Keep, unconditionally.** `Provider.register(name, klass)` calls it so every provider's `configuration_options` (`<slug>_api_key`, `<slug>_api_base`, plus whatever else — see below) become real `Configuration` accessors without `Configuration` ever naming a provider. Extracted to `Provider::Registry` (an `extend`ed module) purely to keep `Provider`'s own line count down; the behavior is identical to upstream. | Yes, unconditionally — this is *the* provider-generic seam. |
| 6 | `provider.rb`'s `Provider.for(model)` (via `Models.find`) | Deleted. No model registry, so "resolve a provider by model id" has nothing to resolve against. `Provider.resolve(name)` (by slug) is what this slice uses and is all any caller needs until a registry exists. | Re-evaluate only if/when a `Models` registry is ever vendored. Until then, keep deleted. |
| 7 | `providers/anthropic.rb`'s six `include`s + `capabilities` override | Trimmed to `include Anthropic::{Chat,Streaming,Tools}`; `Embeddings`, `Media`, `Models` dropped, and with them the `class << self; def capabilities; Anthropic::Capabilities; end; end` override that only `Models` needed. **Caution for the next port:** `Media` is not merely unused scaffolding — `Chat`/`Tools` call `Media.format_content` directly as a *module-qualified* call, not an instance method, so dropping `Media` breaks them unless you replace the call. This branch's fix: `Tools.format_content`, the text-only remainder of the same method (see leak site 9). Do the same for the next provider's own `Media`-equivalent, in whichever of its included modules calls it. Also watch for `Models`-file methods a *kept* module still depends on: `Anthropic::Streaming#build_chunk` called five `extract_*` token/model-id helpers that were filed under `models.rb`, not `streaming.rb`, purely by upstream's organization. They are pure Hash digging, no registry involved, so they moved to their only caller (`streaming.rb`) instead of resurrecting a `Models` file for five leaf methods. **Check every `include`-dropped module for this pattern before assuming "drop the file" is safe.** | Partially — the *decision* (drop Embeddings/Media/Models) generalizes to every provider, since none of them need a model registry either. The *mechanics* (what breaks, what moves where) must be re-verified per provider; openai's `Media` and `Models` are separate files from Anthropic's with their own internals. |
| 8 | `message.rb`'s `#model_info` (`RubyLLM.models.find`) | Deleted, and `#cost` with it — `#cost` only existed to call `#model_info` and build a `RubyLLM::Cost` priced off the (also not vendored) `Model::Info`/pricing tables. Cost accounting is `Lain::Usage`'s job. | Yes, unconditionally — `message.rb` is provider-generic; this applies verbatim to every future provider. |
| 9 | `content.rb`'s `Attachment` branch | Deleted outright; `Content` is text-only (`text`, `format`, `empty?`, `to_h`, plus the `Raw` escape hatch). `Message#normalize_content`'s `Hash` branch no longer passes a second `Content.new` argument (that argument was the attachments list). | Yes, unconditionally, **until** an image/PDF/audio-capable provider is actually ported with a real use case. At that point `Content`/`Attachment` need to come back together, deliberately, not leak back in piecemeal. |
| 10 | `provider.rb`'s `UnsupportedAttachmentError`/`require "marcel"` | `validate_paint_inputs!` and `build_audio_file_part` deleted. Also deleted, beyond what the brief named: the public `#paint`/`#transcribe`/`#embed`/`#moderate`/`#list_models` methods themselves — each called at least one rendering/parsing method only `Anthropic::Media`/`Embeddings`/`Models` ever defined (leak site 7), so keeping the public methods without their support modules would have meant keeping methods that always raise `NoMethodError`. `#complete` is the one API this slice exists to serve. | Yes — no provider in this codebase's scope needs image/audio/moderation/embeddings yet. Revisit `Provider`'s public surface, not just these two private methods, when one does. |
| 11 | `anthropic/tools.rb`'s `RubyLLM::Tool::SchemaDefinition.from_parameters` | `Tools.function_for(tool)` now takes any duck responding to `#name`/`#description`/`#input_schema` — exactly `Lain::Tool`. The `params_schema`/`parameters`/`provider_params` fallbacks upstream had are `RubyLLM::Tool`-specific and have no `Lain::Tool` equivalent, so the provider-params merge step is gone with them. | Yes, unconditionally — every provider's tool-schema renderer should target the same `Lain::Tool` duck, not `RubyLLM::Tool`. |

**Unlisted twelfth leak site, found while porting:** `Configuration#log_regexp_timeout=`'s custom setter called `RubyLLM.logger.warn` on Ruby versions predating `Regexp.timeout=`. Dead code on ruby-4.0.5 (which has had `Regexp.timeout=` since 3.2) and, more to the point, the one call in `configuration.rb` that would have reached a global logger. Dropped in favor of the plain generated setter. Check for this kind of "defensive warn" pattern in any `Configuration`-adjacent code the next provider brings — it is exactly the shape that hides a leak the brief's line-numbered table cannot catch, because it wasn't in the *reviewed* file's leak list, only in a *taken* file's implementation detail.

## Three files not in the brief's take-list that you will need anyway

`thinking.rb` and `tokens.rb` are not named in the porting brief's "Take"
table, but `message.rb`'s `#initialize` and `stream_accumulator.rb`'s
`#to_message` both construct one. Both are small, provider-generic, and
leak-free (no `Models`, no `Attachment`) — vendor them alongside `message.rb`
and `chunk.rb` without a second thought; every provider needs them.

The base **`streaming.rb`** (`RubyLLM::Streaming`, top of `lib/ruby_llm/`)
was also missing from the brief's list, which named only
`providers/anthropic/streaming.rb`. But the per-provider file supplies
*hooks*; the base file supplies `stream_response` itself — the method
`Provider#complete(&block)` actually calls. Omitting it makes streaming raise
`NoMethodError`. Vendor it once, `include` it into the base `Provider`, and
add its one dependency `event_stream_parser`. See the "Streaming" section
above.

## Kept generic, and why (cross-checked against all thirteen providers)

Verified directly against the source, not assumed:

- **`api_base`, `headers`, `configuration_requirements`, `configuration_options`** are overridden by all thirteen providers (openai's `headers` even sends three different header names — `Authorization`, `OpenAI-Organization`, `OpenAI-Project` — compacted, which is exactly the shape `Provider#headers`'s empty-Hash default exists to be overridden into). Never narrow these to Anthropic's shape.
- **`slug`/`models`**: no provider overrides them; the base class methods are enough. (This branch doesn't vendor `models` in any form — see leak site 6/8 — so there is nothing to check there yet, but `slug` is confirmed generic.)
- **The universal streaming hooks are `stream_url`, `build_chunk(data)`, `parse_streaming_error(data)`.** Anthropic *additionally* defines `extract_content_delta`/`extract_thinking_delta`/`extract_signature_delta`/`json_delta?`, which read Anthropic's own `delta.type` values — these are Anthropic-specific and correctly stayed inside `providers/anthropic/streaming.rb`, not promoted into a shared base.
- **`Configuration` must stay dynamic.** Confirmed: nine *other* providers register their own option sets beyond `<slug>_api_key`/`<slug>_api_base` — openai needs `openai_organization_id`, `openai_project_id`, `openai_use_system_role`; bedrock needs `bedrock_secret_key`, `bedrock_region`, `bedrock_session_token`; vertexai needs a project id and location. Hardcoding Anthropic's two keys into `Configuration` would have made every one of those impossible without editing this file per provider.
- **`maybe_normalize_temperature(temperature, model)`** (private, in `Provider`) exists because openai overrides it (`OpenAI::Temperature.normalize(temperature, model.id)` — some OpenAI models reject a `temperature` outside `{0, 1}` or reject it outright). Anthropic's override is the identity function. Keep the hook; do not inline it into `#complete` when only one provider uses it non-trivially.
- **`#complete` itself is overridable, not just `render_payload`/`parse_completion_response`.** Bedrock overrides `#complete` to normalize `params` (AWS's Converse API wants `additionalModelRequestFields`, not the OpenAI/Anthropic-shaped params RubyLLM's caller sends) before delegating to `super`. It also overrides `#parse_error` (different error-body shape: `message`/`Message`/`error`/`__type`) and the private `#sync_response` (AWS SigV4-signs the request instead of just adding headers). **This means when bedrock is ported, `Connection`'s "just add a headers Hash" auth model will not fit** — bedrock signs the whole request, which the current `Connection#post`/`#get` seam (a header merge before handing off to Faraday) does not accommodate. That is a real redesign point, not a config tweak; flag it explicitly when bedrock's turn comes rather than trying to force SigV4 through `#headers`.
- **Only `anthropic`, `gemini`, `openai` define a `tools.rb`; only seven define a `streaming.rb`.** Confirmed by directory listing. `Providers::Anthropic`'s `include Anthropic::{Chat,Streaming,Tools}` is written assuming all three exist for this provider; when porting a provider lacking one (e.g., no `tools.rb`), just omit that `include` rather than vendoring an empty module — `Provider#complete` and `Connection` do not require any of the three to exist as a hard dependency, only whatever payload-rendering method the provider's own `render_payload` needs to call.

## Streaming: two layers, and which is generic

Streaming is split exactly like the rest: a provider-generic base and a provider-specific hook set.

- **The base SSE engine is `lib/ruby_llm/streaming.rb`** (`RubyLLM::Streaming`, at the *top* of `lib/ruby_llm/`, NOT under `providers/`). It is fully generic — it drives Faraday's `on_data`, feeds bytes through `event_stream_parser`, and calls the three universal hooks. Vendor it once into `lib/lain/provider/http/streaming.rb` and `include` it into the base `Provider` (done). It needs the `event_stream_parser` gem (MIT, Shopify, zero transitive deps — now a declared dependency). Its only leaks are `RubyLLM.config.log_stream_debug` and `RubyLLM.logger`, both shimmed the same way as everywhere else: an injected `@sink` + `@stream_debug` flag on the provider, `Sink::Null`/`false` default.
- **The three universal hooks are `stream_url`, `build_chunk(data)`, `parse_streaming_error(data)`.** The base engine calls all three on `self` (the provider). A provider's `providers/<name>/streaming.rb` supplies them.
- **`parse_streaming_error` lives in BOTH layers.** The base has a generic version (in `streaming/error_handling.rb`); Anthropic overrides it (529 vs 500 on `overloaded_error`). Because `Anthropic::Streaming` is included at the *subclass* level and the base `Streaming` at the *parent* level, the subclass override wins for Anthropic, and a provider with no `streaming.rb` falls back to the generic one. **When porting a provider, put its `parse_streaming_error` override in its own `streaming.rb`, not the base** — same as `build_chunk`.
- **Anthropic's `extract_content_delta` / `extract_thinking_delta` / `extract_signature_delta` / `json_delta?` are Anthropic-specific and must NOT migrate into the base.** They read Anthropic's `delta.type` values. They stay in `providers/anthropic/streaming.rb`.
- **A provider with no `streaming.rb` still streams.** The base engine + base `parse_streaming_error` + whatever `build_chunk`/`stream_url` the base supplies is enough. Do not vendor an empty per-provider streaming module; just omit the `include`.
- **`extract_*` token helpers may be filed under the wrong upstream file.** Anthropic's `build_chunk` depends on five `extract_input_tokens`/etc. helpers that upstream filed under `providers/anthropic/models.rb`, not `streaming.rb` — pure Hash digging, no registry. They were moved to their only caller (`streaming.rb`). Check each provider's `build_chunk` for the same cross-file dependency before dropping its `models.rb`.

## What would force a redesign when the next provider lands

- **Bedrock's request signing** (above) — the auth model is not "a headers Hash," and `Connection` currently assumes it is.
- **Gemini's media/embeddings/images are still separate files** the way Anthropic's were; expect the same "module-qualified `Media.format_content` call from a kept module" trap (leak site 7) there too. Check `Gemini::Chat`/`Gemini::Tools` for calls into `Gemini::Media` specifically before dropping it.
- **The OpenAI-compatible shims (`deepseek`, `gpustack`, `mistral`, `ollama`, `openrouter`) subclass `OpenAI`, not `Provider`.** Verified: `class DeepSeek < OpenAI`. This only works once `OpenAI` itself is ported; they cannot be ported before their base class. Plan the wave order accordingly — `openai` is a prerequisite for five "one new row" providers, not just itself.

## Specs

Port `stream_accumulator_spec.rb`, `error_middleware_spec.rb`,
`connection_logging_spec.rb`, `provider_spec.rb` near-verbatim (namespace
swap only) — all four are already provider-generic or trivially adapted (see
`spec/lain/provider/http/`). `error_handling_spec.rb` cannot port verbatim
for *any* provider: upstream drives it through `RubyLLM.chat(...).ask(...)`,
which needs `Chat#complete`'s loop and a default-model lookup through the
Models registry, neither of which this slice (or any future one, on current
scope) vendors. Stub the provider's own completion endpoint with WebMock
(already a global dependency, blocking network by default — see
`spec/spec_helper.rb`) and drive `Provider#complete` directly instead; see
`spec/lain/provider/http/error_handling_spec.rb` for the pattern.

Do not vendor VCR cassettes here. That is the `transport` branch's job —
this branch does not touch `Message`/`Content` mapping into `Lain::Response`,
so a cassette recorded against this branch's payload would need
re-recording the moment `transport` lands anyway.
