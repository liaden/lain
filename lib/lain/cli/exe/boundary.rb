# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # The Thor-boundary conventions every command shares: map the lib's own
      # errors (all Lain::Error) onto Thor's exit contract -- clean message to
      # stderr, nonzero exit, no backtrace -- and police trailing argv. One named
      # home rather than a copy per command.
      #
      # `include Boundary` carries a CLASS-level effect as well as these instance
      # methods: {included} declares Thor's `check_unknown_options!` on whatever
      # includes it. That is the same responsibility rather than a second one --
      # policing argv is the half of this module's job that {#refuse_strays!}
      # already does for positionals, and the declaration is what does it for
      # switches. It has to arrive by the `include` because Thor's own
      # `check_unknown_options?` answers false for a registered subcommand NAME, so
      # every nested Thor class needs its own; see {included} for the whole account.
      module Boundary
        # An unknown switch is an unknown switch, on every command class that
        # includes this -- which is the whole CLI, and has to be.
        #
        # Thor's own `check_unknown_options?` answers FALSE for any name registered
        # through `subcommand` (thor.rb:363-380), so one declaration on {LainCLI}
        # would be INERT for `epic`, `review`, `survey` and `bench` -- the four
        # commands a stray switch was actually reaching, because each is a separate
        # `< Thor` class dispatched by name. Undeclared, Thor left the switch in the
        # POSITIONAL remainder: `qa-lain survey PATH --permissive` became an arity
        # error naming `survey open`, a verb the human never typed and which only
        # exists because `default_command :open` lets Thor compose one.
        #
        # The hook rather than a line per class, for the reason this module exists
        # at all: policing trailing argv is already its job ({#refuse_strays!}), and
        # five copies of one declaration is how the fifth subcommand class ships
        # without it.
        #
        # `up`'s post-`--` splat is exempt STRUCTURALLY and needs no `except:`:
        # `Thor::Options#check_unknown!` inspects only the extras collected before
        # the separator index, so a forwarded chat flag is not an unknown switch
        # here. `spec/lain/cli_spec.rb` drives that invocation.
        def self.included(base) = base.check_unknown_options!

        # The one command-body shape every read-only report command shares: say
        # the String the block returns, mapping Lain::Error onto Thor's contract.
        #
        # Ctrl-C ends a report with a clean word and status 130 (128 + SIGINT), the
        # shell's own convention for "this process died to a signal", never a
        # backtrace over a signal the operator sent on purpose. {#exit_status}
        # differs on purpose: Ctrl-C is how a `watch` tail ends, so it exits 0.
        def render(newline: true, &block)
          newline ? say(yield) : say(yield, nil, false)
        rescue Interrupt
          say "interrupted"
          exit 130
        rescue Lain::Error => e
          raise ::Thor::Error, e.message
        end

        # A gate that said no is a failure to a script, so the command's own
        # status follows the words; a zero status leaves Thor's normal return.
        # The command is built inside render because building it can raise a
        # Lain::Error, which render maps onto Thor's contract.
        def render_failing(build)
          said = nil
          render { (said = yield(build.call)).text }
          exit said.status unless said.status.zero?
        end

        # For commands that OWN their exit status (watch): pass the block's
        # integer through exit, with the same Lain::Error mapping; Ctrl-C ends a
        # tail of a SIGKILL'd (never-closed) session -- clean exit, no backtrace.
        def exit_status(&block)
          exit yield
        rescue Interrupt
          exit 0
        rescue Lain::Error => e
          raise ::Thor::Error, e.message
        end

        # tmux follows $TMUX from inside a pane, so no -L is passed.
        def adopt_input_pane(err:)
          return unless ENV["TMUX_PANE"]

          waiting_on = options[:socket] ? nil : derived_input_socket
          reason = Lain::CLI::Up.adopt_input(ENV.fetch("TMUX_PANE"), chat_socket: waiting_on)
          err.puts("lain input: #{reason}") if reason
        rescue Lain::CLI::Up::Error => e
          err.puts("lain input: #{e.message}")
        end

        # The input socket this directory's chat binds. Derived rather than passed
        # because the path carries no pid: both panes name it from the project and
        # the session alone, before either process exists.
        def derived_input_socket
          project = project_override.fetch(:project_factory) { -> { Lain::Project::Resolver.default_project } }.call
          Lain::CLI::InputSocket.path(name: options[:name], cwd: project.cwd)
        end

        # The one journal-pass shape `consolidate` and `improve` share: `--dry-run`
        # picks the METHOD, so the flag stops at the boundary that parsed it instead
        # of travelling into the pass as a boolean that changes what #report means.
        def journal_pass(pass)
          options[:dry_run] ? pass.dry_report : pass.report
        end

        # Positionals a command has no use for. `up` forwards trailing args to the
        # chat window ONLY from past a `--` separator, which {Argv} has already
        # split off by the time this is asked -- so anything still here is a typo,
        # and `lain up /tmp/repo typo` stays a loud error rather than silent
        # pass-through to chat.
        #
        # UNCONDITIONAL, and that is a fix rather than a tidy: this used to return
        # early whenever the invocation carried a `--` ANYWHERE, so
        # `lain up /tmp/repo typo -- --provider x` forwarded "typo" to the chat
        # pane, where it died inside tmux after the session already existed. The
        # `--` gate belonged here only while nothing else knew where the separator
        # was; {Argv#split_forwarded} knows exactly, so this can be absolute.
        def refuse_strays!(strays)
          return if strays.empty?

          raise ::Thor::Error, "unexpected arguments #{strays.inspect} -- pass chat flags after `--`"
        end
      end
    end
  end
end
