# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): appends one {Improvement} note to the cross-project
    # sink via an injected {Improvement::Sink}. Direct Ruby, no subprocess, no
    # model-controlled command string -- the same shape as {Tools::MemoryWrite}.
    #
    # `sink` already knows WHERE the file lives ({Paths#improvements_path}) and
    # WHO is writing (`project_hash`/`session`); the model only supplies WHAT
    # (`note`/`kind`/`evidence_digests`). This is a note about lain ITSELF, for
    # lain's own maintainers -- distinct from {Tools::MemoryWrite}, which is
    # user-facing recall.
    class ImprovementWrite < Tool
      # `evidence_digests` is a comma-separated String, not a JSON array:
      # {Tool::Input}'s field DSL has no array type today (see JSON_TYPES in
      # tool/input.rb), and adding one is out of this card's scope -- a
      # shared file no other card in this wave touches. Comma-separated
      # keeps the schema and validation in the one declarative place the
      # house style asks for.
      class Input < Tool::Input
        field :note, :string,
              description: "The improvement note itself: a knob lain's user could turn, a bug, a missing " \
                           "feature, or a doc gap noticed about lain while working. For lain's own " \
                           "maintainers, not the user-facing memory memory_write serves.",
              required: true
        field :kind, :string, description: "One of: #{Improvement::KINDS.join(", ")}.", required: true
        field :evidence_digests, :string,
              description: "Comma-separated content digests (e.g. turn or request digests) backing this " \
                           "note. Leave empty if none."

        validates :kind, inclusion: { in: Improvement::KINDS, message: "must be one of #{Improvement::KINDS.inspect}, got %<value>s" }
      end

      input_model Input

      def initialize(sink:)
        super()
        @sink = sink
      end

      def name = "improvement_write"

      def description
        "Records one durable note about lain itself -- a knob, bug, missing-feature, or doc gap -- for " \
          "lain's own maintainers to review later. Never for user-facing recall; use memory_write for that."
      end

      protected

      def perform(input, _invocation)
        record = sink.append(note: input.note, kind: input.kind, evidence_digests: digests_from(input.evidence_digests))
        Tool::Result.ok("recorded #{record.kind} improvement for project #{record.project_hash} " \
                        "(#{record.evidence_digests.size} evidence digest(s))")
      rescue ArgumentError => e
        Tool::Result.error(e.message)
      end

      private

      attr_reader :sink

      def digests_from(raw)
        raw.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
