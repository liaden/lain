# frozen_string_literal: true

require "json"
require "monitor"
require "time"
require "fileutils"

require_relative "error"

module Lain
  # An append-only NDJSON record of everything worth replaying: one event per
  # line, each line a complete JSON object. The Journal IS the experiment record,
  # so its contract is losslessness -- it must never drop an event -- and that is
  # exactly why it does not share the frontend's drop-oldest policy. Durability
  # lives here, not in a channel's backpressure.
  #
  # == Synchronous, under a mutex, on its own fd
  #
  # Every {#record} serializes the whole line in memory, then writes it -- newline
  # included -- in a single `write` under a monitor, with the fd in sync mode.
  # Building the bytes before taking the lock keeps the critical section short;
  # writing them as one buffer means a line is never torn, the same discipline the
  # Rust `SharedWriter` follows so Ruby events and Rust `tracing` spans can share
  # one fd and still parse line by line. The fd is the Journal's own -- a file
  # under `.lain/sessions/` by default, a StringIO in specs -- and NEVER stderr.
  #
  # == Every line parses, even when serialization fails
  #
  # Losslessness would be a lie if a value that cannot be encoded produced a torn
  # line or a swallowed event. So a `JSON` failure is caught and replaced, in the
  # same slot, by a self-describing `journal_error` record. Downstream `JSON.parse`
  # never chokes on a Journal line, and the failure is in the record rather than
  # lost -- the two invariants the Journal exists to guarantee.
  #
  # == Ownership
  #
  # A Journal built with an injected IO does not own it and never closes it (the
  # caller's fd is the caller's). {Journal.open}, which opens the file itself, owns
  # that file and closes it on {#close}. This mirrors the Rust side, which `dup`s
  # the fd precisely so dropping one writer never closes the other's descriptor.
  class Journal
    class Closed < Error; end

    SESSIONS_DIR = ".lain/sessions"

    # Open a Journal on a freshly created session file, owning and later closing
    # it. The default path is a timestamped NDJSON file under `.lain/sessions/`.
    #
    # @param path [String] the file to append to (created, with parents)
    # @param clock [#call] returns the timestamp string stamped on each record
    # @return [Journal]
    def self.open(path = default_path, clock: DEFAULT_CLOCK)
      FileUtils.mkdir_p(File.dirname(path))
      # Append mode so a shared fd (ours and a dup handed to Rust tracing) writes
      # atomically at end-of-file, never overwriting the other's bytes. File.new
      # (not the block form) because the Journal OWNS this handle for its whole
      # life and closes it in #close -- there is no scope to hand it to.
      io = File.new(path, "ab")
      new(io: io, clock: clock, owns_io: true)
    end

    # @return [String] a timestamped path under {SESSIONS_DIR}
    def self.default_path
      File.join(SESSIONS_DIR, "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}.ndjson")
    end

    DEFAULT_CLOCK = -> { Time.now.utc.iso8601(6) }

    # The ONE duck every Journal reader speaks (see {.records}): an entry is
    # either an already-parsed Hash (passed through with its TOP-LEVEL keys
    # string-keyed -- nested hashes keep their keys, the record's reader owns
    # its payload) or one raw NDJSON line (parsed). Answers the record Hash, or
    # nil for anything that is not one of our records.
    #
    # @param entry [Hash, String]
    # @return [Hash{String=>Object}, nil]
    def self.parse(entry)
      return entry.transform_keys(&:to_s) if entry.is_a?(Hash)

      parsed = JSON.parse(entry.to_s)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # The ONE walk every Journal reader shares (see {Handler::Recorded.from_journal},
    # {Ledger::Index.from_journal}): each entry coerced through {.parse}, foreign
    # lines skipped, optionally narrowed to a single record type.
    #
    # Skipping is the contract, not a convenience: the Journal's own lines always
    # parse, but its fd can be shared with other writers (Rust tracing spans), so
    # a reader skips what {.parse} answers nil for rather than raising over
    # somebody else's bytes. Lazy, so `records(File.foreach(path))` streams the
    # file without materializing it.
    #
    # @param entries [Enumerable<Hash, String>]
    # @param type [String, Symbol, nil] keep only records of this type, when given
    # @return [Enumerator::Lazy<Hash{String=>Object}>]
    def self.records(entries, type: nil)
      records = entries.lazy.filter_map { |entry| parse(entry) }
      type.nil? ? records : records.select { |record| record["type"].to_s == type.to_s }
    end

    # @param io [IO, StringIO] the destination the Journal writes to
    # @param clock [#call] returns the timestamp string stamped on each record
    # @param owns_io [Boolean] whether {#close} should close `io`
    def initialize(io:, clock: DEFAULT_CLOCK, owns_io: false)
      @io = io
      @clock = clock
      @owns_io = owns_io
      @monitor = Monitor.new
      @closed = false
      # Unbuffered writes: an event that reached #record is on the fd before the
      # method returns, which is what "synchronous and lossless" means.
      @io.sync = true if @io.respond_to?(:sync=)
    end

    # Append one event as a single NDJSON line. Accepts a Hash (written as-is) or
    # anything answering `#to_journal` with a Hash (every {Lain::Event} does). The
    # line is built before the lock and written whole under it.
    #
    # @param entry [Hash, #to_journal]
    # @return [self]
    # @raise [Closed] if the Journal has been closed
    def record(entry)
      line = "#{encode(entry)}\n"
      @monitor.synchronize do
        raise Closed, "journal is closed" if @closed

        @io.write(line)
      end
      self
    end
    alias << record

    # The underlying fd, for handing to the Rust tracing subscriber so its spans
    # merge into this same NDJSON stream. `nil` for an IO with no descriptor (a
    # StringIO), which simply means no Rust side shares it.
    #
    # @return [Integer, nil]
    def fileno
      @io.respond_to?(:fileno) ? @io.fileno : nil
    rescue IOError
      nil
    end

    # @return [Boolean]
    def closed?
      @monitor.synchronize { @closed }
    end

    # Stop accepting records. Closes the underlying IO only if this Journal opened
    # it; an injected fd is the caller's to close. Idempotent.
    #
    # @return [self]
    def close
      @monitor.synchronize do
        return self if @closed

        @closed = true
        @io.close if @owns_io && @io.respond_to?(:close)
      end
      self
    end

    private

    # Build the JSON object for `entry`, stamped with a timestamp. A serialization
    # failure never escapes and never yields a partial line: it becomes a
    # `journal_error` record that still parses, so the stream's line-by-line
    # parseability is total.
    def encode(entry)
      JSON.generate(record_hash(entry))
    rescue StandardError => e
      JSON.generate(
        "ts" => timestamp,
        "type" => "journal_error",
        "error" => "#{e.class}: #{e.message}",
        "entry_class" => entry.class.name
      )
    end

    def record_hash(entry)
      hash = entry.respond_to?(:to_journal) ? entry.to_journal : entry
      unless hash.is_a?(Hash)
        raise TypeError,
              "journal entry must be a Hash or respond to #to_journal, got #{hash.class}"
      end

      { "ts" => timestamp }.merge(hash.transform_keys(&:to_s))
    end

    def timestamp
      @clock.call
    end
  end
end
