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
      ASSIGNED = /^[ \t]*(?:export[ \t]+)?["']?[\w.-]+["']?[ \t]*[=:][ \t]*(.*?)[ \t]*,?[ \t\r]*$/
      QUOTED = /\A(["'])(.*)\1\z/m
      # The patterns arrive on stdin, so no value is written to disk. `-w`
      # frees a value only where it stands whole, never inside a longer token.
      # `-I` skips binary files and `:/` searches the whole tree from any root.
      PUBLIC = %w[grep -F -w -I -z -o --full-name -f -].freeze

      # The history of a run with no project behind it.
      module Null
        # @return [self]
        def self.prime = self

        # @return [Array<String>] none
        def self.to_a = [].freeze
      end

      # @param root [String] the project root
      # @param policy [Sensitivity::Policy] what decides a path is sensitive
      # @param shell [#call] `(*argv, **opts) -> Shell::Out`
      # @param clock [#call] the monotonic source each git child's timeout reads
      def initialize(root:, policy:, shell: Shell::Out.public_method(:new), clock: RunClock::MONOTONIC)
        # Bytes, as git lists a name, so a name and the root always join.
        @root = root.b
        @policy = policy
        @git = Isolation::Checkout.new(root, shell_out_factory: ->(*argv, **opts) { shell.call(*argv, clock:, **opts) })
        @lock = Mutex.new
        @fingerprint = nil
        @sensitive = {}
        @blobs = {}
        @start = UNREAD
        @state = State.new(history: [].freeze, on_disk: [].freeze, public: Set[].freeze)
        @priming = nil
      end

      # Starts the first enumeration off the caller's thread; {#to_a} joins it.
      #
      # @return [self]
      def prime
        @priming ||= Thread.new { @lock.synchronize { refresh } }.tap { _1.report_on_exception = false }
        self
      end

      # @return [Array<String>] frozen, each at least {Literals::FLOOR} bytes
      def to_a
        join_priming
        state = @lock.synchronize { refresh }
        (state.history + Values.in_files(state.on_disk)).uniq.reject { state.public.include?(_1) }.freeze
      end

      private

      State = Data.define(:history, :on_disk, :public)
      private_constant :State

      UNREAD = Object.new.freeze
      private_constant :UNREAD

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
        fingerprint = repository.fingerprint
        return @state if fingerprint == @fingerprint

        held = history(repository) || @state.history
        disk = on_disk || @state.on_disk
        public = tracked_publicly(repository, held + Values.in_files(disk), start)
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

      # `--reflog`, so a commit amended away still answers for what it held.
      def history(repository)
        objects = run("rev-list", "--objects", "--all", "--reflog")
        objects && values_of(repository, objects).freeze
      end

      def on_disk
        listed = run("ls-files", "-z", "-co", "--", ".", *Confine::MaskList::EXCLUDES)
        listed && listed.split("\0").map { File.join(@root, _1) }.select { sensitive?(_1) }.uniq.freeze
      end

      def values_of(repository, objects)
        shas = objects.each_line.filter_map do |line|
          sha, path = line.chomp.split(" ", 2)
          sha if path && sensitive?(File.join(repository.top, path))
        end
        read(shas.uniq.reject { @blobs.key?(_1) })
        shas.flat_map { @blobs.fetch(_1, []) }.uniq
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
        # @return [Array<String>]
        def in_files(paths) = paths.flat_map { of(contents(_1)) }

        # Each assignment's value, or a file's lone line when it assigns
        # nothing, and every region the detector finds.
        #
        # @param bytes [String]
        # @return [Array<String>] binary, each at least {Literals::FLOOR} bytes
        def of(bytes)
          bytes = bytes.b
          found = assigned(bytes).then { _1.empty? ? lone(bytes) : _1 } + Regions.detect(bytes).map(&:bytes)
          found.select { _1.bytesize >= Literals::FLOOR }.uniq
        end

        def lone(bytes) = bytes.lines.map(&:strip).reject(&:empty?).then { _1.one? ? _1 : [] }

        def assigned(bytes) = bytes.scan(ASSIGNED).map { |(value)| value.sub(QUOTED, '\2') }

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

        # @return [String]
        def fingerprint
          files = @heads + Dir.glob("**/*", base: @refs).sort.map { File.join(@refs, _1) }
          files.each_with_object(Digest::SHA256.new) { |path, digest| digest << path << "\0" << contents(path) }
               .hexdigest
        end

        private

        def contents(path)
          File.file?(path) ? File.binread(path) : ""
        rescue SystemCallError
          ""
        end

        # No repository: one fingerprint forever, which matches the one a
        # fresh reader starts from, so nothing is ever enumerated.
        module Nowhere
          def self.fingerprint = nil
        end
      end
      private_constant :Repository
    end
  end
end
