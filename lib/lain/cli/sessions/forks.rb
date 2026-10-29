# frozen_string_literal: true

module Lain
  module CLI
    class Sessions
      # The sessions that began from another session's turn, found by their header's `resumed_from`.
      # A fork and a resume write the same pair, so a child is only known to start there, not how.
      module Forks
        # @param session_file [String, nil] the session whose children are wanted; nil (no journal) has none
        # @param dirs [Array<String>] the directories the project's sessions are filed in
        # @return [Hash{String => Array<String>}] child file names, by the digest they resumed from
        def self.of(session_file, dirs:)
          return {} if session_file.nil?

          parent = File.basename(session_file)
          dirs.flat_map { |dir| Paths.ndjson_in(dir) }.sort.each_with_object({}) do |path, found|
            from = resumed_from(path)
            (found[from["head"]] ||= []) << File.basename(path) if from["file"] == parent
          end
        end

        # Read per call, because promoting a chat renames its journal and a child names its parent by file.
        #
        # @param chronicle [#journal_path] the running chat's journal, whose path is nil without one
        # @param paths [Paths] where the project's sessions are filed
        # @param project [Project] whose session directories are scanned
        # @return [#call] answers {.of}'s Hash for the chronicle's current file
        def self.source(chronicle, paths:, project:)
          -> { of(chronicle.journal_path, dirs: paths.session_dirs(project)) }
        end

        def self.resumed_from(path)
          Journal.records(File.foreach(path), type: SessionRecord::HEADER_TYPE).first&.fetch("resumed_from", nil) || {}
        end
        private_class_method :resumed_from
      end
    end
  end
end
