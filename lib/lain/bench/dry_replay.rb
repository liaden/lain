# frozen_string_literal: true

require_relative "../canonical"
require_relative "../error"
require_relative "../workspace"

module Lain
  module Bench
    # Re-render a recorded Timeline under a (possibly different) Context and
    # byte-diff against the recorded baseline. Pure, instant, deterministic, and
    # free -- no API. This is the whole reason `Context#render` is a pure
    # function of `(Timeline, Toolset, Workspace)`: a strategy change costs a
    # re-render and a diff, not a re-run.
    #
    # == How it obtains the recorded Timeline and the baseline
    #
    # Honestly, from what a real run naturally holds. The inputs are:
    #
    # * `timeline` -- the recorded FINAL Timeline: the actual content-addressed
    #   DAG the run produced (`agent.timeline`).
    # * `baseline` -- the Requests that were ACTUALLY sent, one per model call,
    #   in order (`provider.requests`). These are the recorded bytes to diff
    #   against; they are DATA, not re-derived from the Context under test.
    #
    # The prefix each recorded Request rendered over is RECONSTRUCTED from the
    # recorded DAG rather than trusted: a model call happens immediately before
    # its assistant turn commits, so the k-th recorded Request rendered exactly
    # the timeline whose head is the k-th assistant turn's parent. Walking the
    # DAG's assistant-turn boundaries recovers those prefixes with no extra
    # recording. Reconstructing rather than re-deriving is what makes the
    # byte-identity claim a real test of `#render` purity: re-render each prefix
    # under the recording's own Context and the bytes must match the baseline
    # to the digest -- which they cannot if `#render` leaked a clock or a pwd.
    class DryReplay
      # A recorded model call: the reconstructed Timeline prefix that was
      # rendered, paired with the recorded Request the render produced.
      Step = Data.define(:index, :timeline, :recorded)

      # @param timeline [Lain::Timeline] the recorded final DAG
      # @param baseline [Array<Lain::Request>] requests actually sent, in order
      # @param toolset [#to_schema] the toolset in effect at record time
      # @param workspace [Lain::Workspace] the workspace in effect at record time
      def initialize(timeline:, baseline:, toolset:, workspace: Workspace.empty)
        @toolset = toolset
        @workspace = workspace
        @steps = reconstruct(timeline, Array(baseline))
      end

      # @return [Integer] one per recorded model call
      def steps
        @steps.size
      end

      # Re-render every recorded step's prefix under `context`.
      #
      # @param context [Lain::Context]
      # @return [Array<Lain::Request>] one per step, in order
      def replay(context)
        @steps.map { |step| render(context, step.timeline) }
      end

      # Byte-diff the recorded baseline against a re-render under `context`.
      #
      # @param context [Lain::Context]
      # @return [Diff] deterministic for identical inputs
      def diff(context)
        Diff.new(@steps.map { |step| StepDiff.build(step.index, step.recorded, render(context, step.timeline)) })
      end

      private

      def render(context, timeline)
        context.render(timeline: timeline, toolset: @toolset, workspace: @workspace)
      end

      # Recover, from the recorded DAG, the Timeline prefix each model call
      # rendered over. Assistant turns in oldest-first order ARE the model
      # calls; each rendered the prefix ending at its parent.
      #
      # This couples to Agent#step's commit order: the model is called, THEN its
      # assistant turn commits, so the k-th assistant turn's parent is exactly
      # the head the k-th recorded Request saw. Two guards keep a future Agent
      # reorder from turning that into a silent mystery: the size check below
      # raises when the counts stop lining up, and the "matches the recorded
      # bytes digest-for-digest" spec fails loudly if the ORDER ever drifts, since
      # a mis-paired prefix re-renders to different bytes than the baseline.
      def reconstruct(timeline, baseline)
        assistant_turns = timeline.to_a.select { |turn| turn.role == "assistant" }
        unless assistant_turns.size == baseline.size
          raise ArgumentError,
                "baseline has #{baseline.size} request(s) but the recorded DAG has " \
                "#{assistant_turns.size} model call(s); they must line up 1:1"
        end

        assistant_turns.each_with_index.map do |turn, index|
          Step.new(index: index, timeline: timeline.checkout(turn.parent), recorded: baseline.fetch(index))
        end
      end
    end

    # One step's byte comparison: the recorded Request vs the re-rendered one,
    # and the `cache_payload` fields whose canonical bytes changed. A frozen
    # value so two diffs of identical inputs are `==`.
    StepDiff = Data.define(:index, :recorded, :replayed, :changed_fields) do
      # Compare on the CACHE payload -- the bytes that decide prompt-cache
      # identity -- field by field, so a difference is named, not just detected.
      def self.build(index, recorded, replayed)
        before = recorded.cache_payload
        after = replayed.cache_payload
        changed = (before.keys | after.keys).reject do |field|
          Canonical.dump(before[field]) == Canonical.dump(after[field])
        end
        new(index: index, recorded: recorded, replayed: replayed, changed_fields: changed.freeze)
      end

      def identical?
        changed_fields.empty?
      end
    end

    # The whole replay's diff: one StepDiff per model call. `#identical?` is the
    # byte-identity verdict the identity-Context acceptance test asserts. The
    # steps array is frozen (its StepDiff members already are, being Data with a
    # frozen `changed_fields`) so a Diff clears the project's `Ractor.shareable?`
    # bar like every other value object here.
    Diff = Data.define(:steps) do
      def initialize(steps:)
        super(steps: steps.freeze)
      end

      def identical?
        steps.all?(&:identical?)
      end
    end
  end
end
