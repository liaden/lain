# frozen_string_literal: true

module Lain
  module Compaction
    class DerivationAudit
      # One journalled `context_derived` record, read through one place.
      # Everything in {DerivationAudit} asks THIS for a field, so no string key
      # is written twice and the shape check sits beside the readers it
      # protects.
      #
      # It reads the RE-DERIVED edge too ({.of}), which is what makes the
      # window comparison apples to apples: one value type, one set of readers,
      # for a record off the journal and for one a derivation just wrote.
      Edge = Data.define(:record) do
        # The edge a re-derivation writes for itself, read as the same value a
        # recorded one is.
        def self.of(journalled) = new(record: journalled.to_journal)

        def strategy = interned(record["strategy"])
        def source_head = interned(record["source_head"])
        def derived_head = interned(record["derived_head"])
        def cut = record["cut"].to_s
        def spans = Canonical.normalize(record["spans"] || [])
        def offered? = cut == OFFERED

        # Defaulted, never fetched: {Telemetry::ContextDerived} defaults it to 0
        # and always writes it, so a record without one meant 0.
        def moved = record.fetch("moved", 0)

        # Both heads absent is the empty derivation, and the ONE shape in which
        # two matching heads must not be read as agreement.
        def vacuous? = record["source_head"].nil? && record["derived_head"].nil?

        def complete? = violations.empty?

        # The record type's own WRITE-side guard, plus the two things it cannot
        # see: that the keys are there at all, and that the heads are heads.
        # Reusing the guard is what keeps a reader's idea of the shape from
        # drifting from the writer's -- there is one definition of what a
        # `context_derived` record is, and this is it.
        def violations = absent + misshapen + guarded

        private

        def absent = REQUIRED.reject { |key| record.key?(key) }.map { |key| "no #{key}" }

        # A head is a digest or it is nothing; `""` is neither. And a derivation
        # over an absent source cannot have produced a named chain, so that pair
        # is a contradiction rather than a disagreement. REFUSED rather than
        # accused: no derivation could have written either shape, so re-deriving
        # against one and reporting a drift would blame the strategy for bytes
        # nothing in `lib/` emits.
        def misshapen = blank_heads + orphaned

        def blank_heads
          HEADS.select { |key| record.key?(key) && !record[key].nil? && !digest?(record[key]) }
               .map { |key| "#{key} is #{record[key].inspect}, which is not a digest" }
        end

        def digest?(value) = value.is_a?(String) && !value.strip.empty?

        def orphaned
          return [] unless record["source_head"].nil? && !record["derived_head"].nil?

          ["#{record["derived_head"].inspect} is named as derived from no source head at all"]
        end

        # The guard is a throwaway {Lain::Guard} carrier, asked with `valid?`
        # rather than `check!`: a reader reports what is wrong with a record it
        # did not write, and never raises over it.
        def guarded
          guard = Telemetry::Guards::ContextDerived.new(strategy: record["strategy"], spans: record["spans"],
                                                        cut: record["cut"]&.to_s&.to_sym)
          guard.valid? ? [] : guard.errors.full_messages
        end

        # Interned on the way out: a digest read off the Journal is a fresh
        # MUTABLE String, and a finding holding one is not `Ractor.shareable?`
        # -- the project's mechanical statement of "no reachable mutable state".
        def interned(value) = value.nil? ? nil : -value.to_s
      end
      private_constant :Edge
    end
  end
end
