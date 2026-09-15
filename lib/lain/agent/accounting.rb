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
      # The run's cumulative {Usage}; the monoid sum of every observed response.
      attr_reader :usage

      # Readable so a caller can confirm what it was wired to.
      attr_reader :journal

      # @param journal [#<<] where TurnUsage records land; the Null channel by
      #   default, so no caller guards `if journal`
      def initialize(journal: Channel::Null.instance)
        @journal = journal
        @usage = Usage.zero
        @last_turn_usage = nil
      end

      # Roll one model response into the running total and journal it against
      # the turn it was committed as.
      #
      # @param response [Lain::Response]
      # @param digest [String] the committed assistant turn's content address
      # @return [Lain::Usage] the cumulative usage, ready for a budget check
      def observe(response, digest:)
        @usage += response.usage
        take_reading(response.usage)
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
      # @return [Integer, nil] the current reading
      def observe_refusal(prompt_tokens:)
        take_reading(Usage.new(input_tokens: prompt_tokens))
        @last_turn_usage
      end

      # Current context occupancy: the billed-on-the-way-in tokens of the most
      # recent response that reported any, not the run's cumulative sum. `#usage`
      # answers "what has this run spent"; compaction's `Need` needs "how full is
      # the context right now", which only a response carrying a real input count
      # can answer -- see `#take_reading` for why a response carrying none is
      # skipped rather than believed.
      #
      # @return [Integer, nil] nil before any turn -- distinct from zero, which
      #   would read as an empty context on a resumed session whose Accounting is
      #   fresh but whose Timeline is not
      attr_reader :last_turn_usage

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
      def take_reading(usage)
        reading = usage.total_input_tokens
        @last_turn_usage = reading if reading.positive?
      end
    end
  end
end
