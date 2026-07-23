# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # The `you>` command registry (T9): named lib-side commands the Repl
      # consults BEFORE the skill middleware, so a registered `/word` runs with
      # zero model turns while every other line -- prose, a path, `@role/skill`,
      # an UNREGISTERED `/word` -- falls through to {Middleware::SkillDispatch}
      # unchanged. Commands shadow skills only when registered: precedence is
      # command-first by design, and the namespace stays honest because two
      # COMMANDS colliding is a loud {Collision} at wiring time.
      class Registry
        include Enumerable

        # Two commands claiming one name is a wiring bug, never a quiet
        # last-write-wins: the second register raises at assembly, not at use.
        class Collision < Error; end

        def initialize(commands = [])
          @commands = {}
          commands.each { |command| register(command) }
        end

        # Later command cards land as exactly one require (cli/command.rb) plus
        # one register call in {Wiring}; returns self so those reads chain.
        def register(command)
          raise Collision, "command #{command.name.inspect} is already registered" if @commands.key?(command.name)

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

        # The registry curried over the session's one {Env} -- what Wiring hands
        # the Repl, so the Repl dispatches with text alone and never holds (or
        # reaches into) the Env; later cards extend the Env by editing Wiring
        # only.
        Bound = Data.define(:registry, :env) do
          def dispatch(text, &fallthrough) = registry.dispatch(text, env, &fallthrough)
        end

        def bind(env) = Bound.new(registry: self, env:)

        private

        # A command blowing up mid-call must not kill the session (panel fix
        # 2): a returned-garbage command is already recovered loudly at the
        # Repl boundary, and a RAISING one deserves the same. A non-Lain raise
        # wraps into an ATTRIBUTED Lain::Error -- named for the command, so the
        # boundary's render says who failed -- while a Lain::Error is already
        # loud and renderable and passes through untouched (a command's own
        # refusal keeps its own words).
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
        # would: the Repl's dispatch boundary renders it and loops.
        def command_invocation(text)
          invocation = Skill::Invocation.parse(text)
          invocation if invocation&.inline? && @commands.key?(invocation.skill)
        end
      end
    end
  end
end
