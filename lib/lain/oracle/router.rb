# frozen_string_literal: true

module Lain
  module Oracle
    # The router arm: "which model (and shared sibling template, if any) should
    # THIS child run under" -- answered from the task's own text, at spawn time,
    # before any child exists. {Arm::AdaptiveRouter} is the one caller: it asks
    # inside `#run`, BEFORE `spawn_seam.call`, and passes the answer through as
    # spawn_opts.
    module Router
      # `model` is the one bit the spawn boundary needs; `template` names a
      # shared sibling-template prefix and is blank when the routed child gets
      # none; `reason` rides along for the journal only.
      SCHEMA = Class.new(Tool::Input) do
        field :model, :string, required: true, description: "the child's model, e.g. claude-haiku-4"
        field :template, :string, description: "shared sibling template prefix; blank for none"
        field :reason, :string, description: "one-line justification, for the journal"
      end

      # `task` is the ONLY feature this question asks about: a richer feature
      # extractor (tool affinity, estimated token count) is a richer arm's job,
      # not this baseline's.
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

      # The LENGTH baseline: a task at least `long_after_chars` long routes to
      # `long_model`, everything shorter to `short_model`. `template` is the
      # SAME string on both branches -- a heuristic that also picked a
      # per-branch template would be a richer arm than this baseline claims to
      # be.
      #
      # THE LIVE ROSTER DELIBERATELY DOES NOT USE IT: `long_after_chars` is a
      # number tuned to a corpus, and `bench arms FIXTURE` takes an arbitrary
      # one. {Bench::LiveArms.default_route} splits on a property of the task
      # instead. This stays as the baseline that split has to beat, which is an
      # experiment somebody has to run rather than one that ships.
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
