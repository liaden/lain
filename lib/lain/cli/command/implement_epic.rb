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
        # so is not something anybody does mid-chat. Typed, it outranks both
        # `[epics] width` and the width the driver derives from where its models
        # run; UNTYPED it is not spelled here at all, so that order stays stated
        # in one place ({EpicDriver::Run.width_for}) instead of being pre-empted
        # by a default this command invented. The budget stays a construction
        # seam -- it is a bench's question, not a prompt's.
        FLAGS = %w[--width].freeze

        def name = "implement-epic"

        def usage = USAGE

        # @param args [String] the line after the verb
        # @param env [Env] the run's collaborators
        # @return [String] what the run came to
        # @raise [Error] when this chat is in no epic
        # @raise [Lain::Error] when the width is not a positive whole number
        def call(args, env)
          env.epic_driver.run(**width(args.to_s), resumed: resumed?(env.journal_path)).to_s
        end

        private

        # A chat resumed mid-epic -- after a crash, most often -- is carrying on
        # the run its issue branches belong to, so the driver keeps them rather
        # than asking. The session's own header is what says so: a resumed chat
        # opens its file chained to the one it resumed.
        def resumed?(path)
          Array(path).select { |file| File.file?(file) }.any? do |file|
            Lain::Journal.records(File.foreach(file), type: Lain::SessionRecord::HEADER_TYPE).first.to_h
                         .key?("resumed_from")
          end
        end

        # {Command::Args} does this command's reading now -- it is what makes
        # `/implement-epic plans --wdith 1` name `--wdith` rather than reading
        # `plans` as though this command took a path. Refused rather than
        # defaulted: a human who typed a width meant it, and driving the epic
        # at some other number because the word was misspelled is the kind of
        # quiet substitution that is found three issues later.
        def width(args)
          parsed = Lain::CLI::Command::Args.parse(args, name:, usage: USAGE, flags: FLAGS, positionals: 0)
          return {} unless parsed.pairs.key?("width")

          value = parsed.pairs["width"]
          raise Error, "#{name} takes only --width N -- #{USAGE}" if value.nil? || value.start_with?("--")

          { width: positive!(value) }
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
