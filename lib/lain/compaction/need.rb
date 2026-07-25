# frozen_string_literal: true

module Lain
  module Compaction
    # Marks "compaction needed" WITHOUT compacting. #check is a pure query:
    # given a snapshot of the run's state, it says which signals fired, and
    # never touches {Context::Compact}. Deciding whether NOW is a good time to
    # pay for that rewrite (cache warmth, hard caps) is a separate, later
    # policy (`cache-aware-compaction.md`'s scheduler); deciding to actually
    # run it is {Context::Compact}'s job. This object answers only "is a
    # compaction warranted", and {Result} proves it structurally -- it carries
    # flags, never rewritten content, so there is nothing for a caller to
    # accidentally apply.
    #
    # Four independent signals, each its OWN small object rather than four
    # branches inside one method (CLAUDE.md: a tripped Metrics/* cop here
    # would be naming a missing collaborator, not licensing a raised limit).
    # #check just asks each detector in turn and collects who fired.
    class Need
      # What #check hands each detector. A Data type so the argument list
      # cannot silently drift from what a detector actually reads -- a fifth
      # signal means adding a field HERE, visibly, not threading one more
      # keyword through #check's signature and every detector's #fired?.
      #
      # `window_tokens` is the exception that proves it: a field added for a
      # PARAMETER, not for a signal. The context window belongs to the model
      # THIS turn renders through, and `/model` rewrites that mid-session
      # ({Context::ModelSwitch}), so a window fixed when the Need was built
      # would keep measuring occupancy against the model the run began with.
      # Per-turn state travels here; it does not make Need mutable.
      State = Data.define(:messages, :used_tokens, :window_tokens, :manual, :plan_step_completed)
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
      end

      # Crosses {Context::Compact}'s own proxy: the canonical byte length of
      # the candidate messages, not a real tokenizer (see that class's header
      # comment for why -- a deterministic proxy is the only property this
      # detector needs).
      class TokenThreshold
        KIND = :token_threshold

        def initialize(byte_threshold:)
          @byte_threshold = Integer(byte_threshold)
          freeze
        end

        def fired?(state) = Canonical.dump(state.messages).bytesize >= @byte_threshold
      end

      # Fires once usage crosses a configurable fraction of the model's
      # context window -- ahead of the hard cap, the way a fuel gauge warns
      # before empty rather than at it.
      #
      # It holds the RATIO (a policy, set once) and reads the WINDOW off the
      # state (a fact about this turn's model, which can change under a running
      # session). That split is what keeps this detector frozen and shareable
      # while still following a `/model` switch.
      class ApproachingWindow
        KIND = :approaching_window

        def initialize(ratio:)
          @ratio = Float(ratio)
          freeze
        end

        def fired?(state)
          !state.used_tokens.nil? && state.used_tokens >= state.window_tokens * @ratio
        end
      end

      # An explicit, on-demand trigger -- the caller already decided; this
      # detector's only job is to fold that decision into the same Result
      # shape as the other three.
      class Manual
        KIND = :manual

        def fired?(state) = state.manual
      end

      # A finished plan step is a natural summarization boundary (see
      # `cache-aware-compaction.md`'s Need-signal list). The transition
      # itself is detected upstream -- {Session#plan_step_completed?}, fed by
      # {Tools::TodoWrite} -- so this detector only relays the boolean it is
      # handed; it does not reach into a Session itself, keeping Need
      # decoupled from run-state storage.
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
      # @param messages [Array<Hash>] the candidate-for-drop head, sized the
      #   same way {Context::Compact} sizes it
      # @param used_tokens [Integer, nil] current usage against the context window
      # @param manual [Boolean] an explicit, on-demand trigger
      # @param plan_step_completed [Boolean] {Session#plan_step_completed?}'s signal
      # @return [Result]
      def check(window_tokens:, messages: [], used_tokens: nil, manual: false, plan_step_completed: false)
        state = State.new(messages:, used_tokens:, window_tokens: window!(window_tokens),
                          manual:, plan_step_completed:)
        fired = @detectors.select { |detector| detector.fired?(state) }.map { |detector| detector.class::KIND }
        Result.new(signals: fired)
      end

      private

      # The coercion {ApproachingWindow} ran at construction while the window
      # was its own, moved to where the value now arrives -- and it has to be
      # here rather than in `#fired?`, which short-circuits on a nil
      # `used_tokens`. A garbage window would otherwise stay SILENT until the
      # first turn carrying usage and then surface as a NoMethodError on nil
      # from inside a private detector, naming neither the parameter nor the
      # fix. Zero and negatives are worse: they raise nothing ever and fire
      # :approaching_window on every turn forever, which reads as a compaction
      # policy rather than as the wiring bug it is.
      def window!(window_tokens)
        tokens = Integer(window_tokens, exception: false)
        return tokens if tokens&.positive?

        raise ArgumentError, "window_tokens must be a positive Integer, got #{window_tokens.inspect} -- " \
                             "it is the context window of the model this turn renders through"
      end
    end
  end
end
