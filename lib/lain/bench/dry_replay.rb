# frozen_string_literal: true

module Lain
  module Bench
    # Re-render a recorded Timeline under a (possibly different) Context and
    # byte-diff against the recorded baseline. Pure, instant, deterministic, and
    # free -- no API. This is the whole reason `Context#render` is a pure
    # function of `(Timeline, Toolset, Workspace)`: a strategy change costs a
    # re-render and a diff, not a re-run.
    #
    # Both inputs are what a real run naturally holds: the recorded FINAL
    # Timeline, and the Requests that were ACTUALLY sent, one per model call, in
    # order. The baseline is DATA, never re-derived from the Context under test.
    #
    # The prefix each recorded Request rendered over is RECONSTRUCTED from the
    # recorded DAG rather than trusted: a model call happens immediately before
    # its assistant turn commits, so the k-th recorded Request rendered exactly
    # the timeline whose head is the k-th assistant turn's parent. Walking the
    # DAG's assistant-turn boundaries recovers those prefixes with no extra
    # recording, and that is what makes the byte-identity claim a real test of
    # `#render` purity: re-rendered under the recording's own Context, the bytes
    # must match to the digest -- which they cannot if `#render` leaked a clock
    # or a pwd.
    #
    # A compacted run did not send its prefixes as they stand: each request
    # rendered through the compaction cuts held when it was sent. Handed the
    # run's recorded cuts and keep, each step renders through them again, from
    # the record and with no model call -- writing the derived chains it
    # renders into the recording's Store, as the live run did into its own.
    class DryReplay
      # A recorded model call: the reconstructed Timeline prefix that was
      # rendered, paired with the recorded Request the render produced, and
      # the recorded cut it was sent under -- nil before any held.
      Step = Data.define(:index, :timeline, :recorded, :cut)

      # A step before anyone has asked which cut it holds.
      Call = Data.define(:index, :timeline, :recorded)
      private_constant :Call

      # The {Compaction::Source::HeldCut} duck for a run that committed no cut.
      module Unheld
        module_function

        def in_force = nil

        def render(context) = context
      end
      private_constant :Unheld

      # @param timeline [Lain::Ext::Timeline] the recorded final DAG
      # @param baseline [Array<Lain::Request>] requests actually sent, in order
      # @param toolset [#to_schema] the toolset in effect at record time
      # @param workspace [Lain::Workspace] the workspace in effect at record time
      # @param cuts [Session, nil] the recording's restored compaction cuts, or
      #   nil for a run that committed none
      # @param keep_last [Integer] the keep the run compacted under, which
      #   decides whether a cut still holds
      def initialize(timeline:, baseline:, toolset:, workspace: Workspace.empty, cuts: nil,
                     keep_last: ::Lain::CLI::Backend::DEFAULT_KEEP_LAST)
        @toolset = toolset
        @workspace = workspace
        @calls = reconstruct(timeline, Array(baseline))
        @holding = holding(cuts, keep_last)
        @held = {}
      end

      # @return [Integer] one per recorded model call
      def steps
        @calls.size
      end

      # @yieldparam step [Step] each recorded model call, in order
      # @return [Enumerator<Step>] without a block
      def each_step
        return enum_for(:each_step) { steps } unless block_given?

        @calls.each { |call| yield Step.new(**call.to_h, cut: held(call).in_force) }
      end

      # Re-render every recorded step's prefix under `context`.
      #
      # @param context [Lain::Context]
      # @return [Array<Lain::Request>] one per step, in order
      def replay(context)
        chain = Request::PrefixChain.new
        @calls.map { |call| render(held(call).render(context), call.timeline, chain) }
      end

      # Byte-diff the recorded baseline against a re-render under `context`.
      #
      # @param context [Lain::Context]
      # @return [Diff] deterministic for identical inputs
      def diff(context)
        replayed = replay(context)
        Diff.new(@calls.zip(replayed).map { |call, request| StepDiff.build(call.index, call.recorded, request) })
      end

      private

      # One derivation shared by every step, for speed: a held render resumes
      # the derived chain the step before it built rather than deriving from
      # the root again. The arm is the one the cuts were recorded under, which
      # is the name a cut must match to hold.
      def holding(cuts, keep_last)
        return ->(_timeline) { Unheld } if cuts.nil?

        derived = Compaction::Source::Derived.new(keep_last: Compaction.validate_keep_last(keep_last))
        arm = cuts.compaction_cuts.last&.strategy
        ->(timeline) { Compaction::Source::HeldCut.on(session: cuts, timeline:, derived:, arm:) }
      end

      # Found on first ask, so a caller counting steps walks no chain per step.
      def held(call) = @held[call.index] ||= @holding.call(call.timeline)

      def render(context, timeline, chain)
        context.render(timeline:, toolset: @toolset, workspace: @workspace, chain:)
      end

      # Couples to `Agent#step`'s commit order: the model is called, THEN its
      # assistant turn commits, so the k-th assistant turn's parent is exactly
      # the head the k-th recorded Request saw. Two guards keep a future Agent
      # reorder from turning that into a silent mystery -- the size check below
      # raises when the counts stop lining up, and the digest-for-digest spec
      # fails loudly if the ORDER drifts, since a mis-paired prefix re-renders
      # to different bytes than the baseline.
      def reconstruct(timeline, baseline)
        assistant_turns = timeline.to_a.select { |turn| turn.role == "assistant" }
        unless assistant_turns.size == baseline.size
          raise ArgumentError,
                "baseline has #{baseline.size} request(s) but the recorded DAG has " \
                "#{assistant_turns.size} model call(s); they must line up 1:1"
        end

        assistant_turns.each_with_index.map do |turn, index|
          Call.new(index:, timeline: timeline.checkout(turn.parent), recorded: baseline.fetch(index))
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
        new(index:, recorded:, replayed:, changed_fields: changed.freeze)
      end

      def identical?
        changed_fields.empty?
      end
    end

    # The whole replay's diff: one StepDiff per model call. The steps array is
    # frozen -- its StepDiff members already are, being Data with a frozen
    # `changed_fields` -- so a Diff clears `Ractor.shareable?` like every other
    # value object here.
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
