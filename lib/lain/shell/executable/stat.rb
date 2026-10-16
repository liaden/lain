# frozen_string_literal: true

module Lain
  module Shell
    class Executable
      # The filesystem as {Resolver} reads it.
      class Stat
        # @param path [String]
        # @return [File::Stat] the link itself, not its target
        def lstat(path) = File.lstat(path)

        # @param path [String]
        # @return [String] the link's target, as written
        def readlink(path) = File.readlink(path)

        # @param path [String]
        # @return [String] every link and `..` resolved
        def realpath(path) = File.realpath(path)

        # @param path [String]
        # @return [String] the realpath, or the path as given when it cannot be resolved
        def real(path)
          realpath(path)
        rescue SystemCallError
          path
        end

        # @param path [String]
        # @return [Array<String>] the names in a directory
        def children(path) = Dir.children(path).sort

        # @param path [String]
        # @return [Boolean]
        def directory?(path) = File.directory?(path)

        # execvp skips a directory or a file without the x bit and keeps searching.
        #
        # @param path [String]
        # @return [Boolean]
        def executable?(path) = File.file?(path) && File.executable?(path)

        # @param path [String]
        # @return [Boolean] whether this process could replace or rename into it
        def writable?(path) = File.writable?(path)
      end
    end
  end
end
