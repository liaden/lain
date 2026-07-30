# Tools and ToolUse: what more algebra would buy

status: research, 2026-07-29. Nothing here is a commitment; each idea names the follow-up
shape it would take and what it would cost under the registry's rules.

## The question

Would adopting more concepts from abstract algebra or category theory improve how Tools and
ToolUse are modeled? Asked as research to plan future work, after the algebra-vocabulary chunk
landed the registry, the 5 structures, and the sweep.

## The rules any answer inherits

The algebra chunk set 3 rulings that bound every proposal below
(`planning/specs/chunk-algebra-vocabulary.md`):

1. **No structure without a named consumer.** Group, ring, functor, and category were excluded
   on purpose. The bar is a bug class ruled out or a bench axis opened, not prior art.
2. **A declaration is an obligation.** Each one costs a generator in
   `spec/support/algebra_generators.rb`, or `spec/algebra_laws_spec.rb` fails by name.
3. **Negatives have equal rank** and need a recorded reason. The instructive entries in this
   codebase are often refutations (the derivation non-functor, `causal_meets`).

So each candidate gets judged on: what law, held by what, catching what, at what generator cost.

## What the tool layer already maintains, with no declaration saying so

| Structure | Where | Evidence today |
|---|---|---|
| Attenuation is strictly decreasing | `Toolset#only`/`#except` (`toolset.rb:75`, `:86`) | doc comment + example specs; no law group |
| Union exists only below the trust boundary | `Toolset.new(base.to_a + [...])` (`cli/wiring/toolset_build.rb:70`); no `#|` on the class | implicit; nothing states it |
| `parallel_safe?` is a commutation claim | `tool.rb:111`, consumed by `ToolRunner#gather` | `parallel_safety_spec.rb` pins *which* tools claim it; `tool_runner_spec.rb` pins the scheduler; the claim's own semantics are untested |
| The barrier partition is an interval partition | `ToolRunner#contiguous_runs` (`tool_runner.rb:191`) | `chunk_while` makes well-formedness structural; the glossary entry covers only compaction's instance |
| Handler chains are an ordered union of partial interpreters | `Effect::Handler` (`handler.rb:33-41`) | doc comment ("the handler is the algebra"); no law |
| Two enforcement semantics for one attenuation | `SpawnPolicy::AttenuationPosture` (`spawn_policy.rb:238`) | compared by the bench (CE-4); equivalence untested |

The pattern from the chunk repeats here: real structure, evidenced only by how methods happen
to behave.

## Ideas, ranked

Ranked by consumer strength. 1 and 2 guard semantics that are live today; 3 makes the security
model checkable; the rest are cheaper and smaller.

### 1. The exchange law behind `parallel_safe?`

`parallel_safe?` is a claim that a tool's dispatch commutes with any other safe tool's. The
category-theory name is centrality (a central morphism in a premonoidal category commutes with
everything); the useful residue is one property, no new vocabulary:

> For parallel-safe tools `t1`, `t2` and fixed inputs, `[t1, t2]` sequential, `[t2, t1]`
> sequential, and the gathered fan-out all produce the same results and the same observable
> session state.

**Consumer.** The boolean already ships and already decides concurrency
(`ToolRunner#gatherable?`). Today a false claim is a silent data race; under the law it is a
red spec. `parallel_safety_spec.rb` pins the partition's membership, so the two specs would
cover complementary halves: who claims it, and whether the claim is true.

**Cost and shape.** Per-tool generators over a temp workspace, realistic for the read-set
(`read_file`, `grep`, `glob`, `list_files`), probably a tagged sweep since it runs real
dispatches. This does not fit the existing 5 structures, so it either extends
`Algebra::STRUCTURES` (`:commuting`, refutable in the house style: `bash` would carry the
refutation with "the model controls the command string" as its reason) or lands as a plain
shared example group first. The group alone captures most of the value.

### 2. Posture equivalence, for bench honesty

`AttenuationPosture::Schema` and `HandlerUnion` are 2 enforcement semantics for one
attenuation, and CE-4 compares their cache economics. That comparison measures cache only if
the 2 postures agree on everything else. The law:

