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
      # is stated for every adapter, and this view needs three members it does
      # not name: a file entry's `#hunks` (whose first hunk's `#new_start` is the
      # line an open lands on -- a `Review::Hunk` already answers it), and a
      # group entry's `#label` and its `#added` / `#deleted`, as SCALARS.
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
      # == What a row NAMES, and why the keys are cut from the whole changeset
      #
      # A row carries the hunk keys the human is marking when they mark it (T19).
      # The editor cannot send one: a sidebar row renders no key, and a key is a
      # content DIGEST that never crosses the wire in either direction -- so a
      # `review_mark` gesture sends a LINE, and this view is the only object that
      # can say which hunks that line named. Carrying them made {#marks}
      # possible; without them the gesture rail reached the surface and stopped.
      #
      # Cut from `changeset.files` -- the WHOLE file's hunks -- in BOTH scopes,
      # never from the file entry the row was drawn from. `Hunk.keys` is a batch
      # operation by construction ("a hunk cannot tell on its own that it is
      # duplicated"), and a group entry carries only the hunks reachable in that
      # group, so keying that subset can hand a duplicated hunk a
      # different key than the cumulative view gives it -- a mark landing on a
      # key `Marks` never produces. `Marks#states` groups by path over the whole
      # changeset and keys within the group; this does the identical thing, so
      # the two cannot disagree. It also means a nested row means what its
      # marker already means: the WHOLE file, not its part in that group.
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
        NO_STAMP = "the buffer this gesture came from carries no rendering stamp, so nothing has been " \
                   "rendered into #{NAME} yet and line %d names nothing".freeze
        UNISSUED = "#{NAME} was sent a rendering stamp of %<generation>s, which this view never issued -- " \
                   "the gesture did not come from a rendering this view drew".freeze
        UNSHOWN = "#{NAME} is showing rendering %<generation>s, which is not one this view still holds -- " \
                  "it has re-rendered since, so row %<line>d could name two different files and this will " \
                  "not guess between them".freeze
        NO_FILE = "no file on #{NAME} line %d".freeze

        # {NO_FILE}'s sibling, and NOT a reuse of it: a commit header names no
        # file and no hunk, but a file row whose path the changeset carries no
        # hunks for names a file and still nothing to mark. Told apart because
        # the two gestures fail for different reasons and the human is owed the
        # one that happened.
        NO_HUNK = "no hunk on #{NAME} line %d -- nothing on that row can be marked".freeze

        # No hunk keys: every row that is not a file, and the frozen singleton
        # they all share rather than an Array each.
        NO_KEYS = [].freeze

        # One drawn row: what it says, and what it names. `path` is nil for
        # every row that is not a file -- the legend, a commit header, the
        # absorbed-commit note, a placeholder -- which is what makes "this row
        # opens nothing" one check rather than four. `hunk_keys` is {NO_KEYS}
        # for exactly those same rows, and is the row's OTHER identity: what a
        # mark gesture on it means (see the class doc).
        Row = Data.define(:text, :path, :line, :hunk_keys)
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
          return unopened(refused(line, generation)) if rendering.nil?

          row = rendering.at(line)
          row.nil? || row.path.nil? ? unopened(format(NO_FILE, line)) : offer(row)
        end

        # Which of the three things went wrong. `1..@generation` is exactly the
        # set of stamps this view has ever issued, so "never issued" and "issued
        # and since aged out" are told apart by arithmetic rather than by guess.
        def refused(line, generation)
          return format(NO_STAMP, line) if generation.nil?
          return format(UNISSUED, generation: generation.inspect) unless (1..@generation).cover?(generation)

          format(UNSHOWN, generation: generation.inspect, line:)
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
          return unmarked(refused(line, generation)) if rendering.nil?

          row = rendering.at(line)
          keys = row.nil? ? NO_KEYS : row.hunk_keys
          keys.empty? ? unmarked(format(NO_HUNK, line)) : Marked.new(hunk_keys: keys, report: naming(row, keys))
        end

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
        def file_rows(changeset)
          keys = keys_by_path(changeset)
          changeset.files.map { |file| file_row(file, "", keys) }
        end

        # The walk, and the ONE thing that makes it different from any other
        # grouping: its legend, which is a claim about authorship.
        def commit_rows(changeset) = led(grouped_rows(changeset), WALK_LEGEND)

        def led(rows, legend) = rows.empty? ? [] : [plain(legend), *rows]

        def grouped_rows(changeset)
          keys = keys_by_path(changeset)
          changeset.partitions.flat_map { |partition| partition_section(partition, keys) }
        end

        def partition_section(partition, keys)
          nested = partition.files.map { |file| file_row(file, "  ", keys) }
          [partition_header(partition), *(nested.empty? ? [plain(NO_HUNKS_HERE)] : nested)]
        end

        # `Review::Hunk` resolves at CALL time, which is what makes this legal at
        # all: `lain.rb` loads `lain/frontend` first, so the same reference in a
        # class body would not resolve (see {STATE_MARKERS}).
        #
        # Cut from `changeset.files` in every scope -- the class doc says why a
        # group entry's own subset cannot be keyed. A path the flat view
        # does not carry gets {NO_KEYS} and its row refuses the gesture by name,
        # rather than being handed keys cut from a narrower batch.
        def keys_by_path(changeset)
          changeset.files.to_h { |file| [file.path.to_s, Review::Hunk.keys(file.hunks)] }
        end

        # The figures LEAD, ahead of the label, for the reason the class doc
        # gives: for a commit they are the only numbers on this row that are
        # certainly the commit's own -- with the merge caveat the class doc
        # states and {WALK_LEGEND} points at.
        def partition_header(group) = plain("+#{group.added} -#{group.deleted}  #{legible(group.label)}")

        def file_row(file, indent, keys)
          path = file.path.to_s
          plain("#{indent}#{STATE_MARKERS.fetch(file.state.to_s)} #{legible(file.path)}")
            .with(path:, line: first_line(file), hunk_keys: keys.fetch(path, NO_KEYS))
        end

        def plain(text) = Row.new(text:, path: nil, line: nil, hunk_keys: NO_KEYS)

        # Where an open lands. A file entry always carries hunks in practice --
        # `group_by` yields no empty group -- but a private method is still a
        # promise to whatever calls it next, so a hunkless entry opens at the
        # top of the file rather than raising on the editor's fiber.
        def first_line(file) = file.hunks.first&.new_start || 1

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
