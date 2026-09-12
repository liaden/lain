# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/implement-epic` at `you>`: work the mounted epic's approved issues to
      # its working branch, and report what landed and what is still waiting.
      #
      # The driving is {EpicDriver::Run}'s and the collaborators are
      # {EpicDriver::Factory}'s; this command is the door onto them, the way
      # {Goal} is the write surface over {GoalDriver}. What it owns is the
      # words: how a width is spelled, and what a human reads back.
      #
      # It is registered in EVERY chat, in an epic or not, and refuses by name
      # where there is nothing to drive -- a command that exists in some
      # sessions and not others is one a human cannot learn.
      class ImplementEpic
        USAGE = "/implement-epic [--width N] -- work the mounted epic's approved issues to its working branch"

        # `--width` is the one knob worth typing: a human watching a run may
        # want the issues taken one at a time, and editing a config file to say
        # so is not something anybody does mid-chat. The budget stays a
        # construction seam -- it is a bench's question, not a prompt's.
        WIDTH = /\A--width[= ]\s*(?<width>\S+)\z/

        def name = "implement-epic"

        def usage = USAGE

        # @param args [String] the line after the verb
        # @param env [Env] the run's collaborators
        # @return [String] what the run came to
        # @raise [EpicDriver::NoEpicMounted] when this chat is in no epic
        # @raise [Lain::Error] when the width is not a positive whole number
        def call(args, env)
          env.epic_driver.run(**width(args.strip)).to_s
        end

        private

        # Refused rather than defaulted: a human who typed a width meant it, and
        # driving the epic at some other number because the word was misspelled
        # is the kind of quiet substitution that is found three issues later.
        def width(args)
          return {} if args.empty?

          matched = WIDTH.match(args)
          raise Error, "#{name} takes only --width N -- #{USAGE}" if matched.nil?

          { width: positive!(matched[:width]) }
        end

        def positive!(value)
          width = Integer(value, exception: false)
          raise Error, "--width takes a whole number of issues above zero, not #{value.inspect}" unless
            width&.positive?

          width
        end
      end
    end
  end
end
