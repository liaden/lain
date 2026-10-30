# frozen_string_literal: true

module Lain
  module Shell
    class Executable
      # `realpath` for a filesystem that offers only `lstat` and `readlink`, one component at a time so
      # a caller may answer each hop from a different place.
      module RealpathWalk
        # An including stat's `lstat` and `readlink`, as {Landing.walk} asks them of a path it has resolved.
        class Facts
          # @param lstat [#call] path to its entry, raising ENOENT when there is none
          # @param readlink [#call] path to its link's target
          def initialize(lstat, readlink)
            @lstat = lstat
            @readlink = readlink
          end

          # @param path [String] resolved
          # @return [Boolean]
          def symlink?(path) = entry(path)&.symlink? || false

          # @param path [String] resolved
          # @return [Boolean]
          def exist?(path) = !entry(path).nil?

          # @param path [String] resolved
          # @return [String] the target, as written
          def readlink(path) = @readlink.call(path)

          private

          # The walk asks `symlink?` then `exist?` of each component, which is 1 lstat when remembered.
          def entry(path)
            return @entry if @at == path

            @at = path
            @entry = lstat_or_nil(path)
          end

          def lstat_or_nil(path)
            @lstat.call(path)
          rescue Errno::ENOENT
            nil
          end
        end

        # @param path [String] absolute
        # @return [String] every link and `..` resolved
        # @raise [Errno::ENOENT] a component is missing
        # @raise [Errno::ELOOP] more than {Landing::HOPS} links were followed
        def realpath(path)
          walk = Landing.walk(path, facts: Facts.new(method(:resolved_lstat), method(:resolved_readlink)))
          raise Errno::ELOOP, path if walk.looped?
          raise Errno::ENOENT, path if walk.absent?

          walk.path
        end

        private

        # Where the kernel's lstat lands: the parent resolved, the last name kept unless it is `.` or `..`.
        def located(path)
          dir, base = File.split(path)
          return realpath(path) if dir == path || %w[. ..].include?(base)

          File.join(realpath(dir), base)
        end

        # The walk hands over a path it has already resolved, which an includer may answer without a second walk.
        def resolved_lstat(path) = lstat(path)

        def resolved_readlink(path) = readlink(path)
      end
    end
  end
end
