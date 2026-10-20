# frozen_string_literal: true

require "monitor"

module Lain
  module Budget
    # What the children below one agent have spent, and the tokens its live
    # children still hold. A child's token ceiling is reserved when it is
    # granted and traded for its real spend when it settles, so siblings granted
    # from one room cannot together outspend it by more than the bound below.
    #
    # The bound is the room plus one call per child: a call's cost is known only
    # once it is paid, so a child under its ceiling may make one call that
    # passes it.
    #
    # The lock covers the arithmetic alone. Fan-out siblings are fibers under
    # one reactor, and a lock held across a provider call would park every
    # sibling behind the one holding it.
    class Shared
      def initialize
        @monitor = Monitor.new
        @spent = Spent.zero
        @reserved = 0
      end

      # @return [Spent] what every settled child has spent
      def spent = @monitor.synchronize { @spent }

      # @return [Integer] the tokens live children still hold
      def reserved = @monitor.synchronize { @reserved }

      # The grant is computed under the lock, so 2 siblings cannot both read
      # the room before either has reserved from it.
      #
      # @yieldreturn [Ceilings] the child's ceilings, read from the holder's room
      # @return [Reservation]
      def reserve
        @monitor.synchronize do
          ceilings = yield
          tokens = [ceilings.tokens.to_i, 0].max
          @reserved += tokens
          Reservation.new(shared: self, ceilings:, tokens:)
        end
      end

      # @api private
      def settle(tokens, spent)
        @monitor.synchronize do
          @reserved -= tokens
          @spent += spent
        end
      end

      # A child's claim on its holder's room, given back once.
      class Reservation
        attr_reader :ceilings

        def initialize(shared:, ceilings:, tokens:)
          @shared = shared
          @ceilings = ceilings
          @tokens = tokens
          @open = true
          @monitor = Monitor.new
        end

        # @param spent [Spent] what the child spent, its own children included
        # @return [self]
        def settle(spent)
          @shared.settle(@tokens, spent) if closed!
          self
        end

        def release = settle(Spent.zero)

        private

        def closed! = @monitor.synchronize { @open.tap { @open = false } }
      end

      # The holder no agent stands behind: it grants what it is asked and
      # keeps no account.
      module Null
        def self.spent = Spent.zero
        def self.reserved = 0
        def self.reserve = Reservation.new(shared: self, ceilings: yield, tokens: 0)
        def self.settle(_tokens, _spent) = nil
      end

      # A builder's reservation before any grant: nothing to give back.
      module Unreserved
        def self.settle(_spent) = self
        def self.release = self
      end
    end
  end
end
