# frozen_string_literal: true

# A ctime is stamped from the coarse clock, and a VM's time sync can step the clock back about
# 180 ms, so a fixed sleep before a write can still stamp it before a mark. Waiting on the coarse
# clock just before the write cannot. Fresh's own wait is bounded far below a step, so a spec
# cannot borrow it.
module CoarseClock
  # Several steps long, so only a clock that stopped reaches it.
  BOUND = 2

  def coarse_now = Process.clock_gettime(Process::CLOCK_REALTIME_COARSE, :nanosecond)

  def past_coarse_clock(time)
    floor = (time.to_i * 1_000_000_000) + time.nsec
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOUND
    sleep(0.0005) until coarse_now > floor || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "the coarse clock did not pass #{time.iso8601(9)} within #{BOUND} s" unless coarse_now > floor
  end
end
