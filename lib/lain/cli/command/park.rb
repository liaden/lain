# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/park text`: leave a re-entry note in the session record, which a
      # resume prints first. Zero model turns; no text clears the note.
      class Park
        def initialize = freeze

        def name = "park"

        def usage = "/park text -- leave a note for when you return; no text clears it"

        def call(args, env)
          text = args.to_s.strip
          env.agent.session.record_reentry_note(text)
          text.empty? ? "cleared the re-entry note" : "noted: #{text}"
        end
      end
    end
  end
end
