# frozen_string_literal: true

require "tempfile"
require "tmpdir"

module Lain
  class Sensitivity
    # The project files a run that could read the secrets left holding one, gated for the rest of the
    # process: a read asks a human, no judge may approve it, and a later sandbox masks it. "Per process"
    # because in-process children share the policy holding it, while a fork or pane chat builds its own.
    #
    # A file is in scope when its ctime is at or after the run's start {.mark}. mtime is not used, since
    # `cp -p`, a hard link, `tar x` and `touch -d` all keep an old one. The names are git's listing as
    # {Confine::MaskList} reads it, and each tree that listing prunes or a nested repo hides is walked
    # beside it; where git does not answer, the whole project is walked. Git's own objects are read too:
    # what the run staged, and what every ref it made or moved reaches.
    #
    # A path lain cannot reach holds its nearest reachable ancestor whole, when the run changed it. A
    # changed file's bytes, a changed symlink's target and a changed path's name each count.
    #
    # Only a known value byte for byte counts, so a value the run reshaped (base64, reversed) or split
    # across path levels or files is missed.
    # Nothing under a `.git` directory is read as a file, a user xattr is not read, and a write below a
    # directory that was already closed before the mark is not seen.
    class Taint
      LIMIT = 8 * 1024 * 1024
      # A file written up to this long before the mark still counts, so a clock that stamps a write a
      # little early cannot hide it.
      EARLY = 2
      REASON = :tainted
      GIT_DIR = ".git"

      Scan = Data.define(:gated, :unscanned, :unopened, :commits, :unscanned_commits)
      NOTHING = Scan.new(gated: [], unscanned: [], unopened: [], commits: [], unscanned_commits: []).freeze

      # A start mark on the project's own filesystem, whose clock stamps the run's writes.
      #
      # @param root [String] the project
      # @return [Time] the ctime of a file made in its git dir, or in the project itself, less {EARLY}
      def self.mark(root)
        dir = [File.join(root, GIT_DIR), root].find { File.directory?(_1) && File.writable?(_1) } || Dir.tmpdir
        Tempfile.create(".lain-taint-mark", dir) { File.lstat(_1.path).ctime } - EARLY
      end

      # @param root [String]
      # @return [Hash{String => String}] each ref and HEAD with the object it names; empty outside a repository
      def self.refs(root) = Git.refs(Isolation::Checkout.of(root))

      # @return [String, nil] git's stdout as binary; nil when it failed
      def self.git(checkout, *, input: nil) = Confine::DecoyGuard.git(checkout, *, input:)

      def initialize
        @cell = Bounds::Cell.new([].freeze)
      end

      # @return [Array<String>] absolute paths, frozen; a directory lain could not open stands for everything
      #   below it
      def paths = @cell.current

      # @return [Boolean]
      def empty? = paths.empty?

      # By bytes, since a held name need not be valid UTF-8, and comparing it as text would raise.
      #
      # @param path [String] absolute
      # @return [Boolean] whether it is held, or lies under a directory held whole
      def include?(path)
        asked = path.b
        paths.any? { |held| asked == held.b || Landing.under?(asked, held.b) }
      end

      # @param root [String] absolute; the project the run wrote
      # @param since [Time] see {.mark}
      # @param refs [Hash{String => String}] see {.refs}, taken before the run
      # @param secrets [#for_reads] the known values, as a file read masks them
      # @return [Scan] gated paths, paths too large to read and directories lain could not open, absolute, and each
      #   `[object, path]` holding a known value or too large to read; the path is nil for an object no new
      #   commit names
      # @raise [FrozenError] on {NONE}
      # @raise [SystemCallError] when the root itself is gone
      def scan(root:, since:, refs:, secrets:)
        raise FrozenError.new("the empty taint takes no scan", receiver: self) if frozen?

        union = TextMask::Union.new(secrets.for_reads(nil))
        real = File.realpath(root)
        found(Files.new(real, since, union), Git.new(real, refs, union)).tap { hold(_1) }
      end

      # Held whole when the scan could not finish, so a defect in it gates what the run wrote.
      #
      # @param path [String] absolute
      # @return [void]
      # @raise [FrozenError] on {NONE}
      def hold_whole(path)
        raise FrozenError.new("the empty taint holds nothing", receiver: self) if frozen?

        @cell.swap { |held| (held | [path]).freeze }
      end

      NONE = new.freeze

      private

      def hold(scan) = @cell.swap { |held| (held | scan.gated | scan.unscanned | scan.unopened).freeze }

      def found(files, git)
        Scan.new(gated: (files.gated + git.gated).uniq, unscanned: (files.unscanned + git.unscanned).uniq,
                 unopened: files.unopened, commits: git.commits, unscanned_commits: git.unscanned_commits)
      end

      # The project's files that changed since the mark, each read for a known value unless it is too large.
      class Files
        # Each in bytes, as git lists a name.
        SEPARATOR = File::SEPARATOR.b
        PRUNE_SPECS = [*Confine::MaskList::PRUNES,
                       *Confine::MaskList::PRUNED_WHOLE.flat_map { [":(glob)**/#{_1}/**", ":(glob)**/#{_1}"] }].freeze
        # A path that is no longer there hides nothing.
        GONE = [Errno::ENOENT, Errno::ENOTDIR].freeze

        def initialize(root, since, union)
          @root = root
          @since = since
          @union = union
          @unopened = []
          @named = []
          small, large = changed.partition { |_, size| size <= LIMIT }.map { |part| part.map(&:first) }
          @gated = (small.select { holds?(_1) }.filter_map { real(_1) } + @named).uniq
          @unscanned = large.filter_map { real(_1) }
        end

        # @return [Array<String>]
        attr_reader :gated, :unscanned

        # @return [Array<String>] each directory changed since the mark that holds a path lain could not reach
        def unopened = @unopened.uniq

        private

        # The scan reads no git prose: any warning from the listing, or a prune listing that failed, sends it
        # to a walk of the whole project.
        def changed
          shell = Confine::MaskList::Listing.listed(@root, Shell::Out.method(:new))
          listed = Confine::MaskList::Listing.names(shell)
          trees = listed && shell.stderr.to_s.empty? ? pruned : nil
          return walked(@root) unless trees

          from_listing(listed.map { joined(_1) }, trees)
        end

        def from_listing(paths, trees)
          dirs, entries = paths.filter_map { stated(_1) }.partition { |_, stat| stat.directory? }
          [*entries.filter_map { listed_entry(*_1) }, *(dirs.map(&:first) + trees).uniq.flat_map { walked(_1) }]
        end

        # git lists a nested repo, or a submodule, as 1 directory name.
        def stated(path)
          [path, File.lstat(path)]
        rescue SystemCallError => e
          hold_reachable_ancestor(path, e)
          nil
        end

        def joined(name) = File.join(@root.b, name.b.chomp(SEPARATOR)).force_encoding(::Lain::FILESYSTEM)

        # The trees the listing leaves out, each at the directory a prune starts from.
        # Through the listing's own git, since the guard's pins pathspecs literal and these are globs.
        #
        # @return [Array<String>, nil] nil when git did not answer
        def pruned
          shell = Confine::MaskList::Listing.git(@root, Shell::Out.method(:new), "ls-files", "-z", "-co", "--directory",
                                                 "--", *PRUNE_SPECS)
          return nil unless Shell::Out.ok?(shell)

          shell.stdout.b.split("\0").filter_map { pruned_root(_1) }.uniq.map { joined(_1) }
        rescue Shell::Out::Timeout, SystemCallError
          nil
        end

        def pruned_root(name)
          segments = name.chomp(SEPARATOR).split(SEPARATOR)
          whole = segments.index { Confine::MaskList::PRUNED_WHOLE.include?(_1) }
          below = segments[0...-1].index { Confine::MaskList::PRUNED.include?(_1) }
          last = [whole, below&.succ].compact.min
          segments[0..last].join(SEPARATOR) if last
        end

        # No cap on size or depth: a deep copy is as readable as a shallow one.
        def walked(top)
          found = []
          pending = [top]
          pending.concat(visited(pending.pop, found)) until pending.empty?
          found.compact
        end

        # @return [Array<String>] the entries below a directory, to walk next
        def visited(path, found)
          stat = File.lstat(path)
          return [] if stat.directory? && File.basename(path) == GIT_DIR

          found << entry(path, stat)
          stat.directory? ? children(path, stat) : []
        rescue SystemCallError => e
          hold_reachable_ancestor(path, e)
          []
        end

        def children(path, stat)
          Dir.children(path).sort.reverse.map { File.join(path, _1) }
        rescue SystemCallError
          open_if_changed(path, stat)
          []
        end

        # A changed path whose name or link target holds a known value is gated without a read.
        def entry(path, stat)
          return unless stat.ctime >= @since

          @named << path if named?(path, stat)
          [path, stat.size] if stat.file?
        end

        # A listed file under an older name may sit in a directory the run renamed to a known value.
        def listed_entry(path, stat)
          shallowest_named(path)&.then { @named << _1 }
          entry(path, stat)
        end

        def shallowest_named(path)
          relative = path.b.delete_prefix(@root.b)
          return unless known?(relative)

          parts = relative.split(SEPARATOR).reject(&:empty?)
          depth = parts.index { known?(_1) }
          depth && changed_at(joined(parts[0..depth].join(SEPARATOR)))
        end

        def changed_at(path)
          File.lstat(path).ctime >= @since ? path : nil
        rescue SystemCallError
          path
        end

        def named?(path, stat)
          known?(path.b.delete_prefix(@root.b)) || (stat.symlink? && known?(File.readlink(path)))
        rescue SystemCallError
          false
        end

        def known?(text) = @union.in(text.b).any?

        # A path lain cannot lstat or open, for any reason but being gone, holds its nearest ancestor that
        # lstat answers whole, when the run changed that ancestor. Below the root only: a path the root
        # itself answers for is held by its own name.
        def hold_reachable_ancestor(path, error)
          return if GONE.any? { error.is_a?(_1) }

          ancestor = ancestors(path).lazy.filter_map { stat_of(_1) }.first
          ancestor ? open_if_changed(*ancestor) : @unopened << path
        end

        # By the filesystem's bytes in their own encoding, which a name that is not valid UTF-8 keeps.
        def ancestors(path)
          Enumerator.produce(File.dirname(path)) { File.dirname(_1) }.take_while { _1.bytesize > @root.bytesize }
        end

        def stat_of(dir)
          [dir, File.lstat(dir)]
        rescue SystemCallError
          nil
        end

        def open_if_changed(path, stat)
          @unopened << path if stat.ctime >= @since
        end

        # A file lain cannot read back is gated rather than waved through.
        def holds?(path)
          @union.in(File.binread(path)).any?
        rescue SystemCallError
          true
        end

        # A file the run removed again holds nothing to gate.
        def real(path)
          File.realpath(path).force_encoding(::Lain::FILESYSTEM)
        rescue SystemCallError
          nil
        end
      end
      private_constant :Files

      # What the run staged, and what each ref it made or moved reaches.
      class Git
        # A stash is never pushed, and a stashed file was in the worktree, where the file scan reads it.
        STASH = "refs/stash"
        RAW = /:\S+ \S+ \h+ (\h+) \S+\0([^\0]*)\0/n

        # @param checkout [Isolation::Checkout]
        # @return [Hash{String => String}] frozen
        def self.refs(checkout)
          listed = Taint.git(checkout, "show-ref", "--head").to_s.lines.map(&:split)
          listed.to_h { |object, name| [name, object] }.except(STASH).freeze
        end

        def initialize(root, refs, union)
          @checkout = Isolation::Checkout.of(root)
          @top = Taint.git(@checkout, "rev-parse", "--show-toplevel")&.chomp&.force_encoding(::Lain::FILESYSTEM)
          @refs = refs
          @union = union
        end

        # @return [Array<String>] each index path whose staged blob holds a known value, absolute
        def gated = staged.select { holds?(_1.first) }.map { at(_1.last) }.uniq

        # @return [Array<String>] each index path whose staged blob is too large to read, absolute
        def unscanned = staged.select { large?(_1.first) }.map { at(_1.last) }.uniq

        # @return [Array<Array(String, String)>] each new commit and path, or object and nil, holding a known value
        def commits = named(added.select { holds?(_1) })

        # @return [Array<Array(String, String)>] as {#commits}, for each blob too large to read
        def unscanned_commits = named(added.select { large?(_1) })

        private

        def at(path) = File.join(@top, path)

        def staged
          @staged ||= if !@top then []
                      elsif (head = @refs["HEAD"])
                        raw(git("diff-index", "--cached", "-z", "--raw", "--no-renames", "--no-abbrev", head))
                      else
                        listed_blobs
                      end
        end

        def listed_blobs
          git("ls-files", "-s", "-z").to_s.split("\0").map do |line|
            _mode, blob, _stage, path = line.split(/[ \t]/, 4)
            [blob, shown(path)]
          end
        end

        def raw(out) = out.to_s.scan(RAW).map { |blob, path| [blob, shown(path)] }

        # Every blob a ref reaches that none reached before the run, a tagged one included.
        def added
          @added ||= @top ? objects.keys.select { kinds.dig(_1, 0) == "blob" } : []
        end

        def objects
          @objects ||= git("rev-list", "--objects", "--exclude=#{STASH}", "--all", "--stdin", input: excluded)
                       .to_s.lines.to_h { |line| line.chomp.split(" ", 2).then { |object, path| [object, path] } }
        end

        def excluded = @refs.values.uniq.map { "^#{_1}\n" }.join

        def named(blobs)
          blobs.flat_map { |blob| logged.fetch(blob) { [[blob, nil]] } }
        end

        def logged
          @logged ||= git("log", "-z", "--format=%H", "--raw", "--no-renames", "--no-abbrev", "--exclude=#{STASH}",
                          "--all", "--stdin", input: excluded).to_s
                      .scan(/(\h{40,64})\0\n?((?::[^\0]*\0[^\0]*\0)*)/n)
                      .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(commit, raw), by_blob|
                        raw(raw).each { |blob, path| by_blob[blob] << [commit, path] }
                      end
        end

        def kinds
          @kinds ||= begin
            wanted = [*staged.map(&:first), *objects.keys].uniq
            batch("--batch-check", wanted).lines.map(&:split).to_h { |object, type, size| [object, [type, size.to_i]] }
          end
        end

        def large?(blob) = kinds.dig(blob, 0) == "blob" && kinds.dig(blob, 1) > LIMIT

        def holds?(blob) = bytes.key?(blob) && @union.in(bytes[blob]).any?

        def bytes
          @bytes ||= begin
            small = kinds.select { |_, (type, size)| type == "blob" && size <= LIMIT }.keys
            read(batch("--batch", small))
          end
        end

        # git waits on stdin for a batch, so an empty one is never started.
        def batch(mode, objects)
          objects.empty? ? "" : git("cat-file", mode, input: objects.map { "#{_1}\n" }.join).to_s
        end

        def read(out)
          blobs = {}
          offset = 0
          while (header_end = out.index("\n", offset))
            blob, _type, size = out.byteslice(offset, header_end - offset).split
            blobs[blob] = out.byteslice(header_end + 1, size.to_i)
            offset = header_end + 1 + size.to_i + 1
          end
          blobs
        end

        def git(*, input: nil) = Taint.git(@checkout, *, input:)

        def shown(path) = path.dup.force_encoding(Encoding::UTF_8)
      end
      private_constant :Git
    end
  end
end
