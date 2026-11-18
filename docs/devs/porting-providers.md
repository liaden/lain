# Porting a provider from `ruby_llm`

This page records the pattern the `vendor` branch used to fork Anthropic out of
`ruby_llm` 1.16.0 (commit `2cf34b9`), so openai/gemini/bedrock/the
OpenAI-compatible shims can be ported the same way later. Read `lib/lain/provider/http/VENDOR.md` for the file map, and its own
`## Why fork instead of depend` section for why we fork at all.

Every claim below was checked against the actual `ruby_llm` 1.16.0 source
(cloned locally, tag `1.16.0`, commit `2cf34b9`).

## Wire protocols and configurations

`openai` (1,090 lines) is the base class for 8 others; `gemini` (1,350)
and `bedrock` (1,107) are standalone; `anthropic` (755, this branch) is the
fourth. `azure`, `deepseek`, `gpustack`, `mistral`, `ollama`, `openrouter`,
`perplexity`, `xai` all subclass `OpenAI` directly (verified:
`class DeepSeek < OpenAI`) and are mostly `api_base`/`headers`/pricing;
`deepseek.rb` is 20 lines. `vertexai` wraps `Gemini`.

Porting `openai` is the second real port (a new wire protocol,
same weight as this branch). Everything `< OpenAI` after that is close to
one new row in a table.

## The 11 leak sites

This table records the port as it landed; `StreamAccumulator`, the message model, the Chat/Tools mixins and `Provider#complete` were deleted later.

