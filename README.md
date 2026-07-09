# Lain

Lain is an agent harness for Claude, built as a study bench for LLM orchestration and tool design. It is a hand-rolled agentic loop whose distinguishing property is not that it drives a coding agent well, but that its context strategies, tool designs, and orchestration tactics are swappable, observable, and comparable against one another.

## What Lain is, and what it is not

Lain is a bench. The agent is the vehicle; the bench is the deliverable. A conventional agent optimizes for completing a task. Lain optimizes for making the *strategies behind* the task first-class objects you can substitute, journal, replay, and diff. If the agent itself is only mediocre but you can demonstrate which tool description raised the correct-call rate, or which context strategy survived a provider swap, the project has done its job.

Lain is **not** a competitor to Claude Code. Feature parity is irrelevant here, and it is not a goal. Lain also does not use either provider SDK's built-in agentic loop (`tool_runner`, `Chat#complete`). Those loops work, but they own the loop, and the loop is precisely the object of study. Lain owns its own loop so that every turn passes through seams it can measure.

The motivating context is worth stating plainly, because it explains every design choice below. The author already knows how to judge correctness in Ruby software development, so it is a domain where a mediocre-but-measurable agent teaches something real: you can eyeball whether the agent was right, and then trust the mechanical numbers the bench reports alongside that judgement. The intent is that the intuition transfers to a domain where correctness *cannot* be eyeballed, namely LLM tool-call systems that synthesize medical literature. The bench exists to make that transfer possible.

## Status

This is early. Milestone M0 (housekeeping) is in progress, and **nothing works end to end yet**. The gemspec has been settled, this README has been written, and the build scaffolding is being brought into shape. The objects described below are the intended design, not shipped, working code. Where this README shows an API, for example `Lain.agent(tools: [...])`, treat it as the target design rather than behavior you can run today. Nothing in the "Core design" or "The bench" sections should be read as a description of code you can currently execute.

The milestone plan, in brief:

- **M0 (in progress).** Settle the gemspec, rewrite this README, and get `bundle install` and `rake compile` passing. The Rust extension stays stubbed and compiling.
- **M1.** The spine: canonical serialization, `Turn`, `Timeline` (pure Ruby first), the provider-neutral request/response value objects, the `Provider` interface with `Provider::Anthropic`, tools and toolsets, effects, the model and tool middleware phases, the live handler, the agent state machine, and a TTY frontend. Seven correctness gates ship as specs.
- **M2.** Observability: the `Journal` as an NDJSON event bus, per-turn usage and dollar cost, and a recording handler. Measurement comes before the seams, because a seam you cannot measure is decoration.
- **M3.** The algebra with property-tested laws, the composable `Context` combinators, all four middleware phases, the second provider (`Provider::RubyLLM`, after a timeboxed spike), machine-checked provider capabilities, and the bench (`DryReplay`, `LiveReplay`, `Grader`, `Compare`).
- **M4.** The Timeline reimplemented in Rust behind the same interface with the same property tests, plus a Neovim frontend.
- **M5.** Orchestration (subagents, todos), cross-session memory, and code mode.
- **M6.** A second round of Rust work and a sweep of retrieval strategies through the bench.

## Requirements

- Ruby `>= 3.2.0`.
- `ANTHROPIC_API_KEY` in the environment. Anything that talks to the Claude API reads it. Without it, only offline paths (for example, dry replay over a recorded session, once that exists) can run.

## Core design

The load-bearing idea is that tool design, context management, and orchestration are not three separate subsystems. They interlock. A tool's result shape *is* context, because the result lands in the message log and is then cached, pruned, and compacted. A context strategy decides which tool results survive, which changes what the model believes it has already done. A subagent is a tool whose result is a compressed context, which makes orchestration a form of context management. Lain treats these as three views of one pure function that renders a `Context`, a `Timeline`, and a toolset into a provider request, and it makes that function a first-class, composable object so that a recorded session can be replayed under a different strategy and diffed.

### The Timeline is a lossless content-addressed Merkle DAG

