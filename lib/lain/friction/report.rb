# frozen_string_literal: true

module Lain
  module Friction
    # Folds the existing offline analysis graders -- {Grader::FrustrationRepair}
    # (rephrase loops), {Grader::ToolSteering} (over-selected tools), and
    # {Bench::Rewrites} (prompt-cache churn) -- over one session Journal and
    # renders each detected signal beside the KNOB that addresses it. A pure
    # function of the Journal: no provider is touched, so two renders of the
    # same entries are byte-identical (the class's own spec pins this).
    #
    # The fuzzy tier behind {Grader::FrustrationRepair}'s injected `oracle:`
    # stays Null here on purpose (interview decision, 2026-07-21 -- plan
    # chunk-gherkin-meta-agents-plan-compaction.md, M1's escalation trigger):
    # this report is the MECHANICAL floor only, never a model call.
    #
    #   Friction::Report.new(Journal.records(File.foreach(path))).render
    #   #=> "1 friction signal(s):\n..."
    class Report
      # Tools whose command string the MODEL controls -- {Tool#requires_approval?}
      # is true today for exactly {Tools::Bash} and {Tools::CoreExec}. The
      # Journal carries no tier metadata of its own (a session header's
      # `"tools"` entries are name/description/input_schema/strict only), so
      # this is a NAME heuristic over the two shipped tier-3 tools, not a live
      # lookup against the toolset that actually ran. A richer signal (the
      # header recording tier) is a follow-up, not this card's problem.
      TIER_3_TOOL_NAMES = %w[bash core_exec].freeze

      # More than this many prefix rewrites in one session is "high" -- a
      # stated, arbitrary threshold, the same shape {Grader::ToolSteering::DEFAULT_THRESHOLD}
      # documents.
      CACHE_REWRITE_THRESHOLD = 3

      # Declarative signal-kind => knob-guidance mapping. This table is the
      # whole point of the class: adding a new knob is an edit here, never a
      # new conditional buried in a render method.
      KNOBS = {
        rephrase_loop_tier3: "consider the approval queue timeout, or a structured tool with its own " \
                             "precondition (Tool.requires) instead of this tier-3 one",
        rephrase_loop: "consider tightening this tool's error messages or description so a retry " \
                       "does not repeat the same failing call",
        tool_steering: "rewrite this tool's description so it does not over-claim -- see the disclosure sweep",
        cache_rewrites: "high cache-rewrite count -- look at compaction scheduling knobs " \
                        "(Compaction::Scheduler, Context::Compact's byte threshold)"
      }.freeze

      # The analyzers this report folds, named for the "clean session" state --
      # kept as data (not re-derived from KNOBS' keys) so the two can evolve
      # independently: one knob can cover several analyzers' findings and vice
      # versa.
      ANALYZERS = ["Grader::FrustrationRepair", "Grader::ToolSteering", "Bench::Rewrites"].freeze

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
      # @param oracle [#frustrated?] forwarded to {Grader::FrustrationRepair};
      #   Null by default and never anything else in production use of this
      #   class (see the class doc) -- injectable only so a spec can assert
      #   the default stays Null.
      def initialize(entries, oracle: Grader::FrustrationRepair::NullOracle.instance)
        @entries = entries.to_a.freeze
        @oracle = oracle
      end

      # @return [String] the rendered report; never printed here (output
      #   discipline -- the frontend prints)
      def render
        lines = signal_lines
        return clean_render if lines.empty?

        (["#{lines.size} friction signal(s):"] + lines).join("\n")
      end

      private

      def clean_render
        "no friction found -- analyzers run: #{ANALYZERS.join(", ")}"
      end

      def signal_lines
        rephrase_lines + steering_lines + rewrite_lines
      end

      def call_index
        @call_index ||= Grader::ToolCallIndex.new(@entries)
      end

      def rephrase_lines
        Grader::FrustrationRepair.new(oracle: @oracle).signals(@entries).map { |signal| rephrase_line(signal) }
      end

      def rephrase_line(signal)
        name = retried_tool_name(signal)
        knob = TIER_3_TOOL_NAMES.include?(name) ? KNOBS.fetch(:rephrase_loop_tier3) : KNOBS.fetch(:rephrase_loop)
        "rephrase_loop at #{signal.turn_digest} (#{name}, caused by #{signal.caused_by.join(", ")}): #{knob}"
      end

      # {Grader::FrustrationRepair::Signal} carries no tool name of its own --
      # only `turn_digest`/`caused_by` digests. The retried tool is the name
      # shared between an ERRORED call at the cause turn and a call at the
      # signal's own turn (the mechanical detector requires that exact name
      # match, frustration_repair.rb's `nearest_prior_use`); intersecting
      # recovers it without re-implementing that walk.
      def retried_tool_name(signal)
        retry_names = names_at(signal.turn_digest)
        shared = errored_names_at(signal.caused_by.first) & retry_names
        shared.first || retry_names.first || "unknown"
      end

      def names_at(digest)
        (call_index.calls[digest] || []).map(&:name)
      end

      def errored_names_at(digest)
        (call_index.calls[digest] || []).select(&:is_error).map(&:name)
      end

      def steering_lines
        Grader::ToolSteering.new(@entries).flags.map { |flag| steering_line(flag) }
      rescue Grader::ToolSteering::NoDeclaredTools
        []
      end

      def steering_line(flag)
        "tool_steering: #{flag.name} selected #{format("%.2f", flag.ratio)}x its declared share: " \
          "#{KNOBS.fetch(:tool_steering)}"
      end

      def rewrite_lines
        count = Bench::Rewrites.from_journal(@entries).count
        return [] if count <= CACHE_REWRITE_THRESHOLD

        ["cache_rewrites: #{count} prefix rewrites detected: #{KNOBS.fetch(:cache_rewrites)}"]
      end
    end
  end
end
