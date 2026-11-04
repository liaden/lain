# frozen_string_literal: true

module Lain
  module Tools
    # One issue of an epic as an implementer will be handed it: the authored
    # file plus the header, scenarios and links lain renders around it. The
    # text is the one {CLI::Epic#show} prints for `issues/ID`.
    #
    # It asks no approval: it reads the epic's documents and writes nothing.
    class EpicShow < Tool
      # An issue file is authored text of any length, so it is cut by whole lines.
      BOUND = Tool::Bounds::Fill.new(limit: Tool::Bounds::CEILINGS.fetch("epic_show"), unit: "lines",
                                     narrower: ["read the issue file's remainder with read_file"])

      # The issue to read and, optionally, the epic it is in.
      class Input < Tool::Input
        field :id, :string, required: true, description: "The issue's id, for example store-crate."
        field :slug, :string,
              description: "The epic's slug: #{Epic::Home::NAME_RULE}. Omit it when the project has one epic."
      end

      input_model Input

      # @param homes [#epics, #for, #root] the {CLI::Epic} verbs for this chat, and the homes and root a cut
      #   view's notice names the issue file through
      def initialize(homes:)
        super()
        @homes = homes
      end

      def name = "epic_show"

      def description
        "Shows an epic's issue as the implementer will read it: the issue file with the header, " \
          "acceptance criteria and links lain renders around it."
      end

      protected

      def perform(input, _invocation)
        Tool::Result.ok(bounded(@homes.epics.show("issues/#{input.id}", input.slug), input))
      rescue Lain::Error, SystemCallError => e
        Tool::Result.error(e.message)
      end

      private

      def bounded(view, input)
        return view if BOUND.admits?(view.bytesize)

        notice = "read the rest of #{issue_path(input)} with read_file"
        Tool::Bounds::Fill.new(limit: BOUND.limit, unit: BOUND.unit, narrower: [notice])
                          .fit(view.lines(chomp: true)).join("\n")
      end

      # Relative to the project root so read_file follows it; a home outside the
      # root has no such path and is named absolutely.
      def issue_path(input)
        slug = @homes.epics.resolve_slug(input.slug, remedy: CLI::Epic::BY_SLUG)
        path = Pathname(@homes.for(slug).issue(input.id).path)
        path.to_s.start_with?("#{@homes.root}/") ? path.relative_path_from(@homes.root).to_s : path.to_s
      end
    end
  end
end
