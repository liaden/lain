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
    # A body is a WHOLE ARTIFACT in {Tool::Bounds}' sense, so an oversized one
    # is refused rather than truncated. But this is the one whole-artifact tool
    # with NO narrower read -- no window on memory, no structural query, no
    # manifest tool -- so a ceiling here alone would be a dead end, and an
    # asymmetry besides: {Tools::MemoryWrite} would accept a body this tool then
    # refused forever, the same read/write trap `edit_file`'s partial-read
    # refusal exists to close.
    #
    # So the pair is bounded together and the WRITE carries the real ceiling,
    # because that is where the model still HOLDS the bytes and has a genuinely
    # narrower action. This ceiling is then unreachable through the toolset and
    # stands as a runaway guard for an item that predates it or arrived from a
    # seeded index -- which is why {NARROWER} says what it says and no more.
    class MemoryRead < Tool
      BOUND = Tool::Bounds::Artifact.new(limit: Tool::Bounds::CEILINGS.fetch("memory_read"))

      # Two things the model can ACTUALLY do. Neither of the first draft's
      # entries survived being followed: "read the memory manifest" named a tool
      # that does not exist -- the manifest rides every Request, so it is a fact
      # already in context -- and "supersede it with a smaller memory_write" was
      # destructive AND needed the very bytes the refusal withheld.
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

      # Audited: `@index` is a frozen Memory::Index snapshot, and #fetch only
      # walks its own frozen content-addressed chain. No Session touched, no
      # process-global state, nothing mutated.
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
