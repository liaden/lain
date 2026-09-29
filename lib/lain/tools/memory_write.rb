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
      # No higher than {Tools::MemoryRead::BOUND}: a write this tool accepts
      # must be a read that tool can serve, and the pair is ASSERTED rather than
      # remembered.
      BOUND = Tool::Bounds::Artifact.new(limit: Tool::Bounds::CEILINGS.fetch("memory_write"))

      # The id and the description render into the manifest every Request
      # carries, one line per item, so each is bounded at a line's worth rather
      # than at a result's.
      ID_BOUND = Tool::Bounds::Artifact.new(limit: 128)
      DESCRIPTION_BOUND = Tool::Bounds::Artifact.new(limit: 512)

      # Both are non-destructive and available while the bytes are still in
      # hand, which is the whole reason this ceiling is on the write.
      NARROWER = [
        "write less -- keep the body to what a later read actually needs",
        "split it across several ids, one subject each, so the manifest can point at the right one"
      ].freeze

      # A manifest line has nowhere narrower to go than shorter.
      ID_NARROWER = ["use a shorter id -- a few words naming the subject"].freeze
      DESCRIPTION_NARROWER = ["shorten it to one short line -- the body is where the detail belongs"].freeze

      # The wire shape: an id to key the item, a one-line description for the
      # manifest, and the body itself. Mirrors {Memory::Item}'s fields.
      class Input < Tool::Input
        field :id, :string, description: "Id under which to store the item, at most #{ID_BOUND.limit} bytes. " \
                                         "Replaces an earlier item at this id unless another author owns it.",
                            required: true
        field :description, :string,
              description: "One-line summary shown in the memory manifest, at most #{DESCRIPTION_BOUND.limit} bytes.",
              required: true
        field :body, :string, description: "The full content to store.", required: true
      end

      input_model Input

      # @param recorder [Memory::Recorder] where the item is written
      # @param author [Memory::Author] stamped on every write; lain's to set,
      #   so the model has no field for it
      def initialize(recorder:, author:)
        super()
        @recorder = recorder
        @author = author
      end

      def name = "memory_write"

      def description
        "Writes the memory item with the given id, description, and body. " \
          "Replaces an existing item at that id, unless another author owns it " \
          "and the write is refused; the prior version stays " \
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
        refusal = oversized(input)
        return refusal if refusal

        item = Memory::Item.new(id: input.id, description: input.description, body: input.body, author:)
        root = recorder.write(item)
        Tool::Result.ok("wrote memory item #{item.id.inspect}; index root is now #{root}")
      rescue ArgumentError, Memory::Ownership::Refused => e
        Tool::Result.error(e.message)
      end

      private

      # Asked BEFORE {Memory::Item}, so nothing oversized is ever hashed or
      # reaches the store: each refusal costs a `bytesize`. The id is judged
      # first because the body's refusal names it.
      def oversized(input)
        refusal(ID_BOUND, input.id, ID_NARROWER) { "the id" } ||
          refusal(DESCRIPTION_BOUND, input.description, DESCRIPTION_NARROWER) { "the description" } ||
          refusal(BOUND, input.body, NARROWER) { "the body for memory item #{input.id.inspect}" }
      end

      # The subject is a block because the body's names the id, and an id that
      # was itself refused is not worth building a sentence around.
      def refusal(bound, text, narrower)
        bound.refusal(subject: yield, size: text.bytesize, narrower:) unless bound.admits?(text.bytesize)
      end

      attr_reader :recorder, :author
    end
  end
end
