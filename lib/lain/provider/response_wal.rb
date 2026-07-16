# frozen_string_literal: true

require "json"
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
      end

      # A single frame's write handle: the transport appends raw chunks and closes
      # it, and never learns what a request digest is.
      class Frame
        def initialize(io, watermark:)
          @io = io
          @watermark = watermark
          @bytes = 0
          @unsynced = 0
        end

        def append(chunk)
          @io.write(chunk)
          @bytes += chunk.bytesize
          @unsynced += chunk.bytesize
          fsync_watermark
          self
        end

        def close(complete:)
          @io.write("#{RECORD_SEPARATOR}#{JSON.generate("bytes" => @bytes, "complete" => complete)}\n")
          @io.fsync
          nil
        end

        private

        def fsync_watermark
          return if @unsynced < @watermark

          @io.fsync
          @unsynced = 0
        end
      end

      def initialize(path, fsync_watermark: FSYNC_WATERMARK)
        @path = path
        @fsync_watermark = fsync_watermark
      end

      # Opens a frame for one round trip. The header lands immediately (the file
      # is unbuffered), so a crash before the first byte still leaves a readable,
      # incomplete frame.
      def open_frame(request_digest:)
        writer.write("#{RECORD_SEPARATOR}#{JSON.generate("request_digest" => request_digest,
                                                         "at" => Time.now.utc.iso8601)}\n")
        Frame.new(writer, watermark: @fsync_watermark)
      end

      # @return [Enumerator<Entry>] every frame in the file, in write order, each
      #   carrying its verbatim bytes and whether it terminated cleanly.
      #   Entry#bytes is ASCII-8BIT (the file is read with binread); callers
      #   must `force_encoding(Encoding::UTF_8)` before SSE/JSON parsing.
      def frames
        return [].each unless File.exist?(@path)

        Reader.new(File.binread(@path)).each
      end

      def close
        @writer&.close
        @writer = nil
      end

      private

      # A long-lived append handle spanning every frame of the session, so the
      # block form does not apply; #close owns its lifetime. `sync: true` pushes
      # each write straight to the OS, so a SIGKILL leaves the bytes recoverable.
      def writer
        @writer ||= File.open(@path, "ab").tap { |io| io.sync = true } # rubocop:disable Style/FileOpen
      end
    end
  end
end

# After the class body: Reader references Entry, CorruptFrame, and
# RECORD_SEPARATOR through the ResponseWal namespace.
require_relative "response_wal/reader"
