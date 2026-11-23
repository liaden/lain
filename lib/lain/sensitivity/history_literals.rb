# frozen_string_literal: true

require "digest"

module Lain
  class Sensitivity
    # The values a project's sensitive paths hold where no file read sees
    # them: in git history and in ignored files. A command can print either
    # (`git show HEAD~1:.env`), and a value no detector shapes would reach the
    # model whole. Held in memory only, because a value written down is the
    # leak this masks.
    #
    # Read once per ref set, fingerprinted off the disk so an unmoved one costs
    # no git child. A failed listing waits for the next ref move rather than
    # costing every read its timeout. Files on disk are listed with the
    # history, so one created after the last ref move is not seen until the
    # next; one already listed is re-read on every ask.
    class HistoryLiterals
      # Seconds each of ls-files, rev-list and the public search may take: the
      # same bound MaskList gives the same listing.
      TIMEOUT = 10
      # A sensitive directory can hold a dump; a credential file is small.
      LARGEST = 64 * 1024
      ASSIGNED = /^[ \t]*(?:export[ \t]+)?["']?([\w.-]+)["']?[ \t]*[=:][ \t]*(.*?)[ \t]*,?[ \t\r]*$/
      QUOTED = /\A(["'])(.*)\1\z/m
      # The patterns arrive on stdin, so no value is written to disk. `-w`
      # frees a value only where it stands whole, never inside a longer token.
      # `-I` skips binary files and `:/` searches the whole tree from any root.
      PUBLIC = %w[grep -F -w -I -z -o --full-name -f -].freeze

      # Both sets from one read, for a caller that needs the two together.
      #
      # @!attribute [r] known
      #   @return [Array<String>] as {HistoryLiterals#to_a}
      # @!attribute [r] refusable
      #   @return [Array<String>] as {HistoryLiterals#refusable}
      Split = Data.define(:known, :refusable) do
        def initialize(known:, refusable:)
          super(known: Ractor.make_shareable(known.map(&:-@)), refusable: Ractor.make_shareable(refusable.map(&:-@)))
        end
      end

      # The history of a run with no project behind it.
      module Null
        # @return [self]
        def self.prime = self

        # @return [Array<String>] none
        def self.to_a = [].freeze

        # @return [Array<String>] none
        def self.refusable = [].freeze

        # @return [Split] empty
        def self.split = Split.new(known: [], refusable: [])
      end

      # @param root [String] the project root
      # @param policy [Sensitivity::Policy] what decides a path is sensitive
      # @param shell [#call] `(*argv, **opts) -> Shell::Out`
      # @param clock [#call] the monotonic source each git child's timeout reads
      # @param wall [#call] the wall time a ref fingerprint is taken at, for its racy window
      # @param report [#call] receives why an encrypted credentials file added nothing
      def initialize(root:, policy:, shell: Shell::Out.public_method(:new), clock: RunClock::MONOTONIC,
                     wall: Time.method(:now), report: ->(_reason) {})
        # Bytes, as git lists a name, so a name and the root always join.
        @root = root.b
        @policy = policy
        @shell_out = ->(*argv, **opts) { shell.call(*argv, clock:, **opts) }
        @git = Isolation::Checkout.of(root, shell_out_factory: @shell_out)
        @lock = Mutex.new
        @wall = wall
        @fingerprint = Fingerprint::NONE
        @sensitive = {}
        @blobs = {}
        @start = UNREAD
        @state = State.new(history: {}.freeze, on_disk: [].freeze, public: Set[].freeze)
        @priming = nil
        @credentials = RailsCredentials.new(root:, report:)
      end

      # Starts the first enumeration off the caller's thread; {#to_a} joins it.
      #
      # @return [self]
      def prime
        @priming ||= Thread.new { @lock.synchronize { refresh } }.tap { _1.report_on_exception = false }
        self
      end

      # @return [Array<String>] frozen, each at least {Literals::FLOOR} bytes
      def to_a = split.known

      # The narrower set a value is refused from leaving the machine on: one
      # assigned to a secret-named key, or one the region detector or the
      # entropy test accepts. The rest is ordinary config as often as not.
      #
      # @return [Array<String>] frozen, a subset of {#to_a}
      def refusable = split.refusable

      # @return [Split] {#to_a} and {#refusable} from one read
      def split
        values = known
        Split.new(known: values.keys, refusable: values.select { |_, refusable| refusable }.keys)
      end

      private

      State = Data.define(:history, :on_disk, :public)
      private_constant :State

      UNREAD = Object.new.freeze
      private_constant :UNREAD

      def known
        join_priming
        state, decrypted = @lock.synchronize { [refresh, @credentials.leaves.to_h { [_1, true] }] }
        Values.merged(state.history, Values.in_files(state.on_disk), decrypted).except(*state.public)
      end

      def join_priming
        priming = @priming
        @priming = nil
        priming&.value
      end

      # The starting commit is read first, so a refresh that raises cannot
      # leave it to be read after a commit the session made.
      def refresh
        start = starting_commit
        repository = (@repository ||= Repository.at(@git, @root))
        fingerprint = repository.fingerprint(now: @wall.call)
        return @state if fingerprint.unchanged_since?(@fingerprint)

        held = history(repository) || @state.history
        disk = on_disk || @state.on_disk
        public = tracked_publicly(repository, held.keys + Values.in_files(disk).keys, start)
        @state = State.new(history: held, on_disk: disk, public:)
        # Last, so a read that raised is retried rather than answered from a stale state.
        @fingerprint = fingerprint
        @state
      end

      # A value a non-sensitive file tracked at the session's starting commit
      # also holds is public, and masking it hides nothing. Only that commit
      # counts, so a commit made in the session cannot launder a history
      # secret. A failed search leaves every value masked.
      def tracked_publicly(repository, values, start)
        return Set[].freeze if values.empty? || start.nil?

        shell = @git.run(*PUBLIC, start, "--", ":/", timeout: TIMEOUT, input: "#{values.uniq.join("\n")}\n")
        Shell::Out.ok?(shell) ? published(repository, shell.stdout.b, start) : Set[].freeze
      rescue Shell::Out::Timeout, SystemCallError
        Set[].freeze
      end

      # Read once, at the top of the first refresh, which {#prime} runs as the board is built.
      def starting_commit
        return @start unless @start.equal?(UNREAD)

        @start = run("rev-parse", "--verify", "--quiet", "HEAD^{commit}")&.strip&.then { _1.empty? ? nil : _1 }
      end

      def published(repository, matches, start)
        matches.split("\n").filter_map do |match|
          path, value = match.split("\0", 2)
          value unless sensitive?(File.join(repository.top, path.delete_prefix("#{start}:")))
        end.to_set.freeze
      end

      # `--reflog`, so a commit amended away still answers for what it held. A partial clone's unfetched
      # blob is skipped rather than failing the listing, since no git lain runs may fetch it.
      def history(repository)
        objects = run("rev-list", "--objects", "--all", "--reflog", "--missing=allow-any")
        objects && values_of(repository, objects).freeze
      end

      def on_disk
        listed = Confine::MaskList::Listing.of(@root, @shell_out)
        listed && listed.map { File.join(@root, _1) }.select { sensitive?(_1) }.uniq.freeze
      end

      def values_of(repository, objects)
        shas = objects.each_line.filter_map do |line|
          sha, path = line.chomp.split(" ", 2)
          sha if path && sensitive?(File.join(repository.top, path))
        end
        read(shas.uniq.reject { @blobs.key?(_1) })
        Values.merged(*shas.map { @blobs.fetch(_1, {}) })
      end

      def sensitive?(path)
        @sensitive.fetch(path) { @sensitive[path] = !@policy.classify(Policy.text_of(path)).ordinary? }
      end

      def read(shas)
        small = blobs_of(shas)
        return if small.empty?

        Batch.each(run("cat-file", "--batch", input: "#{small.join("\n")}\n").to_s) do |sha, bytes|
          @blobs[sha] = Values.of(bytes)
        end
      end

      def blobs_of(shas)
        return [] if shas.empty?

        checked = run("cat-file", "--batch-check", input: "#{shas.join("\n")}\n").to_s
        checked.each_line.filter_map do |line|
          sha, type, size = line.split
          sha if type == "blob" && size.to_i <= LARGEST
        end
      end

      def run(*, input: nil)
        shell = @git.run(*, timeout: TIMEOUT, input:)
        Shell::Out.ok?(shell) ? shell.stdout.b : nil
      rescue Shell::Out::Timeout, SystemCallError
        nil
      end

      # What one sensitive file's bytes yield to mask.
      module Values
        module_function

        # @param paths [Array<String>] absolute
        # @return [Hash{String=>Boolean}] as {.of}
        def in_files(paths) = merged(*paths.map { of(contents(_1)) })

        # Each assignment's value, or a file's lone line when it assigns
        # nothing, and every region the detector finds, each with whether it
        # is refusable (see {HistoryLiterals#refusable}).
        #
        # @param bytes [String]
        # @return [Hash{String=>Boolean}] binary keys, each at least {Literals::FLOOR} bytes
        def of(bytes)
          bytes = bytes.b
          pairs = assigned(bytes).then { _1.empty? ? lone(bytes).map { |line| [nil, line] } : _1 }
          found = pairs.map { |name, value| [value, refusable?(name, value)] }
          found += Regions.detect(bytes).map { [_1.bytes, true] }
          merged(*found.select { |value, _| value.bytesize >= Literals::FLOOR }.map { |value, flag| { value => flag } })
        end

        # A value seen twice is refusable if either sighting is.
        #
        # @param sets [Array<Hash{String=>Boolean}>]
        # @return [Hash{String=>Boolean}]
        def merged(*sets) = sets.each_with_object({}) { |set, all| all.merge!(set) { |_, was, now| was || now } }

        def refusable?(name, value)
          (!name.nil? && Regions::SECRET_NAMING.match?(name)) || Regions.detect(value).any? || Entropy.high?(value)
        end

        def lone(bytes) = bytes.lines.map(&:strip).reject(&:empty?).then { _1.one? ? _1 : [] }

        def assigned(bytes) = bytes.scan(ASSIGNED).map { |name, value| [name, value.sub(QUOTED, '\2')] }

        def contents(path)
          File.size(path) <= LARGEST ? File.binread(path) : ""
        rescue SystemCallError
          ""
        end
      end
      private_constant :Values

      # `git cat-file --batch` output: a `<sha> <type> <size>` header, then
      # exactly that many bytes, then a newline.
      module Batch
        # @param output [String] binary
        # @yieldparam sha [String]
        # @yieldparam bytes [String]
        def self.each(output)
          offset = 0
          while (header_end = output.index("\n", offset))
            sha, _type, size = output.byteslice(offset...header_end).split
            yield sha, output.byteslice(header_end + 1, size.to_i)
            offset = header_end + 1 + size.to_i + 1
          end
        end
      end
      private_constant :Batch

      # The stat stamps of a set of paths, taken without reading one. A ref
      # update is a rename over the old file, so its inode moves; an added or
      # removed ref moves its directory. A stamp within a tick of the take
      # cannot tell a change later in the same tick, the racy window of git's
      # index, so a take that close to a change vouches for nothing.
      class Fingerprint
        # A whole-second filesystem stamps no nanoseconds; a kernel without
        # fine-grained timestamps stamps by clock tick, at most 10 ms.
        COARSE_TICK = 2.0
        FINE_TICK = 0.01

        Stamp = Data.define(:mtime, :ctime, :ino, :size)

        # @param paths [Enumerable<String>] absolute, files or directories
        # @param now [Time] taken before any path is stamped
        # @return [Fingerprint]
        def self.take(paths, now: Time.now)
          new(now, paths.to_h { [_1, stamp(_1)] })
        end

        def self.stamp(path)
          found = File.stat(path)
          Stamp.new(found.mtime.dup.freeze, found.ctime.dup.freeze, found.ino, found.size)
        rescue SystemCallError
          nil
        end
        private_class_method :stamp

        # @param taken_at [Time] taken before any path is stamped
        # @param by_path [Hash{String => Stamp, nil}]
        def initialize(taken_at, by_path)
          @taken_at = taken_at.dup.freeze
          @by_path = by_path.freeze
          freeze
        end

        # Only the earlier take's racy window counts, so the argument order matters.
        #
        # @param earlier [Fingerprint, nil]
        # @return [Boolean] whether no path moved since the earlier take, and it could tell
        def unchanged_since?(earlier) = !earlier.nil? && earlier.vouches_for?(@by_path)

        # @param by_path [Hash{String => Stamp, nil}]
        # @return [Boolean]
        def vouches_for?(by_path) = @by_path == by_path && @by_path.each_value.none? { racy?(_1) }

        # The same value a reader that has taken nothing holds, so a directory
        # that is no repository is never enumerated.
        NONE = new(Time.at(0), {})

        private

        def racy?(stamp)
          return false if stamp.nil?

          changed_at = [stamp.mtime, stamp.ctime].max
          @taken_at - changed_at < (changed_at.nsec.zero? ? COARSE_TICK : FINE_TICK)
        end
      end

      # Where a repository keeps its refs, read off the disk so an unmoved ref
      # set costs no git child.
      class Repository
        # @return [Repository, Nowhere]
        def self.at(git, root)
          shell = git.run("rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir", timeout: TIMEOUT)
          top, git_dir, common = shell.stdout.lines(chomp: true)
          Shell::Out.ok?(shell) && common ? new(top, git_dir, File.expand_path(common, root)) : Nowhere
        rescue Shell::Out::Timeout, SystemCallError
          Nowhere
        end

        attr_reader :top

        def initialize(top, git_dir, common)
          @top = top
          @heads = [File.join(git_dir, "HEAD"), File.join(common, "packed-refs"),
                    File.join(common, "reftable", "tables.list")]
          @refs = File.join(common, "refs")
        end

        # logs/ is not stamped: a reflog grows only beside a ref that moved, and an expire moves
        # no ref but can only shrink what the enumeration reaches, so a stale set over-masks.
        #
        # @param now [Time]
        # @return [Fingerprint]
        def fingerprint(now: Time.now)
          Fingerprint.take(@heads + [@refs] + Dir.glob("**/*", base: @refs).sort.map { File.join(@refs, _1) }, now:)
        end

        # No repository: one fingerprint forever, which matches the one a
        # fresh reader starts from, so nothing is ever enumerated.
        module Nowhere
          def self.fingerprint(**) = Fingerprint::NONE
        end
      end
      private_constant :Repository
    end
  end
end
