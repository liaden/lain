# frozen_string_literal: true

require "json"
require "monitor"
require "time"
require "fileutils"

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
  # under {Paths#sessions_dir} by default, a StringIO in specs -- and NEVER stderr.
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

    # Open a Journal on a freshly created session file, owning and later closing
    # it. The default path is a timestamped NDJSON file under {Paths#sessions_dir}
    # (`$XDG_STATE_HOME/lain/sessions/<project-hash>/`).
    #
    # @param path [String, nil] the file to append to (created, with parents);
    #   defaults to {default_path}
    # @param clock [#call] returns the timestamp string stamped on each record
    # @param fsync [Boolean] fsync the fd after every {#record} -- see {#initialize}
    # @param paths [Paths] resolves the default location; injectable so a spec
    #   never touches the real XDG env
    # @return [Journal]
    def self.open(path = nil, clock: DEFAULT_CLOCK, fsync: false, paths: Paths.new)
      path ||= default_path(paths:)
      FileUtils.mkdir_p(File.dirname(path))
      # File.new (not the block form) because the Journal OWNS this handle for
      # its whole life and closes it in #close -- there is no scope to hand it
      # to. `path:` ONLY when this call created the file: it is the sole thing
      # licensing #close to unlink, and a file that already existed is somebody
      # else's (see {#discard_unwritten}).
      created = create(path)
      new(io: created || File.new(path, "ab"), clock:, owns_io: true, fsync:, path: created && path)
    end

    # O_CREAT|O_EXCL: answers the fd only if this call brought the file into
    # existence, nil if the name was already taken. Append mode for the same
    # reason the fallback uses "ab" -- a shared fd (ours plus a dup handed to
    # Rust tracing) writes atomically at end-of-file, never overwriting the
    # other's bytes -- and binary so the bytes on the wire are unchanged.
    #
    # O_EXCL also refuses to create THROUGH a symlink, which is what keeps
    # {#discard_unwritten} from ever facing a link whose target it measured and
    # whose pointer it would remove.
    def self.create(path)
      File.new(path, File::WRONLY | File::CREAT | File::EXCL | File::APPEND | File::BINARY)
    rescue SystemCallError
      nil
    end
    private_class_method :create

    # The ONE predicate for "this file holds no records at all", shared by the
    # readers that pick a session off the directory listing ({Resume::Selector},
    # {CLI::Watch}, {CLI::Sessions}). An absent path answers true for the same
    # reason a zero-byte one does -- there is nothing in it to read -- so a file
    # reaped between a listing and this call is a skip, never an Errno::ENOENT.
    #
    # `File.size?` is the idiom that gives both: nil for empty AND for absent.
    #
    # THE WINDOW: a live session is genuinely zero bytes between {.open} and the
    # moment {SessionRecord::Scribe} writes its header, so this answers true for
    # a session that is starting right now. A byte count cannot tell "never
    # written" from "not written YET", and no cheap predicate can. The cost is
    # not merely a wrong label: {CLI::Watch} uses this to CHOOSE a file, so a
    # chat starting in the same instant can be passed over for an older session.
    # Naming a file explicitly (`--session`) bypasses the choice entirely, which
    # is why that path stays honored even when the file is empty.
    #
    # @param path [String]
    # @return [Boolean]
    def self.empty?(path) = !File.size?(path)

    # @param paths [Paths] resolves `sessions_dir`; injectable for specs
    # @return [String] a timestamped path under `paths.sessions_dir`
    def self.default_path(paths: Paths.new)
      File.join(paths.sessions_dir, "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}.ndjson")
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

    # The ONE walk every Journal reader shares (see {Effect::Handler::Recorded.from_journal},
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
    # @param fsync [Boolean] fsync `io` after every {#record} that lands, so a
    #   crash between the write and the OS's own flush can't lose it. Silently a
    #   no-op on an `io` that truly lacks `#fsync` (note StringIO is NOT such an
    #   IO -- it answers `#fsync` as a no-op itself) -- this is a durability
    #   upgrade, never a new failure mode.
    # @param path [String, nil] the file this Journal opened and may therefore
    #   remove when it closes still empty (see {#close}); nil for an injected
    #   IO, whose file is the caller's and never ours to unlink
    def initialize(io:, clock: DEFAULT_CLOCK, owns_io: false, fsync: false, path: nil)
      @io = io
      @clock = clock
      @owns_io = owns_io
      @fsync = fsync
      # `path:` is public, so the "a file we did not open is never ours to
      # unlink" rule is applied HERE rather than trusted to {.open} happening to
      # be the only caller that passes one.
      @unwritten = Unwritten.new(owns_io ? path : nil)
      @monitor = Monitor.new
      @closed = false
      # Unbuffered writes: an event that reached #record is on the fd before the
      # method returns, which is what "synchronous and lossless" means.
      @io.sync = true if @io.respond_to?(:sync=)
    end

    # Append one event as a single NDJSON line. Accepts a Hash (written as-is) or
    # anything answering `#to_journal` with a Hash (every {Lain::Telemetry} does). The
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
        @io.fsync if @fsync && @io.respond_to?(:fsync)
      end
      self
    end
    alias << record

    # Hand this Journal's descriptor to another writer -- the Rust tracing
    # subscriber dups it (`dup_writer` in ext/lain) so its spans merge into this
    # same NDJSON stream. `nil` for an IO with no descriptor (a StringIO), which
    # simply means nothing can share it.
    #
    # Sharing is a COMMITMENT, and it is what this method exists to NAME: the
    # receiver may land bytes long after we stop looking, so a shared Journal
    # retires {#discard_unwritten} for good. Those writes would otherwise go to
    # an inode we had already unlinked -- invisibly, since nothing on this side
    # can see them coming. Asking for the number and asking to share are the
    # same act, but only one of them says so, and the cleanup policy has to turn
    # on a decision a caller made deliberately.
    #
    # @return [Integer, nil]
    def share_fd
      @monitor.synchronize { @unwritten.shared! }
      descriptor
    end

    # Conservatively an alias for {#share_fd}: a descriptor that leaves this
    # object may be written through whatever the caller meant by asking, so the
    # disarm cannot be the thing a caller has to remember. New callers say
    # {#share_fd}.
    #
    # @return [Integer, nil]
    def fileno = share_fd

    # @return [Boolean]
    def closed?
      @monitor.synchronize { @closed }
    end

    # Stop accepting records. Closes the underlying IO only if this Journal opened
    # it; an injected fd is the caller's to close. Idempotent.
    #
    # A file this Journal CREATED and that is still empty at close is REMOVED --
    # see {Unwritten#discard} for which files that is and why it is so narrow.
    #
    # @return [self]
    def close
      @monitor.synchronize do
        return self if @closed

        @closed = true
        # Judged BEFORE the close, through the fd, because that is the only
        # handle on the inode itself -- see {Unwritten#inode}.
        inode = @unwritten.inode(@io)
        @io.close if @owns_io && @io.respond_to?(:close)
        @unwritten.discard(inode)
      end
      self
    end

    private

    def descriptor
      @io.respond_to?(:fileno) ? @io.fileno : nil
    rescue IOError
      nil
    end

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

# At the bottom, not the top: Unwritten reopens Lain::Journal to nest itself, so
# the class has to exist first ({CLI::Watch}'s LineageFilter, same shape). Only
# ever constructed at runtime from #initialize, so nothing above needs it.
require_relative "journal/unwritten"
