# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  module Memory
    # The one mutable holder of a live {Memory::Index}, single-threaded like
    # {Agent::Accounting}. `Index#write` is pure -- it returns a new Index and
    # leaves its receiver untouched -- so something has to hold "the current one"
    # for a session's tools to share.
    #
    # #fetch delegates to the current snapshot, so a Recorder satisfies the same
    # duck a bare Index does: {Tools::MemoryRead.new(index: recorder)} needs no
    # constructor change, and a read constructed against the Recorder always sees
    # the most recent write.
    #
    # Deliberately NOT a singleton: two Recorders sharing an underlying Store is
    # a legitimate bench arm. The real invariant -- "the Agent wires exactly one
    # Recorder into a session's tools" -- is a wiring fact the caller owns, not
    # something this class could check without also deciding who else is allowed
    # to hold a reference.
    #
    # A Recorder IS a session's VIEW of the project memory store: the items the
    # store held when this session loaded ({#loaded}), plus the writes made
    # since. {#write} appends to both, so an item written here outlives the
    # session, while another chat's concurrent write does not join this view
    # and cannot move a root this session already recorded.
    class Recorder
      # @param index [Index] the view's starting snapshot, which must be what
      #   `loaded` renders as ({ProjectStore::Loaded#index}) or the session's
      #   own file will not replay to the roots it records
      # @param store [#append] where a write lands durably; {ProjectStore::Null}
      #   keeps nothing, which is what a child, a bench run and a bare Recorder
      #   all want
      # @param loaded [ProjectStore::Loaded] the store version this view opened
      #   on, journaled once as {Telemetry::MemoryLoaded}
      def initialize(index: Index.empty, store: ProjectStore::Null, loaded: ProjectStore.empty)
        @index = index
        @store = store
        @loaded = loaded
      end

      # The current snapshot. Exposed (rather than just #root) so a caller can
      # #checkout an earlier root to inspect what a prior write superseded.
      attr_reader :index, :loaded

      delegate :root, :fetch, to: :index

      # Swaps in the Index that results from writing item, and returns the new
      # root -- the one fact a caller (the memory_write tool) needs to report.
      #
      # The store first, the view second: a store that refuses the write leaves
      # the view where it was, rather than rendering an item nothing durable
      # holds.
      def write(item)
        Ownership.permit!(item, index.key?(item.id) ? fetch(item.id) : nil)
        @store.append(item)
        @index = folded(index.to_a + [item])
        root
      end

      # The view follows the chain. A `/rewind` past a memory_write drops it
      # from what this session renders, because the view IS the load plus the
      # writes the CURRENT chain carries -- and a session showing the model a
      # memory its own record says is gone is a manifest that changes across a
      # resume with nothing to announce it.
      #
      # ONE FOLD, over the load AND the chain together. A resumed chain carries
      # turns whose writes the load already holds; folding them a second time
      # would move the root while the content stayed put, and the recorded root
      # is what a replay has to reproduce. {ProjectStore::Loaded.of} resolves
      # the two together -- last write per id, id order -- so a chain that wrote
      # nothing the load lacks lands exactly on the load's own root, however
      # many of its turns the timeline carries.
      #
      # Nothing goes back to the store: a rewound entry stays durable, where the
      # next fresh chat still sees it.
      #
      # @param timeline [Lain::Timeline] the chain as the rewind left it
      # @return [String, nil] the new root
      def follow(timeline)
        @index = folded(loaded.items + Writes.new(timeline.ancestors.to_a.reverse.map(&:content)).to_a)
        root
      end

      private

      # The SAME Store throughout, so every root this view ever stood on stays
      # resolvable through `Index#checkout` -- what {Tools::MemoryWrite} promises
      # a caller about the version it superseded.
      def folded(items) = ProjectStore::Loaded.of(items).index(store: index.store)
    end
  end
end
