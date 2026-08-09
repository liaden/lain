# frozen_string_literal: true

module Lain
  module Review
    # A changeset is files -> hunks -> anchorable lines, read from a {Source} and
    # from nothing else. The parser is `spike/review-probe/diff_map.rb` promoted:
    # a unified diff is a line-oriented state machine with two counters, one per
    # side, and the three predicates below are what keep both honest.
    #
    # == Nothing is parsed until something is asked for
    #
    # Every answer memoizes on first demand, and {#each_anchor} without a block
    # returns an {Enumerator} that has not read the source's diff yet. A work-scale
    # changeset is 80,800 rendered lines (research §3.7); materializing an Anchor
    # per line for a caller that wanted the first screenful is the cost this shape
    # exists to avoid.
    #
    # == The diff is a TWO-TREE diff, so no hunk ever has two old sides
    #
    # A merge commit shows up in the WALK ({#by_commit}), never in the diff's
    # shape: {Source::LocalBranch#diff} is `git diff <base> <head>`, and git emits
    # a combined diff (`@@@ -1,8 -1,8 +1,8 @@@`, two old sides, which {Hunk}'s
    # single `(old_start, old_count)` cannot represent) only for a commit against
    # its own parents. T3 already closed the other half of the same gap, by
    # passing `--diff-merges=first-parent` so a file changed only by a hand
    # resolution reaches some commit's numstat. There is a spec for both.
    #
    # == Where the marks-derived tri-state is NOT
    #
    # A {ChangedFile} answers {ChangedFile#status} -- the diff's own fact -- and
    # deliberately not `#state`, which is what T9's `Surface::Text` reads as the
    # marks-derived tri-state. This object cannot know that; joining the two is
    # the session's (T13), and putting both meanings on one message name is how
    # a table renders the wrong glyph without anything failing.
    class Changeset
      # A file in the diff that no commit's numstat accounts for. Refused rather
      # than dropped or given an invented owner: silently skipping it loses every
      # anchor under it without saying so, and {Source}'s own contract
      # ("names every file the diff touches in some commit's numstat") says it
      # cannot happen -- so when it does, the source is wrong and must say so.
      class Unattributed < Error; end

      # A file section whose header names no `a/`+`b/` pair at all. `diff.noprefix`
      # is the realistic cause and {Source::LocalBranch::DIFF_HYGIENE} pins it off,
      # so reaching this means the bytes did not come from a source that pinned it.
      class Unparseable < Error; end

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
      # carries and what a mark is keyed under. The side-specific paths are what an
      # ANCHOR needs: an old-side anchor on a renamed file resolves against
      # `git show <base>:<old_path>`, and naming the new path there would resolve
      # nothing while still looking like a well-formed anchor.
      #
      # A binary file, a mode-only change and a pure rename each carry zero hunks.
      # They are still files here, because dropping them would lose the fact that
      # they changed.
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
      end

      # One commit's slice of the changeset -- and, deliberately, a VIEW that
      # cannot be mistaken for the whole one.
      #
      # It answers neither `#hunks` nor `#base_ref`, which are exactly the two
      # messages `Marks#reconcile` reads. That is what makes handing a FILTERED
      # changeset to the pruner impossible rather than merely discouraged: the
      # reconciler drops every key the changeset it is given does not produce, so
      # a filtered one silently prunes the marks on everything the filter hid.
      # tuicr#247 closed that with a `preserve_hunks` flag whose own comment admits
      # the default path still reaches the bug; a flag on the wrong side of the
      # call is the special case, and the missing message is the fix. The hunk
      # count is still reachable the honest way, through {#files}.
      #
      # `numstat` is the commit's OWN, unpartitioned figure (T14's sidebar renders
      # it), while `files` is this commit's share of the cumulative diff -- see
      # {Changeset#by_commit} for why those two are not the same set.
      CommitScope = Data.define(:sha, :subject, :body, :numstat, :files)

      include Enumerable

      # @param source [#diff, #commits, #base_ref, #head_ref] a {Review::Source}
      def initialize(source:)
        @source = source
      end

      # @return [String] the resolved merge base every old-side anchor rests on
      def base_ref = @source.base_ref

      # @return [String] the resolved head every new-side anchor rests on
      def head_ref = @source.head_ref

      # The source's walk, oldest first, forwarded because a {Partition::Strategy}
      # takes a CHANGESET and never a source -- {Partition::ByCommit} needs the
      # walk to attribute a file, and a strategy holding a source would be the
      # seam in the wrong place (a strategy would then need a repository to be
      # testable at all).
      #
      # @return [Array<Source::Commit>]
      def commits = @source.commits

      # @return [Array<ChangedFile>] in the diff's own (path-sorted) order
      def files = @files ||= Parser.new(@source.diff).files.freeze

      # Every hunk in the WHOLE changeset, flat and unfiltered -- what
      # `Marks#reconcile` prunes against, and what `Hunk.keys` needs a whole
      # file's worth of at once to decide its duplicate fallback.
      #
      # @return [Array<Hunk>]
      def hunks = @hunks ||= files.flat_map(&:hunks).freeze

      # One file, by the path that IDENTIFIES it -- {ChangedFile#path}, which is
      # the new path wherever there is one. Indexed rather than scanned because
      # the caller is a human's keystroke and §3.7 measured a real changeset at
      # 810 files.
      #
      # @param path [String]
      # @return [ChangedFile, nil] nil when this changeset carries no such file,
      #   which is a real answer rather than an error: a gesture can name a row
      #   drawn from a changeset that has since been replaced
      def file(path) = by_path[path.to_s]

      # The file as the BASE held it, line by line -- what an editor draws
      # opposite the working copy, and the one question a diff cannot answer for
      # itself (it carries the hunks and three lines around them, never the whole
      # side).
      #
      # Read against the file's OLD path, which is the whole reason this is a
      # method here rather than a `file_at` call at the caller: a renamed file's
      # old side lives at `base_ref:old_path`, and naming the new path there
      # resolves nothing while still looking like a well-formed request.
      #
      # Split on newlines and NOT chomped, because the carriage return is
      # somebody else's decision: whoever displays this is diffing it against a
      # working copy whose line endings the editor has already read, and a
      # changeset that genuinely CONVERTED a file's endings must show that rather
      # than have it quietly stripped here.
      #
      # @param file [ChangedFile] one of {#files}
      # @return [Array<String>, nil] the lines; `[]` for a file this changeset
      #   ADDS, which has an empty old side rather than no old side; nil when the
      #   base does not carry the path at all, which is a repository that cannot
      #   answer for its own diff
      def old_side(file)
        return [] if file.old_path.nil?

        bytes = @source.file_at(base_ref, file.old_path)
        lines(bytes) unless bytes.nil?
      end

      # @return [Enumerator] over {#files}, which is what makes this Enumerable.
      #   Blockless, it parses nothing -- the same promise {#each_anchor} makes,
      #   and worth making twice: a caller holding an `Enumerable` cannot tell
      #   which of the two it has, so one lazy and one eager is worse than either
      #   being consistent. The size block is called only if `#size` is asked.
      def each(&block)
        return enum_for(:each) { files.size } unless block

        files.each(&block)
      end

      # The commit walk, one {CommitScope} per commit in the source's walk --
      # including a commit whose every file was later superseded, which gets an
      # empty `files` rather than disappearing from the sidebar.
      #
      # The files are PARTITIONED, not replicated: a file two commits touched
      # appears under the LAST of them, because the cumulative diff shows its
      # hunks once and the last commit is the one that left the content now on
      # screen. Handing it to both would double-count, and the acceptance
      # criterion this card is written against ("groups whose hunks sum to the
      # cumulative hunk count") is precisely that conservation law.
      #
      # Attribution is at FILE granularity because that is the finest the port
      # answers: {Source::Commit} carries a numstat, not a per-commit diff. Real
      # hunk-level provenance would need a fifth message on the port.
      #
      # == What a consumer may and may not claim about a scope
      #
      # A scope means "this commit is the LAST in the range to touch these files,
      # and here are their net hunks". It does not mean "this commit did this",
      # and one case makes the difference stark rather than academic: with a
      # merge in the range, `--diff-merges=first-parent` re-reports everything
      # the merge brought in, so the merge's numstat names the side branch's
      # files too and last-writer-wins hands them ALL to the merge. The commit
      # that actually authored a side-branch file then shows an EMPTY scope.
      #
      # Empty scopes for an empty commit or an add-then-delete pair are honest.
      # An empty scope for real work absorbed by a merge is not, and it cannot be
      # fixed from inside this object: telling a merge from an ordinary commit
      # needs a parent count, and {Source::Commit} carries sha, subject, body and
      # numstat with no parents. That is a port change. Until then {CommitScope}
      # keeps `numstat` -- the commit's OWN figure, which a merge does not steal
      # -- so a sidebar that needs "what did this commit do" has something true
      # to read. There is a spec pinning the behaviour, not endorsing it.
      #
      # @return [Array<CommitScope>]
      # @raise [Unattributed] if a file in the diff reaches no commit
      def by_commit = @by_commit ||= scopes.freeze

      # Every anchorable line of the changeset, on ONE side, in diff order.
      #
      # One side per walk rather than a `both` for context lines: {Review::SIDES}
      # is closed at two, a context line is a real position on each of them, and
      # a caller placing an annotation knows which side its cursor is on. Calling
      # it twice is how you get every position.
      #
      # @param side [Symbol, String] `:new` (additions and context, against
      #   {#head_ref}) or `:old` (deletions and context, against {#base_ref})
      # @return [Enumerator<Anchor>] when no block is given, having parsed nothing
      # @raise [Anchor::UnknownSide] for anything else, before any parsing
      def each_anchor(side: :new, &block)
        side = Anchor.side!(side)
        return enum_for(:each_anchor, side:) { anchor_count(side) } unless block

        files.each { |file| file.hunks.each { |hunk| walk(file, hunk, side, &block) } }
      end

      private

      # A file two paths could somehow collide on keeps the FIRST, matching the
      # diff's own order -- `to_h` would keep the last, and a changeset naming a
      # path twice is a defect nobody should have their gesture resolved by.
      def by_path = @by_path ||= files.reverse.to_h { |file| [file.path, file] }.freeze

      # One buffer line per line the base held. A trailing newline TERMINATES the
      # last line rather than starting an empty one, which is how an editor reads
      # the same file -- `split("\n", -1)` alone would append a phantom line to
      # every well-formed file and report the whole side as changed.
      #
      # `delete_suffix`, never `chomp("\n")`: chomp treats that argument as the
      # RECORD separator and strips a trailing "\r\n" whole, so a CRLF file would
      # lose the one carriage return this method promises not to touch -- and
      # only that one, which is a last line that differs from every line above it.
      def lines(bytes) = bytes.delete_suffix("\n").split("\n", -1).freeze

      # The Enumerator's size block, and the reason there is one: with no block
      # at all `#size` answers `nil`, which a reader takes for "empty". A size
      # block is invoked only WHEN asked, so this parses on `#size` and merely
      # holding the enumerator still parses nothing.
      def anchor_count(side)
        hunks.sum do |hunk|
          hunk.lines.count { |raw| side == :old ? old_side?(raw) : new_side?(raw) }
        end
      end

      # The spike's own shape: a pure fold carrying the two counters, yielding
      # where the requested side has a position. A context line advances BOTH,
      # which is the only reason one pass can carry two numbers.
      def walk(file, hunk, side)
        hunk.lines.inject([hunk.old_start, hunk.new_start]) do |(old, new), raw|
          anchor = anchor_at(file, raw, side, old:, new:)
          yield(anchor) if anchor
          [old + (old_side?(raw) ? 1 : 0), new + (new_side?(raw) ? 1 : 0)]
        end
      end

      def anchor_at(file, raw, side, old:, new:)
        return nil unless side == :old ? old_side?(raw) : new_side?(raw)

        path, line, revision = side == :old ? [file.old_path, old, base_ref] : [file.new_path, new, head_ref]
        Anchor.new(path:, side:, line:, revision:, anchor_text: evidence(raw))
      end

      # `\ No newline at end of file` is neither side and moves neither counter.
      # An entirely EMPTY line reads as context: git spells one as a bare `" "`,
      # but a diff that reached us through anything that trims trailing whitespace
      # would otherwise stall both counters and shift every anchor below it.
      def context?(line) = line.start_with?(" ") || line.empty?

      def addition?(line) = line.start_with?("+")

      def deletion?(line) = line.start_with?("-")

      def old_side?(line) = context?(line) || deletion?(line)

      def new_side?(line) = context?(line) || addition?(line)

      # EVIDENCE, so decoded but never scrubbed: `anchor_text` is compared byte
      # for byte against the line the file now holds, and substituting U+FFFD for
      # a latin-1 source file's bytes would report drift on a line nobody touched.
      # A path is the opposite case and is scrubbed -- see {Parser#path_text}.
      def evidence(line) = line.byteslice(1..).to_s.dup.force_encoding(Encoding::UTF_8)

      def scopes
        grouped = files.group_by { |file| owner_of(file) }
        @source.commits.map do |commit|
          CommitScope.new(sha: commit.sha, subject: commit.subject, body: commit.body,
                          numstat: commit.numstat, files: (grouped[commit.sha] || []).freeze)
        end
      end

      # The new path first: for a rename, that is the commit that performed it,
      # while the old path would name whoever last touched the file beforehand.
      def owner_of(file)
        ownership[file.new_path] || ownership[file.old_path] ||
          raise(Unattributed,
                "#{file.path.inspect} is in the diff but in no commit's numstat, so grouping it " \
                "by commit would either drop the file or invent an owner for it")
      end

      # name => the LAST commit in the walk that named it. Oldest-first order is
      # the source's contract, so a later write is a later commit.
      def ownership
        @ownership ||= @source.commits.each_with_object({}) do |commit, owner|
          commit.numstat.each do |entry|
            rename_sides(entry.path).each { |name| owner[name] = commit.sha }
          end
        end
      end

      # A rename reaches a numstat path as `old => new` or `pre/{old => new}/post`,
      # and BOTH sides count as named -- the cumulative diff may have detected the
      # rename where a single commit did not, or the reverse.
      def rename_sides(path)
        braced = path.match(/\A(?<pre>.*)\{(?<old>.*) => (?<new>.*)\}(?<post>.*)\z/m)
        return %i[old new].map { |side| "#{braced[:pre]}#{braced[side]}#{braced[:post]}" } if braced

        arrow = path.match(/\A(?<old>.*) => (?<new>.*)\z/m)
        arrow ? [arrow[:old], arrow[:new]] : [path]
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
        # joined against the numstat paths {Source} already scrubbed, so bytes that
        # cannot survive either would break the join and the record both. A hunk
        # heading gets the same treatment for the same reason -- it is display
        # text, never evidence.
        #
        # == The trade this makes, and what it costs
        #
        # A filename whose bytes are not valid UTF-8 is legal on this filesystem
        # and git does NOT quote it (`core.quotePath` governs non-ASCII, not
        # invalid), so `bad\xFF.rb` arrives as those bytes and leaves here as
        # `bad<U+FFFD>.rb`. That name is journallable, and it still JOINS --
        # {Source} scrubs identically, which is the half `by_commit` needs -- but
        # it is NOT a name any caller can open. `File.read` will not find it, so
        # {Anchor#drifted?} and T15's file-opening cannot reach that one file.
        #
        # The journal won on purpose: the alternative is a BINARY String reaching
        # `JSON.generate`, which raises, into the NDJSON Journal where one bad
        # line breaks the parse of the whole experiment record. The fix, when
        # something needs it, is to carry the raw bytes BESIDE the scrubbed name
        # rather than instead of it. Nothing does yet -- and pretending the cost
        # is zero is how it would go unnoticed when something does.
        def path_text(bytes) = -bytes.dup.force_encoding(Encoding::UTF_8).scrub

        # {Wire.unquote}, never a private copy. {Source::LocalBranch} decodes the
        # NUMSTAT side with the same function and {#by_commit} joins the two by
        # name; two decoders is precisely how those two names drift apart, which
        # they did.
        def unquote(field) = Wire.unquote(field)
      end
    end
  end
end