| # | Site | Pattern | Reusable for the next provider? |
|---|---|---|---|
| 1 | `connection.rb`'s `RubyLLM.logger` | `Logging::SinkLogger` wraps an injected `Lain::Sink`, exposing exactly the duck `Faraday::Response::Logger`'s formatter needs (`#debug`/`#info`/`#warn`/`#error`/`#fatal`, block form, plus `#debug?`). `Connection#initialize` takes `sink:`/`log_level:` keywords with `Sink::Null`/`:info` defaults. | Yes, unconditionally: `connection.rb` is provider-generic already; nothing here is Anthropic-specific. |
| 2 | `stream_accumulator.rb`'s `RubyLLM.logger.debug{} if RubyLLM.config.log_stream_debug` | Same idea, but `StreamAccumulator#initialize` takes `sink:`/`debug:` directly rather than reading a `Configuration` singleton; this class already took no other global state, and reading one `Configuration.log_stream_debug` would have been the sole exception. | Yes: `StreamAccumulator` is provider-generic upstream too. |
| 3 | `connection.rb`'s `RubyLLM.instrument` | Kept as a seam: `Connection#initialize` takes `instrumenter:` (`#call(name, payload) { }`), defaulting to a no-op (`Connection::NULL_INSTRUMENTER`) that just yields. Do not wire `ActiveSupport::Notifications` here; that is the `journal` branch's job, and the payload shape (`provider:`, `method:`, `url:`, `status:`) is already generic. | Yes, no change needed. |
| 4 | `connection.rb`'s `RubyLLM.configure` | Not a call; a heredoc string inside `ensure_configured!`'s error message. Just reword; verify no other file has the same cosmetic reference. | Check per-provider; cosmetic only. |
| 5 | `provider.rb`'s `Configuration.register_provider_options` | Keep, unconditionally. A provider file calls it directly after its class body (as `providers/anthropic.rb` does), so every provider's `configuration_options` (`<slug>_api_key`, `<slug>_api_base`, plus whatever else, see below) become real `Configuration` accessors without `Configuration` ever naming a provider. There is no slug registry: nothing resolves a provider by name. | Yes, unconditionally: this is *the* provider-generic seam. |
| 6 | `provider.rb`'s `Provider.for(model)` (via `Models.find`) | Deleted. No model registry, so "resolve a provider by model id" has nothing to resolve against. | Re-evaluate only if/when a `Models` registry is ever vendored. Until then, keep deleted. |
| 7 | `providers/anthropic.rb`'s 6 `include`s + `capabilities` override | Upstream's 6 `include`s were trimmed; `Embeddings`, `Media`, `Models` dropped, and with them the `class << self; def capabilities; Anthropic::Capabilities; end; end` override that only `Models` needed. Caution for the next port: `Media` is used beyond its own file; `Chat`/`Tools` call `Media.format_content` directly as a module-qualified call (not an instance method), so dropping `Media` breaks them unless you replace the call. This branch's fix: `Tools.format_content`, the text-only remainder of the same method (see leak site 9). Do the same for the next provider's own `Media`-equivalent, in whichever of its included modules calls it. Also watch for `Models`-file methods a *kept* module still depends on: `Anthropic::Streaming#build_chunk` called 5 `extract_*` token/model-id helpers that were filed under `models.rb`, not `streaming.rb`, purely by upstream's organization. They are pure Hash digging, no registry involved, so they moved to their only caller (`streaming.rb`) instead of resurrecting a `Models` file for 5 leaf methods. Check every `include`-dropped module for this pattern before assuming "drop the file" is safe. | Partially: the *decision* (drop Embeddings/Media/Models) generalizes to every provider, since none of them need a model registry either. The *mechanics* (what breaks, what moves where) must be re-verified per provider; openai's `Media` and `Models` are separate files from Anthropic's with their own internals. |
| 8 | `message.rb`'s `#model_info` (`RubyLLM.models.find`) | Deleted, and `#cost` with it; `#cost` only existed to call `#model_info` and build a `RubyLLM::Cost` priced off the (also not vendored) `Model::Info`/pricing tables. Cost accounting is `Lain::Usage`'s job. | Yes, unconditionally: `message.rb` is provider-generic; this applies verbatim to every future provider. |
| 9 | `content.rb`'s `Attachment` branch | Deleted outright; `Content` is text-only (`text`, `format`, `empty?`, `to_h`, plus the `Raw` escape hatch). `Message#normalize_content`'s `Hash` branch no longer passes a second `Content.new` argument (that argument was the attachments list). | Yes, unconditionally, **until** an image/PDF/audio-capable provider is actually ported with a real use case. At that point `Content`/`Attachment` need to come back together, deliberately, not leak back in piecemeal. |
| 10 | `provider.rb`'s `UnsupportedAttachmentError`/`require "marcel"` | `validate_paint_inputs!` and `build_audio_file_part` deleted. Also deleted, beyond what the brief named: the public `#paint`/`#transcribe`/`#embed`/`#moderate`/`#list_models` methods themselves; each called at least one rendering/parsing method only `Anthropic::Media`/`Embeddings`/`Models` ever defined (leak site 7), so keeping the public methods without their support modules would have meant keeping methods that always raise `NoMethodError`. `#complete` is the one API this slice exists to serve. | Yes: no provider in this codebase's scope needs image/audio/moderation/embeddings yet. Revisit `Provider`'s public surface, beyond these 2 private methods, when one does. |
| 11 | `anthropic/tools.rb`'s `RubyLLM::Tool::SchemaDefinition.from_parameters` | `Tools.function_for(tool)` now takes any duck responding to `#name`/`#description`/`#input_schema`; exactly `Lain::Tool`. The `params_schema`/`parameters`/`provider_params` fallbacks upstream had are `RubyLLM::Tool`-specific and have no `Lain::Tool` equivalent, so the provider-params merge step is gone with them. | Yes, unconditionally: every provider's tool-schema renderer should target the same `Lain::Tool` duck, not `RubyLLM::Tool`. |

