# frozen_string_literal: true

module Lain
  class Tool
    # Runs a tool's walk on its own thread, joined from the calling fiber.
    #
    # A walk calls Dir.glob, Dir.each_child, File.lstat and File.foreach, and no
    # fiber scheduler hook offloads any of them, so on the reactor's thread one
    # search holds every other fiber -- the HUD, the input pane, a signal's grace
    # countdown -- until it ends. Joining a thread is a hook the scheduler does
    # take, so the reactor keeps running while the walk does.
    module Offload
      # Matching lines is Ruby code, which hands the lock between threads over
      # only when its time slice ends; MRI shortens a slice by halving it per
      # step below zero, so the reactor gets a turn about every 12ms, not 100ms.
      # The trade: while the reactor is itself busy running Ruby, the walk runs
      # about 3 times slower; while the reactor waits, as it mostly does, the
      # walk loses nothing.
      PRIORITY = -3

      # An error inside the work reaches the caller from {Thread#value}; a stop
      # of the waiting task kills the thread, whose own ensure blocks then run.
      #
      # @yieldreturn [Object] what the call answers
      # @return [Object] the block's value
      def self.call(&work)
        thread = Thread.new do
          # Re-raised to the caller, so a report on stderr would only scribble
          # over the frontend's pane.
          Thread.current.report_on_exception = false
          Thread.current.priority = PRIORITY
          yield
        end
        thread.value
      ensure
        thread&.kill&.join
      end
    end
  end
end
