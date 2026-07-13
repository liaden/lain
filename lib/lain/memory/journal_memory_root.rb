# frozen_string_literal: true

require_relative "recorder"
require_relative "../event"

module Lain
  module Memory
    # A Journal-duck decorator: every entry is forwarded to the real Journal
    # untouched, and a {Event::TurnUsage} is additionally followed by an
    # {Event::MemoryRoot} pairing that SAME turn's digest with the recorder's
    # current root. Constructed over the real Journal and a live {Recorder},
    # then handed to the Agent AS its `journal:` -- the Agent (via
    # {Agent::Accounting}) and {Middleware::JournalRequests} call nothing on
    # their injected journal but `#<<`, so that is exactly the duck this
    # satisfies; other Journal methods (`#fileno`, `#close`, ...) are
    # deliberately not proxied because nothing on this seam calls them on the
    # Agent's journal.
    #
    # This is how the Agent stays memory-blind: it never sees {Memory::Index}
    # or {Recorder}, only a journal that happens to also remember the root
    # in force at each turn it is told about.
    #
    # Order matters: the turn_usage record is forwarded FIRST, the memory_root
    # SECOND, so a reader scanning forward sees a turn before its snapshot --
    # commit order all the way through. The root is read from the recorder at
    # the INSTANT `#<<` runs, never cached -- because {Agent::Accounting#observe}
    # journals TurnUsage inside `Agent#step` right after the assistant commit
    # and strictly BEFORE `perform_tools`, that instant's root is the
    # pre-write snapshot the render actually saw: no tool from THIS turn has
    # written yet.
    class JournalMemoryRoot
      # @param journal [#<<] the real Journal (or another Journal-duck) every
      #   entry is forwarded to
      # @param recorder [Memory::Recorder] the live holder of the current root
      def initialize(journal:, recorder:)
        @journal = journal
        @recorder = recorder
      end

      # @param entry [Hash, #to_journal]
      # @return [self]
      def record(entry)
        @journal << entry
        if entry.is_a?(Event::TurnUsage)
          @journal << Event::MemoryRoot.new(turn_digest: entry.digest, root: @recorder.root)
        end
        self
      end
      alias << record
    end
  end
end
