# Dominator-tree meets over the union DAG — research pass (2026-07-17)

> ⚠️ **LLM-generated synthesis** (deep-research harness: 103 agents, 5 search angles,
> 3-vote adversarial verification per claim; quotes verified against primary PDFs via
> pdftotext). Compiled to inform the TL-3 ruling. Claims below carry their vote and
> sources; read the sources before building on a claim this doc alone.

**Question.** Is a dominator-tree meet over lain's union graph (render ∪ causal edges) a
principled generalization of the render-chain meet-semilattice — and what does it buy
beyond cache-break localization?

**Ruling it informed (Joel, 2026-07-17): enriched (a), full** — three operators:
`meet`/`diverge_at` unchanged (render edge), `causal_meets` set-valued (maximal lower
bounds), and a NEW `dominator_meet` (union graph, virtual root) as the
checkpoint/safe-compaction primitive. See
`planning/specs/chunk-meet-supervision-fanout-interface.md` (S1/S3).

## Verified findings

1. **The dominator-tree meet is a true meet-semilattice** over any rooted graph (3-0).
   Dominance is a partial order; dominators of a node are totally ordered, so the Hasse
   diagram is a tree; deepest-common-dominator = unique NCA — idempotent, commutative,
   associative, total. Mechanical acceptance test: a tree is THE dominator tree iff it
   has the parent + sibling properties (Georgiadis–Tarjan, SODA 2005).
   Precondition: a single distinguished root reaching all nodes → lain needs a virtual
   root over the subagent forest.
   — Cornell CS4120 lec25; Georgiadis et al. ESA 2019; Kuderski LLVM dev-mtg 2017.
2. **Dominance is lattice-theoretic all the way down** (3-0): dominator sets are the
   maximal fixed point of a distributive dataflow framework whose meet is set
   intersection; MFP = meet-over-all-paths = Dom. Cooper/Harvey/Kennedy's `intersect`
   on the tree is exactly the NCA meet lain would implement.
   — Cornell lec25; Cooper/Harvey/Kennedy "A Simple, Fast Dominance Algorithm".
3. **Literal LCA over a multi-parent DAG is broken, and git is the precedent for living
   with it** (3-0): merge bases are the SET of maximal lower bounds; criss-cross merges
   make it plural; `--all` exposes the set, otherwise the choice is *unspecified*.
   Recursive/ort synthesize a virtual ancestor rather than tolerate ambiguity.
   → the honest shape for `causal_meets` is set-valued. — git-merge-base docs.
4. **Winskel event structures give the exact condition for unique causal meets** (3-0,
   3-0, 2-1): STABLE event structures make any compatible set of configurations closed
   under intersection; stability ("essentially unique minimal enabling") is the
   event-structure analogue of dominance-style uniqueness, and corresponds exactly to
   distributivity (prime algebraic domains / dI-domains). Meets are *bounded* (partial),
   not a full lattice. — Winskel 1987 ch. "Event Structures"; Castellan & Winskel
   (arXiv:2003.06267) on disjunctive causes.
5. **Category-theoretic precedent for the "third shape"** (3-0): Mimram & Di Giusto's
   patch theory defines merge as a pushout; pushouts don't always exist (a conflict IS
   the failure of the universal construction); the fix is enlarging the universe (free
   conservative finite cocompletion), not forcing uniqueness. Strategy transferred to
   lain: totalize by enriching the codomain — a set of meets — rather than redefining
   the operator. (Caveat: pushout is join-side; the strategy, not the construction,
   transfers.) — arXiv:1311.3903; pijul builds on this.
6. **What a dominance cut buys beyond caching** (2-1, 3-0, 3-0): CRDT *causal
   stability* — an op applied by all replicas, no concurrent op can arrive — is the
   causal analogue of "the latest event every future passes through", and it is exactly
   a safe-compaction point: stable prefixes collapse to sequential structure, causal
   metadata stripped. The cost transfers too: **one silent participant stalls
   stability** — an open subagent branch freezes lain's checkpoint frontier at its
   spawn point until the branch speaks or closes. (Conceptual parallel, not formal
   equivalence — coincides on linear histories; a frontier dominator is the compaction
   point.) — Bauwens & González Boix MPLR '20; arXiv:1710.04469.
7. **Costs** (3-0 across; one 2-1 refutation on over-claimed local stability):
   append-only insertion is the tractable regime — O(m·min{n,k} + kn) total for k
   insertions with O(1) dominance queries (Georgiadis/Italiano/Laura/Santaroni,
   arXiv:1604.02711); static recompute is linear per rebuild. BUT the tree is NOT
   locally stable: a single edge insertion can change ⌈n/2⌉ immediate dominators
   (explicit-maintenance lower bounds Ω(n²)/Ω(mn) hold even for DAGs) — which is why
   redefining `meet` as the dominator meet would make `diverge_at` answers drift
   retroactively as causal edges land, and why lain computes it **on demand, memoized
   by head digest** instead of maintaining it. LLVM ships incremental semi-NCA
   maintenance (production precedent) if a bench ever shows the recompute hot.

## Why not option (b)

The union-graph dominator meet answers a *different question* than the render meet.
Cache-break localization needs answers that are stable under append (the render chain
only grows at the head); the dominator meet's answers legitimately move as causal edges
land. Same laws, different order — two lawful operators, not one redefined one.
