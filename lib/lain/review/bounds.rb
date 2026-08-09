# frozen_string_literal: true

module Lain
  module Review
    # The sizes past which the review surface REFUSES, and the alternative it
    # names when it does.
    #
    # {Agent::Budget}'s shape, for {Agent::Budget}'s reason: a ceiling the
    # harness enforces is not an outcome the subject produced, so it raises
    # rather than returning a value a caller can read past. The difference is
    # what it is protecting. A budget bounds a loop pointed at a shell; this
    # bounds a VIEW, and the thing it is defending against is not a crash but a
    # success that isn't one -- octo's fix for its own large-PR bug (research
    # S4.2, octo#302) turned a crash into a quietly truncated file list, and a
    # truncated list reads exactly like a short one.
    #
    # So: this object never truncates, never samples, and never elides. Either
    # the whole changeset is handled or {TooLarge} names the measurement, the
    # ceiling, and what to do instead.
    #
    # == Where the bound is NOT
    #
    # Not on diff size. Research S3.7 measured the parser at 80,800 rendered
    # lines in 0.26s and 39MB, so nothing here is defending the parse. The
    # constraints are downstream of it: a human reading a cumulative view, and
    # a `/critique` prompt against a context window.
    #
    # == Deciding cheaply, and why nothing here reads a hunk
    #
    # The file count is the cheapest fact and, at the work scale that motivates
    # this card, the one that fires first -- 800 files against a ceiling of 300.
    # {#check_presentation!} therefore asks it FIRST, so the DECISION to refuse
    # is reached on a file count alone and never costs a walk over the thing it
    # is refusing to walk over.
    #
    # Ordering alone was never the whole of it, and reading it as such is the
    # trap this paragraph exists to close: a short-circuit fires on the REFUSAL
    # path, so every SUCCESSFUL presentation went on to sum `file.hunks` over
    # every file it had just agreed to present. Wrapping the argument in a
    # lambda fixes nothing -- the ordering was already right and the input was
    # wrong. So the line ceiling now asks a FILE what it costs
    # ({Source::ChangedFile#rendered_lines}), and each file answers from what
    # its own source already knows: a parsed diff from the hunks it parsed, a
    # corpus from the line counts its identity pass harvested in one streamed
    # read. Nothing here sends `#hunks`, so a file nobody has chunked survives a
    # whole bounded presentation unchunked.
    #
    # That now covers the MESSAGE as well as the DECISION, which it did not
    # use to: naming a narrower scope only when that scope actually fits still
    # means measuring the candidate's groups, but the measurement is the same
    # per-file arithmetic and it still gives up at the first candidate's first
    # group whose FILE count is over. {#cumulative_advice} says so again at the
    # point of use. The promise is nevertheless stated as being about the
    # DECISION, because that is the one a future strategy cannot quietly break:
    # composing a sentence is allowed to measure, and a candidate that had to
    # read content to know whether it fits would be within its rights.
    #
    # There is a spec on each half, and both drive files that RAISE when their
    # hunks are read -- the only proof that a message was not sent, since a
    # recording double leaves a green run resting on the recorder.
    class Bounds
      # A view is past a ceiling. Carries the measurement, the ceiling and the
      # alternative in its message, because a bare "too large" leaves the
      # reader to guess which of three bounds fired.
      class TooLarge < Error; end

      # GitHub stops serving a combined diff past 300 files (research S3.7),
      # and tuicr#475 independently settled on the same hard ceiling, reporting
      # that "patches large enough to hit the limit also made file and commit
      # navigation slow" (S4.2). Two unrelated projects, one number -- and for
      # {Source::GithubPr} it is an API fact rather than a preference.
      DEFAULT_MAX_FILES = 300

      # DERIVED from {DEFAULT_MAX_FILES} rather than chosen beside it: S3.7's
      # work-scale changeset is 80,800 rendered lines over 800 files, so 101
      # lines per file, so 300 files is ~30,000 lines. Setting the two ceilings
      # to fire at the same changeset SIZE is what keeps both alive -- a line
      # ceiling far above the implied one would be dead code, and one far below
      # would make the file ceiling unreachable. What it catches that the file
      # count cannot is the other shape: 40 files of 1,000 lines each.
      #
      # For scale, it is 11x the 2,727-line single-commit view S3.7 measured,
      # so an ordinary review is nowhere near it.
      DEFAULT_MAX_LINES = 30_000

      # The size a `/critique` chunk is packed to, and the only ceiling set
      # against a context window rather than a reader.
      #
      # Set from the WINDOW, which is the constraint this doc argues from.
      # A rendered diff line measures **49.6 bytes** here (`git diff HEAD~8`,
      # 6,849 lines, 339,711 bytes / measured), so ~14 tokens/line at ~3.5
      # bytes/token (an ESTIMATE for code, not a measurement); 7,000 lines is
      # then ~99k tokens. That is **half** of the smallest window a bench arm
      # might run (200K, Haiku 4.5) and ~10% of the 1M default, leaving the
      # prompt, the surrounding code and the reply the other half of the worst
      # case. The estimate is bounded and the conclusion survives its range: at
      # 3.0 bytes/token 7,000 lines is 58% of a 200K window, at 4.0 it is 43%.
      #
      # The half is a POLICY -- a judgement about how much of a window the diff
      # should occupy -- while the window and the bytes/line are measured. That
      # distinction is the correction: the first cut set 4,000 from S3.7's 2,727
      # rendered lines per commit, which is the mean of a SYNTHETIC UNIFORM
      # generator (`bigdiff_stacked` emits 30 identical commits) and therefore a
      # distribution with no tail. A ceiling at mean + 47% refuses the tail of
      # every real changeset -- concretely, it refused a 5,001-line single-file
      # commit that is ~71k tokens, 7% of a 1M window, while the doc justified
      # itself by that same window. The two could not both be true.
      #
      # The measured per-commit view now sits at 39% of the ceiling rather than
      # 68% of it. The same arithmetic is what makes the card's premise true
      # rather than assumed: 74,400 changed lines is ~80,800 rendered, ~1.1M
      # tokens, past even a 1M window.
      DEFAULT_MAX_CRITIQUE_LINES = 7_000

      # The scope vocabulary, read off {Partition::STRATEGIES} rather than
      # restated -- the standing rule this chunk formed three times, now with
      # the registry as its one source. Everything below reads out of this one
      # Hash, so there is no second place a scope is spelled.
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
      # constructed here so there is one instance and one spelling. A LATER card
      # takes the strategy as an argument; today the two scope checks below are
      # still named for the two groupings the vocabulary declares, so naming the
      # commit walk here is the rename and nothing more.
      COMMIT_STRATEGY = Partition::STRATEGIES.fetch(:commits)

      # The directory grouping, read out of the registry for {COMMIT_STRATEGY}'s
      # reason. Named here because {SCOPE_CHECKS} derives a `check_<name>!` per
      # REGISTERED strategy, so a strategy shipping without one is a
      # `NoMethodError` deep in a refusal path -- `bounds_spec.rb` pins a real
      # private method behind every derived name, which is where that miss
      # surfaces instead.
      DIRECTORY_STRATEGY = Partition::STRATEGIES.fetch(:by_directory)

      # Every strategy a cumulative refusal may recommend narrowing TO -- every
      # registered strategy except {Whole} itself, since "narrow to the whole
      # changeset" recommends nothing. Registry order, so the same candidate
      # wins whenever a changeset fits more than one: {#cumulative_advice}
      # takes the FIRST fit, not the best one, and repeat runs must agree.
      #
      # This is what makes a refusal's advice strategy-neutral: nothing here
      # spells "commit" or "directory", so a fourth strategy is recommended the
      # moment it registers, with no matching edit to this file -- the
      # sentence itself comes off the winning candidate's own `#advice`.
      #
      # Tried in this order with NO `#supports?(source)` filtering: `#fits?`
      # calls straight through to `strategy.partition(view)`, so a source
      # {ByCommit} cannot walk (no `#commits`) raises `NoMethodError` here
      # rather than falling through to {ByDirectory}, which would have
      # accepted it. NOT a regression -- the pre-A4 code only ever consulted
      # {ByCommit} and failed the same way -- but it means this registry is
      # only as safe as its FIRST candidate, not as safe as its safest one.
      # Filtering by source belongs to {Session#present} (A3's Open decision:
      # "`#supports?` is consulted where the source is in hand"), not here --
      # adding it in `Bounds` would be the object taking on a resolution
      # decision the escalation triggers reserve for that card.
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
      # The first cut said this of a COMMIT, and it was false: a {Partition}
      # answers `#files`, so the file is a boundary GIT SUPPLIES below the
      # commit, and packing by it drops nothing and invents nothing.
      #
      # A hunk is a git-supplied boundary too -- {Hunk} answers `#lines` and
      # `#path`, and {Review::MARK_STATES} is recorded per HUNK, with a file's
      # tri-state ({Review::FILE_STATES}) the FOLD of them. So the model
      # addresses hunks perfectly well, and the honest reason this stops at the
      # file is not impossibility: it is a judgement that a critique of one hunk
      # without the rest of its file is a DIFFERENT task rather than a smaller
      # one, because a reviewer judging a change needs its siblings. Stated as a
      # judgement because that is what it is. If something later wants
      # hunk-level chunks, that is a decision to take deliberately, not a line
      # this comment gets to foreclose by calling it impossible.
      UNSPLITTABLE = "and a file is the smallest chunk this splits by, because a critique of one " \
                     "hunk without the rest of its file is a different task rather than a smaller one"

      # A ceiling that refuses nothing, for the caller who has said so.
      #
      # `Float::INFINITY` rather than `nil`, and the difference is the whole
      # reason it is a constant: infinity answers the entire comparison duck a
      # number does -- `x <= INFINITY` is true, `x > INFINITY` is false -- so
      # every guard below is untouched and only the coercion has to know. `nil`
      # would need a branch at each comparison, and, worse, it is what a missed
      # config lookup hands you. This value cannot arrive by accident.
      #
      # Nothing DEFAULTS to it, deliberately: an absent ceiling is a number, and
      # a silently unbounded view is precisely the success-that-isn't-one this
      # object exists to refuse. It is opt-in, at the command line, by a human
      # who has said the word.
      UNBOUNDED = Float::INFINITY

      # What a view costs, in the two units the ceilings are set in.
      #
      # ONE line unit, deliberately. `lines` is RENDERED lines -- what a reader
      # scrolls and what a prompt carries -- and never numstat's changed-line
      # count, which is ~9% lower at work scale (S3.7: 74,400 changed against
      # 80,800 rendered). Two constructors measuring "lines" off two different
      # tapes is the same trap {Review::SIDES} records, one level down.
      #
      # It counts each hunk's body plus its `@@` header, and NOT the four-line
      # `diff --git`/`index`/`---`/`+++` preamble: that is a constant per FILE,
      # which is the quantity the file ceiling already governs.
      Size = Data.define(:files, :lines) do
        # @param files [Enumerable<#rendered_lines>] a changeset's or a scope's
        #   files. Not `#hunks` -- asking a file its own size instead of
        #   counting its hunks is the whole of what lets a bound run over a
        #   corpus nobody has chunked.
        def self.of(files) = new(files: files.size, lines: lines_in(files))

        # The measurement without the value object, because the guards below run
        # it per commit and per FILE on the packing walk and never read
        # {Size#files}. One implementation, two callers -- {.of} is for a caller
        # that wants both numbers to show a human.
        #
        # It ASKS rather than counts, and that is the difference between a
        # bound a survey can afford and one it cannot. See
        # {Source::ChangedFile#rendered_lines}, which is where the unit above is
        # actually implemented for a parsed file.
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

      # The `/critique` input, chunked by the boundaries git already supplies:
      # the commit first, and the FILE within a commit that is too big to send
      # whole. Both are boundaries the changeset hands over -- neither drops
      # content nor invents a split -- so a chunk is always a {Review::Partition},
      # carrying its commit's label whether it holds all of that commit's files
      # or some of them. A caller that cannot tell which of two types it was
      # handed would have to branch; joining chunks is its business anyway.
      #
      # An empty group still yields -- see {Partition::ByCommit} for how a merge
      # produces one -- because skipping it is the silent drop this object exists
      # to refuse.
      #
      # == What a SPLIT commit's chunks share, and what that costs a renderer
      #
      # N chunks from one commit carry the same `label` AND the same `detail` --
      # including the commit's OWN, unpartitioned numstat, because that is what
      # {Partition::ByCommit::Commit} means and partitioning it would invent
      # per-chunk numbers git never reported. `files` is the only member that
      # differs.
      #
      # The cost lands on a renderer: T14's sidebar renders `numstat`, so a
      # commit split into three chunks renders that one figure three times, and
      # the three do not sum to it. A consumer that shows per-chunk totals must
      # derive them from `files` (what {Size.of} answers) rather than read the
      # detail's `numstat`, which describes the whole commit however it was
      # chunked.
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
        guard!(files.size, max_files, "files", "the cumulative view") { cumulative_advice(view) }
        guard!(Size.lines_in(files), max_lines, "rendered lines", "the cumulative view") do
          cumulative_advice(view)
        end
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

      # The subject is what the group's DETAIL calls it, which is what replaced
      # `"commit #{sha}"`: a refusal that says "commit" in prose is one this
      # object cannot make honest for any other grouping, and only the strategy
      # knows how its own groups are looked up. The commit walk puts the sha
      # back there; a directory answers its path, which names itself already.
      #
      # Asked ONCE and shared by both guards, because the two ceilings refuse
      # the same group and a reader comparing two messages should not have to
      # check whether they name one thing.
      def check_group!(group)
        files = group.files
        subject = group.detail.named(group.label)
        guard!(files.size, max_files, "files", subject) { NO_NARROWER }
        guard!(Size.lines_in(files), max_lines, "rendered lines", subject) { NO_NARROWER }
      end

      # Computed only on the refusal path, and only there.
      #
      # This is where the short-circuit's promise gets its exact wording: the
      # DECISION to refuse reads no hunks, and the MESSAGE is allowed to
      # measure, because deciding whether a narrower scope actually fits means
      # measuring it. It happens not to cost a hunk either -- the measurement is
      # {Size.lines_in}, which asks each file its own size -- but that is the
      # candidates' property rather than this method's promise, and `all?` gives
      # up at the first candidate's first group whose FILE count is over anyway.
      # A true sentence is worth the measurement; Schneeman's finding was a
      # message that sent a human down a path which also refuses.
      #
      # {NARROWING_CANDIDATES} is tried in registry order and the FIRST fit
      # wins, `#advice` read off that strategy rather than composed here.
      #
      # `#supports?` comes FIRST and is what makes the registry as safe as its
      # safest candidate rather than as safe as its first. {Session#present}
      # filters the RESOLVED scope, which is `:cumulative` on this path -- so
      # every candidate is consulted here regardless, and {ByCommit} leading
      # the order meant a source with no walk died in `ownership` with a
      # `NoMethodError` naming neither the scope asked for nor the source.
      # `lain survey` reaches it on the default scope.
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
      # memoize on itself, so the memo lives in the closure the Enumerator
      # holds -- which also scopes it to this one walk rather than growing a
      # cache keyed by changeset. `enum_for` would re-enter this method per
      # query, and `#size` followed by `#each` then packed the whole changeset
      # twice: {Changeset#files} memoizes, but neither the grouping, the packing
      # walk nor its per-file guard does.
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

      # `limit` rather than `ceiling`, which is what this argument means and was
      # called until {#ceiling} became a method: a parameter shadowing a private
      # method of the same object is one edit away from a collision nobody
      # reading either half would predict. The MESSAGE still says "ceiling",
      # because that is the word the reader was refused by.
      def guard!(measured, limit, unit, subject)
        return if measured <= limit

        raise TooLarge, "#{subject} is #{measured} #{unit}, over the ceiling of #{limit} -- #{yield}"
      end
    end
  end
end
