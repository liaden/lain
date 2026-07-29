# frozen_string_literal: true

# Deliberately OUTSIDE spec/support/, for the reason spec/support_matchers_spec.rb
# states in full: spec_helper glob-requires `spec/support/**/*.rb`, and RSpec's
# own discovery `load`s `spec/**/*_spec.rb` without consulting $LOADED_FEATURES,
# so a `_spec.rb` under the support glob registers twice and every example is
# counted twice. This file tests the helper defined at
# spec/support/store_fetch_count.rb, so it lives one level up where only
# discovery finds it. Do not "tidy" it back inside spec/support/.
#
# T14 built that helper and spec/lain/session_record_spec.rb is its first
# consumer, but the contract belongs here rather than buried under an unrelated
# subject: T17 and T20 reuse it. What it measures is a COST, and a broken cost
# meter does not fail loudly -- it reads LOW, and a low reading passes every
# assertion a cost spec makes. So the ways it can lie are the ways its callers
# can go green while regressing.
RSpec.describe StoreFetchCount do
  let(:store) { Lain::Store.new }
  let(:timeline) { Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "a" }]) }

  # Panel probe P3b (Schneeman): a second arming replaces the first's stub, so
  # the first tally stops counting and reads 0 -- and 0 passes. Loud beats
  # convenient, the same reasoning that keeps StringInquirer out of this
  # codebase (CLAUDE.md).
  it "refuses a second tally on a store it is already counting, rather than freezing the first" do
    count_store_fetches(store)

    expect { count_store_fetches(store) }
      .to raise_error(described_class::AlreadyCounting, /already counting/)
  end

  it "names the way out in the refusal, since one store measured twice is the case that hits this" do
    count_store_fetches(store)

    expect { count_store_fetches(store) }.to raise_error(/Tally#reset/)
  end

  # Panel probe P3f: the block form READS as scoped, so it must BE scoped --
  # otherwise a measurement quietly absorbs whatever the example does next.
  it "stops counting when its block returns, so later work is not absorbed" do
    tally = count_store_fetches(store) { store.fetch(timeline.head_digest) }

    store.fetch(timeline.head_digest)

    expect(tally.count).to eq(1)
  end

  it "counts a finished block form as done, so the same store can be measured again" do
    count_store_fetches(store) { store.fetch(timeline.head_digest) }

    expect { count_store_fetches(store) }.not_to raise_error
  end

  # Measuring what a REFUSAL costs is the reuse this helper was built for --
  # `count_store_fetches(store) { scribe.catch_up(diverged) }` is how it reads --
  # so a block that raises has to close its measurement on the way out. Without
  # that the store stays armed and the next arming is refused for a reason that
  # has nothing to do with the caller.
  it "closes the measurement when its block raises, leaving the store free to arm again" do
    expect { count_store_fetches(store) { raise ArgumentError, "boom" } }.to raise_error(ArgumentError)

    fresh = count_store_fetches(store)
    store.fetch(timeline.head_digest)

    expect(fresh.count).to eq(1)
  end

  # Reading the helper's own bookkeeping, which is this example group's own ivar
  # -- the module is mixed into the example, so there is no other object to ask.
  it "stops the abandoned tally when its block raises, rather than counting on past the failure" do
    expect { count_store_fetches(store) { raise ArgumentError, "boom" } }.to raise_error(ArgumentError)
    abandoned = @store_fetch_tallies[store]

    store.fetch(timeline.head_digest)

    expect(abandoned).not_to be_counting
  end

  it "counts calls rather than distinct digests, and only on the store it was given" do
    elsewhere = Lain::Timeline.empty(store: Lain::Store.new).commit(role: :user, content: [])
    tally = count_store_fetches(store)

    2.times { store.fetch(timeline.head_digest) }
    elsewhere.to_a

    expect(tally.count).to eq(2)
  end

  it "resets mid-example, which is how one store is measured across two phases" do
    tally = count_store_fetches(store)
    store.fetch(timeline.head_digest)
    expect(tally.reset.count).to be_zero

    store.fetch(timeline.head_digest)

    expect(tally.count).to eq(1)
  end

  it "passes keyword arguments through to the real fetch, so it wraps any store duck" do
    ducked = Class.new { def fetch(digest, strict: false) = [digest, strict] }.new
    tally = count_store_fetches(ducked)

    expect(ducked.fetch("d", strict: true)).to eq(["d", true])
    expect(tally.count).to eq(1)
  end
end
