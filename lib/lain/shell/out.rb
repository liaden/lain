# frozen_string_literal: true

require "open3"

module Lain
  module Shell
    # One command, run to completion, reported as stdout, stderr and an exit
    # status. It presents the surface the `shell_out_factory` seam is spelled
    # against: `#run_command`, `#stdout`, `#stderr`, `#exitstatus`.
    #
    # SPAWNED, NOT FORKED. A `fork` + `exec` runner copies the parent's page
    # tables on every invocation, so the cost is linear in the parent's RSS.
    # Measured on this machine, same git command,
    # same repository: **3.1ms from a 25MB heap, 7.2ms at 128MB, 26.7ms at
    # 542MB**, against a flat **0.6-1.8ms** for `Process.spawn`, which reaches
    # `posix_spawn`/`vfork` and copies no page tables at all. The process that
    # pays most is the one holding a Store, a Timeline and an index -- which is
    # the process shelling out per turn.
    #
    # It answers the calls that pass an argv array, optionally a directory and
    # some stdin, and read three values back. A keyword it does not implement
    # is an `ArgumentError` rather than a silently ignored option.
    #
    # NEVER THROUGH A SHELL. `Process.spawn("ls -l")` is not `exec`: a lone
    # String is re-split on whitespace, and one holding a metacharacter goes to
    # `/bin/sh` outright. Every command is spawned in the `[program, argv0]`
    # form, which can do neither -- the same defence {Shell::Pipeline} takes,
    # for the same reason.
    class Out
      # A child that outlived its bound. Subclasses {Lain::Error} next to the
      # owner that raises it, per the error-taxonomy convention.
      class Timeout < Error; end

      # Ten minutes: long enough for a build or test run, short enough that a
      # hung child does not hold a turn open for the session.
      DEFAULT_TIMEOUT = 600

      # Seconds between TERM and KILL, the figure {Shell::Pipeline} shares.
      GRACE = 3.0

      # One `read(2)` per ready stream.
      CHUNK = 65_536

      # How long to wait between polls of a child that has been signalled. There
      # is no `waitpid` that takes a deadline, so the grace period is polled.
      POLL = 0.01

      # `pgroup: true` makes the child a group leader, which is what lets a
      # timeout kill the command's own descendants rather than only the command.
      SPAWN = { pgroup: true, unsetenv_others: false }.freeze

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

      # The stdin of a run given no input: `/dev/null`, never a pipe and never
      # inherited. Inherited, the child would read the human's keystrokes; a
      # pipe, even an empty one, changes what some tools do -- rg searches its
      # stdin instead of the directory.
      module Unfed
        def self.redirection = { in: File::NULL }
        def self.close_read = nil
        def self.writers = []
        def self.closed? = true
        def self.close = nil
      end

      # The input still owed to the child, written a pipe-buffer at a time as
      # the select loop finds stdin writable. Writing it all up front instead
      # deadlocks once the input outgrows what the pipes and the child's own
      # buffer absorb: the parent blocks on a full stdin while the child
      # blocks on a full stdout.
      class Feed
        # @param input [String, nil]
        # @return [Feed, Unfed]
        def self.for(input) = input.nil? ? Unfed : new(input)

        def initialize(input)
          @read, @io = IO.pipe
          @pending = input.b
        end

        def redirection = { in: @read }

        # Called once the child holds its copy, so the child's exit is what
        # closes the last read end and turns a pending write into EPIPE.
        def close_read
          @read.close
          finish if @pending.empty?
        end

        # @return [Array<IO>] the stdin write end while input is owed, else none
        def writers = @io.closed? ? [] : [@io]

        def closed? = @io.closed?

        def close = [@read, @io].each { |io| io.close unless io.closed? }

        # A child that exits without reading closes its end, and the write
        # answers EPIPE: the input is moot, the exit status is still the answer.
        def write
          @pending = @pending.byteslice(@io.write_nonblock(@pending)..)
          finish if @pending.empty?
        rescue IO::WaitWritable
          nil # writable went stale between select and write; the next round retries
        rescue Errno::EPIPE
          finish
        end

        private

        def finish = @io.close
      end

      # A module function so the `run_command` fakes that only answer
      # `exitstatus` keep working. Not `.zero?`: a signalled child has a nil status.
      #
      # @param out [#exitstatus]
      # @return [Boolean]
      def self.ok?(out) = out.exitstatus.eql?(0)

      # @return [String] everything the child wrote to stdout
      attr_reader :stdout

      # @return [String] everything the child wrote to stderr
      attr_reader :stderr

      # @return [Integer, nil] the child's exit status, or nil when a signal
      #   killed it -- the same nil a signalled `Process::Status` reports
      attr_reader :exitstatus

      # @param argv [Array<String>] the command and its arguments, never a
      #   single string for a shell to parse
      # @param environment [Hash{String=>String,nil}] merged over the parent's
      #   environment in the child, where a nil value DELETES the variable --
      #   `Process.spawn`'s `env` semantics, which
      #   {Isolation::Worktree::GIT_CONTEXT_SCRUB} depends on
      # @param cwd [String, nil] the child's working directory; nil keeps the
      #   parent's
      # @param input [String, nil] written to the child's stdin, which then
      #   closes; nil gives the child an empty stdin
      # @param timeout [Numeric] seconds before the child's process group is
      #   TERMed, then KILLed
      # @param clock [#call] the monotonic source the bound is measured
      #   against, defaulted from {RunClock::MONOTONIC} as every `clock:` seam
      #   in the repo is -- naming the primitive here instead would be the
      #   second site of a constant that is spec'd to have exactly one
      def initialize(*argv, environment: {}, cwd: nil, input: nil, timeout: DEFAULT_TIMEOUT,
                     clock: RunClock::MONOTONIC)
        @argv = argv
        @environment = environment
        @chdir = { chdir: cwd }.compact
        @input = string_or_nil(input)
        @timeout = timeout
        @clock = clock
        @stdout = +""
        @stderr = +""
      end

      # Run it and wait. Raises whatever `Process.spawn` raises -- `Errno::ENOENT`
      # for a program that is not there.
      #
      # The kill happens HERE and not at the caller: any early exit, a Timeout or
      # a killed thread alike, would otherwise leave an orphan holding the pipes
      # about to be closed. An `ensure`, because a killed thread runs ensure
      # blocks and no rescue, and the spawn defers interrupts, so no kill can
      # land between the child existing and this method holding its pid.
      #
      # @param on_spawn [#call] given the child's pid, which is also its
      #   process group id, once, after the spawn and before the wait
      # @return [self] so `run_command.stdout` chains
      # @raise [Timeout] when the child outlives its bound
      def run_command(on_spawn: ->(_pid) {})
        pid = nil
        pipes = Pipes.new
        feed = Feed.for(@input)
        Thread.handle_interrupt(Object => :never) { pid = spawn(pipes, feed) }
        on_spawn.call(pid)
        @exitstatus = collect(pid, pipes.readers(@stdout, @stderr), feed)
        pid = nil
        self
      ensure
        terminate(pid) if pid
        pipes&.close
        feed&.close
      end

      private

      def spawn(pipes, feed)
        pid = Process.spawn(@environment, *command, **pipes.redirection, **feed.redirection, **@chdir, **SPAWN)
        pipes.close_writes
        feed.close_read
        pid
      end

      def string_or_nil(input)
        return input if input.nil? || input.is_a?(String)

        raise TypeError, "input: must be a String or nil, got #{input.class}"
      end

      # `[program, argv0]` rather than a bare String: see the class comment on
      # why a one-word command would otherwise be re-split or shelled out.
      def command = [[@argv.first, @argv.first], *@argv.drop(1)]

      def collect(pid, buffers, feed)
        pump(buffers, feed)
        reap(pid)
      end

      def pump(buffers, feed)
        deadline = clock + @timeout
        open = buffers.keys
        open = transfer(open, buffers, feed, deadline) until open.empty? && feed.closed?
      end

      def transfer(open, buffers, feed, deadline)
        readable, writable = ready(open, feed.writers, deadline)
        feed.write unless writable.empty?
        open - readable.select { |io| read_chunk(io, buffers.fetch(io)).nil? }
      end

      def ready(open, writers, deadline)
        remaining = deadline - clock
        selected = remaining.positive? ? IO.select(open, writers, nil, remaining) : nil
        raise Timeout, "timed out after #{@timeout}s: #{@argv.join(" ")}" if selected.nil?

        selected
      end

      # `readpartial` answers ASCII-8BIT, and an empty buffer adopts the encoding
      # of the first thing appended to it -- which keeps a binary payload
      # byte-identical to what the child wrote.
      def read_chunk(io, buffer)
        chunk = io.readpartial(CHUNK)
        buffer << chunk
        chunk
      rescue EOFError
        nil
      end

      def terminate(pid)
        group = ProcessGroup.new(clock: @clock, grace: GRACE, poll: POLL)
        group.terminate(pid, reaper: -> { reap_exited(pid) })
        reap(pid)
      end

      # A zombie leader keeps its group listed as alive, so it is collected
      # before the group is asked about.
      def reap_exited(pid)
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        nil
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
