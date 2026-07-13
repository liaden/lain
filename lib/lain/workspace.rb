# frozen_string_literal: true

module Lain
  # State that is SENT to the model but never STORED in the Timeline.
  #
  # This distinction is the whole reason Workspace exists. Todo lists, a
  # file-staleness ledger, and a remaining-budget countdown all have to reach the
  # model, and they have to reflect *current* truth on every turn. Appending them
  # as Turns would be wrong twice over: the Timeline would accrete a stale copy
  # per turn (compounding token cost forever), and rewinding would resurrect a
  # todo list that has since been completed.
  #
  # So the Workspace is rendered into the Request by {Lain::Context}, at the tail
  # of the last user message, and is never appended to the Timeline. It dies with
  # the session. Anything that must outlive the session belongs in Memory.
  #
  # Frozen and value-like, so a Context render stays pure: the same Timeline,
  # Toolset, and Workspace must always produce the same Request, or dry replay is
  # worthless and the prompt cache breaks silently.
  class Workspace
    BLOCK_TYPE = "text"

    # Shared with Context::Recall, whose query-exclusion rule must match
    # exactly what #to_blocks injects: one constant, two call sites, so the
    # tag cannot drift between the writer and the reader.
    OPENING_TAG = "<workspace>"
    CLOSING_TAG = "</workspace>"

    attr_reader :reminders

    def self.empty
      @empty ||= new
    end

    # @param reminders [Array<String>] injected verbatim, in order
    def initialize(reminders: [])
      @reminders = Canonical.normalize(Array(reminders))
      freeze
    end

    def empty?
      reminders.empty?
    end

    def with(*additional)
      # The steady state -- no live reminders -- must not allocate a fresh
      # Workspace (and a Canonical.normalize pass) every render. A frozen,
      # value-like Workspace with nothing to add IS the result, so returning
      # self is safe and keeps the common render path allocation-free.
      return self if additional.empty?

      self.class.new(reminders: reminders + additional.flatten.map(&:to_s))
    end

    # Rendered as ordinary text blocks. They are tagged so a reader (human or
    # model) can tell injected state from conversation, and so a future Context
    # can strip them back out when re-rendering under a different strategy.
    def to_blocks
      reminders.map do |reminder|
        { "type" => BLOCK_TYPE, "text" => "#{OPENING_TAG}#{reminder}#{CLOSING_TAG}" }
      end
    end

    def to_s
      "#<Lain::Workspace reminders=#{reminders.size}>"
    end
    alias inspect to_s
  end
end
