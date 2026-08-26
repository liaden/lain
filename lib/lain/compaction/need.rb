# frozen_string_literal: true

module Lain
  module Compaction
    # Marks "compaction needed" WITHOUT compacting. {#check} is a pure query
    # over a snapshot of the run's state, and {Result} makes that structural:
    # it carries flags, never rewritten content, so there is nothing for a
    # caller to accidentally apply. WHEN a warranted compaction runs is
    # {Scheduler}'s; performing it is {Context::Compact}'s.
    #
    # Four independent signals, each its OWN small object rather than four
    # branches inside one method.
    class Need
      # What {#check} hands each detector. A Data type so the argument list
      # cannot silently drift from what a detector actually reads: a fifth
      # signal means adding a field HERE, visibly, rather than threading one
      # more keyword through `#check`'s signature and every detector's
      # `#fired?`.
      #
      # `window_tokens` is a field added for a PARAMETER rather than a signal.
      # The context window belongs to the model THIS turn renders through, and
      # `/model` rewrites that mid-session, so a window fixed when the Need was
      # built would keep measuring occupancy against the model the run began
      # with. Per-turn state travels here; it does not make Need mutable.
      State = Data.define(:head_bytes, :used_tokens, :window_tokens, :manual, :plan_step_completed)
      private_constant :State

      # Which signals fired, as a frozen list of Symbols; empty means "not
      # needed". A Data type rather than a bare Array so a caller asks
      # `.needed?` instead of re-deriving "non-empty" at every call site.
      Result = Data.define(:signals) do
        def initialize(signals:)
          super(signals: signals.to_a.freeze)
        end

        # @return [Boolean]
        def needed? = !signals.empty?

        # This result with one detector's signal withdrawn, for a caller that
        # knows something the detector bank cannot: {Compaction::Source} holds
        # the window BOOK and so knows whether the number {ApproachingWindow}
        # compared against was measured, published or guessed, while the
        # detector sees only the integer.
        #
        # A message rather than `Result.new(signals: r.signals - [kind])` at
        # the call site, which reconstructs a frozen value object from outside
        # and spreads the shape of this type into its callers.
        #
        # @param kind [Symbol] which detector to withdraw, named by its `KIND`
        #   constant. One that did not fire passes through unchanged, which is
        #   the ordinary case rather than an error.
        # @return [Result]
        def without(kind) = with(signals: signals - [kind])
      end

      # Crosses {Context::Compact}'s own proxy: the canonical byte length of
      # the candidate messages, not a real tokenizer.
      #
      # It READS that length rather than measuring it. {Compaction::Head}
      # measures itself at construction and holds the count, so dumping it
      # again here was a second full Canonical pass over the droppable history
      # on every turn, including every turn that then deferred.
      class TokenThreshold
        KIND = :token_threshold

        def initialize(byte_threshold:)
          @byte_threshold = Integer(byte_threshold)
          freeze
        end

        def fired?(state) = state.head_bytes >= @byte_threshold
      end

      # Fires once usage crosses a configurable fraction of the model's
      # context window -- ahead of the hard cap, the way a fuel gauge warns
      # before empty rather than at it.
      #
      # It holds the RATIO (a policy, set once) and reads the WINDOW off the
      # state (a fact about this turn's model, which can change under a running
      # session). That split keeps the detector frozen and shareable while
      # still following a `/model` switch.
      #
      # It measures {ContextWindow::Occupancy}, the same value a chat status
      # line reads, so "90% full" and "fired" cannot disagree. Absence -- no
      # turn yet -- is the Null {ContextWindow::Occupancy::None}, which never
      # fires.
      class ApproachingWindow
        KIND = :approaching_window

        def initialize(ratio:)
          @ratio = Float(ratio)
          freeze
        end

        def fired?(state)
          occupancy = ContextWindow::Occupancy.of(used_tokens: state.used_tokens,
                                                  window_tokens: state.window_tokens)
          occupancy.at_least?(@ratio)
        end
      end

      # An explicit, on-demand trigger -- the caller already decided; this
      # detector's only job is to fold that decision into the same Result
      # shape as the other three.
      class Manual
        KIND = :manual

        def fired?(state) = state.manual
      end

      # A finished plan step is a natural summarization boundary. The
      # transition is detected upstream, so this detector only relays the
      # boolean it is handed and never reaches into a Session -- which is what
      # keeps Need decoupled from run-state storage.
      class PlanStepCompletion
        KIND = :plan_step_completion

        def fired?(state) = state.plan_step_completed
      end

      DETECTORS = [TokenThreshold, ApproachingWindow, Manual, PlanStepCompletion].freeze
      private_constant :DETECTORS

      # @param byte_threshold [Integer] see {TokenThreshold}
      # @param approaching_ratio [Float] see {ApproachingWindow}
      def initialize(byte_threshold:, approaching_ratio: 0.9)
        @detectors = [
          TokenThreshold.new(byte_threshold:),
          ApproachingWindow.new(ratio: approaching_ratio),
          Manual.new.freeze,
          PlanStepCompletion.new.freeze
        ].freeze
        freeze
      end

      # @param window_tokens [Integer] the context window of the model THIS turn
      #   renders through. Required, and deliberately not defaulted: a guessed
      #   window is a silently wrong threshold, and the one thing worse than
      #   compacting early is never compacting at all.
      # @param head_bytes [Integer] the candidate-for-drop head in
      #   {Context::Compact}'s byte proxy, ALREADY MEASURED ({Head#bytesize}).
      #   Defaults to nothing droppable, the honest reading for a caller naming
      #   no head at all, which no configurable threshold can cross.
      # @param used_tokens [Integer, nil] current usage against the context window
      # @param manual [Boolean] an explicit, on-demand trigger
      # @param plan_step_completed [Boolean] {Session#plan_step_completed?}'s signal
      # @return [Result]
      def check(window_tokens:, head_bytes: 0, used_tokens: nil, manual: false, plan_step_completed: false)
        state = State.new(head_bytes:, used_tokens:, window_tokens: window!(window_tokens),
                          manual:, plan_step_completed:)
        fired = @detectors.select { |detector| detector.fired?(state) }.map { |detector| detector.class::KIND }
        Result.new(signals: fired)
      end

      private

      # HERE rather than in `#fired?`, which short-circuits on a nil
      # `used_tokens`: a garbage window would otherwise stay SILENT until the
      # first turn carrying usage and then surface as a NoMethodError on nil
      # from inside a private detector, naming neither the parameter nor the
      # fix. Zero and negatives are worse -- they raise nothing ever and fire
      # `:approaching_window` on every turn forever, which reads as a
      # compaction policy rather than as the wiring bug it is.
      def window!(window_tokens)
        tokens = Integer(window_tokens, exception: false)
        return tokens if tokens&.positive?

        raise ArgumentError, "window_tokens must be a positive Integer, got #{window_tokens.inspect} -- " \
                             "it is the context window of the model this turn renders through"
      end
    end
  end
end
