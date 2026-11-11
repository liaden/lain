# frozen_string_literal: true

module Lain
  module Herdr
    # Where a herdr note goes before the chat's screen exists. The resolver and the reporter are
    # built before the terminal, and a note written straight to stdout from their worker thread
    # would land in the middle of the line editor's prompt; so each note is held until {#bind}
    # names the screen's own warning line. A chat that never builds a terminal (a refusal before
    # the screen opens) drops what it held, by intent: nothing could show the note without
    # scribbling where no screen was promised.
    class HeldNotes
      def initialize
        @guard = Mutex.new
        @held = []
        @say = nil
      end

      # @param line [String]
      # @return [nil]
      def puts(line)
        @guard.synchronize { @say ? @say.call(line) : @held << line }
        nil
      end

      # @param say [#call] takes 1 line, the screen's warning
      # @return [self]
      def bind(say)
        @guard.synchronize do
          @say = say
          @held.each { say.call(_1) }
          @held.clear
        end
        self
      end
    end
  end
end
