# frozen_string_literal: true

module Lain
  module Tools
    # Where an epic stands: its stage, its waves with their issue ids, and the
    # state of each gate, so a skill reads the numbering `epic_submit` takes
    # without a shell. The text is the one {CLI::Epic#status} prints.
    #
    # It asks no approval: it reads the fold of the epic's records and writes nothing.
    class EpicStatus < Tool
      # The report grows with the epic's issues, so it is cut by whole lines.
      BOUND = Tool::Bounds::Fill.new(limit: Tool::Bounds::CEILINGS.fetch("epic_status"), unit: "lines",
                                     narrower: ["read one issue at a time with epic_show"])

      # The epic to read, which may be left out when the project has one.
      class Input < Tool::Input
        field :slug, :string,
              description: "The epic's slug: #{Epic::Home::NAME_RULE}. Omit it when the project has one epic."
      end

      input_model Input

      # @param homes [#epics] answers `epics` with the {CLI::Epic} verbs for this chat
      def initialize(homes:)
        super()
        @homes = homes
      end

      def name = "epic_status"

      def description
        "Reports where an epic stands: its stage, its waves with their issue ids, and each gate's state. " \
          "Read it for the wave numbers epic_submit takes."
      end

      protected

      def perform(input, _invocation)
        Tool::Result.ok(bounded(@homes.epics.status(input.slug)))
      rescue Lain::Error, SystemCallError => e
        Tool::Result.error(e.message)
      end

      private

      def bounded(report) = BOUND.admits?(report.bytesize) ? report : BOUND.fit(report.lines(chomp: true)).join("\n")
    end
  end
end
