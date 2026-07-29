# frozen_string_literal: true

# Counts `Store#fetch` calls, so a spec can pin the COST of a DAG walk and not
# only its result. A walk bounded to the new events and one that re-reads the
# whole chain produce IDENTICAL output, so no assertion over that output can
# tell them apart -- the fetch count is the only observable that can.
#
# Deliberately NOT spec/lain/timeline_spec.rb's `Canonical.digest` stub: that
# counts hashing, which is a different cost from reading the DAG, and it is
# global where this is per store INSTANCE.
#
# `and_wrap_original` leaves the store real -- this measures, it never stubs --
# so the code under test still gets its events and still fails the way it would
# unmeasured.
module StoreFetchCount
  # A second tally on a store already being counted. Named and raised rather
  # than tolerated, because rspec-mocks lets the second `allow` REPLACE the
  # first's stub: the first tally would stop counting and read 0, and 0 passes
  # every assertion a cost spec makes. A cost meter that breaks silently reads
  # LOW, which is the direction that hides a regression.
  class AlreadyCounting < StandardError; end

  # A live tally rather than a returned Integer: a walk's cost is asserted per
  # PHASE (seed the chain, then measure only the pass that follows), so the
  # count has to be readable at any point, not only after one block.
  class Tally
    attr_reader :count

    def initialize
      @count = 0
      @counting = true
    end

    def counting? = @counting

    # A stopped tally ignores the calls that keep arriving: the stub cannot be
    # uninstalled mid-example, so "stopped" is enforced on this side.
    def record
      @count += 1 if counting?
      self
    end

    def reset
      @count = 0
      self
    end

    def stop
      @counting = false
      self
    end

    def to_s = "#{count} Store#fetch call(s)#{", stopped" unless counting?}"
    alias inspect to_s
  end

  # Start counting `store`'s fetches.
  #
  # With no block the tally stays live to the end of the example -- the spelling
  # for a phase you bracket by hand. With a block it is SCOPED: it counts that
  # block and stops when it returns, so a later line in the same example cannot
  # quietly inflate the reading. Either way the Tally comes back, because the
  # count, not the block's value, is the answer being asked for.
  #
  # The `ensure` is the point, not decoration: measuring what a REFUSAL costs is
  # a first-class use here, so the block raising is expected traffic. Leaving
  # the tally live then does double damage -- it counts on past the failure, and
  # the store stays armed, so the next arming is refused for a reason that has
  # nothing to do with its caller.
  #
  # @param store [Lain::Store] counted by identity; other stores are untouched
  # @return [Tally]
  # @raise [AlreadyCounting] when a live tally is already counting this store
  def count_store_fetches(store)
    tally = armed_store_tally(store)
    return tally unless block_given?

    begin
      yield
    ensure
      tally.stop
    end
    tally
  end

  private

  def armed_store_tally(store)
    live = (@store_fetch_tallies ||= {}.compare_by_identity)
    already_counting!(store, live[store])

    Tally.new.tap do |tally|
      live[store] = tally
      allow(store).to receive(:fetch).and_wrap_original do |original, *args, **kwargs, &fetch_block|
        tally.record
        original.call(*args, **kwargs, &fetch_block)
      end
    end
  end

  def already_counting!(store, tally)
    return unless tally&.counting?

    raise AlreadyCounting,
          "#{store.class} #{store.object_id} is already counting fetches; a second tally would replace " \
          "the first's stub and freeze it at #{tally.count}, where a frozen count passes silently. Hold " \
          "the one tally and clear it between phases with Tally#reset."
  end
end

RSpec.configure { |config| config.include StoreFetchCount }
