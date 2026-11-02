# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Lain
  class Tool
    # Keeps a result too large to hand back whole in a file under the project's
    # answers dir, so the model is handed a pointer beside a head that says it
    # is a head, rather than a clipped head that reads complete or nothing at all.
    #
    # A file is named by the time and a random suffix, never by lease or
    # worker id, and opened exclusively: two results kept in the same second
    # must not meet, and a spill never writes over another.
    class Spill
      # The answers dir could not be made or written.
      class Unwritable < Error; end

      # What a keep can come to, one callback each: `kept` takes the paths
      # written, `unwritable` why they could not be, and `unkept` nothing,
      # for a spill that keeps nothing. A value rather than loose keywords,
      # so a misspelled callback raises where the outcomes are built.
      Outcomes = Data.define(:kept, :unwritable, :unkept)

      # How long a kept file outlives the session that wrote it.
      AGE = 7 * 24 * 60 * 60
      # The most of one stream a spill keeps, web_fetch's own stream cap.
      STREAM_CAP = 5 * 1024 * 1024
      PENDING = ".pending"
      KEPT = ".txt"

      # A tool with no answers dir: it keeps nothing, so an oversized result
      # is refused as it was before spills existed.
      module Null
        # @param _answer [String] unused: nothing is kept
        # @param _summary [String, nil] unused
        # @param outcomes [Outcomes]
        # @return [Object] what `unkept` answers
        def self.keep(_answer, _summary, outcomes) = outcomes.unkept.call

        # @param threshold [Integer] unused: nothing is kept
        # @return [Pending::None]
        def self.pending(threshold:) = Pending::None.new(threshold:)

        # @return [Array<String>] nothing, since nothing was kept
        def self.sweep(**) = []
      end

      # @param paths [Paths]
      # @param root [String] the project root
      # @return [String] where the project's spills are kept, keyed by project
      #   so a confined reader of one project's never reaches another's
      def self.home(paths, root) = paths.container("answers", key: paths.project_hash(root))

      # Dashed, because the compact `20261102T084512-9f3ac1e7` joined to a
      # state path reads as a high-entropy token to the secret detector, which
      # would mask the very path a result hands back.
      #
      # @return [String] a file name without its extension, unique per call
      def self.stem = "#{Time.now.utc.strftime("%Y-%m-%d-%H%M%S")}-#{SecureRandom.hex(4)}"

      # @param dir [String] the answers dir, created at the first spill
      def initialize(dir:)
        @dir = -dir.to_s
        freeze
      end

      # A summary that cannot be written still leaves the answer kept, since
      # the answer is the half the parent spawned the child for.
      #
      # @param answer [String] the whole text to keep
      # @param summary [String, nil] a summary of it, when there is a whole one
      # @return [Array<String>] the paths written, full answer first
      # @raise [Unwritable] when the answer itself could not be written
      def call(answer:, summary: nil)
        FileUtils.mkdir_p(@dir, mode: 0o700)
        stem = File.join(@dir, self.class.stem)
        [written("#{stem}.md", answer), *summarized("#{stem}.summary.md", summary)]
      rescue SystemCallError, IOError => e
        raise Unwritable, e.message
      end

      # @param answer [String] the whole text to keep
      # @param summary [String, nil] a summary of it, when there is a whole one
      # @param outcomes [Outcomes]
      # @return [Object] what `kept` or `unwritable` answers
      def keep(answer, summary, outcomes)
        outcomes.kept.call(call(answer:, summary:))
      rescue Unwritable => e
        outcomes.unwritable.call(e.message)
      end

      # @param threshold [Integer] bytes held in memory before a file is opened
      # @param cap [Integer] the most the file keeps
      # @return [Pending] a stream that opens its file only once it passes the threshold
      def pending(threshold:, cap: STREAM_CAP) = Pending.new(dir: @dir, threshold:, cap:)

      # Run when a session starts. A pending file is a write that never
      # settled, unless its writer still holds the lock on it, which is how
      # a second session's live write survives the first one's start.
      #
      # @param now [Time]
      # @return [Array<String>] the paths removed
      def sweep(now: Time.now)
        return [] unless File.directory?(@dir)

        Dir.children(@dir).map { File.join(@dir, _1) }.select { |path| swept?(path, now) }
      end

      private

      def swept?(path, now)
        return unlocked_removed?(path) if path.end_with?(PENDING)

        File.file?(path) && File.mtime(path) < now - AGE && File.unlink(path).positive?
      rescue SystemCallError
        false
      end

      def unlocked_removed?(path)
        File.open(path, File::RDONLY) do |file|
          file.flock(File::LOCK_EX | File::LOCK_NB) && File.unlink(path).positive?
        end
      end

      def summarized(path, summary)
        summary ? [written(path, summary)] : []
      rescue SystemCallError, IOError
        FileUtils.rm_f(path)
        []
      end

      def written(path, text)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(text) }
        path
      end

      # A result being written while its tool runs. The first `threshold`
      # bytes are held in memory, so a result that fits never touches the
      # disk; past them the file is opened, holding an exclusive lock for as
      # long as it is open, and everything is written to it up to `cap`.
      #
      # It never raises while bytes arrive, since it sits in a command's pipe
      # drain: a file that cannot be written leaves it unspilled, and the tool
      # refuses as it would with no spill at all.
      #
      # Mutable, and locked, because a command's two streams may arrive on two
      # threads.
      class Pending
        # The stream of a tool that keeps nothing: it counts and holds the head,
        # and never spills.
        class None
          attr_reader :size, :head

          # @param threshold [Integer] how much of the head is held
          def initialize(threshold:)
            @threshold = threshold
            @size = 0
            @head = +"".b
          end

          # @param chunk [String]
          # @return [self]
          def <<(chunk)
            @size += chunk.bytesize
            @head << chunk.b.byteslice(0, [@threshold - @head.bytesize, 0].max)
            self
          end

          def keeps? = false
          def spilled? = false
          def kept = 0
          def path = nil
          def discard = nil

          # @param sinks [Hash{Symbol => #<<}]
          # @return [Hash{Symbol => #<<}] the same sinks: nothing is kept, so nothing is teed
          def tee(sinks) = sinks
        end

        # @return [Integer] every byte offered
        attr_reader :size
        # @return [Integer] the bytes the file holds
        attr_reader :kept
        # @return [String, nil] where the file is, once it was opened
        attr_reader :path

        # @param dir [String] where the file is opened
        # @param threshold [Integer] bytes held before the file is opened
        # @param cap [Integer] the most the file keeps
        def initialize(dir:, threshold:, cap:)
          @dir = dir
          @threshold = threshold
          @cap = cap
          @head = +"".b
          @size = 0
          @kept = 0
          @state = :held
          @lock = Mutex.new
        end

        # @param chunk [String] bytes as they arrived
        # @return [self]
        def <<(chunk)
          @lock.synchronize { take(chunk.b) }
          self
        end

        # @param sinks [Hash{Symbol => #<<}] a command's live sinks
        # @return [Hash{Symbol => Exec::Capture::Tee}] each also writing here
        def tee(sinks) = sinks.transform_values { Exec::Capture::Tee.new(_1, self) }

        # @return [String] the first `threshold` bytes, as they arrived
        def head = @lock.synchronize { @head.dup }

        # @return [Boolean] whether what passes the threshold is kept in a file
        def keeps? = true

        # @return [Boolean] whether a file holds what passed the threshold
        def spilled? = @state == :writing

        # Read from the descriptor the bytes were written to, never by name:
        # the command that produced them can reach this dir, and delete or
        # swap the file under its name.
        #
        # @return [String] every byte the file holds
        # @raise [IOError] when no file is open
        def whole
          @lock.synchronize do
            raise IOError, "no spill file is open" unless @state == :writing

            @file.pread(@kept, 0)
          end
        end

        # Copies the descriptor's bytes to the kept name rather than renaming
        # the name, which the command may have swapped, and lets go of the
        # lock only once they are there. A detached writer still holding its
        # own descriptor can add bytes after the scan, the same adversarial
        # limit the withhold layer states, and read_file's masking still
        # applies when they are read back.
        #
        # @return [String] the kept path
        # @raise [Unwritable] when the copy failed; nothing is left then
        def commit
          @lock.synchronize do
            kept = @path.delete_suffix(PENDING) + KEPT
            copied(kept)
            close(:committed, kept)
            kept
          end
        rescue SystemCallError, IOError => e
          discard
          raise Unwritable, e.message
        end

        # Deletes the file, unless it was committed. Safe to call twice.
        #
        # @return [nil]
        def discard
          @lock.synchronize { close(:discarded, nil) unless @state == :committed }
          nil
        end

        private

        def take(bytes)
          @size += bytes.bytesize
          into_head = bytes.byteslice(0, [@threshold - @head.bytesize, 0].max)
          @head << into_head
          rest = bytes.byteslice(into_head.bytesize..)
          return if rest.empty?

          opened if @state == :held
          write(rest) if @state == :writing
        end

        def opened
          FileUtils.mkdir_p(@dir, mode: 0o700)
          path = File.join(@dir, "#{Spill.stem}#{PENDING}")
          @file = File.open(path, File::RDWR | File::CREAT | File::EXCL, 0o600)
          @path = path
          @file.flock(File::LOCK_EX)
          @file.sync = true
          @state = :writing
          write(@head)
        rescue SystemCallError, IOError
          failed
        end

        def write(bytes)
          piece = bytes.byteslice(0, [@cap - @kept, 0].max)
          @file.write(piece) unless piece.empty?
          @kept += piece.bytesize
        rescue SystemCallError, IOError
          failed
        end

        def failed = close(:failed, nil)

        def copied(kept)
          File.open(kept, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |out|
            IO.copy_stream(@file, out, @kept, 0)
          rescue SystemCallError, IOError
            File.unlink(kept)
            raise
          end
        end

        # Only the file this object opened is removed: a name it never
        # created, or one swapped in under it, is not its to delete.
        def close(state, path)
          unlinked if @file && own?
          @file&.close
          @file = nil
          @state = state
          @path = path
        end

        def unlinked
          File.unlink(@path)
        rescue SystemCallError
          nil
        end

        def own?
          named = File.lstat(@path)
          held = @file.stat
          named.ino == held.ino && named.dev == held.dev
        rescue SystemCallError
          false
        end
      end

      Held = Data.define(:pending, :render, :refusal) do
        # @return [Tool::Result] the result naming the pending file
        def provisional = render.call(pending.path)

        # @return [Tool::Result] the result naming the kept file, or the
        #   refusal when the file could not be kept
        def commit
          render.call(pending.commit)
        rescue Unwritable
          refusal.call
        end

        # @param env [Hash] a call's env, its result naming the pending file
        # @return [Hash] the env, its result naming the kept file
        def kept_in(env) = env.merge(result: commit)

        # @param _env [Hash] unused: the file holds more than the result
        # @return [String] every byte the file holds
        # @raise [IOError, SystemCallError] when it cannot be read back
        def whole(_env) = pending.whole

        # @return [nil]
        def discard = pending.discard
      end

      # A spilled result whose file is still pending, handed to whatever
      # decides whether it may be kept: {#commit} keeps it and answers the
      # result naming the kept file, {#discard} deletes it. Reopened so the
      # constant below lands here rather than on {Spill}.
      class Held
        # What a call that spilled nothing hands on: nothing to keep or delete.
        module None
          # @param env [Hash]
          # @return [Hash] the same env
          def self.kept_in(env) = env

          # @param env [Hash]
          # @return [String, Array] the result's own content
          def self.whole(env) = env.fetch(:result).content

          def self.discard = nil
        end
      end
    end
  end
end
