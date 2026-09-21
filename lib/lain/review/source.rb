# frozen_string_literal: true

module Lain
  module Review
    # The changeset-source port: where a reviewable changeset comes from.
    #
    # A source answers SEVEN messages, and the shared example group
    # `"a review changeset source"` is the contract, not this comment:
    #
    #   #files        the changed files, as model values -- {ChangedFile}s
    #   #identity     the {Identity} an address is computed from
    #   #base_ref     what every old-side anchor rests on
    #   #head_ref     what every new-side anchor rests on
    #   #file_at      one path, as one revision holds it
    #   #diff_origin  where the bytes came from, and whether anything fell back
    #   #sides        which of {Review::SIDES} this round presents at all
    #
    # Every source also answers `#line_at`, one line by the file's own numbering,
    # which a note's evidence is read from. The shared group does not hold it
    # yet; each source's own spec does.
    #
    # {LocalBranch#diff} and {LocalBranch#commits} are NOT on that list. They
    # belong to sources that have unified-diff bytes and a commit walk, which is
    # a real category and not the port. Everything downstream -- the anchors, the
    # marks, the session's address -- reads only the seven, so none of them knows
    # which source it has.
    #
    # Six arguments behind this port live in `docs/review.md` under "The
    # changeset-source port": why {#sides} is the SOURCE's question and not a
    # file's, why the port hands down model values rather than bytes, why the
    # laws split into universal and diff-bearing halves, why {#file_at} exists
    # when a diff does not carry enough to draw from, why {DiffOrigin} is on the
    # port rather than under {GithubPr}, and why refusals here RAISE where
    # {Forge::Gh}'s are values.
    module Source
      # Whether each of {Review::SIDES} rests on the BASE revision. The literals
      # are KEYS here rather than answers: a `%w[new]` written as an answer would
      # be a second declaration of membership, free to disagree with the set that
      # decides it, while a `fetch` against a table makes the dependency real.
      # Add a side to {Review::SIDES} and this raises while the module body runs.
      RESTS_ON_BASE = { "old" => true, "new" => false }.freeze
      private_constant :RESTS_ON_BASE

      # What a source spanning two revisions presents: the vocabulary itself,
      # never a copy of it.
      BOTH_SIDES = Review::SIDES

      # What a source whose base holds nothing presents -- {Source::Corpus}, and
      # anything else surveyed as it stands.
      HEAD_SIDE_ONLY = Review::SIDES.reject { |side| RESTS_ON_BASE.fetch(side) }.freeze

      # A ref the source was built against does not resolve, or two refs share no
      # history so there is no merge base to anchor the old side to. Named per
      # the error-taxonomy convention: a refusal subclasses {Lain::Error} next to
      # the owner that raises it.
      class UnknownRef < Error
        # Which side {.unresolved} named, when it did -- "head", "base" or
        # "pull request" -- so a caller that offered only ONE of them behind
        # a flag (`--base`) can tell whether THAT flag caused this refusal
        # without parsing its own words back out of the message. Nil for
        # {.no_merge_base}, which is about neither side alone.
        attr_reader :role

        def self.unresolved(role, ref, repo_root, shell)
          new("#{role} ref #{ref.inspect} does not resolve to a commit " \
              "in #{repo_root}#{because(shell)}", role:)
        end

        def self.no_merge_base(base, head, repo_root)
          new("#{base.inspect} and #{head.inspect} share no merge base " \
              "in #{repo_root}, so there is no revision to anchor the old side to")
        end

        def initialize(message, role: nil)
          super(message)
          @role = role
        end

        # git's own words, when it had any. `rev-parse --verify --quiet`
        # silences "unknown revision" but NOT "not a git repository" or "cannot
        # change to …", and those two are the ones a caller most needs -- without
        # them a missing or wrong `repo_root` reports only that HEAD did not
        # resolve, which sends the reader looking at the wrong thing. Scrubbed
        # because stderr arrives as bytes.
        def self.because(shell)
          detail = shell.stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip
          detail.empty? ? "" : ": #{detail}"
        end
      end

      # A file section whose header names no `a/`+`b/` pair at all.
      # `diff.noprefix` is the realistic cause and {LocalBranch::DIFF_HYGIENE}
      # pins it off, so reaching this means the bytes did not come from a source
      # that pinned it.
      class Unparseable < Error; end

      # One file's line accounting within one commit.
      #
      # `added` and `deleted` are nil for a binary file rather than 0, because a
      # caller cannot tell 0/0 from an empty text change, and git itself spells
      # the distinction as `-` for exactly this reason.
      FileStat = Data.define(:path, :added, :deleted) do
        def binary? = added.nil? && deleted.nil?
      end

      # One commit in the walk, carrying its OWN numstat rather than the
      # cumulative one -- the sidebar's commit scope needs per-commit figures,
      # and §3.7 measured a cumulative view at 81,810 lines against one commit's
      # 2,727.
      Commit = Data.define(:sha, :subject, :body, :numstat)

      # Where {LocalBranch#diff} came from, and why. The requirement is that a
      # fallback be REPORTED rather than silent, and this is the report: a value
      # a caller renders or journals, carrying gh's own words rather than a
      # paraphrase. On the PORT rather than under {GithubPr}, where it was first
      # written -- see the module doc for what asking one source and not the
      # other cost.
      DiffOrigin = Data.define(:origin, :reason, :message, :fell_back) do
        # The object database could answer, so no API was ever asked. Both
        # sources reach it: {GithubPr} when the head was already fetched, and
        # {LocalBranch} always.
        def self.already_local
          new(origin: "object_database", reason: "already_local", message: "", fell_back: false)
        end

        def self.served = new(origin: "combined_diff_api", reason: "served", message: "", fell_back: false)

        # @param reason [String] `too_large` when GitHub named its own
        #   ceiling, `refused` or `timeout` otherwise
        # @param message [String] what gh said. SCRUBBED, not verbatim: this
        #   value is journalled, the Journal is NDJSON, and stderr is bytes --
        #   one line `JSON.generate` refuses breaks the parse of the whole
        #   experiment record. {UnknownRef.because} and {LocalBranch#text}
        #   scrub for the same reason.
        def self.fallback(reason:, message:)
          new(origin: "object_database", reason:,
              message: message.to_s.dup.force_encoding(Encoding::UTF_8).scrub.freeze,
              fell_back: true)
        end

        def fell_back? = fell_back
      end

      ChangedFile = Data.define(:old_path, :new_path, :binary, :hunks) do
        def initialize(old_path:, new_path:, hunks:, binary: false)
          super(old_path: old_path && -old_path, new_path: new_path && -new_path,
                binary:, hunks: hunks.freeze)
        end

        def path = new_path || old_path

        def binary? = binary
      end

      # One file's slice of the changeset.
      #
      # Two paths, because a rename has two and neither side can be assumed: an
      # addition has no old path, a deletion no new one. {#path} is the file's
      # IDENTITY -- the new path where there is one -- and is what {Hunk#path}
      # carries and what a mark is keyed under. The side-specific paths are what
      # an ANCHOR needs: an old-side anchor on a renamed file resolves against
      # `git show <base>:<old_path>`, and naming the new path there would resolve
      # nothing while still looking like a well-formed anchor.
      #
      # A binary file, a mode-only change and a pure rename each carry zero
      # hunks. They are still files here, because dropping them would lose the
      # fact that they changed.
      #
      # It answers {#status} -- the diff's own fact -- and deliberately not
      # `#state`, which is what {Surface::Text} reads as the marks-derived
      # tri-state. A file value cannot know that; joining the two is the
      # session's, and putting both meanings on one message name is how a table
      # renders the wrong glyph without anything failing.
      #
      # Reopened rather than folded into the `Data.define` block, {Anchor}'s
      # reason: {STATUSES} written inside that block would scope to
      # `Lain::Review` and `#status` would not find it. The docstring lives HERE
      # for the second half of the same rule -- YARD keeps one per namespace.
      class ChangedFile
        # The Symbol projection of {Review::FILE_STATUSES}, keyed by the String
        # spelling that declares it -- and read by PRODUCTION code, which is the
        # point of it. The first cut declared the vocabulary and never referenced
        # it: `#status` restated four Symbol literals and a spec held the two
        # lists equal, which is a shared vocabulary in name only.
        STATUSES = Review::FILE_STATUSES.to_h { |name| [name, name.to_sym] }.freeze

        # `fetch` makes the dependency real: drop or rename a member of
        # {Review::FILE_STATUSES} and this raises a `KeyError` where the status
        # is asked for, rather than drifting quietly apart from it.
        #
        # @return [Symbol] one of {STATUSES}' values
        def status
          return STATUSES.fetch("added") if old_path.nil?
          return STATUSES.fetch("deleted") if new_path.nil?

          STATUSES.fetch(old_path == new_path ? "modified" : "renamed")
        end

        # What this file costs a reader, in {Bounds::Size}'s unit: each hunk's
        # body plus its `@@` header, never the four-line preamble, which is a
        # constant per file and is what the file ceiling already governs.
        #
        # On the FILE because a bound must be able to size a view without
        # chunking it. {Bounds} used to sum `file.hunks` itself, which is free
        # here and is the whole corpus for a source whose files are unchunked. So
        # the question goes to the file: this one counts, {LazyFile} was told.
        #
        # @return [Integer]
        def rendered_lines = hunks.sum { |hunk| hunk.lines.size + 1 }

        # Always, for {#rendered_lines}' reason: a parser has already produced
        # these hunks, so there is no moment at which one of these files is
        # unread. {LazyFile} is the kind that has one, and the question goes to
        # the file so nothing above has to ask which kind it is holding.
        #
        # @return [Boolean]
        def chunked? = true
      end

      Identity = Data.define(:scheme, :parts) do
        def initialize(scheme:, parts:)
          super(scheme: -scheme.to_s, parts: parts.map { |part| -part.to_s }.freeze)
        end
      end

      # What a source answers when asked what changeset it is, for addressing --
      # ONE message and one value, not two. A scheme and its parts travel
      # together and are consumed together (`Keying.digest(scheme, parts)`), so
      # two messages would be a data clump the single call site had to re-join.
      # Carrying them as one value is also what lets a source name its OWN
      # scheme: a corpus reviewed as it stands is not a diff, and an address that
      # claimed otherwise would be forgeable across the two.
      #
      # Deeply frozen, {Event}'s rule and reason: an address already journalled
      # must not be editable under the session that wrote it. `-part.to_s` is
      # what makes that true of the members as well as the tuple -- string
      # interpolation returns a MUTABLE String, and one of those anywhere in the
      # array is enough for `Ractor.shareable?` to answer false.
      class Identity
        # @return [String] `<scheme>:<hex>`, the address itself
        def digest = Keying.digest(scheme, parts)
      end

      # What a source that HAS a unified diff gets for free: the model values
      # under it, and the address they compose.
      #
      # INCLUDED by each diff source rather than delegated from one to the other,
      # and that is the point. {GithubPr#diff} has two producers and the
      # API-served bytes never reach {LocalBranch}, so a `#files` delegated the
      # way `#commits` is would parse a locally regenerated diff instead of the
      # bytes actually served -- silently, and only on the leg nobody observes.
      module Diffed
        # Hashed, never merely prefixed -- {Hunk#key}'s lesson, for the same
        # forgery reason, and this address IS journaled.
        DIGEST_SCHEME = "review-changeset-v1"

        # @return [Array<ChangedFile>] in the diff's own (path-sorted) order
        def files = @files ||= Parser.new(diff).files.freeze

        # Both, and HERE for {#files}' reason: having a diff IS having two
        # revisions. It does not move with the files -- a diff whose only file is
        # an addition is still a round with an old side, and collapsing the two is
        # exactly the guess this message exists to remove.
        #
        # @return [Array<String>] {BOTH_SIDES}
        def sides = BOTH_SIDES

        # The changeset's content address: base, paths, statuses and hunk keys --
        # and deliberately NOT the head. The head moves every time the author
        # commits, and surviving that is the entire purpose of {Hunk}'s
        # content-addressed keys; an address including it would open a new round
        # on every amend and throw away every mark. The BASE is in it because
        # {Marks} refuses to cross one at all. Statuses and paths are in it so a
        # change no hunk can express -- a pure rename, a mode change, a binary
        # blob swapped -- still moves the address.
        #
        # WHICH parts, in which order, is all this decides; how they are framed
        # and how the scheme is bound to them belong to {Review::Keying}.
        #
        # @return [Identity]
        def identity = @identity ||= Identity.new(scheme: DIGEST_SCHEME, parts: identity_parts)

        # One line of {#file_at}'s answer, cut by {Anchor.lines}' rule -- what a
        # note's evidence is read from. {Corpus#line_at} answers the same
        # question, and cannot be this: its whole-file answer is projected, and a
        # projection's line numbers are not the file's.
        #
        # @param revision [String] {#base_ref} or {#head_ref}
        # @param path [String] the path as that revision names it
        # @param number [Integer] 1-based
        # @return [String, nil] the line's raw bytes; nil when the revision holds
        #   no such path or no such line
        def line_at(revision, path, number)
          bytes = file_at(revision, path)
          Anchor.lines(bytes)[number - 1] unless bytes.nil?
        end

        private

        # `group_by(&:path)` then `Hunk.keys` over one file's hunks at a time --
        # the batch is a precondition of the key scheme rather than a
        # convenience, since {Hunk.keys} cannot decide its duplicate fallback one
        # hunk at a time. The same rule {Session::MarkedChangeset.keys_by_path}
        # applies to the same hunks, and `session_spec.rb` pins the two equal
        # THROUGH the digest, because a session addressing a changeset by keys
        # the marks do not recognise would unmark everything.
        def identity_parts
          keys = files.flat_map(&:hunks).group_by(&:path).transform_values { |hunks| Hunk.keys(hunks) }
          [base_ref,
           *files.flat_map { |file| [file.path, file.status.to_s, *keys.fetch(file.path, [])] }]
        end
      end

      # The unified-diff reader, promoted from `spike/review-probe/diff_map.rb`.
      #
      # The one structural change from the spike: head and body are split at the
      # file's FIRST `@@`, and the predicates run only over the body. The spike
      # walked the whole diff in one pass, so it had to guard `addition?` against
      # `+++` and `deletion?` against `---`; with the split that guard is actively
      # WRONG, because a deleted line that itself begins with `--` is content and
      # would be miscounted as a file header. There is a spec.
      class Parser
        HUNK = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)\z/
        SECTION = /^(?=diff --git )/

        # @param diff [String] raw diff bytes
        def initialize(diff)
          @diff = diff
        end

        # @return [Array<ChangedFile>]
        def files = sections.map { |section| changed_file(section) }

        private

        # A body line always carries an origin marker (` `, `+`, `-`, `\`), so no
        # content line can be mistaken for the `diff --git` that starts the next
        # file's section.
        def sections = @diff.split(SECTION).grep(/\Adiff --git /)

        def changed_file(section)
          # `delete_suffix` and not `chomp`: a body line may legitimately END in a
          # carriage return (a CRLF file's content), and `chomp` would eat it.
          lines = section.each_line.map { |line| line.delete_suffix("\n") }
          split = lines.index { |line| HUNK.match?(line) }
          head = split ? lines[0...split] : lines
          old_path, new_path = sided_paths(head)
          ChangedFile.new(old_path:, new_path:, binary: binary?(head),
                          hunks: hunks(new_path || old_path, split ? lines[split..] : []))
        end

        # `new file mode` / `deleted file mode` are applied after the paths are
        # read rather than instead of them: a binary addition names its path only
        # in the `diff --git` header, where both sides are spelled regardless.
        def sided_paths(head)
          old_path, new_path = marker_paths(head) || rename_paths(head) || header_paths(head.first)
          [head.any? { |line| line.start_with?("new file mode") } ? nil : old_path,
           head.any? { |line| line.start_with?("deleted file mode") } ? nil : new_path]
        end

        def binary?(head) = head.any? { |line| line.start_with?("Binary files ", "GIT binary patch") }

        # Present whenever the file has hunks, and unambiguous where the header is
        # not: one path per line, `/dev/null` for the side that does not exist.
        def marker_paths(head)
          old = head.find { |line| line.start_with?("--- ") }
          new = head.find { |line| line.start_with?("+++ ") }
          return nil unless old && new

          [marker_path(old.delete_prefix("--- "), "a/"), marker_path(new.delete_prefix("+++ "), "b/")]
        end

        # git terminates the name with a TAB when it carries a space, so the tab
        # is a delimiter and never part of the name -- a path containing a real
        # tab is C-quoted instead, which is why stripping here is safe.
        #
        # Anything that is not `a/…`/`b/…` is the side not existing: git spells
        # that `/dev/null`, and reading it as "no prefix, no path" rather than
        # matching the token means an added file is recognised the same way
        # whatever a non-git source spells its absent side.
        def marker_path(field, prefix)
          named = unquote(field.sub(/\t.*\z/, ""))
          named.start_with?(prefix) ? path_text(named.delete_prefix(prefix)) : nil
        end

        def rename_paths(head)
          from = head.find { |line| line.start_with?("rename from ") }
          to = head.find { |line| line.start_with?("rename to ") }
          return nil unless from && to

          [path_text(unquote(from.delete_prefix("rename from "))),
           path_text(unquote(to.delete_prefix("rename to ")))]
        end

        # The last resort, and it is reached only by a file with neither hunks nor
        # rename lines -- a binary change or a mode-only one -- both of which carry
        # the SAME path on each side. That is what makes the split point arithmetic
        # rather than a guess: `<A> <B>` with `|A| == |B|` fixes it, quoted or not.
        def header_paths(header)
          rest = header.to_s.delete_prefix("diff --git ")
          half = (rest.bytesize - 1) / 2
          pair = [rest.byteslice(0, half).to_s, rest.byteslice(half + 1, half).to_s]
          return even_header_paths(pair) if rest.byteslice(half) == " " && even_header?(pair)

          loose_header_paths(rest)
        end

        def even_header?((old, new)) = unquote(old).start_with?("a/") && unquote(new).start_with?("b/")

        def even_header_paths((old, new))
          [path_text(unquote(old).delete_prefix("a/")), path_text(unquote(new).delete_prefix("b/"))]
        end

        def loose_header_paths(rest)
          loose = rest.match(%r{\Aa/(.+) b/(.+)\z})
          raise Unparseable, "no a/ and b/ paths in diff header #{rest.inspect}" unless loose

          [path_text(loose[1]), path_text(loose[2])]
        end

        # `slice_before` rather than an index walk: every chunk begins with its own
        # `@@` header, and the body was cut at the first one, so no chunk can be
        # headerless.
        def hunks(path, body)
          body.slice_before { |line| HUNK.match?(line) }.map { |chunk| hunk(path, chunk) }
        end

        def hunk(path, (header, *lines))
          span = HUNK.match(header)
          Hunk.new(path:, lines:, old_start: span[1].to_i, old_count: (span[2] || 1).to_i,
                   new_start: span[3].to_i, new_count: (span[4] || 1).to_i,
                   heading: path_text(span[5].to_s.delete_prefix(" ")))
        end

        # SCRUBBED, unlike an anchor's text: a path is journalled as JSON and is
        # joined against the numstat paths this port already scrubbed, so bytes
        # that cannot survive either would break the join and the record both. A
        # hunk heading gets the same treatment -- display text, never evidence.
        #
        # The trade, and what it costs: a filename whose bytes are not valid
        # UTF-8 is legal on this filesystem and git does NOT quote it
        # (`core.quotePath` governs non-ASCII, not invalid), so `bad\xFF.rb`
        # leaves here as `bad<U+FFFD>.rb`. That name is journallable and it still
        # JOINS ({LocalBranch#text} scrubs identically), but it is NOT a name any
        # caller can open, so {Anchor#drifted?} and file-opening cannot reach that
        # one file.
        #
        # The journal won on purpose: the alternative is a BINARY String reaching
        # `JSON.generate`, which raises, into the NDJSON Journal where one bad
        # line breaks the parse of the whole experiment record. The fix, when
        # something needs it, is to carry the raw bytes BESIDE the scrubbed name
        # rather than instead of it.
        def path_text(bytes) = -bytes.dup.force_encoding(Encoding::UTF_8).scrub

        # {Wire.unquote}, never a private copy. {LocalBranch} decodes the NUMSTAT
        # side with the same function and {Partition::ByCommit} joins the two by
        # name; two decoders is precisely how those two names drift apart, which
        # they did.
        def unquote(field) = Wire.unquote(field)
      end

      # Where a chat's `implementation` review reads its diff from: this
      # repository, at whatever base the model named, against the working tree's
      # own head. The `changesets:` seam {Tools::RequestReview} takes, and the
      # only implementation of it -- until this existed, every `implementation`
      # call in every real process refused with `no_changeset`.
      #
      # A FACTORY and not a source, because `base` is the model's argument and
      # arrives per call: {LocalBranch} resolves its refs in its constructor and
      # refuses an unresolvable one there, so one built at wiring time would have
      # to guess a base -- the guess that tool's `base` field exists to refuse.
      #
      # `source` and not `call`, deliberately: {Tools::RequestReview#live} treats
      # anything answering `call` as a thunk read with no arguments.
      class Repository
        # @param repo_root [String] the repository every git call reads
        def initialize(repo_root: Dir.pwd)
          @repo_root = repo_root
        end

        # @param base [String] the ref the changeset is reviewed against
        # @param head [String] the ref under review
        # @return [LocalBranch]
        # @raise [UnknownRef] for a ref that does not resolve, or two that share
        #   no history -- which {Tools::RequestReview::Implementation#hold}
        #   answers as a refusal rather than letting out of the tool
        def source(base:, head:) = LocalBranch.new(base:, head:, repo_root: @repo_root)
      end
    end
  end
end
