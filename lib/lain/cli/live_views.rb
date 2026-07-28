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
      # A `push`-shaped fan-out of one attributed event onto the run's TTY
      # Channel and every attached live view. NOT {JournalTee}, for two
      # reasons. First the duck: {Sink::IOAdapter#emit} calls `push`, and
      # {Lain::Channel} aliases `<<` TO push, not the reverse -- a tee dropped
      # in here would raise NoMethodError on the first byte of tool output.
      # Second the destination: a tee's first leg is the durable record, and
      # streamed tool bytes are a VIEW. Their durable copy already rides the
      # turn's tool_result ({Tools::Bash.render_output}), so journalling them
      # again would double the session file for no new fact.
      #
      # What IS copied from the tee is its two-part failure discipline, and
      # BOTH halves matter:
      #
      # * The legs are not equals. A view leg MAY simply be gone -- quitting
      #   nvim closes its Channel -- so its ClosedQueueError is swallowed,
      #   because a dead viewer must never break a running tool. The TTY leg
      #   is the one that must land, so ITS ClosedQueueError propagates. That
      #   asymmetry is the whole point: a chat with no editor gets a bare
      #   Channel back from {LiveViews.tool_output}, where a closed queue
      #   raises and {Effect::Handler::Live}'s gate 3 turns it into an
      #   is_error tool_result. Swallowing it here would give one failure two
      #   behaviours depending on an unrelated flag, and the --nvim one would
      #   be the dishonest one: a tool reporting success with nobody watching.
      # * Every leg still gets its turn, whichever one is sick, because leg
      #   order must not decide who receives an event -- the review probe that
      #   grew {JournalTee}'s own fan-out found exactly that. So a failure is
      #   RETURNED, never raised in place, and only once the whole fan-out has
      #   run does it surface: one failing leg raises its own error unchanged,
      #   several raise {JournalTee::SinkFailures}, which names them all.
      #
      # There is deliberately NO lock across the legs. Per-`tool_use_id` order
      # is preserved (one stream is written by one thread) and every event is
      # attributed, but the GLOBAL interleave of two concurrent
      # `parallel_safe?` tools may differ between the TTY and the editor: the
      # two views are not promised to be byte-identical transcripts of each
      # other. A mutex would buy that promise by serializing the editor's
      # non-blocking push behind the TTY's blocking one, which is exactly the
      # coupling {Channel::DropOldest} exists to avoid.
      class Fanout
        def initialize(tty, *views)
          @tty = tty
          @views = views
        end

        def push(event)
          failures = [tty_failure(event), *@views.map { |view| view_failure(view, event) }].compact
          raise_named(failures) unless failures.empty?

          self
        end
        alias << push

        private

        # @return [StandardError, nil] the TTY leg's failure -- returned
        #   rather than raised so the views still get the event, but never
        #   swallowed: this leg is the one the human is watching.
        def tty_failure(event)
          @tty.push(event)
          nil
        rescue StandardError => e
          e
        end

        # @return [StandardError, nil] a view leg's failure, with a closed
        #   queue answering nil: the consumer quit, and a dead consumer has
        #   nobody left to receive the event.
        def view_failure(view, event)
          view.push(event)
          nil
        rescue ClosedQueueError
          nil
        rescue StandardError => e
          e
        end

        def raise_named(failures)
          raise failures.first if failures.one?

          raise JournalTee::SinkFailures, failures
        end
      end

      # Where the tool executor ({Effect::Handler::Live}) streams its bytes:
      # the run's TTY Channel, joined by the editor's when one is attached, so
      # nvim's lain://journal sees what the terminal sees. `views` is this
      # class's own {#views} hash, read back here because the shape is its own
      # -- Wiring only asks for the destination. The bare channel comes back
      # when no editor is attached, so a plain chat allocates and crosses
      # nothing extra -- and, because {Fanout} never swallows the TTY leg's
      # failure, the two branches degrade identically.
      def self.tool_output(channel, views)
        views ? Fanout.new(channel, views.fetch(:channel)) : channel
      end

      # `status_feed:` is REQUIRED, not defaulted: a caller that forgets it
      # would silently get an event-blind /status (the T9 panel's exact trap).
      # ChatLaunch constructs the ONE feed and threads it here AND into Wiring,
      # so the tee's sink and the command's reader are the same live instance.
      def initialize(options:, chronicle:, status_feed:)
        @options = options
        @channel = Lain::Channel::DropOldest.new if options[:nvim]
        # The FleetWindows sink is built BEFORE the tee (it goes IN it), then
        # pointed AT the tee's own journal so its capped-overflow notice lands
        # on the same record stream -- Null under no --windows, so no window
        # machinery constructs unless the flag is set (and $TMUX present).
        @fleet = FleetWindows.for(options)
        @journal = chronicle.wrap_tee(sink([@channel, status_feed, @fleet].compact))
        @fleet.notice = @journal
      end

      attr_reader :journal, :fleet

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
