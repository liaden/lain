# frozen_string_literal: true

module Lain
  module Review
    # A changeset is files -> hunks -> anchorable lines, read from a {Source} and
    # from nothing else. The line walk is two counters, one per side, and the
    # three predicates below are what keep both honest.
    #
    # It reads MODEL VALUES and parses nothing. {#files} is `@source.files`; it
    # used to be `Parser.new(@source.diff).files`, which quietly made "a source"
    # mean "a thing with unified-diff bytes in it", so a source with no diff had
    # to synthesize some for this object to take apart again. There is exactly ONE
    # of this class, parameterised by its source, which is why {#identity}
    # forwards rather than composes: an address that branched here would have to
    # branch on the source's TYPE.
    #
    # NOTHING IS READ UNTIL SOMETHING IS ASKED FOR. Every answer memoizes on first
    # demand, and {#each_anchor} without a block returns an {Enumerator} that has
    # not asked the source for anything. A work-scale changeset is 80,800 rendered
    # lines; materializing an Anchor per line for a caller that wanted the first
    # screenful is the cost this shape avoids.
    #
    # THE DIFF IS A TWO-TREE DIFF, so no hunk ever has two old sides. A merge
    # commit shows up in the WALK ({Partition::ByCommit}), never in the diff's
    # shape: git emits a combined diff (two old sides, which {Hunk}'s single
    # `(old_start, old_count)` cannot represent) only for a commit against its own
    # parents. The other half of that gap is closed by `--diff-merges=first-parent`,
    # so a file changed only by a hand resolution reaches some commit's numstat.
    class Changeset
      # A file in the changeset that no commit's numstat accounts for. Refused
      # rather than dropped or given an invented owner: silently skipping it
      # loses every anchor under it without saying so, and {Source}'s own contract
      # ("names every file the diff touches in some commit's numstat") says it
      # cannot happen -- so when it does, the source is wrong and must say so.
      class Unattributed < Error; end

      include Enumerable

      # @param source [#files, #identity, #base_ref, #head_ref, #file_at] a
      #   {Review::Source}
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

      # The source's own model values, handed down rather than derived: this
      # object has no opinion about how a file came to be a file.
      #
      # @return [Array<Source::ChangedFile>] in the source's own order
      def files = @files ||= @source.files

      # The source's answer to "what changeset is this", forwarded. ONE message
      # carrying both the scheme and the parts, so nothing here assembles an
      # address out of two -- and nothing here asks what kind of source it holds.
      #
      # @return [Source::Identity]
      def identity = @source.identity

      # Every hunk in the WHOLE changeset, flat and unfiltered -- what
      # `Marks#reconcile` prunes against, and what `Hunk.keys` needs a whole
      # file's worth of at once to decide its duplicate fallback.
      #
      # @return [Array<Hunk>]
      def hunks = @hunks ||= files.flat_map(&:hunks).freeze

      # One file, by the path that IDENTIFIES it -- {Source::ChangedFile#path}, which is
      # the new path wherever there is one. Indexed rather than scanned because
      # the caller is a human's keystroke and §3.7 measured a real changeset at
      # 810 files.
      #
      # @param path [String]
      # @return [Source::ChangedFile, nil] nil when this changeset carries no such file,
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
      # @param file [Source::ChangedFile] one of {#files}
      # @return [Array<String>, nil] the lines; `[]` for a file this changeset
      #   ADDS, which has an empty old side rather than no old side; nil when the
      #   base does not carry the path at all, which is a repository that cannot
      #   answer for its own diff
      def old_side(file)
        return [] if file.old_path.nil?

        bytes = @source.file_at(base_ref, file.old_path)
        lines(bytes) unless bytes.nil?
      end

      # The file as the HEAD held it -- {#old_side}'s twin, for an editor that
      # cannot draw the working copy opposite the base because the checkout is
      # not the revision under review (see {#checked_out?}).
      #
      # @param file [Source::ChangedFile] one of {#files}
      # @return [Array<String>, nil] the lines; `[]` for a file this changeset
      #   DELETES; nil when the head does not carry the path at all
      def new_side(file)
        return [] if file.new_path.nil?

        bytes = @source.file_at(head_ref, file.new_path)
        lines(bytes) unless bytes.nil?
      end

      # Whether the working copy of this file IS the head's, so an editor may
      # show the real file -- language server and all -- as the new side.
      # Asked only of a round that presents both sides ({#sides}): a survey's
      # new side is the disk by definition, and its source is never asked.
      #
      # @param file [Source::ChangedFile] one of {#files}
      # @return [Boolean]
      def checked_out?(file) = @source.checked_out?(file.path)

      # The position a note names, with the evidence read out of the revision
      # that side rests on -- the head for `new`, the base for `old` -- rather
      # than out of the editor buffer the note was placed in. On a changeset that
      # buffer is the working copy, which need not be the head; on a survey it is
      # the file on disk, unprojected, and the source masks the line it answers
      # ({Source::Corpus#line_at}). Either way the buffer's text is not what the
      # round reviewed, and the journal records what it reviewed.
      #
      # It NEVER REFUSES on evidence. A position the revision holds no line at --
      # a file this changeset does not carry, a line past the end, a surveyed
      # file deleted since -- anchors with a nil `anchor_text`. The note rail
      # takes a batch of notes whole or refuses it whole, so refusing one note
      # would journal its neighbours a second time on the retry.
      #
      # The text is SCRUBBED, unlike a diff anchor's {#evidence}: it goes into a
      # journal record, and bytes that are not valid UTF-8 cannot be written as
      # JSON, so a latin-1 line would cost the note its place on the record. The
      # editor measures drift on its own buffer, so a U+FFFD here changes no
      # measurement.
      #
      # The side and the line are judged BEFORE anything is read: `line: 0`
      # indexes the last line, which is a position nobody named.
      #
      # @param path [String] the file as {#file} knows it, on either side
      # @param side [Symbol, String] one of {Review::SIDES}
      # @param line [Integer] 1-based
      # @return [Anchor]
      # @raise [Anchor::UnknownSide, Anchor::InvalidLine] a position that cannot exist
      def anchor(path:, side:, line:)
        side = Anchor.side!(side)
        number = Anchor.line!(line)
        revision = side == :old ? base_ref : head_ref
        text = evidence_at(file(path), side, revision, number)
        Anchor.new(path:, side:, line: number, revision:, anchor_text: text && decoded(text).scrub)
      end

      # Register that this file has now been READ, on somebody's behalf, and
      # answer what reading it produced.
      #
      # A review asks two questions about a file and only one is about the diff:
      # what it says, and whether anybody has looked at it. {LazyFile#chunked?}
      # answers the second, and it flips only when {LazyFile#hunks} is asked -- so
      # a caller that puts a file in front of a human WITHOUT asking leaves a read
      # file reporting that it has not been. {Session::MarkedChangeset.row} then
      # hands its row no key and every marking gesture on it is refused.
      #
      # A message here rather than `file.hunks` at the caller, because a call
      # whose return value nobody wants reads as dead code and is deleted by the
      # next person through. Over a diff source it costs nothing.
      #
      # {#old_side} deliberately does NOT call it. That is a query, and the
      # callers that size or hash an old side have read the file on nobody's
      # behalf; welding the two would make every such caller mark the corpus read.
      #
      # @param file [Source::ChangedFile, LazyFile] one of {#files}
      # @return [Array<Hunk>] that file's hunks, now in hand
      def read(file) = file.hunks

      # @return [Enumerator] over {#files}, which is what makes this Enumerable.
      #   Blockless, it parses nothing -- the same promise {#each_anchor} makes,
      #   and worth making twice: a caller holding an `Enumerable` cannot tell
      #   which of the two it has, so one lazy and one eager is worse than either
      #   being consistent. The size block is called only if `#size` is asked.
      def each(&block)
        return enum_for(:each) { files.size } unless block

        files.each(&block)
      end

      # Group the changeset for reading, by whichever {Partition::Strategy} the
      # caller hands over -- the commit walk ({Partition::ByCommit}), the flat
      # view ({Partition::Whole}), by directory, or whatever is registered next.
      #
      # NOT memoized, and deliberately: a memo keyed by strategy is a stale
      # partition waiting to happen under a re-render, which is the same reason
      # {Session#marked} is rebuilt on demand. Grouping is arithmetic over
      # `files`, which IS memoized, so the parse still happens once.
      #
      # @param strategy [Partition::Strategy] anything answering the port
      # @return [Array<Partition>] disjoint, together covering every file once
      # @raise [Unattributed] if the strategy cannot attribute a file -- see
      #   {Partition::ByCommit}, which is the one that can fail this way
      def partitions(strategy) = strategy.partition(self)

      # Whether this changeset's SOURCE can be grouped that way -- asked before
      # {#partitions}, so a source with no walk refuses by name instead of dying
      # on a missing message halfway through one.
      #
      # The question goes to `@source`, which stays private. It cannot be asked
      # of the changeset either: `#commits` above is forwarded unconditionally,
      # so `ByCommit#supports?(self)` would answer true for a source that has no
      # walk at all and the refusal would be unreachable.
      #
      # @param strategy [Partition::Strategy] anything answering the port
      # @return [Boolean]
      def supports?(strategy) = strategy.supports?(@source)

      # Which of {Review::SIDES} this round presents at all -- what an editor
      # builds its layout from, before a single row is opened.
      #
      # {#supports?}'s shape for {#supports?}'s reason, and it cannot be derived
      # HERE either: {#old_side} answers `[]` both for a file this changeset adds
      # and for every file of a corpus, so a version reading the files would
      # report a one-sided round for any diff whose only file is an addition.
      #
      # @return [Array<String>] a subset of {Review::SIDES}, in its order
      def sides = @source.sides

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
      # A path is the opposite case and is scrubbed -- see {Source::Parser#path_text}.
      def evidence(line) = decoded(line.byteslice(1..).to_s)

      def decoded(text) = text.dup.force_encoding(Encoding::UTF_8)

      # The name that side's revision holds the file under: nil for the old side
      # of an addition or the new side of a deletion, which is no evidence.
      def evidence_at(held, side, revision, number)
        named = held && (side == :old ? held.old_path : held.new_path)
        named && @source.line_at(revision, named, number)
      end
    end
  end
end
