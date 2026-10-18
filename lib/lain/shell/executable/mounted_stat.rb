# frozen_string_literal: true

module Lain
  module Shell
    class Executable
      # {Stat} for a container: a path under a mount is the host's, any other is the image's.
      class MountedStat
        include RealpathWalk

        # @param mounts [Array<String>] realpaths, so "under a mount" is a lexical test
        # @param image [#lstat, #readlink, #children, #directory?, #executable?, #writable?]
        # @param host [Stat]
        def initialize(mounts:, image:, host: Stat.new)
          @mounts = mounts.map { |mount| mount.chomp("/") }.freeze
          @image = image
          @host = host
        end

        # The parent is resolved first, as the kernel does, so a path that leaves a mount through `..` or a
        # symlinked parent is answered by the side it lands on.
        #
        # @param path [String]
        # @return [File::Stat, ListedStat::Entry] the link itself, not its target
        def lstat(path) = resolved_lstat(located(path))

        # @param path [String]
        # @return [String] the link's target, as written
        def readlink(path) = resolved_readlink(located(path))

        # @param path [String]
        # @return [String] the realpath, or the path as given when it cannot be resolved
        def real(path)
          realpath(path)
        rescue SystemCallError
          path
        end

        # @param path [String]
        # @return [Array<String>] the names in a directory
        def children(path) = settled(path) { |side, real| listing(side, real) }

        # @param path [String]
        # @return [Boolean]
        def directory?(path)
          absent_is_false { settled(path) { |side, real| above_mount?(real) || side.directory?(real) } }
        end

        # @param path [String]
        # @return [Boolean]
        def executable?(path) = absent_is_false { settled(path) { |side, real| side.executable?(real) } }

        # @param path [String]
        # @return [Boolean]
        def writable?(path) = absent_is_false { settled(path) { |side, real| side.writable?(real) } }

        private

        def resolved_lstat(path)
          side(path).lstat(path)
        rescue Errno::ENOENT
          raise unless above_mount?(path)

          @host.lstat(path)
        end

        def resolved_readlink(path)
          side(path).readlink(path)
        rescue Errno::ENOENT
          raise unless above_mount?(path)

          @host.readlink(path)
        end

        # The walk hands over a path it has already resolved, which needs no second walk.
        def link_at(parts)
          full = "/#{parts.join("/")}"
          resolved_readlink(full) if resolved_lstat(full).symlink?
        end

        def side(path) = mounted?(path) ? @host : @image

        # The image has no entry for a directory that exists only to hold a mount, so the walk falls back to the host.
        def above_mount?(path) = @mounts.any? { |mount| mount.start_with?("#{path.chomp("/")}/") }

        def mounted?(path) = @mounts.any? { |mount| path == mount || path.start_with?("#{mount}/") }

        def listing(side, real)
          return side.children(real) if mounted?(real)

          (image_children(real) + toward_mounts(real)).uniq.sort.tap do |names|
            raise Errno::ENOENT, real if names.empty?
          end
        end

        def image_children(real)
          @image.children(real)
        rescue Errno::ENOENT
          []
        end

        def toward_mounts(real)
          prefix = real == "/" ? "/" : "#{real}/"
          @mounts.filter_map { |mount| mount.delete_prefix(prefix).split("/").first if mount.start_with?(prefix) }
        end

        def absent_is_false
          yield
        rescue SystemCallError
          false
        end

        # Resolves first so a link is judged where it lands, not where it sits.
        def settled(path)
          real = realpath(path)
          yield side(real), real
        end
      end
    end
  end
end
