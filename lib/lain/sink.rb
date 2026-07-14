# frozen_string_literal: true

module Lain
  # Sinks are where output goes when it is NOT the frontend's to render.
  #
  # The output-discipline rule is that only the frontend touches the terminal;
  # everything else is handed a sink. {Sink::IOAdapter} exists for the awkward
  # reality that some third-party code (and `Mixlib::ShellOut`'s `live_stdout` /
  # `live_stderr`) insists on writing to an IO. It presents an IO-shaped duck,
  # but every write becomes an attributed {Lain::Event::ToolOutput} on a
  # {Lain::Channel}, tagged at the source with its `tool_use_id` and stream.
  # {Sink::Null} is the `/dev/null` of sinks.
  module Sink
    # A minimal IO look-alike over a {Lain::Channel}. Each write turns into a
    # {Lain::Event::ToolOutput} carrying a fixed `tool_use_id` and `stream`, so
    # bytes are attributed the moment they are produced.
    #
    # Only the IO surface third-party writers actually reach for is implemented:
    # `#write`, `#puts`, `#print`, `#<<`, and `#flush`. Return values follow the
    # real `IO` contract (notably `#write` returns the number of bytes written).
    #
    # Not a painter's algorithm: each write-family method allocates exactly one
    # fresh, mutable buffer local to that call (`+""`), appends each argument to
    # it AT MOST ONCE, hands it to {#emit}, and lets it go -- there is no
    # instance-level buffer that grows call over call, so N calls cost O(total
    # bytes written), never O(n^2). The one thing that *could* look like
    # re-appending -- `puts`'s recursive `append_line` over a nested Array -- is
    # still a single pass per byte: each element is visited once and appended
    # once to the SAME buffer, not copied into a growing chain of buffers.
    class IOAdapter
      # @param channel [Lain::Channel] destination for emitted events
      # @param tool_use_id [String] attribution stamped on every event
      # @param stream [Symbol] `:stdout` or `:stderr` (validated by the event)
      def initialize(channel, tool_use_id:, stream:)
        @channel = channel
        @tool_use_id = tool_use_id
        @stream = stream
        # Fail fast on a bad stream rather than at first write, deep in a tool.
        Event::ToolOutput.new(tool_use_id:, stream:, bytes: "")
      end

      # Write the string form of each argument. Emits one event per call (never
      # per byte), so a single logical write can never be split mid-line.
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

      # Write each argument's string form with no separators or terminator.
      # Body is identical to {#write}'s -- concatenate, emit -- so it delegates
      # there rather than duplicating the buffer-building loop; only the return
      # value differs, per each method's own `IO` contract.
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

      # No-op flush: events are enqueued synchronously, so there is nothing to
      # push. Returns self, as `IO#flush` does.
      # @return [self]
      def flush
        self
      end

      private

      # Recursively render one `puts` argument into `buffer`, matching the
      # quirks confirmed against real `IO`: an empty array contributes nothing,
      # a nested array is flattened, and a trailing newline is not doubled.
      def append_line(buffer, arg)
        if arg.is_a?(Array)
          arg.each { |element| append_line(buffer, element) }
          return
        end

        string = arg.to_s
        buffer << string
        buffer << "\n" unless string.end_with?("\n")
      end

      # Enqueue attributed bytes, skipping empty writes so we never emit a
      # zero-byte event.
      def emit(bytes)
        return if bytes.empty?

        @channel.push(
          Event::ToolOutput.new(tool_use_id: @tool_use_id, stream: @stream, bytes:)
        )
      end
    end

    # A sink that swallows everything. Satisfies the same IO-shaped duck as
    # {IOAdapter} -- including `#write` returning a byte count -- but sends the
    # bytes nowhere. Handy for muting a tool or in tests.
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
