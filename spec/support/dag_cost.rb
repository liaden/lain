# frozen_string_literal: true

# The cost of a DAG walk, for a spec that pins work rather than output: a
# bounded walk and a full one answer alike, so only what they read can tell
# them apart. The Rust timeline walks inside the extension and calls no
# `Store#fetch` a double could count, so what it is charged with is the events
# it hands to Ruby, each one a fresh wrapper.
module DagCost
  WALKS = %i[to_a messages ancestor_digests].freeze

  # The events a block reads: every one materialized while it runs, from any
  # store, since a wrapper does not say which store it came from. Collection is
  # off while counting, or a wrapper freed mid-block would read as one never
  # made.
  #
  # @return [Integer]
  def count_dag_reads
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
    trace = TracePoint.new(:c_call) do |point|
      commits += 1 if point.method_id == :commit && point.defined_class == Lain::Ext::Timeline
    end
    trace.enable(&block)
    commits
  end

  # The whole-chain walks a block makes, by the head each walked from. A walk
  # is a call to one of WALKS on a Timeline, which none of them makes of
  # another, or an `#ancestors` walk that reached the root. A caller that stops
  # an `#ancestors` walk early read only part of the chain, which
  # {#count_dag_reads} is the measure of; whether one ran to the end is read
  # off the events it made, so a block that makes events of its own can only
  # make a partial walk read as whole, never the reverse.
  #
  # @return [Hash{String, nil => Integer}]
  def count_walks(&block)
    walks = Hash.new(0)
    ancestry = []
    trace = TracePoint.new(:c_call, :c_return) do |point|
      walk_call(point, walks, ancestry) if point.defined_class == Lain::Ext::Timeline
    end
    paused_collection { trace.enable(&block) }
    walks
  end

  private

  def walk_call(point, walks, ancestry)
    head = point.self.head_digest
    walks[head] += 1 if point.event == :c_call && WALKS.include?(point.method_id)
    return unless point.method_id == :ancestors

    return ancestry.push(live_events) if point.event == :c_call

    made = live_events - ancestry.pop
    length = point.self.length
    walks[head] += 1 if length.positive? && made >= length
  end

  def live_events = ObjectSpace.each_object(Lain::Ext::Event).count

  def paused_collection
    was_disabled = GC.disable
    yield
  ensure
    GC.enable unless was_disabled
  end
end

RSpec.configure { |config| config.include DagCost }
