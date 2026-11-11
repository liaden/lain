# frozen_string_literal: true

module Lain
  module Approval
    class Judge
      # What lain resolved each stage of a bash call to, told to the judge as
      # lines it did not write: which file a name runs, who could have put it
      # there, and what it shadows. A program name says what a command means to
      # run; these say what will. A stage that changed this session, did not
      # resolve or ran past an anomaly bars the call ({#bar}), so the judge is
      # never asked about it and no line says so.
      #
      # Every name and path is printed bare only while it holds nothing but
      # path-safe characters, and inspected otherwise, so a file named to look
      # like a prompt line or a tag reads as one quoted string.
      class Facts
        HEADER = "facts (computed by lain, not by the model):"
        GUIDANCE = "A command name runs the file shown in the facts block, not the program its name suggests. " \
                   "A stage that is not [system] is a reason to DEFER."
        MASKED = "hidden from the command by its sandbox: %<paths>s"
        HISTORY = "a value a sensitive file ever held in git history is masked in the command's output"
        PLAIN = %r{\A[\w./+@:,=%~-]+\z}
        UNCHANGED = "unchanged since before session"
        SWAPPABLE = %i[user project].freeze
        private_constant :PLAIN, :UNCHANGED, :SWAPPABLE

        # @param executables [Array<Shell::Executable>] one per stage of the call
        # @param masked [Array<String>] absolute; what the call's sandbox hides from it
        # @param history [Boolean] whether its output is masked for what git history held
        def initialize(executables, masked: [], history: false)
          @executables = executables.dup.freeze
          @masked = masked.map(&:-@).freeze
          @history = history
          freeze
        end

        NONE = new([])

        # Appended to the judge's prompt as is: empty when there is no stage, so
        # a prompt without facts is the prompt from before they existed.
        #
        # @return [String]
        def to_s
          return "" if @executables.empty? && @masked.empty? && !@history

          "\n#{HEADER}\n#{lines.join("\n")}\n\n#{GUIDANCE}\n"
        end

        # @return [Array<String>] why no machine may approve it, one reason per stage, run file or anomaly
        def bar = Shell::Executable.bar(@executables)

        # @param masked [Array<String>] absolute; what the call's sandbox hides from it
        # @param history [Boolean] whether its output is masked for what git history held
        # @return [Facts] these, and what the sandbox keeps from the call
        def masking(masked, history:) = Facts.new(@executables, masked:, history:)

        # @return [Array<String>] one per program and run file, each once, then what is masked
        def lines = [*@executables.flat_map { |stage| stage_lines(stage) }, *masked_lines].uniq

        private

        def masked_lines
          [(format(MASKED, paths: @masked.map { safe(_1) }.join(", ")) unless @masked.empty?),
           (HISTORY if @history)].compact
        end

        def stage_lines(stage)
          [program_line(safe(stage.name), stage),
           *stage.run_files.map { |file| line(safe(File.basename(file.path)), file.path, tags(file)) }]
        end

        def program_line(name, program)
          line(name, program.realpath || program.resolved, [*tags(program), *shadows(program.shadowed)])
        end

        def line(name, path, tags) = "#{name} -> #{safe(path.to_s)} [#{tags.join("; ")}]"

        def tags(found) = [found.klass.to_s, (UNCHANGED if !found.fresh && SWAPPABLE.include?(found.klass))].compact

        def shadows(paths) = paths.empty? ? [] : ["shadows #{paths.map { |path| safe(path) }.join(", ")}"]

        def safe(text) = PLAIN.match?(text) ? text : text.inspect

        # The facts of a session that asks for them: the shell verdict first,
        # because a stage it does not fully understand has no program lain could
        # name, and then the session's one resolver, bound where the call runs.
        class Resolving
          FAULT_RULE = "judge facts"
          TOOL = "bash"
          IGNORED = ->(_fault, tool_use_id:) {}
          private_constant :FAULT_RULE, :TOOL, :IGNORED

          # @param verdict [#call] the session's {Shell::Verdict}
          # @param stages [#executables] the ladder's classifier factory, which
          #   binds the session's resolver to its worker's env
          # @param faults [#call] `(fault, tool_use_id:)`, told why a stage
          #   could not be resolved ({Escalation::Faults})
          def initialize(verdict:, stages:, faults: IGNORED)
            @verdict = verdict
            @stages = stages
            @faults = faults
            freeze
          end

          # A fact that cannot be computed is told as unresolved, never dropped.
          #
          # @param command [String]
          # @param cwd [String] absolute; where the command runs
          # @param tool_use_id [String, nil] the call's, so a fault joins its ruling
          # @param parsed [Shell::Parse::Result, nil] the gate's parse of the command, judged rather than parsing again
          # @return [Facts]
          def call(command, cwd, tool_use_id: nil, parsed: nil)
            decision = parsed ? @verdict.of(parsed) : @verdict.call(command)
            # An interpreter stage reaches the judge, but the Verdict names no program for it, so it stays unresolved.
            # A runner never reaches the judge, as Named reads it as opaque; wrapper facts come with changing that.
            return unresolved(command) unless decision.allow?

            Facts.new(@stages.executables(decision.term, cwd))
          rescue StandardError => e
            faulted(e, tool_use_id)
            unresolved(command)
          end

          private

          def unresolved(command) = Facts.new([Shell::Executable.unresolved(command)])

          # Evidence about the facts must never cost the call.
          def faulted(error, tool_use_id)
            fault = Escalation::Faults::Broken.of(Ladder::Fault.for(rung: FAULT_RULE, error:), tool: TOOL)
            @faults.call(fault, tool_use_id:)
          rescue StandardError
            nil
          end
        end

        # The facts of a session that was not asked for them: none.
        module Off
          # @param _command [String]
          # @param _cwd [String]
          # @return [Facts]
          def self.call(_command, _cwd, **) = NONE
        end
      end
    end
  end
end
