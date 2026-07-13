# frozen_string_literal: true

require_relative "../memory/item"
require_relative "../memory/recorder"
require_relative "../tool"

module Lain
  module Tools
    # Tier 1 (structured): writes (or overwrites) one memory item by id, via a
    # {Memory::Recorder} injected at construction. Direct Ruby, no subprocess,
    # no model-controlled command string.
    #
    # A write never destroys the item it supersedes -- the recorder's prior
    # root still resolves it via {Memory::Index#checkout} -- so this tool
    # reports the new root rather than merely "ok": that root is the caller's
    # only handle on "what was readable before this write" going forward.
    class MemoryWrite < Tool
      # The wire shape: an id to key the item, a one-line description for the
      # manifest, and the body itself. Mirrors {Memory::Item}'s fields.
      class Input < Tool::Input
        field :id, :string, description: "Id under which to store the item. Overwrites any prior item at this id.",
                            required: true
        field :description, :string,
              description: "One-line summary shown in the memory manifest.", required: true
        field :body, :string, description: "The full content to store.", required: true
      end

      input_model Input

      def initialize(recorder:)
        super()
        @recorder = recorder
      end

      def name = "memory_write"

      def description
        "Writes the memory item with the given id, description, and body. " \
          "Overwrites any existing item at that id; the prior version stays " \
          "reachable by its old root, only no longer the one resolved by " \
          "memory_read. Returns the new root alongside the id written."
      end

      protected

      # Item's own constructor is the validity check (blank/multi-line id or
      # description) -- rescuing here reports it the same way MemoryRead
      # reports an unknown id: as an error Result the model can act on, not a
      # raise that only Handler::Live would catch.
      def perform(input, _invocation)
        item = Memory::Item.new(id: input.id, description: input.description, body: input.body)
        root = recorder.write(item)
        Tool::Result.ok("wrote memory item #{item.id.inspect}; index root is now #{root}")
      rescue ArgumentError => e
        Tool::Result.error(e.message)
      end

      private

      attr_reader :recorder
    end
  end
end
