# frozen_string_literal: true

module Lain
  module Frontend
    class Intake
      # The lines kept for `you>`, in the order typed, and where each was typed: what `/held` lists, what a stop
      # clears, and what an answer prompt's own words expire with it.
      class HeldLines
        # `read` names the reader of an answer prompt the line was typed at, nil for any other; a word typed there
        # dies with that read, while a command outlives it.
        Kept = Data.define(:text, :kind, :at, :read, :clock) do
          def dies_with?(reader) = read == reader && !text.start_with?("/")

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
        # @param read [Integer, nil] the answer reader the line was typed at
        def keep(text, kind: nil, read: nil)
          entry = Kept.new(text:, kind:, at: @clock.call, read:, clock: @clock)
          @lock.synchronize { @kept << entry }
        end

        def take = @lock.synchronize { @kept.shift }&.text

        def texts = entries.map(&:text)

        def entries = @lock.synchronize { @kept.dup }

        # @return [Array<String>] what was dropped
        def clear = @lock.synchronize { @kept.slice!(0..) }.map(&:text)

        # @return [Array<Kept>] the entries that died with the reader
        def expire(reader)
          @lock.synchronize do
            gone, @kept = @kept.partition { |entry| entry.dies_with?(reader) }
            gone
          end
        end
      end
    end
  end
end
