# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # Wiring's one herdr collaborator: everything herdr touches in a chat reaches it through this
      # object, because Wiring has no line to spare for a keyword apiece. It hands the reporter the
      # chat's screen once the terminal is built (notes go to the terminal's warning line, the message
      # is masked by the notifier, whose secrets are the chat's own) by wrapping the terminal factory,
      # the one place both exist; and it answers focus from the same resolver the reporter reads. A
      # Wiring built without a launch gets {Null}: the stock terminal and tmux's own focus.
      class HerdrBinding
        # What a {Wiring} built without a launch uses: the stock terminal and tmux's own focus.
        class Null
          # @param tty_factory [#call] builds the terminal
          # @param env [#[], #slice] the chat process's environment
          def initialize(tty_factory: Frontend::TTY.public_method(:new), env: ENV)
            @tty_factory = tty_factory
            @env = env
          end

          attr_reader :tty_factory

          def focus = Frontend::Focus.tmux(env: @env)

          # @return [TmuxSurface]
          def window_surface = TmuxSurface.new

          # @return [Herdr::Reporter::Null]
          def reporter = Herdr::Reporter::Null.new

          # @return [Sink::Null]
          def notes = Sink::Null.new
        end

        # @return [Herdr::Reporter]
        attr_reader :reporter

        # @return [HeldNotes] the chat's own notes line, shown on the terminal's warning line once it is built
        attr_reader :notes

        # @param notes [HeldNotes] the sink the resolver and the reporter write to
        # @param reporter [Herdr::Reporter]
        # @param resolver [Herdr::Target::Resolver] the one the reporter reads, asked again for focus
        # @param env [#[], #slice] the chat process's environment
        def initialize(notes:, reporter:, resolver:, env: ENV)
          @notes = notes
          @reporter = reporter
          @resolver = resolver
          @env = env
        end

        # @return [#focused?] whether the human is at the chat's window, by where the chat runs
        def focus = Frontend::Focus.for(env: @env, resolver: @resolver)

        # @return [WindowSurface::Lazy] chooses once, on first use, so the probe and its note are not repeated
        def window_surface = @window_surface ||= WindowSurface::Lazy.new(resolver: @resolver, notes: @notes)

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
          tty.mask_with(notifier.mask)
          @notes.bind(tty.method(:render_warning))
        end
      end
    end
  end
end
