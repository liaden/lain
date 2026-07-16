# frozen_string_literal: true

module Lain
  module CLI
    # The parked-prompt breakout seam. While the human is idle at the `you>`
    # prompt, Reline holds the terminal in a blocking read on the main thread and
    # there is no run for {Agent::Budget#interrupt} to stop -- so a terminating
    # signal there must instead break the readline out, and it must do so without
    # any work in the trap body.
    #
    # PromptBreaker reuses {Shutdown::Ingress}: {#signal} is the SAME single
    # async-signal-safe pipe write the coordinator's is (so {Signals} can route
    # prompt-time traps straight here), and a side thread parked on the pipe's read
    # end turns the byte into a {Break} raised into the prompt thread. The raise
    # runs OFF the trap -- on the watcher thread, at a plain scheduler point -- so
    # nothing forbidden happens in async-signal context; Reline propagates the
    # exception and runs its own terminal-restoring ensure (probe-verified).
    #
    # The raise targets the thread that constructed the breaker, captured as
    # `main:` -- the thread that will be sitting in {Frontend::TTY#prompt}.
    class PromptBreaker
      # Raised into the prompt thread to unblock the readline. An {Interrupt}, not
      # a {StandardError}, so a bare `rescue` or `rescue StandardError` between
      # here and the prompt's own handler cannot swallow the breakout.
      class Break < Interrupt
        attr_reader :input

        def initialize(input)
          super("prompt interrupted by #{input}")
          @input = input
        end
      end

      # @param main [Thread] the thread parked in the prompt's blocking read
      def initialize(main: Thread.current)
        @main = main
        @ingress = Shutdown::Ingress.new
        @thread = Thread.new { watch }
      end

      # Trap-safe: one nonblocking pipe write, IOError-swallowed after {#dispose}
      # -- delegated to the ingress, whose comment carries the full reasoning.
      def signal(name) = @ingress.signal(name)

      # Tear the watcher down: closing the pipe wakes its blocking read as
      # `:retired`, so it returns without raising, and the join is race-free.
      def dispose
        @ingress.dispose
        @thread.join
        self
      end

      private

      # One byte is all the prompt breakout needs: the first signal breaks the
      # readline, after which {Signals} re-routes the next one to the run's
      # coordinator (or a fresh breaker). A closed ingress reads `:retired` -- the
      # {#dispose} path -- and the thread ends without touching the prompt thread.
      def watch
        input = @ingress.read
        @main.raise(Break.new(input)) unless input == :retired
      end
    end
  end
end
