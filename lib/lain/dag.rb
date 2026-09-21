# frozen_string_literal: true

module Lain
  # Orders over one Store's event DAG. A Timeline is an element of an order,
  # not its owner: the order belongs to the Store the Timelines point into, so
  # it answers questions about two of them rather than living on either.
  # {Dag::RenderAncestry} is the render edge alone.
  module Dag
    # Two Timelines over different Stores share no DAG, so no order can compare
    # them; every order refuses by name rather than answering the bottom.
    class CrossStore < Error; end

    def self.same_store!(one, other)
      return if one.store.equal?(other.store)

      raise CrossStore, "cannot compare Timelines backed by different stores"
    end
  end
end
