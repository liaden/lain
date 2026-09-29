# frozen_string_literal: true

module Lain
  module Oracle
    module Handoff
      # The state a handoff carries, as fields, and the one place its rendered
      # shape is written ({#to_s}). Nothing reads a rendered document back into
      # fields: the next handoff carries the recorded text whole, so a document
      # an older writer produced is never lost to a parser that disliked it.
      Document = Data.define(:goal, :progress, :files_and_decisions, :open_todos, :next_step) do
        # @param answer [Hash{String=>String}] the oracle's JSON, keyed by {HEADINGS}
        # @return [Document]
        def self.from_answer(answer) = new(**answer.slice(*HEADINGS.keys).transform_keys(&:to_sym))

        # @return [String] what {Handoff.document} records as the replacement
        def to_s
          [PREAMBLE, *HEADINGS.map { |field, heading| "## #{heading}\n\n#{public_send(field)}" }].join("\n\n")
        end
      end
    end
  end
end
