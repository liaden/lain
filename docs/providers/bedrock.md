# Bedrock

Anthropic models through AWS Bedrock's Mantle endpoint. `--provider bedrock` builds
`Provider::Bedrock`, which reaches Mantle over Lain's own vendored Faraday transport — the same
stack `Provider::Anthropic` uses for the direct API.

`Provider::BedrockReference`, on the official SDK's `Anthropic::BedrockMantleClient`, is the
`#encode` differential ORACLE that arm is byte-diffed against. It lives in
`spec/support/provider_oracles/` and no run constructs it, which is why neither `anthropic` nor
`aws-sdk-core` is a runtime dependency.

Mantle speaks the plain Anthropic Messages API over SSE (model in the body, ordinary streaming),
so `AnthropicEncoding` is shared verbatim with [`Provider::Anthropic`](anthropic.md). Only the
endpoint, the credentials, and the model ids differ.

## Setup

Bearer/API-key mode only. `api_key:` (or `AWS_BEARER_TOKEN_BEDROCK`) sends
`Authorization: Bearer` and never signs with SigV4.

```bash
export AWS_BEARER_TOKEN_BEDROCK=...
export AWS_REGION=us-east-1
lain --provider bedrock
```

There is no `--api-key` or `--region` flag. `Provider::Bedrock` reads both from the environment
itself, or from `api_key:` / `region:` when you construct it directly. (The
`Provider::BedrockReference` oracle takes `aws_region:` instead — the SDK's own keyword.)

`aws-sdk-core` is a **test** dependency for exactly one reason: the SDK requires it eagerly at
client construction, before it branches on auth mode, so the oracle cannot be built without it.
Bearer mode never uses it, and the shipped arm never loads it.

## Model ids

Bedrock model ids carry the `anthropic.` vendor prefix. `DEFAULT_MODEL` is
`anthropic.claude-opus-4-8`.

```bash
lain --provider bedrock --model anthropic.claude-opus-4-8
```

`PriceBook`'s family-substring matching resolves the prefixed ids unchanged, so cost accounting
needs no translation table.

**A "model does not exist" error is usually a region or endpoint mismatch, not a bad id.** Bare
`anthropic.`-prefixed Mantle ids are correct as written. Check `AWS_REGION` and the SDK's
resolved endpoint before you start rewriting the id with account prefixes or inference-profile
ARNs.

## Capabilities

`streaming`, `prompt_caching`, `thinking`, `parallel_tool_use`.

**`strict_tools` is deliberately absent**, and it is the clearest live example of why
`Capability::Policy` exists. Mantle's request validator rejects the tools' `strict` field
outright: `tools.0.custom.strict: Extra inputs are not permitted`, a real 400.
`AnthropicEncoding#mask_strict` keeps the field off the wire for this provider.

A run that mounts a `strict_tools`-requiring tactic against Bedrock resolves under the run's
capability policy: `:strict` raises, `:degrade` no-ops the tactic and records the degradation in
the Journal. `Capability::Guard` then refuses to compare a Bedrock run against a direct-Anthropic
run whose degraded set differs, unless you opt in.

`cache_profile` is `CacheProfile::ANTHROPIC`, the same as the direct path, so the 4096-token
minimum cacheable prefix applies here too.

## Errors

Every transport failure is wrapped so nothing above the Provider ever rescues a Faraday (or, in
the oracle's case, an SDK) class. The original survives as `#cause`.

- `Provider::Bedrock::APIError` is the base, and it is a `Lain::Error`.
- `Provider::Bedrock::APIStatusError` carries `#status` as an Integer, so you can branch on the
  HTTP status without unwrapping `#cause`.

`Provider::BedrockReference` defines its own same-named pair with no shared ancestor beyond
`Lain::Error`. Rescuing "a Bedrock API error" across both means handling both explicitly.
