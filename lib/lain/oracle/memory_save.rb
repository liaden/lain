# frozen_string_literal: true

module Lain
  module Oracle
    # T4 (OR-3), second oracle arm: "worth remembering?" -- plugs into
    # {Middleware::RefuseSecretWrites}'s existing `oracle:` seam via {Gate}.
    #
    # UNLIKE {PruneScoring}, this arm sits ON the live tool-dispatch path:
    # `RefuseSecretWrites#call` is a SYNCHRONOUS gate that must decide BEFORE
    # a `memory_write` proceeds -- once a credential (or anything else) is
    # inside the Memory::Index it is readable by every future `memory_read`,
    # so there is no un-writing it after the fact. That constraint means the
    # live gate may only ever be backed by {.heuristic} (or a {Recorded}
    # replay of one): no model round trip may sit on this hot path. A
    # model-tier arm answering this SAME {.definition} is real and useful,
    # but confined to bench/replay comparison (OR-4) -- never constructed as
    # the live gate.
    module MemorySave
      SCHEMA = Class.new(Tool::Input) do
        field :worth_saving, :boolean, required: true,
                                       description: "whether persisting this memory_write is worth doing"
        field :reason, :string, description: "one-line justification, for the journal"
      end

      # The three fields {Tools::MemoryWrite::Input} declares -- id,
      # description, body -- are exactly the slots this question needs.
      TEMPLATE = <<~ERB
        A tool wants to write this item to durable memory:

        id: <%= render("id") %>
        description: <%= render("description") %>
        body: <%= render("body") %>

        Is this worth remembering -- real content, not a secret, not noise?
      ERB

      # @param tier [Symbol] see {PruneScoring.definition} -- same reasoning.
      # @return [Oracle::Definition]
      def self.definition(tier: :heuristic)
        Definition.new(template: TEMPLATE, schema: SCHEMA, tier:)
      end

      # A body that is one unbroken run of token-shaped characters, 24+ long:
      # the heuristic's complement to {Middleware::RefuseSecretWrites::PATTERNS},
      # which only fires on a NAMED credential shape (`sk-`, `AKIA`, a
      # `key: value` assignment). An opaque blob with no such cue -- no
      # keyword, no prefix, just entropy -- reads as not worth saving on its
      # own terms: whatever it is, it is not prose a memory_read is meant to
      # surface later.
      OPAQUE_TOKEN = %r{\A[A-Za-z0-9+/=_.-]{24,}\z}

      # The heuristic baseline every richer arm (OR-4) must beat: blank
      # bodies and opaque tokens are not worth saving; everything else is.
      #
      # @return [Oracle::Heuristic]
      def self.heuristic
        Heuristic.new(definition: definition(tier: :heuristic), predicate: lambda do |inputs|
          body = inputs.fetch(:body).to_s.strip
          worth = !body.empty? && !OPAQUE_TOKEN.match?(body)
          { "worth_saving" => worth, "reason" => worth ? "readable content" : "blank or opaque-token body" }
        end)
      end

      # Adapts a memory-save oracle tier to {Middleware::RefuseSecretWrites}'s
      # existing binary `#secret?(input)` seam: the richer `worth_saving` +
      # `reason` answer collapses to the one bit that seam asks for.
      class Gate
        # @param tier [#ask] a live tier answering this module's {.definition}.
        #   Defaults to {.heuristic} -- the only tier safe to construct here,
        #   since {#secret?} runs synchronously on the live write path (see
        #   the module comment). Pass a {Recorded} replay for deterministic
        #   replay of a journaled run; never a {Model} tier here.
        def initialize(tier: MemorySave.heuristic)
          @tier = tier
        end

        # @param input [Hash] the memory_write effect's raw input
        #   (String-keyed id/description/body)
        # @return [Boolean] true refuses the write -- the oracle judged it
        #   not worth saving
        def secret?(input)
          answer = @tier.ask(id: input["id"], description: input["description"], body: input["body"]).await
          !answer.worth_saving
        end
      end
    end
  end
end
