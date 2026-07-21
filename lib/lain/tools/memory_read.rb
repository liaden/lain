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
    class MemoryRead < Tool
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
          "to fetch the body behind a manifest line. Returns an error " \
          "result if no item has that id."
      end

      # Audited: `@index` is a frozen Memory::Index snapshot injected at
      # construction -- #fetch only walks its own frozen content-addressed
      # chain. No Session touched, no process-global state, nothing mutated.
      def parallel_safe? = true

      protected

      # Rescuing UnknownId beats a #key? pre-check, which would walk the
      # chain a second time to learn what #fetch already says.
      def perform(input, _invocation)
        Tool::Result.ok(index.fetch(input.id).body)
      rescue Memory::Index::UnknownId
        Tool::Result.error("no memory with id #{input.id.inspect}")
      end

      private

      attr_reader :index
    end
  end
end