> For any call naming an *allowed* tool, dispatch under Schema and under HandlerUnion produce
> equal results. For a *disallowed* name, Schema's refusal is absence from the rendered schema
> and HandlerUnion's is an `is_error` tool_result; the difference is exactly and only that.

**Consumer.** Bench validity, the same argument that gives `Capability::Guard` its job: 2 arms
that differ semantically are not an A/B on cache. Shape: a shared example group over the spawn
seam with `Provider::Mock`, no new registry structure.

**A negative worth recording beside it.** Under HandlerUnion, 2 children with different `only`
sets render byte-identical tools blocks, so the rendered schema does not determine the
capability set. That is by design (sibling cache sharing is the point), and it quietly breaks
the "read the schema to know what it can do" intuition that holds everywhere else. One
sentence in `docs/GLOSSARY.md` or the posture's doc comment would keep a later reader from
"fixing" it.

### 3. Attenuation laws on `Toolset`, and the refused join

The order-theoretic reading: Toolsets under capability inclusion, with `only`/`except` as
strictly decreasing maps. The laws worth holding:

- idempotence: `ts.only(*a).only(*a) == ts.only(*a)`
- composition: `ts.only(*a).only(*b) == ts.only(*(a & b))` when `b ⊆ a`, raises otherwise
- duality: `ts.except(*a) == ts.only(*(ts.names - a))`
- monotonicity: the result's names are a subset of the receiver's, for every attenuation

And the declaration that carries the security model, in the house negative form:

```ruby
not_a_join_semilattice on: :only,
                       because: "a capability once dropped cannot be regained by the holder; " \
                                "union exists only at construction, below the trust boundary"
```

**Consumer.** "Possession is authorization" currently rests on doc comments and frozen-ness.
The laws make it property-tested, and `SpawnPolicy#attenuate` (which is `union.only(*only)`)
rides the same group for free.

**Prerequisite, and the real cost.** The laws need `Toolset#==`, which does not exist. Tools
are behavior-bearing objects, so full `Regular` is out of reach; the honest equality is names
plus canonical schema bytes (`Canonical.dump(to_schema)`), which is also the equality prompt
caching already lives by. Deciding and spec'ing that equality is most of this idea's work, and
it needs care not to claim more than it means (2 tools with equal schemas and different
`#perform` bodies would compare equal).

### 4. Attenuation commutes with rendering

`ts.only(*a).to_schema == ts.to_schema.select { name in a }`: rendering is elementwise in the
capability set, so attenuating-then-rendering and rendering-then-filtering agree. Small, rides
idea 3's group. The consumer is deferred disclosure: `Toolset::Disclosure` arms render *from*
the set, and this law is what makes "the catalog never shows a capability the set lacks" a
property rather than a review item.

### 5. A used-capability ledger, the dual monoid

The Journal already records every tool call. Folding each session's used-tool-name set with
union is a commutative idempotent monoid, which is the same fold-order-independence argument
`Usage` makes for token totals. The payoff is a bench metric, held-versus-used per role, and
a least-privilege miner that suggests `only(...)` lines from observed sessions.

