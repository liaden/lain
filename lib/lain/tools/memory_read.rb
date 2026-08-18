# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): reads one memory item's full body by id, over a
    # frozen {Memory::Index} snapshot injected at construction. Direct Ruby,
    # no subprocess, no model-controlled command string.
    #
    # An unknown id is reported as an error {Tool::Result}, never a raise: a
    # miss is an answer the model can act on -- the manifest it read may be
    # stale, and "no such id" is exactly what tells it so.
    #
    # == The ceiling, and why the real one is on the WRITE
    #
    # A body is a WHOLE ARTIFACT in {Tool::Bounds}' sense, exactly as a file's
    # contents are, so an oversized one is refused rather than truncated. But
    # this is the one whole-artifact tool with no narrower READ -- there is no
    # window on memory, no structural query over it, and no manifest tool to
    # fall back to -- so a ceiling here ALONE would be a dead end, and worse
    # than that it would be an asymmetry: {Tools::MemoryWrite} would accept a
    # body this tool then refused forever, which is the same read/write trap
    # `edit_file`'s partial-read refusal exists to close.
    #
    # So the pair is bounded together, and the write carries the real ceiling
    # ({Tools::MemoryWrite::BOUND}, no higher than {BOUND}), because that is
    # where the model still HOLDS the bytes and so has a genuinely narrower
    # action: write less, or split across ids. This ceiling is then
    # unreachable through the toolset and stands as an honest runaway guard for
    # an item that predates it or arrived from a seeded index -- which is why
    # {NARROWER} says what it says and no more.
    class MemoryRead < Tool
      # 256 KiB, matching {Tools::ReadFile}'s whole-read ceiling because it is
      # the same question about the same kind of payload -- a body handed back
      # entire -- and two different answers to one question would be a number
      # to remember rather than a rule to know.
      BOUND = Tool::Bounds::Artifact.new(limit: 256 * 1024)

      # Two things the model can actually do, and nothing it cannot. Neither of
      # the first draft's entries survived being followed: "read the memory
      # manifest" named a TOOL that does not exist (the manifest rides every
      # Request through {Workspace}, so it is a fact already in context, not a
      # call), and "supersede it with a smaller memory_write" was destructive
      # AND needed the very bytes the refusal withheld.
      NARROWER = [
        "the memory manifest already in your context carries this item's one-line description",
        "ask for a different id -- memory_write cannot create an item this large, so this one predates the ceiling"
      ].freeze

      # The wire shape: one required id.
      class Input < Tool::Input
        field :id, :string, description: "Id of the memory item to read, as listed in the memory manifest.",
                            required: true
      end

      input_model Input

      def initialize(index:)
        super()
        @index = index
      end

      def name = "memory_read"

      def description
        "Reads the full body of the memory item with the given id. The " \
          "memory manifest lists one id and description per item; use this " \
          "to fetch the body behind a manifest line. A body over " \
          "#{BOUND.limit} bytes is refused rather than truncated. Returns an " \
          "error result if no item has that id."
      end

      # Audited: `@index` is a frozen Memory::Index snapshot injected at
      # construction -- #fetch only walks its own frozen content-addressed
      # chain. No Session touched, no process-global state, nothing mutated.
      def parallel_safe? = true

      protected

      # Rescuing UnknownId beats a #key? pre-check, which would walk the
      # chain a second time to learn what #fetch already says.
      def perform(input, _invocation)
        body = index.fetch(input.id).body
        # `bytesize` and not `size`: the ceiling counts bytes, and a body of
        # multi-byte characters would otherwise measure short by up to 4x.
        return refusal(input.id, body.bytesize) unless BOUND.admits?(body.bytesize)

        Tool::Result.ok(body)
      rescue Memory::Index::UnknownId
        Tool::Result.error("no memory with id #{input.id.inspect}")
      end

      private

      def refusal(id, size) = BOUND.refusal(subject: "memory item #{id.inspect}", size:, narrower: NARROWER)

      attr_reader :index
    end
  end
end
