# frozen_string_literal: true

require "digest"
require "json"
require "socket"

module Lain
  module Daemon
    # Forks headless runs from a process that has already paid for `require "lain"`, so a run
    # starts without a boot of its own. Requests arrive as JSON lines on a socket, each
    # `{argv, env, cwd, log}`; the answers are `{pid}` at the fork and `{pid, status}` at the
    # run's exit, with 128 plus the signal for a run a signal ended.
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

      # The daemon hands the socket over as fd 0. It moves to an fd of its own, so a run's
      # /dev/null stdin cannot close it, and the old wrapper must not close /dev/null when collected.
      #
      # @param starter [#call] runs lain with a request's argv, in the forked run
      # @return [Spawner]
      def self.on_stdin(starter:)
        stdin = UNIXSocket.for_fd($stdin.fileno)
        stdin.autoclose = false
        new(socket: stdin.dup.tap { $stdin.reopen(File::NULL) }, starter:)
      end

      # @param socket [UNIXSocket] where requests arrive and answers go
      # @param starter [#call] runs lain with a request's argv, in the forked run
      # @param root [String] the install whose files the boot loaded
      def initialize(socket:, starter:, root: Paths::Shipped::GEM_ROOT)
        @socket = socket
        @starter = starter
        @root = root
        @booted = digest
        @wake, @woken = IO.pipe
      end

      # Serves until the socket closes, or until lain's own files change. A change is answered
      # with {STALE} rather than a run forked from code the install no longer has; the runs
      # still live then are reported as they end, and then it returns.
      #
      # @return [nil]
      # @raise [Threaded] when another thread lives at a fork
      def call
        Process.warmup
        @chld = Signal.trap("CHLD") { @woken.write_nonblock(".", exception: false) }
        serve
      ensure
        Signal.trap("CHLD", @chld) if @chld
        [@wake, @woken].each(&:close)
      end

      private

      def serve
        while (line = next_line)
          return outlive_runs if digest != @booted

          take(line)
        end
      end

      def outlive_runs
        answer(STALE)
        @wake.wait_readable while reap
      end

      # Runs that ended while it waited are answered first.
      def next_line
        reap while IO.select([@socket, @wake]).first.none?(@socket)
        @socket.gets
      end

      def take(line)
        request = JSON.parse(line)
        wrong = misshapen(request)
        answer(wrong ? { "error" => wrong } : { "pid" => fork_run(request) })
      rescue JSON::ParserError => e
        answer("error" => "a request is 1 JSON line: #{e.message}")
      end

      def misshapen(request)
        return "a request is a JSON object" unless request.is_a?(Hash)

        wrong = SHAPE.keys.reject { |field| SHAPE.fetch(field).call(request[field]) }
        "#{wrong.join(", ")} missing or of the wrong type" unless wrong.empty?
      end

      # Lazy, so each exit is answered before the wait that finds no run left raises.
      #
      # @return [Boolean] whether a run is still live
      def reap
        @wake.read_nonblock(4096, exception: false)
        Enumerator.produce { Process.wait2(-1, Process::WNOHANG) }.lazy.take_while(&:itself).each do |pid, status|
          answer("pid" => pid, "status" => status.exitstatus || (128 + status.termsig))
        end
        true
      rescue Errno::ECHILD
        false
      end

      def answer(fields)
        @socket.write("#{JSON.generate(fields)}\n")
        nil
      end

      def fork_run(request)
        raise Threaded, "the spawner forks only as its process's one thread" unless Thread.list == [Thread.main]

        fork { run(request) }
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
        [@socket, @wake, @woken].each(&:close)
        File.open(request.fetch("log"), LOG, 0o600) do |log|
          $stdout.reopen(log)
          $stderr.reopen(log)
        end
        Dir.chdir(request.fetch("cwd"))
        ENV.replace(request.fetch("env"))
        Config.forget!
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
