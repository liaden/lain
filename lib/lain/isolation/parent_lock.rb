# frozen_string_literal: true

require "concurrent/map"
require "monitor"

module Lain
  module Isolation
    # The one lock on a parent checkout, held by everything that merges into
    # it: a chat's handback and a landing queue alike.
    #
    # TWO LOCKS IN ONE OBJECT. Within a process, a Monitor serialises fibers.
    # It is owned per fiber on Ruby 4, so a waiting sibling yields to the
    # scheduler, and it is reentrant, which a resolver's lease handed back
    # through the same handoff from inside the same fiber needs. Across
    # processes, an flock on a file under the repository's common git dir,
    # shared by every worktree of the repository, keeps `lain epic land` out of
    # a live chat's merge.
    #
    # ONE INSTANCE PER REPOSITORY, so the reentrancy holds across callers: a
    # landing queue whose resolver's lease is handed back through a chat's
    # handoff finds the lock it already holds, not a second one that waits on
    # it forever.
    #
    # POLLED, NOT BLOCKED. A blocking flock stalls the whole thread, reactor
    # and all, for as long as another process holds it; a non-blocking try
    # with a Kernel#sleep between tries yields to the scheduler instead.
    #
    # THE HOLDER NAMES ITSELF. It writes its pid and command into the lock
    # file, and a waiter that outlasts its patience is told, once and through
    # the notice it was handed, who it is waiting on.
    #
    # A CHILD FORKED WITHOUT EXEC INSIDE A HOLD KEEPS THE LOCK. It inherits the
    # open file description the flock belongs to, and a copy of the depth
    # counter, so the lock stays held until that child exits, and the child's
    # own hold re-enters a count its parent is about to unwind. No caller in
    # lain forks inside a hold; an exec'd child is safe, since Ruby opens files
    # close-on-exec.
    class ParentLock
      NAME = "lain-parent-checkout.lock"

      INTERVAL = 0.05

      PATIENCE = 5

      REGISTRY = Concurrent::Map.new
      private_constant :REGISTRY

      # A wait nobody is told about.
      module Silent
        def self.call(_text) = nil
      end

      # @param repo_root [String] any directory inside the repository
      # @param shell_out_factory [#call] builds the subprocess that finds the
      #   repository's common git dir
      # @return [ParentLock] the same object for every directory of one repository
      def self.for(repo_root:, shell_out_factory: Shell::Out.public_method(:new))
        path = located(File.expand_path(repo_root), shell_out_factory)
        REGISTRY.compute_if_absent(path || File.expand_path(repo_root)) { new(path:) }
      end

      # nil for a directory in no repository: there is no checkout there to
      # merge into, so nothing across processes to keep out of it.
      def self.located(root, shell_out_factory)
        shell = Checkout.new(root, shell_out_factory:).run("rev-parse", "--path-format=absolute", "--git-common-dir")
        shell.exitstatus.zero? ? File.join(shell.stdout.strip, NAME) : nil
      end
      private_class_method :located

      # @return [String, nil] the file the cross-process lock is taken on
      attr_reader :path

      # @param path [String, nil] the lock file; nil takes the in-process lock only
      # @param sleeper [#call] waits between tries while another process holds it
      # @param interval [Numeric] seconds between tries
      # @param patience [Numeric] seconds of waiting before the waiter is told who holds it
      def initialize(path:, sleeper: ->(seconds) { sleep(seconds) }, interval: INTERVAL, patience: PATIENCE)
        @path = path
        @sleeper = sleeper
        @interval = interval
        @told_after = [(patience / interval.to_f).ceil, 1].max
        @monitor = Monitor.new
        @depth = 0
      end

      # @param notice [#call] told once, in words, who holds the lock when a
      #   wait outlasts the patience; never the process's own streams
      # @return the block's value
      def hold(notice: Silent, &block)
        @monitor.synchronize { @depth.zero? && @path ? locked(notice, &block) : counted(&block) }
      end

      private

      # Only the outermost hold takes the file lock; closing the file on the
      # block's way out, a cancel mid-sleep included, is what releases it.
      def locked(notice, &block)
        File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
          waited(file, notice)
          claimed(file) { counted(&block) }
        end
      end

      def waited(file, notice)
        tries = 0
        until file.flock(File::LOCK_EX | File::LOCK_NB)
          notice.call(waiting_on) if (tries += 1) == @told_after
          @sleeper.call(@interval)
        end
      end

      def claimed(file)
        file.truncate(0)
        file.write("pid=#{Process.pid} command=#{[$PROGRAM_NAME, *ARGV].join(" ")}\n")
        file.flush
        yield
      ensure
        file.truncate(0)
      end

      def waiting_on
        holder = File.read(@path).strip
        "waiting on #{holder.empty? ? "a holder that has not named itself yet" : holder} for the parent " \
          "checkout's lock (#{@path})"
      end

      def counted
        @depth += 1
        yield
      ensure
        @depth -= 1
      end
    end
  end
end