**Unlisted twelfth leak site, found while porting.** `Configuration#log_regexp_timeout=`'s custom setter called `RubyLLM.logger.warn` on Ruby versions predating `Regexp.timeout=`. Dead code on ruby-4.0.5 (which has had `Regexp.timeout=` since 3.2) and, more to the point, the one call in `configuration.rb` that would have reached a global logger. Dropped in favor of the plain generated setter. Check for this kind of "defensive warn" pattern in any `Configuration`-adjacent code the next provider brings; it is exactly the shape that hides a leak the brief's line-numbered table cannot catch, because it wasn't in the *reviewed* file's leak list, only in a *taken* file's implementation detail.

## A file the brief's take-list missed

The base `streaming.rb` (`RubyLLM::Streaming`, top of `lib/ruby_llm/`)
was also missing from the brief's list, which named only
`providers/anthropic/streaming.rb`. The per-provider file supplies
*hooks*; the base file supplies the SSE engine itself. Vendor it once, `include` it into the base `Provider`, and
add its one dependency `event_stream_parser`. See the "Streaming" section
below.

## Kept generic

Each point below was cross-checked against the source of all 13 providers:

- `api_base`, `headers`, `configuration_requirements` and `configuration_options` are overridden by all 13 providers (openai's `headers` even sends 3 different header names (`Authorization`, `OpenAI-Organization`, `OpenAI-Project`) compacted, which is exactly the shape `Provider#headers`'s empty-Hash default exists to be overridden into). Keep them wider than Anthropic's shape.
- `slug` and `models`: no provider overrides them; the base class methods are enough. (This branch doesn't vendor `models` in any form (see leak site 6/8), so there is nothing to check there yet, but `slug` is confirmed generic.)
- The universal streaming hooks are `stream_url` and `parse_streaming_error(data)`. Upstream's Anthropic also defines delta-extraction helpers that read its own `delta.type` values; they are Anthropic-specific and never belong in a shared base.
- `Configuration` must stay dynamic. Nine other providers register their own option sets beyond `<slug>_api_key`/`<slug>_api_base`; openai needs `openai_organization_id`, `openai_project_id`, `openai_use_system_role`; bedrock needs `bedrock_secret_key`, `bedrock_region`, `bedrock_session_token`; vertexai needs a project id and location. Hardcoding Anthropic's 2 keys into `Configuration` would have made every one of those impossible without editing this file per provider.

## Streaming layers

Streaming is split like the rest: a provider-generic base and a provider-specific hook set.

- The base SSE engine is `lib/ruby_llm/streaming.rb` (`RubyLLM::Streaming`, at the top of `lib/ruby_llm/`, not under `providers/`). It is fully generic; it drives Faraday's `on_data`, feeds bytes through `event_stream_parser`, and calls the 2 universal hooks. Vendor it once into `lib/lain/provider/http/streaming.rb` and `include` it into the base `Provider` (done). It needs the `event_stream_parser` gem (MIT, Shopify, zero transitive deps; now a declared dependency). Its only leaks are `RubyLLM.config.log_stream_debug` and `RubyLLM.logger`, both shimmed the same way as everywhere else: an injected `@sink` + `@stream_debug` flag on the provider, `Sink::Null`/`false` default.
- The 2 universal hooks are `stream_url` and `parse_streaming_error(data)`. The base engine calls both on `self` (the provider).
- `parse_streaming_error` lives in both layers. The base has a generic version (in `streaming/error_handling.rb`); Anthropic overrides it in `providers/anthropic.rb` (529 vs 500 on `overloaded_error`). The subclass method wins over the base `Streaming` include, and a provider that defines none falls back to the generic one. When porting a provider, put its `parse_streaming_error` override in the provider class.

## What would force a redesign when the next provider lands

- Bedrock's request signing: Bedrock signs the whole request with SigV4, while `Connection` assumes auth is a header merge.
- Gemini's media/embeddings/images are still separate files, the way Anthropic's were; expect the same "module-qualified `Media.format_content` call from a kept module" trap (leak site 7) there too. Check `Gemini::Chat`/`Gemini::Tools` for calls into `Gemini::Media` specifically before dropping it.
- The OpenAI-compatible shims (`deepseek`, `gpustack`, `mistral`, `ollama`, `openrouter`) subclass `OpenAI`, and `Provider` is not their base. Verified: `class DeepSeek < OpenAI`. This only works once `OpenAI` itself is ported; they cannot be ported before their base class. Plan the wave order accordingly; `openai` is a prerequisite for 5 "one new row" providers, as well as a provider in its own right.

## Specs

Port `error_middleware_spec.rb`, `connection_logging_spec.rb` and
`provider_spec.rb` near-verbatim (namespace swap only); all 3 are already
provider-generic or trivially adapted (see `spec/lain/provider/http/`).

Do not vendor VCR cassettes here. Record them against the transport that
builds the payload, once it exists.


## Anthropic: the default client and the SDK oracle

Anthropic is the one provider with 2 implementations on the same seam.

| | `Provider::Anthropic` | `Provider::AnthropicReference` |
|---|---|---|
| Transport | vendored Faraday + SSE (`lib/lain/provider/http/`) | the official `anthropic` gem (`net/http`, `connection_pool`); lives in `spec/support/provider_oracles/anthropic_reference.rb`, not in `lib/` |
| Role | the default path for `lain chat` | the correctness oracle |
| Capabilities | `streaming`, `prompt_caching`, `strict_tools`, `thinking`, `parallel_tool_use`, `token_counting` | `streaming`, `prompt_caching`, `strict_tools`, `thinking`, `parallel_tool_use`, `structured_output` |

Both share `AnthropicEncoding`, so `#encode` produces byte-identical kwargs and the dry
differential proves it. The SDK is retired only once the vendored path has held: the byte-diff
must match and one live differential run must produce an identical `Lain::Response`.

## Anthropic wire traps

Each of these cost real debugging, and each was verified against the code.

- The stream accumulator is `accumulated_message`; `get_final_message` is the wrong call. The stream is
  single-pass and `accumulated_message` mutates its snapshot.
- On the streaming path with raw-hash tool schemas, `tool_use.input` arrives as a raw JSON
  String. `Provider::Anthropic` parses it, and nothing above the Provider may see it
  unparsed.
- The system keyword is `system_:`, with a trailing underscore. `#encode` returns that form so
  the dry-diff can compare against the oracle; `#complete` rewrites it to the wire `system` and
  adds the top-level `stream` flag. Those are the only 2 places the neutral kwargs and the actual
  JSON body differ.
- A content block's `.type` is a Symbol; comparing it to a String is always false.
- `:model_context_window_exceeded` and `:compaction` are Beta-only stop reasons. The non-beta
  enum is `:end_turn :max_tokens :stop_sequence :tool_use :pause_turn :refusal`, and it is
  non-exhaustive. Always have an `else`.

## Why the Anthropic transport is vendored

`ruby_llm` is not a dependency of any kind, and there is no `Lain::Provider::RubyLLM`. This reverses
an earlier plan (own the loop on the official SDK, keep `ruby_llm` behind a provider seam) after 3
findings:

- **Auth is the same either way.** The API supports exactly 2 auth methods, a Console `x-api-key` and
  Workload Identity Federation. Claude Code's subscription OAuth is, per Anthropic's credential-use
  policy, exclusive to Claude Code and claude.ai. A Console key is required either way, so the gem
  gives no advantage on auth.
- **The gem's loop sits above the seam lain uses.** `RubyLLM::Provider#complete` is already a
  stateless single-shot, and `Chat#complete` owns the loop above it. Lain uses the single-shot and
  never touches `Chat`.
- **Their message model is lossy for this project.** `parse_completion_response` joins every text
  block into one String, joins every thinking block, and keeps only the first thinking block's
  signature, which destroys the original content array. Lain must commit the full block list, and
  extended-thinking signatures must be echoed back verbatim.

## Live Anthropic specs

The `:api_integration` specs hit the live API and cost money. They run only with both:

```bash
LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
```
