# frozen_string_literal: true

require "json"
require "monitor"
require "time"

module Lain
  class Provider
    # An append-only write-ahead log of raw provider response bytes: one file per
    # session (`<session-stem>.wal` beside the NDJSON), one frame per round trip.
    #
    # It is a {Spool} -- the Provider opens a frame with the request digest it
    # alone computes, and the transport only appends chunks and closes. The bytes
    # spooled are EXACTLY what came off the wire (SSE lines, or a sync body before
    # JSON parsing), never a re-serialization: that verbatim property is the whole
    # point, since a salvage pass rebuilds a turn by re-parsing these bytes.
    #
    # == Frame format, and what the reader actually trusts
    #
    # A frame is a header record, the raw bytes, then a terminator record:
    #
    #   RS {"request_digest":..,"at":..}\n <raw bytes> RS {"bytes":N,"complete":b}\n
    #
    # This is DELIMITER framing, not length framing: {Reader} scans for RS
    # (ASCII 0x1E, RFC 7464 json-seq's separator) and uses the terminator's byte
    # count only as a completeness CHECKSUM, never as a seek distance. The
    # invariant that makes the scan sound is RS-absence in payloads -- Anthropic
    # escapes C0 controls in its JSON/SSE output, the same trust shape as
    # NDJSON's no-embedded-newline -- and it is trusted loudly, not silently:
    # an embedded RS mis-slots a record mid-file and the reader refuses with
    # {CorruptFrame} rather than let completeness lie.
    #
    # A frame is COMPLETE only when its terminator is present, marks
    # `complete: true`, and its byte count matches the bytes on disk. A frame
    # abandoned terminator-less -- crash, retry exhaustion, a terminal error --
    # reads as incomplete, and the reader RESYNCS on the next header so every
    # later frame in the session stays readable (see {Reader}).
    #
    # == One file, many fibers: no interleaved records, ever
    #
    # T17w lets the main Agent and every subagent share ONE spool, and parallel
    # subagents fan out as sibling async fibers that all reach this ONE file.
    # Async fibers yield to the scheduler on socket IO, so two frames' writes
    # could interleave AT RECORD GRANULARITY -- and an interleaved record is
    # exactly the corruption {Reader} refuses ("bytes trail a terminator
    # record"), which would make a crashed parallel-subagent session
    # unresumable. Two guards make interleaving structurally impossible:
    #
    # 1. Every write to the file goes through {@monitor}. A single `write` never
    #    tears, whatever the fiber scheduler does around it.
    # 2. At most ONE frame streams incrementally to the file at a time -- the
    #    frame that opened while no other FIBER's stream was live. It writes its
    #    header, chunks, and terminator as a CONTIGUOUS run (nothing else may
    #    write between them, or its bytes would straddle another frame and the
    #    Reader's scan would mis-slot). Every frame opened concurrently, from a
    #    DIFFERENT fiber, buffers its whole header+bytes+terminator in memory and
    #    lands as ONE atomic locked write at close; if the streaming frame is
    #    still live at that close, the blob waits in {@pending} and the streaming
    #    frame flushes it when it closes, so no buffered blob is ever written
    #    mid-stream. Frames are response-sized (bounded by max_tokens), so the
    #    buffer memory is a fine trade on a study bench.
    #
    # The fiber test is what tells abandonment apart from concurrency: a frame
    # left terminator-less by retry exhaustion or a terminal error is never
    # closed, but the SAME fiber's next round trip proves the abandoned one is
    # done (one fiber is never in two dispatches at once), so the new frame takes
    # over the streaming slot and the abandoned partial stays a torn, reviewable
    # tail. A DIFFERENT fiber opening mid-stream is a genuine parallel subagent,
    # so it buffers.
    #
    # DURABILITY TRADE, stated honestly. The SERIAL case (one frame open at a
    # time -- the overwhelming common case, and every non-subagent session) is
    # byte-identical to before: it streams, mid-stream watermark fsyncs land
    # durably well before the terminator, and a SIGKILL mid-stream leaves a torn
    # partial the Reader surfaces incomplete -- a reviewable artifact, the plan's
    # decision 5.
    #
    # A CONCURRENTLY-buffered frame gives that up entirely: its bytes live in
    # memory, unwritten, until a DRAIN POINT flushes {@pending} -- the live
    # streaming frame closing, a same-fiber takeover of the streaming slot, or
    # the spool closing. Between its own `close` and the next drain point the
    # frame is COMPLETE but not yet on disk, so a SIGKILL there loses a WHOLE
    # completed buffered frame, not merely a partial -- the buffered case has no
    # reviewable-torn-tail consolation the streaming case has. (A graceful spool
    # close always drains, so a clean exit never loses one; only a SIGKILL in
    # that window does.) Only the second-and-later of a set of genuinely
    # simultaneous frames pays this; the streaming sibling still leaves its own
    # reviewable partial.
    class ResponseWal
      # An impossible record shape mid-file. Raised, never skipped: a reader
      # that guesses across corruption cannot promise `complete` is true.
      class CorruptFrame < Lain::Error; end
      # RFC 7464 record separator; see the class comment for why RS and not \n.
      RECORD_SEPARATOR = "\x1e"

      # fsync mid-stream every 64 KiB so a long stream is durable well before its
      # terminator, without paying an fsync per token-sized SSE chunk. The file is
      # opened `sync: true`, so every write already reaches the OS (a SIGKILL
      # leaves the bytes recoverable); the watermark fsync is the disk-durability
      # knob on top of that.
      FSYNC_WATERMARK = 64 * 1024

      Entry = Data.define(:request_digest, :bytes, :complete) do
        def complete? = complete
        # Distinguishes a real frame from a {Reader::Corrupt} marker in a
        # tolerant enumeration, so a caller (see {SessionRecord::Salvage}) can
        # partition the two without type-sniffing.
        def corrupt? = false
      end

      # The streaming frame: the sole frame permitted to write to the file
      # incrementally (see the class comment). Its header was written when it
      # opened; it appends raw chunks and, at close, writes its terminator and
      # flushes any buffered siblings that closed while it was live.
      class StreamingFrame
        def initialize(wal:, watermark:)
          @wal = wal
          @watermark = watermark
          @bytes = 0
          @unsynced = 0
        end

        def append(chunk)
          @bytes += chunk.bytesize
          @unsynced += chunk.bytesize
          fsync = @unsynced >= @watermark
          @wal.append_streaming(chunk, fsync:)
          @unsynced = 0 if fsync
          self
        end

        def close(complete:)
          @wal.close_streaming(self, ResponseWal.terminator_record(@bytes, complete))
          nil
        end
      end

      # A frame opened while another was already streaming: it buffers its whole
      # header+bytes+terminator in memory (binary, so wire bytes and the ASCII
      # JSON records concatenate without an encoding clash) and lands as ONE
      # atomic locked write at close -- never mid-stream.
      class BufferedFrame
        def initialize(wal:, header:)
          @wal = wal
          @buffer = String.new(header, encoding: Encoding::BINARY)
          @bytes = 0
        end

        def append(chunk)
          @buffer << chunk.b
          @bytes += chunk.bytesize
          self
        end

        def close(complete:)
          @buffer << ResponseWal.terminator_record(@bytes, complete).b
          @wal.flush_buffered(@buffer)
          nil
        end
      end

      # @return [String] a header record naming the request digest and open time.
      def self.header_record(request_digest)
        "#{RECORD_SEPARATOR}#{JSON.generate("request_digest" => request_digest, "at" => Time.now.utc.iso8601)}\n"
      end

      # @return [String] a terminator record: the byte count is a completeness
      #   CHECKSUM (see the class comment), never a seek distance.
      def self.terminator_record(bytes, complete)
        "#{RECORD_SEPARATOR}#{JSON.generate("bytes" => bytes, "complete" => complete)}\n"
      end

      def initialize(path, fsync_watermark: FSYNC_WATERMARK)
        @path = path
        @fsync_watermark = fsync_watermark
        @monitor = Monitor.new
        @streaming = nil
        @streaming_fiber = nil
        @pending = []
      end

      # Opens a frame for one round trip. If no frame is currently streaming this
      # one streams (its header lands immediately, so a crash before the first
      # byte still leaves a readable, incomplete frame); otherwise it buffers so
      # its records never interleave with the live stream's (see the class
      # comment).
      def open_frame(request_digest:)
        @monitor.synchronize do
          header = ResponseWal.header_record(request_digest)
          stream_here?(Fiber.current) ? begin_streaming(header) : BufferedFrame.new(wal: self, header:)
        end
      end

      # @return [Enumerator<Entry>] every frame in the file, in write order, each
      #   carrying its verbatim bytes and whether it terminated cleanly. Refuses
      #   loudly ({CorruptFrame}) on a mis-slotted record. Entry#bytes is
      #   ASCII-8BIT (binread); callers `force_encoding` before SSE/JSON parsing.
      def frames
        return [].each unless File.exist?(@path)

        Reader.new(File.binread(@path)).each
      end

      # @return [Enumerator<Entry, Reader::Corrupt>] like {#frames}, but resyncs
      #   past a mis-slotted region instead of raising -- a corrupt region is
      #   surfaced as a {Reader::Corrupt} marker so a salvage pass can still
      #   select a clean target frame beyond it (a corrupt region elsewhere must
      #   not abort recovery of a paid-for response).
      def salvageable_frames
        return [].each unless File.exist?(@path)

        Reader.new(File.binread(@path), tolerant: true).each
      end

      def close
        @monitor.synchronize do
          # A streaming frame abandoned terminator-less (terminal error / retry
          # exhaustion) never drains @pending, so completed buffered siblings can
          # still be queued at a CLEAN spool close -- flush them or lose a
          # paid-for response. They land after the abandoned torn tail, which the
          # Reader already resyncs past, so no interleaving is reintroduced.
          flush_pending
          @writer&.close
          @writer = nil
        end
      end

      # Called only by a {StreamingFrame}: append a chunk under the lock, so it
      # cannot tear against a buffered sibling's flush.
      def append_streaming(chunk, fsync:)
        @monitor.synchronize do
          writer.write(chunk)
          writer.fsync if fsync
        end
      end

      # Called only by a {StreamingFrame}: write its terminator, then drain every
      # sibling that buffered-and-closed while it was live -- all under one lock,
      # so the drained blobs land contiguously after this frame, never inside it.
      def close_streaming(frame, terminator)
        @monitor.synchronize do
          # A no-op once the frame was abandoned and another took over the slot
          # (see the fiber note): writing its terminator now would land inside
          # the successor's stream.
          write_terminator_and_drain(terminator) if @streaming.equal?(frame)
        end
      end

      # Called only by a {BufferedFrame} at close: write its blob now if no frame
      # is streaming, else queue it for the streaming frame to drain (writing it
      # now could land mid-stream).
      def flush_buffered(blob)
        @monitor.synchronize do
          if @streaming.nil?
            writer.write(blob)
            writer.fsync
          else
            @pending << blob
          end
        end
      end

      private

      # Caller holds the lock. Streams iff the slot is free, or this fiber
      # already owns it -- a same-fiber reopen means the prior frame was
      # abandoned, so the new one takes over (see the fiber note).
      def stream_here?(fiber)
        @streaming.nil? || @streaming_fiber.equal?(fiber)
      end

      # Caller holds the lock. On a same-fiber TAKEOVER the predecessor was
      # abandoned, so its queued buffered siblings must land NOW (after its torn
      # tail, before this header) rather than be stranded; then this frame writes
      # its header and claims the slot.
      def begin_streaming(header)
        flush_pending
        writer.write(header)
        @streaming_fiber = Fiber.current
        @streaming = StreamingFrame.new(wal: self, watermark: @fsync_watermark)
      end

      # Caller holds the lock.
      def write_terminator_and_drain(terminator)
        writer.write(terminator)
        writer.fsync
        drain
      end

      # Caller holds the lock: the streaming slot is free again, so its queued
      # buffered siblings can land contiguously.
      def drain
        @streaming = nil
        @streaming_fiber = nil
        flush_pending
      end

      # Caller holds the lock. Writes every queued buffered-sibling blob (each a
      # complete atomic frame) and clears the queue. A no-op when empty -- and
      # only then is the writer left untouched, so a spool that spooled nothing
      # never creates an empty file. When non-empty the writer is guaranteed
      # present: a blob only queues while a streaming frame is live, which opened
      # the writer.
      def flush_pending
        return if @pending.empty?

        @pending.each do |blob|
          writer.write(blob)
          writer.fsync
        end
        @pending = []
      end

      # A long-lived append handle spanning every frame of the session, so the
      # block form does not apply; #close owns its lifetime. `sync: true` pushes
      # each write straight to the OS, so a SIGKILL leaves the bytes recoverable.
      # Only ever touched under {@monitor}.
      def writer
        @writer ||= File.open(@path, "ab").tap { |io| io.sync = true } # rubocop:disable Style/FileOpen
      end
    end
  end
end

# After the class body: Reader references Entry, CorruptFrame, and
# RECORD_SEPARATOR through the ResponseWal namespace.
require_relative "response_wal/reader"
