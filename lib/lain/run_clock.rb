# frozen_string_literal: true

module Lain
  # Three elapsed-time measures for the chat UI: since the session started,
  # since the user last answered a prompt, since the last compaction. Each is a
  # plain subtraction against ONE injected clock, so all three move together
  # under a jumped-clock spec. Every reading here is a DURATION, never a
  # wall-clock deadline a renderer ticks locally against the way {StatusFeed}'s
  # published `cache_deadline` is, and nothing here is published.
  #
  # Two write sites, shaped by how each fact arrives: {#record_input} is a
  # direct call from the ONE place a user prompt is answered, while `#<<` is
  # the {Channel}/{CLI::JournalTee} sink duck {StatusFeed} also answers, so a
  # {Telemetry::Compaction} arrives off the SAME fan-out rather than a bespoke
  # callback. Every unrecognized event is inert.
  #
  # NO IVAR HERE IS MUTEX-GUARDED, deliberately. This is the first of its family
  # actually read from a thread other than the writer's ({StatusFeed} publishes
  # to a file, so every renderer reads the FILE). Safe under CRuby's GVL for
  # exactly this shape: every write is one ivar reassignment to an immutable
  # `Float` or `nil`, never an in-place mutation spanning bytecode boundaries,
  # and a single ivar swap is atomic -- a reader sees the old value or the new
  # one, never a torn one. What a mutex would not address at all is a reader's
  # own two touches of one ivar disagreeing, which is why {#since_compaction}
  # binds to a local. Probed directly: two writer threads hammering
  # `#record_input`/`#<<` against a reader pulling all three methods 200k times
  # raised nothing and produced no wrong-typed or impossible reading.
  class RunClock
    # The one monotonic time source every `clock:` seam in the repo defaults to.
    # It lives HERE because this class was already the repo's clock object; a
    # second `Lain::Clock` unit would only add a name.
    #
    # ONE lambda, not a factory: two seams built on the default therefore hold
    # the same object, which is what makes `Arm::Instrument.new ==
    # Arm::Instrument.new` true.
    #
    # There is deliberately no `WALL` sibling. Wall time is asked three
    # different ways on purpose -- an ISO8601 String, a utc `Time`, a local
    # `Time.now` -- so a single constant would misname two of the three.
    #
    # Units that load BEFORE run_clock in `lain.rb` may still name it: a
    # keyword's default is evaluated per call, not at definition.
    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    def initialize(clock: MONOTONIC)
      @clock = clock
      @started_at = @clock.call
      @last_input_at = @started_at
      @last_compaction_at = nil
    end

    # @return [Float] seconds since construction (session start).
    def elapsed = @clock.call - @started_at

    # @return [Float] seconds since the user last answered a prompt, or since
    #   session start when no prompt has been answered yet -- there is no
    #   earlier "last input" to measure from, so start stands in for it.
    def idle = @clock.call - @last_input_at

    # @return [Float, nil] seconds since the last observed compaction, or
    #   `nil` when none has been observed -- absence, not a zero a renderer
    #   could mistake for "just compacted".
    #
    # Bound to a local FIRST. Reading the ivar in both the nil check and the
    # subtraction lets a concurrent `#<<` advance it in between, so the check
    # passes against the old value while the subtraction uses a newer one,
    # reporting a reading for a compaction the caller never decided to report.
    # One read, one snapshot.
    def since_compaction
      last = @last_compaction_at
      last && (@clock.call - last)
    end

    # {CLI::Conductor#read_prompt}'s one write site: called only when a real
    # line came back (never on a {CLI::PromptBreaker::Break}, never on a
    # `nil` EOF) -- a signal-ended or empty prompt is not user input.
    # @return [self]
    def record_input
      @last_input_at = @clock.call
      self
    end

    # @param event [Object] any fan-out event; only a {Telemetry::Compaction}
    #   moves a measure.
    # @return [self]
    def <<(event)
      @last_compaction_at = @clock.call if event.is_a?(Telemetry::Compaction)
      self
    end
  end
end
