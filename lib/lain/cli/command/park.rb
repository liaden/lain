# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/park text`: leave a re-entry note in the session record, which a
      # resume prints first, and tell the feed and the herdr pane. Zero model
      # turns; no text clears the note and the pane's token.
      class Park
        TOKEN = "lain_parked"

        # @param root [String] the project root, whose basename titles the feed entry
        # @param notes [#puts] where a failing feed is named
        # @param env [#[]] searched for `notify-feed` when no feed is handed in
        # @param feed [#call] takes source, title and body ({Notices::Feed})
        def initialize(root:, notes:, env: ENV, feed: Notices.for(env:, notes:))
          @title = File.basename(root.to_s)
          @feed = feed
          freeze
        end

        def name = "park"

        def usage = "/park text -- leave a note for when you return; no text clears it"

        def call(args, env)
          text = env.reporter.mask.call(args.to_s.strip)
          env.agent.session.record_reentry_note(text)
          text.empty? ? clear(env) : announce(text, env)
        end

        private

        def announce(text, env)
          @feed.call("lain", @title, "parked: #{text}")
          env.reporter.metadata(TOKEN, text)
          "noted: #{text}"
        end

        def clear(env)
          env.reporter.metadata(TOKEN, nil)
          "cleared the re-entry note"
        end
      end
    end
  end
end
