# frozen_string_literal: true

require "fileutils"
require "rbconfig"

module Lain
  module Isolation
    module MergeCoordinator
      # Starts a detached `lain land ...` so a submitter never waits on the
      # landing it queued. The command is the launching binary under the
      # running Ruby, as {CLI::GcSchedule} composes it and for its reason: a
      # `lain` looked up on PATH under `bundle exec` may be some other install.
      # A launcher that is not lain, rspec included, starts nothing.
      class Spawner
        # Detached, so the submitter never waits on the child or leaves it a zombie.
        SPAWN = ->(argv, **options) { Process.detach(Process.spawn(*argv, **options)) }

        # @param spawn [#call] starts `argv` with `Process.spawn` options
        # @param program [String] the launching binary
        # @param ruby [String] the interpreter that runs it
        def initialize(spawn: SPAWN, program: $PROGRAM_NAME, ruby: RbConfig.ruby)
          @spawn = spawn
          @program = program.to_s
          @ruby = ruby
        end

        # Its own process group, so a Ctrl-C at the submitter cannot stop a
        # drainer in the middle of a batch.
        # @param args [Array<String>] lain's arguments, `land drain ...`
        # @param chdir [String] where the child runs
        # @param log [String] the file its output is appended to
        # @return [Boolean] whether a child was started; false when the spawn
        #   itself fails, so the submitter can say how to drain by hand
        def call(args, chdir:, log:)
          return false unless lain?

          FileUtils.mkdir_p(File.dirname(log))
          @spawn.call(command(args), chdir:, in: File::NULL, out: [log, "a"], err: [log, "a"], pgroup: true)
          true
        rescue SystemCallError
          false
        end

        private

        def command(args) = [@ruby, File.expand_path(@program), *args]

        def lain? = File.basename(@program) == "lain"
      end
    end
  end
end
