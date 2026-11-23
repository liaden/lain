# frozen_string_literal: true

require "digest"
require "json"
require "socket"

module Lain
  module Daemon
    # Forks headless runs from a process that has already paid for `require "lain"`, so a run
    # starts without a boot of its own. Requests arrive as JSON lines on a socket, each
    # `{argv, env, cwd, log}`; the answers are `{pid}` at the fork and `{pid, status}` at the
    # run's exit, with 128 plus the signal for a run a signal ended. A pane's program is asked
    # for on a second socket, {Spawner::PaneListener}, and forked under a waiter that answers its client.
    #
    # The parent stays a blank slate: it reads requests and reaps runs on its one thread, and
    # forks only while that thread is the process's only one. The extension's locks are taken
    # by a call on the calling thread and released before it returns, so with no other thread
    # none can be held at the fork.
    class Spawner
      # Another thread lived at a fork, so a lock it held would stay held in the run forever.
      class Threaded < Lain::Error; end

      STALE = { "stale" => true }.freeze
      LOG = File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW
      # The request's fields and what each must be; a request that fails one is answered, not run.
      SHAPE = {
        "argv" => ->(value) { value.is_a?(Array) && value.all?(String) },
        "env" => ->(value) { value.is_a?(Hash) && value.all? { |name, said| [name, said].all?(String) } },
        "cwd" => ->(value) { value.is_a?(String) },
        "log" => ->(value) { value.is_a?(String) }
      }.freeze
      # A pane's program writes to its terminal, so it has no log.
      PANE_SHAPE = SHAPE.except("log").freeze

      # @param status [Process::Status]
      # @return [Integer] the exit status, or 128 plus the signal that ended it
      def self.exit_code(status) = status.exitstatus || (128 + status.termsig)

      # The daemon hands the socket over as fd 0. It moves to an fd of its own, so a run's
      # /dev/null stdin cannot close it, and the old wrapper must not close /dev/null when collected.
      #
      # @param starter [#call] runs lain with a request's argv, in the forked run
      # @return [Spawner]
      def self.on_stdin(starter:)
        stdin = UNIXSocket.for_fd($stdin.fileno)
        stdin.autoclose = false
        new(socket: stdin.dup.tap { $stdin.reopen(File::NULL) }, starter:,
            pane_listener: PaneListener.listen(Paths.new.spawner_socket))
      end

      # @param socket [UNIXSocket] where requests arrive and answers go
      # @param starter [#call] runs lain with a request's argv, in the forked run
      # @param root [String] the install whose files the boot loaded
      # @param pane_listener [PaneListener, PaneListener::Off] where pane requests arrive
      def initialize(socket:, starter:, root: Paths::Shipped::GEM_ROOT, pane_listener: PaneListener::Off.new)
        @socket = socket
        @starter = starter
        @root = root
        @pane_listener = pane_listener
        @booted = digest
        @wake, @woken = IO.pipe
        @runs = Set.new
      end

      # Serves until the socket closes, or until lain's own files change. A change found at any
      # request, a pane's included, closes the pane socket and writes {STALE} once, unasked,
      # rather than fork from code the install no longer has; the runs still live then are
      # reported as they end, and then it returns.
      #
      # @return [nil]
      # @raise [Threaded] when another thread lives at a fork
      def call
        Process.warmup
        @chld = Signal.trap("CHLD") { @woken.write_nonblock(".", exception: false) }
        serve
      ensure
        @pane_listener.close(STALE)
        Signal.trap("CHLD", @chld) if @chld
        [@wake, @woken].each(&:close)
      end

      private

      def serve
        while (request = next_request)
          return outlive_runs(request) if digest != @booted

          request.is_a?(PaneListener::Request) ? fork_pane(request) : take(request)
        end
      end

      def outlive_runs(request)
        @pane_listener.close(STALE)
        request.refuse(STALE) if request.is_a?(PaneListener::Request)
        answer(STALE)
        @wake.wait_readable while reap
      end

      # @return [PaneListener::Request, String, nil] a whole pane request, or the daemon's next line, or
      #   nil once the daemon hangs up
      def next_request
        ready = []
        ready = await until @pane_listener.waiting? || ready.include?(@socket)
        @pane_listener.shift || @socket.gets
      end

      # Runs that ended while it waited are answered first.
      def await
        ready = IO.select([@socket, @wake, *@pane_listener.ios], nil, nil, @pane_listener.timeout)&.first.to_a
        reap
        @pane_listener.take(ready)
        ready
      end

      def take(line)
        request = JSON.parse(line)
        wrong = misshapen(request)
        answer(wrong ? { "error" => wrong } : { "pid" => fork_run(request) })
      rescue JSON::ParserError => e
        answer("error" => "a request is 1 JSON line: #{e.message}")
      end

      def misshapen(request, shape = SHAPE)
        return "a request is a JSON object" unless request.is_a?(Hash)

        wrong = shape.keys.reject { |field| shape.fetch(field).call(request[field]) }
        "#{wrong.join(", ")} missing or of the wrong type" unless wrong.empty?
      end

      # Lazy, so each exit is answered before the wait that finds no child left raises. A pane's
      # waiter is reaped unreported: the daemon never asked for it.
      #
      # @return [Boolean] whether a run is still live
      def reap
        @wake.read_nonblock(4096, exception: false)
        Enumerator.produce { Process.wait2(-1, Process::WNOHANG) }.lazy.take_while(&:itself).each do |pid, status|
          answer("pid" => pid, "status" => Spawner.exit_code(status)) if @runs.delete?(pid)
        end
        @runs.any?
      rescue Errno::ECHILD
        false
      end

      def answer(fields)
        @socket.write("#{JSON.generate(fields)}\n")
        nil
      end

      def fork_run(request)
        alone!
        fork { run(request) }.tap { |pid| @runs << pid }
      end

      def alone!
        raise Threaded, "the spawner forks only as its process's one thread" unless Thread.list == [Thread.main]
      end

      # The waiter leads a session of its own, so the daemon's kill of the spawner's group on a
      # restart leaves the pane running.
      def fork_pane(request)
        fields = JSON.parse(request.line)
        wrong = misshapen(fields, PANE_SHAPE)
        return request.refuse("error" => wrong) if wrong

        alone!
        fork { wait_on(request, fields) }
        request.close
      rescue JSON::ParserError => e
        request.refuse("error" => "a request is 1 JSON line: #{e.message}")
      end

      def wait_on(request, fields)
        ForkedExit.new(out: $stdout, err: $stderr).call do
          Process.setsid
          leave_spawner
          alone!
          request.relay(fork { program(request, fields) })
        end
      end

      def program(request, fields)
        ForkedExit.new(out: $stdout, err: $stderr).call do
          request.own_terminal { |tty| [$stdin, $stdout, $stderr].each { |stdio| stdio.reopen(tty) } }
          Dir.chdir(fields.fetch("cwd"))
          ENV.replace(fields.fetch("env"))
          Config.forget!
          @starter.call(fields.fetch("argv"))
        end
      end

      def run(request)
        ForkedExit.new(out: $stdout, err: $stderr).call do
          detach(request)
          @starter.call(request.fetch("argv"))
        end
      end

      # The run owns none of the spawner's fds, so the spawner's death reads as an end of file.
      # Its stdin is the spawner's, which {.on_stdin} already pointed at /dev/null.
      def detach(request)
        Process.setsid
        leave_spawner
        File.open(request.fetch("log"), LOG, 0o600) do |log|
          $stdout.reopen(log)
          $stderr.reopen(log)
        end
        Dir.chdir(request.fetch("cwd"))
        ENV.replace(request.fetch("env"))
        Config.forget!
      end

      def leave_spawner
        [@socket, @wake, @woken].each(&:close)
        @pane_listener.forget
        Signal.trap("CHLD", @chld)
      end

      # Path, mtime and size, never content: a stat per file is cheap enough to take per request.
      def digest = Digest::SHA256.hexdigest(installed.filter_map { |name| stamp(name) }.join("\n"))

      def installed = [*Dir.glob("lib/**/*", base: @root), "exe/lain"].sort

      def stamp(name)
        stat = File.lstat(File.join(@root, name))
        "#{name}\0#{stat.mtime.to_r}\0#{stat.size}"
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
