# frozen_string_literal: true

module Lain
  module CLI
    # A `#<<` adapter that fans one event onto BOTH the durable Journal record
    # and the frontend's live-view Channel, extracted from exe/lain (see
    # {Lain::CLI::Backend} for the same extraction rationale) so it carries a
    # spec the way lib/ does.
    #
    # The channel leg is the one that dies: quitting nvim closes its
    # {Channel::DropOldest} (Frontend::Neovim's own teardown contract), and a
    # closed channel's `<<` raises `ClosedQueueError`. The Journal leg must
    # always land -- it is the experiment record -- so the journal write comes
    # FIRST, and only `ClosedQueueError` from the channel leg is swallowed
    # afterward. Anything else the channel raises is a real bug and propagates,
    # so this never grows into a blanket rescue.
    class JournalTee
      def initialize(journal, channel)
        @journal = journal
        @channel = channel
      end

      def <<(event)
        @journal << event
        begin
          @channel << event
        rescue ClosedQueueError
          # The editor died and closed its channel; the record already landed
          # in the journal, and a dead view has nobody left to render it.
        end
        self
      end
    end
  end
end