The conversation history is stored the way git stores commits. A `Turn` is a frozen node carrying a role, its content blocks, and the hash of its parent. Its own hash is the SHA-256 of a canonical serialization of those fields. Crucially, hashing is used for *identity, not storage*: the hash is a derived name, and the full content lives in a store keyed by that name. Nothing is discarded.

Because names are hashes, comparison, deduplication, and cache-break detection are cheap pointer-level operations, while inspection reads the store. Branches share the hashes of their common prefix, so the store holds a single copy of any shared history. Four properties fall out of this one structure: forking is O(1), time-travel operations (checkout, rewind, branch listing) are natural, prompt-cache-break localization is free (walk two chains and the first differing hash is where the cache died), and deduplication across branches is automatic.

One concrete payoff illustrates why the structure is worth the trouble. Naively summing token usage across a branched timeline double-counts the shared prefix. Aggregating over the set of *unique reachable hashes* is correct by construction, with no special-casing.

The canonical serializer (sorted keys, stable ordering) serves two masters at once: it backs turn hashing, and it backs deterministic tool-schema serialization for prompt-cache stability. One function, two invariants. The Timeline is also the honest first home for the Rust extension, because Ruby has no good persistent, structurally-shared DAG and Rust's ownership model is exactly the right tool for one. The Timeline ships as pure Ruby first, behind the same interface, so the eventual Rust version is a swap rather than a rewrite.

### Tool calls are effects interpreted by a middleware stack

Tool dispatch, middleware, and journal replay are collapsed into a single idea. A tool call is an *effect*, and an effect is interpreted by a *handler*. The public API is the familiar Rack, Sidekiq, and Faraday middleware idiom (`#call(env) { |env| ... }`), the effects are the implementation story underneath, and the composition law is what gets verified: middleware composition is associative, and a pass-through is the identity. In that framing, middleware is handler composition, and **deterministic replay is simply a recorded handler** rather than a live one.

There are four middleware phases, all sharing one protocol: a model stack wrapping each provider completion (retry, cost accounting, cache instrumentation, request logging), a tool stack wrapping each tool call (approval gate, timeout, contract checking, result truncation, journaling), a turn stack wrapping each agent turn (budget, iteration ceiling, interrupt, speculative fork), and a REPL stack wrapping each REPL command. Because middleware ordering is the classic Rack footgun, the stacks are inspectable and mutable in the Sidekiq style, with `to_a`, `insert_before`, and `insert_after`.

The model middleware phase is load-bearing rather than decorative, for a transport reason. The official `anthropic` gem uses `net/http` and `connection_pool`, not Faraday, so Faraday middleware cannot wrap the Claude path. The model phase is therefore the single layer at which both transports look identical to the bench, which is why retries, cost accounting, and cache instrumentation live there rather than in any provider's own HTTP stack.

### Context is a monoid of message transformations

Pruning, compaction, cache-breakpoint placement, and reminder injection are not rival subclasses to choose between. Each is an endomorphism on the message list, and they compose associatively with pass-through as the identity:

```ruby
# Target design, not shipped behavior.
ctx = Prune.new(keep: 3) >> Compact.new(at: 150_000) >> CacheBreakpoints.new
```

Because composition is associative and lawful, the bench can sweep the entire lattice of combinations rather than a fixed menu of hand-written strategies. The associativity is property-tested, because a `Context` combinator that is not associative silently produces different prompts depending on composition order, which is exactly the class of bug ordinary unit tests miss.

### Tools are capabilities, not permissions

A subagent holds the tools it was handed, attenuated at construction time (for example, `toolset.only(:read_file, :grep)`). The answer to "what can this subagent do" is one line of code you can read, not a policy engine you have to audit. There is no permission layer to consult; possession of the tool *is* the authorization.

### Putting it together

