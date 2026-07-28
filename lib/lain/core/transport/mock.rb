# frozen_string_literal: true

module Lain
  module Core
    module Transport
      # The minimum a {Transport} can be: it is HANDED an already-connected
      # socket, so it provisions nothing, spawns nothing, and kills nothing.
      #
      # That poverty is the point. A client built over this has no process to
      # TERM, so any teardown that only works because a daemon died shows up as
      # a hang rather than as a passing test -- which is exactly the shape a
      # transport that attaches to someone else's daemon has in production.
      # Lib-resident for the same reason {Provider::Mock} is: it stands in for a
      # contract, so it must not be free to drift from one.
      class Mock
        # What {#stop} reports when a spec does not care. Deliberately not a
        # `Process::Status` -- the contract's return is "something that
        # describes the termination", and pinning a Status here would smuggle
        # {Child}'s process-owning shape back into the minimum.
        DEFAULT_TERMINATION = "mock transport released"

        # @param socket [IO] connected already; the builder keeps ownership of
        #   the far end and of closing this one if the client never does
        # @param termination [Object] what {#stop} returns, and therefore what
        #   {Core::Died} says when this transport's wire dies
        def initialize(socket:, termination: DEFAULT_TERMINATION)
          @socket = socket
          @termination = termination
          @starts = 0
          @stops = 0
        end

        # Counted so a spec can pin the double-{#stop} the contract allows:
        # {Client#perish} and {Client#stop} both send it.
        attr_reader :starts, :stops

        # @return [IO] the connected socket, ownership passing to the caller
        def start
          @starts += 1
          @socket
        end

        # Releases nothing, because this transport provisioned nothing: it was
        # handed its socket, and {#start} passed that on. The attaching case in
        # one line.
        # @return [Object] the termination description, every time
        def stop
          @stops += 1
          @termination
        end
      end
    end
  end
end
