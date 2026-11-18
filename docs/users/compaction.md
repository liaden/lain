# Compaction

Compaction is on by default in `lain chat`. It runs in 3 tiers, and only one of them costs a
model call. Each tier only sees what the one before it declined.

Tier 0 is yours and free. Summarizers you declare in `.lain/summarizers.rb` are pure Ruby with no provider
and no IO, so they cost neither tokens nor latency. Each one answers 2 questions about 1 tool
result: `suitable?` and `compact`. They live in one object because "can I compress this" and "how"
are the same knowledge.

```ruby
# .lain/summarizers.rb
summarizer "rspec" do
  def suitable?(result) = result.tool_name == "bash" && result.text.include?("examples,")

  def compact(result) = result.text.lines.grep(/examples,|^rspec /).join
end
```

A `Summarizer::Result` carries `tool_name` and `text`, because some kinds are distinguishable by
tool and some only by content (a coverage report and a build log are both `bash`). Declaration order
decides between 2 suitable summarizers: the first declared wins, which you can see in
your own file.

A typo'd verb, a duplicate name, and a bodyless declaration are each refused by name
at load. A summarizer that raises falls through to tier 1 and the summary is kept. That includes
the half-written states, a `NotImplementedError` from a method you have not got to yet or a
`SystemStackError` from a predicate that calls itself. One returning blank is refused loudly. An
absent file is an empty catalog and never an error.

One failure nothing contains is a predicate that never returns: your `suitable?` runs on the
fiber that observed the tool result, so a loop there blocks that turn, with no timeout, once per tool
result. Keep predicates finite and cheap. They are consulted for every result, and the large
ones are not the only ones. `Lain::Summarizer`'s own docstring has the mechanism.

`/meta summarizer <prompt>` will draft one for you into `.lain/summarizers/` for review. Nothing
loads that directory. Copy the declaration into `.lain/summarizers.rb` yourself once you have read
it.

Tier 1 is eager and model-backed. When a tool result lands and no tier-0 summarizer claimed it,
`Oracle::Eager` fires a summary on its own `Async` task and holds the answer against the result's
content address. It fires once per distinct result, off the turn's critical path, but it only
asks a model above 4 KiB, because that gate is a cost policy and tier 0 has no cost to gate. A
smaller unclaimed result is left unsummarized, and renders as the same attested elision a
summary still in flight does.

The summarizer is chosen independently of the chat: `--summarizer-provider`,
`--summarizer-model`, `--summarizer-max-tokens`. It follows the chat's provider by default.
`--summarizer-provider ollama` keeps a local Ollama `qwen3:4b`, because
paying frontier-model tokens to compress a tool result usually costs more than resending the result.
When it is a paid tier, its spend lands on the record as a `Telemetry::OracleAnswer` carrying the
model and real usage. A summarizer that spent silently would leave the ledger wrong.

Tier 2 is the compacting turn, and it is pure. When the head grows past the threshold, the run materializes
a derived context timeline and collapses the head's span into it, reading the summaries the
tiers above already produced out of a frozen `Compaction::SummarySnapshot`. No model call, no
network, deterministic bytes. A result with no held summary renders as an elision line. What
that derived lineage is, and why it is a second timeline and not a rewritten array, is the
next section.

To turn the local tier 1 on:

```bash
ollama serve            # http://localhost:11434
ollama pull qwen3:4b    # Provider::Ollama::DEFAULT_MODEL
```

With Ollama absent or the model unpulled, the fire fails inside its task boundary and nothing
raises. You get elision lines in place of summaries, which is a less useful compaction and not
an error. `--api-base` moves whichever of the chat and the summarizer is on Ollama.

Pinned history. [`/pin`](commands.md#pin) marks a turn the compactor may not touch, and
`/goal`'s objective is pinned automatically once it enters the timeline. A pin is a turn digest
recorded on the `Session`, journalled, and replayed on `--resume`. Both halves of the pipeline honor
the same pin set: the candidate head excludes pinned turns, and the derivation treats a pin as a
cut point and not a shield, so the pinned turn is retained verbatim in position, between
the collapses of what preceded and what followed it. Pinning enough can leave a compaction with
nothing worth removing, which the journal records as a decision that would not shrink rather than a
compaction that did nothing.

Compaction prices every decision from its own `PriceBook`, which degrades to zero for a model with
no list price rather than crashing a local chat mid-conversation. `Telemetry::Compaction` records
the model those figures are quoted in, so a zero beside `qwen3:4b` reads as the fallback it is. When a run switches models mid-session, the cost fields are absent and are not repriced, since a
figure quoted against a model that did not run is worse than no figure. The record still names the
model the compaction actually ran under.

Knobs: `--no-compact`, `--compact-bytes` (default 262144, roughly 64k tokens), `--compact-cap`
(1048576, forces a compaction even while the cache is warm), `--compact-keep` (20 trailing messages
left verbatim), and `--compact-strategy` (below; it swaps the collapse policy and leaves compaction
itself on). The window that triggers a compaction follows the live model, re-derived each turn, so
switching to a larger-window model mid-session widens the runway instead of leaving the old ceiling
in force. A finished session's journal shows which of these the run was fighting: approval churn, compaction
thrash or iteration ceilings. The developer tool that reads it back is in
[`docs/devs/qa-lain.md`](../devs/qa-lain.md#qa-lain-friction).
