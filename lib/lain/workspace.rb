# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  # State that is SENT to the model but never STORED in the Timeline, which is
  # the whole reason Workspace exists. Todo lists, a file-staleness ledger and a
  # remaining-budget countdown must reach the model reflecting *current* truth
  # every turn; appending them as turn events would be wrong twice over -- the
  # Timeline would accrete a stale copy per turn (compounding token cost
  # forever), and rewinding would resurrect a completed todo list. So
  # {Lain::Context} renders it into the Request at the tail of the last user
  # message and it dies with the session; anything that must outlive one belongs
  # in Memory.
  #
  # Frozen and value-like, so a Context render stays pure: the same Timeline,
  # Toolset and Workspace must always produce the same Request, or dry replay is
  # worthless and the prompt cache breaks silently.
  class Workspace
    # Freeze happens once, after initialize sets @reminders (see Lain::Freezable).
    prepend Freezable
    include Inspectable

    BLOCK_TYPE = "text"

    # The tags delimit injected workspace state so a human or model reader tells
    # it apart from genuine conversation at a glance. One constant, two call
    # sites, so writer and reader cannot drift. Provenance is NOT inferred from
    # this text -- see WORKSPACE_MARKER below.
    OPENING_TAG = "<workspace>"
    CLOSING_TAG = "</workspace>"

    # The neutral, structural marker a block carries to say "I am injected
    # workspace state, not conversation" -- the same shape as
    # {Provider::AnthropicEncoding::CACHE_MARKER}: never a wire field, always
    # stripped before a payload is emitted (translate_block) or digested
    # (Request#prefix_digests). {Context::Recall}'s query-exclusion rule keys off
    # this rather than the visible tag, so genuine user text that happens to
    # start with "<workspace>" carries no such key and stays real query material.
    WORKSPACE_MARKER = "workspace"

    attr_reader :reminders

    delegate :empty?, to: :reminders

    # @param reminders [Array<String>] injected verbatim, in order
    def initialize(reminders: [])
      @reminders = Canonical.normalize(Array(reminders))
    end

    # A shared frozen instance rather than `@empty ||= new`: a class-method ivar
    # memo is not thread-safe, and every empty Workspace is value-equal anyway.
    # Defined after #initialize so `new` resolves to it. Freezable already froze
    # it; the trailing `.freeze` is a harmless restatement of intent.
    EMPTY = new.freeze

    def self.empty
      EMPTY
    end

    def with(*additional)
      # The steady state -- no live reminders -- must not cost a fresh Workspace
      # and a Canonical.normalize pass every render. A frozen, value-like
      # Workspace with nothing to add IS the result.
      return self if additional.empty?

      self.class.new(reminders: reminders + additional.flatten.map(&:to_s))
    end

    # Ordinary text blocks, tagged for a reader and carrying the structural
    # WORKSPACE_MARKER so provenance survives text a user message imitates.
    def to_blocks
      reminders.map do |reminder|
        { "type" => BLOCK_TYPE, "text" => "#{OPENING_TAG}#{reminder}#{CLOSING_TAG}", WORKSPACE_MARKER => true }
      end
    end

    # The human-facing projection; inspect keeps the class-tagged debug form --
    # the DegradedSet convention.
    def to_s
      "reminders=#{reminders.size}"
    end
  end
end

# Snapshot nests inside Workspace, so it loads after the class body -- this
# file is the workspace subtree's index (see CLAUDE.md, Requires).
require_relative "workspace/snapshot"
require_relative "workspace/on_disk"
require_relative "workspace/restore"
require_relative "workspace/revert"
require_relative "workspace/snapshot_log"
