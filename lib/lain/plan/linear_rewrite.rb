# frozen_string_literal: true

module Lain
  module Plan
    # The linear-rewrite execution shape: the timeline stays LINEAR (every
    # chunk's turns are committed to the one mainline, nothing forks away), and
    # the state effect lands entirely on the {Continuation}'s PIPELINE half.
    # After a chunk closes, subsequent turns render through a Compact-shaped
    # pipeline whose summarizer is the deterministic rendering of EVERY chunk
    # closed so far -- so the chunks' verbatim turns are elided from the render
    # (they remain in the Store, addressed by their closures) and one summary
    # standing in for all of them rides in their place.
    #
    # Because the same mainline positions now render to SUMMARIZED bytes, the
    # prompt-cache prefix is rewritten at the seam -- which is exactly the
    # difference PC-3 makes visible: a linear-rewrite run shows one prefix
    # rewrite per seam where a {ForkPerStep} run shows none.
    #
    # The plan-shaped working view a linear run carries is `plan + every closed
    # chunk's record + the current chunk`, so the summarizer must ACCUMULATE:
    # summarizing only the LATEST chunk would silently drop every earlier
    # closure from the render and under-inform the arm (and corrupt a later
    # shape comparison). It therefore keeps the closures in seam order and
    # renders all of them into ONE summary each seam.
    #
    # Stateful, like {ForkPerStep} and unlike {Compaction::Scheduler}, on two
    # counts: it accumulates the closed closures, and it MEMOIZES the original
    # base pipeline from the first seam's incoming continuation. It always
    # composes a SINGLE Compact over that fixed base, never over the
    # already-rewritten pipeline -- stacking Compact-over-Compact each seam would
    # re-summarize a summary. One Compact over the fixed base, whose summarizer
    # names all closures so far, keeps the render honest without stacking.
    class LinearRewrite
      include SeamPolicy

      # @param pipeline_factory [#call] answers
      #   +call(closures:, base:) -> shareable pipeline+; defaults to
      #   {CompactRewrite}, which composes a {Context::Compact} whose summarizer
      #   renders the closed closures deterministically ahead of +base+
      def initialize(pipeline_factory: CompactRewrite.new)
        @factory = pipeline_factory
        @base = nil
        @closed = []
      end

      # Leave the timeline head where the chunk left it (linear) and swap in a
      # pipeline that summarizes every chunk closed so far going forward.
      #
      # @param state [Continuation] the current continuation; its +head_digest+
      #   passes through unchanged, its +pipeline+ (first time only) is captured
      #   as the base every rewrite composes over
      # @param closure [Closure] the just-closed chunk's deterministic record
      # @return [Continuation]
      def at_seam(state:, closure:)
        @base ||= state.pipeline
        @closed << closure
        Continuation.new(head_digest: state.head_digest, pipeline: @factory.call(closures: @closed.dup, base: @base))
      end
    end

    # A callable that renders a fixed String, ignoring the messages Compact hands
    # it: the summary of the closed chunks is their deterministic rendering, not
    # a function of the bytes being dropped. A frozen value (String member), so
    # it is +Ractor.shareable?+ and rides safely inside the pipeline a
    # {Continuation} carries -- where a bare Proc would fail shareability the
    # moment the Context storing it was forked.
    ClosureSummary = Data.define(:text) do
      def initialize(text:)
        super(text: -text.to_s)
      end

      def call(_dropped)
        text
      end
    end

    # The default {LinearRewrite} pipeline factory: it builds a
    # {Context::Compact} whose summarizer is a {ClosureSummary} of ALL closed
    # closures, and composes it AHEAD of the base -- Compact runs first so the
    # head is summarized before the base's reminders inject and its cache marks
    # land (the same ordering {Compaction::Scheduler} uses).
    #
    # Frozen and shareable (only Integer knobs), so the pipeline it returns is
    # itself shareable when the base is. {COMPOSE} is a class-scope lambda for
    # the reason spelled out in {Compaction::Scheduler}: a Proc built inside an
    # instance method captures that instance as its +self+, and would drag it
    # (and anything it holds) into the pipeline, failing +Ractor.make_shareable+;
    # here +self+ is the class and the shareable +compact+/+base+ arrive as
    # explicit arguments.
    class CompactRewrite
      # @param threshold [Integer] byte-length proxy above which Compact fires
      # @param keep_last [Integer] trailing messages kept verbatim under Compact
      def initialize(threshold: 1, keep_last: 1)
        @threshold = Integer(threshold)
        @keep_last = Integer(keep_last)
        freeze
      end

      # @param closures [Array<Closure>] every chunk closed so far, in seam
      #   order; all are rendered into the one summary
      # @param base [#call, #requires] the pipeline Compact composes ahead of --
      #   a Combinator (used as-is) or a +->(workspace)+ provider (called per
      #   render), the same duck {Context#render} resolves
      # @return [Proc] a shareable +->(workspace)+ pipeline provider
      def call(closures:, base:)
        compact = Context::Compact.new(threshold: @threshold, keep_last: @keep_last,
                                       summarizer: ClosureSummary.new(text: render(closures)))
        COMPOSE.call(compact, base)
      end

      private

      # The closed chunks' deterministic rendering: one line per closure in seam
      # order, derived entirely from content-addressed fields so a replay
      # reproduces it byte-for-byte. Each line names its own elision count --
      # what the summary stands in FOR -- rather than copying the elided turns.
      def render(closures)
        closures.map { |closure| render_one(closure) }.join("\n")
      end

      def render_one(closure)
        "[closure #{closure.step_id} #{closure.status} score=#{closure.score} pass=#{closure.passed}] " \
          "#{closure.why} (elided #{closure.elided_digests.size} turns)"
      end

      COMPOSE = lambda do |compact, base|
        Ractor.make_shareable(
          ->(workspace) { compact >> (base.respond_to?(:requires) ? base : base.call(workspace)) }
        )
      end
      private_constant :COMPOSE
    end
  end
end