This is graded-effect thinking (Katsumata's parametric effect monads) with the grading monoid
kept and the monad dropped. It also stays consistent with the standing ruling that accounting
reads from the Journal, never `turn.meta`, so the digest stays content-only. The algebra here
is trivial; the value is the metric, so this is a bench feature first and a declaration second.

### 6. A pipeline algebra over whitelisted commands (Joel's pipe idea)

Joel's original thought: let whitelisted tools compose, so `grep pattern | rspec` is
considered safe because it was built as a composition of safe pieces rather than as a shell
string. This supplies the consumer the Kleisli rejection below said was missing, and it lands
inside the existing vocabulary.

**The structure.** Processes under pipe compose associatively, and `cat` is literally the
identity element, so pipeline terms over untyped byte streams are a monoid. Typing the ends
(what stdin accepts, what stdout yields) is what would upgrade it to Kleisli composition;
nothing needs the types on day 1.

**The tier axis survives by construction.** Tier 3 gates because the model controls a string
handed to `sh -c`. A pipeline term is data: a list of argv arrays plus one combinator, and
stdlib `Open3.pipeline` runs it with no shell anywhere. So this is tier 2 closed under pipe,
and "does the model control the command string" stays false because there is no string. The
term form matters: `[["grep", "pattern"], ["rspec"]]`, never a `"grep pattern"` string that
gets re-split.

**Capability semantics compose for free.** A term is authorized iff the Toolset holds every
component, so `only(:grep, :rspec)` already bounds the expressible pipelines, and attenuation
needs no new mechanism.

**The trap, and the law that matters.** Pipeline safety is not the conjunction of each
component's tier-2 safety. Tier 2 means "safe given model-controlled argv". Pipe opens a
second channel: stdin now carries bytes influenced by the previous stage. A command that
executes its stdin (`psql`, `ruby`, `sh`) is tier-2-safe alone, with fixed argv, and unsafe
downstream of a pipe. So pipeline membership needs a stronger per-tool predicate, "safe under
arbitrary stdin", declared per tool like `parallel_safe?` is, defaulting false. The algebraic
statement is that those tools form a **submonoid**: closed under pipe, so safety is inductive
over terms and a compound never needs its own review. `parallel_safe?` composes the same way,
as conjunction over components.

**Consumer.** Shrinks the approval surface: compound read-and-analyze commands stop being
gated tier-3 bash calls. If any current or future tool exists mainly to avoid a gated bash
compound, it collapses into a term. The bench gains too: a term is journal-able,
content-addressable data, so dedupe and replay come free where a bash string is opaque, and
"one bash tool" versus "pipeline terms" becomes a tool-design arm.

**Cost.** A term `Tool::Input` (list of argv arrays), an evaluator on `Open3.pipeline`, the
new stdin-safety declaration per tool, and a placement question if pipelines get long-running
(process management for the exec arm lives in `lain-core` today). This is a feature chunk
with an algebra inside it, not a declaration retrofit. It is also the one idea in this doc
that simplifies anything, by cutting approval prompts and by capping the number of bespoke
compound tools anyone needs to write.

### 7. Glossary additions, zero code

- `ToolRunner#contiguous_runs` is the second interval partition in the codebase, and
  `chunk_while` is the same trick `Algebra::Elementwise` uses: the structure is generated, so
  well-formedness cannot be broken through that door. The glossary entry currently names only
  compaction's instance.
- Handler chains are a left-biased union of partial interpreters, with the base Handler (which
  handles nothing and only delegates) as the identity. Naming the left bias also names the
  shadowing risk: 2 handlers claiming the same effect resolve to the outermost, silently. No
  chain today has that overlap; a sentence saying so costs less than debugging it later.

## Considered and rejected

**Free monad over `Effect`.** The 2-level split that a free monad exists to provide (pure
effect data + a swappable interpreter) is already built, and `effect.rb`'s doc comment states
it. Full reification would add a bind tree: inspectable multi-step intentions before any
execution. Nothing consumes such a tree, the loop is the object of study and stays visible in
Ruby, and `Effect::Approval` already reifies the one wrapper gating needed. Revisit only if
something needs to *statically analyze* a multi-effect plan before running it.

**`Tool::Result` as a monad.** Results never compose with each other inside lain; each one
returns to the model as a `tool_result` block. There is no bind call site, so the structure
would have zero consumers.

**Tools as Kleisli arrows, Toolset as a category.** Rejected for the tools as they stand:
there is no second category to map to and no composition of tools (tools do not call tools).
Idea 6 revises this: pipe composition of whitelisted commands is a real composition with a
real consumer, and its useful residue is a monoid plus a submonoid safety claim, with the
Kleisli typing held in reserve until something needs typed ends.

**A term algebra of orchestration topologies.** The bench enumerates context strategies as
words in a free monoid; the same move on `Arm` (a grammar of spawn combinators, swept
mechanically) is attractive and would make topology space enumerable rather than hand-listed.
Deliberately not proposed here: it collides with the in-flight epic-orchestration research,
and `Arm`'s seam is minimal on purpose. Raise it as a question in that review instead.

**Optics/profunctors for `Tool::Input`.** One declaration already yields both schema and
validation; there is no second representation to keep in sync, so the machinery has no job.

## Building past the rejections

Round 2, 2026-07-29. The rejections above judged each concept as a retrofit onto current
code. This section asks what each would become if it drove a design change. These are
chunk-scale arcs, not declarations, and B1 is the gateway: B2's static checks and the
plan-approval UX both need its term value.

### B1. Reify the dispatch plan (the free-monad rejection, consumed)

`ToolRunner` already evaluates an implicit term: a turn's tool_uses partition into contiguous
runs, safe runs gather, unsafe singletons are barriers. Written down, that is a
series-parallel term, `seq(par(a, b), c, par(d, e))`, with both operations associative and
`par` commutative. The term exists only as control flow inside one class; nothing else can
see it.

Making it a value (`Dispatch::Plan`, built by a pure planner from the uses and the safety
map, evaluated by what remains of `ToolRunner`) buys 4 things:

- **Simplification of the hardest spec in the tool layer.** The partition logic
  (`safety_by_name`, `contiguous_runs`, `gatherable?`) becomes a pure function into a value,
  spec'd by data assertions. Today `tool_runner_spec.rb` drives entered/release queues and
  ordered logs to observe interleaving; under a plan value only the small evaluator needs
  that machinery.
- **The exchange law gets its natural home.** Idea 1's law restates as: evaluation is
  invariant under permutation within a `par` block. One property over terms replaces a
  scheduling test.
- **The plan is journal-able.** The Journal records calls and results but not the concurrency
  structure that ran them. A recorded plan makes the parallel-tools bench arm replayable and
  diffable, the same way `Provider::ResponseWal` made round trips recoverable.
- **Static interpreters.** Handlers are already 3 interpretations of atomic effects (Live,
  Mock, Recorded). Over terms, an interpreter can answer without running: does the Toolset
  cover this plan (capability check), what does it cost at `PriceBook` rates (a pre-run bound
  in the `Usage` monoid), what would it do (an Explain rendering).

The Explain interpreter is where this compounds into UX: plan-level approval. `Gate` approves
one `ToolCall` at a time; a plan value lets a human approve a term once, with the approval
recorded as data. `Effect::Approval` already reifies per-call gating, so this is the same
move one level up.

Scope honesty: this is the free monad's useful half. The loop itself stays un-reified, since
model responses arrive one turn at a time and there is no multi-turn bind tree to build, so
the object of study stays visible in Ruby.

### B2. Contracts compose sequentially (the Result-monad rejection, redirected)

`Tool::Contract` is already data (`message` + `predicate`). The motivating contract,
"edit_file requires this file was read this session", is a Hoare triple over session state,
and `read_file`'s execution establishes exactly what `edit_file` requires. Sequential
composition of pre/postconditions is the oldest composition rule in the book, and lain has
both halves in adjacent files with no arrow between them.

With B1's plan value the arrow becomes a static check: walk the term, thread the session
facts each step's postcondition establishes, and refuse (or warn on) a plan whose later
precondition nothing earlier establishes. The failure message writes itself: "step 4 edits a
file no step reads". Today that violation surfaces mid-run as a raised `ContractViolation`
after 3 steps already executed.

Cost: contracts today are opaque predicates, so static checking needs them to *name* the
facts they establish and require (a small vocabulary of session facts, `read?(path)` and
kin). That is a redesign of the `Contracts` declaration surface, not a retrofit, and the
vocabulary should stay closed the way `Event::KINDS` is.

### B3. The bench sweeps free algebras (the topology rejection, generalized)

The free-monoid sweep is the bench's one repeated trick: express a strategy space as terms
over a small generator set and the space becomes enumerable instead of hand-listed. It
generalizes to every axis this document touched:

| Axis | Generators | Term shape | Status |
|---|---|---|---|
| Context strategies | 11 combinators | words (free monoid) | shipped |
| Compaction ranges | cut points | interval partitions | shipped; combination designed, not built |
| Dispatch | tool calls | series-parallel terms | B1 |
| Command tools | argv commands | pipe terms (monoid) | idea 6 |
| Orchestration | roles, attenuations, prefix strategies | topology terms | epic-orchestration's open question |

The rows share one requirement: an evaluator that is the only thing touching the world, so
terms stay pure data the bench can enumerate, price, and journal. That is the discipline
`Effect`/`Effect::Handler` already enforces at the atom level, applied at each composite
level. For the epic review, the sharp question is which generator set makes the interesting
topologies expressible and the uninteresting ones unwritable, since `Arm` today is a
hand-written topology per class.

**The grammar, read off the shipped arms (expanded 2026-07-29).** The 4 arms decompose into
5 generators, which is evidence the grammar is real rather than imposed:

| Arm | As a term |
|---|---|
| `SingleThread` | `leaf(role, spawn_policy)` |
| `OrchestratorWorker` | `seq(decompose, par(leaf × N), join(synthesis))` |
| `AdaptiveRouter` | `choice(oracle, leaf-per-model)`, resolved once at spawn |
| `DualLedger` | `loop(step, until: stall policy, bound: max_steps)` |

What resists termification is informative: `decompose`, the router's oracle, and DualLedger's
progress/replanner are injected callables, so they stay leaf parameters and evaluator policy,
never term structure. The term captures topology shape; policies stay where `Arm`'s minimal
seam already keeps them.

**The signature has a name.** Sequence, parallel with an exchange law, choice, and bounded
iteration is concurrent Kleene algebra (Hoare, Möller, Struth, Wehrman 2009). The CKA
exchange inequality, `(a ∥ b);(c ∥ d) ≤ (a;c) ∥ (b;d)`, is the barrier-semantics statement
`ToolRunner` already implements one level down, which is why B1's dispatch plans and topology
terms are the same term library at 2 leaf types, with pipe terms (idea 6) as the seq-only
fragment.

**Reused machinery, the actual case for building it:**

- **One generic term value, 3 instantiations.** Series-parallel(+choice, +loop) terms
  parameterized by leaf type: argv commands (pipe), `ToolCall`s (dispatch), role+`SpawnPolicy`
  (topology). Laws run as shared groups parameterized by generator, exactly how `monoid.rb`
  already serves `Middleware`, `Context`, and `Usage`.
- **The topology leaf already exists.** `Tool::SpawnPolicy` is `(prefix, posture, only)` and
  `Role::Catalog` names the prompt half. No new leaf design.
- **The evaluator is just another Arm.** `Arm::FromTerm` answering the same
  `#run(task, spawn_seam:, isolation:, grader:) -> Run` seam means `Driver`, `Compare`,
  `Ledger`, and every grader reuse unchanged, and hand-written arms coexist with terms
  indefinitely.
- **The Run reachability contract, implemented once.** `Arm::Run`'s pricing rule (render
  reachability or labeled re-attribution) is a documented obligation on each arm today. A
  term evaluator discharges it structurally: every `par` block's join re-attributes, every
  `seq` threads one head. The trickiest accounting contract in the arm layer moves from N
  class comments into 1 evaluator.
