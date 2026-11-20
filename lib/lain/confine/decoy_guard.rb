# frozen_string_literal: true

require "digest"
require "pathname"
require "shellwords"

module Lain
  module Confine
    # Keeps a masked file's stand-in out of the repo. Inside a sandbox a mask
    # reads as an empty file or a {Decoys} decoy, and `git commit -a` or
    # `git add -f` would stage those bytes, where an unreadable mask once
    # failed the command. Two layers: the run's git gets a clean filter that
    # maps each tracked mask back to the blob it held, and after the run an
    # index entry holding a stand-in is put back or taken out, and a new
    # commit holding one is named. A `.gitattributes` the run writes can turn
    # the filter off, which is why the check after it exists. A stand-in holds
    # no secret, so this guards the repo's integrity, not a secret.
    #
    # Git names a path in bytes, so every path here is compared as binary.
    class DecoyGuard
      ATTRIBUTES = "/tmp/.lain-decoy-attributes"
      FILTER = "laindecoy"
      TIMEOUT = 10
      KEPT = 64
      # An attributes line splits on whitespace and reads glob characters, so only a plain path gets one.
      PLAIN = %r{\A[\w./@+-]+\z}n
      # The masks' own paths, never a glob that could reach further.
      LITERAL = { "GIT_LITERAL_PATHSPECS" => "1" }.freeze
      # The bytes an ANSI-C quoted word holds as themselves; every other is written `\xNN`.
      ANSI_C_PLAIN = ((32..126).to_a - ["'", "\\"].map(&:ord)).freeze
      # What moves when the index or HEAD does: git writes each by rename, so a new inode marks every write.
      STAMPED = %w[index HEAD logs/HEAD packed-refs].freeze
      ASKED = ["--show-toplevel", "--git-common-dir", "--show-object-format",
               *STAMPED.flat_map { ["--git-path", _1] }].freeze

      Settled = Data.define(:restored, :unstaged, :failed, :commits) do
        def initialize(restored: [], unstaged: [], failed: [], commits: []) = super
      end
      Entry = Data.define(:path, :mode, :blob, :bytes) do
        # @return [Boolean] whether git tracked the path before the run
        def tracked? = !blob.nil?
      end

      # What git says of a repository once: where its top is, which files move with its index and HEAD,
      # how it names an object, and the user's own attributes, which the run's attributes file replaces.
      Repo = Data.define(:top, :stamped, :common, :format, :attributes) do
        # @return [Array] a stamp per file that moves with the index or HEAD, the branch HEAD names included
        def stamps = [*stamped, branch].map { DecoyGuard.stamp(_1) }

        # @param bytes [String]
        # @return [String] the id git gives a blob of these bytes
        def blob_id(bytes)
          digest = format == "sha256" ? Digest::SHA256 : Digest::SHA1
          digest.hexdigest("blob #{bytes.bytesize}\0".b + bytes.b)
        end

        private

        def branch
          head = stamped.fetch(STAMPED.index("HEAD"))
          ref = (File.binread(head) if File.file?(head)).to_s[/\Aref: (\S+)/, 1]
          File.join(common, ref) if ref
        end
      end

      # A lookup kept while a stamp holds: a repo's facts by root, and a listing by its index's stamps.
      class Memo
        def initialize
          @kept = {}
          @lock = Mutex.new
        end

        # @param key [Object]
        # @param stamp [Object] what must still hold for a kept value to answer
        # @yieldreturn [Object, nil] the value, kept unless nil
        # @return [Object, nil]
        def kept(key, stamp)
          held = @lock.synchronize { @kept[key] }
          return held.last if held&.first == stamp

          yield.tap { |value| store(key, stamp, value) unless value.nil? }
        end

        private

        def store(key, stamp, value)
          @lock.synchronize do
            @kept.clear if @kept.size >= KEPT
            @kept[key] = [stamp, value]
          end
        end
      end

      NO_REPO = :no_repo
      REPOS = Memo.new
      LISTINGS = Memo.new
      private_constant :NO_REPO, :REPOS, :LISTINGS

      # @param root [String, nil] the project the call runs in
      # @param masks [Hash{String => String}] each masked path and the bytes the call reads there
      # @return [DecoyGuard] holding HEAD, the index blobs of the masks git tracks, and the rest by path
      def self.before(root:, masks:)
        under = inside(root, masks)
        return NONE if under.empty?

        gits = dot_gits(root.b)
        repo = REPOS.kept(root.b, gits) { located(Isolation::Checkout.of(root)) || (NO_REPO if gits.none?) }
        return NONE if repo.nil? || repo == NO_REPO

        stamps = repo.stamps
        entries, head = LISTINGS.kept([repo.top, under], stamps) { listed(repo, under) }
        entries ? new(repo, entries, head:, stamps:) : NONE
      end

      # A root with no `.git` at it or above it stays no repository until one appears. A failure while one
      # stands is never kept, since it would leave the root unguarded for the life of the process.
      def self.dot_gits(root) = Pathname(root).ascend.map { DecoyGuard.stamp(File.join(_1, ".git"))&.first }

      # A file's identity and times, nil when it is not there.
      #
      # @param path [String, nil]
      # @return [Array, nil]
      def self.stamp(path)
        stat = File.stat(path) if path
        stat && [stat.ino, stat.size, stat.mtime.to_r, stat.ctime.to_r]
      rescue SystemCallError
        nil
      end

      # One git command over a checkout. The run may have written the repository's config, so no fsmonitor
      # it names runs. The positional arguments after the checkout are the subcommand and its own.
      #
      # @param checkout [Isolation::Checkout]
      # @param input [String, nil] stdin
      # @return [String, nil] stdout as binary, nil when git failed
      def self.git(checkout, *, input: nil)
        shell = checkout.run(*, env: LITERAL, timeout: TIMEOUT, input:, pins: Isolation::Checkout::FSMONITOR_OFF)
        shell.stdout.b if Shell::Out.ok?(shell)
      rescue Shell::Out::Timeout, SystemCallError
        nil
      end

      def self.inside(root, masks)
        return {} unless root

        masks.to_h { |path, bytes| [path.b, bytes] }.select { |path, _| path != root.b && Landing.under?(path, root.b) }
      end

      def self.located(checkout)
        lines = git(checkout, "rev-parse", *ASKED)&.split("\n") or return
        top, common, format, *stamped = lines
        expand = ->(path) { File.expand_path(path, checkout.dir.b) }
        Repo.new(top: expand.call(top), common: expand.call(common), format:, stamped: stamped.map(&expand),
                 attributes: user_attributes(checkout))
      end

      def self.user_attributes(checkout)
        named = git(checkout, "config", "--path", "--get", "core.attributesFile").to_s.chomp
        path = named.empty? ? xdg_attributes : named
        File.file?(path) ? File.binread(path) : ""
      rescue SystemCallError
        ""
      end

      def self.xdg_attributes
        config = ENV.fetch("XDG_CONFIG_HOME", "")
        File.join(config.empty? ? File.join(Dir.home, ".config") : config, "git", "attributes")
      end

      def self.listed(repo, masks)
        checkout = Isolation::Checkout.of(repo.top)
        listing = git(checkout, "ls-files", "-s", "-z", "--", *masks.keys) or return
        tracked = listing.split("\0").to_h { |line| line.split(/[ \t]/, 4).then { [_1.last, _1] } }
        entries = masks.sort.filter_map do |path, bytes|
          relative = path.delete_prefix("#{repo.top}/")
          mode, blob, stage = tracked[relative]
          Entry.new(path: relative, mode:, blob:, bytes:) unless stage && stage != "0"
        end
        [entries, git(checkout, "rev-parse", "-q", "--verify", "HEAD")&.chomp]
      end
      private_class_method :inside, :dot_gits, :located, :user_attributes, :xdg_attributes, :listed

      # @param repo [Repo, nil]
      # @param entries [Array<Entry>]
      # @param head [String, nil]
      # @param stamps [Array, nil] the repo's stamps when the entries were listed
      def initialize(repo, entries, head:, stamps: nil)
        @repo = repo
        @entries = entries
        @head = head
        @stamps = stamps
        @checkout = Isolation::Checkout.of(repo.top) if repo
      end

      NONE = new(nil, [], head: nil)

      # @return [Hash{String => String}] the attributes file to bind into the run, at {ATTRIBUTES}
      def binds
        return {} if filterable.empty?

        lines = filterable.map { |entry, index| "/#{entry.path} filter=#{FILTER}#{index}\n".b }
        { ATTRIBUTES => [@repo.attributes, *lines].join }
      end

      # @return [Hash{String => String}] git config for the run, through the environment
      def env
        return {} if filterable.empty?

        cleans = tracked.each_with_index.map { |entry, index| clean(entry, index) }
        config = [["core.attributesFile", ATTRIBUTES], *cleans]
        pairs = config.each_with_index.flat_map do |(key, value), index|
          [["GIT_CONFIG_KEY_#{index}", key], ["GIT_CONFIG_VALUE_#{index}", value]]
        end
        { "GIT_CONFIG_COUNT" => config.size.to_s, **pairs.to_h }
      end

      # Nothing runs unless the index or HEAD moved. When one did, every tracked mask git still holds whole
      # is written back too, which clears the size and times the run's git recorded off the stand-in: left,
      # they make the host's `git status` call the file changed and refuse a rebase.
      #
      # @return [Settled] what was put back, what was taken out, what git refused with the command that
      #   undoes it, and each new commit holding a stand-in with its path
      def settle
        return Settled.new if @entries.empty? || @repo.stamps == @stamps

        staged = blobs
        decoys = @entries.map { @repo.blob_id(_1.bytes) }
        back, out = stand_ins(staged, decoys).partition(&:tracked?)
        whole = tracked.select { staged[_1.path] == [_1.mode, _1.blob] }
        settled(back:, out:, decoys:, restored: back_in_index?(back + whole) ? back : [],
                unstaged: out_of_index?(out) ? out : [])
      end

      private

      def stand_ins(staged, decoys)
        @entries.select { |entry| staged[entry.path]&.last.then { _1 != entry.blob && decoys.include?(_1) } }
      end

      def settled(back:, out:, decoys:, restored:, unstaged:)
        failed = undos(back - restored, "update-index", "--cacheinfo") { cacheinfo(_1) } +
                 undos(out - unstaged, "rm", "--cached", "-f", "--", &:path)
        Settled.new(restored: restored.map { shown(_1.path) }, unstaged: unstaged.map { shown(_1.path) }, failed:,
                    commits: head == @head ? [] : commits(decoys))
      end

      # Pasted into a shell from wherever the human stands, so it names the repo and quotes every word.
      def undos(entries, *argv)
        entries.map do |entry|
          words = [@repo.top, *argv, yield(entry)].map { pasteable(_1) }
          [shown(entry.path), "git -C #{words.join(" ")}"]
        end
      end

      # A control byte would reach the human's terminal raw, and invalid UTF-8 cannot sit in a note, so such a
      # word becomes an ANSI-C `$'...'` word, which bash and zsh both read.
      def pasteable(word)
        text = shown(word)
        return Shellwords.escape(text) if text.valid_encoding? && !text.match?(/[[:cntrl:]]/)

        "$'#{word.b.each_byte.map { ansi_c(_1) }.join}'"
      end

      def ansi_c(byte) = ANSI_C_PLAIN.include?(byte) ? byte.chr : format("\\x%02x", byte)

      def shown(path) = path.dup.force_encoding(Encoding::UTF_8)

      def tracked = @entries.select(&:tracked?)

      def clean(entry, index) = ["filter.#{FILTER}#{index}.clean", "git cat-file blob #{entry.blob}"]

      def filterable = tracked.each_with_index.select { |entry, _| PLAIN.match?(entry.path) }

      def git(*, input: nil) = self.class.git(@checkout, *, input:)

      def head = git("rev-parse", "-q", "--verify", "HEAD")&.chomp

      # @return [Hash{String => Array(String, String)}] each staged path's mode and blob
      def blobs
        git("ls-files", "-s", "-z", "--", *@entries.map(&:path)).to_s.split("\0").to_h do |line|
          mode, blob, _stage, path = line.split(/[ \t]/, 4)
          [path, [mode, blob]]
        end
      end

      def cacheinfo(entry) = "#{entry.mode},#{entry.blob},#{entry.path}"

      # An entry written by `--cacheinfo` has no size or times, so plumbing such as `diff-files` calls it
      # changed until the refresh reads them back off the file.
      def back_in_index?(entries)
        return true if entries.empty?
        return false unless git("update-index", *entries.flat_map { ["--cacheinfo", cacheinfo(_1)] })

        git("update-index", "-q", "--refresh")
        true
      end

      # `-f`, since the stand-in staged differs from both the file and HEAD, which git's own check refuses.
      def out_of_index?(entries) = entries.empty? || !git("rm", "--cached", "-f", "-q", "--", *entries.map(&:path)).nil?

      # Each commit since HEAD that changed a mask's path to a stand-in, newest first.
      def commits(decoys)
        range = @head ? "#{@head}..HEAD" : "HEAD"
        paths = @entries.map(&:path)
        logged = git("log", "-z", "--format=%H", "--raw", "--no-renames", "--no-abbrev", range, "--", *paths).to_s
        recorded = @entries.to_h { [_1.path, _1.blob] }
        logged.scan(/(\h{40,64})\0\n?((?::[^\0]*\0[^\0]*\0)*)/n).flat_map do |commit, raw|
          raw.scan(/:\S+ \S+ \h+ (\h+) \S+\0([^\0]*)\0/n)
             .select { |blob, path| decoys.include?(blob) && blob != recorded[path] }
             .map { |_, path| [commit, shown(path)] }
        end
      end
    end
  end
end
