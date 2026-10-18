# frozen_string_literal: true

require "json"
require "monitor"
require "time"
require "fileutils"

module Lain
  # An append-only NDJSON record of everything worth replaying, one complete JSON
  # object per line. The Journal IS the experiment record, so its contract is
  # losslessness and it does not share the frontend's drop-oldest policy:
  # durability lives here, not in a channel's backpressure.
  #
  # Every {#record} serializes the whole line in memory, then writes it -- newline
  # included -- in a single `write` under a monitor, with the fd in sync mode.
  # Building the bytes before taking the lock keeps the critical section short,
  # apart from the observers {#observe} runs inside it; writing them as one
  # buffer means a line is never torn. The fd is the Journal's own -- a file
  # under {Paths#sessions_dir} by default, a StringIO in specs -- and NEVER stderr.
  #
  # A value that cannot be encoded would otherwise tear a line or swallow an
  # event, so a `JSON` failure is caught and replaced, in the same slot, by a
  # self-describing `journal_error` record: downstream `JSON.parse` never chokes
  # on a Journal line, and the failure is in the record rather than lost.
  #
  # A Journal built with an injected IO does not own it and never closes it.
  # {Journal.open} owns the file it opened and closes it on {#close}.
  class Journal
    class Closed < Error; end

    # Open a Journal on a freshly created session file, owning and later closing
    # it. The default path is a timestamped NDJSON file under {Paths#sessions_dir}
    # (`$XDG_STATE_HOME/lain/sessions/<project-hash>/`).
    #
    # WITH A BLOCK the Journal's lifetime is the block's: it is closed on the
    # way out however the block leaves, which is what a caller that opens a
    # journal for one bounded piece of work wants. Every such caller had
    # written the same eight-line `begin`/`ensure` by hand, and the failure
    # mode of the copy that drifts is a leaked fd and an unclosed record,
    # where {.stem}'s is only a filename. Without a block the caller owns the
    # Journal and must {#close} it -- a chat's journal outlives every method
    # that could bracket it.
    #
    # @param path [String, nil] the file to append to (created, with parents);
    #   defaults to {default_path}
    # @param clock [#call] returns the timestamp string stamped on each record
    # @param fsync [Boolean] fsync the fd after every {#record} -- see {#initialize}
    # @param paths [Paths] resolves the default location; injectable so a spec
    #   never touches the real XDG env
    # @yieldparam journal [Journal] closed when the block returns or raises
    # @return [Journal, Object] the Journal, or what the block answered
    def self.open(path = nil, clock: DEFAULT_CLOCK, fsync: false, paths: Paths.new)
      path ||= default_path(paths:)
      FileUtils.mkdir_p(File.dirname(path))
      # File.new, not the block form: the Journal owns this handle for its whole
      # life. `path:` ONLY when this call created the file -- it is the sole
      # thing licensing #close to unlink, and a file that already existed is
      # somebody else's.
      created = create(path)
      journal = new(io: created || File.new(path, "ab"), clock:, owns_io: true, fsync:, path: created && path)
      return journal unless block_given?

      begin
        yield journal
      ensure
        journal.close
      end
    end

    # O_CREAT|O_EXCL answers the fd only if this call brought the file into
    # existence. Append mode for the same reason the fallback uses "ab": every write
    # lands atomically at end-of-file, never overwriting another writer's bytes.
    # O_EXCL also refuses to create THROUGH a symlink, which is what keeps the unwritten-file cleanup
    # from ever facing a link whose target it measured and whose pointer it
    # would remove.
    def self.create(path)
      File.new(path, File::WRONLY | File::CREAT | File::EXCL | File::APPEND | File::BINARY)
    rescue SystemCallError
      nil
    end
    private_class_method :create

    # The ONE predicate for "this file holds no records at all", shared by the
    # readers that pick a session off a directory listing. An absent path answers
    # true for the same reason a zero-byte one does, so a file reaped between a
    # listing and this call is a skip, never an Errno::ENOENT -- `File.size?` is
    # the idiom that gives both.
    #
    # THE WINDOW: a live session is genuinely zero bytes between {.open} and the
    # moment {SessionRecord::Scribe} writes its header, so this answers true for a
    # session that is starting right now. A byte count cannot tell "never written"
    # from "not written YET", and no cheap predicate can. The cost is not merely a
    # wrong label -- {CLI::Watch} uses this to CHOOSE a file, so a chat starting in
    # the same instant can be passed over for an older session. Naming a file
    # explicitly (`--session`) bypasses the choice, which is why that path stays
    # honored even when the file is empty.
    #
    # @param path [String]
    # @return [Boolean]
    def self.empty?(path) = !File.size?(path)

    # @param paths [Paths] resolves `sessions_dir`; injectable for specs
    # @return [String] a timestamped path under `paths.sessions_dir`
    def self.default_path(paths: Paths.new) = File.join(paths.sessions_dir, stem)

    # What a journal file is CALLED, wherever it lands: UTC to the second, then
    # the pid, so two runs that started in the same second write two files and
    # a directory listing sorts chronologically. A passing run that is not a
    # chat ({CLI::Consolidate}, {CLI::Improve}) journals into its own state
    # container rather than into `sessions`, and takes this name with it --
    # spelled once here, because a third copy of the format is how the two
    # start disagreeing about what a journal is called.
    #
    # @return [String]
    def self.stem = "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}.ndjson"

    DEFAULT_CLOCK = -> { Time.now.utc.iso8601(6) }

    # The ONE duck every Journal reader speaks (see {.records}): an entry is either
    # an already-parsed Hash -- passed through with only its TOP-LEVEL keys
    # stringified, because the record's own reader owns its nested payload -- or
    # one raw NDJSON line. nil for anything that is not one of our records.
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

    # The ONE walk every Journal reader shares. Skipping is the contract, not a
    # convenience: the Journal's own lines always parse, but a file may have been
    # touched by another writer or torn by a crash, so a reader skips what
    # {.parse} answers nil for rather than raising over somebody else's bytes.
    # Lazy, so `records(File.foreach(path))` streams the file without
    # materializing it.
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
      # `path:` is public, so "a file we did not open is never ours to unlink" is
      # enforced HERE rather than trusted to {.open} being its only caller.
      @unwritten = Unwritten.new(owns_io ? path : nil)
      @monitor = Monitor.new
      @closed = false
      @observers = []
      @telling = Set.new.compare_by_identity
      # An event that reached #record is on the fd before the method returns,
      # which is what "synchronous and lossless" means.
      @io.sync = true if @io.respond_to?(:sync=)
    end

    # Accepts a Hash or anything answering `#to_journal` with one (every
    # {Lain::Telemetry} does). The line is built before the lock and written whole
    # under it.
    #
    # @param entry [Hash, #to_journal]
    # @return [self]
    # @raise [Closed] if the Journal has been closed
    def record(entry)
      write_whole("#{encode(entry)}\n", [entry])
    end
    alias << record

    # Several records in ONE write, for records that only make sense together:
    # a process killed between two writes leaves the first alone in the file,
    # and between the records of one write there is no such point.
    #
    # @param entries [Array<Hash, #to_journal>]
    # @return [self]
    # @raise [Closed] if the Journal has been closed
    def record_all(entries)
      write_whole(entries.map { |entry| "#{encode(entry)}\n" }.join, entries)
    end

    # Observers are told under the monitor, after the bytes land, so they fold
    # records in file order, except that a record written from a callback
    # reaches the remaining observers before the record that caused it. An
    # observer is told nothing written during its own callback, whether it or
    # another observer wrote it.
    #
    # Running under the monitor keeps that order across threads, at a price:
    # an observer must be cheap, must not block on a thread that writes this
    # Journal, and must not take a lock held around a write to it elsewhere,
    # or it stalls or deadlocks every writer.
    #
    # An observer receives the entry as given, a Hash or a `#to_journal`
    # object, and must not mutate it. A StandardError it raises becomes a
    # `journal_error` record; anything else reaches the writer, after the
    # record has landed.
    #
    # @param observer [#<<] told each entry after it is written, never on the display
    # @return [self]
    def observe(observer)
      # A new array, so a callback that registers an observer cannot grow the one being walked.
      @monitor.synchronize { @observers = [*@observers, observer] }
      self
    end

    # @return [Boolean]
    def closed?
      @monitor.synchronize { @closed }
    end

    # Idempotent. Closes the underlying IO only if this Journal opened it, and a
    # file this Journal CREATED that is still empty is REMOVED -- see
    # {Unwritten#discard} for why that is so narrow.
    #
    # @return [self]
    def close
      @monitor.synchronize do
        return self if @closed

        @closed = true
        # Judged BEFORE the close, through the fd: that is the only handle on the
        # inode itself -- see {Unwritten#inode}.
        inode = @unwritten.inode(@io)
        @io.close if @owns_io && @io.respond_to?(:close)
        @unwritten.discard(inode)
      end
      self
    end

    private

    def write_whole(bytes, entries)
      @monitor.synchronize do
        raise Closed, "journal is closed" if @closed

        @io.write(bytes)
        @io.fsync if @fsync && @io.respond_to?(:fsync)
        entries.each { |entry| notify(entry) }
      end
      self
    end

    def notify(entry)
      @observers.each { |observer| tell(observer, entry) unless @telling.include?(observer) }
    end

    def tell(observer, entry)
      @telling << observer
      observer << entry
    rescue StandardError => e
      record(observer_error(observer, entry, e))
    ensure
      @telling.delete(observer)
    end

    def observer_error(observer, entry, error)
      {
        "type" => "journal_error", "observer" => observer.class.to_s, "entry_type" => entry_type(entry),
        "error" => "#{error.class}: #{error.message}", "backtrace" => error.backtrace&.first
      }
    end

    def entry_type(entry)
      named = entry.is_a?(Hash) ? entry["type"] || entry[:type] : nil
      (named || entry.class.name).to_s
    end

    # A serialization failure never escapes and never yields a partial line: it
    # becomes a `journal_error` record that still parses, so the stream's
    # line-by-line parseability is total.
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
