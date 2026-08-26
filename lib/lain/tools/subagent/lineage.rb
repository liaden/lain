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
        # `lifecycle` and `unattended` are both written CONDITIONALLY, so a
        # one-shot spawn's bytes -- and every digest derived from them -- are
        # unchanged. `unattended` belongs in the record because without it the
        # recorded spawn no longer determines the child's toolset, which is the
        # one property a bench reader replays a spawn to check.
        def spawn(parent, lifecycle: nil)
          head = parent.head_digest
          body = { "prefix" => @policy.prefix.label, "posture" => @policy.posture.label,
                   "only" => @policy.only, "spawned_from" => head }
          body["lifecycle"] = lifecycle unless lifecycle.nil?
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
        def message(parent, spawn, child, response)
          final = child.head_digest
          body = { "result" => response.text, "final" => final }
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

        # The payload-then-envelope write, delegated so @chain_writer is its
        # one home.
        def put(parent, kind:, from:, to:, causal_parents:, body:)
          @chain_writer.put(parent, kind:, from:, to:, causal_parents:, body:)
        end
      end
    end
  end
end
