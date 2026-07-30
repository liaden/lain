# frozen_string_literal: true

module Lain
  class Arm
    # How an arm MEASURES: the monotonic clock it times work with, and the price book
    # it turns a run's journal into dollars with. Injected into every arm, which
    # is the point -- `elapsed` and `ledger` are the bench's two headline
    # metrics, and before this object each arm carried its own byte-identical
    # copy of both (four `#timed`s, three `Ledger.from_journal` lines, two
    # DEFAULT_CLOCKs). Copies agree until one of them is edited; a shared
    # collaborator cannot disagree at all.
    #
    # It is a COLLABORATOR, not a base class: an arm still assembles its own
    # {Arm::Run}, because what a topology measures is common and what it
    # produces is its own. {#timed} therefore hands the block's value BACK
    # alongside the elapsed seconds -- a bare "seconds only" timer is what forced
    # two arms into `state = nil; timed { state = ... }`, mutable capture written
    # to smuggle a result out of a block that discarded it.
    #
    # FROZEN BUT NOT YET `Ractor.shareable?`, the same posture {Arm::Run} states
    # for itself: `price_book` is shareable, `clock` is a Proc, and a Proc is not
    # shareable until it has been isolated -- so the Data is frozen while
    # `Ractor.shareable?(instrument)` is false. NOT YET, not never: probed on
    # 4.0.6, `Ractor.make_shareable(RunClock::MONOTONIC)` SUCCEEDS, because that
    # lambda captures nothing, and the frozen Instrument holding it then reports
    # shareable. `Ractor::IsolationError` is what a clock closing over mutable
    # state would raise -- being a Proc is not the boundary; capturing is.
    #
    # Left undone because nothing crosses a Ractor with one today: {Driver} runs
    # arms serially and the fan-out is `Async` fibers inside one Ractor, and a
    # clock is asked for the time and holds no state to race over. Isolating a
    # constant mutates it process-wide, so that call belongs to whoever
    # introduces a Ractor-parallel Driver, next to its own spec.
    #
    # And because both defaults are single shared objects, `Instrument.new ==
    # Instrument.new` -- as Data equality promises for two built from the same
    # clock and book. Nothing here depends on that; it is only worth saying
    # because the default clock USED to be a fresh lambda per call, which made
    # the same two Instruments unequal (T33).
    Instrument = Data.define(:clock, :price_book) do
      # `clock` is {RunClock::MONOTONIC}, which never jumps backward on an NTP
      # step, so an elapsed measurement is never negative; injectable so a spec
      # can pin it deterministic.
      def initialize(clock: RunClock::MONOTONIC, price_book: PriceBook.default)
        super
      end

      # Run the block and answer BOTH what it took and what it produced.
      #
      # @return [Array(Float, Object)] elapsed monotonic seconds, and the block's
      #   own value
      def timed
        started = clock.call
        result = yield
        [clock.call - started, result]
      end

      # Drain a run's recording journal into a priced {Ledger}. Draining is
      # deliberate and total: the Ledger is built from turn_usage records, and
      # every other record kind (a `ledger_transition`, an `oracle_answer`) rides
      # along and is ignored. A caller that needs to SEE those must tee them
      # before this drain -- inject a `journal_factory:` that mirrors each push
      # into a sink it holds (see {Bench::ArmSweep}, which counts replans that
      # way).
      #
      # @param journal [Lain::Channel] the run's own recording channel
      # @return [Lain::Ledger]
      def price(journal) = price_records(journal.drain.map(&:to_journal))

      # The same fold over records a caller has ALREADY drained -- a fan-out arm
      # collects one journal per worker and merges them before pricing.
      #
      # @param records [Array<Hash>] journal-shaped records
      # @return [Lain::Ledger]
      def price_records(records) = Ledger.from_journal(records, price_book:)
    end
  end
end
