# frozen_string_literal: true

module Lain
  module SessionRecord
    Sections = Data.define(:profile, :compaction, :arms, :middleware, :provenance, :summarizer)

    # The header sections a launch contributes, each already a header Hash. One
    # value so the writer, the scribe and the chronicle pass a single argument,
    # and an omitted optional section defaults here once. The profile and the
    # provenance have no default, so a writer that forgets one raises instead of
    # writing a header no reader can compare. See {SessionRecord.header} for what
    # each section writes.
    class Sections
      EMPTY = {}.freeze
      private_constant :EMPTY

      # A compaction section is not asked for a header because
      # `CLI::Backend#compaction_header` resolves one from the backend already.
      #
      # @param profile [#to_header] `CLI::RunProfile`
      # @param compaction [Hash{String=>Object}]
      # @param arms [#to_header] `CLI::Arms`
      # @param middleware [#to_header] `Config::Middleware`
      # @param provenance [#to_header] {Provenance}
      # @param summarizer [Hash{String=>String}] the summarizer tier's provider and model
      # @return [Sections]
      def self.of(profile:, compaction:, arms:, middleware:, provenance:, summarizer:)
        new(profile: profile.to_header, compaction:, arms: arms.to_header, middleware: middleware.to_header,
            provenance: provenance.to_header, summarizer:)
      end

      # @param profile [Hash{String=>Object}] the run profile's header fields, never empty
      # @param compaction [Hash{String=>Object}] the compaction section
      # @param arms [Hash{String=>String}] the bench arms that are on
      # @param middleware [Hash{String=>String}] whose trust digest admitted the middleware
      # @param provenance [Hash{String=>Hash}] what produced the run, never empty
      # @param summarizer [Hash{String=>String}] the summarizer tier's provider and model
      # @raise [ArgumentError] when the profile or the provenance is empty
      def initialize(profile:, provenance:, compaction: EMPTY, arms: EMPTY, middleware: EMPTY, summarizer: EMPTY)
        { profile:, provenance: }.each do |name, section|
          raise ArgumentError, "#{name} section is empty; a header without it cannot be compared" if section.empty?
        end

        super
      end
    end
  end
end
