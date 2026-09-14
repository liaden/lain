# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# `lain://review`, the changeset review's navigator -- the scopes it
# renders, the line -> target map it builds in the same pass, and the gesture it
# resolves against the rendering the human is actually looking at.
#
# The changeset duck is the one `Lain::Review::Surface`'s class doc states
# (`#files` / `#partitions`), plus the members that doc does not name and this
# view needs -- a file entry's `#hunks`, `#hunk_keys` and `#chunked?`, a group
# entry's `#counted?` with its `#added`/`#deleted` or its `#rendered_lines`.
# `Lain::Review::Session::MarkedChangeset` answers all of them now, and the
# doubles here stay because they can be parted where a real row's members
# always agree -- which is what tells a view reading a row from one deriving a
# second answer of its own.
RSpec.describe Lain::Frontend::Neovim::ReviewView do
  subject(:view) { described_class.new(changesets: opener) }

  let(:opener) { recorder }

  # `Surface::Text`'s own spec idiom for the same unlanded ducks: anonymous
  # Structs, so nothing here pretends to be the real object.
  # `old_start` is deliberately NOT `new_start`: an open lands on the NEW side,
  # and a fixture where the two agree cannot tell a correct view from one
  # reading the wrong side of the hunk.
  def hunk(new_start:, path: "lib/a.rb")
    Lain::Review::Hunk.new(path:, old_start: new_start + 500, old_count: 1, new_start:, new_count: 1,
                           lines: [" x"])
  end

  # A file the review has READ: `#hunk_keys` is what a mark gesture on its row
  # names, derived ONCE by the join and carried, and `#chunked?` says the hunks
  # are already in hand. `keys:` is separable from `hunks:` on purpose -- the
  # two are equal on every real row, and a fixture that could not part them
  # could not tell a view reading the row from one re-deriving keys off the
  # hunks it was handed.
  def file_entry(path:, state: "unreviewed", first: 1, hunks: nil, keys: nil, lines: 3)
    hunks ||= [hunk(path:, new_start: first)]
    Struct.new(:path, :state, :hunks, :hunk_keys, :rendered_lines) do
      def chunked? = true
    end.new(path, state, hunks, keys || Lain::Review::Hunk.keys(hunks), lines)
  end

  # A file a survey has LISTED and nothing has read. `#hunks` raises, which is
  # the honest way to assert that drawing it read nothing -- a counting spy
  # passes just as well against a view that walks and discards the answer.
  def unread_entry(path:, state: "unreviewed", lines: 3)
    Struct.new(:path, :state, :hunk_keys, :rendered_lines) do
      def chunked? = false
      def hunks = raise("#{path} was chunked to draw a row that shows no hunk")
    end.new(path, state, [].freeze, lines)
  end

  # `#added` / `#deleted` as SCALARS on the group entry, and NOT reached
  # through `#numstat`. `Partition::ByCommit::Commit#numstat` is a frozen Array
  # of per-file stats, so it answers neither -- a double that invented an
  # aggregate behind that name would read as satisfied while the real object
  # crashed the walk. The `numstat:` member is carried here in its REAL shape so
  # the two facts sit side by side in the fixture.
  #
  # `#counted?` is the group's own answer to whether `#added`/`#deleted` are
  # real, and `#rendered_lines` the size it claims when they are not.
  def commit_entry(subject:, files:, added: 1, deleted: 0, stats: [], counted: true, lines: 0)
    Struct.new(:label, :files, :numstat, :added, :deleted, :counted, :rendered_lines) do
      def counted? = counted
    end.new(subject, files, stats.freeze, added, deleted, counted, lines)
  end

  def file_stat(path:, added:, deleted:) = Struct.new(:path, :added, :deleted).new(path, added, deleted)

  def changeset(files: [], commits: [])
    Struct.new(:files, :partitions).new(files, commits)
  end

  # Where a resolved row is actually opened -- {ReviewView::Unwired}'s duck,
  # recording what it was asked for so "no file is opened" is an observation
  # rather than a tautology.
  def recorder(answer: nil)
    calls = []
    rounds = []
    Object.new.tap do |port|
      port.define_singleton_method(:calls) { calls }
      port.define_singleton_method(:rounds) { rounds }
      port.define_singleton_method(:open) { |path, line| calls.push([path, line]) && answer }
      port.define_singleton_method(:reviewing) { |changeset| rounds.push(changeset) && nil }
    end
  end

  describe "the scopes it renders" do
    let(:five_files) do
      %w[lib/a.rb lib/b.rb lib/c.rb lib/d.rb lib/e.rb].map { |path| file_entry(path:) }
    end

    it "renders one row per file at cumulative scope" do
      rendered = view.render(changeset(files: five_files), scope: :cumulative)

      expect(rendered.lines)
        .to eq(["[ ] lib/a.rb", "[ ] lib/b.rb", "[ ] lib/c.rb", "[ ] lib/d.rb", "[ ] lib/e.rb"])
    end

    it "renders one row per commit with that commit's files beneath at commit scope" do
      commits = [commit_entry(subject: "Add the thing", files: five_files.first(3), added: 12, deleted: 3),
                 commit_entry(subject: "Fix the other", files: five_files.last(2), added: 4, deleted: 0)]

      rendered = view.render(changeset(files: five_files, commits:), scope: :commits)

      expect(rendered.lines).to eq([described_class::WALK_LEGEND,
                                    "+12 -3  Add the thing",
                                    "  [ ] lib/a.rb", "  [ ] lib/b.rb", "  [ ] lib/c.rb",
                                    "+4 -0  Fix the other",
                                    "  [ ] lib/d.rb", "  [ ] lib/e.rb"])
    end

    # A review panel's measurement: with a merge in the range, the commit walk
    # attributes at FILE granularity and the merge absorbs every file it
    # re-reports, so the authoring commits come back with `files: []`. Two of
    # three scopes blank is what that looks like, and a walk that renders them
    # as nothing at all defeats its own purpose.
    it "renders a commit whose files are all absorbed elsewhere, naming why it lists none" do
      commits = [commit_entry(subject: "Merge branch 'side'", files: [file_entry(path: "lib/a.rb")],
                              added: 9, deleted: 9),
                 commit_entry(subject: "the side branch's own commit", files: [], added: 9, deleted: 0)]

      rendered = view.render(changeset(commits:), scope: :commits)

      expect(rendered.lines).to include("+9 -0  the side branch's own commit", described_class::NO_HUNKS_HERE)
    end

    it "refuses a scope no strategy declares" do
      expect { view.render(changeset, scope: :cumulatve) }.to raise_error(KeyError)
    end

    # The completeness law that replaced a literal equality against
    # a two-member scope vocabulary: what has to hold is that every strategy anybody can be
    # handed HAS a rendering here, which a two-member equality stopped saying
    # the moment a third strategy shipped.
    it "declares rows for every registered partition strategy" do
      expect(described_class::SCOPE_ROWS.keys).to include(*Lain::Review::Partition::STRATEGIES.keys)
    end

    it "resolves a real private renderer for each, so a name alone is not enough" do
      expect(described_class::SCOPE_ROWS.values)
        .to all(satisfy { |renderer| described_class.private_method_defined?(renderer) })
    end

    it "refuses a strategy it declares no rows for, naming it" do
      expect { view.render(changeset, scope: :by_size) }.to raise_error(KeyError, /by_size/)
    end

    # The ONE reason `:commits` and `:by_directory` have separate entries.
    # WALK_LEGEND is a claim about AUTHORSHIP, which only the commit walk makes;
    # rendering it over a directory grouping is a lie about who wrote what. The
    # completeness law cannot catch a `by_directory: :commit_rows` mutant,
    # because `commit_rows` is a real method that resolves.
    it "renders a directory grouping with its labels and WITHOUT the walk's authorship legend" do
      groups = [commit_entry(subject: "lib", files: [file_entry(path: "lib/a.rb")], added: 2, deleted: 1),
                commit_entry(subject: "spec", files: [file_entry(path: "spec/a_spec.rb")], added: 4, deleted: 0)]

      rendered = view.render(changeset(commits: groups), scope: :by_directory)

      expect(rendered.lines).to eq(["+2 -1  lib", "  [ ] lib/a.rb", "+4 -0  spec", "  [ ] spec/a_spec.rb"])
      expect(rendered.lines).not_to include(described_class::WALK_LEGEND)
    end

    it "still heads the commit walk with it, so flat and grouped are not one renderer" do
      groups = [commit_entry(subject: "Add the thing", files: [file_entry(path: "lib/a.rb")])]

      expect(view.render(changeset(commits: groups), scope: :commits).lines)
        .to start_with(described_class::WALK_LEGEND)
    end
  end

  # A corpus surveyed from OUTSIDE the project root -- `/survey
  # <absolute path>` when the walked tree merely sits beside the chat's cwd --
  # names every file with a `../../..` climb ahead of its own path
  # (`Review::Source::Corpus::Prefix.between`), so a row rendered verbatim
  # reads as a parent-directory traversal instead of a name.
  describe "a row named for a survey outside the project root" do
    let(:files) { [file_entry(path: "../../../etc/foo/bar.rb", first: 1)] }

    it "drops the climb from what is drawn" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      expect(rendered.lines).to eq(["[ ] etc/foo/bar.rb"])
    end

    # The RESOLUTION key must not move with the display: `<CR>` still has to
    # open the exact string the corpus named the file by, which is what
    # `47_diff.lua`'s old-side buffer resolves against the editor's own cwd.
    it "still opens the file by the climbing path the corpus named it with" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      view.open(1, generation: rendered.generation)

      expect(opener.calls).to eq([["../../../etc/foo/bar.rb", 1]])
    end

    it "leaves an in-project path exactly as it was drawn before" do
      rendered = view.render(changeset(files: [file_entry(path: "lib/a.rb")]), scope: :cumulative)

      expect(rendered.lines).to eq(["[ ] lib/a.rb"])
    end

    # A KNOWN LIMITATION, pinned rather than left to a hand-back: `Corpus::Prefix.between`
    # (cwd `/p/docs`, surveyed root `/p/lib`) names this file `../lib/greeter.rb` -- climbing
    # to the shared ancestor and back down into the surveyed root's own directory before the
    # file's own root-relative name. Stripping only the LEADING `..` run leaves `lib/greeter.rb`,
    # which reads as -- and is indistinguishable from -- an ordinary IN-PROJECT row, even though
    # this file is not under the project at all. A true root-relative name (`greeter.rb`) would
    # need `walk.root` itself threaded into `#render`, which is out of this view's single-file
    # scope. Only the fully-disjoint case (no shared ancestor, this describe block's other
    # examples) and the fully-nested case (an in-project survey) render exactly root-relative.
    it "still reads as an in-project path when the surveyed root shares a partial ancestor with cwd" do
      partial = [file_entry(path: "../lib/greeter.rb", first: 1)]

      rendered = view.render(changeset(files: partial), scope: :cumulative)
      view.open(1, generation: rendered.generation)

      expect(rendered.lines).to eq(["[ ] lib/greeter.rb"])
      expect(opener.calls).to eq([["../lib/greeter.rb", 1]])
    end
  end

  # `partition_header` and `file_row` render the SAME path two different
  # ways for a `by_directory` survey outside the project root -- the header
  # keeps its climb, the file rows beneath it drop theirs. Both must go
  # through the one owner now.
  describe "a by_directory group header, alongside the rows beneath it" do
    it "names the path the same way the file rows beneath it do" do
      groups = [commit_entry(subject: "../../../etc/foo", added: 2, deleted: 1,
                             files: [file_entry(path: "../../../etc/foo/bar.rb")])]

      rendered = view.render(changeset(commits: groups), scope: :by_directory)

      expect(rendered.lines).to eq(["+2 -1  etc/foo", "  [ ] etc/foo/bar.rb"])
    end

    it "still opens the file by the climbing path the corpus named it with" do
      groups = [commit_entry(subject: "../../../etc/foo", added: 2, deleted: 1,
                             files: [file_entry(path: "../../../etc/foo/bar.rb")])]

      rendered = view.render(changeset(commits: groups), scope: :by_directory)
      view.open(2, generation: rendered.generation)

      expect(opener.calls).to eq([["../../../etc/foo/bar.rb", 1]])
    end

    it "leaves an in-project group exactly as it was drawn before" do
      groups = [commit_entry(subject: "lib", added: 2, deleted: 1, files: [file_entry(path: "lib/a.rb")])]

      rendered = view.render(changeset(commits: groups), scope: :by_directory)

      expect(rendered.lines).to eq(["+2 -1  lib", "  [ ] lib/a.rb"])
    end
  end

  # The BLOCKER a review panel found: `Partition::ByCommit::Commit#numstat` is an
  # `Array<Source::FileStat>` and answers neither `#added` nor `#deleted`, so a
  # walk reaching through it raises NoMethodError against the real object while
  # every spec double invented to match it passes.
  describe "where a commit's totals come from" do
    it "reads them off the commit entry, leaving #numstat its Changeset meaning" do
      commit = commit_entry(subject: "Add the thing", files: [], added: 12, deleted: 3,
                            stats: [file_stat(path: "lib/a.rb", added: 12, deleted: 3)])

      rendered = view.render(changeset(commits: [commit]), scope: :commits)

      expect(rendered.lines).to include("+12 -3  Add the thing")
    end

    # The double answers `#label` and `#counted?` and withholds ONLY `#added`,
    # so `#added` is the only message that can raise. The first cut left `label`
    # off too and passed on the left-to-right order of one interpolation it did
    # not assert -- reordering that string would have made it raise on `label`
    # and go green for the wrong reason.
    it "never reaches through #numstat, which answers no aggregate at all" do
      commit = Struct.new(:label, :files, :numstat) do
        def counted? = true
      end.new("Add the thing", [], [].freeze)

      expect { view.render(changeset(commits: [commit]), scope: :commits) }
        .to raise_error(NoMethodError, /added/)
    end
  end

  # A survey opens over a directory and reads nothing, and drawing it in
  # the cockpit used to read all of it: the heading's `+n -m`, the key table and
  # the open line each walked every file's hunks, in BOTH scopes. Every file
  # here raises when chunked, so each example below asserts work that did not
  # happen rather than a number a spy reported about itself.
  describe "drawing a survey nobody has read" do
    let(:unread) { (1..3).map { |n| unread_entry(path: "docs/#{n}.md", lines: n * 10) } }

    it "draws every row at flat scope without reading a file" do
      expect(view.render(changeset(files: unread), scope: :cumulative).lines)
        .to eq(["[ ] docs/1.md", "[ ] docs/2.md", "[ ] docs/3.md"])
    end

    it "draws every row under a grouping without reading a file either" do
      groups = [commit_entry(subject: "docs", files: unread, counted: false, lines: 60)]

      expect(view.render(changeset(files: unread, commits: groups), scope: :by_directory).lines.drop(1))
        .to eq(["  [ ] docs/1.md", "  [ ] docs/2.md", "  [ ] docs/3.md"])
    end

    # THE rendering decision. A heading cannot count lines it has not read, and
    # `+0 -0` would be a rendered zero meaning "unknown" -- the reading the
    # partition chunk's Open decisions refused once already. So it claims the
    # SIZE the survey's identity pass already measured, in a form that cannot be
    # read as a diff's accounting.
    it "heads an unread group with the size already measured, not a count it cannot know" do
      groups = [commit_entry(subject: "docs", files: unread, counted: false, lines: 60)]

      expect(view.render(changeset(files: unread, commits: groups), scope: :by_directory).lines.first)
        .to eq("~60 lines  docs")
    end

    it "renders no plus/minus pair at all there, so nothing reads as a count of zero" do
      groups = [commit_entry(subject: "docs", files: unread, counted: false, lines: 0, added: 0, deleted: 0)]

      expect(view.render(changeset(commits: groups), scope: :by_directory).lines.first)
        .not_to match(/[+-]\d/)
    end

    it "goes back to the real figures for a group everything in which has been read" do
      read = [file_entry(path: "docs/1.md")]
      groups = [commit_entry(subject: "docs", files: read, added: 7, deleted: 2, lines: 60)]

      expect(view.render(changeset(files: read, commits: groups), scope: :by_directory).lines.first)
        .to eq("+7 -2  docs")
    end

    it "opens an unread row at the top of its file, having no hunk to land on" do
      rendered = view.render(changeset(files: unread), scope: :cumulative)

      expect(view.open(2, generation: rendered.generation)).to have_attributes(path: "docs/2.md", line: 1)
    end

    # How a gesture resolves for a file nobody has chunked: it does not. An
    # unread file has produced no key, so there is nothing a mark could name.
    it "refuses a mark gesture on an unread row rather than inventing a key for it" do
      rendered = view.render(changeset(files: unread), scope: :cumulative)

      outcome = view.marks(1, generation: rendered.generation)

      expect(outcome).to have_attributes(marked?: false, hunk_keys: [])
    end

    # And refuses it in ITS OWN words. {NO_HUNK}'s rule is that "the two
    # gestures fail for different reasons and the human is owed the one that
    # happened"; a binary file will never have a hunk, while a surveyed file has
    # none only until somebody opens it, and a human told "there is nothing
    # here" stops looking.
    it "names the file and the remedy, because this refusal is transient where a binary's is not" do
      rendered = view.render(changeset(files: unread), scope: :cumulative)

      expect(view.marks(1, generation: rendered.generation).report).to include("docs/1.md", "<CR>")
    end

    it "does not hand it the sentence that means there is genuinely nothing on the row" do
      rendered = view.render(changeset(files: unread), scope: :cumulative)

      expect(view.marks(1, generation: rendered.generation).report)
        .not_to eq(format(described_class::NO_HUNK, 1))
    end

    # The other side of that distinction, or the claim above holds over one
    # sentence nothing else uses: a file something HAS read and which has no
    # hunk keeps the permanent refusal, because that is the true fact about it.
    it "keeps the permanent sentence for a READ file that has no hunk at all" do
      rendered = view.render(changeset(files: [file_entry(path: "img.png", hunks: [])]), scope: :cumulative)

      expect(view.marks(1, generation: rendered.generation).report)
        .to eq(format(described_class::NO_HUNK, 1))
    end

    # `#counted?` is vacuously true for a group with no files, so an empty group
    # takes the counted branch. Right rather than accidental, and which DETAIL
    # is answering is what makes it so: {Review::Partition::ByCommit} reports the
    # commit's own numstat there -- the merge case {NO_HUNKS_HERE} exists for,
    # where the range attributes the commit no file -- and it is a real figure.
    it "heads an empty group with its detail's own figures, never a bound" do
      groups = [commit_entry(subject: "the side branch's own commit", files: [], added: 9, deleted: 0)]

      expect(view.render(changeset(commits: groups), scope: :by_directory).lines)
        .to eq(["+9 -0  the side branch's own commit", described_class::NO_HUNKS_HERE])
    end

    # {Review::Partition::Undetailed} sums to a TRUE zero over no files, because
    # a group with no files has no lines -- a count of nothing, not a zero
    # meaning unknown. `~0 lines` here would be worse: it would claim a bound
    # over a diff group whose figure is real.
    it "lets an empty group read as the zero it truly is rather than as unknown" do
      groups = [commit_entry(subject: "empty", files: [], added: 0, deleted: 0)]

      expect(view.render(changeset(commits: groups), scope: :by_directory).lines.first).to eq("+0 -0  empty")
    end

    it "still resolves the gesture on the one file something HAS read, beside unread neighbours" do
      read = file_entry(path: "docs/2.md", first: 12)
      rendered = view.render(changeset(files: [unread.first, read, unread.last]), scope: :cumulative)

      expect(view.marks(2, generation: rendered.generation))
        .to have_attributes(marked?: true, hunk_keys: read.hunk_keys)
    end
  end

  describe "the empty renderings" do
    it "says which scope found nothing rather than denying the changeset exists" do
      expect(view.render(changeset, scope: :cumulative).lines)
        .to eq([described_class::PLACEHOLDERS.fetch(:cumulative)])
    end

    # The overreach a panel nit found: a changeset with files but no walk is a
    # changeset, and announcing "no changeset under review" over it was a lie
    # about the one thing the human can see is false.
    it "does not deny a changeset with files just because its walk is empty" do
      rendered = view.render(changeset(files: [file_entry(path: "lib/a.rb")]), scope: :commits)

      expect(rendered.lines).to eq([described_class::PLACEHOLDERS.fetch(:commits)])
    end

    it "gives each scope its own wording" do
      expect(described_class::PLACEHOLDERS.values.uniq.size).to eq(described_class::PLACEHOLDERS.size)
    end

    it "declares a placeholder for every scope it dispatches on" do
      expect(described_class::PLACEHOLDERS.keys).to match_array(described_class::SCOPE_ROWS.keys)
    end

    # A placeholder is a rendering like any other: it is stamped and remembered,
    # so a human still holding the rendering it replaced gets the truth about
    # their row rather than "that buffer never existed".
    it "stamps and remembers the placeholder like any other rendering" do
      rendered = view.render(changeset, scope: :cumulative)

      expect(view.open(1, generation: rendered.generation).report).to include("no file")
    end
  end

  describe "the tri-state marker" do
    it "gives the three file states three distinct markers" do
      files = [file_entry(path: "lib/done.rb", state: "reviewed"),
               file_entry(path: "lib/some.rb", state: "partial"),
               file_entry(path: "lib/none.rb", state: "unreviewed")]

      markers = view.render(changeset(files:), scope: :cumulative).lines.map { |line| line[/\A\S+/] }

      expect(markers.uniq.size).to eq(3)
    end

    it "declares a marker for exactly the states Review::FILE_STATES holds" do
      expect(described_class::STATE_MARKERS.keys).to match_array(Lain::Review::FILE_STATES)
    end

    it "reads a Symbol state as readily as the canonical String" do
      symbol = view.render(changeset(files: [file_entry(path: "lib/a.rb", state: :reviewed)]), scope: :cumulative)
      string = view.render(changeset(files: [file_entry(path: "lib/a.rb", state: "reviewed")]), scope: :cumulative)

      expect(symbol.lines).to eq(string.lines)
    end

    it "refuses a state no marker was declared for rather than rendering it blank" do
      files = [file_entry(path: "lib/a.rb", state: "mostly")]

      expect { view.render(changeset(files:), scope: :cumulative) }.to raise_error(KeyError)
    end
  end

  # A file with no hunks (binary, mode-only, a pure rename, or a genuinely
  # empty file) reads `Marks#state_of([])` -> `:unreviewed` by
  # {Lain::Review::Session::MarkedChangeset::HUNKLESS}'s documented rule
  # (`review/marks.rb:203-205`), and that rule is untouched here -- only the
  # glyph a row with no hunks to review is drawn with. Told apart from an
  # UNREAD row (a survey entry nothing has opened yet, `chunked?` false) the
  # same way {NO_HUNK}/{UNREAD} already tell the two refusals apart: a row is
  # hunkless only once it has actually been read and produced zero hunks,
  # never merely because it has not been opened.
  describe "the hunkless marker" do
    it "gives a chunked file with no hunks a marker of its own" do
      rendered = view.render(changeset(files: [file_entry(path: "assets/empty.txt", hunks: [])]), scope: :cumulative)

      expect(rendered.lines.first).to start_with(described_class::HUNKLESS_MARKER)
    end

    it "is distinguishable from every tri-state marker, not just reviewed and unreviewed" do
      expect(described_class::STATE_MARKERS.values).not_to include(described_class::HUNKLESS_MARKER)
    end

    it "does not mark an unopened survey row hunkless just because it has no keys yet" do
      rendered = view.render(changeset(files: [unread_entry(path: "docs/1.md")]), scope: :cumulative)

      expect(rendered.lines.first).to start_with(described_class::STATE_MARKERS.fetch("unreviewed"))
    end

    it "shows no row reading unreviewed once every hunk-bearing file is reviewed" do
      files = [file_entry(path: "lib/done.rb", state: "reviewed"), file_entry(path: "assets/empty.txt", hunks: [])]

      lines = view.render(changeset(files:), scope: :cumulative).lines

      expect(lines).not_to include(a_string_starting_with(described_class::STATE_MARKERS.fetch("unreviewed")))
    end

    it "still marks a hunkless row's identity so a gesture on it resolves the same as before" do
      rendered = view.render(changeset(files: [file_entry(path: "assets/empty.txt", hunks: [])]), scope: :cumulative)

      expect(view.marks(1, generation: rendered.generation)).to have_attributes(marked?: false, hunk_keys: [])
    end
  end

  # The sidebar is a NAVIGATOR at `41_layout`'s 40 columns, so a caveat that
  # wraps to four screen rows spends its most valuable space on prose. The width
  # is read out of the lua module rather than written down here, which is
  # `layout_spec.rb`'s own idiom for a fact that lives on the other side of a
  # language boundary.
  describe "what the walk's own rows cost in a 40-column navigator" do
    def sidebar_width
      source = File.read(File.expand_path("../../../../lib/lain/frontend/neovim/runtime/41_layout.lua", __dir__))
      Integer(source[/lain_review_sidebar_width or (\d+)/, 1])
    end

    it "keeps the legend to one screen row" do
      expect(described_class::WALK_LEGEND.length).to be <= sidebar_width
    end

    it "keeps the absorbed-commit note to one screen row" do
      expect(described_class::NO_HUNKS_HERE.length).to be <= sidebar_width
    end

    # The clause a reader must not miss is IN the row; the merge caveat and the
    # marker's scope are in the help the row points at, because three clauses do
    # not fit in forty columns.
    # `helptags` indexes the tags a doc DEFINES and never the ones it
    # references, so a legend pointing at a tag nobody wrote generates tags
    # happily and answers E149 the moment a human follows it. Read out of the
    # doc rather than written down, `layout_spec.rb`'s cross-boundary idiom.
    it "points at a help tag the shipped doc actually defines" do
      tag = described_class::WALK_LEGEND[/:h (\S+)/, 1]
      doc = File.read(File.expand_path("../../../../plugin/nvim/doc/lain.txt", __dir__))

      expect(tag).not_to be_nil
      expect(doc).to include("*#{tag}*")
    end

    # A pointer is a disclosure only if what it points AT says the thing. The
    # example above asserts the tag is DEFINED and never that it SAYS anything,
    # so with only that one the walk's other two hazards could live forever in
    # a Ruby class doc no reader of the buffer will ever open -- and nothing
    # would fail. The legend has room for one clause; this is what holds the
    # help to carrying the rest.
    it "points at help that names the two hazards the legend has no room for" do
      doc = File.read(File.expand_path("../../../../plugin/nvim/doc/lain.txt", __dir__))
      section = doc[%r{\*lain://review\*(.*?)^-{20,}}m]

      expect(section).to be_a(String)
      expect(section).to include("side branch")
      expect(section).to include("WHOLE changeset")
    end
  end

  describe "the open gesture" do
    let(:files) { [file_entry(path: "lib/a.rb", first: 7), file_entry(path: "lib/b.rb", first: 40)] }

    it "resolves a file row to that file's path and its first hunk's new-side line" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      outcome = view.open(2, generation: rendered.generation)

      expect(outcome).to have_attributes(opened?: true, path: "lib/b.rb", line: 40)
      expect(opener.calls).to eq([["lib/b.rb", 40]])
    end

    it "resolves a file row nested under a commit, not the commit row above it" do
      commits = [commit_entry(subject: "one", files:)]
      rendered = view.render(changeset(files:, commits:), scope: :commits)

      # 1 legend, 2 commit header, 3 lib/a.rb, 4 lib/b.rb
      expect(view.open(4, generation: rendered.generation)).to have_attributes(path: "lib/b.rb", line: 40)
    end

    it "refuses the commit row itself, which names no file to open" do
      rendered = view.render(changeset(files:, commits: [commit_entry(subject: "one", files:)]), scope: :commits)

      outcome = view.open(2, generation: rendered.generation)

      expect(outcome).to have_attributes(opened?: false, path: nil, line: nil)
      expect(outcome.report).to include("line 2")
      expect(opener.calls).to be_empty
    end

    it "refuses line 0, which nvim never reports and which would index the last row" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      expect(view.open(0, generation: rendered.generation)).to have_attributes(opened?: false, path: nil)
    end

    it "refuses a line past the end of the rendering" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      expect(view.open(9, generation: rendered.generation)).to have_attributes(opened?: false, path: nil)
    end

    it "reports the port's own refusal rather than claiming the file opened" do
      refusing = recorder(answer: "no editor is attached")
      detached = described_class.new(changesets: refusing)
      rendered = detached.render(changeset(files:), scope: :cumulative)

      outcome = detached.open(1, generation: rendered.generation)

      expect(outcome).to have_attributes(opened?: false, report: "no editor is attached")
    end
  end

  # The diff-surface wiring, from this side. The diff surface holds the round
  # and this view holds the renderings, so the changeset has to cross once per round --
  # and it is FORWARDED rather than kept here, because a changeset beside the
  # rendering history would be a second answer to "what is under review".
  describe "which changeset the rows belong to" do
    let(:round) { changeset(files: [file_entry(path: "lib/a.rb")]) }

    it "hands the round to the diff surface a row is opened through" do
      view.reviewing(round)

      expect(opener.rounds).to eq([round])
    end

    it "keeps nothing of its own, so nothing here can disagree with the rows" do
      view.reviewing(round)

      expect(view.instance_variables).not_to include(:@changeset)
    end

    # A second review in one editor: the LAST round is the one a row opens
    # against, or the human presses a row of the changeset they can see and
    # lands in a file from the one before it.
    it "replaces the round rather than accumulating them" do
      second = changeset(files: [file_entry(path: "lib/b.rb")])

      view.reviewing(round)
      view.reviewing(second)

      expect(opener.rounds.last).to equal(second)
    end
  end

  # The OTHER direction of the diff-surface wiring's acceptance test, and the reason this group
  # exists at all: {Lain::Frontend::Neovim#review_view} now supplies a
  # {Lain::Frontend::Neovim::ChangesetDiff}, so this sentence must be
  # unreachable from a review drawn in a real editor -- and it must still be
  # what a view built with no diff surface answers, because a navigator with
  # nowhere to open a file has to say so rather than report an open that never
  # happened.
  describe "a view built with no diff surface at all" do
    subject(:view) { described_class.new }

    it "refuses the open gesture in words" do
      rendered = view.render(changeset(files: [file_entry(path: "lib/a.rb")]), scope: :cumulative)

      expect(view.open(1, generation: rendered.generation))
        .to have_attributes(opened?: false, report: a_string_including("no diff surface is wired"))
    end

    it "takes the round without complaint, because naming it is wiring and not a gesture" do
      expect(view.reviewing(changeset)).to be_nil
    end
  end

  # A row's OTHER identity. The editor sends a line, because a sidebar row
  # renders no hunk key and a key is a content digest that never crosses the
  # wire -- so this view is the only object that can say which hunks a marked
  # row named.
  describe "the mark gesture" do
    let(:files) { [file_entry(path: "lib/a.rb", first: 7), file_entry(path: "lib/b.rb", first: 40)] }

    # TWO BYTE-IDENTICAL hunks in one file, which is the only shape that tells a
    # correct batch from a convenient one: `Hunk.keys` hands duplicates a
    # span-qualified key and hands a lone hunk its content key, so keying a
    # SUBSET of a file's hunks produces a key the full file never produces.
    def duplicated_pair
      [Lain::Review::Hunk.new(path: "lib/dup.rb", old_start: 10, old_count: 1, new_start: 10, new_count: 1,
                              lines: [" same"]),
       Lain::Review::Hunk.new(path: "lib/dup.rb", old_start: 90, old_count: 1, new_start: 90, new_count: 1,
                              lines: [" same"])]
    end

    def duplicated_file(hunks, keys: nil) = file_entry(path: "lib/dup.rb", hunks:, keys:)

    it "resolves a file row to exactly the keys Marks would derive for that file" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      outcome = view.marks(2, generation: rendered.generation)

      expect(outcome).to have_attributes(marked?: true, hunk_keys: Lain::Review::Hunk.keys(files.last.hunks))
    end

    # This used to be enforced by re-keying `changeset.files` on every render,
    # which cost every hunk of every file and died over a survey. The invariant
    # now lives one layer down, where it cannot be got wrong:
    # `Session::MarkedChangeset` builds ONE row per file and a partition holds
    # the very same object (`session_spec.rb`, "carries the same file row object
    # under a partition as at whole scope"), so a nested row's keys ARE the
    # whole file's. What this view owes is to read them rather than derive a
    # second answer.
    it "keys a nested row off the row, which is the same row the flat scope draws" do
      whole = duplicated_pair
      row = duplicated_file(whole)
      rendered = view.render(changeset(files: [row], commits: [commit_entry(subject: "one", files: [row])]),
                             scope: :commits)

      # 1 legend, 2 commit header, 3 lib/dup.rb
      expect(view.marks(3, generation: rendered.generation).hunk_keys).to eq(Lain::Review::Hunk.keys(whole))
    end

    # The mutation that example cannot catch on its own: a view re-deriving keys
    # from the hunks it was handed would agree with it, because a real row's two
    # members agree. Here they are parted -- the row carries the whole file's
    # keys beside a single hunk -- and the example below proves the two answers
    # genuinely differ.
    it "never re-derives keys from the hunks on the row it was handed" do
      whole = duplicated_pair
      row = duplicated_file([whole.first], keys: Lain::Review::Hunk.keys(whole))

      rendered = view.render(changeset(files: [row]), scope: :cumulative)

      expect(view.marks(1, generation: rendered.generation).hunk_keys).to eq(Lain::Review::Hunk.keys(whole))
    end

    it "is not merely the subset's keys under another name -- the two genuinely differ" do
      whole = duplicated_pair

      expect(Lain::Review::Hunk.keys(whole).first).not_to eq(Lain::Review::Hunk.keys([whole.first]).first)
    end

    it "refuses the commit row itself, which names no hunk to mark" do
      rendered = view.render(changeset(files:, commits: [commit_entry(subject: "one", files:)]), scope: :commits)

      outcome = view.marks(2, generation: rendered.generation)

      expect(outcome).to have_attributes(marked?: false, hunk_keys: [])
      expect(outcome.report).to include("no hunk", "line 2")
    end

    it "refuses line 0 and a line past the end, which name no row at all" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      expect([view.marks(0, generation: rendered.generation), view.marks(9, generation: rendered.generation)])
        .to all(have_attributes(marked?: false))
    end

    it "refuses a stamp it never issued with the same sentence the open gesture gets" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      expect(view.marks(1, generation: rendered.generation + 5).report)
        .to eq(view.open(1, generation: rendered.generation + 5).report)
    end

    it "tells a missing stamp apart from a row that names nothing" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      expect(view.marks(1, generation: nil).report).not_to eq(view.marks(9, generation: rendered.generation).report)
    end

    it "records nothing itself -- resolving a mark is a query over the renderings" do
      rendered = view.render(changeset(files:), scope: :cumulative)
      view.marks(1, generation: rendered.generation)

      expect(opener.calls).to be_empty
    end
  end

  describe "the rendering stamp" do
    let(:first_files) { [file_entry(path: "lib/a.rb", first: 7), file_entry(path: "lib/b.rb", first: 40)] }
    # EQUAL HEIGHT and different content: the exact shape a line COUNT cannot
    # tell apart, which is the defect protocol 8 replaced the count to fix.
    let(:second_files) { [file_entry(path: "lib/c.rb", first: 1), file_entry(path: "lib/d.rb", first: 2)] }

    def render_first = view.render(changeset(files: first_files), scope: :cumulative)
    def render_second = view.render(changeset(files: second_files), scope: :cumulative)

    it "stamps each rendering with its own generation" do
      expect(render_first.generation).not_to eq(render_second.generation)
    end

    # The stamp and the lines it belongs to leave together, so no caller can
    # post one rendering's lines beneath another's stamp -- there is no
    # `#generation` reader to pair with `#render` and get that wrong.
    it "hands the stamp back with the lines it belongs to, and nowhere else" do
      expect(render_first).to have_attributes(lines: an_instance_of(Array), generation: an_instance_of(Integer))
      expect(view).not_to respond_to(:generation)
    end

    it "resolves a still-held older rendering against the rows THAT rendering drew" do
      stale = render_first.generation
      current = render_second.generation

      expect(view.open(1, generation: stale)).to have_attributes(path: "lib/a.rb", line: 7)
      expect(view.open(1, generation: current)).to have_attributes(path: "lib/c.rb", line: 1)
    end
  end

  # THREE events, three sentences. The first cut had two and told the other two
  # cases the third's story -- a nil stamp was reported as "it has re-rendered
  # since", which is a claim about a rendering that never existed.
  describe "the three ways a stamp names no rendering" do
    let(:files) { [file_entry(path: "lib/a.rb", first: 7)] }

    it "says nothing has been rendered when the buffer carries no stamp at all" do
      view.render(changeset(files:), scope: :cumulative)

      outcome = view.open(1, generation: nil)

      expect(outcome).to have_attributes(opened?: false, path: nil)
      expect(outcome.report).to include("no rendering stamp")
      expect(outcome.report).not_to include("re-rendered")
      expect(opener.calls).to be_empty
    end

    # `{ line, nil }` in lua drops the nil and reaches Ruby as a ONE-element
    # array, so `line, generation = args` really does hand this method a nil --
    # `runtime/65_review.lua` records being bitten by that exact fact.
    it "says a stamp was never issued rather than blaming a re-render" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      outcome = view.open(1, generation: rendered.generation + 99)

      expect(outcome).to have_attributes(opened?: false, path: nil)
      expect(outcome.report).to include("never issued")
      expect(outcome.report).not_to include("re-rendered")
      expect(opener.calls).to be_empty
    end

    it "says it has re-rendered only for a stamp it really did issue and has since dropped" do
      stale = view.render(changeset(files:), scope: :cumulative).generation
      (described_class::HELD + 1).times { view.render(changeset(files:), scope: :cumulative) }

      outcome = view.open(1, generation: stale)

      expect(outcome).to have_attributes(opened?: false, path: nil, line: nil)
      expect(outcome.report).to include("re-rendered", stale.to_s)
      expect(opener.calls).to be_empty
    end

    it "gives the three events three different sentences" do
      rendered = view.render(changeset(files:), scope: :cumulative)
      (described_class::HELD + 1).times { view.render(changeset(files:), scope: :cumulative) }
      reports = [nil, rendered.generation, 10_000].map { |stamp| view.open(1, generation: stamp).report }

      expect(reports.uniq.size).to eq(3)
    end

    it "refuses a gesture that arrives before anything has been rendered" do
      expect(view.open(1, generation: 1)).to have_attributes(opened?: false, path: nil)
    end

    # ZERO is the boundary of `1..@generation`, and it is not an arbitrary one:
    # it is the value a caller with an uninitialised counter sends, which is
    # precisely the wire fault UNISSUED exists to name. Widening the range to
    # `0..` survived every other example here, so the bound is pinned from the
    # side that can actually be got wrong.
    it "names a stamp of 0 as never issued, since no rendering is ever stamped 0" do
      view.render(changeset(files:), scope: :cumulative)

      outcome = view.open(1, generation: 0)

      expect(outcome).to have_attributes(opened?: false, path: nil)
      expect(outcome.report).to include("never issued")
    end
  end

  # The measurement the doubles above cannot make: a real fifty-file corpus, a
  # real {Lain::Review::Session}, and the `chunker:` seam counting at the
  # CHUNKER's own `#call` -- so "the sidebar read nothing" is an observation about
  # work that did not happen rather than a flag the subject set about itself.
  #
  # It is here rather than in `corpus_spec.rb` because the offender was the
  # SURFACE: `Session.open` and `Session#present` were already lazy, and the view
  # chunked all fifty afterwards.
  describe "over a real corpus", :seam do
    subject(:view) { described_class.new }

    # The real dispatch, wrapped so every chunking is logged with its path. The
    # count is taken inside the chunker rather than at the dispatch, so a view
    # that resolved chunkers eagerly and chunked lazily still counts zero.
    def counting(log)
      lambda do |for_path|
        chunker = Lain::Survey::Chunker.for(for_path)
        lambda do |path:, source:|
          log << path
          chunker.call(path:, source:)
        end
      end
    end

    def corpus(root, log)
      sensitivity = Lain::Sensitivity.new(home: "/home/surveyor", cwd: root)
      Lain::Review::Source::Corpus.new(walk: Lain::Survey::Walk.new(root:, sensitivity:),
                                       projection: Lain::Survey::Projection.new(ledger:),
                                       chunker: counting(log))
    end

    def ledger = @ledger ||= Lain::Sensitivity::Ledger.new

    def section(ordinal) = "## S#{ordinal}\n\nbody #{ordinal} one.\nbody #{ordinal} two.\nbody #{ordinal} three.\n\n"

    # Five directories of ten, so `:by_directory` produces real groups rather than
    # one heading over everything.
    def build(root)
      50.times do |n|
        dir = File.join(root, "d#{n % 5}")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "f#{n}.md"), (1..6).map { |i| section(i) }.join)
      end
    end

    def session(root, log)
      changeset = Lain::Review::Changeset.new(source: corpus(root, log))
      [changeset, Lain::Review::Session.open(changeset:, journal: [], source: "corpus")]
    end

    def draw(session)
      %i[cumulative by_directory].map do |scope|
        view.render(session.marked(strategy: Lain::Review::Partition::STRATEGIES.fetch(scope)), scope:).lines
      end
    end

    around do |example|
      Dir.mktmpdir("lain-review-view-corpus") { |made| @root = File.realpath(made) and example.run }
    end

    it "draws all fifty files at both scopes having chunked none of them" do
      log = []
      build(@root)
      _changeset, opened = session(@root, log)

      flat, grouped = draw(opened)

      expect(flat.size).to eq(50)
      expect(grouped.size).to eq(55)
      expect(log).to be_empty
    end

    it "heads each group with a size rather than a line count nobody could have read" do
      log = []
      build(@root)
      _changeset, opened = session(@root, log)

      _flat, grouped = draw(opened)

      expect(grouped.grep(/^~/).size).to eq(5)
      expect(grouped).to all(satisfy { |line| !line.match?(/^\+\d+ -\d+/) })
    end

    it "chunks exactly the file something has read, and no other, however often it is drawn" do
      log = []
      build(@root)
      changeset, opened = session(@root, log)
      read = changeset.files.first
      read.hunks

      draw(opened)
      draw(opened)

      expect(log.uniq).to eq([read.path])
    end
  end
end
