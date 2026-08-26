# frozen_string_literal: true

module Lain
  module Oracle
    # The first oracle arm: "which spans are stale?" -- the judgment
    # `cache-aware-compaction.md`'s cold-window work will eventually gate a real
    # prune on. This module answers the question only; it touches neither
    # {Context::Prune} nor a Timeline.
    #
    # Deliberately OFF the render hot path: {Context#render} is a PURE, per-turn
    # function, and scoring staleness -- however cheap the heuristic tier is -- is
    # post-turn/idle work that must never be called from inside it. A caller
    # invokes {.heuristic} from outside the render path, the way
    # {Compaction::Need} is checked between turns.
    module PruneScoring
      # `stale` is the one bit a prune decision needs; `reason` rides along
      # for the journal ({Oracle::Recorded::Journaling} records the whole
      # answer), not for control flow.
      SCHEMA = Class.new(Tool::Input) do
        field :stale, :boolean, required: true,
                                description: "whether this span is safe to prune as stale"
        field :reason, :string, description: "one-line justification, for the journal"
      end

      # `age_turns` and `content` are the only slots either tier needs. Kept
      # independent of any real Span/Timeline projection type -- the cold-window
      # work is not built, so this must not couple to a shape that does not
      # exist.
      TEMPLATE = <<~ERB
        A span from the conversation, last referenced <%= render("age_turns") %> turns ago:

        <%= render("content") %>

        Is it stale -- safe to prune because nothing later in the conversation depends on it?
      ERB

      # @param tier [Symbol] folded into the Definition's digest, so a
      #   heuristic answer and a model answer to the identical question are
      #   two different oracles at two different addresses.
      # @return [Oracle::Definition]
      def self.definition(tier: :heuristic)
        Definition.new(template: TEMPLATE, schema: SCHEMA, tier:)
      end

      # The heuristic baseline every richer arm must beat: a span is stale once it
      # has gone unreferenced for `stale_after_turns` -- the "age crosses a
      # threshold" shape {Context::PurgeFailedInputs} uses for a different
      # signal.
      #
      # @param stale_after_turns [Integer]
      # @return [Oracle::Heuristic]
      def self.heuristic(stale_after_turns:)
        threshold = Integer(stale_after_turns)
        Heuristic.new(definition: definition(tier: :heuristic), predicate: lambda do |inputs|
          stale = Integer(inputs.fetch(:age_turns)) >= threshold
          { "stale" => stale, "reason" => stale ? "unreferenced for >= #{threshold} turns" : "recent" }
        end)
      end
    end
  end
end
