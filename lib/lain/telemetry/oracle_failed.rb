# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Mirrors {OracleAnswer}'s own two required attributes, plus the one thing
      # a failure adds and an answer never carries: what broke.
      class OracleFailed < Declarative::Carrier
        attribute :tier
        attribute :oracle_digest
        attribute :error_class
        validates :tier, presence: { message: "must name the oracle's tier, got nil" }
        validates :oracle_digest, presence: { message: "must name the oracle that failed, got nil" }
        validates :error_class, presence: { message: "must name what broke, got nil" }
      end
    end

    # One oracle call that raised before it could answer, journaled by
    # {Oracle::Recorded::Journaling} beside the {RequestSent} its inner tier
    # already wrote. Before this record existed, a failed call read as an
    # absence: a {RequestSent} with no {OracleAnswer} after it, indistinguishable
    # from a capacity skip without reading the error itself off a log line
    # nothing durable kept. This names the failure instead of leaving it to be
    # inferred from what is missing.
    #
    # `tier` and `oracle_digest` are the SAME two facts {OracleAnswer} carries
    # (`oracle_digest` is {Oracle::Definition#digest}, the join key
    # {Oracle::Recorded} substitutes on) -- so a reader scanning the journal for
    # one oracle's traffic finds its failures the same way it finds its answers.
    # `error_class` is the raised exception's class NAME, a String: the class
    # object itself has no canonical JSON form and holding one would make the
    # record fail `Ractor.shareable?`.
    #
    # Never read as an answer: {Oracle::Recorded.from_journal} selects
    # `oracle_answer` records only, so a journal holding this instead of an
    # {OracleAnswer} for a question still misses, loudly, through {Oracle::
    # Recorded::Unrecorded} -- replay must never invent an answer a live run
    # never produced.
    OracleFailed = Data.define(:tier, :oracle_digest, :error_class) do
      include Journalable

      def initialize(tier:, oracle_digest:, error_class:)
        tier = tier&.to_sym
        Carriers::OracleFailed.check!(tier:, oracle_digest:, error_class:)

        super(tier:, oracle_digest: oracle_digest.dup.freeze, error_class: error_class.to_s.freeze)
      end
    end
  end
end
