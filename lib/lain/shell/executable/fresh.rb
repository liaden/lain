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
      # It fails closed. A record it cannot fold, or a lineage it cannot read,
      # leaves it answering every path fresh, since the journal reports an
      # observer's fault and carries on.
      class Fresh
        WRITTEN = "file_written"
        # Most lines of a session file are not write records; a substring test
        # skips them without parsing.
        WRITTEN_MARK = %("type":"#{WRITTEN}").freeze

        # Both the lineage and a live record name a path this way, so a record
        # that names none degrades the same wherever it is read.
        PATH_OF = lambda do |record|
          path = record.fetch("path")
          path.is_a?(String) ? path : raise(TypeError, "#{WRITTEN} names no path: #{path.inspect}")
        end
        private_constant :PATH_OF

        # @param paths [Array<String>] the lineage's session files, oldest first
        # @param stat [Stat] the filesystem port
        # @param clock [#call] the lineage's start when it has no file yet
        # @param faults [#<<] where the reason lands when the lineage cannot be read
        # @return [Fresh]
        def self.for_lineage(paths, stat: Stat.new, clock: -> { Time.now }, faults: Channel::Null.instance)
          new(start: paths.empty? ? clock.call : first_ts(paths.first), written: written_in(paths), stat:)
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

        # A marked line that does not parse is a torn write record, and so a
        # fault rather than a line to skip.
        def self.written_in(paths)
          paths.lazy.flat_map { |path| File.foreach(path, encoding: Encoding::UTF_8).lazy }
               .select { |line| line.include?(WRITTEN_MARK) }
               .map { |line| JSON.parse(line) }.select { |record| record["type"] == WRITTEN }
               .map { |record| PATH_OF.call(record) }.to_a
        end

        private_class_method :first_ts, :written_in

        # @param start [Time] the lineage's first record
        # @param written [Array<String>] the paths the lineage's write records name
        # @param stat [Stat]
        # @param degraded [Boolean] whether to answer every path fresh
        def initialize(start:, written:, stat:, degraded: false)
          @start = nanoseconds(start)
          @written = Set.new(written)
          @stat = stat
          @degraded = degraded
          @lock = Mutex.new
        end

        # A {Journal} observer. Called under the journal's monitor, so it only
        # folds; the lock it takes is never held around a journal write. A
        # fault degrades it and is raised on, for the journal to record.
        #
        # @param event [Telemetry::FileWritten, Hash, Object] any journal entry
        # @return [self]
        def <<(event)
          path = written_path(event)
          @lock.synchronize { @written << path } if path
          self
        rescue StandardError
          @degraded = true
          raise
        end

        # @param path [String] absolute
        # @return [Boolean]
        def fresh?(path)
          return true if @degraded

          [path, @stat.real(path)].uniq.any? { |candidate| written?(candidate) || changed?(candidate) }
        rescue StandardError
          true
        end

        private

        def written_path(event)
          return event.path if event.is_a?(Telemetry::FileWritten)
          return unless event.is_a?(Hash) && (event["type"] || event[:type]).to_s == WRITTEN

          PATH_OF.call(Journal.parse(event))
        end

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
