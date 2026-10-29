# frozen_string_literal: true

module Lain
  module Frontend
    class TTY
      # A dim "working… 3s" line on the row below the last output while the model
      # or a tool is silent. It is never given a newline, so erasing it leaves
      # nothing in the scrollback.
      class Indicator
        INTERVAL = 1

        # @param output [#print, #flush] where the line is drawn; {TTY} hands it the writer
        #   that holds the same lock as every other print
        # @param theme [Theme] paints the line with the `label` token
        # @param clock [#call] monotonic seconds
        # @param tty [Boolean] a pipe gets no cursor escapes, so nothing is drawn
        # @param interval [Numeric] seconds between redraws, and the quiet time before the first
        def initialize(output:, theme:, clock: RunClock::MONOTONIC, tty: output.tty?, interval: INTERVAL)
          @output = output
          @theme = theme
          @clock = clock
          @tty = tty
          @interval = interval
          @guard = Mutex.new
          @label = nil
          @started = nil
          @drawn = false
          @ticker = nil
        end

        # Arms the ticker; nothing shows until a full interval has passed.
        def start(label = "working")
          @guard.synchronize do
            @label = label
            @started = @clock.call
            @ticker ||= Thread.new { loop { sleep(@interval) && tick } } if @tty
          end
        end

        def tick
          @guard.synchronize do
            elapsed = @started && (@clock.call - @started).floor
            draw("#{@label}… #{elapsed}s") if @tty && elapsed && elapsed >= @interval
          end
        end

        # Erases the line and starts the quiet time over, so the next line the
        # human sees is followed by a fresh interval before it shows again. A tick
        # racing the print that follows still cannot draw into the scrollback: both
        # happen under the guard, and the print comes after the erase.
        def clear
          @guard.synchronize do
            @started &&= @clock.call
            erase
          end
        end

        # Disarms for good: the turn is over, and nothing may draw until the next start.
        def stop
          ticker = @guard.synchronize do
            @started = nil
            erase
            @ticker.tap { @ticker = nil }
          end
          ticker&.kill&.join
        end

        private

        def erase
          write("\r#{::TTY::Cursor.clear_line}") if @drawn
          @drawn = false
        end

        def draw(text)
          write("\r#{::TTY::Cursor.clear_line}#{@theme.paint(:label, text)}")
          @drawn = true
        end

        def write(bytes)
          @output.print(bytes)
          @output.flush
        end
      end
    end
  end
end
