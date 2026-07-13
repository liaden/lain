# frozen_string_literal: true

module Lain
  class Ledger
    # A Journal's `turn_usage` records, folded into `digest => payments` so the
    # Ledger can join spend onto the turns a Timeline walk reaches. One {Entry}
    # per RECORD: the digest is a JOIN KEY onto content, NOT a key that
    # identifies a payment (see {Event::TurnUsage}).
    #
    # Deeply frozen at construction; an Index is a value derived from the
    # Journal, and `Ractor.shareable?` is the project's mechanical proof of that.
    class Index
      # One payment: the tokens bought and the model they were bought from
      # (nil when the provider reported none -- a bare mock).
      Entry = Data.define(:usage, :model) do
        def self.from_record(record)
          usage = record["usage"]
          if usage.nil?
            raise ArgumentError,
                  "turn_usage record #{record["digest"].inspect} carries no usage; " \
                  "a corrupt payment record must not price as free"
          end

          new(usage: Usage.new(**usage.transform_keys(&:to_sym)), model: record["model"])
        end

        def initialize(usage:, model:)
          super(usage: usage, model: model&.to_s&.freeze)
        end
      end

      # Fold journal entries -- the {Journal.records} duck: parsed Hashes or raw
      # NDJSON line Strings -- keeping only `turn_usage` records.
      #
      # @param entries [Enumerable<Hash, String>]
      # @return [Index]
      def self.from_journal(entries)
        records = Journal.records(entries, type: "turn_usage")
        new(entries: records.group_by { |record| record["digest"].to_s }
                            .transform_values { |group| group.map { |record| Entry.from_record(record) } })
      end

      EMPTY = [].freeze

      # @param entries [Hash{String=>Array<Entry>}] digest => one Entry per payment
      def initialize(entries:)
        @entries = entries.to_h { |digest, payments| [-digest.to_s, payments.freeze] }.freeze
        freeze
      end

      # Every payment recorded against `digest`, in journal order; empty for a
      # digest the Journal never priced (user turns, un-instrumented runs).
      #
      # @param digest [String]
      # @return [Array<Entry>]
      def entries_for(digest)
        @entries.fetch(digest, EMPTY)
      end
    end
  end
end
