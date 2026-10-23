# frozen_string_literal: true

require "fileutils"

module Lain
  module Isolation
    # The one lock a verify run holds, for every repository of one user on one
    # machine. It sits under the state home, which specs isolate per worker;
    # the runtime dir is not isolated.
    module SuiteLock
      NAME = "suite.lock"
      # Set for a child of a holder, so a suite it starts does not wait on its own parent.
      HELD_VARIABLE = "LAIN_SUITE_LOCK_HELD"

      # @param paths [Lain::Paths]
      # @param patience [Numeric] seconds a waiter waits before it is told who holds the lock
      # @return [Lain::FileLock]
      def self.for(paths:, patience: 5)
        dir = File.join(paths.state_home, "locks")
        begin
          FileUtils.mkdir_p(dir)
        rescue SystemCallError => e
          raise Paths::Unwritable.new(dir, e)
        end
        FileLock.new(File.join(dir, NAME), label: "the suite lock", patience:)
      end

      # @param paths [Lain::Paths]
      # @param env [#[]] where {HELD_VARIABLE} is read
      # @param notice [#call] told, in words, who holds the lock when the wait runs long
      # @param patience [Numeric] seconds of waiting before the notice
      # @return the block's value
      def self.holding(paths:, env: ENV, notice: ParentLock::Silent, patience: 5, &block)
        return yield if env[HELD_VARIABLE] == "1"

        self.for(paths:, patience:).hold(notice:, &block)
      end
    end
  end
end
