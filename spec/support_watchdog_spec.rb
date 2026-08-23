# frozen_string_literal: true

# Deliberately OUTSIDE spec/support/, for the reason spec/support_matchers_spec.rb
# and spec/support_vsock_availability_spec.rb both give: spec_helper glob-requires
# spec/support/**/*.rb as CONFIGURATION, and RSpec's own discovery separately
# `load`s every spec/**/*_spec.rb -- which does not consult $LOADED_FEATURES, so a
# `_spec.rb` inside that glob would run twice. This tests spec/support/watchdog.rb,
# so it lives one level up, where only discovery finds it.
#
# {SpecWatchdog} has no injection seam a normal example reaches, so this file
# needed one before {SpecWatchdog::Sentry::Starvation}'s verdict could be
# proven at all: driven here against a controlled clock and a controlled load
# average, never a real 30-second stall.
RSpec.describe SpecWatchdog::Sentry::Starvation do
  def starvation(cores: 8, load1: 1.0)
    described_class.new(cores:, load1_reader: -> { load1 })
  end

  it "reads CPU time through the injected clock" do
    expect(described_class.new(cpu_clock: -> { 42.0 }).cpu_now).to eq(42.0)
  end

  it "calls it starvation when the process barely ran and the box is oversubscribed" do
    reading = starvation(cores: 8, load1: 40.0).reading(cpu_elapsed: 0.1, wall_elapsed: 30.0)

    expect(reading.starved).to be(true)
  end

  it "calls it a hang when the process kept its CPU even though wall time is long" do
    reading = starvation(cores: 8, load1: 1.2).reading(cpu_elapsed: 29.5, wall_elapsed: 30.0)

    expect(reading.starved).to be(false)
  end

  it "calls it a hang when CPU share is low but the box was not oversubscribed" do
    reading = starvation(cores: 8, load1: 2.0).reading(cpu_elapsed: 0.1, wall_elapsed: 30.0)

    expect(reading.starved).to be(false)
  end

  it "cannot call itself starved without a load average to point at" do
    unreadable = described_class.new(cores: 8, load1_reader: -> { raise Errno::ENOENT })

    reading = unreadable.reading(cpu_elapsed: 0.1, wall_elapsed: 30.0)

    expect(reading.starved).to be(false)
    expect(reading.load1).to be_nil
  end

  it "carries the numbers behind the verdict, not just the verdict" do
    reading = starvation(cores: 4, load1: 9.0).reading(cpu_elapsed: 0.2, wall_elapsed: 10.0)

    expect(reading).to have_attributes(cpu_elapsed: 0.2, wall_elapsed: 10.0, load1: 9.0, cores: 4)
  end
end

RSpec.describe SpecWatchdog::Sentry do
  # Real budget and tick would need a genuine 30s wait to prove anything --
  # both are constructor arguments precisely so this file never does. `tick`
  # is the supervisor's poll interval ({SpecWatchdog::Sentry::TICK} in
  # production); shrinking it here is what keeps this spec itself under the
  # suite's own p99, the property {SpecWatchdog} exists to protect.
  def sentry(starvation:) = described_class.new(budget: 0.02, tick: 0.01, starvation:)

  def fake_example(location: "spec/support/watchdog_spec.rb:1")
    instance_double(RSpec::Core::Example, location:)
  end

  # Runs `sentry.watch` over a block that outlives the budget, and returns the
  # {SpecWatchdog::Stuck} message the supervisor raised into THIS thread --
  # the same thread a real example runs on, and the same exception a real
  # strike raises.
  def struck_message(sentry, &block)
    sentry.watch(fake_example, &block)
    raise "expected SpecWatchdog::Stuck to be raised"
  rescue SpecWatchdog::Stuck => e
    e.message
  end

  # A genuine hang: CPU share is near zero (a real `sleep` consumes none) but
  # the box's own load average -- stubbed low here -- says nobody was denied a
  # core. {Starvation}'s conjunction is what keeps this from being called
  # starvation on CPU share alone.
  it "raises Stuck naming a hang, not starvation, when the box was not oversubscribed" do
    starvation = SpecWatchdog::Sentry::Starvation.new(cores: 8, load1_reader: -> { 1.0 })

    message = struck_message(sentry(starvation:)) { sleep 0.2 }

    expect(message).to include("This is a hang, not slowness")
    expect(message).not_to include("STARVED")
  end

  # The same near-zero CPU share, but the load average -- stubbed high, as
  # this session measured live under `rake check`'s own contention -- says the
  # box denied this process a core. The verdict flips on that signal alone.
  it "raises Stuck naming starvation, not a hang, when the box was oversubscribed" do
    starvation = SpecWatchdog::Sentry::Starvation.new(cores: 2, load1_reader: -> { 20.0 })

    message = struck_message(sentry(starvation:)) { sleep 0.2 }

    expect(message).to include("STARVED, not necessarily stuck")
    expect(message).not_to include("This is a hang, not slowness")
  end

  it "still prints the thread dump under a starvation verdict, because it costs nothing and might be both" do
    starvation = SpecWatchdog::Sentry::Starvation.new(cores: 2, load1_reader: -> { 20.0 })

    message = struck_message(sentry(starvation:)) { sleep 0.2 }

    expect(message).to include("Thread ").and include("spec-watchdog")
  end
end
