# frozen_string_literal: true

module Lain
  class Provider
    class Admission
      # Who hears that a caller is about to queue for a slot and when it got
      # one. Held in Fiber storage rather than threaded through every provider
      # signature, so it reaches the admission of any call made inside
      # {.with}'s block, including from tasks spawned there, and none made
      # beside it.
      module Listener
        KEY = :"lain.provider.admission.listener"

        # For a caller outside any listener's block.
        module Null
          # @return [nil]
          def self.entering = nil

          # @return [nil]
          def self.admitted = nil

          # @return [nil]
          def self.abandoned = nil

          # @return [nil]
          def self.released = nil
        end

        # @return [#entering, #admitted, #abandoned, #released] the listener set for this fiber, or {Null}
        def self.current = Fiber[KEY] || Null

        # @param listener [#entering, #admitted, #abandoned, #released]
        # @yield with the listener set
        # @return the block's value
        def self.with(listener)
          previous = Fiber[KEY]
          Fiber[KEY] = listener
          yield
        ensure
          Fiber[KEY] = previous
        end
      end
    end
  end
end
