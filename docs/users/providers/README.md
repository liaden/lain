# Providers

Lain talks to a provider through a single HTTP round trip with no loop. A provider declares
its `capabilities`, encodes a provider-neutral request into a wire payload (so the payload can be
byte-diffed and reasoned about for caching), and completes a request into a provider-neutral
response. `Lain::Request` and `Lain::Response` are the value objects each provider translates to and
from.

Three live backends ship on that seam, plus `Provider::Mock` for specs. They are the
3 `--provider` values below; the 2 ollama rows are one backend under 2 deployments. Each doc covers setup, that
provider's capability mask, and the wire quirks that cost real debugging.

| Provider | `--provider` | Default model | Doc |
|---|---|---|---|
| Anthropic | `anthropic` | `claude-opus-4-8` | [docs/users/providers/anthropic.md](anthropic.md) |
| Ollama (local) | `ollama` | `qwen3:4b` | [docs/users/providers/ollama.md](ollama.md) |
| Ollama Cloud | `ollama-cloud` | `gpt-oss:20b-cloud` | [references/ollama/cloud.md](../../../references/ollama/cloud.md) |

The 2 ollama rows are one backend with 2 deployments. `ollama.com`
serves the same native `/api/chat` a local `ollama serve` does, so `Provider::Ollama` picks a
`Deployment` and the encoder, decoder and wire format stay byte-identical across the pair. Only hosting and the models on offer differ between the 2.

Running Ollama Cloud needs a key:

```bash
export OLLAMA_API_KEY=...                  # create one at https://ollama.com/settings/keys
exe/lain chat --provider ollama-cloud      # defaults to gpt-oss:20b-cloud
```

With `OLLAMA_API_KEY` unset lain refuses before it constructs anything, and the refusal names
the variable, the flag that asked for it, and where a key comes from. `--api-base` still moves the
endpoint, but the cloud deployment requires https, so it never sends a bearer token in plaintext.

Concurrency starts at 3 requests at once; `LAIN_PROVIDER_CONCURRENCY` sets another width.
When the server answers a request with a concurrency 429 that carries `x-ratelimit-max-concurrent`,
the gate narrows to that number and the narrowing is journaled. The gate only lowers its width.
A plan with no server queue can fail the requests already in flight past its limit before the narrowing
lands; later requests run at the narrowed width. A cloud launch prints the width in force and the
variable that changes it.

> **Ollama Cloud output varies between runs.** Measured against a live subscription on
> 2026-08-24: `temperature 0`, a fixed seed and warm runs returned 3 distinct completions
> from 3 measured runs. The cause is not established. If you compare results, take several
> samples rather than one, and do not assume the repeatability a local Ollama usually has
> (itself high-probability, not guaranteed). The full measurement is in
> [references/ollama/cloud.md](../../../references/ollama/cloud.md).

`anthropic` is `Provider::Anthropic`, on lain's own HTTP transport. The official SDK is not a runtime
dependency.

Ollama is worth installing if you want free local summaries: `--summarizer-provider ollama`
runs the compaction summarizer there. See [Compaction and summarizer
tiers](../compaction.md).

Porting a fourth provider is documented in
[`docs/devs/porting-providers.md`](../../devs/porting-providers.md): the 4 wire protocols, the 11 leak sites,
and what would force a redesign.

The default Claude transport is vendored from `ruby_llm`'s HTTP layer (MIT, © 2025 Carmine
Paolino); the gem is not a dependency. Why, and what was stripped, is in
[docs/users/providers/anthropic.md](anthropic.md#the-vendored-transport).
