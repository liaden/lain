# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # `lain://review`, the changeset review's NAVIGATOR (T14): the sidebar the
      # diff pair is opened from. {InboxView}'s shape -- plain lines out, a
      # line -> identity index built by the same pass that drew them, a gesture
      # resolved through that index -- and never nvim itself; `runtime/46_sidebar.lua`
      # does the rendering.
      #
      # A FLAT scope and a GROUPED one, and the grouping is a requirement rather
      # than a convenience: research §3.7 measured a real work changeset at
      # 81,810 rendered lines cumulatively against 2,727 for one commit, so
      # "scroll the flat list" is not a usable surface at that size. Which scope
      # is on screen is NOT held here -- T13 records that the presented scope is
      # the SURFACE's state -- so it rides in as an argument on every render.
      #
      # == What this view may claim about a COMMIT group, and what it may not
      #
      # {Review::Partition::ByCommit} attributes at FILE granularity: the last
      # commit in the range to touch a file gets that file's hunks. Three things
      # follow, and all three are the reader's to know rather than this object's
      # to hide. None of them is true of a grouping that is not the walk, which
      # is why {WALK_LEGEND} heads that scope and only that one.
      #
      # 1. It is not per-hunk provenance, and with a MERGE in the range it is
      #    not even close -- the merge absorbs every file it re-reports and the
      #    authoring commits come back with `files: []` (the T7 panel measured 3
      #    commits with 2 of 3 blank). So the files under a commit are the hunks
      #    REACHABLE there, which is all they are, and a commit that reaches none
      #    says so ({NO_HUNKS_HERE}) rather than rendering as a subject with
      #    nothing beneath it.
      # 2. A merge's own numstat is the WHOLE SIDE BRANCH (`Changeset` runs
      #    `--diff-merges=first-parent`), so `+9 -9  Merge branch 'side'` can
      #    outrank the commit that actually wrote the code. This view cannot
      #    suppress it: `Source::Commit` carries no parent count, and
      #    {Review::Partition::ByCommit}'s doc records that telling a merge apart
      #    "is a port change". A
      #    subject matching /^Merge/ is a guess, not a fact, and this codebase
      #    does not ship those.
      # 3. The tri-state marker on a nested file row is that file's WHOLE
      #    CHANGESET state, not its state within that commit. The two coincide
      #    only because attribution is file-granular, so they will part company
      #    the day it is not.
      #
      # {WALK_LEGEND} carries what fits in a 40-column navigator, which is a
      # pointer and one clause; `:h lain://review` is where all three live, because
      # a caveat that costs four of the first five rows is not a navigator.
      #
      # == The changeset duck
      #
      # {Review::Surface}'s class doc is where the `#files` / `#partitions` duck
      # is stated for every adapter, and this view needs five members it does
      # not name. A file entry's `#hunk_keys`, `#chunked?` and `#hunks` (whose
      # first hunk's `#new_start` is the line an open lands on -- a
      # `Review::Hunk` already answers it, and `#chunked?` is what says whether
      # asking is affordable); a group entry's `#counted?` with its
      # `#added` / `#deleted` or its `#rendered_lines`, all as SCALARS.
      # {Review::Session::MarkedChangeset}'s two rows are what answer them.
      #
      # Not `#numstat`. That name is already taken and already means something
      # else: `Partition::ByCommit::Commit#numstat` is a frozen `Array` of
      # per-file stats, so `numstat.added` raises. A duck that borrows an
      # occupied name for a different shape is worse than a missing method,
      # because it reads as satisfied -- a T13 session that decorated the
      # detail and forwarded what it does not answer would have crashed this
      # walk. The aggregate belongs on the row object that can honestly supply
      # it, which is where it now lives.
      #
      # == Drawing costs only what the review has already read
      #
      # Three reads in this class used to force every file's hunks on every
      # render, in BOTH scopes -- the heading's `+n -m`, the key table, and the
      # line an open lands on. Over a diff that is free, because a parser
      # produces a file's hunks with the file. Over a {Review::Source::Corpus}
      # it chunked the whole survey the moment the sidebar was drawn, which is
      # precisely the cost that arm exists to defer, and it undid the laziness
      # {Review::Bounds} and {Review::Session} had already been taught. All
      # three now ask the ROW, which knows without reading.
      #
      # == What a heading may claim about a group nobody has read
      #
      # `+n -m` is a COUNT, and a count of a group nobody has read cannot be
      # taken without reading it. Rendering `+0 -0` instead would be a zero that
      # silently means "unknown" -- the reading the partition chunk's Open
      # decisions already refused once. So the group says whether its figures
      # are real (`#counted?`), and a heading that cannot count claims the SIZE
      # the survey's identity pass already measured ({UNREAD_SIZE}), which is a
      # different quantity written in a different form.
      #
      # The switch is all-or-nothing per group rather than per file, because
      # `+n -m` summed over the read SUBSET of a group is an undercount wearing
      # a count's spelling -- the same defect one step smaller.
      #
      # == What a row NAMES, and why the keys come off the row
      #
      # A row carries the hunk keys the human is marking when they mark it (T19).
      # The editor cannot send one: a sidebar row renders no key, and a key is a
      # content DIGEST that never crosses the wire in either direction -- so a
      # `review_mark` gesture sends a LINE, and this view is the only object that
      # can say which hunks that line named. Carrying them made {#marks}
      # possible; without them the gesture rail reached the surface and stopped.
      #
      # They are READ off the entry rather than derived here, and the invariant
      # that used to justify deriving them is now structural. `Hunk.keys` is a
      # batch operation by construction ("a hunk cannot tell on its own that it
      # is duplicated"), and a group entry carries only the hunks reachable in
      # that group -- so keying that subset can hand a duplicated hunk a
      # different key than the cumulative view gives it, a mark landing on a key
      # `Marks` never produces. This view used to close that by re-keying
      # `changeset.files` on every render, at the cost above.
      # {Review::Session::MarkedChangeset} builds ONE row per file and a
      # partition holds the very same object, so a nested row's keys ARE the
      # whole file's and there is no second derivation left to disagree. A row
      # that names no key refuses the gesture by name ({NO_HUNK}), which is also
      # what a file nobody has read answers.
      #
      # THREAD CONTRACT. {#render} is driven by the surface and {#open}/{#marks}
      # by whichever fiber serves the editor's commands, and they share the
      # rendering history the second resolves through -- so both take one
      # `Mutex`, {InboxView}'s `@slot` for {InboxView}'s reason: a check-then-act
      # across this seam does not fail loudly, it opens the wrong file. There is
      # no `#generation` reader to pair with {#render}, deliberately: two atomic
      # reads are not an atomic pair, and the only stamp anyone can obtain is the
      # one {Rendered} hands back with the lines it belongs to. Nothing under the
      # lock waits on the editor -- `@changesets.open` is the non-blocking
      # refuse-a-full-queue path, and nothing on the far side calls back here.
      class ReviewView
        NAME = "lain://review"

        # What a scope renders when it finds nothing, keyed like {SCOPE_ROWS} so
        # each says what THAT scope looked for. One shared "(no changeset under
        # review)" was wrong in the case that actually happens: a changeset with
        # files but an empty walk announced that there was no changeset at all.
        PLACEHOLDERS = { cumulative: "(no files in this changeset)", commits: "(no commits in this changeset)",
                         by_directory: "(no directories in this changeset)" }.freeze

        # One glyph per canonical file state, and a LITERAL table rather than
        # `Review::FILE_STATES.to_h { ... }` -- which is what {Surface::Text}
        # does one layer down and is the better shape. It cannot be done here:
        # `lain.rb` loads `lain/frontend` BEFORE `lain/review`, so the constant
        # is not resolvable while this class body runs. The spec pins these keys
        # against `Review::FILE_STATES` instead, which is the same guarantee
        # bought a line later.
        #
        # `#file_row` looks up `state.to_s`, so a Symbol reads as readily as the
        # canonical String -- `Surface::Text`'s own tolerance, for its reason: a
        # `Marks#states` Hash answers Symbols and every journaled record stores
        # the String.
        STATE_MARKERS = { "reviewed" => "[x]", "partial" => "[~]", "unreviewed" => "[ ]" }.freeze

        # `scope:` dispatch, keyed by the NAME of each {Review::Partition}
        # strategy. `fetch`, never a bare `==`: a scope nothing declares must
        # fail loudly rather than fall through to whichever branch happened to
        # be the default, and the `KeyError` names what was asked for.
        #
        # `:commits` gets its own entry rather than sharing `:by_directory`'s,
        # and the difference is one row: {WALK_LEGEND} is a caveat about
        # AUTHORSHIP, which is a claim only the commit walk makes. A spec pins
        # completeness -- every registered strategy resolves here.
        SCOPE_ROWS = { cumulative: :file_rows, commits: :commit_rows, by_directory: :grouped_rows }.freeze

        # The COMMIT walk's one caveat row -- no other grouping claims
        # authorship, so no other scope carries it. Caveat-SIZED because the sidebar
        # is 40 columns (`41_layout`'s `lain_review_sidebar_width` default). The
        # honest full statement is three clauses long and wrapped to four screen
        # rows at the top of every render, which spends a navigator's most
        # valuable space on prose; so the line carries the clause a reader must
        # not miss and points at the help tag carrying the rest -- an EXISTING
        # tag (`*lain://review*`, which 6.4 defines), never a new one invented
        # here: `helptags` indexes what a doc DEFINES and never what it
        # references, so a legend pointing at a tag nobody wrote answers E149
        # the moment a human follows it. A spec pins the width against that
        # default and the target against the doc.
        WALK_LEGEND = "-- not authored here: :h lain://review"

        # A group the range attributes no file to -- normal for a commit, and the
        # merge case above is why. Rendered rather than left blank so the walk
        # accounts for every commit, and short for {WALK_LEGEND}'s reason.
        NO_HUNKS_HERE = "  (no hunks reachable here)"

        # What a heading claims where `+n -m` would be a lie -- see the class
        # doc's "What a heading may claim about a group nobody has read".
        #
        # `~` and the WORD `lines`, so it cannot be read as the pair it replaces:
        # a `+0 -0` meaning "unknown" is the rendered zero the partition chunk's
        # Open decisions refused once already, and a bare number in that column
        # would be the same mistake spelled differently.
        #
        # `~` reads as "approximately" and the figure is stricter than that: a
        # ONE-SIDED bound, and on a different measure. `rendered_lines` bounds a
        # hunk's body plus one line per unit ({Review::Source::Corpus} over-
        # measures deliberately, and `added` counts only added lines), so the
        # same unchanged group goes `~172 lines` -> `+144 -0` on being read --
        # measured, 19% apart. Wrong only in the direction that cannot let an
        # oversized view through, which is why the glyph stays a tilde rather
        # than becoming a claim of equality.
        UNREAD_SIZE = "~%d lines"

        # How many renderings stay resolvable. {InboxView::Renderings::HELD}'s
        # number and its reasoning: this is a MEMORY bound, not a correctness
        # one, because the stamp -- not the line count -- is what identifies a
        # rendering. A forgotten rendering is refused BY NAME; it never aliases
        # onto a later one of equal height.
        HELD = 16

        # THREE sentences for three different events, not one for all of them.
        # The first cut had two and told the other two cases the third's story:
        # a buffer nothing has ever rendered into carries NO stamp (a nil value
        # drops its key from a lua table entirely, so `{ line, nil }` reaches
        # Ruby as a one-element array -- `runtime/65_review.lua` records being
        # bitten by exactly that), and a stamp this view never issued is a wire
        # or caller fault. Neither is "it has re-rendered since", which is a
        # true and specific claim about a stamp that WAS issued and has since
        # aged out of {HELD}.
        #
        # All three are pinned under `spec/refusal_width_discipline_spec.rb`'s
        # bar, which is what took them from 131/140/194 rendered characters to
        # here: they ride the echo rail, and the message area is one line wide.
        # Each keeps its CONDITION and its REMEDY and gives up the explanation
        # in between -- the reasoning above is where a reader who wants it goes.
        # `%<line>d` left {UNSHOWN} for that: the row is under the human's
        # cursor, so naming it back cost width and told them nothing.
        NO_STAMP = "this gesture carries no rendering stamp -- render #{NAME} first".freeze
        UNISSUED = "#{NAME} never issued rendering %<generation>s -- press again on a drawn row".freeze
        UNSHOWN = "#{NAME} re-rendered since %<generation>s -- press again on the row you want".freeze
        NO_FILE = "no file on #{NAME} line %d".freeze

        # {NO_FILE}'s sibling, and NOT a reuse of it: a commit header names no
        # file and no hunk, but a file row whose path the changeset carries no
        # hunks for names a file and still nothing to mark. Told apart because
        # the two gestures fail for different reasons and the human is owed the
        # one that happened.
        NO_HUNK = "no hunk on #{NAME} line %d -- nothing on that row can be marked".freeze

        # {NO_HUNK}'s third case, and the one that is TRANSIENT. A commit header
        # will never name a hunk and a binary file will never have one; a
        # surveyed file has none only until somebody opens it, and the remedy is
        # one keystroke. That is {NO_HUNK}'s own rule applied once more -- the
        # gestures fail for different reasons and the human is owed the one that
        # happened -- over the distinction {Review::Session::MarkedChangeset}
        # already keeps one layer down, where "read, and there is nothing" and
        # "nobody has read it" are deliberately two facts rather than one glyph.
        # Told "there is nothing here", a human stops looking.
        UNREAD = "#{NAME} line %<line>d names %<path>s, which nothing has read -- open it with <CR> first".freeze

        # No hunk keys: every row that is not a file, and the frozen singleton
        # they all share rather than an Array each.
        NO_KEYS = [].freeze

        # One drawn row: what it says, and what it names. `path` is nil for
        # every row that is not a file -- the legend, a commit header, the
        # absorbed-commit note, a placeholder -- which is what makes "this row
        # opens nothing" one check rather than four. `hunk_keys` is {NO_KEYS}
        # for exactly those same rows, and is the row's OTHER identity: what a
        # mark gesture on it means (see the class doc).
        #
        # `read` is nil on those same rows and a Boolean on a file's -- the
        # file's own `#chunked?`, under the word a navigator uses for it. It is
        # carried for one reason: an empty `hunk_keys` has two causes and they
        # are owed different sentences ({UNREAD} against {NO_HUNK}). The row is
        # the only place that fact survives the render.
        Row = Data.define(:text, :path, :line, :hunk_keys, :read)
        private_constant :Row

        # One rendering, as a gesture has to read it back: the STAMP the
        # editor's buffer carries for it, and which row sits on each line.
        Rendering = Data.define(:generation, :rows) do
          # The 1-based/0-based seam, guarded here rather than at the caller:
          # line 0 would index -1, which is the LAST row -- a cursor nvim never
          # reports would silently open the bottom file.
          def at(line) = line.positive? ? rows[line - 1] : nil
        end
        private_constant :Rendering

        # {#render}'s whole answer: the buffer, and the stamp THOSE lines are to
        # be posted under. One value rather than a method pair, so a caller
        # cannot post rendering N's lines beneath rendering N+1's stamp -- which
        # a `#generation` reader alongside `#render` makes possible however
        # carefully each one is locked, since two atomic reads are not an atomic
        # pair. `RenderInlet#set_review` wants both anyway.
        Rendered = Data.define(:lines, :generation)

        # What the `<CR>` gesture opened, or the reason none did:
        # {InboxView::Opened}'s shape for its reason -- this object touches
        # neither nvim nor stdio, so "report the failure" can only mean "hand it
        # back". `path` is nil exactly when nothing opened.
        Opened = Data.define(:path, :line, :report) do
          def opened? = !path.nil?
        end

        # {Opened}'s shape for the OTHER gesture: which hunks the marked row
        # named, or the reason it named none. `hunk_keys` is empty exactly when
        # nothing was marked, so `marked?` is one check rather than a nil test,
        # and it is spelled as {Row}'s own member rather than `keys` -- which
        # reads as a Hash's, both to a human and to `Style/HashEachMethods`.
        Marked = Data.define(:hunk_keys, :report) do
          def marked? = !hunk_keys.empty?
        end

        # The diff pair nobody wired ({InboxView::Unwired}'s honesty, one object
        # over): it answers the two messages this view sends it, so no path below
        # asks whether a surface exists -- and it refuses, because a navigator
        # with nowhere to open a file must say so rather than report an open
        # that never happened.
        #
        # Its sentence is the ACCEPTANCE TEST for T32a and is read as one by
        # `spec/lain/frontend/neovim_spec.rb`: after that card it must be
        # unreachable from a review drawn in a real editor -- {Neovim#review_view}
        # supplies a {ChangesetDiff} -- and still be what a view built with no
        # diff surface at all answers.
        module Unwired
          module_function

          def open(_path, _line) = "no diff surface is wired to this review, so nothing opens from it"

          # Nothing to hold a changeset for, and this is a no-op rather than a
          # refusal: naming the round is not a gesture a human made, so there is
          # nobody to tell.
          def reviewing(_changeset) = nil
        end

        # @param changesets [#open, #reviewing] where a resolved row is opened as
        #   the diff pair -- {ChangesetDiff}, which takes `(path, line)` and
        #   answers the notice saying why it did not open, or nil
        def initialize(changesets: Unwired)
          @changesets = changesets
          @held = [].freeze
          @generation = 0
          @slot = Mutex.new
        end

        # @param changeset [#files, #partitions] see the class doc
        # @param scope [Symbol] the name of a {Review::Partition} strategy as a
        #   Symbol; anything else raises via {SCOPE_ROWS}' `fetch`
        # @return [Rendered] the whole buffer and the stamp it must be posted
        #   under, which is `RenderQueue::SET_REVIEW`'s second argument --
        #   REQUIRED there rather than optional as `SET_VIEW`'s is, because a
        #   sidebar row moves the moment the scope toggles
        def render(changeset, scope:)
          rows = send(SCOPE_ROWS.fetch(scope), changeset)
          rows = [plain(PLACEHOLDERS.fetch(scope))] if rows.empty?
          @slot.synchronize do
            remember(rows)
            Rendered.new(lines: rows.map(&:text), generation: @generation)
          end
        end

        # Which changeset the rows this view draws BELONG to, forwarded to the
        # diff surface a `<CR>` opens through.
        #
        # It is not held here, and that is the point of forwarding rather than
        # keeping: this view's state is the rendering HISTORY, and a changeset
        # kept beside it would be a second answer to "what is under review" free
        # to disagree with the rows. The diff surface holds exactly one thing and
        # this is it.
        #
        # Sent by whoever opened the round -- {CLI::Command::Review#handover} and
        # {Tools::RequestReview::Implementation#handover}, the two rails that
        # build a {Review::Handover} -- because the editor's view pair is built
        # when the frontend attaches and a review is opened long afterwards.
        # Under {#render}'s own lock for {#render}'s reason: a gesture resolving
        # a row while the round is being replaced must see one round or the
        # other, never a rendering of one against the changeset of the next.
        #
        # @param changeset [Review::Changeset] the round the sidebar now shows
        # @return [void] whatever the diff surface answered, which is nothing on
        #   both implementations of that duck
        def reviewing(changeset) = @slot.synchronize { @changesets.reviewing(changeset) }

        # The `<CR>` gesture from lain://review (`runtime/46_sidebar.lua`): open
        # the file the cursor sits on, at its first reachable hunk. The LINE
        # rides -- the recorded rule, never a hunk key -- with the GENERATION
        # stamped on the buffer the human is looking at, because a line number
        # alone names a POSITION and these positions move every time the scope
        # toggles or a mark redraws a row.
        #
        # @param line [Integer] 1-based, as nvim's cursor reports it
        # @param generation [Integer, nil] b:lain_view_generation off that
        #   buffer; nil when the buffer carries none
        # @return [Opened]
        def open(line, generation:)
          @slot.synchronize { resolve(line, generation) }
        end

        # The mark gesture from the same sidebar (`["review_mark", [line, state,
        # generation]]`): which hunks does the row on this line name? {#open}'s
        # shape and every one of its reasons -- the line rides because a row
        # renders no key, the stamp rides because the row moves -- and the same
        # three refusals, because a stamp this view cannot resolve is the same
        # fact for both gestures.
        #
        # It RESOLVES and applies nothing. Recording a mark is the session's,
        # via T19's surface, so this stays a query over the rendering history
        # and the lock never spans a write to the review model.
        #
        # @param line [Integer] 1-based, as nvim's cursor reports it
        # @param generation [Integer, nil] b:lain_view_generation off that buffer
        # @return [Marked]
        def marks(line, generation:)
          @slot.synchronize { resolve_marks(line, generation) }
        end

        private

        def resolve(line, generation)
          rendering = @held.find { |held| held.generation == generation }
          return unopened(refused(generation)) if rendering.nil?

          row = rendering.at(line)
          row.nil? || row.path.nil? ? unopened(format(NO_FILE, line)) : offer(row)
        end

        # Which of the three things went wrong. `1..@generation` is exactly the
        # set of stamps this view has ever issued, so "never issued" and "issued
        # and since aged out" are told apart by arithmetic rather than by guess.
        def refused(generation)
          return NO_STAMP if generation.nil?
          return format(UNISSUED, generation: generation.inspect) unless (1..@generation).cover?(generation)

          format(UNSHOWN, generation: generation.inspect)
        end

        def offer(row)
          refusal = @changesets.open(row.path, row.line)
          return unopened(refusal) unless refusal.nil?

          Opened.new(path: row.path, line: row.line, report: "opened #{row.path}:#{row.line}")
        end

        def unopened(report) = Opened.new(path: nil, line: nil, report:)

        # {#resolve}'s twin. A row this view never drew and a row that names no
        # hunk both answer nothing to mark; they differ in the sentence, which
        # is the whole reason {#refused} exists.
        def resolve_marks(line, generation)
          rendering = @held.find { |held| held.generation == generation }
          return unmarked(refused(generation)) if rendering.nil?

          row = rendering.at(line)
          keys = row.nil? ? NO_KEYS : row.hunk_keys
          keys.empty? ? unmarked(unmarkable(row, line)) : Marked.new(hunk_keys: keys, report: naming(row, keys))
        end

        # Which of the two reasons this row names no unit -- see {UNREAD}.
        # `== false` rather than a negation: `read` is nil for every row that is
        # not a file at all (and `row` itself is nil for a line naming none),
        # and all of those keep {NO_HUNK}.
        def unmarkable(row, line) = row&.read == false ? format(UNREAD, path: row.path, line:) : format(NO_HUNK, line)

        def unmarked(report) = Marked.new(hunk_keys: NO_KEYS, report:)

        def naming(row, keys) = "#{keys.size} hunk(s) of #{row.path}"

        # Newest first, bounded, and stamped with a generation that never
        # repeats -- a stamp that repeated would name two different files on one
        # row, which is the defect it exists to close.
        def remember(rows)
          @generation += 1
          @held = [Rendering.new(generation: @generation, rows: rows.freeze), *@held].first(HELD).freeze
        end

        # The lines and the line -> target index are ONE pass' two outputs: a
        # Row carries both, so an index built by a SECOND walk cannot disagree
        # with the rendering the first time either changes.
        def file_rows(changeset) = changeset.files.map { |file| file_row(file, "") }

        # The walk, and the ONE thing that makes it different from any other
        # grouping: its legend, which is a claim about authorship.
        def commit_rows(changeset) = led(grouped_rows(changeset), WALK_LEGEND)

        def led(rows, legend) = rows.empty? ? [] : [plain(legend), *rows]

        def grouped_rows(changeset)
          changeset.partitions.flat_map { |partition| partition_section(partition) }
        end

        def partition_section(partition)
          nested = partition.files.map { |file| file_row(file, "  ") }
          [partition_header(partition), *(nested.empty? ? [plain(NO_HUNKS_HERE)] : nested)]
        end

        # The figures LEAD, ahead of the label, for the reason the class doc
        # gives: for a commit they are the only numbers on this row that are
        # certainly the commit's own -- with the merge caveat the class doc
        # states and {WALK_LEGEND} points at.
        def partition_header(group) = plain("#{accounting(group)}  #{legible(group.label)}")

        # {UNREAD_SIZE} or the pair, and the group decides -- see the class doc.
        def accounting(group)
          return format(UNREAD_SIZE, group.rendered_lines) unless group.counted?

          "+#{group.added} -#{group.deleted}"
        end

        def file_row(file, indent)
          plain("#{indent}#{STATE_MARKERS.fetch(file.state.to_s)} #{legible(file.path)}")
            .with(path: file.path.to_s, line: first_line(file), hunk_keys: file.hunk_keys, read: file.chunked?)
        end

        def plain(text) = Row.new(text:, path: nil, line: nil, hunk_keys: NO_KEYS, read: nil)

        # Where an open lands. A row nobody has read has no hunk to land on and
        # must not be chunked to find that out, so it answers 1 -- the same
        # answer a hunkless entry has always got, for the same reason: there is
        # no first hunk. A file entry that HAS been read always carries hunks in
        # practice (`group_by` yields no empty group), but a private method is
        # still a promise to whatever calls it next.
        #
        # It is not a promise of a line >= 1, and never was: a DELETED file's
        # first hunk has `new_start` 0, and `0 || 1` is 0 in Ruby. That reaches
        # the editor, where `47_diff.lua` clamps with `math.max(1, ...)`. So
        # "opens at the top of the file" is true of what a human sees and not of
        # what this returns; the clamp is the editor's and is where to look if a
        # deleted file ever opens somewhere surprising.
        def first_line(file) = (file.chunked? && file.hunks.first&.new_start) || 1

        # `Surface::Text#legible`'s force-encode-and-scrub, and its doc is where
        # the reasoning lives: git answers BYTES, a rendering is not the diff
        # itself, and a String that is not validly UTF-8 breaks things far from
        # here. Display only -- the TARGET keeps `file.path`'s own bytes, since
        # that is what has to name a file on disk.
        def legible(string) = string.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
      end
    end
  end
end
