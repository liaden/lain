# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "socket"

module Lain
  module Daemon
    class Spawner
      # The spawner's second socket, where a pane's client asks for its program on the pane's own
      # terminal. A request is 1 JSON line `{argv, env, cwd}` and then the terminal by `send_io`.
      # Every read is nonblocking and each connection has a deadline, so a client that stalls
      # never holds the loop that also serves the daemon's runs.
      class PaneListener
        DEADLINE = 1
        # A `sun_path` holds 108 bytes, its terminating NUL included.
        LONGEST = 107

        # @param path [String] where to bind, 0600
        # @param deadline [Numeric] seconds a connection has to send its whole request
        # @param host_os [String] the platform; the terminal ioctl and `sun_path` are Linux's
        # @return [PaneListener, Off] {Off} away from Linux, when the path is too long, or when another
        #   spawner answers on it
        def self.listen(path, deadline: DEADLINE, host_os: RbConfig::CONFIG["host_os"])
          return Off.new unless host_os.include?("linux") && path.bytesize <= LONGEST

          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          return Off.new if answered?(path)

          FileUtils.rm_f(path)
          new(owner_only { UNIXServer.new(path) }, path:, deadline:)
        rescue SystemCallError
          Off.new
        end

        def self.answered?(path)
          UNIXSocket.new(path).close
          true
        rescue Errno::ECONNREFUSED, Errno::ENOENT
          false
        end

        # The umask, not a chmod after the bind, so the socket is never reachable wider than 0600.
        def self.owner_only
          umask = File.umask(0o177)
          yield
        ensure
          File.umask(umask) if umask
        end

        private_class_method :answered?, :owner_only

        # @param server [UNIXServer]
        # @param path [String]
        # @param deadline [Numeric]
        def initialize(server, path:, deadline:)
          @server = server
          @path = path
          @deadline = deadline
          @pending = []
          @waiting = []
        end

        # @return [Array<IO>] what to select on for readability
        def ios = [@server, *@pending.map(&:conn)]

        # @return [Numeric, nil] seconds until the nearest deadline, nil with none pending
        def timeout = @pending.map(&:deadline).min&.then { |at| [at - now, 0].max }

        # Accepts, reads what arrived, and settles each connection: whole, past its deadline, or gone.
        #
        # @param ready [Array<IO>] what the select found readable
        # @return [void]
        def take(ready)
          accept if ready.include?(@server)
          @pending.select { |request| ready.include?(request.conn) }.each(&:read)
          settle
        end

        # @return [Boolean] whether a whole request is waiting
        def waiting? = @waiting.any?

        # @return [Request, nil] the oldest whole request
        def shift = @waiting.shift

        # Stops listening: a client that connects afterwards finds no socket, and one already
        # connected is answered `fields`. Once only: by a second call the path may be a fresh
        # spawner's.
        #
        # @param fields [Hash] the last answer each open connection gets
        # @return [void]
        def close(fields)
          return if @server.closed?

          FileUtils.rm_f(@path)
          @server.close
          [*@pending, *@waiting].each { |request| request.refuse(fields) }
        end

        # In a forked child: drops the spawner's copies, unlinking and answering nothing.
        #
        # @return [void]
        def forget
          @server.close
          [*@pending, *@waiting].each(&:close)
        end

        private

        def accept
          conn = @server.accept_nonblock(exception: false)
          @pending << Request.new(conn, deadline: now + @deadline) unless conn == :wait_readable
        end

        def settle
          whole, @pending = @pending.partition(&:whole?)
          @waiting.concat(whole)
          gone, @pending = @pending.partition(&:gone?)
          gone.each(&:close)
          late, @pending = @pending.partition { |request| request.deadline <= now }
          late.each { |request| request.refuse("error" => "no whole request within #{@deadline} s") }
        end

        def now = RunClock::MONOTONIC.call

        # 1 connection: its request as it arrives, then its answers.
        class Request
          # Linux's ioctl number; Ruby names none.
          TIOCSCTTY = 0x540E

          # @return [UNIXSocket]
          attr_reader :conn
          # @return [Float] the monotonic time its request must be whole by
          attr_reader :deadline

          # @param conn [UNIXSocket]
          # @param deadline [Float]
          def initialize(conn, deadline:)
            @conn = conn
            @deadline = deadline
            @said = +""
            @ttys = []
            @gone = false
          end

          # Every read takes ancillary data, so the terminal is never dropped with the byte it rides on.
          #
          # @return [void]
          def read
            received = @conn.recvmsg_nonblock(4096, scm_rights: true, exception: false)
            return if received == :wait_readable

            said, _, _, *controls = received
            @gone = said.empty? && controls.empty?
            @said << said
            @ttys.concat(controls.flat_map { |control| control.unix_rights.to_a })
          rescue SystemCallError
            @gone = true
          end

          def whole? = @said.include?("\n") && @ttys.any?

          def gone? = @gone

          # @return [String] the request's JSON line
          def line = @said.lines.first

          # @param fields [Hash]
          # @return [void]
          def answer(fields)
            @conn.write("#{JSON.generate(fields)}\n")
          rescue SystemCallError, IOError
            nil
          end

          # @param fields [Hash] the answer before the hang-up
          # @return [void]
          def refuse(fields)
            answer(fields)
            close
          end

          # @return [void]
          def close = [@conn, *@ttys].each(&:close)

          # In the program: a session of its own, led from the passed terminal, which its client
          # gave up before sending it. Then nothing of the request stays open.
          #
          # @yieldparam tty [IO] the terminal, for the program's stdio
          # @return [void]
          def own_terminal
            Process.setsid
            tty = @ttys.first
            tty.ioctl(TIOCSCTTY, 0)
            yield tty
            close
          end

          # In the waiter: names the program, hangs it up when the client goes, and relays its
          # exit. The waiter holds no terminal, so the pane's lives only in the program.
          #
          # @param program [Integer] the program's pid
          # @return [void]
          def relay(program)
            @ttys.each(&:close)
            answer("pid" => program)
            answer("pid" => program, "status" => Spawner.exit_code(outwait(program)))
          end

          private

          # The CHLD trap wakes the select, so the waiter watches both ends with no thread. The
          # program is reaped only here, so the pid a hang-up signals is still the program's.
          def outwait(program)
            ended, ending = IO.pipe
            Signal.trap("CHLD") { ending.write_nonblock(".", exception: false) }
            watched = [@conn, ended]
            until (status = Process.wait2(program, Process::WNOHANG)&.last)
              ready = IO.select(watched).first
              ended.read_nonblock(4096, exception: false)
              hang_up(program, watched) if ready.include?(@conn) && hung_up?
            end
            status
          end

          def hung_up?
            @conn.read_nonblock(4096, exception: false).nil?
          rescue SystemCallError
            true
          end

          def hang_up(program, watched)
            watched.delete(@conn)
            Process.kill(:HUP, program)
          end
        end

        # No pane socket: the spawner serves only the daemon's runs.
        class Off
          def ios = []
          def timeout = nil
          def take(_ready) = nil
          def waiting? = false
          def shift = nil
          def close(_fields) = nil
          def forget = nil
        end
      end
    end
  end
end
