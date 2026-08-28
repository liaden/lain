# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # Records a spawn's causal lineage as events in the shared Store:
      # {Subagent} runs the child, this writes the record. Both events are
      # causal-only, so neither enters any render chain -- `meet`, the
      # first-parent walk and gate 2 are untouched.
      class Lineage
        # Every event this writer puts into the shared Store is also appended
        # to `log` in EMISSION ORDER, so a mailbox {Event::Projection} can fold
        # it. The one-shot path injects {Log::Null}, whose appends vanish.
        #
        # `observer` is the outward slot on the same funnel. A further observer
        # must COMPOSE with the @log append, as this constructor does, never
        # SUBSTITUTE for it -- or @log's mailbox fold silently stops.
        def initialize(policy:, log: Log::Null, observer: Event::ChainWriter::Null.new)
          @policy = policy
          @log = log
          @adoptions = Hash.new(0)
          @chain_writer = Event::ChainWriter.new(observer: lambda { |event|
            @log << event
            observer.call(event)
          })
        end

        # The causal record the fresh root omits: its edge to H is what keeps
        # lineage reconstructable when the child's render chain shares nothing
        # with the parent's. Put into the SHARED Store, where H already lives,
        # so referential integrity holds.
        #
        # `lifecycle`, `adoption` and `unattended` are written CONDITIONALLY, so
        # only the actor path pays a byte change and every one-shot digest on
        # disk stays as it was. `unattended` is in the record because without it
        # a recorded spawn no longer determines the child's toolset, the one
        # property a bench reader replays a spawn to check.
        #
        # `adoption` is the identity two live children cannot share: an adopted
        # actor's ADDRESS is this event's digest, and two launches of one arm
        # from one head are otherwise byte-identical, so the fleet, the journal
        # and a `tell` would read the twins as one. A one-shot is adopted by
        # nobody and addressed by nobody, hence the condition above.
        #
        # A COUNTER, not a nonce, and that is the binding constraint: a nonce
        # would not break replay (a record rebuilds from its own recorded body)
        # but would break CROSS-RUN reproducibility, and two runs of one bench
        # arm could then not be joined on a spawn digest.
        #
        # Its scope is this WRITER; {#next_adoption} says what that leaves open.
        def spawn(parent, lifecycle: nil)
          head = parent.head_digest
          body = { "prefix" => @policy.prefix.label, "posture" => @policy.posture.label,
                   "only" => @policy.only, "spawned_from" => head }
          unless lifecycle.nil?
            body["adoption"] = next_adoption(head)
            body["lifecycle"] = lifecycle
          end
          body["unattended"] = true if @policy.unattended
          put(parent, kind: :spawn, from: correlation_of(parent), to: nil,
                      causal_parents: [head].compact, body:)
        end

        # The return as a first-class event -- the schema has no `:result`
        # kind, and a result IS a message. It names the :spawn and the child's
        # final turn F, so a provenance walk reaches both intent and answer.
        #
        # The JOIN to the parent is at CORRELATION grain -- the parent chain's
        # root digest, NOT the parent's rendered tool_result turn, which keeps
        # `causal_parents` empty so ToolRunner and Timeline#commit stay out of
        # this seam. A walk therefore enters at the correlation, finds this
        # :message, and descends to the :spawn and F. Edge-grain linkage is
        # deliberately not built here.
        #
        # The completion is a TRANSITION, so it carries the same discriminator
        # every other transition does -- STOPPED, because a one-shot child is
        # done for good, exactly as an actor's farewell is. Written
        # UNCONDITIONALLY: future completions hash differently from the ones
        # on disk, which is safe because a recorded journal re-derives its
        # digest from its own recorded body. This closes the vocabulary's
        # TERMINAL end only -- a one-shot's :spawn still writes no "launched"
        # (see {#spawn}), so "did this spawn start" is still `kind == :spawn`.
        def message(parent, spawn, child, response)
          final = child.head_digest
          body = { "result" => response.text, "final" => final,
                   "lifecycle" => Telemetry::SpawnLifecycle::STOPPED }
          put(parent, kind: :message, from: correlation_of(child), to: correlation_of(parent),
                      causal_parents: [spawn.digest, final].compact, body:)
        end

        # A plain message between two chain identities, carrying the renderable
        # `text` {Context::Mailbox} folds. The actor's inbound and outbound both
        # go through here.
        #
        # `lifecycle` is the body-level discriminator a reader keys on WITHOUT
        # parsing prose. Its ABSENCE is meaningful: a tell is conversation, not
        # a transition.
        def note(parent, from:, to:, text:, causal_parents:, lifecycle: nil)
          body = { "text" => text }
          body["lifecycle"] = lifecycle unless lifecycle.nil?
          put(parent, kind: :message, from:, to:, causal_parents:, body:)
        end

        # The parent chain's root digest, the same identity {#put} stamps on
        # every event. Public so an {Actor} can address the parent without
        # reaching into `identity`.
        def correlation_of(timeline) = Event::ChainWriter.correlation_of(timeline)

        private

        # Keyed by the head, the scope a collision lives in: two adoptions from
        # ONE head. Different heads already differ in `spawned_from`, and a
        # per-head sequence is what makes an identical second run replay the
        # same numbers in the same order.
        #
        # Scoped to THIS writer, which is what it leaves open. A cockpit builds
        # one {Tools::Subagent} and memoizes its Lineage, so every actor it
        # launches counts off this one sequence -- but a SECOND writer over the
        # same head starts again and re-collides, as a resumed run does. Both
        # want an identity minted outside this object.
        #
        # Unsynchronized, and safe only because nothing between the read and the
        # write suspends the fiber; behind an await it would issue duplicates
        # with nothing raised.
        #
        # One entry per head ever actor-spawned from, never evicted: O(actor
        # launches), a session-sized Hash rather than a leak.
        def next_adoption(head)
          @adoptions[head] += 1
        end

        # The payload-then-envelope write, delegated so @chain_writer is its
        # one home.
        def put(parent, kind:, from:, to:, causal_parents:, body:)
          @chain_writer.put(parent, kind:, from:, to:, causal_parents:, body:)
        end
      end
    end
  end
end
