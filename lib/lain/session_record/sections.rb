# frozen_string_literal: true

module Lain
  module SessionRecord
    Sections = Data.define(:profile, :compaction, :arms, :middleware, :provenance)

    # The header sections a launch contributes, each already a header Hash. One
    # value so the writer, the scribe and the chronicle pass a single argument,
    # and an omitted section defaults here once. See {SessionRecord.header} for
    # what each section writes.
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
      # @return [Sections]
      def self.of(profile:, compaction:, arms:, middleware:, provenance:)
        new(profile: profile.to_header, compaction:, arms: arms.to_header, middleware: middleware.to_header,
            provenance: provenance.to_header)
      end

      # @return [Sections] every section empty
      def self.none = NONE

      # @param profile [Hash{String=>Object}] the run profile's header fields
      # @param compaction [Hash{String=>Object}] the compaction section
      # @param arms [Hash{String=>String}] the bench arms that are on
      # @param middleware [Hash{String=>String}] whose trust digest admitted the middleware
      # @param provenance [Hash{String=>Hash}] what produced the run
      def initialize(profile: EMPTY, compaction: EMPTY, arms: EMPTY, middleware: EMPTY, provenance: EMPTY)
        super
      end

      NONE = new
    end
  end
end
