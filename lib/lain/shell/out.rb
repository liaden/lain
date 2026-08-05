# frozen_string_literal: true

require "open3"

module Lain
  module Shell
    # One command, run to completion, reported as stdout, stderr and an exit
    # status. The `Mixlib::ShellOut` surface the `shell_out_factory` seam is
    # spelled against -- `#run_command`, `#stdout`, `#stderr`, `#exitstatus` --
    # so it substitutes for it wherever only that surface is used.
    #
    # SPAWNED, NOT FORKED, and that is the entire reason it exists beside a gem
    # that already works. `Mixlib::ShellOut` runs its child with `fork` + `exec`,
    # so the parent copies its page tables on every invocation and the cost is
    # linear in the parent's RSS. Measured on this machine, same git command,
    # same repository: **3.1ms from a 25MB heap, 7.2ms at 128MB, 26.7ms at
    # 542MB**, against a flat **0.6-1.8ms** for `Process.spawn`, which reaches
    # `posix_spawn`/`vfork` and copies no page tables at all. The process that
    # pays most is the one holding a Store, a Timeline and an index -- which is
    # the process shelling out per turn.
    #
    # NOT A REPLACEMENT FOR `Mixlib::ShellOut` EVERYWHERE. It answers the calls
    # that pass an argv array and read three values back. Callers wanting
    # mixlib's `cwd:`, `input:`, `live_stdout:` or its `CommandTimeout` class
    # keep mixlib; a keyword this does not implement is an `ArgumentError` here
    # rather than a silently ignored option.
    #
    # NEVER THROUGH A SHELL. `Process.spawn("ls -l")` is not `exec`: a lone
    # String is re-split on whitespace, and one holding a metacharacter goes to
    # `/bin/sh` outright. Every command is spawned in the `[program, argv0]`
    # form, which can do neither -- the same defence {Shell::Pipeline} takes,
    # for the same reason.
    class Out
      # A child that outlived its bound. Subclasses {Lain::Error} next to the
      # owner that raises it, per the error-taxonomy convention; it is NOT
      # `Mixlib::ShellOut::CommandTimeout`, which nothing reaching for this class
      # rescues by name -- both are `StandardError`, so a caller that rescues
      # broadly sees no difference.
      class Timeout < Error; end

      # Mixlib's own default, matched so that swapping the runner under a caller
      # that never passed one does not change when a hung child dies.
      DEFAULT_TIMEOUT = 600

      # Seconds between TERM and KILL. Mixlib hardcodes 3 with no option and
      # {Shell::Pipeline} matched the figure; this is the third arm of the same
      # agreement.
      GRACE = 3.0

      # One `read(2)` per ready stream.
      CHUNK = 65_536

      # How long to wait between polls of a child that has been signalled. There
      # is no `waitpid` that takes a deadline, so the grace period is polled.
      POLL = 0.01

      # `pgroup: true` makes the child a group leader, which is what lets a
      # timeout kill the command's own descendants rather than only the command.
      # `in:` is `/dev/null` because the child would otherwise inherit lain's
      # stdin and read the human's keystrokes -- mixlib hands its child an
      # immediately-closed pipe and `crates/lain-core/src/exec.rs` sets
      # `Stdio::null()`, so all three arms agree.
      SPAWN = { in: File::NULL, pgroup: true, unsetenv_others: false }.freeze

      # The file descriptors one run needs: opened together, handed to `spawn`,
      # and closed exactly once. Its own object because the bookkeeping is a
      # separate responsibility from running the command, and getting it wrong
      # is silent -- a parent still holding the WRITE end open never sees EOF on
      # the matching read end, so the pump waits out the whole timeout on a
      # command that finished immediately.
      class Pipes
        def initialize
          @stdout = IO.pipe
          @stderr = IO.pipe
        end

        # The ends the CHILD writes to, spelled as `spawn` wants them.
        def redirection = { out: @stdout.last, err: @stderr.last }

        def close_writes = [@stdout.last, @stderr.last].each(&:close)

        # The ends the PARENT reads, each keyed to the buffer it fills.
        def readers(stdout, stderr) = { @stdout.first => stdout, @stderr.first => stderr }

        def close = [@stdout, @stderr].flatten.each { |io| io.close unless io.closed? }
      end

      # @return [String] everything the child wrote to stdout
      attr_reader :stdout

      # @return [String] everything the child wrote to stderr
      attr_reader :stderr

      # @return [Integer, nil] the child's exit status, or nil when a signal
      #   killed it -- the same nil `Mixlib::ShellOut` reports for that case
      attr_reader :exitstatus

      # @param argv [Array<String>] the command and its arguments, never a
      #   single string for a shell to parse
      # @param environment [Hash{String=>String,nil}] merged over the parent's
      #   environment in the child, where a nil value DELETES the variable --
      #   mixlib's `environment:` semantics, which
      #   {Isolation::Worktree::GIT_CONTEXT_SCRUB} depends on
      # @param timeout [Numeric] seconds before the child's process group is
      #   TERMed, then KILLed
      # @param clock [#call] the monotonic source the bound is measured
      #   against, defaulted from {RunClock::MONOTONIC} as every `clock:` seam
      #   in the repo is -- naming the primitive here instead would be the
      #   second site of a constant that is spec'd to have exactly one
      def initialize(*argv, environment: {}, timeout: DEFAULT_TIMEOUT, clock: RunClock::MONOTONIC)
        @argv = argv
        @environment = environment
        @timeout = timeout
        @clock = clock
        @stdout = +""
        @stderr = +""
      end

      # Run it and wait. Raises whatever `Process.spawn` raises -- `Errno::ENOENT`
      # for a program that is not there, as mixlib does.
      #
      # @return [self] so `run_command.stdout` reads as it does with mixlib
      # @raise [Timeout] when the child outlives its bound
      def run_command
        pipes = Pipes.new
        pid = Process.spawn(@environment, *command, **pipes.redirection, **SPAWN)
        pipes.close_writes
        @exitstatus = collect(pid, pipes.readers(@stdout, @stderr))
        self
      ensure
        pipes&.close
      end

      private

      # `[program, argv0]` rather than a bare String: see the class comment on
      # why a one-word command would otherwise be re-split or shelled out.
      def command = [[@argv.first, @argv.first], *@argv.drop(1)]

      # The kill happens HERE and not at the caller: a Timeout that escaped with
      # the child still running would leave an orphan holding the pipes this
      # method's caller is about to close.
      def collect(pid, buffers)
        pump(buffers)
        reap(pid)
      rescue Timeout
        terminate(pid)
        raise
      end

      def pump(buffers)
        deadline = clock + @timeout
        open = buffers.keys
        open = read_ready(open, buffers, deadline) until open.empty?
      end

      def read_ready(open, buffers, deadline)
        finished = ready(open, deadline).select { |io| read_chunk(io, buffers.fetch(io)).nil? }
        open - finished
      end

      def ready(open, deadline)
        remaining = deadline - clock
        selected = remaining.positive? ? IO.select(open, nil, nil, remaining) : nil
        raise Timeout, "timed out after #{@timeout}s: #{@argv.join(" ")}" if selected.nil?

        selected.first
      end

      # `readpartial` answers ASCII-8BIT, and an empty buffer adopts the encoding
      # of the first thing appended to it -- the mechanics `Mixlib::ShellOut`
      # accumulates through, which is what keeps a binary payload byte-identical
      # across the two runners.
      def read_chunk(io, buffer)
        chunk = io.readpartial(CHUNK)
        buffer << chunk
        chunk
      rescue EOFError
        nil
      end

      def terminate(pid)
        signal(pid, "TERM")
        return if reaped_within?(GRACE, pid)

        signal(pid, "KILL")
        reap(pid)
      end

      # Whether the child died within `grace`. The trailing `waitpid` answers
      # the question the loop's own condition consumed: it raises `ECHILD` when
      # the loop exited because the child WAS reaped, and answers nil when it
      # exited on the deadline instead.
      def reaped_within?(grace, pid)
        deadline = clock + grace
        sleep(POLL) while Process.waitpid(pid, Process::WNOHANG).nil? && clock < deadline
        !Process.waitpid(pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        true
      end

      def signal(pid, name)
        Process.kill(name, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil # already reaped, or no longer ours to signal
      end

      def reap(pid)
        Process.waitpid2(pid).last.exitstatus
      rescue Errno::ECHILD
        nil # a timeout already reaped it
      end

      def clock = @clock.call
    end
  end
end
