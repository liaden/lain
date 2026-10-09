# frozen_string_literal: true

require "fileutils"

module Lain
  module Isolation
    # The one lock a verify run holds, for every repository of one user on one
    # machine. It sits under the state home, which specs isolate per worker;
    # the runtime dir is not isolated.
    module SuiteLock
      NAME = "suite.lock"

      # @param paths [Lain::Paths]
      # @return [Lain::FileLock]
      def self.for(paths:)
        dir = File.join(paths.state_home, "locks")
        begin
          FileUtils.mkdir_p(dir)
        rescue SystemCallError => e
          raise Paths::Unwritable.new(dir, e)
        end
        FileLock.new(File.join(dir, NAME), label: "the suite lock")
      end
    end
  end
end
