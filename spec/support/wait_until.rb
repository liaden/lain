# frozen_string_literal: true

# Polling waits, bounded. A condition that never holds must be a FAILING example that
# says which condition, never a suite that hangs with nothing to read -- the idiom
# human_replies_spec wrote first and two other files then copied.
module WaitUntil
  DEFAULT_TIMEOUT = 3
  POLL = 0.02

  def wait_until(timeout: DEFAULT_TIMEOUT, reason: "the condition")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep(POLL) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "#{reason} never held within #{timeout}s" unless yield
  end

  # `task.sleep` parks the fiber under Async's scheduler, so the fibers being waited
  # ON get their turn; a plain Kernel#sleep would block the whole reactor.
  def pumped_until(task, timeout: DEFAULT_TIMEOUT, reason: "the condition")
    deadline = Async::Clock.now + timeout
    task.sleep(POLL) until yield || Async::Clock.now > deadline
    raise "#{reason} never held within #{timeout}s" unless yield
  end

  # Asserting a NEGATIVE -- "nothing more arrives" -- is not a wait, it is a fixed
  # window, and it is the one case where running out the clock is the success. Kept
  # separate so `pumped_until` can treat its own timeout as a failure.
  def settle_for(task, duration)
    task.sleep(duration)
  end
end

RSpec.configure { |config| config.include(WaitUntil) }
