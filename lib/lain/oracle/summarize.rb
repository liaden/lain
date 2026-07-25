# frozen_string_literal: true

module Lain
  module Oracle
    # The eager summarizer's question: "compress this tool result into prose a
    # later reader can act on". {Oracle::Eager} fires it per large tool result
    # and holds the answer against the result's content address, so a compacting
    # turn can render the summary instead of an elision line.
    #
    # The slot is named `source` because {Eager::DEFAULT_SLOT} is, and the
    # answer field is named `summary` because {Compaction::SummarySnapshot.take}
    # reads `.summary` off it -- the two ends of the same wire, kept in one file
    # so neither can drift alone.
    #
    # The live tier DEFAULTS to a local model ({CLI::Backend::DEFAULT_SUMMARIZER_PROVIDER}
    # is ollama), because this fires once per large result, off the turn's
    # critical path, and paying frontier-model tokens to compress a tool result
    # would cost more than resending it. It is a default and not a law:
    # `--summarizer-provider` and `--summarizer-model` resolve through the same
    # PROVIDERS set `--provider` does, so the tier may be pointed at a paid
    # model -- the chat's own provider included. That is precisely why every
    # answer it gives is journalled ({Recorded::Journaling}): an unrecorded
    # model call is spend the bench cannot see.
    #
    # It is also no longer the FIRST tier tried. {Oracle::RoutedSummarizer}
    # sits above it and offers each result to the project's own declared
    # summarizers first, falling through to here when none answers.
    #
    # A tier that is absent or down is a MISS, not an error -- {Eager#fire}'s
    # task boundary contains the failure and the compaction renders the honest
    # elision instead.
    module Summarize
      SCHEMA = Class.new(Tool::Input) do
        field :summary, :string, required: true,
                                 description: "the result's content in a few sentences: what it was, what it " \
                                              "showed, and anything a later turn would need to act on"
      end

      # Deliberately says the summary REPLACES the text in a later prompt: a
      # summarizer that does not know it is writing the only surviving record
      # writes a table of contents instead of a substitute.
      TEMPLATE = <<~ERB
        A tool returned this result:

        <%= render("source") %>

        Summarize it. The summary will REPLACE this text in a later prompt, so
        state the facts a reader would otherwise have to go back to the original
        for. Do not editorialize and do not offer to help.
      ERB

      # @param tier [Symbol] folded into the Definition's digest, so a heuristic
      #   answer and a model answer to this SAME question are two different
      #   oracles at two different addresses (see {PruneScoring.definition}).
      # @return [Oracle::Definition]
      def self.definition(tier: :model)
        Definition.new(template: TEMPLATE, schema: SCHEMA, tier:)
      end
    end
  end
end
