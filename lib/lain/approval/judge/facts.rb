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

        # A project script that runs its interpreter is a wrapper of it, named with what it shadows; its run file
        # line would only repeat it.
        def stage_lines(stage)
          scripts = stage.wrappers.select { _1.klass == :project }
          [program_line(safe(stage.name), stage), *scripts.map { program_line(safe(_1.name), _1) },
           *run_file_lines(stage.run_files.reject { |file| scripts.any? { _1.resolved == file.path } })]
        end

        def run_file_lines(files) = files.map { |file| line(safe(File.basename(file.path)), file.path, tags(file)) }

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
        # Given a reader of the command's words, it reads them instead, scripts
        # and substitutions included, and names what they cannot as unresolved.
        class Resolving
          FAULT_RULE = "judge facts"
          TOOL = "bash"
          IGNORED = ->(_fault, tool_use_id:) {}
          AS_LENT = ->(lent) { lent }
          GIT_CONFIG = "GIT_CONFIG_GLOBAL"
          private_constant :FAULT_RULE, :TOOL, :IGNORED, :AS_LENT, :GIT_CONFIG

          # @param verdict [#call] the session's {Shell::Verdict}
          # @param stages [#executables] the ladder's classifier factory, which
          #   binds the session's resolver to its worker's env
          # @param faults [#call] `(fault, tool_use_id:)`, told why a stage
          #   could not be resolved ({Escalation::Faults})
          # @param runs [#executables] what a command's words run, as
          #   `Tools::Bash::ShellRuns` reads them; the verdict alone by default
          # @param received [#call] `lent -> Hash`, the env a child handed the worker's env holds, beside lain's
          #   own lend (`Exec::ChildEnv#received_unlent`); the worker's env as it is by default
          def initialize(verdict:, stages:, faults: IGNORED, runs: NoReader, received: AS_LENT)
            @verdict = verdict
            @stages = stages
            @faults = faults
            @runs = runs
            @received = received
            freeze
          end

          # @return [Boolean] true: an opaque call may be weighed on these facts
          def routes? = true

          # A fact that cannot be computed is told as unresolved, never dropped.
          #
          # @param command [String]
          # @param cwd [String] absolute; where the command runs
          # @param tool_use_id [String, nil] the call's, so a fault joins its ruling
          # @param parsed [Shell::Parse::Result, nil] the gate's parse of the command, judged rather than parsing again
          # @return [Facts]
          def call(command, cwd, tool_use_id: nil, parsed: nil)
            read = read(command, cwd)
            return Facts.new(read) if read

            decision = parsed ? @verdict.of(parsed) : @verdict.call(command)
            decision.allow? ? Facts.new(@stages.executables(decision.term, cwd)) : unresolved(command)
          rescue StandardError => e
            faulted(e, tool_use_id)
            unresolved(command)
          end

          private

          # Read whatever the verdict says, since a verdict's term never opens a `-c` script. A command whose
          # words show no program still runs something, so it is one unresolved stage rather than a clear bar.
          #
          # @return [Array<Shell::Executable>, nil] nil when nothing reads the command's words
          def read(command, cwd)
            env = -> { @received.call(@stages.environment) }
            programs = @runs.executables(command, env:) do |argv|
              @stages.executables(Shell::Term.of(argv), cwd).first
            end
            programs&.then { _1.empty? ? [Shell::Executable.unresolved(command)] : with_git_config(_1, env.call, cwd) }
          end

          # A lent global git config is git's to read, so it is held to a run file's freshness rather than barred.
          def with_git_config(programs, received, cwd)
            config = received[GIT_CONFIG]
            return programs if config.to_s.empty?

            programs.map { git?(_1) ? reading(_1, @stages.run_file(config, cwd)) : _1 }
          end

          # Compared in place rather than held in a constant: the git-spawn scan reads a constant holding git as a
          # spawn site, and this one only names a file.
          def git?(program) = File.basename(program.realpath || program.resolved || "") == "git"

          def reading(program, file) = Shell::Executable.new(**program.to_h, run_files: [*program.run_files, file])

          def unresolved(command) = Facts.new([Shell::Executable.unresolved(command)])

          # Evidence about the facts must never cost the call.
          def faulted(error, tool_use_id)
            fault = Escalation::Faults::Broken.of(Ladder::Fault.for(rung: FAULT_RULE, error:), tool: TOOL)
            @faults.call(fault, tool_use_id:)
          rescue StandardError
            nil
          end
        end

        # The words of a session that does not read them, so the verdict alone names the stages.
        module NoReader
          # @param _command [String]
          # @return [nil] nothing read
          def self.executables(_command, **) = nil
        end

        # The route of an opaque call nobody asked to weigh: none, so it is never weighed.
        module Unrouted
          # @return [Boolean] false
          def self.routes? = false
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
