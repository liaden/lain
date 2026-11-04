# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # The `you>` command registry: named lib-side commands the Repl
      # consults BEFORE the skill middleware, so a registered `/word` runs with
      # zero model turns while every other line -- prose, a path, `@role/skill`,
      # an UNREGISTERED `/word` -- falls through to {Middleware::SkillDispatch}
      # unchanged. Commands shadow skills only when registered: precedence is
      # command-first by design, and the namespace stays honest because two
      # COMMANDS colliding is a loud refusal at wiring time.
      class Registry
        include Enumerable

        def initialize(commands = [])
          @commands = {}
          commands.each { |command| register(command) }
        end

        # Later command cards land as exactly one require (cli/command.rb) plus
        # one register call in {Wiring}; returns self so those reads chain.
        def register(command)
          # Two commands claiming one name is a wiring bug, never a quiet
          # last-write-wins: the second register raises at assembly, not at use.
          raise Error, "command #{command.name.inspect} is already registered" if @commands.key?(command.name)

          @commands[command.name] = command
          self
        end

        # Registration order, which is also /help's listing order.
        def each(&block)
          return enum_for(:each) unless block_given?

          @commands.each_value(&block)
        end

        # The registered command's result for +text+, or the block's: the
        # fallthrough block IS the unmatched path (SkillDispatch's turf), so no
        # caller ever writes `if registry.matches?`. Only the command CALL is
        # error-guarded (see {#invoke}) -- a raise from the fallthrough block
        # belongs to the middleware chain and its own boundary.
        def dispatch(text, env)
          invocation = command_invocation(text)
          invocation ? invoke(invocation, env) : yield
        end

        # Whether the command +text+ names is ITSELF a reply surface: one that
        # opens its own `human> ` read over the pending questions
        # ({Command::Inbox}). A reply prompt asks it ({HumanReplies::Reply}), so
        # `/inbox` typed there detours into the drain for the parked set rather
        # than opening a second drain for whichever set is oldest.
        #
        # Sent as a message a command MAY not understand, rather than required of
        # all twenty-odd: one command in the set has any use for it, and this asks
        # whether the object answers a message, not what class it is.
        #
        # @param text [String] the line as the human typed it
        # @return [Boolean] false for prose, for a role-bound line, and for every
        #   command that has never claimed to answer a human
        def serves_replies?(text)
          invocation = command_invocation(text)
          command = invocation && @commands.fetch(invocation.skill)
          command.respond_to?(:serves_replies?) && command.serves_replies?
        end

        # Whether the command +text+ names returns a Repl action (`:quit`) rather than an
        # answer. Asked BEFORE the call by a surface that cannot honour an action, because a
        # command that arms something and then returns one would leave it armed.
        #
        # @param text [String] the line as the human typed it
        # @return [Boolean] false for prose, a role-bound line, and every command that never declares it
        def returns_action?(text)
          command = named(text)
          command.respond_to?(:returns_action?) && command.returns_action?
        end

        # What a line typed while a run holds the chat is: a control command
        # acts now, since held behind the run what it acts on is gone or moot,
        # and one with nothing to act on is refused now. Prose, a skill, and
        # every other command wait for `you>`.
        #
        # The refusal is read once and travels with the kind: the queue it
        # reads can change between two reads, and a refusal with nothing to say
        # is worse than either answer.
        #
        # @param text [String] the line as the human typed it
        # @param env [Env] what a control command reads to tell whether it has anything to act on
        # @return [Frontend::Intake::Disposition] kind :control, :refuse or :hold; said is the
        #   refusal for :refuse and the line otherwise
        def disposition(text, env)
          command = named(text)
          return Frontend::Intake::Disposition.new(:hold, text) unless control?(command)

          refusal = command.refusal(env) if command.respond_to?(:refusal)
          Frontend::Intake::Disposition.new(refusal ? :refuse : :control, refusal || text)
        end

        # The registry curried over the session's one {Env} -- what Wiring hands
        # the Repl, so the Repl dispatches with text alone and never holds (or
        # reaches into) the Env.
        Bound = Data.define(:registry, :env) do
          def dispatch(text, &fallthrough) = registry.dispatch(text, env, &fallthrough)

          # Env-free, unlike {#dispatch}: whether a line serves replies is a fact
          # about the COMMAND, decided before anything is called.
          def serves_replies?(text) = registry.serves_replies?(text)

          def returns_action?(text) = registry.returns_action?(text)

          def disposition(text) = registry.disposition(text, env)
        end

        def bind(env) = Bound.new(registry: self, env:)

        private

        # A command blowing up mid-call must not kill the session: a
        # returned-garbage command is already recovered loudly at the Repl
        # boundary, and a RAISING one deserves the same. A non-Lain raise wraps
        # into an ATTRIBUTED Lain::Error -- named for the command, so the
        # boundary's render says who failed -- while a Lain::Error is already
        # loud and renderable and passes through untouched.
        def invoke(invocation, env)
          @commands.fetch(invocation.skill).call(invocation.args, env)
        rescue Lain::Error
          raise
        rescue StandardError => e
          raise Error, "command /#{invocation.skill} failed: #{e.message}"
        end

        # Commands parse with the SAME grammar skills do ({Skill::Invocation}),
        # and only the inline `/word` shape can name a command -- a role-bound
        # `@role/skill` never is. A {Skill::Invocation::Malformed} raise
        # propagates exactly as SkillDispatch's own parse of the same line
        # would.
        def named(text)
          invocation = command_invocation(text)
          invocation && @commands.fetch(invocation.skill)
        end

        def control?(command) = command.respond_to?(:disposition) && command.disposition == :control

        def command_invocation(text)
          invocation = Skill::Invocation.parse(text)
          invocation if invocation&.inline? && @commands.key?(invocation.skill)
        end
      end
    end
  end
end