- **Canonical addressing for free.** Terms are frozen Data, so they digest, so a bench run
  keys on (term digest, task, model): dedupe, replay, and normal forms (flatten by
  associativity, sort `par` children by digest since it is commutative) all transfer from the
  free-monoid description/strategy distinction.
- **The conditional-law pattern recurs.** `par` commutativity at topology level holds only
  given isolated workers; shared mutable state breaks it. That is an `elementwise given:`
  shaped claim, and it recasts `Isolation` as the mechanism that makes the exchange law true
  rather than an unrelated subsystem.
- **Audit by re-derivation.** A term predicts the causal DAG a run should record (`:spawn`
  fan-outs, the synthesis event's multi-parent fiber). Checking the recorded DAG against the
  term is `Compaction::DerivationAudit`'s pattern applied to orchestration.

Cross-analysis folded into `planning/epic-orchestration.md` §3.10 (2026-07-29): the exchange
law's third altitude (independent issue landings commute, given per-issue isolation; `ready`
monotone under landings, not under graph edits), the `blocks`/`discovered_from` edge split
mirroring `render_parent`/`causal_parents`, split/merge fibers enabling audit and the
decomposition-fidelity cover check, the PR-granularity convexity condition (a DAG quotient is
a DAG only over blocking-convex groupings), and the altitude arms as prefixes of one ladder
term with gate policy as a parameter. `/implement-epic` is this section's evaluator in
dynamic form: the term recomputes from the graph as `discovered_from` events land.

