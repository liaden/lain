# frozen_string_literal: true

require "json"

module Lain
  class Provider
    class ResponseWal
      # Recovers {Entry}s from the bytes on disk. This is a DELIMITER SCAN over
      # RS-separated records, not length-framing -- the terminator's byte count
      # is a completeness checksum, never a seek distance (see the invariant in
      # response_wal.rb's header).
      #
      # A record is classified by its first line: a header (carries
      # "request_digest") opens a frame whose raw bytes follow the newline; a
      # terminator (carries "bytes") settles the open frame. The reader RESYNCS
      # rather than blind-pairing: a header arriving while a frame is still open
      # means that frame was abandoned terminator-less (retry exhaustion, a
      # terminal error, a SIGKILL followed by --resume on the same file), so it
      # is emitted incomplete and the header starts fresh -- every later frame
      # stays readable. A record that is neither header nor terminator is a torn
      # tail if it ends the file (emitted incomplete), and {CorruptFrame} -- loud,
      # never a silent mis-slot -- anywhere else, because mid-file it can only
      # mean a payload smuggled the record separator.
      #
      # == Tolerant mode
      #
      # `tolerant: true` swaps every mid-file refusal for a {Corrupt} marker and
      # a resync on the next header, so a corrupt region cannot hide a clean
      # frame written after it. The strict mode's job is to trust `complete`
      # loudly; the tolerant mode's job is to let a salvage pass still reach a
      # paid-for response beyond a legacy mis-slot (see {ResponseWal#frames}
      # vs {ResponseWal#salvageable_frames}).
      class Reader
        # A frame whose header has been read but whose terminator has not.
        Open = Data.define(:request_digest, :raw)

        # A mis-slotted region that tolerant mode skipped. Its `reason` names why
        # the scan could not trust the bytes there; a caller partitions it from a
        # real {Entry} by `#corrupt?`.
        Corrupt = Data.define(:reason) do
          def corrupt? = true
        end

        def initialize(data, tolerant: false)
          @records = data.split(RECORD_SEPARATOR, -1)
          @tolerant = tolerant
        end

        def each(&emit)
          return enum_for(:each) unless block_given?

          raise CorruptFrame, "bytes precede the first frame header" unless @records.fetch(0, "").empty?

          frames = @records.drop(1)
          open = frames.each_with_index.inject(nil) do |pending, (record, index)|
            fold(pending, record, tail: index == frames.size - 1, &emit)
          end
          emit.call(torn(open)) if open
        end

        private

        def fold(open, record, tail:, &emit)
          line, _newline, rest = record.partition("\n")
          json = parse_line(line)
          return begin_frame(json, rest, open, &emit) if json&.key?("request_digest")
          return finish_frame(json, rest, open, &emit) if json&.key?("bytes")

          unrecognized(record, open, tail:, &emit)
        end

        def begin_frame(json, raw, open)
          yield torn(open) if open
          Open.new(request_digest: json["request_digest"], raw:)
        end

        def finish_frame(json, rest, open, &emit)
          return corrupt("terminator record with no open frame", &emit) if open.nil?
          return corrupt("bytes trail a terminator record", &emit) unless rest.empty?

          emit.call(Entry.new(request_digest: open.request_digest, bytes: open.raw,
                              complete: json["complete"] == true && json["bytes"] == open.raw.bytesize))
          nil
        end

        def unrecognized(record, open, tail:, &emit)
          return torn_tail(open, &emit) if tail

          corrupt("unrecognized record mid-file (payload smuggled the record separator?): " \
                  "#{record[0, 40].inspect}", &emit)
        end

        def torn_tail(open, &emit)
          emit.call(open ? torn(open) : Entry.new(request_digest: nil, bytes: "", complete: false))
          nil
        end

        # Strict mode refuses; tolerant mode drops the mis-slotted region as a
        # {Corrupt} marker and resyncs (the open frame is abandoned, the next
        # header starts fresh), so a clean frame after the corruption still reads.
        def corrupt(reason, &emit)
          raise CorruptFrame, reason unless @tolerant

          emit.call(Corrupt.new(reason:))
          nil
        end

        def torn(open)
          Entry.new(request_digest: open.request_digest, bytes: open.raw, complete: false)
        end

        def parse_line(line)
          parsed = JSON.parse(line)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
