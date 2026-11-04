# frozen_string_literal: true

module Lain
  module Epic
    # Whether an epic's issues can reach the red step: each tested issue's
    # declared subject and level must place under the project's test layout.
    # Asked after the issues are written, when a bad `Subject:` is still a
    # one-line edit rather than a refusal mid-implementation.
    #
    # It reads issues and a layout and starts no driver.
    class Readiness
      # Just enough of a name for a flat level's test path to be arithmetic.
      PROBE_NAME = "probe"

      private_constant :PROBE_NAME

      # @param graph [Epic::Graph] the epic's issues
      # @param layout [TestLayout] the project's declared layout
      # @return [Readiness]
      def self.of(graph, layout)
        tested, manual = graph.partition { |issue| tested?(issue) }
        refusals = layout.in_force? ? tested.filter_map { |issue| refusal(issue, layout) }.to_h : {}
        new(tested:, manual: manual.size, unplaceable: refusals, layout:)
      end

      def self.tested?(issue) = CLI::EpicDriver::Acceptance.of_issue(issue).placed_by_layout?

      def self.refusal(issue, layout)
        subject = CLI::EpicDriver::PlanSubject.of(issue, layout:)
        mapping = layout.mapping
        level = subject.level || mapping.default_level&.name
        mapping.test_path(subject.subject, level:, name: (PROBE_NAME if mapping.level(level).flat?))
        nil
      rescue CLI::EpicDriver::PlanSubject::Refusal, TestLayout::Unplaceable => e
        [issue.id, e.message]
      end
      private_class_method :tested?, :refusal

      # @return [Hash{String => String}] issue id to why its tests have nowhere to go
      attr_reader :unplaceable

      # @return [Integer] issues judged by failing tests
      def tested = @tested.size

      # @return [Integer] issues judged by a human
      attr_reader :manual

      def initialize(tested:, manual:, unplaceable:, layout:)
        @tested = tested
        @manual = manual
        @unplaceable = unplaceable.freeze
        @layout = layout
        freeze
      end

      def missing_layout? = !@layout.in_force?

      def ready? = !missing_layout? && unplaceable.empty?

      # @return [String, nil] the `.lain/config.rb` line placing {#placed_by_proposal}; nil when none can be placed
      def proposal
        preset = proposed_preset
        preset && "tests preset: :#{preset}, source_roots: #{proposed_roots.inspect}"
      end

      # @return [Array<String>] ids of the issues the proposed line would place
      def placed_by_proposal = placeable.map(&:id)

      # @return [Array<String>] ids of tested issues with no subject, or one at the project root, which no
      #   source root can hold
      def needs_subject = (@tested - placeable_candidates).map(&:id)

      def to_s
        [headline, *problems, "#{tested} tested, #{manual} manual"].join("\n")
      end

      private

      def placeable_candidates = @tested.select { |issue| issue.subject && File.dirname(issue.subject) != "." }

      def placeable = placeable_candidates.select { |issue| preset_for(issue.subject) == proposed_preset }

      def proposed_preset = placeable_candidates.filter_map { |issue| preset_for(issue.subject) }.first

      def proposed_roots = placeable.map { |issue| File.dirname(issue.subject) }.uniq

      def preset_for(subject)
        TestLayout::PRESETS.values.find { |preset| preset.test_file.extension == File.extname(subject) }&.name
      end

      def proposed_line
        "add to .lain/config.rb: #{proposal || "a `tests` line naming the preset and source roots"}"
      end

      def headline
        return "readiness: ready" if ready?

        missing_layout? ? "readiness: no test layout" : "readiness: #{unplaceable.size} unplaceable"
      end

      def problems
        return unplaceable.map { |id, reason| "- #{id} unplaceable: #{reason}" } unless missing_layout?

        [proposed_line, *needs_subject.map { |id| "- #{id} needs a Subject under a source root" }]
      end
    end
  end
end