### B4. One partition value, two consumers

`Compaction::Strategy::Base` holds a private `Partition` value enforcing well-formedness;
`ToolRunner#contiguous_runs` builds the same structure through `chunk_while`. Compaction's
designed-but-unbuilt feature (combining 2 strategies over one span) is the refinement meet of
2 partitions, and B1's plan is a partition of the wire order. Extracting the value gives the
designed feature its mechanism, lets both sites share one set of well-formedness guarantees,
and removes a private class rather than adding a public one.

### B5. A least-privilege recommender (the ledger completed by the lattice)

Idea 5's used-capability sets and idea 3's attenuation order compose into a Galois
connection: observed use maps to the smallest Toolset covering it, and a Toolset maps to the
calls it permits. A recommender reads sessions from the Journal and suggests `only(...)`
lines per role, with the one law that matters proved rather than promised: a suggestion never
drops a capability the observed sessions used. `Role::Catalog` is the consumer surface, since
a suggested attenuation is a diff against a catalog entry.

### B6. Typed content blocks, and the laws that make the migration safe

Joel's observation, 2026-07-29: the raw-hash `result`/`response` shapes read as primitive
obsession, and moving toward values (the Result-monad direction) is also a move away from
primitives that are harder to reason about over time.

**The measurement.** `Tool::Result`, `Effect::ToolCall`, `Request`, `Response`, and
`Middleware::Env` are already values. The pervasive primitive is one level down: the
**content block**. 97 raw string-key access sites (`block["type"]`, `fetch("id")`,
`fetch("tool_use_id")`, `fetch("input")`) across 20+ files in `lib/`, including at least 8
outside the provider layer (context combinators, compaction strategies, `Event::Projection`,
`Grader::ToolCallIndex`, `StatusFeed`), where "stay close to the wire" is no justification.
`Tool#dig` and `SchemaValidator`'s dual-spelling lookups exist only because hashes carry 2
key spellings. `Tool::Result` is a value island: hashes flow in (`tool_use.fetch("id")`) and
hashes flow out (`ToolRunner#result_block` rebuilds a wire hash around it).

