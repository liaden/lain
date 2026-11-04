# frozen_string_literal: true

module Lain
  class Sensitivity
    class Bounds
      # The one mutable reference to an agent's {Bounds}. A parent's bounds
      # grow as it leases checkouts to its children, while the policy that
      # reads them is frozen at stack build, so the policy holds this cell and
      # the spawner swaps what it holds. Every read answers a frozen value.
      #
      # One cell belongs to one tool stack. The spawner that builds the stack
      # mints it and hands the same cell to the stack and to the spawners the
      # child's union holds; it is never found by the environment the stack
      # runs in, since an environment can be shared by several stacks.
      class Cell
        # @param bounds [Bounds, Cell] a cell given is held as it is
        # @return [Cell]
        def self.of(bounds) = bounds.is_a?(Cell) ? bounds : new(bounds)

        # @param bounds [Bounds]
        def initialize(bounds)
          @bounds = bounds
          @lock = Mutex.new
        end

        # A read takes no lock: the reference is replaced whole by {#swap}, and
        # every value it can hold is frozen.
        #
        # @return [Bounds] frozen
        attr_reader :bounds
        alias current bounds

        # @yieldparam bounds [Bounds] what the cell holds now
        # @yieldreturn [Bounds] what it holds from now
        # @return [Bounds]
        def swap
          @lock.synchronize { @bounds = yield(@bounds).freeze }
        end
      end
    end
  end
end
