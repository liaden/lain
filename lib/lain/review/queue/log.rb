# frozen_string_literal: true

require "json"
require "time"

module Lain
  module Review
    class Queue
      # The queue's memory: an append-only NDJSON file that readers fold, as a
      # session is. Many processes write it, so an append is one `O_APPEND`
      # `syswrite` of one whole line and takes no lock; that holds on a local
      # disk only, since `O_APPEND` is not atomic over NFS.
      # Each record starts with a newline, so the file's first line is always
      # blank by design and the fold skips it.
      class Log
        KINDS = %i[opened notified offered listed].freeze
        LIMIT = 1_048_576

        Event = Data.define(:kind, :at, :row_id, :head_sha) do
          def initialize(kind:, at:, row_id:, head_sha:)
            raise ArgumentError, "unknown queue event kind #{kind.inspect}" unless KINDS.include?(kind)

            super
          end
        end

        # What the last fold skipped, one note per unreadable line.
        # @return [Array<String>]
        attr_reader :notes

        def initialize(paths:, clock: -> { Time.now })
          @path = paths.review_queue_log
          @clock = clock
          @notes = []
        end

        # Every record opens with "\n", so a crash mid-write leaves a torn
        # record that ends at the next record's own newline, with no read
        # before the write for a concurrent appender to race.
        #
        # @param event [Event] stamped from the clock when it carries no time
        def append(event)
          record = "\n#{JSON.generate(kind: event.kind, at: (event.at || @clock.call).utc.iso8601(6),
                                      row_id: event.row_id, head_sha: event.head_sha)}"
          File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |io|
            written = io.syswrite(record)
            unless written == record.bytesize
              raise IOError,
                    "short write to #{@path}: #{written} of #{record.bytesize} bytes"
            end
          end
        end

        # @param row [Queue::Row]
        def seen?(row) = events.any? { |e| e.kind == :opened && e.row_id == row.id && e.head_sha == row.head_sha }

        def notified?(row_id) = events.any? { |e| e.kind == :notified && e.row_id == row_id }

        # @return [Time, nil]
        def last_listed_at = events.select { |e| e.kind == :listed }.map(&:at).max

        # Rotation, not deletion: an appender that opened the file before the
        # rename keeps writing into the inode, which is now log.1, still read.
        # A second rotation replaces log.1, so history older than one rotation
        # is gone by design. The inode check narrows the case of a slow pruner
        # renaming the fresh log another one left behind over the log it just
        # rotated; a window between the check and the rename remains.
        def prune
          sized = File.stat(@path)
          File.rename(@path, "#{@path}.1") if sized.size > LIMIT && File.stat(@path).ino == sized.ino
        rescue Errno::ENOENT
          nil
        end

        private

        def events
          @notes = []
          [@path, "#{@path}.1"].flat_map { |file| lines(file).filter_map { |line| parse(line) } }
        end

        # The live file first: a rotation between the two reads moves its rows
        # into log.1, which is read after, so they are read twice and never
        # missed. A file that rotates away under the open is simply absent.
        def lines(file)
          File.open(file, &:readlines)
        rescue Errno::ENOENT
          []
        end

        def parse(line)
          return if line.strip.empty?

          record = JSON.parse(line)
          Event.new(kind: record.fetch("kind").to_sym, at: Time.iso8601(record.fetch("at")),
                    row_id: record["row_id"], head_sha: record["head_sha"])
        rescue JSON::ParserError, KeyError, ArgumentError, NoMethodError
          @notes << "skipped a torn or malformed queue log line: #{line.byteslice(0, 40).inspect}"
          nil
        end
      end
    end
  end
end
