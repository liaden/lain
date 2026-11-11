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
      # every program for one opaque command.
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

        # Both the lineage and a live record name a path this way, so a record
        # that names none degrades the same wherever it is read.
        PATH_OF = lambda do |record|
          path = record.fetch("path")
          path.is_a?(String) ? path : raise(TypeError, "#{WRITTEN} names no path: #{path.inspect}")
        end
        private_constant :PATH_OF

        # Relative to the root: what a build writes, left out of the ctime check only.
        UNWATCHED = %w[target .git/objects].freeze
        # Where a cargo workspace keeps its members, each watched by its own ctime.
        MEMBERS = "crates"

        # @param paths [Array<String>] the lineage's session files, oldest first
        # @param stat [Stat] the filesystem port
        # @param clock [#call] the lineage's start when it has no file yet
        # @param faults [#<<] where the reason lands when the lineage cannot be read
        # @return [Fresh]
        def self.for_lineage(paths, stat: Stat.new, clock: -> { Time.now }, faults: Channel::Null.instance)
          written, unread = folded(paths)
          new(start: paths.empty? ? clock.call : first_ts(paths.first), written:, unread:, stat:)
        rescue StandardError => e
          unknown(e, faults:, stat:)
        end

        # What a lineage that cannot be read answers: every path fresh, with
        # the reason recorded, so a run that lost the rule says so.
        #
        # @param error [StandardError] why the lineage could not be read
        # @param faults [#<<] where the reason lands
        # @param stat [Stat]
        # @return [Fresh]
        def self.unknown(error, faults:, stat: Stat.new)
          faults << { "type" => "journal_error", "observer" => name, "error" => "#{error.class}: #{error.message}" }
          new(start: Time.at(0), written: [], stat:, degraded: true)
        end

        # Session files are UTF-8 whatever the locale says.
        def self.first_ts(path)
          Time.iso8601(File.open(path, "r:UTF-8") { |file| JSON.parse(file.gets).fetch("ts") })
        end

        # A marked line that does not parse is a torn record, and so a fault
        # rather than a line to skip.
        #
        # @return [Array(Array<String>, Boolean)] the written paths, and whether any write went unread
        def self.folded(paths)
          paths.lazy.flat_map { |path| File.foreach(path, encoding: Encoding::UTF_8).lazy }
               .select { |line| line.include?(WRITTEN_MARK) || line.include?(UNREAD_MARK) }
               .map { |line| JSON.parse(line) }
               .inject([[], false]) { |(written, unread), record| fold(record, written, unread) }
        end

        def self.fold(record, written, unread)
          case record["type"]
          when WRITTEN then [written << PATH_OF.call(record), unread]
          when UNREAD then [written, true]
          else [written, unread]
          end
        end

        private_class_method :first_ts, :folded, :fold

        # @param start [Time] the lineage's first record
        # @param written [Array<String>] the paths the lineage's write records name
        # @param stat [Stat]
        # @param degraded [Boolean] whether to answer every path fresh
        # @param unread [Boolean] whether the lineage ran a command whose writes no record names
        def initialize(start:, written:, stat:, degraded: false, unread: false)
          @start = nanoseconds(start)
          @written = Set.new(written)
          @stat = stat
          @degraded = degraded
          @unread = unread
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
          @unread = true if marks_unread?(event)
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
        #   lain could not read, or when the root cannot be read
        def any_under?(root)
          return true if @degraded || @unread

          real = @stat.real(root)
          roots = [root, real].uniq
          @lock.synchronize { @written.any? { |path| roots.any? { Landing.under?(path, _1) } } } ||
            watched_entries(real).any? { changed?(_1) }
        rescue StandardError
          true
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

        def marks_unread?(event) = event.is_a?(Telemetry::WritesUnread) || journal_type(event) == UNREAD

        def journal_type(event) = event.is_a?(Hash) ? (event["type"] || event[:type]).to_s : nil

        def written?(path) = @lock.synchronize { @written.include?(path) }

        def changed?(path)
          nanoseconds(@stat.lstat(path).ctime) > @start
        rescue Errno::ENOENT, Errno::ENOTDIR
          false
        end

        # Integer nanoseconds, since a ctime in nanoseconds exceeds what a Float holds exactly.
        def nanoseconds(time) = (time.to_i * 1_000_000_000) + time.nsec
      end
    end
  end
end
