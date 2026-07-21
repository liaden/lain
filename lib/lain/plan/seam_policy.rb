# frozen_string_literal: true

module Lain
  module Plan
    # PC-3: what the mainline continues AS once a chunk closes. The two execution
    # shapes ({ForkPerStep}, {LinearRewrite}) have DIFFERENT state effects, and
    # this value says so out loud instead of hiding it -- a continuation has
    # exactly two halves, one per effect a shape is allowed to have:
    #
    # * +head_digest+ -- the mainline Timeline to continue on. A Timeline IS a
    #   (head digest, Store) pair over a SHARED Store, so the head digest is its
    #   whole identity; the Store is ambient (the {Runner} holds it and every
    #   fork shares it), which is why the timeline half rides as a digest, not a
    #   Timeline object. That is ALSO what lets a Continuation be
    #   +Ractor.shareable?+ (pinned by spec): a Store-bearing Timeline never is
    #   (it holds a Monitor and a mutable Hash), so encoding the timeline half as
    #   its digest is the only representation that keeps the whole value
    #   shareable -- the stronger sibling of {Bench}'s "non-Timeline members are
    #   shareable" convention. +nil+ is the empty timeline.
    # * +pipeline+ -- the render strategy every SUBSEQUENT turn builds its
    #   {Context} around ({Context.new}(pipeline:)); a shareable {Context::Combinator}
    #   or a +->(workspace)+ provider (the T21 injected-pipeline shape).
    #
    # {ForkPerStep} acts on the timeline half (advances +head_digest+, leaves
    # +pipeline+); {LinearRewrite} acts on the pipeline half (swaps +pipeline+,
    # leaves +head_digest+). Neither ever touches both -- if a future hybrid
    # shape needs a third effect, this value WIDENS deliberately (a named member),
    # never grows an options Hash (PC-3 escalation trigger).
    Continuation = Data.define(:head_digest, :pipeline) do
      def initialize(head_digest:, pipeline:)
        # The digest is frozen so the whole value is deeply immutable; the
        # pipeline is expected already-shareable (a Combinator is frozen, a
        # provider arrives via Ractor.make_shareable) -- we do not re-freeze it,
        # only carry it, so a non-shareable pipeline surfaces at the caller that
        # built it, not here.
        super(head_digest: head_digest&.dup&.freeze, pipeline:)
      end

      # The mainline Timeline this names, over the shared +store+. Reconstitution
      # is pointer movement -- O(1), no copy -- exactly because a Timeline owns
      # nothing but its head digest. +nil+ yields the empty Timeline.
      def timeline(store)
        Timeline.new(head_digest:, store:)
      end
    end

    # The seam-policy contract (the design precedent is {Compaction::Scheduler}'s
    # policy-object posture: a pure decision extracted from the loop). A seam
    # policy answers ONE message:
    #
    #   at_seam(state:, closure:) -> Continuation
    #
    # where +state+ is the CURRENT {Continuation} (its +head_digest+ names where
    # the just-closed chunk's turns landed -- the fork's tail -- and its
    # +pipeline+ is the strategy that rendered them) and +closure+ is that
    # chunk's deterministic {Closure}. The policy returns the NEXT continuation.
    #
    # This module is the documented duck, not a base class: {ForkPerStep} and
    # {LinearRewrite} share only the message, not implementation, so depending on
    # the message (Sandi Metz) rather than a type is the honest coupling. There
    # is no default +at_seam+ to inherit -- a policy that did nothing would be a
    # silent third shape, and this contract exists precisely to make the shapes
    # explicit.
    module SeamPolicy
    end

    # PC-3's reopen reference, defined at THIS layer on purpose: P2's {Closure}
    # deliberately carries no +supersedes:+ member (a closed record is content-
    # addressed and immutable; superseding it must never rewrite it). When a step
    # REOPENS -- a fresh fork closing a step that already closed -- the new
    # closure supersedes the old BY REFERENCE, and this is that reference: a
    # content-addressed sibling naming both digests, so the Store keeps the old
    # record untouched and the pointer records the succession beside it.
    Supersession = Data.define(:step_id, :superseded, :superseding) do
      include ContentAddressed

      def initialize(step_id:, superseded:, superseding:)
        super(step_id: -step_id.to_s, superseded: -superseded.to_s, superseding: -superseding.to_s)
        freeze
      end

      def digest
        Canonical.digest(canonical)
      end

      # Plain-hash wire form for {Canonical}; String keys, sorted downstream. The
      # +kind+ tag keeps a Supersession's digest from ever colliding with a bare
      # {step_id, ...} Hash that happened to share fields.
      def canonical
        { "kind" => "plan.supersession", "step_id" => step_id,
          "superseded" => superseded, "superseding" => superseding }
      end
    end
  end
end
