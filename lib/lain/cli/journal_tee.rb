# frozen_string_literal: true

module Lain
  module CLI
    # A `#<<` adapter that fans one event onto the durable Journal record and
    # any number of live-view sinks (the frontend's Channel, {StatusFeed}, ...).
    #
    # A live-view sink is the one that dies: quitting nvim closes its
    # {Channel::DropOldest} (Frontend::Neovim's own teardown contract), and a
    # closed channel's `<<` raises `ClosedQueueError`. The Journal leg must
    # always land -- it is the experiment record -- so the journal write comes
    # FIRST, and only `ClosedQueueError` from a SINK's `<<` is swallowed,
    # per sink.
    #
    # EVERY sink is attempted, regardless of what an earlier one did: sink
    # order must not decide who receives an event. A review probe caught the
    # first N-sink cut getting this wrong -- `@sinks.each { tell }` let a
    # raise from sink 2 abort the `each`, so sink 3 (which might be the
    # Channel the AC's own wording names as a leg that "still completes")
    # silently never saw the event at all. So a non-ClosedQueueError failure
    # is now CAPTURED, not raised in place, and every remaining sink still
    # gets its turn; only once the whole fan-out has run does the failure (or
    # failures) surface. A single failing sink raises ITS OWN error, class and
    # message unchanged -- "named", not wrapped -- so an existing `rescue
    # SpecificError` at a call site is undisturbed by the common case; more
    # than one failing sink raises {SinkFailures}, which names all of them.
    class JournalTee
      # Marks a failure raised AFTER the durable leg landed: the record is in
      # the session file, and only a live view missed it. A mixin rather than a
      # wrapping class, so the sink's own error keeps its class and message for
      # every existing `rescue`, while a caller whose commit IS the record --
      # a mode or policy flip -- can still tell it from a durable write that
      # never happened.
      module Recorded; end

      # Runs the block and answers the {Recorded} failure it raised, or nil. Any
      # other raise -- the durable write's own -- goes straight through.
      #
      # @return [Recorded, nil]
      def self.landed
        yield
        nil
      rescue Recorded => e
        e
      end

      # More than one sink failed on the same event. `#failures` is the
      # ordered Array of the original exceptions (one per failing sink, in
      # sink order) -- available for a caller that wants to inspect each one
      # individually rather than parse the joined message.
      class SinkFailures < Error
        attr_reader :failures

        def initialize(failures)
          @failures = failures
          summary = failures.map { |error| "#{error.class}: #{error.message}" }.join("; ")
          super("#{failures.size} sinks raised: #{summary}")
        end
      end

      def initialize(journal, *sinks)
        @journal = journal
        @sinks = sinks
      end

      def <<(event)
        @journal << event
        failures = @sinks.filter_map { |sink| tell(sink, event) }
        raise_named(failures) unless failures.empty?

        self
      end

      # The Journal's own two spellings, because under `--no-journal --nvim`
      # this tee IS the run's record journal, and every switch and driver
      # writes through `#record`.
      alias record <<

      private

      # @return [StandardError, nil] the sink's own failure (other than a
      #   closed queue), so the caller can collect one per sink and decide
      #   what "named" means once every sink has had its turn -- never raised
      #   from here, which is what keeps one sink's trouble from costing the
      #   sinks after it their event.
      def tell(sink, event)
        sink << event
        nil
      rescue ClosedQueueError
        # The consumer died and closed its queue; the record already landed
        # in the journal, and a dead consumer has nobody left to receive it.
        nil
      rescue StandardError => e
        e
      end

      # A frozen error cannot take the mark, and the FrozenError that would
      # escape instead reads as a durable failure. Its dup keeps the class,
      # message, backtrace and cause.
      def raise_named(failures)
        error = failures.one? ? failures.first : SinkFailures.new(failures)
        error = error.dup if error.frozen?
        raise error.extend(Recorded)
      end
    end
  end
end
