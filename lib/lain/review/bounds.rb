# frozen_string_literal: true

module Lain
  module Review
    # The sizes past which the review surface REFUSES, and the alternative it
    # names when it does.
    #
    # {Agent::Budget}'s shape, for {Agent::Budget}'s reason: a ceiling the
    # harness enforces is not an outcome the subject produced, so it raises
    # rather than returning a value a caller can read past. What differs is what
    # it defends. A budget bounds a loop pointed at a shell; this bounds a VIEW,
    # and the thing it defends against is not a crash but a success that isn't
    # one -- octo's fix for its own large-PR bug (octo#302) turned a crash into a
    # quietly truncated file list, and a truncated list reads exactly like a
    # short one. So this object never truncates, never samples, and never elides:
    # either the whole changeset is handled or {TooLarge} names the measurement,
    # the ceiling, and what to do instead.
    #
    # Two arguments live in `docs/review.md` under "Where the review ceilings
    # come from": where the bound is NOT (never on parse cost), and why nothing
    # here reads a hunk -- the DECISION to refuse is reached on a file count
    # alone, and the line ceiling asks a FILE what it costs rather than summing
    # its hunks.
    class Bounds
      # A view is past a ceiling. Carries the measurement, the ceiling and the
      # alternative in its message, because a bare "too large" leaves the
      # reader to guess which of three bounds fired.
      class TooLarge < Error; end

      # GitHub stops serving a combined diff past 300 files, and tuicr#475
      # independently settled on the same hard ceiling, reporting that "patches
      # large enough to hit the limit also made file and commit navigation
      # slow". Two unrelated projects, one number -- and for {Source::GithubPr}
      # it is an API fact rather than a preference.
      DEFAULT_MAX_FILES = 300

      # DERIVED from {DEFAULT_MAX_FILES} rather than chosen beside it: the
      # measured work-scale changeset is 80,800 rendered lines over 800 files, so
      # 101 lines per file, so 300 files is ~30,000 lines. Setting both ceilings
      # to fire at the same changeset SIZE is what keeps both alive -- a line
      # ceiling far above the implied one would be dead code, one far below would
      # make the file ceiling unreachable. What it catches that a file count
      # cannot is the other shape: 40 files of 1,000 lines each. For scale, it is
      # 11x the measured 2,727-line single-commit view.
      DEFAULT_MAX_LINES = 30_000

      # The size a `/critique` chunk is packed to, and the only ceiling set
      # against a context window rather than a reader. ~99k tokens at a measured
      # 49.6 bytes per rendered line -- half the smallest window a bench arm
      # might run. The full derivation, and why the first cut at 4,000 was wrong,
      # is in `docs/review.md` under "Where the review ceilings come from".
      DEFAULT_MAX_CRITIQUE_LINES = 7_000

      # The scope vocabulary, read off {Partition::STRATEGIES} rather than
      # restated: everything below reads out of this one Hash, so there is no
      # second place a scope is spelled.
      SCOPE_NAMES = Partition::STRATEGIES.transform_values(&:name).freeze

      # `fetch` is what makes the derivation real: a scope nobody declared
      # raises `KeyError` at the dispatch rather than falling through to
      # whichever branch a bare `==` left as the default.
      SCOPE_CHECKS = SCOPE_NAMES.transform_values { |name| :"check_#{name}!" }.freeze

      # The alternative a cumulative refusal offers, in the vocabulary's own
      # spelling rather than a literal -- a literal would go on advertising a
      # scope after the vocabulary stopped serving it, and `fetch` will not.
      COMMIT_WALK = SCOPE_NAMES.fetch(:commits)

      # The strategy `:commits` means, read out of the registry rather than
      # constructed here so there is one instance and one spelling.
      COMMIT_STRATEGY = Partition::STRATEGIES.fetch(:commits)

      # The directory grouping, read out of the registry for {COMMIT_STRATEGY}'s
      # reason. Named here because {SCOPE_CHECKS} derives a `check_<name>!` per
      # REGISTERED strategy, so a strategy shipping without one is a
      # `NoMethodError` deep in a refusal path; `bounds_spec.rb` pins a real
      # private method behind every derived name, which is where that surfaces.
      DIRECTORY_STRATEGY = Partition::STRATEGIES.fetch(:by_directory)

      # What {#check_corpus_files!} recommends, and the ONE advice here that is a
      # constant rather than a measurement: {Source::Corpus} refuses in its
      # CONSTRUCTOR off the walk's file count alone, so there is no changeset to
      # hand {#cumulative_advice}, and building one to compose a sentence would
      # spend the exact property the early refusal buys.
      #
      # It names no SCOPE, and must not. Both remedies here change the FILE
      # COUNT, which is the only thing this ceiling measures: a narrower walk
      # root holds fewer files, `--unbounded` lifts the number. A partition
      # strategy does NEITHER -- it groups the same file set for display, and
      # this refusal has already fired by the time any scope is applied
      # ({CLI::Survey#present} builds the corpus before `session.present`). A
      # version of this sentence that recommended `--scope by_directory` sent the
      # reader to a path that refused again with byte-identical wording.
      #
      # "a subdirectory" and not a NAMED one: naming which subdirectory would fit
      # needs the walk this refusal exists to avoid.
      #
      # `--unbounded` is LAST as DEFENCE IN DEPTH rather than a guard over a live
      # path -- said plainly, because a comment claiming otherwise is one a future
      # reader would trust. This sentence never reaches the eliding rail today:
      # it raises before any surface is called and is rendered whole by
      # `Repl#dispatch` and by Thor's stderr. The placement costs nothing and the
      # reasoning would hold if that changed, since `elided` (`65_review.lua`)
      # preserves a head AND a tail, so the token a reader cannot guess is the
      # one that wants an end.
      #
      # Shared with {#cumulative_advice_for}'s own last word: a walk refused for
      # too many files and a walk refused for too many lines are the same tree,
      # so the escape is the same flag, spelled once here rather than twice.
      UNBOUNDED_REMEDY = "raise the ceiling with --unbounded"

      # `.freeze` by hand, {Partition::Whole::ADVICE}'s reason: this interpolates.
      CORPUS_NARROWING = "survey a subdirectory instead, or #{UNBOUNDED_REMEDY}".freeze

      # What a corpus refusal calls the thing it is refusing, in {#guard!}'s
      # subject position. A survey is of a TREE and has no revision, so there is
      # no sha and no scope name to put here -- the corpus is the whole subject.
      CORPUS = "this corpus"

      # Every strategy a cumulative refusal may recommend narrowing TO -- every
      # registered strategy except {Whole}, since "narrow to the whole changeset"
      # recommends nothing. Registry order, so the same candidate wins whenever a
      # changeset fits more than one: {#cumulative_advice} takes the FIRST fit,
      # not the best one, and repeat runs must agree.
      #
      # This is what makes a refusal's advice strategy-neutral: nothing here
      # spells "commit" or "directory", so a fourth strategy is recommended the
      # moment it registers, with no matching edit here -- the sentence comes off
      # the winning candidate's own `#advice`.
      #
      # Filtering by source belongs to {Session#present} ("`#supports?` is
      # consulted where the source is in hand"), not here; doing it in `Bounds`
      # would be this object taking on a resolution decision that is not its own.
      NARROWING_CANDIDATES = Partition::STRATEGIES.except(:cumulative).values.freeze

      # What a group's own refusal says: below a {Partition}'s files there is
      # no narrower PRESENTATION scope, whatever strategy produced the group --
      # only `/critique`'s file-level packing splits further, and that is a
      # different operation, not a smaller scope.
      NO_NARROWER = "and this is already the narrowest scope, so there is nothing to fall back to"

      # What a cumulative refusal says when NO candidate in {NARROWING_CANDIDATES}
      # fits either. Strategy-neutral by construction -- naming one candidate's
      # strategy here would be exactly the "commit" prose this port replaced.
      # Advice that sends a human down a path which also refuses is worse than
      # no advice.
      NO_PRESENTABLE_SCOPE = "and no other scope presents it either, so there is no scope " \
                             "that presents this changeset whole"

      # The refusal below the FILE, which is where splitting genuinely stops.
      #
      # The first cut said this of a COMMIT and it was false: a {Partition}
      # answers `#files`, so the file is a boundary GIT SUPPLIES below the
      # commit. A hunk is git-supplied too, and {Review::MARK_STATES} is recorded
      # per HUNK, so the model addresses hunks perfectly well. The honest reason
      # this stops at the file is not impossibility but a JUDGEMENT: a critique
      # of one hunk without the rest of its file is a different task rather than
      # a smaller one, because a reviewer judging a change needs its siblings.
      # Hunk-level chunks are a decision to take deliberately, not one this
      # comment forecloses by calling it impossible.
      UNSPLITTABLE = "and a file is the smallest chunk this splits by, because a critique of one " \
                     "hunk without the rest of its file is a different task rather than a smaller one"

      # `Float::INFINITY` rather than `nil`, and the difference is the whole
      # reason it is a constant: infinity answers the entire comparison duck a
      # number does, so every guard below is untouched and only the coercion has
      # to know. `nil` would need a branch at each comparison and is what a
      # missed config lookup hands you -- this value cannot arrive by accident.
      #
      # Nothing DEFAULTS to it: an absent ceiling is a number, and a silently
      # unbounded view is precisely the success-that-isn't-one this object exists
      # to refuse. Opt-in, at the command line, by a human who said the word.
      UNBOUNDED = Float::INFINITY

      # What a view costs, in the two units the ceilings are set in.
      #
      # ONE line unit, deliberately. `lines` is RENDERED lines -- what a reader
      # scrolls and what a prompt carries -- and never numstat's changed-line
      # count, which is ~9% lower at work scale (74,400 changed against 80,800
      # rendered). Two constructors measuring "lines" off two different tapes is
      # the trap {Review::SIDES} records, one level down.
      #
      # It counts each hunk's body plus its `@@` header, and NOT the four-line
      # `diff --git`/`index`/`---`/`+++` preamble: that is a constant per FILE,
      # the quantity the file ceiling already governs.
      Size = Data.define(:files, :lines) do
        # @param files [Enumerable<#rendered_lines>] a changeset's or a scope's
        #   files. Not `#hunks` -- asking a file its own size instead of
        #   counting its hunks is the whole of what lets a bound run over a
        #   corpus nobody has chunked.
        def self.of(files) = new(files: files.size, lines: lines_in(files))

        # The measurement without the value object, because the guards below run
        # it per commit and per FILE on the packing walk and never read
        # {Size#files}. It ASKS rather than counts, which is the difference
        # between a bound a survey can afford and one it cannot -- see
        # {Source::ChangedFile#rendered_lines}, where the unit above is
        # implemented for a parsed file.
        def self.lines_in(files) = files.sum(&:rendered_lines)
      end

      attr_reader :max_files, :max_lines, :max_critique_lines

      def initialize(max_files: DEFAULT_MAX_FILES, max_lines: DEFAULT_MAX_LINES,
                     max_critique_lines: DEFAULT_MAX_CRITIQUE_LINES)
        @max_files = ceiling(max_files)
        @max_lines = ceiling(max_lines)
        @max_critique_lines = ceiling(max_critique_lines)
        freeze
      end

      # @param view [#files, #partitions] a {Changeset}
      # @param scope [Symbol] one of {SCOPE_CHECKS}' keys
      # @return [nil] when the whole view can be presented at this scope
      # @raise [TooLarge] naming the measurement, the ceiling and the alternative
      # @raise [KeyError] for a scope {Partition::STRATEGIES} does not declare
      def check_presentation!(view, scope:)
        send(SCOPE_CHECKS.fetch(scope), view)
        nil
      end

      # The file ceiling asked from a FILE COUNT, for the caller who has one and
      # no view -- {Source::Corpus}, deciding in its constructor whether to
      # become one at all. Public because that caller is outside this object, and
      # the alternative is what it replaced: a refusal sentence written out by
      # hand elsewhere, against the same ceiling, with nothing keeping the two
      # spellings in step.
      #
      # Only `max_files`. A line count is not a fact a walk has -- it is the read
      # this refusal is avoiding -- and {Session#present} asks it afterwards, of a
      # corpus that got built.
      #
      # @param measured [Integer] how many files the walk found
      # @return [nil] when the walk is within the ceiling
      # @raise [TooLarge] naming the measurement, the ceiling and
      #   {CORPUS_NARROWING}
      def check_corpus_files!(measured)
        guard!(measured, max_files, "files", CORPUS) { CORPUS_NARROWING }
        nil
      end

      # The `/critique` input, chunked by the boundaries git already supplies:
      # the commit first, and the FILE within a commit too big to send whole.
      # Neither drops content nor invents a split, so a chunk is always a
      # {Review::Partition}, carrying its commit's label whether it holds all of
      # that commit's files or some. An empty group still yields -- see
      # {Partition::ByCommit} for how a merge produces one -- because skipping it
      # is the silent drop this object exists to refuse.
      #
      # N chunks from ONE commit carry the same `label` AND the same `detail`,
      # including the commit's own unpartitioned numstat, because partitioning it
      # would invent per-chunk numbers git never reported. `files` is the only
      # member that differs. The cost lands on a renderer: the sidebar renders
      # `numstat`, so a commit split into three chunks renders that one figure
      # three times and the three do not sum to it. A consumer showing per-chunk
      # totals must derive them from `files` ({Size.of}).
      #
      # Every chunk is packed and measured BEFORE any is yielded. Checking as it
      # goes would hand chunks 1 and 2 to the model and then refuse at chunk 3,
      # which is neither handling the whole thing nor refusing it.
      #
      # @param changeset [#partitions]
      # @return [Enumerator<Review::Partition>] when no block is given; one
      #   or more per commit, disjoint, together covering every file exactly once
      # @raise [TooLarge] if ONE FILE alone is past {#max_critique_lines} -- see
      #   {UNSPLITTABLE} for why the file is where splitting stops
      def each_critique_chunk(changeset, &block)
        return critique_enumerator(changeset) unless block

        critique_chunks(changeset).each(&block)
      end

      private

      # The ONE place {UNBOUNDED} is a special case, which is what buys every
      # comparison below staying a plain `<=`. The predicate is exact, and both
      # of the obvious spellings are wrong:
      #
      # - `equal?` passes only the CONSTANT. Infinity is not a flonum, so the
      #   constant is one heap object and a COMPUTED `1.0/0` is another -- which
      #   is how an unbounded ceiling actually arrives once a flag parses one.
      # - `value == UNBOUNDED` dispatches to the ARGUMENT, so an object
      #   answering `true` to everything becomes an unbounded ceiling with
      #   `Integer()` never run. Reversing it does not help either: `Float#==`
      #   falls back to asking `other == self`.
      #
      # `eql?` on infinity itself is neither: true for any Float of that value,
      # false for anything that is not a Float at all.
      def ceiling(value) = UNBOUNDED.eql?(value) ? UNBOUNDED : Integer(value)

      def check_cumulative!(view)
        files = view.files
        subject = cumulative_subject(view)
        guard!(files.size, max_files, "files", subject) { cumulative_advice_for(view) }
        guard!(Size.lines_in(files), max_lines, "rendered lines", subject) { cumulative_advice_for(view) }
      end

      # Asked of the view's own {Source#sides} rather than its class: a source
      # with no old side is the one this port already has a name for --
      # {Source::HEAD_SIDE_ONLY}'s own doc says "a corpus, and anything else
      # surveyed as it stands" -- so a future survey-shaped source earns
      # {CORPUS}'s words with no edit here, and this object never asks what kind
      # of source it holds.
      def surveyed_as_it_stands?(view) = view.sides == Source::HEAD_SIDE_ONLY

      # {CORPUS} everywhere a source surveyed as it stands is refused, so the
      # file ceiling ({#check_corpus_files!}) and the line ceiling say the same
      # word for the same reason rather than two words that happen to agree.
      def cumulative_subject(view) = surveyed_as_it_stands?(view) ? CORPUS : "the cumulative view"

      # {#cumulative_advice}'s narrower scopes, plus the one remedy that is real
      # only for a tree a human can re-walk at a smaller root: {UNBOUNDED_REMEDY},
      # named LAST, {CORPUS_NARROWING}'s own placement. A diff source keeps
      # exactly {#cumulative_advice}'s sentence -- `/review` has no `--unbounded`
      # to offer, and naming a flag its reader cannot type would be worse advice
      # than none.
      def cumulative_advice_for(view)
        advice = cumulative_advice(view)
        return advice unless surveyed_as_it_stands?(view)

        "#{advice}, or #{UNBOUNDED_REMEDY}"
      end

      def check_commits!(view) = check_partitioned!(view, COMMIT_STRATEGY)

      def check_by_directory!(view) = check_partitioned!(view, DIRECTORY_STRATEGY)

      # Every grouping bounds the same way -- each group whole or nothing --
      # so the two above differ only in which strategy cut the groups. The
      # cumulative check stays separate because it measures `view.files`
      # directly and offers a NARROWING rather than {NO_NARROWER}.
      def check_partitioned!(view, strategy)
        view.partitions(strategy).each { |group| check_group!(group) }
      end

      # The subject is what the group's DETAIL calls it, which replaced
      # `"commit #{sha}"`: a refusal that says "commit" in prose is one this
      # object cannot make honest for any other grouping, and only the strategy
      # knows how its own groups are looked up. Asked ONCE and shared by both
      # guards, so a reader comparing two messages need not check whether they
      # name one thing.
      def check_group!(group)
        files = group.files
        subject = group.detail.named(group.label)
        guard!(files.size, max_files, "files", subject) { NO_NARROWER }
        guard!(Size.lines_in(files), max_lines, "rendered lines", subject) { NO_NARROWER }
      end

      # Computed only on the refusal path. This is where the short-circuit's
      # promise gets its exact wording: the DECISION to refuse reads no hunks,
      # and the MESSAGE is allowed to measure, because deciding whether a
      # narrower scope actually fits means measuring it. It happens not to cost a
      # hunk either ({Size.lines_in} asks each file its own size), but that is
      # the candidates' property rather than this method's promise. A true
      # sentence is worth the measurement; the finding this replaced was a
      # message that sent a human down a path which also refuses.
      #
      # {NARROWING_CANDIDATES} in registry order, FIRST fit wins, `#advice` read
      # off that strategy rather than composed here.
      #
      # `#supports?` comes FIRST, which is what makes the registry as safe as its
      # safest candidate rather than as safe as its first. {Session#present}
      # filters the RESOLVED scope, which is `:cumulative` on this path, so every
      # candidate is consulted here regardless -- and {ByCommit} leading the
      # order meant a source with no walk died in `ownership` with a
      # `NoMethodError` naming neither the scope asked for nor the source.
      def cumulative_advice(view)
        candidate = NARROWING_CANDIDATES.find { |strategy| view.supports?(strategy) && fits?(view, strategy) }
        candidate ? candidate.advice : NO_PRESENTABLE_SCOPE
      end

      def fits?(view, strategy)
        view.partitions(strategy).all? { |group| presentable?(group) }
      end

      def presentable?(group)
        group.files.size <= max_files && Size.lines_in(group.files) <= max_lines
      end

      # Packs at most ONCE however many times the Enumerator is asked, while
      # still packing nothing until it is asked at all. A frozen Bounds cannot
      # memoize on itself, so the memo lives in the closure the Enumerator holds,
      # which also scopes it to this one walk. `enum_for` would re-enter this
      # method per query, and `#size` followed by `#each` then packed the whole
      # changeset twice: {Changeset#files} memoizes, but neither the grouping,
      # the packing walk nor its per-file guard does.
      def critique_enumerator(changeset)
        packed = nil
        chunks = -> { packed ||= critique_chunks(changeset) }
        Enumerator.new(-> { chunks.call.size }) do |yielder|
          chunks.call.each { |chunk| yielder << chunk }
        end
      end

      def critique_chunks(changeset)
        changeset.partitions(COMMIT_STRATEGY).flat_map do |group|
          pack(group.files).map { |files| group.with(files: files.freeze) }
        end
      end

      # Greedy, in the diff's own order: a new chunk opens only when the next
      # file would push the current one past the ceiling. An empty group packs
      # to one empty chunk rather than none, which is what keeps a merge-blanked
      # commit in the walk.
      def pack(files)
        filled = 0
        packed = files.each_with_object([]) do |file, chunks|
          lines = file_lines!(file)
          opening = chunks.empty? || filled + lines > max_critique_lines
          chunks << [] if opening
          filled = opening ? lines : filled + lines
          chunks.last << file
        end
        packed.empty? ? [[]] : packed
      end

      def file_lines!(file)
        lines = Size.lines_in([file])
        guard!(lines, max_critique_lines, "rendered lines", "#{file.path} alone") { UNSPLITTABLE }
        lines
      end

      # `limit` rather than `ceiling`: a parameter shadowing a private method of
      # the same object is one edit away from a collision nobody reading either
      # half would predict. The MESSAGE still says "ceiling", because that is the
      # word the reader was refused by.
      def guard!(measured, limit, unit, subject)
        return if measured <= limit

        raise TooLarge, "#{subject} is #{measured} #{unit}, over the ceiling of #{limit} -- #{yield}"
      end
    end
  end
end
