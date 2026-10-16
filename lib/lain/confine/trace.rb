# frozen_string_literal: true

module Lain
  module Confine
    # Reads the strace exec record a confined call wrote to its trace pipe. The pipe is drained
    # to the end even past the cap, because a writer blocked on a full pipe would hang the call
    # it is tracing; only the parsing stops.
    class Trace
      CAP = 8 * 1024 * 1024
      CHUNK = 64 * 1024
      REFUSED = %w[EACCES EPERM].freeze

      # @param io [#readpartial] the read end of the trace pipe
      # @param cap [Integer] the most bytes of trace that are parsed
      def initialize(io, cap: CAP)
        @io = io
        @cap = cap
      end

      # @param tool_use_id [String] the call this trace belongs to
      # @param profile [Symbol] the confinement profile it ran under
      # @return [Telemetry::ExecRecord]
      def record(tool_use_id:, profile:)
        text, truncated = drain
        execs, fd_execs = Parser.new.parse(text).partition { |call| call[:fd].nil? }
        Telemetry::ExecRecord.new(tool_use_id:, profile:, truncated:,
                                  execs: execs.map { |call| call.slice(:path, :argv0, :rc) },
                                  refusals: refusals(execs + fd_execs),
                                  fd_execs: fd_execs.map { |call| call.slice(:fd, :path, :argv0, :rc, :errno) })
      end

      private

      def refusals(calls)
        calls.select { |call| REFUSED.include?(call[:errno]) }.map { |call| call.slice(:path, :errno) }
      end

      def drain
        held = +"".b
        total = 0
        while (chunk = read_chunk)
          held << chunk.byteslice(0, [@cap - total, 0].max)
          total += chunk.bytesize
        end
        [held, total > @cap]
      end

      def read_chunk
        @io.readpartial(CHUNK)
      rescue EOFError
        nil
      end

      # Joins an "<unfinished ...>" call to its "<... resumed>" line by pid, then reads the
      # call's strings the way strace escaped them.
      class Parser
        CALL = /\A(?:(?<pid>\d+)\s+)?(?<name>execve|execveat)\((?<args>.*)\z/
        RESUMED = /\A(?:(?<pid>\d+)\s+)?<\.\.\. (?:execve|execveat) resumed>(?<tail>.*)\z/
        UNFINISHED = /\s*<unfinished \.\.\.>\z/
        RESULT = /\)\s+=\s+(?<rc>-?\d+)(?:\s+(?<errno>E[A-Z0-9]+))?(?:\s+\(.*\))?\s*\z/
        ESCAPE = /\\(?:(?<octal>[0-7]{1,3})|x(?<hex>\h{1,2})|(?<char>.))/m
        SIMPLE = { "n" => "\n", "t" => "\t", "r" => "\r", "v" => "\v", "f" => "\f", "a" => "\a", "b" => "\b" }.freeze

        # @param text [String] whole trace; a final line cut short by the cap is dropped
        # @return [Array<Hash>] one per finished call, in trace order
        def parse(text)
          lines = text.split("\n", -1)
          lines.pop
          @pending = {}
          lines.filter_map { |line| read(line.b) }
        end

        private

        def read(line)
          if (resumed = RESUMED.match(line))
            finish(@pending.delete(resumed[:pid]), resumed[:tail])
          elsif (call = CALL.match(line))
            start(call)
          end
        end

        def start(call)
          if UNFINISHED.match?(call[:args])
            @pending[call[:pid]] = [call[:name], call[:args].sub(UNFINISHED, "")]
            nil
          else
            finish([call[:name], call[:args]], call[:args])
          end
        end

        def finish(pending, tail)
          name, args = pending
          result = RESULT.match(tail)
          shape(name, args, result) if args && result
        end

        def shape(name, args, result)
          rc = Integer(result[:rc])
          if name == "execveat"
            fd_exec(args, rc, result[:errno])
          else
            path, rest = string(args)
            { path:, argv0: argv0(rest), rc:, errno: result[:errno] } if path
          end
        end

        def fd_exec(args, status, errno)
          dirfd, rest = args.split(",", 2)
          path, after = string(rest.to_s.lstrip)
          return { path:, argv0: argv0(after), rc: status, errno: } unless dirfd.strip.match?(/\A\d+\z/)

          { fd: Integer(dirfd), path:, argv0: argv0(after), rc: status, errno: }
        end

        def argv0(rest)
          list = rest.to_s.sub(/\A\s*,\s*\[/, "")
          string(list.lstrip)&.first || ""
        end

        # @return [Array(String, String), nil] the string literal at the front and what follows it
        def string(text)
          return unless text&.start_with?('"')

          body = text.byteslice(1..)
          close = closing_quote(body)
          [unescape(body.byteslice(0, close)), body.byteslice((close + 1)..).delete_prefix("...")]
        end

        def closing_quote(body)
          index = 0
          index += body.getbyte(index) == 0x5c ? 2 : 1 while index < body.bytesize && body.getbyte(index) != 0x22
          index
        end

        def unescape(raw)
          raw.gsub(ESCAPE) { unescaped(Regexp.last_match) }.force_encoding(Encoding::UTF_8).scrub
        end

        def unescaped(match)
          return match[:octal].to_i(8).chr.b if match[:octal]
          return match[:hex].to_i(16).chr.b if match[:hex]

          SIMPLE.fetch(match[:char], match[:char]).b
        end
      end
      private_constant :Parser
    end
  end
end
