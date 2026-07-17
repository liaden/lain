# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # Records a spawn's causal lineage as events in the shared Store -- the
      # separate responsibility the Metrics cop was pointing at: {Subagent}
      # runs the child; this writes the record. Both events are causal-only
      # (`render_parent` nil), so neither enters any render chain: `meet`, the
      # first-parent walk, and gate 2 are untouched.
      class Lineage
        # `log` is the append-only read-side (see {Log}): every event this
        # writer puts into the shared Store is also appended there in emission
        # order, so a mailbox {Event::Projection} can fold it. The one-shot path
        # injects {Log::Null}, whose appends vanish -- its stream is consumed
        # within a dispatch and nobody folds it.
        #
        # `observer` is the outward slot on the same funnel -- how a session
        # scribe (T13) sees every event this writer puts, attached as one line
        # at the call site. A further observer must COMPOSE with the @log
        # append (as this constructor composes `observer`), never substitute
        # for it, or @log's mailbox fold silently stops.
        def initialize(policy:, log: Log::Null, observer: Event::ChainWriter::Null.new)
          @policy = policy
          @log = log
          @chain_writer = Event::ChainWriter.new(observer: lambda { |event|
            @log << event
            observer.call(event)
          })
        end

        # The :spawn event -- the causal record the fresh root omits. Its
        # causal edge to H is what keeps lineage reconstructable when the
        # child's render chain shares nothing with the parent's; put into the
        # SHARED Store, where H already lives, so referential integrity holds.
        #
        # `lifecycle` is the actor path's machine-readable transition marker
        # (see {#note}); a one-shot spawn passes none, so its bytes -- and
        # every digest already derived from them -- are unchanged.
        def spawn(parent, lifecycle: nil)
          head = parent.head_digest
          body = { "prefix" => @policy.prefix.label, "posture" => @policy.posture.label,
                   "only" => @policy.only, "spawned_from" => head }
          body["lifecycle"] = lifecycle unless lifecycle.nil?
          put(parent, kind: :spawn, from: correlation_of(parent), to: nil,
                      causal_parents: [head].compact, body:)
        end

        # The :message event carrying the child's result back to the parent --
        # the return as a first-class event (event-schema has no `:result`
        # kind; a result IS a message). It names the :spawn and the child's
        # final turn F, so the provenance walk reaches both the intent and the
        # answer.
        #
        # The JOIN to the parent is at CORRELATION grain (T19 panel ruling):
        # `message.to == parent.correlation` -- the parent chain's root digest
        # -- NOT the parent's rendered tool_result turn, which keeps
        # causal_parents [] because ToolRunner and Timeline#commit (gate 2's
        # guts) stay out of this seam. A provenance walk therefore enters at
        # the correlation, finds this :message, and descends `causal_parents`
        # to the :spawn and F. Edge-grain linkage (the rendered turn naming F
        # directly) is recorded in the plan for the M5 tail, deliberately not
        # built here.
        def message(parent, spawn, child, response)
          final = child.head_digest
          body = { "result" => response.text, "final" => final }
          put(parent, kind: :message, from: correlation_of(child), to: correlation_of(parent),
                      causal_parents: [spawn.digest, final].compact, body:)
        end

        # A plain message between two chain identities, carrying renderable
        # `text` (what {Context::Mailbox} folds). The actor's inbound (parent ->
        # actor, addressed to the actor's spawn digest) and outbound (actor ->
        # parent, addressed to the parent's correlation) both go through here --
        # a result IS a message, the same reasoning as {#message}, but the actor
        # exchanges continuously rather than returning once.
        #
        # `lifecycle` ("settled"/"stopped", or "launched" on a :spawn) is the
        # body-level discriminator a reader keys on WITHOUT parsing prose --
        # events are content-addressed, so this marker had to land before
        # recorded journals existed, not after (W3 review fix 4). Its absence
        # is meaningful: a tell is conversation, not a transition.
        def note(parent, from:, to:, text:, causal_parents:, lifecycle: nil)
          body = { "text" => text }
          body["lifecycle"] = lifecycle unless lifecycle.nil?
          put(parent, kind: :message, from:, to:, causal_parents:, body:)
        end

        # The correlation an actor addresses its parent by -- the parent chain's
        # root digest, the same identity {#put} stamps on every event. Public so
        # an {Actor} can address the parent without reaching into `identity`.
        def correlation_of(timeline) = Event::ChainWriter.correlation_of(timeline)

        private

        # Delegates the payload-then-envelope write to the shared
        # {Event::ChainWriter} -- this method's own body used to build the
        # Payload and envelope by hand; @chain_writer is the one home now.
        def put(parent, kind:, from:, to:, causal_parents:, body:)
          @chain_writer.put(parent, kind:, from:, to:, causal_parents:, body:)
        end
      end
    end
  end
end
