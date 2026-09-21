# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/quit`: hands the Repl its :quit action, so the conversation winds
      # down through the SAME exit a bare "quit" farewell takes -- converse's
      # loop condition fails and run's ensures fire; no second shutdown path.
      class Quit
        def initialize = freeze

        def name = "quit"

        def usage = "/quit -- end the session (same as bare quit)"

        def call(_args, _env) = :quit
      end
    end
  end
end
