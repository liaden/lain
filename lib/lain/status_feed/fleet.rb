# frozen_string_literal: true

module Lain
  class StatusFeed
    # Every spawn this feed is still carrying, as the digests the HUD's `fleet`
    # segment and the `state.json` readers name. Its own object for {Inbox}'s
    # reason rather than an instance variable in the feed: a standing set with
    # an arrival side and a retirement side is a collaborator, and the feed
    # derives a dozen unrelated fields beside it.
    #
    # A Hash keyed by digest, not an Array: that is what makes a redelivered
    # `:spawn` -- a journal replay, a warm start feeding recorded history back
    # through the sinks -- a no-op update instead of a second entry. Content
    # addressing does the rest, so two separately constructed Events naming the
    # same spawn are one member, because they name one spawn.
    #
    # THE STANDING SET AND THE LIVE SET ARE SEPARATE, which is
    # {CLI::FleetWindows}'s structure and the reason a member can leave at all:
    # keying arrival on live membership would make a `:spawn` redelivered AFTER
    # its own completion resurrect a child that is gone. `@seen` is therefore
    # never pruned -- two thousand finished spawns leave two thousand entries
    # against an empty roster, which is what that rule costs, not a leak.
    #
    # The retirement is journal-derived because it can be nothing else: the
    # {StatusFeed} class doc forbids this feed asking a live registry, so "has
    # this child finished" is only ever a fact read off a record.
    class Fleet
      def initialize
        @seen = Set.new
        @members = {}
      end

      # Named for the lifecycle word the `:spawn` record already speaks, so the
      # call site reads as the event it is answering.
      #
      # @param event [#digest] the arriving `:spawn` Event
      # @return [void]
      def launched(event)
        digest = event.digest
        return if @seen.include?(digest)

        @seen << digest
        @members[digest] = true
        nil
      end

      # The other half of the same word: a `:message` that ends a spawn's
      # lifecycle takes it back out. {Telemetry::SpawnLifecycle} answers
      # whether this record is that message -- an actor's farewell and a
      # one-shot's completion say so differently, and asking is what keeps one
      # reading of a journal record rather than a copy of it per reader.
      #
      # WHICH member ended is the `causal_parents` join those records already
      # carry: an actor's farewell cites the address it took from its own
      # `:spawn` digest, a one-shot's completion cites that `:spawn` beside the
      # child's final head. EVERY cited digest is dropped rather than the first
      # one found to be a member, because `Event#normalize_causal` uniqs and
      # SORTS: "the first cited parent" is not recoverable from the list, and
      # matching once would make the retirement turn on which digest sorted
      # lower. A record citing no member drops nothing.
      #
      # @param record [#causal_parents] an arriving `:message`, in either shape
      #   the feed's `:message` arm dispatches: a raw {Event} or the
      #   {Telemetry::Message} the actor path promotes it into
      # @return [void]
      def completed(record)
        return unless Telemetry::SpawnLifecycle.new(record).terminal?

        Array(record.causal_parents).each { |cited| @members.delete(cited) }
        nil
      end

      # @return [Array<String>] what the feed publishes as `fleet`, in the
      #   order the spawns arrived
      def digests = @members.keys
    end
  end
end
