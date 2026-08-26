# frozen_string_literal: true

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
    #
    # == Why the memory ceiling lives here rather than only on the read
    #
    # A ceiling on the read ALONE would be an asymmetry with no way out: this
    # tool would accept a body its sibling then refused FOREVER, and the model
    # would be told to shorten bytes it can no longer see. Here the model still
    # holds them, so "write less" and "split across ids" are moves it can make.
    # Bounded no higher than the read's, it makes that one unreachable through
    # the toolset -- which is what lets it be the runaway guard it claims to be.
    class MemoryWrite < Tool
      # Matched to {Tools::MemoryRead::BOUND}: a write this tool accepts must
      # be a read that tool can serve, and the pair is ASSERTED rather than
      # remembered.
      BOUND = Tool::Bounds::Artifact.new(limit: 256 * 1024)

      # Both are non-destructive and available while the bytes are still in
      # hand, which is the whole reason this ceiling is on the write.
      NARROWER = [
        "write less -- keep the body to what a later read actually needs",
        "split it across several ids, one subject each, so the manifest can point at the right one"
      ].freeze

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
          "memory_read. A body over #{BOUND.limit} bytes is refused rather " \
          "than stored, because memory_read could not hand it back. Returns " \
          "the new root alongside the id written."
      end

      protected

      # Blank fields never get here -- `required: true` rejects them in
      # #validate_input!. The one {Memory::Item} rejection that reaches this
      # rescue is a multi-line id or description, reported as an error Result
      # the model can act on rather than a raise.
      def perform(input, _invocation)
        refusal = too_large(input)
        return refusal if refusal

        item = Memory::Item.new(id: input.id, description: input.description, body: input.body)
        root = recorder.write(item)
        Tool::Result.ok("wrote memory item #{item.id.inspect}; index root is now #{root}")
      rescue ArgumentError => e
        Tool::Result.error(e.message)
      end

      private

      # Asked BEFORE {Memory::Item}, so an oversized body is never hashed and
      # never reaches the store: the refusal costs a `bytesize`, and nothing it
      # refuses is recorded.
      def too_large(input)
        size = input.body.bytesize
        return nil if BOUND.admits?(size)

        BOUND.refusal(subject: "the body for memory item #{input.id.inspect}", size:, narrower: NARROWER)
      end

      attr_reader :recorder
    end
  end
end
