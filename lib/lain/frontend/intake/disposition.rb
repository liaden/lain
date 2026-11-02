# frozen_string_literal: true

module Lain
  module Frontend
    class Intake
      # A perishable command is never held: held behind a run, its question is
      # gone by the time `you>` returns, and the line would answer nothing.
      Disposition = Data.define(:kind, :said) do
        # @param text [String] the line as typed
        # @param notes [#take?] posts the line as a note when it is one
        # @param commands [#perishable?, #refusal] the chat's command registry, asked about the line
        def self.of(text, notes:, commands:)
          return new(kind: :note, said: text) if notes.take?(text)
          return new(kind: :hold, said: text) unless commands.perishable?(text)

          refusal = commands.refusal(text)
          refusal ? new(kind: :refuse, said: refusal) : new(kind: :run_now, said: text)
        end
      end
    end
  end
end
