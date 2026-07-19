# frozen_string_literal: true

module Lain
  module Oracle
    # OR-5, the router arm: "which model (and shared sibling template, if any)
    # should THIS child run under" -- answered from the task's own text, at
    # spawn time, before any child exists. {Arm::AdaptiveRouter} is the one
    # caller: it asks this oracle inside `#run`, BEFORE `spawn_seam.call`, and
    # passes the answer straight through as spawn_opts (`model:`/`template:`)
    # -- see that class's header for why no other seam reaches this oracle.
    module Router
      # `model` is the one bit the spawn boundary needs; `template` names a
      # shared sibling-template prefix ({Tool::SpawnPolicy::PrefixStrategy::
      # SiblingTemplate}'s territory) and is blank when the routed child gets
      # none; `reason` rides along for the journal only, like
      # {PruneScoring::SCHEMA}'s own `reason` field.
      SCHEMA = Class.new(Tool::Input) do
        field :model, :string, required: true, description: "the child's model, e.g. claude-haiku-4"
        field :template, :string, description: "shared sibling template prefix; blank for none"
        field :reason, :string, description: "one-line justification, for the journal"
      end

      # `task` is the ONLY feature this question asks about -- the same
      # "stay independent of a shape that does not exist yet" discipline
      # {PruneScoring}'s header documents: a richer feature extractor (tool
      # affinity, estimated token count, ...) is a richer arm's job, not this
      # baseline's.
      TEMPLATE = <<~ERB
        A child is about to be spawned for this task:

        <%= render("task") %>

        Which model should run it, and should it share a sibling template
        prefix with other children (blank if not)?
      ERB

      # @param tier [Symbol] folded into the Definition's digest, so a
      #   heuristic route and a model route to the SAME question are two
      #   different oracles at two different addresses (see
      #   {PruneScoring.definition} for the same reasoning).
      # @return [Oracle::Definition]
      def self.definition(tier: :heuristic)
        Definition.new(template: TEMPLATE, schema: SCHEMA, tier:)
      end

      # The heuristic baseline every richer arm (a model tier) must beat: a
      # task whose text is at least `long_after_chars` long routes to
      # `long_model`; everything shorter routes to `short_model`. `template`
      # is the SAME string on both branches -- a heuristic that also picks a
      # per-branch template would be a richer arm than this baseline claims
      # to be.
      #
      # @param short_model [String]
      # @param long_model [String]
      # @param long_after_chars [Integer]
      # @param template [String] the shared sibling template every routed
      #   answer names; blank (the default) means none.
      # @return [Oracle::Heuristic]
      def self.heuristic(short_model:, long_model:, long_after_chars:, template: "")
        threshold = Integer(long_after_chars)
        Heuristic.new(definition: definition(tier: :heuristic), predicate: lambda do |inputs|
          task = inputs.fetch(:task).to_s
          long = task.length >= threshold
          {
            "model" => long ? long_model : short_model,
            "template" => template,
            "reason" => "task length #{task.length} #{long ? ">=" : "<"} #{threshold}"
          }
        end)
      end
    end
  end
end
