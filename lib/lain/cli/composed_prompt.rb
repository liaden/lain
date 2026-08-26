# frozen_string_literal: true

module Lain
  module CLI
    # Where the next human line comes from, including its detour through the
    # editor. Its own object because C-g opening a draft in nvim gave "read the
    # prompt" a round trip, a re-prompt loop, and a key binding -- three
    # responsibilities {Repl} does not otherwise have.
    #
    # The split that matters is WHERE the wait happens. A key handler runs on
    # Reline's own input loop, and Reline re-traps SIGINT for the duration of a
    # read -- so lain's trap runs only from that loop, and a handler that blocks
    # has nothing left to interrupt it. The handler therefore only records
    # intent and returns; the wait lives here, in the caller's loop, where
    # {Conductor::PromptBreaker}'s Interrupt can still reach it.
    class ComposedPrompt
      # @param conductor [#read_prompt] reads through the conductor so an idle
      #   prompt signal breaks out cleanly, exactly as a bare read did
      # @param tty [#render_warning] the one surface a lost draft or a lost key
      #   can be reported on
      # @param compose [Frontend::Neovim::Compose] the round trip; its Null
      #   shape is a pass-through, so a chat with no editor takes the same path
      # @param text [String] the prompt string, unchanged from the bare read
      def initialize(conductor:, tty:, compose:, text: "you> ")
        @conductor = conductor
        @tty = tty
        @compose = compose
        @text = text
      end

      # Binding is a separate call rather than constructor work: it mutates
      # process-global Reline state, and an object that rebinds the human's
      # keyboard merely by being constructed cannot be built in a spec, or
      # twice, without surprise.
      #
      # `unless bound?` because a second chat in one process meets a refusal,
      # not a rebind. The rescue leads with the CONSEQUENCE, because KeyTaken's
      # own message says only which mechanism refused, never that C-g is dead
      # -- and losing the compose key must never cost the session.
      def bind_key
        return if Frontend::LineEditor.bound?(KEY)

        Frontend::LineEditor.bind(KEY) { |draft| @compose.open(draft) }
      rescue Frontend::LineEditor::KeyTaken => e
        @tty.render_warning("compose key unavailable: #{e.message}")
      end

      # A compose that was abandoned or timed out sends NOTHING: it yields the
      # draft, which is rendered so the human can still see and re-use their
      # text, and the prompt is read again. Iterative rather than recursive --
      # an abandon never dispatches, so nothing else bounds how many times a
      # human may go round.
      #
      # The loop turns on whether the block FIRED, never on the value: a
      # pass-through returns nil at EOF, and looping on the value would spin
      # against a closed stdin forever.
      #
      # @return [String, nil] the line to dispatch, or nil at EOF
      def read
        text = nil
        @again = true
        while @again
          @again = false
          text = @compose.settle(@conductor.read_prompt(@tty, @text), &method(:keep))
        end
        text
      end

      # Returns nil, and that is not incidental: {Compose#settle} answers with
      # whatever this block returns, so anything truthy here would be dispatched
      # as the human's message -- sending the very draft they abandoned. An ivar
      # rather than a closed-over local because the block is now a method; the
      # prompt is read on one thread, so there is nothing to race.
      def keep(draft)
        @again = true
        @tty.render_warning("draft kept: #{draft}")
        nil
      end

      # C-g, one of exactly two keys free across every keymap lain binds.
      KEY = "C-g"
    end
  end
end
