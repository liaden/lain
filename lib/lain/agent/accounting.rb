# frozen_string_literal: true

module Lain
  class Agent
    # The run's token ledger.
    #
    # Split out of the Agent for the same reason Budget was: rolling up and
    # recording spend is bookkeeping, not the loop's job. Per-turn cost lives in
    # the Journal, one {Telemetry::TurnUsage} per model call, keyed by the
    # committed turn's digest.
    class Accounting
      # How full a context was, and the turn the measured chain stood on. A
      # reading describes a chain, so it is believed only on a chain still
      # holding that turn: after a rewind past it the number describes history
      # no request will carry, and believing it fires the window signal on a
      # context a fraction of its size. `head` is nil for a chain standing on
      # nothing, which every chain extends.
      Reading = Data.define(:tokens, :head) do
        # @param timeline [Timeline] the chain being asked about
        # @return [Integer, nil] the tokens, or nil where the reading does not
        #   describe `timeline`
        def on(timeline) = head.nil? || timeline.include?(head) ? tokens : nil
      end

      # No reading yet: absent on every chain.
      module Unread
        def self.on(_timeline) = nil
      end

      # The run's cumulative {Usage}; the monoid sum of every observed response.
      attr_reader :usage

      # Readable so a caller can confirm what it was wired to.
      attr_reader :journal

      # @param journal [#<<] where TurnUsage records land; the Null channel by
      #   default, so no caller guards `if journal`
      def initialize(journal: Channel::Null.instance)
        @journal = journal
        @usage = Usage.zero
        @reading = Unread
      end

      # Roll one model response into the running total and journal it against
      # the turn it was committed as.
      #
      # @param response [Lain::Response]
      # @param digest [String] the committed assistant turn's content address
      # @return [Lain::Usage] the cumulative usage, ready for a budget check
      def observe(response, digest:)
        @usage += response.usage
        take_reading(response.usage, head: digest)
        @journal << Telemetry::TurnUsage.new(
          digest:,
          model: response.model,
          stop_reason: response.stop_reason,
          usage: response.usage.to_h
        )
        @usage
      end

      # A prompt the provider refused whole for not fitting its context, which
      # it measured with its own tokenizer against the context it loaded: the
      # most believable reading a run gets, and the only one a refused turn
      # yields. Nothing was generated or billed, so nothing is summed and no
      # record lands. Without it compaction's approaching-window signal goes on
      # reading the last ANSWERED turn and never fires, and every later prompt
      # is refused the same way.
      #
      # @param prompt_tokens [Integer] the provider's exact prompt count
      # @param head [String, nil] the turn below the refused prompt, which the
      #   caller names because only it knows the prompt may be withdrawn: the
      #   count still describes that chain plus the next prompt put on it
      # @return [Reading, Unread] the current reading
      def observe_refusal(prompt_tokens:, head:)
        take_reading(Usage.new(input_tokens: prompt_tokens), head:)
        @reading
      end

      # Current context occupancy: the billed-on-the-way-in tokens of the most
      # recent response that reported any, not the run's cumulative sum. `#usage`
      # answers "what has this run spent"; compaction's `Need` needs "how full is
      # the context right now", which only a response carrying a real input count
      # can answer -- see `#take_reading` for why a response carrying none is
      # skipped rather than believed.
      #
      # @param on [Timeline] the chain whose occupancy is asked
      # @return [Integer, nil] nil before any turn, and on a chain that no
      #   longer holds the turn the reading stood on -- distinct from zero,
      #   which would read as an empty context
      def last_turn_usage(on:) = @reading.on(on)

      private

      # The gate is over exactly the value being written -- one local, so the two
      # cannot drift apart. Zero is how missing billing information arrives,
      # every nullable field on the wire normalizing to it, so a response
      # reporting no input tokens has said nothing about how full the window is.
      # Writing its zero would report an emptied context: `Agent#occupancy` falls
      # to 0.0 and `Need` stops firing until a genuine reading arrives.
      #
      # Gating on the whole four-field value would let precisely that through,
      # since output tokens make it non-zero while the three input fields being
      # summed are all still zero -- the shape Ollama really produces when a
      # body omits `prompt_eval_count`. Ignoring output is correct here:
      # occupancy asks what filled the window on the way IN, and this turn's
      # output is accounted as the next turn's input.
      #
      # Spelled `.positive?` rather than "not zero", though the two agree on
      # every value a provider can produce, because neither this type nor
      # {StatusFeed::JournaledUsage} -- which answers the same question for a
      # resumed session -- forbids a NEGATIVE sum: `Integer()` and `#to_i` both
      # take one. That is the single input the spellings disagree on, one
      # suppressing where the other measures, so both producers of this reading
      # say `.positive?` and the policy has one spelling instead of two that
      # merely happen to agree on the inputs anyone expects.
      #
      # The turn itself is never suppressed -- the cumulative total and the
      # journal record above still count it -- and no real reading can be lost
      # this way.
      def take_reading(usage, head:)
        tokens = usage.total_input_tokens
        @reading = Reading.new(tokens:, head:) if tokens.positive?
      end
    end
  end
end
