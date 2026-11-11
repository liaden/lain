# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # Hands the herdr reporter the chat's screen once the terminal is built: its notes go to the
      # terminal's warning line, and its message is masked by the terminal's notifier, whose secrets
      # are the chat's own (a committed .env, a passed connection string). It wraps the terminal
      # factory because that is the one place both exist and Wiring has no line to spare.
      class HerdrBinding
        # @param notes [HeldNotes] the sink the resolver and the reporter write to
        # @param reporter [Herdr::Reporter]
        def initialize(notes:, reporter:)
          @notes = notes
          @reporter = reporter
        end

        # @param factory [#call] builds the terminal from {Wiring}'s keywords, `tmux:` the notifier among them
        # @return [#call] the same factory, binding the reporter to what it builds
        def tty_factory(factory = Frontend::TTY.public_method(:new))
          lambda do |**keywords|
            factory.call(**keywords).tap { |tty| bind(tty, keywords.fetch(:tmux)) }
          end
        end

        private

        def bind(tty, notifier)
          @reporter.mask_with(notifier.mask)
          @notes.bind(tty.method(:render_warning))
        end
      end
    end
  end
end
