# frozen_string_literal: true

require "irb"

module Lain
  module CLI
    module Command
      # `/ruby` (T22): inspect the live conversation in Ruby, three arities over
      # one {InspectionBinding}.
      #
      #   /ruby                 opens an embedded IRB console over the binding;
      #                         `exit` returns to chat
      #   /ruby timeline.head   evaluates the expression and renders its inspect
      #   /ruby ./probe.rb      runs the named file against the same binding
      #
      # The expression and file arities RETURN rendered text (a command never
      # prints -- the Repl's boundary renderer delivers it), so an evaluation
      # that raises renders its error rather than tearing down the session: an
      # inspection console shows a typo, it does not die on one. The console
      # arity is the {Console} collaborator's -- injected, so a spec asserts the
      # wiring without driving a live REPL, and so IRB's terminal ownership stays
      # in one small, separately-testable place.
      class Ruby
        RETURNED = "-- returned to chat"

        def initialize(console: Console.new)
          @console = console
          freeze
        end

        attr_reader :console

        def name = "ruby"

        def usage = "/ruby [expr|file] -- inspect live state: bare opens a console, an expr its inspect, a path a file"

        # Bare -> console; an existing path -> that file; otherwise the argument
        # IS the expression. `File.file?` is the disambiguator, not a guess about
        # the text: `timeline.head` names no file, `./probe.rb` does.
        def call(args, env)
          source = args.to_s.strip
          inspection = InspectionBinding.for(env)
          return open_console(inspection) if source.empty?
          return evaluate { inspection.context.eval(File.read(source), source) } if File.file?(source)

          evaluate { inspection.context.eval(source) }
        end

        private

        def open_console(inspection)
          @console.open(inspection)
          RETURNED
        end

        # inspect the value, or render the error: an inspection tool that ended
        # the session on a bad expression would be worse than useless. ScriptError
        # is caught beside StandardError because a syntax slip (`timeline.`) is the
        # ordinary case here, and it is a ScriptError, not a StandardError -- the
        # Registry's own boundary would let it escape.
        def evaluate
          yield.inspect
        rescue ScriptError, StandardError => e
          "#{e.class}: #{e.message}"
        end

        # The real console: an embedded IRB over the inspection binding, mirroring
        # `Binding#irb` but forcing {IRB::StdioInputMethod} -- the deliberate
        # answer to T22's escalation trigger. IRB's default input method is
        # Reline-backed and shares the ONE global `Reline` module and
        # `Reline::HISTORY` the chat's own prompt already owns; nesting it would
        # let a console session pollute (or clobber) the chat's history and
        # prompt state machine. Stdio uses the terminal fds directly, so it never
        # touches Reline at all -- and console I/O reaches the terminal through
        # those streams, never the Channel/Journal. This class writes no terminal
        # byte itself; IRB owns every one, which is why output discipline holds.
        class Console
          def open(inspection)
            IRB.setup(nil, argv: []) unless IRB.initialized?
            workspace = IRB::WorkSpace.new(inspection.context)
            IRB::Irb.new(workspace, IRB::StdioInputMethod.new).run(IRB.conf)
          end
        end
      end
    end
  end
end