**Why blocks stayed hashes, and the constraint any migration inherits.** Two reasons, both
good: `Canonical` computes digests over plain data, and every stored `Event` payload is
addressed by those bytes; and the anti-corruption bar is losslessness (the `ruby_llm`
`Message` rejection: a typed layer that loses content is worse than hashes). So a typed block
layer must be a *view*, with the hash form staying the identity-bearing normal form.

**The algebra this pulls in.** This is where the migration influences the vocabulary, and
each law has the digest as its oracle:

- **Round-trip isomorphism laws.** `Block.from_h(block.to_h) == block`,
  `Block.from_h(h).to_h == h` on valid hashes, and above all
  `Canonical.digest(block.to_h)` unchanged for every block in every recorded session. The
  law suite is the acceptance test for de-primitivizing any wire shape, the same
  differential-oracle pattern the Rust port uses. A `:canonically_isomorphic` law group is
  the registry-shaped version.
- **An open coproduct with a lossless Unknown.** Block kinds are a sum type, but the wire
  enum is non-exhaustive (the known trap: always have an `else`). The sum therefore needs an
  `Unknown` variant that preserves bytes exactly, so typing never re-introduces the loss the
  anti-corruption layer exists to prevent.
- **Prism laws, revising the optics rejection.** The rejection said there was no second
  representation to keep in sync. After this migration there is: hash form and typed form.
  Match/build round trips per block kind are the lawful-prism residue, needed as laws, not
  as a library.
