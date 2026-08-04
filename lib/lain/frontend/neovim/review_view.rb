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
      # TWO SCOPES, and the walk is a requirement rather than a convenience:
      # research §3.7 measured a real work changeset at 81,810 rendered lines
      # cumulatively against 2,727 for one commit, so "scroll the flat list" is
      # not a usable surface at that size. Which scope is on screen is NOT held
      # here -- T13 records that the presented scope is the SURFACE's state --
      # so it rides in as an argument on every render.
      #
      # == What this view may claim about a commit, and what it may not
      #
      # `by_commit` attributes at FILE granularity: the last commit in the range
      # to touch a file gets that file's hunks. Three things follow, and all
      # three are the reader's to know rather than this object's to hide.
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
      #    suppress it: `Changeset::CommitScope` carries no parent count, and its
      #    own doc records that telling a merge apart "is a port change". A
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
      # {Review::Surface}'s class doc is where the `#files` / `#by_commit` duck
      # is stated for every adapter, and this view needs two members it does not
      # name: a file entry's `#hunks` (whose first hunk's `#new_start` is the
      # line an open lands on -- a `Review::Hunk` already answers it) and a
      # commit entry's `#added` / `#deleted`, as SCALARS.
      #
      # Not `#numstat`. That name is already taken and already means something
      # else: `Changeset::CommitScope#numstat` is a frozen `Array` of per-file
      # stats, so `numstat.added` raises. A duck that borrows an occupied name
      # for a different shape is worse than a missing method, because it reads
      # as satisfied -- a T13 session that decorates `CommitScope` and forwards
      # what it does not answer would have crashed this walk. The aggregate
      # belongs on the row object that can honestly supply it.
      #
      # THREAD CONTRACT. {#render} is driven by the surface and {#open} by
      # whichever fiber serves the editor's commands, and they share the
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
        PLACEHOLDERS = { cumulative: "(no files in this changeset)",
                         commits: "(no commits in this changeset)" }.freeze

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

        # `scope:` dispatch, keyed by `Review::SCOPES`' own two spellings as
        # Symbols. `fetch`, never a bare `==`: a typo'd scope must fail loudly
        # rather than fall through to whichever branch happened to be the
        # default. A spec pins these keys against the vocabulary.
        SCOPE_ROWS = { commits: :commit_rows, cumulative: :file_rows }.freeze

        # The walk's one caveat row, and it is caveat-SIZED because the sidebar
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

        # A commit the range attributes no file to -- normal, and the merge case
        # above is why. Rendered rather than left blank so the walk accounts for
        # every commit, and short for {WALK_LEGEND}'s reason.
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

        # One drawn row: what it says, and what it names. `path` is nil for
        # every row that is not a file -- the legend, a commit header, the
        # absorbed-commit note, a placeholder -- which is what makes "this row
        # opens nothing" one check rather than four.
        Row = Data.define(:text, :path, :line)
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

        # The diff pair nobody wired ({InboxView::Unwired}'s honesty, one object
        # over): it answers the one message this view sends it, so no path below
        # asks whether a surface exists -- and it refuses, because a navigator
        # with nowhere to open a file must say so rather than report an open
        # that never happened.
        module Unwired
          module_function

          def open(_path, _line) = "no diff surface is wired to this review, so nothing opens from it"
        end

        # @param changesets [#open] where a resolved row is opened as the diff
        #   pair -- T19's surface, which takes `(path, line)` and answers the
        #   notice saying why it did not open, or nil
        def initialize(changesets: Unwired)
          @changesets = changesets
          @held = [].freeze
          @generation = 0
          @slot = Mutex.new
        end

        # @param changeset [#files, #by_commit] see the class doc
        # @param scope [Symbol] one of `Review::SCOPES` as Symbols; anything
        #   else raises via {SCOPE_ROWS}' `fetch`
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

        def commit_rows(changeset)
          sections = changeset.by_commit.flat_map { |commit| commit_section(commit) }
          sections.empty? ? [] : [plain(WALK_LEGEND), *sections]
        end

        def commit_section(commit)
          nested = commit.files.map { |file| file_row(file, "  ") }
          [commit_header(commit), *(nested.empty? ? [plain(NO_HUNKS_HERE)] : nested)]
        end

        # The figures LEAD, ahead of the subject, for the reason the class doc
        # gives: they are the only numbers on this row that are certainly the
        # commit's own -- with the merge caveat the class doc states and
        # {WALK_LEGEND} points at.
        def commit_header(commit) = plain("+#{commit.added} -#{commit.deleted}  #{legible(commit.subject)}")

        def file_row(file, indent)
          plain("#{indent}#{STATE_MARKERS.fetch(file.state.to_s)} #{legible(file.path)}")
            .with(path: file.path.to_s, line: first_line(file))
        end

        def plain(text) = Row.new(text:, path: nil, line: nil)

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
