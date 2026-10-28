# frozen_string_literal: true

module Lain
  module Bench
    # Where a bench run records when no `--journal` is given.
    module Journals
      # @param state [Lain::Paths]
      # @param prefix [String] names the sweep
      # @param ext [String] `".ndjson"` for a file, empty for a directory
      # @param clock [#now]
      # @param pid [Integer] keeps two runs in the same second apart
      # @return [String] a timestamped path under the state home's `bench` directory
      def self.stamped(state, prefix, ext: "", clock: Time, pid: Process.pid)
        stamp = clock.now.utc.strftime("%Y%m%dT%H%M%S")
        File.join(state.state_home, "bench", "#{prefix}-#{stamp}-#{pid}#{ext}")
      end
    end
  end
end
