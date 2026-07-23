# frozen_string_literal: true

module Lain
  module CLI
    # The live-view tee, lifted out of the Thor class the way Wiring was (the
    # Metrics trip said so: extract, do not loosen): telemetry, spawn, and Q/A
    # message records fan onto the session journal (durable, first) and every
    # live-view sink. I1's StatusFeed is always a sink so `.lain/state.json`
    # publishes for the tmux HUD (the primary renderer -- `lain up`'s chat
    # window carries no --nvim); the nvim Channel joins it when an editor is
    # attached.
    #
    # --nvim: the editor may drop view events but never block the agent; the
    # NDJSON record sees everything. The frontend's own journal: is the RAW
    # Journal, not the tee -- a resend is recorded once, never re-fanned onto
    # the views (the frontend pushes the resent event there itself). The tee
    # itself is Lain::CLI::JournalTee -- quitting nvim closes the Channel, and
    # the tee survives the resulting ClosedQueueError so the journal leg keeps
    # landing.
    #
    # #wrap_tee shares the CHRONICLE's own journal (built in #open_chronicle,
    # which runs first) rather than opening a second one: the old order opened
    # nvim's journal here, then open_chronicle opened its OWN journal
    # microseconds later, and when the two `Journal.open` calls straddled a
    # second tick they named different files -- telemetry silently split from
    # the session record it belonged in. Chronicle::Null#wrap_tee preserves the
    # OLD behavior for --no-journal + --nvim, where there is no session journal
    # to share.
    class LiveViews
      # `status_feed:` is REQUIRED, not defaulted: a caller that forgets it
      # would silently get an event-blind /status (the T9 panel's exact trap).
      # ChatLaunch constructs the ONE feed and threads it here AND into Wiring,
      # so the tee's sink and the command's reader are the same live instance.
      def initialize(options:, chronicle:, status_feed:)
        @options = options
        @channel = Lain::Channel::DropOldest.new if options[:nvim]
        @journal = chronicle.wrap_tee(sink([@channel, status_feed].compact))
      end

      attr_reader :journal

      # The --nvim wiring bits the Repl builds its Neovim frontend from, or nil.
      def views
        @channel && { channel: @channel, socket_path: @options[:nvim], journal: @journal }
      end

      private

      # One sink passes straight through; several fold into a Null-journal
      # JournalTee (a pure fan-out that swallows a closed nvim Channel per sink,
      # so the state feed still lands) before wrap_tee's single slot.
      def sink(sinks)
        sinks.one? ? sinks.first : Lain::CLI::JournalTee.new(Lain::Channel::Null.instance, *sinks)
      end
    end
  end
end
