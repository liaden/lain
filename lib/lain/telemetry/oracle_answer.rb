# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # An oracle-answer record must name the oracle it answered (the digest
      # replay substitutes on) and carry the question that was asked.
      class OracleAnswer < Declarative::Carrier
        attribute :oracle_digest
        attribute :question, :lain_canonical
        attribute :answer, :lain_canonical
        attribute :model, default: nil
        attribute :usage, :lain_canonical, default: -> { {} }
        attribute :wall_clock, default: 0.0
        validates :oracle_digest, presence: { message: "must name the oracle it answered, got nil" }
        validates :question, presence: { message: "must carry the question asked, got nil" }
      end
    end

    # One oracle call, recorded for deterministic replay. `oracle_digest` is the
    # {Oracle::Definition#digest} -- the JOIN KEY {Oracle::Recorded} substitutes
    # on, and precisely why a CHANGED oracle schema (a different digest) misses
    # loudly rather than matching a stale answer. `question` is the rendered,
    # `Canonical.normalize`d prompt, the second half of the `(digest, question)`
    # key. `answer` is the raw answer attributes the definition's schema
    # validated, fed straight back through {Oracle::Definition#answer} on replay
    # -- so a schema the recording no longer satisfies raises THERE too, a
    # second loud staleness guard behind the digest key.
    #
    # `model` names the tier's model (nil for the model-free {Oracle::Heuristic}
    # and a bare mock); `usage` is the call's token accounting in canonical wire
    # form (empty when the tier reported none -- the tier interface deliberately
    # hides which tier answered, so the decorator journals what the caller's
    # wiring supplies); `wall_clock` is the measured elapsed seconds. All three
    # are accounting metadata, NOT part of the substitution key -- like
    # {TurnUsage}, this record is a per-call payment stream, not a dedupe set.
    #
    # Emitted by {Oracle::Recorded::Journaling}, read back by
    # {Oracle::Recorded.from_journal} -- the same "recorded is a replay of a real
    # interpretation" shape as {Verdict}/{Grader::Refuter::Recorded}, one oracle
    # tier over.
    OracleAnswer = Data.define(:oracle_digest, :question, :answer, :model, :usage, :wall_clock) do
      include Journalable

      def initialize(oracle_digest:, question:, answer:, model: nil, usage: {}, wall_clock: 0.0)
        settled = Carriers::OracleAnswer.settle!(oracle_digest:, question:, answer:, model:, usage:, wall_clock:)

        super(**settled, model: settled[:model]&.to_s&.freeze, wall_clock: settled[:wall_clock].to_f)
      end
    end
  end
end
