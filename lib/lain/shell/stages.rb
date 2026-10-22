# frozen_string_literal: true

module Lain
  module Shell
    # The programs a bash command would exec, each resolved in the directory its
    # stage runs in, read off {Named.stages} so the quoting bash undoes is undone
    # once. Builtins are left out: the shell runs them, not a file PATH finds.
    #
    # What it cannot tell it answers {UNKNOWN}, never a guess: the journal reads
    # that as no claim, and a gate that must know what runs refuses it.
    module Stages
      NUL = "\0"
      COMMAND = "command"

      # One exec'd stage: its words, where it runs (nil when a join lets it run
      # where a cd failed to leave), and what those resolve to.
      Stage = Data.define(:argv, :directory, :executable) do
        def placed? = !directory.nil?
      end

      Read = Data.define(:stages) do
        def known? = true
      end

      # What a command whose stages cannot be told answers.
      module UNKNOWN
        def self.known? = false
        def self.stages = []
      end

      module_function

      # @param command [Object] as the model sent it; only a String can be read
      # @param worker_env [WorkerEnv] the call's env, its cwd where the command starts
      # @param resolver [#for] binds to a cwd, so each stage resolves where it runs
      # @param home [String, nil] what a leading `~` names
      # @return [Read, UNKNOWN]
      def of(command, worker_env:, resolver:, home: nil)
        return UNKNOWN unless command.is_a?(String) && !command.include?(NUL)

        placed = Named.stages(Parse.new.call(command), cwd: worker_env.cwd, home:)
        placed ? Read.new(stages: exec_stages(placed, worker_env, resolver)) : UNKNOWN
      rescue SystemCallError, IOError
        UNKNOWN
      end

      # @param input [Object] a bash call's input; its `command` and `cwd` fields are read
      # @param worker_env [WorkerEnv] the session's env, its cwd what the call's own `cwd` resolves against
      # @param resolver [#for]
      # @param home [String, nil]
      # @return [Read, UNKNOWN]
      def for_input(input, worker_env:, resolver:, home: nil)
        directory = Named.directory_of(input, cwd: worker_env.cwd, home:) if input.is_a?(Hash)
        return UNKNOWN unless directory

        of(Named.field_of(input, COMMAND), worker_env: worker_env.with(cwd: directory), resolver:, home:)
      end

      def exec_stages(placed, worker_env, resolver)
        placed.reject { |argv, _| Verdict.builtin?(argv.first) }.map do |argv, directory|
          Stage.new(argv:, directory:, executable: resolved(argv, directory, worker_env, resolver))
        end
      end

      def resolved(argv, directory, worker_env, resolver)
        return Executable.unresolved(argv.first) unless directory

        resolver.for(worker_env.with(cwd: directory)).call(Term.of(argv)).first
      end

      private_class_method :exec_stages, :resolved
    end
  end
end
