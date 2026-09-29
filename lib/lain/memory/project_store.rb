# frozen_string_literal: true

require "fileutils"
require "json"

module Lain
  module Memory
    # The project's durable memory: every item any chat or `lain consolidate`
    # ever wrote, append-only, at
    # `$XDG_STATE_HOME/lain/memory/<project hash>/store.ndjson`.
    #
    # ONE STORE FOR ALL MEMORY, and it is not a compaction artifact. Project
    # memory is durable fact written on purpose and shared across chats;
    # compaction is a derived, rebuildable view of one chat's own history.
    # Nothing under `lib/lain/compaction/` reads or writes this class, and a
    # handoff's state document is never an item here.
    #
    # == It is a LOG, folded last-write-wins
    #
    # The file is an ordered log, never a set, and {Loaded.of} is the ONE fold
    # that resolves it -- used by the reader and by the writer's own dedup, so
    # they cannot hold two models of the same bytes. What that buys is the
    # ordinary correction: a model that writes `x = "one"`, then `x = "two"`,
    # then `x = "one"` again has changed the head twice and both changes are
    # recorded, where a set would have swallowed the third as a duplicate of the
    # first and left every future chat rendering `"two"`.
    #
    # == The store and the view
    #
    # This object is the STORE. A session's VIEW of it is a {Recorder}: the
    # items this store resolved when the session loaded, plus the writes on that
    # session's own chain. A view is a snapshot by construction, so another
    # chat's write lands here without changing what this session renders or
    # what its `memory_root` records verify against.
    #
    # {#view} opens a fresh chat's view on the head; {#resumed} re-opens a
    # resumed chat's recorded one. Both go through {Loaded#index}, so a live
    # view and the replay of its session file start from the same root -- which
    # is the whole reason a session file can be self-contained about memory.
    class ProjectStore
      # The segment under `$XDG_STATE_HOME/lain`, {ProjectDir::STATE_KIND}'s
      # sibling.
      KIND = "memory"

      FILE = "store.ndjson"
      LOCK = "store.lock"

      # Seconds between tries for the cross-process lock, and seconds of waiting
      # before the waiter is told who holds it; {Isolation::ParentLock}'s.
      INTERVAL = 0.05
      PATIENCE = 5

      # A line whose content no longer addresses the digest it was written
      # under. A line that is not an item at all is skipped, never raised on --
      # see {#item_from} for why the two are different claims.
      class Corrupt < Error; end

      # An append the filesystem took only part of. Loud, and before the view
      # advances: a session rendering an item nothing durable holds is exactly
      # what {Recorder#write}'s store-first ordering exists to prevent.
      class Unwritten < Error; end

      # A wait nobody is told about, {Isolation::ParentLock::Silent}'s answer.
      module Silent
        def self.call(_text) = nil
      end

      # What one read of the store resolves to: the version read, and the item
      # each id currently holds.
      #
      # The version is DERIVED from those items rather than stamped, so a reader
      # holding a recorded load can re-address it and find out whether the
      # bodies still match the version they were recorded under.
      Loaded = Data.define(:version, :items) do
        # Last write wins per id, then id order. THE fold: the store's reader,
        # its writer's dedup, the live view and the replay's seed all resolve
        # the log through this one method, and id order is what keeps two walks
        # over the same content from addressing two versions.
        #
        # @param items [Enumerable<Item>] a log, oldest first
        def self.of(items)
          held = items.to_a.reverse.uniq(&:id).sort_by(&:id).freeze
          new(version: Canonical.digest(held.map(&:digest)), items: held)
        end

        def initialize(version:, items:) = super(version: -version.to_s, items: items.freeze)

        # The Index this load renders as: the items folded in id order.
        #
        # ID ORDER, NOT WRITE ORDER, and that is the whole point: a view's root
        # becomes a content address of the items it currently resolves, so two
        # readers that arrived at the same view by different routes -- a live
        # session appending, a replay folding a recorded chain, a rewind
        # retreating -- address it identically. A root that depended on the
        # order writes happened in could not be reproduced by anything except
        # the run that made it.
        #
        # The store is threaded so a caller folding a SEQUENCE of views keeps
        # every root it passed through resolvable: `Index#checkout` of an
        # earlier root is what {Tools::MemoryWrite} promises and what
        # {Bench::Session::RecordedMemory#at} reads a per-turn snapshot back
        # through.
        #
        # @param store [Lain::Store] where the folded nodes land
        def index(store: Store.new)
          items.inject(Index.empty(store:)) { |folded, item| folded.write(item) }
        end

        # id => the digest this load resolves it to. What an append is judged
        # against, and what tells a recorded view apart from a newer store.
        def heads = items.to_h { |item| [item.id, item.digest] }
      end

      # The identity of a store nothing was ever loaded from. A method rather
      # than a constant because a caller holding one is holding a VIEW, and two
      # callers must not share one; the compiled extension `Loaded.of` reaches
      # is already required by the time any class body here runs, so nothing
      # about load order forces it.
      def self.empty = Loaded.of([])

      # No durable store behind the view: a bench run taking the default, a
      # child's fresh recorder, a spec's bare {Recorder}. `#append` keeps
      # nothing, so no caller asks whether it has a project to write to.
      module Null
        def self.path = nil
        def self.load = ProjectStore.empty
        def self.view = Recorder.new
        def self.append(_item) = ProjectStore.empty
        def self.newer_than(_loaded) = 0
      end

      # @param project_dir [ProjectDir] whose {ProjectDir#container} keys this
      #   store to the project, the one recipe every durable per-project
      #   artifact is composed by
      # @param sleeper [#call] waits between tries while another process holds
      #   the lock
      # @param interval [Numeric] seconds between tries
      # @param patience [Numeric] seconds of waiting before the waiter is told
      #   who it is waiting on
      # @param notice [#call] told once, in words, who holds the lock when a
      #   wait outlasts the patience; never the process's own streams
      def initialize(project_dir: ProjectDir.new, sleeper: ->(seconds) { sleep(seconds) },
                     interval: INTERVAL, patience: PATIENCE, notice: Silent)
        @dir = project_dir.container(KIND)
        @sleeper = sleeper
        @interval = interval
        @told_after = [(patience / interval.to_f).ceil, 1].max
        @notice = notice
      end

      # @return [String] the append-only file, whether or not it exists yet
      def path = File.join(@dir, FILE)

      # The store as it currently resolves. SHARED-LOCKED: an unlocked read that
      # landed mid-append saw a partial line, and on this path that is a chat
      # refusing to start in a project another chat is writing a memory in.
      #
      # A store no chat has written to yet is answered without touching the
      # filesystem at all, so starting a chat in a project with no memory
      # creates nothing.
      #
      # @return [Loaded]
      def load
        return self.class.empty unless File.exist?(path)

        locked(File::LOCK_SH) { Loaded.of(held) }
      end

      # A fresh chat's view: the store head, and every later write on this
      # session's chain.
      #
      # @return [Recorder]
      def view = rebound(load)

      # A resumed chat's view. The recorded items are re-addressed rather than
      # re-read, which is what keeps a resume from picking up what other chats
      # wrote since -- and what makes the new session file's own `memory_loaded`
      # reproduce the roots that file records.
      #
      # @param recorder [Recorder] the replayed view
      # @return [Recorder]
      def resumed(recorder) = rebound(Loaded.of(recorder.index.to_a))

      # Append one item unless this id's CURRENT head already holds exactly this
      # content. Judged against the fold rather than against the whole file, for
      # the reason the class docstring gives: over a log, a digest seen anywhere
      # is not the same question as the digest an id resolves to now.
      #
      # @param item [Item]
      # @return [Loaded] the store as this write left it
      # @raise [Ownership::Refused] when the head is the chat's and the writer is not
      def append(item)
        locked(File::LOCK_EX) do
          log = held
          current = Loaded.of(log)
          Ownership.permit!(item, current.items.find { |held| held.id == item.id })
          current.heads[item.id] == item.digest ? current : Loaded.of(written(log, item))
        end
      end

      # How many ids the store resolves to a body a recorded view has not seen
      # -- what a resumed chat is told, since it deliberately keeps its own
      # view. Counted against the FOLD on both sides: a superseded body is not
      # news, and counting raw lines told every chat that had ever updated an
      # item that something newer was waiting.
      #
      # @param loaded [Loaded]
      # @return [Integer]
      def newer_than(loaded)
        seen = loaded.heads
        load.items.count { |item| seen[item.id] != item.digest }
      end

      private

      def rebound(loaded) = Recorder.new(index: loaded.index, store: self, loaded:)

      def held
        return [] unless File.exist?(path)

        File.readlines(path, chomp: true).filter_map { |line| item_from(line) }
      end

      # TWO DIFFERENT CLAIMS, and only one of them is damage worth refusing
      # over.
      #
      # A line that does not parse as an item is SKIPPED -- the Journal's reader
      # contract, for the Journal's reason applied to a file every chat in the
      # project appends to. A crash between the write and its newline, a short
      # write, or a reader that got in ahead of the lock leaves bytes that are
      # not a record, and a project whose only copy of its memory is unreadable
      # forever is a far worse answer than one entry lost. There is no
      # quarantine and none is needed: the next append lands after it and the
      # store reads clean again.
      #
      # A line that IS an item but no longer addresses the digest it was written
      # under still REFUSES: those bytes make a false claim about their own
      # content, which is editing rather than damage, and a manifest would
      # otherwise render it as fact.
      def item_from(line)
        record = JSON.parse(line)
        item = Item.new(id: record.fetch("id"), description: record.fetch("description"),
                        body: record.fetch("body"), author: Author.from(record["author"]))
        return item if item.digest == record.fetch("digest")

        raise Corrupt, "#{path} holds an entry recorded as #{record.fetch("digest")} whose content " \
                       "addresses #{item.digest}; the project's memory has been edited under its own digest"
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError
        nil
      end

      # O_APPEND, {Improvement::Sink}'s idiom, and fsynced like {Journal}: the
      # kernel positions each write at the end, so a sibling process appending
      # under its own fd cannot land inside this line, and the item is on disk
      # before the caller is told it was written.
      #
      # THE TERMINATOR A CRASH OWED IS PAID FIRST, in the same write. A torn
      # append leaves a fragment with no trailing newline -- that byte is the
      # one the writer never reached -- and appending straight after it would
      # merge the fragment and this record into one physical line that neither
      # reads back, losing both. So the whole byte string goes out in one
      # `write`, and a short one RAISES: a caller told its item was stored, over
      # bytes that are not a record, is the one failure this ordering exists to
      # prevent.
      def written(items, item)
        bytes = "#{terminator}#{JSON.generate(row_for(item))}\n"
        File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o644) do |file|
          stored!(file.write(bytes), bytes.bytesize, item)
          file.fsync
        end
        items + [item]
      end

      def row_for(item) = item.payload.merge("author" => item.author.to_h, "digest" => item.digest)

      def stored!(landed, owed, item)
        return if landed == owed

        raise Unwritten, "#{path} took #{landed} of #{owed} bytes for memory item #{item.id.inspect}; " \
                         "the entry is not stored"
      end

      def terminator = unterminated? ? "\n" : ""

      def unterminated?
        return false unless File.exist?(path) && File.size(path).positive?

        File.open(path, "rb") do |file|
          file.seek(-1, IO::SEEK_END)
          file.read(1) != "\n"
        end
      end

      # POLLED, NOT BLOCKED, for {Isolation::ParentLock}'s reason: a blocking
      # flock stalls the whole thread, reactor and all, for as long as another
      # chat in the same project holds it, where a non-blocking try with a sleep
      # between tries yields to the scheduler instead. A waiter that outlasts
      # its patience is told who it is waiting on, once -- a holder that hangs
      # rather than exits must not wedge another chat in silence.
      def locked(mode, &block)
        FileUtils.mkdir_p(@dir)
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |file|
          waited(file, mode)
          claimed(file, mode, &block)
        end
      end

      def lock_path = File.join(@dir, LOCK)

      def waited(file, mode)
        tries = 0
        until file.flock(mode | File::LOCK_NB)
          @notice.call(waiting_on) if (tries += 1) == @told_after
          @sleeper.call(@interval)
        end
      end

      # Only a WRITER names itself: a shared reader excludes nobody it would
      # have to explain itself to, and truncating here would erase the name a
      # writer left.
      def claimed(file, mode, &block)
        mode == File::LOCK_EX ? named(file, &block) : yield
      end

      def named(file)
        file.truncate(0)
        file.write("pid=#{Process.pid} command=#{[$PROGRAM_NAME, *ARGV].join(" ")}\n")
        file.flush
        yield
      ensure
        file.truncate(0)
      end

      def waiting_on
        holder = File.read(lock_path).strip
        "waiting on #{holder.empty? ? "a holder that has not named itself yet" : holder} for this project's " \
          "memory store (#{path})"
      end
    end
  end
end
