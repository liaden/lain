# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "time"

module Lain
  module CLI
    # Once a day, a `lain chat` or `lain up` launch starts one detached
    # `lain worktrees gc` for its project, so what workers leave behind is
    # reaped without anyone remembering to. There is no scheduler: a stamp
    # under {Paths#state_home} records when the last run was started, and a
    # launch that finds it stale renews it and spawns.
    #
    # THE LAUNCHING BINARY, UNDER THE RUNNING RUBY, never `lain` looked up on
    # PATH. A spawned name resolves against the launcher's PATH, which under
    # `bundle exec` holds an installed gem production may not have -- the
    # trap {PaneCommand} documents for tmux panes. A launcher whose program
    # is not lain (rspec, say) has no lain binary to spawn, so it spawns
    # nothing and leaves the stamp alone.
    #
    # NEVER THE TERMINAL. The child reads /dev/null and appends both streams to
    # a log beside the stamp, in its own process group, so neither its output
    # nor a Ctrl-C at the chat reaches the other.
    class GcSchedule
      INTERVAL = 24 * 60 * 60

      # Detached, so no launch waits on the child or leaves it a zombie.
      SPAWN = ->(argv, **options) { Process.detach(Process.spawn(*argv, **options)) }

      # @param root [String] the project the reap runs in
      # @param paths [Paths] supplies the state dir and the per-project key
      # @param clock [#call] answers now
      # @param spawner [#call] starts `argv` with `Process.spawn` options
      # @param program [String] the launching binary, read when constructed
      # @param ruby [String] the interpreter that runs it
      def initialize(root:, paths: Paths.new, clock: -> { Time.now }, spawner: SPAWN, program: $PROGRAM_NAME,
                     ruby: RbConfig.ruby)
        @root = root
        @paths = paths
        @clock = clock
        @spawner = spawner
        @program = program.to_s
        @ruby = ruby
      end

      # A schedule that never spawns: what a launch gets when its directory
      # resolves to no project to key a stamp on.
      NONE = Class.new { def call = false }.new.freeze

      # Keyed on the project a directory resolves to, exactly as the chat
      # started there resolves it, never on the directory itself.
      # @param cwd [String] where the launch will run
      # @param paths [Paths]
      # @param home [String, nil] the user's home directory, where resolution stops
      # @return [GcSchedule, NONE]
      def self.for(cwd:, paths: Paths.new, home: ENV.fetch("HOME", nil)) # rubocop:disable Style/EnvHome
        new(root: Project::Resolver.new(home:, paths:).call(cwd:).project.root, paths:)
      rescue Error
        NONE
      end

      # Housekeeping never aborts a launch: a state dir that cannot be made or
      # a stamp that cannot be opened simply means no run today.
      # @return [Boolean] whether this launch started a run
      def call
        return false unless lain?

        FileUtils.mkdir_p(File.dirname(stamp_path))
        File.open(stamp_path, File::RDWR | File::CREAT) { |stamp| due?(stamp) && spawned?(stamp) }
      rescue SystemCallError
        false
      end

      # @return [Array<String>] the command a run is started with
      def command = [@ruby, File.expand_path(@program), "worktrees", "gc"]

      def stamp_path = File.join(dir, "worktrees-#{key}.stamp")

      def log_path = File.join(dir, "worktrees-#{key}.log")

      private

      def dir = File.join(@paths.state_home, "gc")

      def key = @paths.project_hash(@root)

      def lain? = File.basename(@program) == "lain"

      # The lock is held across the check and the renewal, so two launches in
      # the same moment start one run between them. A stamp this call has just
      # created is empty, which is what the first launch ever looks like.
      def due?(stamp)
        return false unless stamp.flock(File::LOCK_EX | File::LOCK_NB)

        stat = stamp.stat
        stat.zero? || @clock.call - stat.mtime >= INTERVAL
      end

      # Renewed only once the child exists, so a launch whose spawn failed
      # leaves the next launch to try.
      def spawned?(stamp)
        @spawner.call(command, chdir: @root, in: File::NULL, out: [log_path, "a"], err: [log_path, "a"], pgroup: true)
        renew(stamp)
        true
      rescue SystemCallError
        false
      end

      def renew(stamp)
        now = @clock.call
        stamp.truncate(0)
        stamp.write("#{now.utc.iso8601}\n")
        stamp.flush
        File.utime(now, now, stamp_path)
      end
    end
  end
end
