# frozen_string_literal: true

module Lain
  class StatusFeed
    # Every DISTINCT `:spawn` this feed has carried, as the digests the HUD's
    # `fleet` segment and the `state.json` readers name. Its own object for
    # {Inbox}'s reason rather than an instance variable in the feed: a standing
    # set that is added to and asked what it holds is a collaborator, and the
    # feed derives a dozen unrelated fields beside it.
    #
    # A Hash keyed by digest, not an Array: that is what makes a redelivered
    # `:spawn` -- a journal replay, a warm start feeding recorded history back
    # through the sinks -- a no-op update instead of a second entry. Content
    # addressing does the rest, so two separately constructed Events naming the
    # same spawn are one member, because they name one spawn.
    #
    # ⚠️ THERE IS AN ARRIVAL SIDE AND NO RETIREMENT SIDE. A child launched is
    # named here for the rest of the run whether or not it has finished. The
    # feed may not ask a live registry (the {StatusFeed} class doc holds that
    # rule), so a departure has to be derived from a journaled record, and no
    # such derivation exists yet.
    class Fleet
      def initialize
        @members = {}
      end

      # Named for the lifecycle word the `:spawn` record already speaks, so the
      # call site reads as the event it is answering.
      #
      # @param event [#digest] the arriving `:spawn` Event
      # @return [void]
      def launched(event)
        @members[event.digest] = true
        nil
      end

      # @return [Array<String>] what the feed publishes as `fleet`, in the
      #   order the spawns arrived
      def digests = @members.keys
    end
  end
end
