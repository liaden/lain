# frozen_string_literal: true

module Lain
  module Review
    # The changeset-source port: where a reviewable changeset comes from.
    #
    # A source answers SIX messages, and the shared example group
    # `"a review changeset source"` (spec/support/shared_examples/review_source.rb)
    # is the contract, not this comment:
    #
    #   #files        the changed files, as model values -- {ChangedFile}s
    #   #identity     the {Identity} an address is computed from
    #   #base_ref     what every old-side anchor rests on
    #   #head_ref     what every new-side anchor rests on
    #   #file_at      one path, as one revision holds it
    #   #diff_origin  where the bytes came from, and whether anything fell back
    #
    # {LocalBranch#diff} and {LocalBranch#commits} are NOT on that list. They
    # belong to sources that have unified-diff bytes and a commit walk, which is
    # a real category and not the port -- see "Not every source has two
    # witnesses" below. A local branch and a GitHub pull request are today's two
    # implementations, and everything downstream -- the anchors, the marks, the
    # session's address -- reads only the six, so none of them knows which it
    # has. That last clause is the whole design, and it used to be false: an
    # earlier edition of this list said "answers six... reads only these five",
    # which was a miscount in both halves.
    #
    # The one downstream reader that needs the walk is {Partition::ByCommit},
    # through {Changeset#commits}. It is also the one a source without a walk
    # collides with, which is why a strategy answers `#supports?(source)` rather
    # than being assumed to apply: the refusal names the strategy and what the
    # source lacks, instead of a `NoMethodError` from inside a grouping.
    #
    # == The port hands down MODEL VALUES, not bytes
    #
    # {Changeset} used to hold a source's diff and parse it. That made "a source"
    # mean "a thing with unified-diff bytes in it", so a source with no diff --
    # a corpus of files reviewed as they stand -- could not exist without
    # synthesizing bytes for the changeset to take apart again. So {Parser},
    # {ChangedFile} and {Unparseable} live HERE, with the sources that have bytes
    # to parse, and {Diffed} is the two lines of shape that turns bytes into the
    # values the port owes.
    #
    # {Identity} is the same move for the ADDRESS. `Session.digest` used to
    # compose the parts itself, which meant one method knew what every kind of
    # source was made of; now the object that HAS the parts supplies them, and
    # there is no type test anywhere above.
    #
    # == Not every source has two witnesses
    #
    # The port's laws split in two, and the split is forced rather than
    # convenient. Assertions about shape, and about a source agreeing with its
    # OWN other answers, hold for anything: a source may not name a SIDE its own
    # {LocalBranch#file_at} cannot read. But the reversed-diff and
    # binary-agreement cross-checks hold {LocalBranch#diff} against
    # {LocalBranch#commits} -- two witnesses -- and a source with only one cannot
    # satisfy them however correct it is. Those live in
    # `"a diff-bearing review changeset source"`, which diff sources include and
    # which runs the universal group itself.
    #
    # The two messages themselves went with them, and that correction is worth
    # recording: a law calling `#diff` on a source that has none does not fail
    # as a shape violation, it raises `NoMethodError` -- so leaving it universal
    # would have been the port still demanding bytes while its own doc promised
    # otherwise. It was not hypothetical; a corpus-shaped source was built and
    # failed exactly those two examples and nothing else.
    #
    # == {LocalBranch#file_at}, and why a diff is not enough
    #
    # It is the one message about a single PATH rather than
    # about the whole changeset, and it is here because a unified diff cannot be
    # DRAWN from. An editor showing the old side beside the new needs the whole
    # old file; a diff carries the hunks and three lines around them. Every
    # consumer of that is a renderer, so the read belongs to the source that
    # already knows where the bytes live rather than to a renderer that would
    # have to be handed a repository to find out.
    #
    # == {DiffOrigin}, and why it is on the PORT
    #
    # It began as {GithubPr}'s alone, and its first consumer ({CLI::Review})
    # therefore asked `respond_to?(:diff_origin)` -- a type test in duck costume,
    # and the one place a consumer branched on WHICH source it was handed. The
    # answer is not a defter conditional: it is that a source which never asks an
    # API still has an answer to "where did these bytes come from", and
    # {LocalBranch} gives it. The conditional is gone, and with it a live defect
    # -- the guard was tested on one leg only, and an ordinary pull request
    # rendered a fallback note with an empty reason.
    #
    # == Refusals here are RAISED, unlike {Forge::Gh}'s
    #
    # Gh's doctrine is that a refusal is a VALUE, because a landing folds over
    # answers and journals them. This port is not that: a ref that does not
    # resolve is the caller naming something that does not exist, which is Gh's
    # OWN distinction on the other side of the line -- "gh answering no is data,
    # gh not existing is a broken machine". There is no review to be had and no
    # fold to carry a not-ok answer, so {UnknownRef} raises.
    module Source
      # A ref the source was built against does not resolve, or two refs share no
      # history so there is no merge base to anchor the old side to. Named per
      # the error-taxonomy convention: a refusal subclasses {Lain::Error} next to
      # the owner that raises it.
      class UnknownRef < Error
        def self.unresolved(role, ref, repo_root, shell)
          new("#{role} ref #{ref.inspect} does not resolve to a commit " \
              "in #{repo_root}#{because(shell)}")
        end

        def self.no_merge_base(base, head, repo_root)
          new("#{base.inspect} and #{head.inspect} share no merge base " \
              "in #{repo_root}, so there is no revision to anchor the old side to")
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
      # paraphrase of them.
      #
      # On the PORT rather than under {GithubPr}, where it was first written --
      # see the module doc for what asking one source and not the other cost.
      DiffOrigin = Data.define(:origin, :reason, :message, :fell_back) do
        # The object database could answer, so no API was ever asked. Both
        # sources reach it: {GithubPr} when the head was already fetched (or an
        # earlier message fetched it), and {LocalBranch} always -- a branch
        # review has no API in it at all, and "the objects are here and nobody
        # was asked" is the same fact for both.
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
      # == Where the marks-derived tri-state is NOT
      #
      # This answers {#status} -- the diff's own fact -- and deliberately not
      # `#state`, which is what {Surface::Text} reads as the marks-derived
      # tri-state. A file value cannot know that; joining the two is the
      # session's, and putting both meanings on one message name is how a table
      # renders the wrong glyph without anything failing.
      #
      # Reopened rather than folded into the `Data.define` block, {Anchor}'s
      # reason exactly: {STATUSES} written inside that block would scope to
      # `Lain::Review` and `#status` would not find it, because `class_eval`
      # resolves a constant against the block's own lexical scope and not against
      # the class it is evaluated on. The docstring lives HERE for the second
      # half of the same rule -- YARD keeps one per namespace and discards the
      # rest.
      class ChangedFile
        # The Symbol projection of {Review::FILE_STATUSES}, keyed by the String
        # spelling that declares it. `Anchor::SIDES`' shape, with one difference
        # that is the point of it: this projection is read by PRODUCTION code.
        # The first cut declared the vocabulary and then never referenced it --
        # `#status` restated four Symbol literals and a spec held the two lists
        # equal, which is a shared vocabulary in name only.
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
        # body plus its `@@` header, and never the four-line `diff --git` /
        # `index` / `---` / `+++` preamble, which is a constant per file and is
        # what the file ceiling already governs.
        #
        # On the FILE because a bound must be able to size a view without
        # chunking it. {Bounds} used to sum `file.hunks` itself, which is free
        # here -- these hunks are the ones the parser already produced -- and is
        # the whole corpus for a source whose files have not been chunked yet.
        # So the question goes to the file, and each kind answers from what it
        # already knows: this one counts, {LazyFile} was told.
        #
        # @return [Integer]
        def rendered_lines = hunks.sum { |hunk| hunk.lines.size + 1 }
      end

      Identity = Data.define(:scheme, :parts) do
        def initialize(scheme:, parts:)
          super(scheme: -scheme.to_s, parts: parts.map { |part| -part.to_s }.freeze)
        end
      end

      # What a source answers when asked what changeset it is, for addressing
      # purposes -- ONE message and one value, not two.
      #
      # A scheme and its parts travel together and are consumed together
      # (`Keying.digest(scheme, parts)`), so two messages would be a data clump
      # that the single call site had to re-join. Carrying them as one value is
      # also what lets a source name its OWN scheme: a corpus reviewed as it
      # stands is not a diff, and an address that claimed otherwise would be
      # forgeable across the two.
      #
      # Deeply frozen, {Event}'s rule and for {Event}'s reason: this is what an
      # address is computed from, and an address already journalled must not be
      # editable under the session that wrote it. `-part.to_s` is what makes that
      # true for the members as well as the tuple -- string interpolation returns
      # a MUTABLE String, and one of those anywhere in the array is enough for
      # `Ractor.shareable?` to answer false.
      class Identity
        # @return [String] `<scheme>:<hex>`, the address itself
        def digest = Keying.digest(scheme, parts)
      end

      # What a source that HAS a unified diff gets for free: the model values
      # under it, and the address they compose.
      #
      # INCLUDED by each diff source rather than delegated from one to the other,
      # and that is the point rather than a detail. {GithubPr#diff} has two
      # producers and the API-served bytes never reach {LocalBranch}, so a
      # `#files` delegated the way `#commits` is would parse a locally
      # regenerated diff instead of the bytes actually served -- silently, and
      # only on the leg nobody has observed. Reading `diff`, the includer's own
      # message, makes that structural rather than a rule to remember.
      module Diffed
        # Hashed, never merely prefixed -- {Hunk#key}'s lesson, for the same
        # forgery reason, and this address IS journaled.
        DIGEST_SCHEME = "review-changeset-v1"

        # @return [Array<ChangedFile>] in the diff's own (path-sorted) order
        def files = @files ||= Parser.new(diff).files.freeze

        # The changeset's content address: base, paths, statuses and hunk keys --
        # and deliberately NOT the head.
        #
        # The head moves every time the author commits, and surviving that is the
        # entire purpose of {Hunk}'s content-addressed keys; an address that
        # included it would open a new round on every amend and throw away every
        # mark. The BASE is in it because {Marks} refuses to cross one at all, so
        # a base change is genuinely a different review.
        #
        # Statuses and paths are in it so a change no hunk can express -- a pure
        # rename, a mode change, a binary blob swapped -- still moves the address.
        #
        # WHICH parts, in which order, is all this decides. How they are framed
        # and how the scheme is bound to them belong to {Review::Keying}, where
        # both properties have specs of their own rather than a comment here
        # claiming them.
        #
        # @return [Identity]
        def identity = @identity ||= Identity.new(scheme: DIGEST_SCHEME, parts: identity_parts)

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
        # hunk heading gets the same treatment for the same reason -- it is
        # display text, never evidence.
        #
        # == The trade this makes, and what it costs
        #
        # A filename whose bytes are not valid UTF-8 is legal on this filesystem
        # and git does NOT quote it (`core.quotePath` governs non-ASCII, not
        # invalid), so `bad\xFF.rb` arrives as those bytes and leaves here as
        # `bad<U+FFFD>.rb`. That name is journallable, and it still JOINS --
        # {LocalBranch#text} scrubs identically, which is the half the commit walk
        # needs -- but it is NOT a name any caller can open. `File.read` will not
        # find it, so {Anchor#drifted?} and file-opening cannot reach that one
        # file.
        #
        # The journal won on purpose: the alternative is a BINARY String reaching
        # `JSON.generate`, which raises, into the NDJSON Journal where one bad
        # line breaks the parse of the whole experiment record. The fix, when
        # something needs it, is to carry the raw bytes BESIDE the scrubbed name
        # rather than instead of it. Nothing does yet -- and pretending the cost
        # is zero is how it would go unnoticed when something does.
        def path_text(bytes) = -bytes.dup.force_encoding(Encoding::UTF_8).scrub

        # {Wire.unquote}, never a private copy. {LocalBranch} decodes the NUMSTAT
        # side with the same function and {Partition::ByCommit} joins the two by
        # name; two decoders is precisely how those two names drift apart, which
        # they did.
        def unquote(field) = Wire.unquote(field)
      end

      # Where a chat's `implementation` review reads its diff from: this
      # repository, at whatever base the model named, against the working tree's
      # own head.
      #
      # The `changesets:` seam {Tools::RequestReview} takes, and the only
      # implementation of it in the tree -- {Tools::RequestReview::NoChangesets}
      # is its null, and until this existed that null was the only thing any
      # production wiring passed, so every `implementation` call in every real
      # process refused with `no_changeset`.
      #
      # A FACTORY and not a source, because `base` is the model's argument and
      # arrives per call: {LocalBranch} resolves its refs in its constructor and
      # refuses an unresolvable one there, so one built at wiring time would have
      # to guess a base -- the guess that tool's `base` field exists to refuse.
      #
      # `source` and not `call`, deliberately: {Tools::RequestReview#live} treats
      # anything answering `call` as a thunk to be read with no arguments, so a
      # callable seam here would be invoked as one.
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

# This file is the source/ subtree's index. LocalBranch reads UnknownRef, Commit
# and FileStat from the module above, so it loads AFTER the module body, and
# GithubPr reads LocalBranch's constants, so it loads after LocalBranch.
require_relative "source/local_branch"
require_relative "source/github_pr"
