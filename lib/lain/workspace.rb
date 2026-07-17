# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  # State that is SENT to the model but never STORED in the Timeline.
  #
  # This distinction is the whole reason Workspace exists. Todo lists, a
  # file-staleness ledger, and a remaining-budget countdown all have to reach the
  # model, and they have to reflect *current* truth on every turn. Appending them
  # as turn events would be wrong twice over: the Timeline would accrete a stale copy
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
    # Freeze happens once, after initialize sets @reminders (see Lain::Freezable).
    prepend Freezable

    BLOCK_TYPE = "text"

    # The tags delimit injected workspace state so a HUMAN OR MODEL reader can
    # tell it apart from genuine conversation at a glance. One constant, two
    # call sites, so the writer and reader cannot drift. Provenance itself
    # (what {Context::Recall}'s query-exclusion rule keys off) no longer
    # infers from this text -- see WORKSPACE_MARKER below (R.2, resolved).
    OPENING_TAG = "<workspace>"
    CLOSING_TAG = "</workspace>"

    # The neutral, structural marker a block carries to say "I am injected
    # workspace state, not conversation" -- exactly the same shape as
    # {Provider::AnthropicEncoding::CACHE_MARKER}: never a wire field, always
    # stripped before a payload is emitted (translate_block) or digested
    # (Request#prefix_digests). Reading provenance off this key rather than
    # off the visible tag text is what R.2 fixes: genuine user text that
    # happens to start with "<workspace>" carries no such key and is real
    # query material.
    WORKSPACE_MARKER = "workspace"

    attr_reader :reminders

    delegate :empty?, to: :reminders

    # @param reminders [Array<String>] injected verbatim, in order
    def initialize(reminders: [])
      @reminders = Canonical.normalize(Array(reminders))
    end

    # A single shared, frozen instance instead of `@empty ||= new`: an instance
    # variable memoized in a class method is not thread-safe, and every empty
    # Workspace is value-equal anyway, so one deeply frozen constant is both
    # cleaner and race-free. Defined after #initialize so `new` resolves to it.
    # (Freezable already froze it; the trailing `.freeze` is a redundant,
    # harmless statement of intent at the constant's definition.)
    EMPTY = new.freeze

    def self.empty
      EMPTY
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
    # model) can tell injected state from conversation, and carry the
    # structural WORKSPACE_MARKER so provenance survives even when the
    # visible text does not (or is imitated by a genuine user message).
    def to_blocks
      reminders.map do |reminder|
        { "type" => BLOCK_TYPE, "text" => "#{OPENING_TAG}#{reminder}#{CLOSING_TAG}", WORKSPACE_MARKER => true }
      end
    end

    # to_s is the human-facing projection; inspect keeps the class-tagged,
    # debug-oriented form -- the DegradedSet convention.
    def to_s
      "reminders=#{reminders.size}"
    end

    def inspect
      "#<Lain::Workspace #{self}>"
    end
  end
end

# Snapshot nests inside Workspace, so it loads after the class body -- this
# file is the workspace subtree's index (see CLAUDE.md, Requires).
require_relative "workspace/snapshot"
require_relative "workspace/restore"
