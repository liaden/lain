# frozen_string_literal: true

module Lain
  module Memory
    # A Journal-duck decorator: every entry is forwarded to the real Journal
    # untouched, and a {Telemetry::TurnUsage} is additionally followed by a
    # {Telemetry::MemoryRoot} pairing that SAME turn's digest with the recorder's
    # current root. Handed to the Agent AS its `journal:` -- the Agent (via
    # {Agent::Accounting}) and {Middleware::JournalRequests} call nothing on
    # their injected journal but `#<<`, so that is exactly the duck this
    # satisfies; other Journal methods are deliberately not proxied, because
    # nothing on this seam calls them.
    #
    # This is how the Agent stays memory-blind: it never sees {Memory::Index} or
    # {Recorder}, only a journal that happens to also remember the root in force
    # at each turn it is told about.
    #
    # Order matters: turn_usage is forwarded FIRST and memory_root SECOND, so a
    # reader scanning forward sees a turn before its snapshot. The root is read
    # from the recorder at the INSTANT `#<<` runs, never cached -- because
    # {Agent::Accounting#observe} journals TurnUsage right after the assistant
    # commit and strictly BEFORE `perform_tools`, that instant's root is the
    # pre-write snapshot the render actually saw.
    #
    # The match is deliberately a CLASS check, not a journal_type/shape check: a
    # raw Hash with "type" => "turn_usage" -- which {Journal#record} accepts --
    # forwards untouched with NO paired memory_root. {Agent::Accounting} is the
    # only turn_usage writer today and always sends the event object; broaden the
    # match when a real second writer exists, not speculatively.
    #
    # It also writes the session's ONE {Telemetry::MemoryLoaded}, immediately
    # ahead of the first root it explains. Here rather than at each wiring site
    # because a root means nothing without the view it was taken over: every
    # construction site of this decorator -- a chat, a bench recording, an arm,
    # the consolidation clerk -- gets a self-contained record without having to
    # remember to write one, and a reader scanning forward meets the load
    # before the first snapshot of it.
    class JournalMemoryRoot
      # @param journal [#<<] the real Journal (or another Journal-duck) every
      #   entry is forwarded to
      # @param recorder [Memory::Recorder] the live holder of the current root
      def initialize(journal:, recorder:)
        @journal = journal
        @recorder = recorder
        @loaded = false
      end

      # @param entry [Hash, #to_journal]
      # @return [self]
      def record(entry)
        @journal << entry
        paired(entry) if entry.is_a?(Telemetry::TurnUsage)
        self
      end
      alias << record

      private

      def paired(entry)
        announce_load
        @journal << Telemetry::MemoryRoot.new(turn_digest: entry.digest, root: @recorder.root)
      end

      # A session with no turn at all writes nothing: there is no root to
      # explain, and a load nothing was ever rendered over is not a fact about
      # any recorded run.
      def announce_load
        return if @loaded

        @loaded = true
        @journal << Telemetry::MemoryLoaded.of(@recorder.loaded)
      end
    end
  end
end
