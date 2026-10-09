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

        # What a submitter says when {#drain} started nothing.
        BY_HAND = "run `lain land drain --branch %<branch>s` to land it"

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

        # The drainer is handed its project on the command line rather than
        # finding one from its directory, so it journals and verifies for the
        # submitter's project however it was started.
        # @param branch [String] the branch whose queue is drained
        # @param root [String] the repository's main worktree
        # @param home [Home] the branch's coordinator home, where the log goes
        # @return [Boolean] whether a drainer was started
        def drain(branch:, root:, home:)
          call(["land", "drain", "--branch", branch, "--project", root], chdir: root,
                                                                         log: File.join(home.dir, "drain.log"))
        end

        private

        def command(args) = [@ruby, File.expand_path(@program), *args]

        def lain? = File.basename(@program) == "lain"
      end
    end
  end
end
