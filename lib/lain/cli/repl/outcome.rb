# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # What a conversation was worth, as the one number a process can exit
      # with. It exists because "did every line come through" is a different
      # question from "drive the conversation", and only one caller has ever
      # needed the answer: `lain chat --non-interactive`, which has no human in
      # front of it to read the refusal that was already rendered.
      #
      # == What counts as finished is an ALLOW-LIST, and it has to be
      #
      # A refusal is the obvious torn turn and is not the only one. A turn that
      # hit `max_tokens` is a sentence cut in half; a `refusal` stop reason is
      # the model declining; a `pause_turn` has not ended at all. All three
      # render text to the terminal, so an attended human sees what happened --
      # and all three used to exit 0, which told a script the run was clean.
      #
      # So this asks the opposite question. {SETTLED} names the two reasons
      # that mean the answer is COMPLETE, and everything else is unfinished by
      # default. The wire enums are non-exhaustive ({Lain::StopReason} says so
      # in as many words, and normalizes the rest to `:unknown`), so a
      # deny-list would silently welcome every reason Anthropic adds next --
      # which is precisely how the three above got through.
      #
      # STICKY, deliberately: a chat that recovers from a torn turn and goes on
      # to a good one still had a turn tear, and a status that forgot it would
      # tell a script the run was clean. There is no way back to {COMPLETED}
      # once a line has failed. (Unreachable under `--non-interactive` today,
      # which runs exactly one line -- it is the property that keeps the answer
      # correct if that ever stops being true.)
      class Outcome
        # A run that reached the end of what it was asked.
        COMPLETED = 0

        # And one that did not. A single number, not a vocabulary: "which turn
        # tore, and why" is the Journal's answer and the terminal's, both of
        # which say more than a status ever could. This exists so a caller with
        # neither -- a script -- can still tell the two apart.
        UNFINISHED = 1

        # The stop reasons that mean the model said everything it had to say.
        # `stop_sequence` belongs here beside `end_turn`: the generation
        # stopped where the CALLER asked it to, which is a completed answer and
        # not an interruption.
        SETTLED = [Lain::StopReason::END_TURN, Lain::StopReason::STOP_SEQUENCE].freeze

        # Records whatever one line produced, and hands it straight back so a
        # call site reads as the single expression it was.
        #
        # ONE PLACE ASKS. {Repl::Ask#settle} asks about the same value for a
        # different purpose -- what the human is owed -- and the two answers
        # must not drift, so this is where a conversation's definition of
        # "unfinished" lives.
        #
        # @param product [Lain::Response, Lain::Error, nil] the line's answer,
        #   the refusal it came back with, or nil where the ask was torn before
        #   it committed one ({CLI::Conductor::Outcome#response} on an
        #   interrupt)
        # @return [Object] `product`, untouched
        def note(product)
          torn unless settled?(product)
          product
        end

        # A line that failed in a way no VALUE describes -- a middleware that
        # broke its own contract, which nothing else here would ever see.
        # Hands the reason back the way {#note} hands its product back, so the
        # one caller stays the single expression it reads as: it renders that
        # reason at the terminal, and marking the tear rides along rather than
        # being a second statement a future edit could drop.
        #
        # @param reason [String] what {Repl#render_missing_response} says
        # @return [String] `reason`, untouched
        def torn_by(reason)
          torn
          reason
        end

        # @return [Integer]
        def exit_status = @unfinished ? UNFINISHED : COMPLETED

        private

        def torn = @unfinished = true

        # A Response, and one that ENDED. Anything else -- an error, a nil, a
        # reason not on the list -- is a turn that did not finish, which is the
        # allow-list's whole point.
        def settled?(product)
          product.is_a?(Lain::Response) && SETTLED.include?(product.stop_reason)
        end
      end
    end
  end
end
