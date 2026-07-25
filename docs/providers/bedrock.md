# Bedrock

Anthropic models through AWS Bedrock's Mantle endpoint, on the official SDK's
`Anthropic::BedrockMantleClient`.

Mantle speaks the plain Anthropic Messages API over SSE (model in the body, ordinary streaming),
so `AnthropicEncoding` is shared verbatim with [`Provider::Anthropic`](anthropic.md). Only the
client, the model ids, and the endpoint differ.

## Setup

Bearer/API-key mode only. `api_key:` (or `AWS_BEARER_TOKEN_BEDROCK`) sends
`Authorization: Bearer` and never signs with SigV4.

```bash
export AWS_BEARER_TOKEN_BEDROCK=...
export AWS_REGION=us-east-1
lain --provider bedrock
```

There is no `--api-key` or `--region` flag. The Mantle client reads both from the environment
itself, or from `api_key:` / `aws_region:` when you construct `Provider::Bedrock` directly.

`aws-sdk-core` is a gem dependency for exactly one reason: the SDK requires it eagerly at client
construction, before it branches on auth mode. Bearer mode never uses it.

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

Every `Anthropic::Errors::*` is wrapped so nothing above the Provider ever rescues an SDK class.
The original survives as `#cause`.

- `Provider::Bedrock::APIError` is the base, and it is a `Lain::Error`.
- `Provider::Bedrock::APIStatusError` carries `#status` as an Integer, lifted out of the SDK
  error so you can branch on the HTTP status without unwrapping `#cause`.
