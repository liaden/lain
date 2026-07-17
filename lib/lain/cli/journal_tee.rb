# frozen_string_literal: true

module Lain
  module CLI
    # A `#<<` adapter that fans one event onto the durable Journal record and
    # any number of live-view sinks (the frontend's Channel, {StatusFeed}, ...),
    # extracted from exe/lain (see {Lain::CLI::Backend} for the same extraction
    # rationale) so it carries a spec the way lib/ does. Started as a fixed
    # journal+channel pair; generalized to 1->N sinks once {StatusFeed} needed
    # the same fan-out with the same swallow discipline, rather than a second,
    # near-duplicate tee class.
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

      def raise_named(failures)
        raise failures.first if failures.one?

        raise SinkFailures, failures
      end
    end
  end
end
