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
  # buffer means a line is never torn. A chained Journal finishes each line
  # under the monitor instead, because its link names the line written just
  # before it, and only the lock knows which line that is. The fd is the Journal's own -- a file
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

    # Another writer holds a chained file. Two appenders would each keep their
    # own tip and fork the chain, so the second is refused rather than let in.
    class Locked < Error; end

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
    # @param root [String, nil] the project root the default location is keyed
    #   on; the working directory when nil
    # @param chain [Boolean] end each line with the link to the line before it,
    #   continuing from the file's last line, sealing it first when a crash
    #   left it without its newline. A chained Journal holds an exclusive flock
    #   for its life and an unchained one a shared flock, so unchained logs
    #   still share a file while nothing else can append to a chained one. A
    #   forked child must not write a chained Journal: the lock and the tip
    #   survive fork (not exec), and its lines would fork the chain.
    # @yieldparam journal [Journal] closed when the block returns or raises
    # @return [Journal, Object] the Journal, or what the block answered
    # @raise [Locked] when a chained writer holds the file, or, chained, when any writer does
    def self.open(path = nil, clock: DEFAULT_CLOCK, fsync: false, paths: Paths.new, chain: false, root: nil)
      path ||= default_path(paths:, root:)
      FileUtils.mkdir_p(File.dirname(path))
      # File.new, not the block form: the Journal owns this handle for its whole
      # life. `path:` ONLY when this call created the file -- it is the sole
      # thing licensing #close to unlink, and a file that already existed is
      # somebody else's.
      created = create(path)
      io = created || File.new(path, "ab")
      journal = new(io:, clock:, owns_io: true, fsync:, path: created && path, chain: claimed(io, path, chain:))
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

    # Closes the fd on any refusal or raise: the caller never receives it to close.
    def self.claimed(io, path, chain:)
      claim(io, path, chain:)
      continued_tip(io, path) if chain
    rescue StandardError
      io.close
      raise
    end
    private_class_method :claimed

    def self.claim(io, path, chain:)
      return if io.flock((chain ? File::LOCK_EX : File::LOCK_SH) | File::LOCK_NB)

      raise Locked, "#{path} is held by #{chain ? "another writer" : "a chained writer"}"
    end
    private_class_method :claim

    # The torn line is sealed rather than skipped, so the next link covers every byte on disk.
    def self.continued_tip(io, path)
      tip = Line.tip(path)
      io.write("\n") if Line.torn?(path)
      tip
    end
    private_class_method :continued_tip

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
    # @param root [String, nil] the project root to file under; the working directory when nil
    # @return [String] a timestamped path under the root's sessions directory
    def self.default_path(paths: Paths.new, root: nil)
      File.join(root ? paths.filing_dir(root:) : paths.sessions_dir, stem)
    end

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
    LINK = "prev"
    ENTRY_LINK = "entry_prev"

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

    # @param entry [Hash, #to_journal] a record as written
    # @return [Hash] the entry's journal hash, keys as given
    # @raise [TypeError] when the entry is neither, because a stray value must fail loudly
    def self.hash_of(entry)
      hash = entry.respond_to?(:to_journal) ? entry.to_journal : entry
      return hash if hash.is_a?(Hash)

      raise TypeError, "journal entry must be a Hash or respond to #to_journal, got #{hash.class}"
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
    # @param typed [Boolean] answer each record as {Telemetry.read} rebuilds it, leniently. Lenient
    #   reading cannot raise on a JSON line; an entry given as a Hash must hold only JSON values,
    #   or carrying it whole raises {Declarative::UnsettleableAttribute}.
    # @return [Enumerator::Lazy<Hash{String=>Object}, Telemetry::Journalable, Telemetry::Untyped>]
    def self.records(entries, type: nil, typed: false)
      records = entries.lazy.filter_map { |entry| parse(entry) }
      records = records.select { |record| record["type"].to_s == type.to_s } unless type.nil?
      typed ? records.map { |record| Telemetry.read(record, strict: false) } : records
    end

    # The inverse of the envelope {#record} adds: the stamp and the chain's own link go, and an
    # entry's own link, renamed on the way in to make room, comes back under its name.
    #
    # @param hash [Hash{String=>Object}] one parsed line
    # @return [Hash{String=>Object}]
    def self.payload_of(hash)
      payload = hash.except("ts", LINK)
      payload.key?(ENTRY_LINK) ? payload.transform_keys(ENTRY_LINK => LINK) : payload
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
    # @param chain [String, nil] the tip to continue the chain from
    #   ({Line::ORIGIN} for a new file); nil writes no links
    # @raise [ArgumentError] when the tip is neither the origin nor a link
    def initialize(io:, clock: DEFAULT_CLOCK, owns_io: false, fsync: false, path: nil, chain: nil)
      raise ArgumentError, "chain tip must be #{Line::ORIGIN} or a link, got #{chain.inspect}" \
        unless chain.nil? || Line.tip?(chain)

      @io = io
      @clock = clock
      @owns_io = owns_io
      @fsync = fsync
      @tip = chain
      @chained = !chain.nil?
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
      write_whole([encode(entry)], [entry])
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
      write_whole(entries.map { |entry| encode(entry) }, entries)
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

    def write_whole(lines, entries)
      lines.each { |line| line << "\n" } unless @chained
      @monitor.synchronize do
        raise Closed, "journal is closed" if @closed

        tip = @chained ? linked!(lines) : @tip
        @io.write(whole(lines))
        @tip = tip
        @io.fsync if @fsync && @io.respond_to?(:fsync)
        entries.each { |entry| notify(entry) }
      end
      self
    end

    # A lone line goes as it is: joining it would copy a megabyte line once more.
    def whole(lines) = lines.one? ? lines.first : lines.join

    # Splices each line in place and answers the tip after them, which becomes the
    # Journal's only once the bytes have landed.
    def linked!(lines)
      lines.inject(@tip) do |prev, line|
        tip = Line.link(Line.splice!(line, prev))
        line << "\n"
        tip
      end
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
      hash = { "ts" => timestamp }.merge(string_keyed(self.class.hash_of(entry)))
      @chained && hash.key?(LINK) ? unforged(hash) : hash
    end

    def string_keyed(hash)
      hash.each_key { |key| return hash.transform_keys(&:to_s) unless key.is_a?(String) }
      hash
    end

    # Renamed so no entry can supply its own link, and refused when the new name is taken too.
    def unforged(hash)
      raise ArgumentError, "an entry carrying both #{LINK} and #{ENTRY_LINK} cannot be chained" if hash.key?(ENTRY_LINK)

      hash.transform_keys(LINK => ENTRY_LINK)
    end

    def timestamp
      @clock.call
    end
  end
end
