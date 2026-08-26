# frozen_string_literal: true

module Lain
  # Where output goes when it is NOT the frontend's to render. Only the frontend
  # touches the terminal; everything else is handed a sink. {Sink::IOAdapter}
  # exists because some third-party code (and `Mixlib::ShellOut`'s `live_stdout`
  # / `live_stderr`) insists on writing to an IO. {Sink::Null} is `/dev/null`.
  module Sink
    # A minimal IO look-alike over a {Lain::Channel}: each write becomes a
    # {Lain::Telemetry::ToolOutput} carrying a fixed `tool_use_id` and `stream`,
    # so bytes are attributed the moment they are produced. Only the surface
    # third-party writers actually reach for is implemented, and return values
    # follow the real `IO` contract.
    #
    # Not a painter's algorithm: each write-family method allocates one fresh
    # buffer local to that call, appends each argument to it AT MOST ONCE, and
    # lets it go -- no instance buffer grows call over call, so N calls cost
    # O(total bytes written), never O(n^2). `puts`'s recursive `append_line` over
    # a nested Array only looks like re-appending: each element is visited once
    # and appended once to the SAME buffer.
    class IOAdapter
      # @param channel [Lain::Channel] destination for emitted events
      # @param tool_use_id [String] attribution stamped on every event
      # @param stream [Symbol] `:stdout` or `:stderr` (validated by the event)
      def initialize(channel, tool_use_id:, stream:)
        @channel = channel
        @tool_use_id = tool_use_id
        @stream = stream
        # Fail fast on a bad stream rather than at first write, deep in a tool.
        Telemetry::ToolOutput.new(tool_use_id:, stream:, bytes: "")
      end

      # One event per call, never per byte, so a single logical write can never
      # be split mid-line.
      #
      # @return [Integer] total number of bytes written, per the `IO` contract
      def write(*args)
        buffer = +""
        args.each { |arg| buffer << arg.to_s }
        emit(buffer)
        buffer.bytesize
      end

      # @param obj [Object]
      # @return [self] per the `IO#<<` contract
      def <<(obj)
        emit(obj.to_s)
        self
      end

      # No separators or terminator. The body is {#write}'s, so it delegates
      # rather than duplicating the buffer loop; only the return value differs.
      # @return [nil] per the `IO#print` contract
      def print(*)
        write(*)
        nil
      end

      # Faithful `IO#puts`: no args writes a lone newline; `nil` becomes "\n";
      # arrays are flattened recursively; and a string already ending in "\n"
      # gets no second newline.
      #
      # @return [nil] per the `IO#puts` contract
      def puts(*args)
        buffer = +""
        if args.empty?
          buffer << "\n"
        else
          args.each { |arg| append_line(buffer, arg) }
        end
        emit(buffer)
        nil
      end

      # A no-op: events are enqueued synchronously, so nothing is pending.
      # @return [self]
      def flush
        self
      end

      private

      # The quirks confirmed against real `IO`: an empty array contributes
      # nothing, a nested array is flattened, a trailing newline is not doubled.
      def append_line(buffer, arg)
        if arg.is_a?(Array)
          arg.each { |element| append_line(buffer, element) }
          return
        end

        string = arg.to_s
        buffer << string
        buffer << "\n" unless string.end_with?("\n")
      end

      # Skips empty writes, so no zero-byte event is ever emitted.
      def emit(bytes)
        return if bytes.empty?

        @channel.push(
          Telemetry::ToolOutput.new(tool_use_id: @tool_use_id, stream: @stream, bytes:)
        )
      end
    end

    # The Null Object no caller checks for: the same IO-shaped duck as
    # {IOAdapter}, `#write`'s byte count included, sending the bytes nowhere.
    class Null
      # @return [Integer] bytes that would have been written
      def write(*args)
        args.sum { |arg| arg.to_s.bytesize }
      end

      # @return [self]
      def <<(_obj)
        self
      end

      # @return [nil]
      def print(*_args)
        nil
      end

      # @return [nil]
      def puts(*_args)
        nil
      end

      # @return [self]
      def flush
        self
      end
    end
  end
end
