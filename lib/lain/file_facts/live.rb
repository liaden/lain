# frozen_string_literal: true

module Lain
  module FileFacts
    # The live disk, answering exactly as File and Dir do, raises included.
    class Live
      def initialize = freeze

      # @param path [String] absolute
      # @return [String] where it lands
      # @raise [SystemCallError] when it does not resolve
      def realpath(path) = File.realpath(path)

      def symlink?(path) = File.symlink?(path)

      def exist?(path) = File.exist?(path)

      def file?(path) = File.file?(path)

      def directory?(path) = File.directory?(path)

      # @raise [SystemCallError] when the path is not a link
      def readlink(path) = File.readlink(path)

      # @param pattern [String] relative to `base`
      # @param base [String] absolute
      # @return [Array<String>] the matches, relative to `base`
      def glob(pattern, base:) = Dir.glob(pattern, base:)

      # @yieldparam name [String] each entry, without `.` and `..`
      def each_child(directory, &block) = Dir.each_child(directory, &block)
    end
  end
end
