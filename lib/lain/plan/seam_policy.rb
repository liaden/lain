# frozen_string_literal: true

module Lain
  module Plan
    # What the mainline continues AS once a chunk closes. The two execution
    # shapes have DIFFERENT state effects, and this value says so out loud
    # instead of hiding it -- one half per effect a shape is allowed to have.
    #
    # +head_digest+ is the mainline to continue on. A Timeline IS a (head
    # digest, Store) pair over a SHARED Store, so the head digest is its whole
    # identity and the Store is ambient. That is ALSO what lets a Continuation be
    # +Ractor.shareable?+ (pinned by spec): a Store-bearing Timeline never is (it
    # holds a Monitor and a mutable Hash). +nil+ is the empty timeline.
    #
    # +pipeline+ is the render strategy every SUBSEQUENT turn builds its
    # {Context} around -- a shareable {Context::Combinator} or a
    # +->(workspace)+ provider.
    #
    # {ForkPerStep} acts on the timeline half, {LinearRewrite} on the pipeline
    # half. Neither ever touches both -- if a future hybrid shape needs a third
    # effect, this value WIDENS deliberately (a named member), never grows an
    # options Hash (an escalation trigger).
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
    # where +state+ is the CURRENT {Continuation} -- its +head_digest+ names the
    # just-closed chunk's tail, its +pipeline+ is the strategy that rendered it
    # -- and +closure+ is that chunk's deterministic {Closure}.
    #
    # A documented duck, not a base class: {ForkPerStep} and {LinearRewrite}
    # share only the message. There is deliberately no default +at_seam+ to
    # inherit -- a policy that did nothing would be a silent third shape, and
    # this contract exists to make the shapes explicit.
    module SeamPolicy
    end

    # The reopen reference, defined at THIS layer on purpose: the {Closure}
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
