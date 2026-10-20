# frozen_string_literal: true

# The cost of a DAG walk, for a spec that pins work rather than output: a
# bounded walk and a full one answer alike, so only what they read can tell
# them apart. The Rust timeline walks inside the extension and calls no
# `Store#fetch` a double could count, so what it is charged with is the events
# it hands to Ruby, each one a fresh wrapper.
module DagCost
  # Rust's timeline and Ruby's, while both exist.
  COMMITTERS = [Lain::Ext::Timeline, Lain::Timeline].freeze
  WALKS = %i[to_a messages ancestor_digests].freeze

  # The events a block reads out of `store`: the Ruby store's fetches, or every
  # Rust event materialized while it runs, from any store, since a wrapper does
  # not say which store it came from.
  #
  # @return [Integer]
  def count_dag_reads(store, &block)
    return count_store_fetches(store, &block).count unless store.is_a?(Lain::Ext::Store)

    count_materialized_events(&block)
  end

  # Collection is off while counting, or a wrapper freed mid-block would read
  # as one never made.
  #
  # @return [Integer]
  def count_materialized_events
    was_disabled = GC.disable
    before = ObjectSpace.each_object(Lain::Ext::Event).count
    yield
    ObjectSpace.each_object(Lain::Ext::Event).count - before
  ensure
    GC.enable unless was_disabled
  end

  # The commits a block attempts, refused ones included: a commit the store
  # refuses whole leaves no object behind, so the attempt is the only trace.
  #
  # @return [Integer]
  def count_commits(&block)
    commits = 0
    trace = TracePoint.new(:call, :c_call) do |point|
      commits += 1 if point.method_id == :commit && COMMITTERS.include?(point.defined_class)
    end
    trace.enable(&block)
    commits
  end

  # The whole-chain walks a block makes, by the head each walked from. A walk
  # is a call to one of WALKS on a Timeline, which none of them makes of
  # another; `#ancestors` is left out because a caller that stops early reads
  # only part of it, which {#count_dag_reads} is the measure of.
  #
  # @return [Hash{String, nil => Integer}]
  def count_walks(&block)
    walks = Hash.new(0)
    trace = TracePoint.new(:call, :c_call) do |point|
      walking = WALKS.include?(point.method_id) && COMMITTERS.include?(point.defined_class)
      walks[point.self.head_digest] += 1 if walking
    end
    trace.enable(&block)
    walks
  end

  # The expectation that differs between the 2 implementations, by the one the
  # factory builds.
  def on_dag(rust:, ruby:) = Lain::Dag::Factory.implementation == :rust ? rust : ruby
end

RSpec.configure { |config| config.include DagCost }
