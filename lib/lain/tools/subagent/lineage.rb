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
        def initialize(policy:)
          @policy = policy
        end

        # The :spawn event -- the causal record the fresh root omits. Its
        # causal edge to H is what keeps lineage reconstructable when the
        # child's render chain shares nothing with the parent's; put into the
        # SHARED Store, where H already lives, so referential integrity holds.
        def spawn(parent)
          head = parent.head_digest
          body = { "prefix" => @policy.prefix.label, "posture" => @policy.posture.label,
                   "only" => @policy.only, "spawned_from" => head }
          put(parent, kind: :spawn, from: identity(parent), to: nil,
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
          put(parent, kind: :message, from: identity(child), to: identity(parent),
                      causal_parents: [spawn.digest, final].compact, body:)
        end

        private

        def put(parent, kind:, from:, to:, causal_parents:, body:)
          payload = Event::Payload.new(kind:, body:)
          event = Event.new(kind:, from:, to:, causal_parents:,
                            correlation: identity(parent),
                            payload_digest: payload.digest, body: payload.body)
          parent.store.put(event)
          event
        end

        # A chain is named by its root event digest (the pinned `correlation`
        # convention), so parent and child are addressable without new id
        # machinery.
        def identity(timeline)
          head = timeline.head
          head && (head.correlation || timeline.head_digest)
        end
      end
    end
  end
end
