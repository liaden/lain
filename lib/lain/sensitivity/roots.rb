# frozen_string_literal: true

module Lain
  class Sensitivity
    # The directories a confined policy holds, and whether a landing lies under one.
    #
    # Each directory is kept both as written and where it really lands, so a
    # path reached through a link to a root and one spelled under the link are
    # both held. `<=` is a preorder only, since a root beside its own child
    # holds what the root alone does.
    class Roots
      # @return [Roots] holding nothing
      def self.none = NONE

      # @param dirs [Array<String>] each expanded against the process directory
      # @param facts [FileFacts::Live, FileFacts::Recorded] where a directory really lands
      # @return [Roots]
      def self.of(*dirs, facts: FileFacts::LIVE) = new(dirs.flat_map { spellings(_1, facts) })

      def self.spellings(dir, facts)
        expanded = File.expand_path(dir)
        [expanded, facts.realpath(expanded)]
      rescue SystemCallError
        [expanded]
      end
      private_class_method :spellings

      # @param spellings [Array<String>] absolute, already spelled; see {of}
      def initialize(spellings)
        @spellings = spellings.map(&:-@).uniq.freeze
        freeze
      end

      NONE = new([])

      # @param path [String] an absolute landing
      # @return [Boolean]
      def held?(path) = @spellings.any? { Landing.under?(path, _1) }

      # @param other [Roots]
      # @return [Roots] holding what either holds
      def |(other) = Roots.new(@spellings | other.spellings)

      # @param other [Roots]
      # @return [Boolean] whether every root here lies under one of `other`'s
      def <=(other) = @spellings.all? { other.held?(_1) }

      protected

      attr_reader :spellings
    end
  end
end
