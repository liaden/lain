# frozen_string_literal: true

module Lain
  module Shell
    class Executable
      # {Stat} answered from a listing of an image's files, so no call touches the host or runs the image.
      class ListedStat
        include RealpathWalk

        # One path in the listing.
        Entry = Data.define(:type, :mode, :uid, :gid, :link) do
          # @return [Boolean]
          def symlink? = type == "symlink"

          # @return [Boolean]
          def directory? = type == "directory"

          # @return [Boolean] a hard link is a file with its own mode
          def file? = %w[file hardlink].include?(type)
        end

        ROOT = Entry.new(type: "directory", mode: 0o755, uid: 0, gid: 0, link: nil)

        # @param entries [Hash{String => Entry}] absolute path to entry
        def initialize(entries)
          @entries = entries.merge("/" => entries.fetch("/", ROOT))
        end

        # As the kernel does, the parent is resolved first, so `..` and a symlinked parent are followed.
        #
        # @param path [String]
        # @return [Entry] the link itself, not its target
        # @raise [Errno::ENOENT]
        def lstat(path) = entry_at(located(path))

        # @param path [String]
        # @return [String] the link's target, as written
        # @raise [Errno::ENOENT, Errno::EINVAL] missing, or not a link
        def readlink(path)
          entry = lstat(path)
          raise Errno::EINVAL, path unless entry.symlink?

          entry.link
        end

        # @param path [String]
        # @return [String] the realpath, or the path as given when it cannot be resolved
        def real(path)
          realpath(path)
        rescue SystemCallError
          path
        end

        # @param path [String]
        # @return [Array<String>] the names in a directory
        def children(path)
          dir = realpath(path)
          prefix = dir == "/" ? "/" : "#{dir}/"
          @entries.keys.filter_map { |key| key.delete_prefix(prefix) if child_of?(key, prefix) }.sort
        end

        # @param path [String]
        # @return [Boolean]
        def directory?(path) = followed(path)&.directory? || false

        # @param path [String]
        # @return [Boolean]
        def executable?(path)
          entry = followed(path)
          !entry.nil? && entry.file? && entry.mode.anybits?(0o111)
        end

        # @param _path [String]
        # @return [Boolean] always false: no call can change an image file for a later one
        def writable?(_path) = false

        private

        def entry_at(path) = @entries.fetch(path) { raise Errno::ENOENT, path }

        # The walk hands over a path it has already resolved, which needs no second walk.
        def link_at(parts)
          entry = entry_at("/#{parts.join("/")}")
          entry.link if entry.symlink?
        end

        def child_of?(key, prefix) = key != "/" && key.start_with?(prefix) && !key.delete_prefix(prefix).include?("/")

        def followed(path)
          lstat(realpath(path))
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
