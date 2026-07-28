# frozen_string_literal: true

module Lain
  # Three elapsed-time measures for the chat UI: since the session started,
  # since the user last answered a prompt, since the last compaction. Each is
  # a plain subtraction against ONE injected clock, so all three move
  # together under a jumped-clock spec the way {CLI::Conductor}'s own grace
  # timing does -- reusing that class's exact idiom
  # (`clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }`) rather
  # than inventing a second one, because every reading here is a DURATION,
  # never a wall-clock deadline a renderer ticks locally against the way
  # {StatusFeed}'s published `cache_deadline` is. Nothing here is published;
  # a caller reads the three methods directly.
  #
  # Two write sites, deliberately different shapes because the two facts
  # arrive by different means:
  #
  # * {#record_input} is a direct call -- {CLI::Conductor#read_prompt} is the
  #   ONE place a user prompt is answered, so it is the one caller, and there
  #   is no "event" to duck-type there.
  # * `#<<` makes this a {Channel}/{CLI::JournalTee} sink duck, the same one
  #   {StatusFeed} answers, so a {Telemetry::Compaction} record reaches it
  #   off the SAME fan-out rather than a bespoke callback. Every other event
  #   this class does not recognize is inert -- no raise, no measure change --
  #   matching {StatusFeed#<<}'s tolerance of the fan-out's full event mix.
  #
  # No ivar here is mutex-guarded, and that is deliberate, not an oversight.
  # {StatusFeed} never faces this question -- it publishes to
  # `.lain/state.json` and every renderer reads the FILE, so it is never read
  # cross-thread in-process. `RunClock` is the first of this family actually
  # meant to be read directly from another thread/fiber than the one writing
  # it (T7's status line reading `#elapsed`/`#idle` while `#<<` and
  # `#record_input` are written from elsewhere; T13's channel wiring). That is
  # safe under CRuby's GVL for exactly this shape: every write is one ivar
  # reassignment to an immutable `Float` or `nil` (never an in-place mutation
  # spanning bytecode boundaries), and the GVL makes a single ivar swap
  # atomic, so a reader observes either the old value or the new one, never a
  # torn one. `#since_compaction` binding `@last_compaction_at` to a local
  # before its second read (see below) is what keeps a READER's own two
  # touches of one ivar consistent with itself, on top of that per-write
  # atomicity -- a concern a mutex would not even address, since the ivar
  # itself is never in an invalid state, only potentially STALE between a
  # reader's two reads of it. Probed directly: two writer threads hammering
  # `#record_input`/`#<<` against a reader pulling all three methods 200k
  # times raised nothing, produced no wrong-typed reading, and no reading in
  # negative or otherwise impossible territory.
  class RunClock
    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
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
    # Bound to a local FIRST: `@last_compaction_at` is read twice (the
    # truthiness check, then the subtraction), and a concurrent `#<<` can
    # advance the ivar between them -- a bare `@last_compaction_at &&
    # (@clock.call - @last_compaction_at)` could pass the nil check against
    # the old value and then subtract a newer one, reporting a reading for a
    # compaction the caller never decided to report. One read, one snapshot.
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