The agent is an explicit state machine, not a while-loop with a stack of conditionals. Its states (awaiting model, awaiting tools, awaiting approval, awaiting user, done, failed) make `stop_reason` handling total: refusals, token exhaustion, paused turns, and context-window-exceeded conditions are transitions rather than branches someone might forget to write, and each provider normalizes its own stop reasons into this shared set. Everything a frontend shows is a projection of the `Journal` event stream; the TTY, Neovim, and the bench all subscribe, and editor code never reaches into the agent.

## Providers

Both provider paths are first-class targets, but they are deliberately **not** symmetric, and pretending otherwise would silently corrupt the bench.

`anthropic` is a hard dependency and the reference implementation. It is declared in the gemspec, and the Anthropic provider is the path against which every design decision is validated first.

`ruby_llm` is a **supported optional** dependency. It is deliberately *not* in the gemspec's dependency list, because declaring it there currently blocks dependency resolution and would force it on every user of the reference Anthropic path. To use the multi-provider path, install it separately:

```bash
gem install ruby_llm
```

`Lain::Provider::RubyLLM` requires the gem lazily and raises a helpful `LoadError` if it is absent, so the Anthropic path never pays for a dependency it does not use.

The seam between Lain and any provider is a single HTTP round trip with no loop: a provider declares its `capabilities`, encodes a provider-neutral request into a wire payload (so the payload can be byte-diffed and reasoned about for caching), and completes a request into a provider-neutral response. `Lain::Request` and `Lain::Response` are provider-neutral value objects that each provider translates to and from. This anti-corruption layer is what makes both deterministic dry replay and honest cross-provider comparison possible. It also means RubyLLM is demoted from an agentic loop to a plain completion engine, because Lain must own the loop.

### The honest asymmetry

The two providers do not offer the same capabilities, and this matters more than it might first appear. RubyLLM 1.16 has no server-side tools, no MCP connector, no memory tool, no Agent Skills, and no Batches or Files support. If you were to A/B a medical prompt across the two providers and half of your context tactics silently became no-ops on one of them, the comparison would be a lie.

Lain therefore makes capabilities machine-checked rather than merely documented. A `Context` combinator declares what it requires, and a provider declares what it has:

```ruby
# Target design, not shipped behavior.
class CacheBreakpoints < Lain::Context
  requires :prompt_caching
end

class Compact < Lain::Context
  requires :server_compaction   # Prune requires nothing; it works everywhere.
end
```

When a run mounts a strategy the provider cannot support, the policy is explicit and set per run: `:strict` raises, `:degrade` turns the tactic into a no-op but warns and records the degradation in the journal, and `:simulate` approximates it client-side. Bench runs default to `:degrade` so a sweep never dies mid-flight, while anything real defaults to `:strict`. Unsupported tactics degrade *loudly*, never silently, and the comparison tooling refuses to compare two runs whose degraded-capability sets differ unless you explicitly opt in. This turns "which of my context tactics survive a provider swap" from a footnote into a question the bench answers, which is why the provider is a swept axis alongside context rather than an afterthought.

## The bench

Once the spine and the seams exist, the bench replays recorded sessions under different strategies and reports distributions rather than anecdotes. There are two replay modes, and conflating them is the mistake to avoid. *Dry replay* re-renders requests under a different context or provider encoding from a recorded timeline; it is free, instant, deterministic, and byte-diffable, and it is the unit test for context strategies. *Live replay* re-runs against the API; it costs money and is nondeterministic, and it is the experiment. Comparisons report distributions over many runs, because a single-run A/B is noise.

The grader is load-bearing, not a nice-to-have. Mechanical metrics (tokens, cache-hit ratio, turn count, tool-call histogram, wall time, cost) say nothing about whether the agent was actually *right*. In Ruby you can eyeball correctness and then trust those numbers; in medical synthesis you cannot, which is the entire reason the bench exists. The intended grading surfaces are a fixture grader with hard, deterministic assertions and a rubric grader that uses an LLM judge in a separate context window against explicit, independently-gradeable criteria.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will let you experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/joeljohnson/lain. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/joeljohnson/lain/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Lain project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/joeljohnson/lain/blob/main/CODE_OF_CONDUCT.md).
