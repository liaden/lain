# frozen_string_literal: true

# Polls from the calling thread while `worker` runs, and answers the longest gap between
# polls as a share of the whole call. Held, the one gap is nearly the whole call (share
# near 1.0); released, under 0.1 even on a loaded box, because a share scales with the
# call where a fixed clock bound does not.
module GapShare
  def longest_gap_share(worker)
    started = last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    longest = 0
    while worker.alive?
      sleep 0.001
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      longest = [longest, now - last].max
      last = now
    end
    longest / (last - started)
  end
end