- **A wire-projection homomorphism for errors.** `is_error` is a Boolean; the *kinds*
  (invalid input, contract violation, gate refusal, timeout, tool bug) are collapsed into
  content strings. Refining the Boolean into a small closed error sum is the honest
  Result-monad payoff (the typed error coproduct, with no bind needed), under one law: the
  wire projection is unchanged, `kind.error?` equals today's Boolean, so providers see the
  same bytes. Consumers exist now: `Grader::ToolSteering`'s failure taxonomy, and any retry
  policy, since retryable-ness is a property of the kind.
- **A pairing value for gates 2, 3, and 4.** A turn's tool_uses and their answers are a
  bijection by id; `DuplicateToolUse` guards half of it, and `ToolRunner#observe_all`
  re-derives the pairing after the fact through `names_by_id`. A constructed pairing value
  makes gate 4 a constructor invariant and deletes the re-derivation.

**Precedent.** `Middleware::Env` replaced a raw Hash and "quacks like the Hash it replaced";
`Request`/`Response` wrapped the wire once already. The pattern is established; the laws are
what make it safe at the digest layer, and the simplification is concrete: the dual-spelling
tolerance code and the 97-site string-key discipline retire as the view spreads.

### B7. Routing-table handlers, when the vocabulary grows

The handler chain's left-biased delegation is fine at 3 effect kinds. If the vocabulary grows
(B1 adds a plan effect; spawn and memory effects are plausible), a routing table keyed by
kind makes shadowing structurally impossible, the same `Occupied` posture the Algebra
registry takes toward clobbering a method. Not worth doing before the vocabulary grows;
worth remembering when it does.

## Suggested order

1. Idea 1 (exchange law): guards a live concurrency decision; highest defect-catching value.
2. Idea 2 (posture equivalence): cheap, and CE-4's comparisons are only honest with it.
3. Idea 7 (glossary): near-free.
4. Idea 3 (+4) (attenuation laws): the biggest retrofit, gated on deciding `Toolset#==`.
5. Idea 6 (pipeline algebra): the only simplifier, and the only feature chunk; schedule it on
   appetite for the approval-surface win rather than for the algebra.
6. Idea 5 (capability ledger): schedule as a bench chunk, not an algebra chunk.

## References

- Power, Robinson. *Premonoidal categories and notions of computation* (1997). Centrality is
  the formal shape of `parallel_safe?`; only the exchange law is imported.
- Moggi. *Notions of computation and monads* (1991). Ancestry of the effect/interpreter split
  `Effect`/`Effect::Handler` already implements.
- Kiselyov, Ishii. *Freer monads, more extensible effects* (2015). What full effect
  reification looks like, and by contrast why lain does not need it.
- Katsumata. *Parametric effect monads and semantics of effect systems* (2014). The grading
  idea behind the used-capability ledger.
- Miller. *Robust Composition: Towards a Unified Approach to Access Control and Concurrency
  Control* (2006). The object-capability model; attenuation-only algebra for holders is its
  central discipline.
- Hoare, Möller, Struth, Wehrman. *Concurrent Kleene Algebra* (CONCUR 2009). The signature
  shared by dispatch plans and topology terms; its exchange inequality is `ToolRunner`'s
  barrier semantics stated as a law.
- Stepanov, McJones. *Elements of Programming*. Why idea 3 starts at equality, and why full
  `Regular` is out of reach for behavior-bearing tools.
- In-repo: `ARCHITECTURE.md` ("The algebra: laws as architecture"), `docs/GLOSSARY.md`,
  `planning/specs/chunk-algebra-vocabulary.md` (the rulings), `lib/lain/algebra.rb`.
