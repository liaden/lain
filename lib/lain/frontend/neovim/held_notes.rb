# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # Asks the editor how many review notes it holds that were never handed
      # back. They live in the editor's Lua until `:LainNoteDone`, so the count
      # cannot be read from the review model.
      #
      # The ask rides the render rail and the answer returns as an ordinary
      # `lain_command` on the RPC thread, so this waits on a queue the RPC
      # thread fills and never touches nvim itself.
      class HeldNotes
        # Long enough for an editor busy repainting, short enough that a dead
        # one cannot hang the prompt.
        TIMEOUT = 2

        UNANSWERED = "the editor did not say whether review notes are still held -- try again"

        # @param rpc [#ask_review_notes] raises ClosedQueueError (editor gone) or ThreadError (queue full)
        # @param timeout [Numeric] seconds to wait for the editor's answer
        def initialize(rpc:, timeout: TIMEOUT)
          @rpc = rpc
          @timeout = timeout
          @waiting = Concurrent::Map.new
        end

        # @return [Integer] 0 for a detached editor, which holds nothing
        # @raise [Lain::Error] when an attached editor never answers
        def count
          token = SecureRandom.hex(4)
          queue = @waiting[token] = Thread::Queue.new
          @rpc.ask_review_notes(token)
          queue.pop(timeout: @timeout) || raise(Lain::Error, UNANSWERED)
        rescue ClosedQueueError
          0
        rescue ThreadError
          raise Lain::Error, UNANSWERED
        ensure
          @waiting.delete(token)
        end

        # Runs on the RPC thread, so it only hands the number across.
        def answered(token, count) = @waiting[token]&.push(count)
      end
    end
  end
end
