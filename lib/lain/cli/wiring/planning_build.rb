# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What lain://planning folds its gate states from: the epic's own records
      # across every session journal the project has, the way `lain epic status`
      # reads them, because a gate answered in another terminal is written to a
      # session file this chat never sees.
      module PlanningBuild
        TYPES = [Lain::Epic::SignoffQueue::JOURNAL_TYPE, CLI::EpicQueue::PARKED_TYPE].freeze

        module_function

        # @param slug [String] the epic the chat is mounted into
        # @param root [String] the project root
        # @param paths [Lain::Paths] where the session journals are filed
        # @param status [#progress] the fold of the epic's document and journals
        # @return [Frontend::Neovim::StatusView::Mounted]
        def mounted(slug:, root:, paths:, status: Epic.new(root:))
          records = lambda do |epic_slug|
            SessionJournals.of(paths, root, types: TYPES).select { |record| record["epic_slug"] == epic_slug }
          end
          Frontend::Neovim::StatusView::Mounted.new(slug:, status:, records:)
        end
      end
    end
  end
end
