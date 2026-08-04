# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Review
    # What is left to re-read after a reviewed branch has been rewritten.
    #
    # == Why range-diff, and why `git diff` is not a fallback
    #
    # An agent rebases between rounds, so by the second look every sha differs
    # and the base has moved underneath. `git diff <reviewed_head> <head>`
    # compares two TREES, so it reports the base branch's own new commits --
    # work this human never reviewed and is not being asked to. `git range-diff`
    # compares two PATCH SERIES, and answers the question actually being asked:
    # which of these commits is, by content, the one I already read. §3.7
    # measured 29 of 30 identical in 0.22s after a rebase plus an amend, with all
    # 30 shas changed. There is no fallback primitive; the tree compare was
    # measured wrong for this job.
    #
    # == The four flags are the answer's determinism, and each was measured
    #
    # `--no-patch` is what makes the header lines the WHOLE output, which is why
    # none of {Source::LocalBranch::DIFF_HYGIENE}'s prefix and context pins
    # appear here: with no patch rendered, `diff.noprefix`, `diff.context`,
    # `diff.algorithm` and `diff.renames` cannot reach the bytes, and measurement
    # confirms range-diff ignores `diff.external` and a textconv driver outright
    # (a live canary proved both DO reach a plain `git diff` in the same repo).
    # The four that do reach it:
    #
    # - `--no-color`, because `color.ui=always` puts SGR escapes into a pipe and
    #   the entry regex stops matching.
    # - `--abbrev=64`, because `core.abbrev` sets the sha width. Asking for the
    #   hash's full width rather than 40 makes the answer both deterministic and
    #   JOINABLE with {Source::Commit#sha}, and git caps the request at the
    #   repository's own hash length, so one number covers sha1 and sha256.
    # - `--no-notes`, the one nobody would guess: range-diff includes a commit's
    #   NOTES in the patch text it compares, so a note attached to a reviewed
    #   commit flips it from identical to changed and sends a human back to code
    #   that did not move.
    # - `-c i18n.logOutputEncoding=UTF-8`, because range-diff has no `--encoding`
    #   option (measured: it is rejected) and that setting -- or `i18n.commitEncoding`,
    #   which it falls back to -- makes git emit a latin-1 subject. Invalid bytes
    #   in the Journal break `JSON.parse` on that NDJSON line.
    #
    # `--end-of-options` is absent for a reason worth stating: `git range-diff`
    # does NOT accept it -- it consumes it as a range argument and dies. Leading-dash
    # safety is structural instead: both ranges are built from shas this class
    # resolved itself, so there is nothing a caller can spell that reaches git as
    # an option.
    class Delta
      include Enumerable

      # git's four verdicts on a commit. `<` and `>` are not degenerate `!`s: an
      # amend that rewrites a file wholesale exceeds the 60% creation factor and
      # comes back as a drop PLUS an add, and a human re-reading that pair is
      # reading two different commits, not one changed one.
      MARKERS = { "=" => :identical, "!" => :changed, "<" => :dropped, ">" => :added }.freeze

      STATUSES = MARKERS.values.freeze

      # See the class doc: each was measured against a config a developer really
      # has, and each has an example that fails without it.
      HYGIENE = %w[--no-patch --no-color --no-notes --abbrev=64].freeze

      # `-c`, not a scrubbed environment: this arrives from ~/.gitconfig, which
      # no environment change can reach.
      #
      # `core.quotePath=false` is deliberately NOT here, though
      # {Source::LocalBranch::CONFIG_PINS} pins it. Measured: with {Wire.unquote}
      # on the path, the pin has no observable effect -- quoting is exactly what
      # unquote inverts, so `café.rb` comes back the same either way, and the
      # mutant that removes it survives every fixture including a non-ASCII path
      # read under `core.quotePath=true`. A pin that cannot change an answer
      # claims a protection this does not have.
      CONFIG_PINS = %w[-c i18n.logOutputEncoding=UTF-8].freeze

      # One entry line, whole. Padding is variable -- git right-aligns both
      # indices to the width of the larger range -- and a vanished side is spelled
      # `-:` with a run of dashes where the sha would be. An empty subject is a
      # real if pathological commit, so the separator before it is optional
      # rather than a parse failure.
      ENTRY = /\A\s*(?<old_index>-|\d+):\s+(?<old_sha>-+|\h+)\s+(?<marker>[=!<>])
               \s+(?<new_index>-|\d+):\s+(?<new_sha>-+|\h+)(?:\ (?<subject>.*))?\z/x

      # `--format=` empties the commit header so every non-empty line is a path,
      # and `--no-walk=unsorted` shows each sha given as its own commit in the
      # order asked rather than walking history. `--no-show-signature` because
      # `log.showSignature=true` puts gpg's verification chatter on STDOUT, in
      # among the names, where this would read it as a file (measured against a
      # signed commit; range-diff itself is immune to the same setting).
      #
      # `--no-renames` because this call carries no `--no-patch`, so unlike the
      # range-diff above it IS exposed to `diff.renames` -- and the DEFAULT is
      # the harmful setting. Measured: with rename detection on, a renamed file
      # is listed as its destination ALONE; off, both sides appear. The old path
      # is what a reviewer needs to stop looking for, and dropping it also
      # contradicts {#paths}' own rule that a changed entry contributes both
      # sides. Two developers would otherwise get two answers for one delta.
      #
      # No `--diff-merges` here, and it is not merely dead: `git range-diff`
      # REJECTS the option outright, and it omits merge commits from a range
      # altogether -- reporting the side branch's own commits instead -- so no
      # sha reaching this call is ever a merge. See {#paths} for what that costs.
      NAMES = %w[--no-walk=unsorted --name-only --no-color --no-show-signature
                 --no-renames --format= --end-of-options].freeze

      # What git said about one commit, and nothing derived. `old_*` is nil for
      # an added commit and `new_*` for a dropped one -- nil rather than a
      # sentinel, because a caller cannot tell a placeholder from a real value,
      # the reason {Source::FileStat} keeps nil for a binary file's counts.
      Entry = Data.define(:status, :old_index, :old_sha, :new_index, :new_sha, :subject) do
        def identical? = status == :identical
      end

      # A git call this class depends on could not answer, or answered in a shape
      # it does not parse. All of these are one fact -- this git cannot serve a
      # re-review -- and the card's own escalation trigger says there is nothing
      # to fall back to, so none may pass quietly as an empty delta.
      #
      # {.unlisted} is the one that is easy not to write and expensive to omit:
      # a failing `git log` with an unchecked exit status renders "git could not
      # answer" as an EMPTY {#paths}, which a caller reads as "nothing to
      # re-read" -- the worst answer this class can give, and indistinguishable
      # from the good news it is imitating.
      class Unreadable < Error
        # {Source::UnknownRef.because} rather than a second copy of it: it is the
        # same "git's own words, when it had any", about the same repository.
        def self.failed(shell)
          new("git range-diff could not answer#{Source::UnknownRef.because(shell)}")
        end

        def self.unparsed(line)
          new("git range-diff answered a line this cannot read: #{line.inspect}. " \
              "There is no fallback primitive -- a tree compare was measured wrong for this job")
        end

        def self.unlisted(shell)
          new("git log could not name the files of the commits needing re-review, " \
              "so an empty answer would read as nothing to re-read#{Source::UnknownRef.because(shell)}")
        end
      end

      # The baseline could not be WRITTEN, as distinct from a head that does not
      # resolve. The two were one refusal and it lied: under a held `.lock` --
      # this card's own concurrent-reviews case -- it reported that the ref "does
      # not resolve to a commit" while git's appended words said `cannot lock
      # ref`, flatly contradicting it in the same sentence. {Pin#write} now
      # resolves first, so anything reaching here is a write failure and git's
      # own words say which.
      class Unpinnable < Error
        def self.failed(ref, shell)
          new("could not pin the reviewed baseline at #{ref}#{Source::UnknownRef.because(shell)}")
        end
      end

      # Nothing is pinned at this scope and generation. Beside {Unreadable} and
      # {Source::UnknownRef}, never beneath them: "no baseline" is not a broken
      # machine and not a mistyped ref, it is the ordinary fact that this is a
      # FIRST review, and the caller's next move is to show the whole changeset.
      class NoBaseline < Error
        def self.unpinned(ref, repo_root)
          new("no reviewed baseline is pinned at #{ref} in #{repo_root}; " \
              "this is a first review, not a re-review")
        end
      end

      # How both objects here reach git: one place for the `shell_out_factory`
      # seam, the pinned config, and the encoding rule -- rather than the private
      # `#git` that {Source::LocalBranch} and {Source::GithubPr} each keep a copy
      # of. Injected as a collaborator, so a spec substitutes the factory once
      # and both objects are covered.
      class Git
        def initialize(repo_root:, shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @repo_root = File.expand_path(repo_root)
          @shell_out_factory = shell_out_factory
        end

        # @return [String] the repository these calls are made against
        attr_reader :repo_root

        # {Isolation::Worktree}'s pinned scrub set, not a parallel copy: an
        # ambient GIT_DIR (a pre-commit hook sets one) would point every call at
        # the hook's repository instead of `repo_root`. Read from a METHOD body
        # because `lain.rb` loads isolation after review, so a class-body
        # reference would be a load-time NameError.
        def run(*)
          shell = @shell_out_factory.call("git", "-C", @repo_root, *CONFIG_PINS, *,
                                          environment: Isolation::Worktree::GIT_CONTEXT_SCRUB)
          shell.run_command
          shell
        end

        # mixlib tags stdout UTF-8 when the bytes HAPPEN to be valid and BINARY
        # when they are not, so without this a field's encoding depends on its
        # content -- and these fields are journalled as JSON, into NDJSON, where
        # one bad line breaks the parse of the experiment record.
        def text(bytes) = bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub

        # `--verify --quiet` exits nonzero with no output when the rev names
        # nothing. `^{commit}` refuses a rev resolving to a tree or a blob, and
        # `--end-of-options` makes leading-dash safety structural.
        def resolve(rev)
          run("rev-parse", "--verify", "--quiet", "--end-of-options", "#{rev}^{commit}")
        end
      end

      # @param pinned_base [String] the base the review was taken against
      # @param pinned_head [String] the head that was reviewed -- {Pin} is what
      #   keeps it reachable, and `pinned_base` rides along as its ancestor
      # @param base [String] the base now, as {Source::LocalBranch#base_ref}
      #   answers it: already a merge base, so no merge base is derived here
      # @param head [String] the head now
      # @param repo_root [String] the repository to read
      # @param shell_out_factory [#call] builds the subprocess runner, injected
      #   as a factory exactly as {Source::LocalBranch} does
      # @raise [Source::UnknownRef] if any of the four does not resolve
      def initialize(pinned_base:, pinned_head:, base:, head:, repo_root: Dir.pwd,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @git = Git.new(repo_root:, shell_out_factory:)
        @reviewed = range("pinned base", pinned_base, "pinned head", pinned_head)
        @current = range("base", base, "head", head)
      end

      # @return [Array<Entry>] in git's order, one per commit of either range
      def entries = @entries ||= parse(range_diff).freeze

      def each(&block) = entries.each(&block)

      # @return [Array<Entry>] the commits whose patch is byte-for-byte the one
      #   already reviewed, however far their shas have moved
      def identical = with(:identical)

      def changed = with(:changed)
      def dropped = with(:dropped)
      def added = with(:added)

      # @return [Array<Entry>] everything the human has not already read
      def attention = reject(&:identical?)

      def unchanged? = attention.empty?

      # @return [Array<String>] the files touched by {#attention}, sorted and
      #   unique. A changed entry contributes BOTH sides: an amend that deletes
      #   a file is exactly the thing a reviewer must be sent back to. Costs one
      #   subprocess, and none at all when nothing changed -- proportional to the
      #   delta rather than to the series, which is the whole point of the
      #   primitive.
      #
      #   THE MERGE HOLE, stated rather than hidden: range-diff drops merge
      #   commits, so a file that exists only in a hand resolution appears in no
      #   entry and therefore in no path here. There is no flag that recovers it
      #   -- the primitive compares patch series, and a merge has no patch --
      #   and the spec pins the behaviour so a reader meets it as a measured
      #   fact rather than as a surprise mid-review.
      def paths = @paths ||= gather_paths.freeze

      private

      def with(status) = select { |entry| entry.status == status }

      def range(base_role, base, head_role, head)
        "#{resolve!(base_role, base)}..#{resolve!(head_role, head)}"
      end

      def resolve!(role, rev)
        shell = @git.resolve(rev)
        raise Source::UnknownRef.unresolved(role, rev, @git.repo_root, shell) unless shell.exitstatus.zero?

        @git.text(shell.stdout).strip
      end

      def range_diff
        shell = @git.run("range-diff", *HYGIENE, @reviewed, @current)
        raise Unreadable.failed(shell) unless shell.exitstatus.zero?

        @git.text(shell.stdout)
      end

      def parse(output) = output.each_line.map(&:chomp).reject(&:empty?).map { |line| entry(line) }

      def entry(line)
        fields = ENTRY.match(line)
        raise Unreadable.unparsed(line) unless fields

        Entry.new(status: MARKERS.fetch(fields[:marker]), subject: -fields[:subject].to_s, **sides(fields))
      end

      def sides(fields)
        { old_index: index(fields[:old_index]), old_sha: sha(fields[:old_sha]),
          new_index: index(fields[:new_index]), new_sha: sha(fields[:new_sha]) }
      end

      def index(field) = field == "-" ? nil : Integer(field, 10)

      # A vanished side is a run of dashes as wide as the sha would have been.
      def sha(field) = field.start_with?("-") ? nil : -field

      def gather_paths
        shas = attention.flat_map { |entry| [entry.old_sha, entry.new_sha] }.compact.uniq
        shas.empty? ? [] : names(shas)
      end

      # UNQUOTED before it is decoded, and {CONFIG_PINS}' `core.quotePath=false`
      # is not enough on its own: that setting governs non-ASCII paths, while a
      # name carrying a quote, a backslash, a tab or a newline is C-quoted
      # whatever it says. One decoder, {Wire.unquote}, at the edge every source
      # of a path in this codebase crosses.
      def names(shas)
        shell = @git.run("log", *NAMES, *shas)
        raise Unreadable.unlisted(shell) unless shell.exitstatus.zero?

        shell.stdout.b.each_line.map(&:chomp).reject(&:empty?)
             .map { |name| -@git.text(Wire.unquote(name)) }.uniq.sort
      end

      # The ref that keeps a reviewed head reachable, and the name it is written
      # under.
      #
      # WHY A REF AT ALL. Once the branch is rewritten, nothing else points at
      # the commits the human read: they are unreachable, and `git gc` may take
      # them at any time. Without them there is no old range and so no
      # range-diff -- the re-review degrades silently into a first review.
      #
      # WHY THAT NAMESPACE. The reasoning {Isolation::Worktree::Handback::Naming}
      # records for `refs/lain/worker`, and this is its sibling: outside
      # `refs/heads/` a ref is invisible to `git branch` and unreachable by the
      # DWIM that invents a checkout from a name, so a pinned baseline can never
      # be mistaken for -- or checked out as -- a branch. `refs/lain/reviewed/`
      # does not collide with it or with `refs/heads/epic/` ({Forge::Promotion}),
      # the only other two lain writes.
      #
      # WHY THE SCOPE KEY IS NOT OPTIONAL. A generation alone is not unique: a
      # standalone `lain review` has no epic slug, and two reviews open at once
      # on different branches would write the same ref -- `update-ref` overwrites
      # unconditionally, so one review's baseline would silently become the
      # other's. The key is a required keyword and a blank one is refused, which
      # is the only spelling under which that collision cannot come back.
      #
      # WHY A FINGERPRINT FOLLOWS THE SLUG. Slugging alone maps `epic/foo`,
      # `epic foo` and `epic-foo` onto one ref, and those are three scopes a
      # repository can really have at once. The readable half is what a human
      # greps for; the hex is what makes the mapping injective.
      #
      # ONE REF, AT THE HEAD, is enough for reachability: the reviewed base is
      # the merge base of that head, hence its ancestor, hence held alive by it.
      # Its VALUE is the caller's record to keep -- the session already journals
      # what it reviewed -- and inventing a second ref for it would put a
      # directory where this leaf ref lives.
      class Pin
        NAMESPACE = "refs/lain/reviewed"

        # git-check-ref-format rejects spaces, `~^:?*[\`, `@{`, `..`, a leading
        # `.` and a trailing `.` or `.lock`. A scope key is a branch name, a PR
        # number or an epic slug -- `epic/review-surface` and `feature/foo` both
        # carry a `/` -- so its bytes are slugged into that alphabet rather than
        # trusted.
        UNSAFE = /[^A-Za-z0-9._-]+/

        # Long enough to stay readable, short enough that the ref survives a
        # 255-byte filesystem path component once the fingerprint is appended.
        SLUG_LIMIT = 60

        # `core.logAllRefUpdates` logs only refs/heads, refs/remotes, refs/notes
        # and HEAD, so for this namespace a bare `-m` is accepted and simply
        # records nothing. It costs nothing and says who wrote the ref where it
        # is logged.
        REFLOG = "lain review: pinned"

        # @param scope_key [String] the epic slug for a gated review, the PR
        #   number or branch for a standalone one. Required, and refused BLANK --
        #   never merely unslugabble, see {#name}.
        # @param generation [Integer] which round of review this is, from 1
        # @param repo_root [String] the repository the ref is written in
        # @param shell_out_factory [#call] builds the subprocess runner
        # @raise [ArgumentError] if either cannot name a distinct baseline
        def initialize(scope_key:, generation:, repo_root: Dir.pwd,
                       shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @key = scope_key.to_s
          @generation = generation
          raise ArgumentError, refusal("scope_key must name what is under review", scope_key) if @key.strip.empty?
          raise ArgumentError, refusal("generation must be a positive Integer", generation) unless counted?

          @git = Git.new(repo_root:, shell_out_factory:)
        end

        # @return [String] the ref this baseline is written under
        def ref = @ref ||= -"#{NAMESPACE}/#{name}/#{@generation}"

        # Pins the reviewed head, resolving it FIRST so the two failures stay
        # distinguishable: a head that names nothing is the caller's mistake,
        # while a write that fails is the repository's state -- a held `.lock`
        # from a concurrent review being the case this card names. Folding them
        # together produced a refusal that git's own appended words contradicted.
        #
        # @param head [String] the rev being reviewed
        # @return [String] the sha now pinned
        # @raise [Source::UnknownRef] if `head` does not resolve
        # @raise [Unpinnable] if the ref could not be written
        def write(head)
          sha = resolved!(head)
          shell = @git.run("update-ref", "-m", REFLOG, ref, sha)
          raise Unpinnable.failed(ref, shell) unless shell.exitstatus.zero?

          -sha
        end

        # @return [Boolean] whether a baseline was ever pinned here
        def pinned? = !head_sha.nil?

        # @return [String] the reviewed head's sha
        # @raise [NoBaseline] if nothing is pinned here
        def resolve = head_sha || raise(NoBaseline.unpinned(ref, @git.repo_root))

        private

        def head_sha
          shell = @git.resolve(ref)
          shell.exitstatus.zero? ? -@git.text(shell.stdout).strip : nil
        end

        # The half of {#write} that judges the CALLER's argument, named apart
        # from the half that judges the repository's state -- which is the whole
        # point of the split, and keeps each refusal next to the thing it is
        # about.
        def resolved!(head)
          shell = @git.resolve(head)
          raise Source::UnknownRef.unresolved("pinned", head, @git.repo_root, shell) unless shell.exitstatus.zero?

          @git.text(shell.stdout).strip
        end

        # Rejects a Float and a numeric String alike: a generation is a counter
        # its caller owns, and `Integer("2")` quietly accepting one spelling of
        # it is how two rounds end up sharing a ref.
        def counted? = @generation.is_a?(Integer) && @generation.positive?

        # The readable half, and the fingerprint alone when there is no readable
        # half to have. `эпик` and `日本語のエピック` are legal branch names whose
        # every byte is outside a refname's alphabet, so they slug to nothing --
        # and refusing them would block the review outright over a cosmetic
        # half of a ref whose UNIQUENESS lives in the other half.
        def name = slug.empty? ? fingerprint : "#{slug}-#{fingerprint}"

        # `..` and a leading `.` are refused by git-check-ref-format, and both
        # are reachable from an ordinary key: `..foo` is a legal branch name and
        # `../../../heads/main` is what an escape out of the namespace looks
        # like. Slugging runs first, so a `/` is already a `-` by the time `..`
        # is looked for.
        def slug
          readable = @key.strip.gsub(UNSAFE, "-").gsub("..", "-").delete_prefix(".")[0, SLUG_LIMIT].to_s
          readable.delete_suffix("-")
        end

        # On the ORIGINAL key, never the slug -- that is what makes two keys
        # slugging alike land on two refs. `Canonical.digest` answers
        # `blake3:<hex>`, and a colon is not legal in a refname.
        def fingerprint = Canonical.digest(@key).split(":").last[0, 12]

        def refusal(claim, value) = "#{claim}, got #{value.inspect}"
      end
    end
  end
end
