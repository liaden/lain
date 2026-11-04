# frozen_string_literal: true

module Lain
  module Frontend
    class Intake
      # A control command is never held: held behind a run, what it acts on is
      # gone or moot by the time `you>` returns, and the line would answer nothing.
      Disposition = Data.define(:kind, :said) do
        # @param text [String] the line as typed
        # @param notes [#take?] posts the line as a note when it is one
        # @param commands [#disposition] the chat's command registry, asked about the line
        def self.of(text, notes:, commands:)
          notes.take?(text) ? new(kind: :note, said: text) : commands.disposition(text)
        end
      end
    end
  end
end
