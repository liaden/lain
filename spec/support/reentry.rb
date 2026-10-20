# frozen_string_literal: true

# A fiber dropped while suspended is collected without being unwound, so a Rust
# frame waiting inside it never runs its destructors. `Reentry#leaked_by` runs a
# call that suspends inside one of its calls into Ruby, drops the fiber, and
# answers how much Rust heap `Lain::Ext::Probe.live_bytes` says is still
# allocated. A leak grows by one payload per round; anything else the process
# allocates meanwhile does not scale with the rounds, so the bound is one
# payload. The rounds run on a thread of their own, ended before the count,
# because the collector scans live stacks conservatively and a stale word on
# this one could keep a holder reachable.
module Reentry
  PAYLOAD = 1_000_000
  ROUNDS = 20

  def payload = "x" * PAYLOAD

  def leaked_by(&call)
    drop_suspended(1, &call)
    before = live_bytes
    drop_suspended(ROUNDS, &call)
    live_bytes - before
  end

  # The point inside a callback where the call under test suspends.
  def self.suspend_here
    Fiber.yield if Thread.current[:suspend]
  end

  # Runs `example` with `Symbol#to_s` suspending inside a dropped fiber.
  def self.with_suspending_symbol_to_s(example)
    plain = Symbol.instance_method(:to_s)
    Symbol.define_method(:to_s) do
      Reentry.suspend_here
      plain.bind_call(self)
    end
    example.run
  ensure
    Symbol.define_method(:to_s, plain)
  end

  private

  def drop_suspended(rounds, &call)
    Thread.new { rounds.times { Fiber.new { suspended(&call) }.resume } }.join
  end

  def suspended
    Thread.current[:suspend] = true
    yield
  end

  def live_bytes
    GC.start(full_mark: true, immediate_sweep: true)
    Lain::Ext::Probe.live_bytes
  end
end
