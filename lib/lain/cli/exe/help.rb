# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # `--help` written AFTER a command name, which Thor routes for a SUBCOMMAND
      # class and not for a command declared here. `map HELP_MAPPINGS => :help`
      # (thor.rb:660) only ever matches argv's FIRST token, so `lain chat --help`
      # reached the option parser as an ordinary switch: an arity error before
      # {Boundary} declared `check_unknown_options!`, and `Unknown switches
      # "--help"` after it. The second is the worse sentence of the two -- it tells
      # a human that a gesture they type constantly is not a thing, while
      # `lain help chat` answers perfectly well.
      #
      # Not a courtesy invented here: Thor's own `subcommand` wrapper already does
      # it one layer down (`invoke_args.unshift "help" if opts.delete("--help") ||
      # opts.delete("-h")`, thor.rb:337), which is exactly why `qa-lain survey --help`
      # worked while `lain chat --help` did not. This gives the commands declared on
      # THIS class the same answer, off the same HELP_MAPPINGS.
      #
      # In `dispatch` and deliberately NOT in {Argv#start}: the forwarded tail is
      # that module's whole subject, and nothing about help may perturb it. Only the
      # span BEFORE `--` is read here, so `lain up -- --help` still forwards
      # `--help` to the chat window verbatim.
      module Help
        def dispatch(meth, given_args, given_opts, config)
          super(meth, help_instead(meth, given_args) || given_args, given_opts, config)
        end

        # The `help COMMAND` argv an invocation is really asking for, or nothing.
        #
        # A nil command name is what says this is argv's own dispatch: `invoke`
        # names the command it wants, and its arguments do not begin with one.
        #
        # @param meth [String, nil]
        # @param given_args [Array<String>]
        # @return [Array<String>, nil]
        def help_instead(meth, given_args)
          return nil unless meth.nil?

          asked = given_args[0...(given_args.index("--") || given_args.length)]
          name = asked.first.to_s
          return nil unless all_commands.key?(name) && !subcommands.include?(name)

          ["help", name] if Thor::HELP_MAPPINGS.intersect?(asked.drop(1))
        end
      end
    end
  end
end
