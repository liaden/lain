# frozen_string_literal: true

module Lain
  module Survey
    # Which paths under a root a survey may read, and what it kept out.
    #
    # A survey reads EVERY file it lists, which is categorically unlike a diff
    # review reading only what changed. So admission is decided here, once, for
    # the whole corpus: every candidate is classified by name before it is
    # opened, and the two answers a path can get are "listed" or {Withheld}.
    #
    # == The routing is two-way, not three
    #
    # A DENIED path is withheld: denial is not approvable, and no policy,
    # `--yolo` or approval lifts one. Everything else -- gated and ordinary
    # alike -- is listed, with the verdict kept on the listing so a surface can
    # say why a file arrived masked. Withholding a gated file wholesale was this
    # walk's first draft and is wrong in the expensive direction: it would make
    # `/survey` STRICTER than the read path over the same file, which projects
    # it to its released regions ({Projection}) rather than hiding it.
    #
    # == A SYMBOLIC link is two names for one file, and both are classified
    #
    # {Sensitivity} is LEXICAL by contract and makes no syscall, so it can only
    # ever judge the name it is handed -- and a walk that handed it the name it
    # discovered would let `notes.txt -> ~/.netrc` into a corpus with a verbatim
    # password in it. `read_file` is not exposed the same way, because a model
    # has to NAME a path to read it; a survey DISCOVERS every link in a tree and
    # follows it unasked, which is what makes resolution this object's job.
    #
    # So a symbolic link is resolved with `File.realpath` and judged by BOTH
    # names, strictest verdict winning, before anything is opened. The
    # classifier keeps its no-IO contract; the walk, which already stats and
    # sniffs, does the resolving. Then, and only then, containment: a link
    # resolving out of the surveyed tree is withheld as `:outside`, because the
    # human pointed at a directory and reviewing what a link reaches beyond it
    # is a scope nobody agreed to. DENIAL IS TESTED FIRST, so a link out of the
    # tree to a private key is disclosed as the private key it is rather than as
    # a scope note. A broken link is skipped, exactly as a file that vanished
    # mid-walk is.
    #
    # SYMBOLIC is the word that matters. A HARD link is also two names for one
    # file, and only the in-tree one is classified -- there is no target path to
    # resolve, `lstat` cannot tell it from an ordinary file, and it genuinely IS
    # a file in the tree. It is therefore the same case as a plain copy of a
    # secret, which `read_file` passes through identically, and it falls to
    # {Projection}'s stated residual rather than to the classifier.
    #
    # Resolution settles WHICH FILE this was at the moment it was asked, and no
    # more than that: a link swapped afterwards points the later read somewhere
    # else. The window is not the microseconds inside {#linked} -- it is the
    # whole gap between this walk and the corpus reading the file, and closing
    # it means carrying the RESOLVED target on the {Listing} so the read follows
    # the path that was classified. Not done here because it needs write access
    # to the tree being surveyed, at which point pasting the secret into a file
    # is simpler, and `read_file` has the identical property.
    #
    # == Two rules that would otherwise be invented four times
    #
    # BINARY is a NUL byte in the first {SNIFF} bytes. A bounded sniff is
    # permitted and a full read is not -- a survey that read every blob to
    # decide whether to list it has already paid the cost the laziness exists to
    # avoid. This deliberately diverges from grep's semantics, which read on;
    # `crates/lain-core/src/grep.rs`'s `BinaryDetection::quit(0)` note already
    # records that the Ruby and Rust arms are not subsets of each other.
    #
    # IGNORES are git's answer, never ours. When the root is a repository the
    # walk asks `ls-files` once, so `tmp/`, a compiled `*.so` and vendored trees
    # never enter; a non-repository root walks everything, which is what a LaTeX
    # directory or a folder of prose wants. Re-implementing gitignore in Ruby is
    # exactly what the crate-survey rule exists to prevent, and an ignored path
    # is NOT withheld -- it is simply not listed (see {Withheld}).
    #
    # == The size is a stat, and that is all it is
    #
    # `Bounds` needs a cheap size per path before anything is parsed, and
    # re-reading every file to count lines defeats the purpose. So a listing
    # carries BYTES, from the same `stat` that answered "is this a file at
    # all"; line counts arrive later, harvested by the identity pass that has
    # to read each file once anyway.
    class Walk
      # A root that is not a directory to walk. Subclasses {Lain::Error} next to
      # the owner that raises it, per the error-taxonomy convention, so a
      # frontend renders it rather than a backtrace.
      class Refused < Error; end

      # The bounded binary sniff, in bytes.
      SNIFF = 8192

      # Two jobs, one byte: what makes content binary, and what `-z` separates
      # git's paths with. Both are "the byte no text holds".
      NUL = "\0"

      # `--cached` and `--others` together are the working tree as it stands --
      # tracked files plus untracked ones -- and `--exclude-standard` is what
      # applies `.gitignore`, `.git/info/exclude` and the user's global excludes
      # without us knowing any of their rules. `-z` because git QUOTES an
      # unusual name otherwise, and a newline in a name splits a line-delimited
      # reading into two paths that name nothing ({Project::Dotfiles}' lesson).
      LS_FILES = %w[ls-files -z --cached --others --exclude-standard].freeze

      # Seconds one `git` may take. {Project::Dotfiles::GIT_TIMEOUT}'s figure and
      # its reasoning: this runs while a human waits for a survey to open, and a
      # convenience that hangs on a wedged filesystem costs more than it is
      # worth. A child that outlives it reads as "no repository".
      GIT_TIMEOUT = 10

      # `**` with `FNM_DOTMATCH` visits every dotfile -- which a survey wants --
      # but also `.` and `..` and everything under `.git`, which is not content.
      SKIPPED = %w[. .. .git].freeze

      # Paths out of a subprocess are `ASCII-8BIT` and paths out of `Dir.glob`
      # carry this, and the two must compare and sort as one set
      # ({Project::Dotfiles}, at length).
      FILESYSTEM = Encoding.find("filesystem")

      Listing = Data.define(:path, :absolute, :size, :verdict)

      # One path the survey may read: how it is named, where it is, how big it
      # is, and what the classifier made of it.
      #
      # `size` is the file's own bytes, PRE-PROJECTION -- what `stat` said, not
      # what the corpus will hold. The two differ wherever a region is masked
      # (a placeholder is shorter than most secrets), so a ceiling computed from
      # this sizes the tree rather than the corpus. Deliberate: the ceiling has
      # to answer before anything is read, which is the point of taking it from
      # `stat`.
      #
      # The verdict RIDES ALONG rather than being re-derived downstream, so a
      # disclosure can say a file arrived masked because its name is
      # credential-shaped without classifying it a second time and risking a
      # second answer.
      class Listing
        def initialize(path:, absolute:, size:, verdict:)
          super(path: path.dup.freeze, absolute: absolute.dup.freeze, size: Integer(size), verdict:)
        end

        def gated? = verdict.gated?
        def explanation = verdict.explanation
      end

      # Whether `path` IS the tree at `root` or sits below it -- a whole SEGMENT
      # comparison, so `/repo` never swallows `/repo-backup`
      # ({Sensitivity::Rule#descends?}' rule, for its reason).
      #
      # `File.join(root, "")` and not `"#{root}/"`, because the filesystem root
      # already ends in the separator: the interpolation builds `//`, which no
      # path starts with, and every link in the tree would then be withheld as
      # outside it. Public because it is the one expression here worth pinning
      # directly -- the case that decides it is a survey rooted at `/`, which
      # cannot be built as a fixture without walking the filesystem.
      #
      # @param root [String] a resolved, absolute directory
      # @param path [String] a resolved, absolute path
      def self.contains?(root, path) = path == root || path.start_with?(File.join(root, ""))

      include Enumerable

      # @return [String] the surveyed root, absolute
      attr_reader :root

      # @return [Array<Listing>] frozen, ascending by path
      attr_reader :files

      # @return [Array<Withheld>] frozen, ascending by path
      attr_reader :withheld

      # Walked EAGERLY, then frozen: the walk is the cheap half (one `git`, one
      # `stat` and one bounded sniff per path) and every later card asks it the
      # same two questions repeatedly. {Sensitivity::Policy}'s posture -- build
      # in `initialize`, before the freeze, because a lazy memo on a frozen
      # object raises at its first caller, mid-run.
      #
      # @param root [String, Pathname] the directory to survey
      # @param sensitivity [Sensitivity] the run's classifier, INJECTED: it
      #   carries the home and cwd a path is resolved against, and constructing
      #   one here would be a second classifier able to disagree with the gate
      # @param shell_out_factory [#call] builds the subprocess runner, the
      #   `shell_out_factory` seam every git caller here takes
      # @raise [Refused] when `root` is not a directory
      def initialize(root:, sensitivity:, shell_out_factory: Shell::Out.public_method(:new))
        @root = File.expand_path(root)
        raise Refused, "#{root} is not a directory, so there is nothing to survey" unless File.directory?(@root)

        # Containment is judged against the RESOLVED root, so a survey of a
        # symlinked directory (`/tmp` on a Mac, a checkout reached through a
        # link) does not declare every one of its own files outside itself.
        @resolved = File.realpath(@root)
        @sensitivity = sensitivity
        @shell_out_factory = shell_out_factory
        @files, @withheld = sift(candidates)
        freeze
      end

      # @yieldparam listing [Listing]
      def each(&block) = @files.each(&block)

      private

      # Sorted and de-duplicated here and nowhere else, so both arms answer one
      # order. Neither is falsifiable on its own -- `Dir.glob` has sorted since
      # Ruby 3.0 and `git ls-files` merge-sorts its tracked and untracked
      # halves, and no arm produces a duplicate (an unmerged index would) -- but
      # `.reverse` in either position does fail a spec, so the ORDER is pinned
      # even where the call that establishes it is redundant. Kept because the
      # guarantee is this method's to make, not its sources' to keep making.
      def candidates = (tracked || globbed).uniq.sort

      # nil means "git has no answer here", which covers both a directory that
      # is not a repository AND one that is itself ignored -- `ls-files` exits 0
      # with empty output for the second, so an empty answer must fall through
      # to the glob or `lain survey tmp/notes` silently presents nothing at all.
      # A repository whose whole tree is ignored therefore walks like a plain
      # directory, which is what the human naming that directory meant.
      def tracked
        listed = git(*LS_FILES)
        paths = listed.to_s.split(NUL).reject(&:empty?).map { _1.dup.force_encoding(FILESYSTEM) }

        paths unless paths.empty?
      end

      def globbed
        Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH)
           .map { |entry| entry.delete_prefix("#{@root}#{File::SEPARATOR}") }
           .reject { |relative| skipped?(relative) }
      end

      # BYTES, and the path BELOW the root. Bytes because `String#split` raises
      # `ArgumentError` on a name that is not valid UTF-8 -- `café.tex` in a
      # latin-1 documents tree took the whole survey down with a backtrace --
      # and below the root because a root whose own path holds a `.git`
      # component would otherwise skip every candidate under it.
      def skipped?(relative) = relative.b.split(File::SEPARATOR).intersect?(SKIPPED)

      def sift(relatives)
        decided = relatives.filter_map { |relative| decide(relative) }

        [decided.grep(Listing).freeze, decided.grep(Withheld).freeze]
      end

      # Classify FIRST, open second. A denied path's bytes are never read at
      # all -- not even the sniff -- which is the whole reason the classifier
      # answers from the name. `lstat` and not `stat`, so a link is seen as a
      # link and gets its target classified too rather than being judged by the
      # name it happens to wear.
      def decide(relative)
        absolute = File.join(@root, relative)
        entry = File.lstat(absolute)
        return linked(relative, absolute) if entry.symlink?
        return nil unless entry.file?

        admit(relative, absolute, entry.size, verdict_for(absolute))
      rescue SystemCallError
        # Vanished, unreadable, or a broken link, between the listing and here.
        # Skipped the way a real grep skips what it cannot read: one bad file
        # must not take the survey down.
        nil
      end

      # `realpath` raises on a broken link, which {#decide}'s rescue turns into
      # "not listed" -- the honest answer for a name pointing at nothing.
      def linked(relative, absolute)
        target = File.realpath(absolute)
        verdict = verdict_for(absolute, target)
        return Withheld.denied(relative, verdict) if verdict.denied?
        return Withheld.outside(relative) unless within?(target)
        return nil unless File.stat(absolute).file?

        admit(relative, absolute, File.size(absolute), verdict)
      end

      # The STRICTEST of the names one file answers to. `Verdict::LEVELS` is
      # ordered `ordinary, gated, denied`, so its index IS the strictness order
      # and there is no second table to keep in step. Ties keep the first name,
      # which is the link's own.
      def verdict_for(*names)
        names.map { @sensitivity.classify(_1) }
             .max_by { Sensitivity::Verdict::LEVELS.index(_1.level) }
      end

      # Against the RESOLVED root, so a survey whose own root is reached through
      # a link does not declare every file in its tree outside it.
      def within?(target) = Walk.contains?(@resolved, target)

      def admit(relative, absolute, size, verdict)
        return Withheld.denied(relative, verdict) if verdict.denied?
        return Withheld.binary(relative) if binary?(absolute)

        Listing.new(path: relative, absolute:, size:, verdict:)
      end

      # `read` answers nil for an empty file, which is text.
      def binary?(path) = File.open(path, "rb") { |file| file.read(SNIFF).to_s.include?(NUL) }

      # Raw stdout on success and nil for every way git can fail to answer --
      # non-zero, signalled (`exitstatus` is nil), timed out, or not installed.
      # Callers read nil as "no repository", which is the fail-open direction
      # here on purpose: a survey that listed nothing because git was missing
      # would look like an empty directory.
      def git(*argv)
        shell = @shell_out_factory.call("git", "-C", @root, *argv,
                                        environment: Isolation::Worktree::GIT_CONTEXT_SCRUB,
                                        timeout: GIT_TIMEOUT)
        shell.run_command
        shell.stdout if shell.exitstatus&.zero?
      rescue Shell::Out::Timeout, SystemCallError
        nil
      end
    end
  end
end
