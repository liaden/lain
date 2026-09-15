# frozen_string_literal: true

module Lain
  module Telemetry
    # The questions something consumed, named for the inbox readers that fold
    # the tee. Two producers write it, and `turn` tells them apart:
    #
    # * a SPAWNED chain's turn, naming that turn. A relayed question is addressed
    #   to the child's PARENT correlation, so the child's own answering turn is
    #   the only one that can consume it -- and that turn is kept off the
    #   telemetry tee, which left the live inbox surfaces listing a question
    #   nothing ever retired.
    # * a settled {Approval::Gate}, with `turn: nil`. A gate is no tool call, so
    #   no committed turn ever cites the question it asked; the gate names it
    #   consumed itself, however its wait ended. A nil `turn` means exactly
    #   that no turn did the consuming -- read `digests`, never `turn`, to
    #   retire.
    #
    # {ChildTurn} carries the same edges and is not routed instead: it costs the
    # child's whole transcript (measured in its own doc) where this is a flat
    # ~134 bytes, and -- the larger half of the saving -- it routes on EVERY
    # child turn where this routes only on one that cites something.
    #
    # It answers no `#usage`, `#digest`, `#kind` or `#head`: the ducks by which
    # the two inbox surfaces admit a turn's payment and {CLI::FleetWindows} a
    # boundary. One that answered them would retire on one surface, not both.
    QuestionsConsumed = Data.define(:turn, :digests) do
      include Journalable

      # @param event [Lain::Event] a `:turn` arriving on the
      #   {Event::ChainWriter} funnel, which is to say a spawned chain's
      # @return [QuestionsConsumed]
      def self.from_event(event) = new(turn: event.digest, digests: event.causal_parents)

      def initialize(turn:, digests:)
        # The producer's shape (a list) is not enforced by `Canonical.normalize`
        # alone, so the constructor enforces it here instead of trusting the
        # next caller to match it.
        super(turn: Canonical.normalize(turn),
              digests: Array(digests).map { |digest| Canonical.normalize(digest) }.uniq.freeze)
      end
    end
  end
end
