# frozen_string_literal: true

module Lain
  module Frontend
    class Intake
      # The lines kept for `you>`, in the order typed, and where each was typed: what `/held` lists and what a stop
      # clears.
      class HeldLines
        Kept = Data.define(:text, :kind, :at, :clock) do
          # @return [Float] seconds since it was kept
          def age = clock.call - at
        end

        def self.dropped(count) = "dropped #{count} held #{count == 1 ? "line" : "lines"}"

        # @param clock [#call] monotonic seconds, the base `/held` reads an age against
        def initialize(clock: RunClock::MONOTONIC)
          @clock = clock
          @lock = Thread::Mutex.new
          @kept = []
        end

        # @param text [String] the line
        # @param kind [Symbol, nil] the kind of prompt published when it was typed
        def keep(text, kind: nil)
          entry = Kept.new(text:, kind:, at: @clock.call, clock: @clock)
          @lock.synchronize { @kept << entry }
        end

        def take = @lock.synchronize { @kept.shift }&.text

        def texts = entries.map(&:text)

        def entries = @lock.synchronize { @kept.dup }

        # @return [Array<String>] what was dropped
        def clear = @lock.synchronize { @kept.slice!(0..) }.map(&:text)
      end
    end
  end
end
