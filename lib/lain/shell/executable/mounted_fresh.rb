# frozen_string_literal: true

module Lain
  module Shell
    class Executable
      # Freshness for a container: every command starts a new one, so only a mounted path can have changed.
      class MountedFresh
        # @param mounts [Array<String>] realpaths
        # @param host [#fresh?]
        def initialize(mounts:, host:)
          @mounts = mounts.map { |mount| mount.chomp("/") }.freeze
          @host = host
        end

        # @param path [String]
        # @return [Boolean]
        def fresh?(path) = mounted?(path) && @host.fresh?(path)

        private

        def mounted?(path) = @mounts.any? { |mount| path == mount || path.start_with?("#{mount}/") }
      end
    end
  end
end
