# frozen_string_literal: true

require "json"
require "time"

module Lain
  module Shell
    class Executable
      # Answers whether a file changed during this lineage, by either of 2
      # rules: a write record names it, or its ctime is after the lineage's
      # first record. ctime, because `touch -d` sets mtime back and no
      # unprivileged process can set ctime.
      #
      # A write record names the resolved file, so a path is matched as given
      # and as its realpath. The match is by path, not by inode: a hard link to
      # a written file is fresh only by its ctime.
      #
      # The write-record rule reads only the current lineage: the files a
      # resume chains to and this session's own journal. Another session in
      # the same project that this one did not resume is not searched.
      #
      # A {Telemetry::WritesUnread} record stands for writes no record names,
      # so once the lineage holds one every root has changed beneath it, while
      # each path keeps its own rule: answering those fresh too would refuse
      # every program for one opaque command. A human who approves a build
      # under a root vouches for it ({#vouch!}), which lifts only that mark,
      # only there, until the next such command runs.
      #
      # It fails closed. A record it cannot fold, or a lineage it cannot read,
      # leaves it answering every path fresh, since the journal reports an
      # observer's fault and carries on.
      class Fresh
        WRITTEN = "file_written"
        # Most lines of a session file are not write records; a substring test
        # skips them without parsing.
        WRITTEN_MARK = %("type":"#{WRITTEN}").freeze
        UNREAD = "writes_unread"
        UNREAD_MARK = %("type":"#{UNREAD}").freeze
        MADE = "entry_made"
        MADE_MARK = %("type":"#{MADE}").freeze
        MARKS = [WRITTEN_MARK, UNREAD_MARK, MADE_MARK].freeze
        # A record from before the command was kept names none, and a bar still has to say what it waits on.
        UNNAMED = "a command an older lain did not name"
        # Far above any kernel tick, so it only bounds a clock that stopped.
        TICK_BOUND = 0.05

        # The lineage of a stack that reads none, which no command has marked unread.
        module Unmarked
          # @param _root [String]
          # @return [nil]
          def self.unread_command(_root) = nil

          # @param _root [String]
          # @return [Unmarked]
          def self.vouch!(_root, **) = self
        end

        # Both the lineage and a live record name a path this way, so a record
        # that names none degrades the same wherever it is read.
        PATH_OF = lambda do |record|
          path = record.fetch("path")
          path.is_a?(String) ? path : raise(TypeError, "#{WRITTEN} names no path: #{path.inspect}")
        end
        private_constant :PATH_OF

        # A torn record degrades the lineage rather than settle a directory on a guess.
        MADE_OF = lambda do |record|
          directory = record.fetch("directory")
          ctime = record.fetch("ctime")
          raise TypeError, "#{MADE} is torn: #{record.inspect}" unless directory.is_a?(String) && ctime.is_a?(Integer)

          [directory, ctime]
        end
        private_constant :MADE_OF

        # Relative to the root: what a build writes, left out of the ctime check only.
        UNWATCHED = %w[target .git/objects].freeze
        # Where a cargo workspace keeps its members, each watched by its own ctime.
        MEMBERS = "crates"

        # @param paths [Array<String>] the lineage's session files, oldest first
        # @param stat [Stat] the filesystem port
        # @param clock [#call] the lineage's start when it has no file yet
        # @param journal [#<<] the session's durable journal: where the reason lands when the lineage cannot be
        #   read, and where an entry the sandbox makes is recorded, for a resume to fold
        # @return [Fresh]
        def self.for_lineage(paths, stat: Stat.new, clock: -> { Time.now }, journal: Channel::Null.instance)
          written, unread, made = folded(paths)
          new(start: paths.empty? ? clock.call : first_ts(paths.first), written:, unread:, made:, stat:, journal:)
        rescue StandardError => e
          unknown(e, journal:, stat:)
        end

        # What a lineage that cannot be read answers: every path fresh, with
        # the reason recorded, so a run that lost the rule says so.
        #
        # @param error [StandardError] why the lineage could not be read
        # @param journal [#<<] where the reason lands
        # @param stat [Stat]
        # @return [Fresh]
        def self.unknown(error, journal:, stat: Stat.new)
          journal << { "type" => "journal_error", "observer" => name, "error" => "#{error.class}: #{error.message}" }
          new(start: Time.at(0), written: [], stat:, degraded: true)
        end

        # Session files are UTF-8 whatever the locale says.
        def self.first_ts(path)
          Time.iso8601(File.open(path, "r:UTF-8") { |file| JSON.parse(file.gets).fetch("ts") })
        end

        # A marked line that does not parse is a torn record, and so a fault
        # rather than a line to skip.
        #
        # @return [Array(Array<String>, String, nil, Hash{String=>Integer})] the written paths, the last command
        #   whose writes went unread, and each directory's ctime once the sandbox made an entry there
        def self.folded(paths)
          paths.lazy.flat_map { |path| File.foreach(path, encoding: Encoding::UTF_8).lazy }
               .select { |line| MARKS.any? { line.include?(_1) } }
               .map { |line| JSON.parse(line) }
               .inject([[], nil, {}]) { |(written, unread, made), record| fold(record, written, unread, made) }
        end

        def self.fold(record, written, unread, made)
          case record["type"]
          when WRITTEN then [written << PATH_OF.call(record), unread, made]
          when UNREAD then [written, named(record["command"]), made]
          when MADE then [written, unread, made.merge([MADE_OF.call(record)].to_h)]
          else [written, unread, made]
          end
        end

        # @param command [Object] what a record names
        # @return [String]
        def self.named(command) = command.is_a?(String) ? command : UNNAMED

        private_class_method :first_ts, :folded, :fold

        # @param start [Time] the lineage's first record
        # @param written [Array<String>] the paths the lineage's write records name
        # @param stat [Stat]
        # @param degraded [Boolean] whether to answer every path fresh
        # @param unread [String, nil] the last command the lineage ran whose writes no record names
        # @param made [Hash{String=>Integer}] each directory's ctime, in nanoseconds, once the sandbox made an entry
        #   there
        # @param journal [#<<] where an entry the sandbox makes is recorded
        def initialize(start:, written:, stat:, degraded: false, unread: nil, made: {}, journal: Channel::Null.instance)
          @start = nanoseconds(start)
          @written = Set.new(written)
          @stat = stat
          @degraded = degraded
          @unread = unread&.dup&.freeze
          @made = made.transform_values { at_or_after_start(_1) }
          @journal = journal
          @vouched = Set.new
          @lock = Mutex.new
        end

        # A {Journal} observer. Called under the journal's monitor, so it only
        # folds; the lock it takes is never held around a journal write. A
        # fault degrades it and is raised on, for the journal to record.
        #
        # @param event [Telemetry::FileWritten, Telemetry::WritesUnread, Hash, Object] any journal entry
        # @return [self]
        def <<(event)
          path = written_path(event)
          @lock.synchronize { @written << path } if path
          command = unread_command_of(event)
          @lock.synchronize { marked(command) } if command
          self
        rescue StandardError
          @degraded = true
          raise
        end

        # A degrade partway through a session is not announced again; the journal's own error record has it.
        #
        # @return [Boolean] whether it lost the write-record rule and answers every path fresh
        def degraded? = @degraded

        # @param path [String] absolute
        # @return [Boolean]
        def fresh?(path)
          return true if @degraded

          [path, @stat.real(path)].uniq.any? { |candidate| written?(candidate) || changed?(candidate) }
        rescue StandardError
          true
        end

        # Whether anything a build could load changed under `root`, each
        # workspace member included: a write record anywhere beneath it, or a
        # ctime after the lineage began on the root, an entry at its top, or a
        # member under `crates/`. A full walk cost 98 ms on lain's own checkout,
        # so a change no record names shows only where it adds, removes or
        # renames an entry at those levels, or rewrites one of them in place: an
        # in-place edit deeper down, by a command whose write was not recorded,
        # is missed. The ctime check leaves out `target/` and `.git/objects`; a
        # write into `target/` that the journal cannot see, from the string arm
        # or a script, stays a residual that the exec rule for build output there can run.
        #
        # It fails closed on what a granted call leaves: in a main checkout a
        # fetch writes `.git`, a first cargo build makes `target/` and a git add
        # rewrites the index, each withdrawing the next grant, so a lineage gets
        # about 1 grant.
        #
        # @param root [String] absolute; the checkout
        # @return [Boolean] true when degraded, when the lineage ran a command
        #   lain could not read that no human vouched for here, or when the root cannot be read
        def any_under?(root) = !unread_command(root).nil? || changed_under?(root)

        # {#any_under?} by every rule but the unread mark, which is what a human's vouch leaves standing.
        #
        # @param root [String] absolute; the checkout
        # @return [Boolean]
        def changed_under?(root)
          return true if @degraded

          real = @stat.real(root)
          roots = [root, real].uniq
          @lock.synchronize { @written.any? { |path| roots.any? { Landing.under?(path, _1) } } } ||
            watched_entries(real).any? { changed?(_1) }
        rescue StandardError
          true
        end

        # @param root [String] absolute; the checkout
        # @return [String, nil] the last command whose writes went unread, unless a human vouched for `root` since
        def unread_command(root)
          command = @unread
          command unless command.nil? || vouched?(root)
        end

        # A human approved a call under `root` knowing the lineage's unread command, so its mark no longer
        # withholds a grant there. Every other rule stands. The mark is matched by identity, under the lock: a
        # command that ran while the human was asked, the same words again included, is one they never saw.
        #
        # @param root [String] absolute; the checkout
        # @param command [String] the command the human was shown, as {#unread_command} answered it
        # @return [self]
        def vouch!(root, command:)
          real = @stat.real(root)
          @lock.synchronize { @vouched << real if @unread.equal?(command) }
          self
        end

        # Makes an entry the sandbox itself needs, such as a crate's first `target/`, so that making it is no
        # change a human must vouch for: the parent's ctime it leaves becomes that dir's start, unless the
        # parent had changed already. That start is journaled, so a resume folds it too. The coarse clock is
        # waited past it, so an entry made later still counts.
        #
        # @param path [String] absolute; the entry to make
        # @yieldparam path [String]
        # @return [Object] the block's value
        def making(path)
          parent = @stat.real(File.dirname(path))
          quiet = !changed?(parent)
          yield(path).tap { made(parent, File.basename(path)) if quiet }
        end

        private

        def watched?(path, root)
          return false unless Landing.under?(path, root)

          relative = path.delete_prefix(root).delete_prefix(File::SEPARATOR)
          UNWATCHED.none? { relative == _1 || relative.start_with?("#{_1}#{File::SEPARATOR}") }
        end

        def watched_entries(root)
          [root, *entries(root).select { watched?(_1, root) }, *members(File.join(root, MEMBERS))]
        end

        def members(directory)
          @stat.lstat(directory).directory? ? entries(directory) : []
        rescue Errno::ENOENT
          []
        end

        def entries(directory) = @stat.children(directory).map { File.join(directory, _1) }

        def written_path(event)
          return event.path if event.is_a?(Telemetry::FileWritten)
          return unless journal_type(event) == WRITTEN

          PATH_OF.call(Journal.parse(event))
        end

        def unread_command_of(event)
          return self.class.named(event.command) if event.is_a?(Telemetry::WritesUnread)

          self.class.named(Journal.parse(event)["command"]) if journal_type(event) == UNREAD
        end

        # A new unread command may have written under a root vouched for already, so every vouch lapses.
        def marked(command)
          @unread = command.dup.freeze
          @vouched = Set.new
        end

        # Settled here, not by folding the record back: the live session holds the value already, and only a
        # resume needs the record.
        def made(directory, entry)
          ctime = nanoseconds(@stat.lstat(directory).ctime)
          @lock.synchronize { @made[directory] = at_or_after_start(ctime) }
          record(Telemetry::EntryMade.new(directory:, entry:, ctime:))
          past_coarse_clock(ctime)
        end

        # The coarse clock can stamp a ctime before the lineage's start, and a settlement must never read a
        # change from before the lineage began as one inside it.
        def at_or_after_start(ctime) = [ctime, @start].max

        # A record that cannot land costs only a resume's settlement, which then fails closed: the root reads
        # changed, as it did before the entry was made.
        def record(entry)
          @journal << entry
        rescue StandardError
          nil
        end

        def past_coarse_clock(floor)
          deadline = RunClock::MONOTONIC.call + TICK_BOUND
          sleep(0.0005) until coarse_now > floor || RunClock::MONOTONIC.call > deadline
        end

        def coarse_now = Process.clock_gettime(Process::CLOCK_REALTIME_COARSE, :nanosecond)

        def vouched?(root)
          real = @stat.real(root)
          @lock.synchronize { @vouched.include?(real) }
        rescue StandardError
          false
        end

        def journal_type(event) = event.is_a?(Hash) ? (event["type"] || event[:type]).to_s : nil

        def written?(path) = @lock.synchronize { @written.include?(path) }

        def changed?(path)
          nanoseconds(@stat.lstat(path).ctime) > @lock.synchronize { @made.fetch(path, @start) }
        rescue Errno::ENOENT, Errno::ENOTDIR
          false
        end

        # Integer nanoseconds, since a ctime in nanoseconds exceeds what a Float holds exactly.
        def nanoseconds(time) = (time.to_i * 1_000_000_000) + time.nsec
      end
    end
  end
end
