# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "stringio"
require "timeout"
require "tmpdir"

# T14: `lain://review`, the changeset review's navigator -- the scopes it
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

    # The T7 panel's measurement: with a merge in the range, the commit walk
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

  # B19. A survey opens over a directory and reads nothing, and drawing it in
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

  # T32a's wiring, from this side. The diff surface holds the round and this
  # view holds the renderings, so the changeset has to cross once per round --
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

  # The OTHER direction of T32a's acceptance test, and the reason this group
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

  # T19: a row's OTHER identity. The editor sends a line, because a sidebar row
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
end

# The lua half: `runtime/46_sidebar.lua` -- `_G.__lain.set_review`, which is the
# FIRST caller of T26's `review_place`, and `:LainReviewOpen`, which sends the
# cursor line with the stamp the buffer carries.
#
# `layout_spec.rb`'s harness, driving the injected chunk DIRECTLY: what is under
# test is what the editor does with a buffer and a window, and a frontend in
# front of that would mean every assertion had first to prove the frontend was
# not the thing that moved.
#
# ONE EDITOR PER EXAMPLE, and it was measured rather than assumed. Sharing one
# across the rendering group (`before(:context)`) was tried and dropped: it took
# the file from 1.11s to 0.83s, which is 0.28s against a suite whose longest
# FILE is 17.2s, and cost a `RSpec/BeforeAfterAll` suppression plus the order
# dependence that cop is about -- these examples close windows and swap the
# current buffer. A `--headless --clean` spawn measures 5-6ms, so a fresh editor
# is not the expensive fixture that pattern exists for; the 29ms first recorded
# here was the whole around hook -- spawn, socket wait, attach and runtime
# injection -- not the spawn.
RSpec.describe "runtime/46_sidebar.lua", :nvim do
  # `layout_spec.rb`'s hook: one editor per example, torn down whatever the
  # example did to it -- these examples close windows and swap the current
  # buffer, which is the state a shared editor would carry into the next one.
  around do |example|
    @editor, pid, socket = self.class.headless_editor
    example.run
  ensure
    self.class.stop_editor(pid, socket)
  end

  def review_buffer = Lain::Frontend::Neovim::ReviewView::NAME

  def self.headless_editor
    socket = File.join(Dir.tmpdir, "lain-nvim-sidebar-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    editor = Neovim.attach_unix(socket)
    editor.exec_lua(Lain::Frontend::Neovim::RuntimeLoader.new.source,
                    [Lain::VERSION, Lain::Frontend::Neovim::PROTOCOL, editor.channel_id])
    [editor, pid, socket]
  end

  def self.stop_editor(pid, socket)
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    FileUtils.rm_f(socket)
  end

  def lua(source, args = []) = @editor.exec_lua(source, args)

  def set_review(lines, gen) = lua("_G.__lain.set_review(...)", [lines, gen])

  def review_lines
    lua("return vim.api.nvim_buf_get_lines(vim.fn.bufnr(...), 0, -1, false)", [review_buffer])
  end

  def review_buf = lua("return vim.fn.bufnr(...)", [review_buffer])

  def buffer_var(key)
    lua("local name, var = ...; return vim.b[vim.fn.bufnr(name)][var]", [review_buffer, key])
  end

  def sidebar_window
    lua(<<~LUA)
      for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if vim.t[tab].lain_review then
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if vim.w[win].lain_review_slot == "sidebar" then return win end
          end
        end
      end
      return nil
    LUA
  end

  describe "rendering into the review tabpage" do
    it "writes the lines it is given into lain://review" do
      set_review(%w[one two three], 1)

      expect(review_lines).to eq(%w[one two three])
    end

    it "replaces the whole rendering rather than appending to it" do
      set_review(%w[one two three], 1)
      set_review(%w[only], 2)

      expect(review_lines).to eq(["only"])
    end

    it "stamps the buffer with the rendering's generation" do
      set_review(%w[one], 41)

      expect(buffer_var("lain_view_generation")).to eq(41)
    end

    it "lands the sidebar in T26's sidebar slot, not in a split of the session tab" do
      set_review(%w[one], 1)

      expect(lua("return vim.api.nvim_win_get_buf(...)", [sidebar_window])).to eq(review_buf)
    end

    it "leaves the buffer nomodifiable at rest so a stray keystroke cannot desync it" do
      set_review(%w[one], 1)

      expect(lua("return vim.bo[vim.fn.bufnr(...)].modifiable", [review_buffer])).to be(false)
    end

    it "claims the buffer for the lain view contract" do
      set_review(%w[one], 1)

      expect(buffer_var("lain_view")).to eq(review_buffer)
    end

    # 00_constants' READONLY_FILETYPES is a shared table this module does not
    # edit, so the lookup misses and the option would land unset -- exactly the
    # orphan-buffer defect T5 fixed for lain://workspace ("filetype '', no
    # syntax, outside the lain contract").
    it "joins the one shared lain filetype rather than landing as an orphan buffer" do
      set_review(%w[one], 1)

      expect(lua("return vim.bo[vim.fn.bufnr(...)].filetype", [review_buffer])).to eq("lain")
    end

    it "re-renders into the SAME buffer rather than stacking a new one per render" do
      set_review(%w[one], 1)
      first = review_buf
      set_review(%w[two], 2)

      expect(review_buf).to eq(first)
    end

    it "rebuilds the layout when the human closed the sidebar window" do
      set_review(%w[one], 1)
      lua("vim.api.nvim_win_close(..., true)", [sidebar_window])
      set_review(%w[two], 2)

      expect(lua("return vim.api.nvim_win_get_buf(...)", [sidebar_window])).to eq(review_buf)
    end

    it "sends the cursor line and the buffer's stamp as ONE array of arguments" do
      set_review(%w[one two], 7)
      sent = lua(<<~LUA, [review_buffer])
        local restore = vim.api.nvim_get_current_buf()
        local seen = nil
        vim.api.nvim_set_current_buf(vim.fn.bufnr(...))
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        local original = vim.rpcrequest
        vim.rpcrequest = function(_, method, verb, args) seen = { method, verb, args } end
        pcall(vim.cmd, "LainReviewOpen")
        vim.rpcrequest = original
        vim.api.nvim_set_current_buf(restore)
        return seen
      LUA

      expect(sent).to eq(["lain_command", "review_open", [2, 7]])
    end

    it "refuses :LainReviewOpen outside lain://review rather than opening a row nobody looked at" do
      set_review(%w[one two], 7)
      sent = lua(<<~LUA)
        local restore = vim.api.nvim_get_current_buf()
        local seen = false
        vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
        local original = vim.rpcrequest
        vim.rpcrequest = function() seen = true end
        pcall(vim.cmd, "LainReviewOpen")
        vim.rpcrequest = original
        vim.api.nvim_set_current_buf(restore)
        return seen
      LUA

      expect(sent).to be(false)
    end
  end

  # T32b: the MARK gesture, which had been wired all the way to
  # {Review::Handover#mark} since T13 with no key able to send it.
  describe "the mark keys" do
    # Read off the LIVE editor rather than off the runtime's source, because
    # what a human presses is what nvim has bound, not what a file says. Each
    # binding's rhs carries the state as a literal, so this pins three things at
    # once: every state has a key, no key sends a state Ruby cannot take, and
    # the sidebar's set is exactly `Review::MARK_STATES`.
    #
    # The set EQUALITY is the assertion, not `include`. A third state added to
    # `review/vocabulary.rb` and not here would pass an `include`, ship a
    # sidebar that cannot express it, and be refused -- silently -- at the far
    # end of the wire; a key sending a fourth spelling would pass it too, and be
    # refused at `Review::Marks.normalize`. This is `48_annotate`'s MARKERS
    # defence, one module over.
    let(:mark_maps) do
      <<~LUA
        local restore = vim.api.nvim_get_current_buf()
        vim.api.nvim_set_current_buf(vim.fn.bufnr(...))
        local states = {}
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
          local state = tostring(map.rhs):match("LainReviewMark%s+(%a+)")
          if state then states[#states + 1] = { key = map.lhs, state = state } end
        end
        vim.api.nvim_set_current_buf(restore)
        return states
      LUA
    end

    def bound_states
      set_review(%w[one two], 1)
      lua(mark_maps, [review_buffer])
    end

    it "binds one key per member of Review::MARK_STATES, and no others" do
      expect(bound_states.map { |bound| bound["state"] }).to match_array(Lain::Review::MARK_STATES)
    end

    # ONE KEY PER STATE is the card, so the count is the assertion that says so:
    # a single toggle key would satisfy every payload example below on its first
    # press and still be the defect `human_replies.rb` names.
    it "gives each state its own key rather than one key that toggles" do
      keys = bound_states.map { |bound| bound["key"] }

      expect(keys.uniq.size).to eq(Lain::Review::MARK_STATES.size)
    end

    it "refuses a state Ruby has no spelling for rather than putting it on the wire" do
      set_review(%w[one two], 7)
      outcome = lua(<<~LUA, [review_buffer])
        local restore = vim.api.nvim_get_current_buf()
        local seen = false
        vim.api.nvim_set_current_buf(vim.fn.bufnr(...))
        local original = vim.rpcrequest
        vim.rpcrequest = function() seen = true end
        local ok, err = pcall(vim.cmd, "LainReviewMark revewed")
        vim.rpcrequest = original
        vim.api.nvim_set_current_buf(restore)
        return { sent = seen, ok = ok, err = tostring(err) }
      LUA

      expect(outcome).to include("sent" => false, "ok" => false)
      expect(outcome["err"]).to include(*Lain::Review::MARK_STATES)
    end

    it "refuses :LainReviewMark outside lain://review rather than marking a row nobody looked at" do
      set_review(%w[one two], 7)
      sent = lua(<<~LUA)
        local restore = vim.api.nvim_get_current_buf()
        local seen = false
        vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
        local original = vim.rpcrequest
        vim.rpcrequest = function() seen = true end
        pcall(vim.cmd, "LainReviewMark reviewed")
        vim.rpcrequest = original
        vim.api.nvim_set_current_buf(restore)
        return seen
      LUA

      expect(sent).to be(false)
    end
  end

  describe "the first render of a session" do
    it "opens the review in its own tabpage and leaves the human where they were" do
      before_tab = lua("return vim.api.nvim_get_current_tabpage()")
      before_windows = lua("return vim.api.nvim_tabpage_list_wins(...)", [before_tab])

      set_review(%w[one], 1)

      expect(lua("return vim.api.nvim_get_current_tabpage()")).to eq(before_tab)
      expect(lua("return vim.api.nvim_tabpage_list_wins(...)", [before_tab])).to eq(before_windows)
    end

    it "sizes the sidebar as a navigator rather than a third of the screen" do
      set_review(%w[one], 1)

      expect(lua("return vim.api.nvim_win_get_width(...)", [sidebar_window])).to eq(40)
    end
  end
end

# T32b's two gestures, crossing the WIRE into a real Ruby process. The block
# above stubs `vim.rpcrequest` and can therefore only say what lua ATTEMPTED;
# that is the shape of assertion this chunk has repeatedly shipped green over a
# subject nobody was talking to. Here a real {Frontend::Neovim} serves the
# socket, so every layer between the keystroke and the payload is the shipped
# one -- the runtime as {RuntimeLoader} concatenates it, the {RpcThread}'s
# select loop, its {Router}'s acked/answered split, and {ReviewWrite}'s judgement
# of the arguments' SHAPE.
#
# The one thing that is not real is the object at the far end of the verdict
# rail: {Review::Handover} needs a {Review::Session} over a {Review::Changeset},
# which is a fixture this card has no business building. A recorder is bound
# there instead, and the assertions are about what reached it, which is exactly
# the wire this card supplies a caller for.
#
# Keys go through `nvim_feedkeys`, never `:normal!` and never `vim.cmd`: the
# card is a KEYMAP, and both alternatives bypass mapping resolution entirely --
# an example that ran the command directly would pass against a runtime that
# binds no keys at all.
RSpec.describe Lain::Frontend::Neovim, "the changeset review's two gestures", :nvim, :seam do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-gestures-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @socket = socket
    example.run
  ensure
    @inspector = nil
    begin
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.rm_f(socket)
  end

  let(:channel) { Lain::Channel.new }

  # A recorder, not a double: `wrote_verdict` must ANSWER (nil is "taken", a
  # String is the refusal the human's command fails with), and what these
  # examples need to know is what it was handed.
  let(:review) do
    Class.new do
      def initialize = @verdicts = []

      attr_reader :verdicts

      def wrote_annotation(_note) = nil

      def wrote_verdict(verdict)
        @verdicts << verdict
        nil
      end
    end.new
  end

  # The SECOND connection, which is how every :nvim spec here observes an editor
  # the frontend owns: `_G.__lain` is process-wide lua state, so a render posted
  # from here lands in the same runtime the frontend injected, and the `chan`
  # upvalue the gestures send on still names the FRONTEND's channel.
  def inspector = @inspector ||= Neovim.attach_unix(@socket)

  def sidebar = Lain::Frontend::Neovim::ReviewView::NAME

  def wait_until(timeout: 8)
    deadline = Time.now + timeout
    result = yield
    until result
      raise "timed out waiting for the editor" if Time.now > deadline

      sleep 0.02
      result = yield
    end
    result
  end

  def set_review(lines, generation)
    inspector.exec_lua("local lines, gen = ...; _G.__lain.set_review(lines, gen)", [lines, generation])
  end

  # Seats the cursor in the sidebar and feeds `keys` through nvim's own mapping
  # resolution. `"x"` executes them before this returns, so the blocking
  # rpcrequest the map fires has already been answered by the frontend's RPC
  # thread by the time the example looks at the inbox.
  def press(keys, row:)
    inspector.exec_lua(<<~LUA, [sidebar, keys, row])
      local name, keys, row = ...
      vim.cmd("buffer " .. name)
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
      return true
    LUA
  end

  # `pcall`, because the whole point of the ANSWERED rail is that a refusal
  # arrives as the command's ERROR -- and `Neovim::Client#command` would turn
  # that into a raise in the spec process rather than a value to assert on.
  def run(command)
    inspector.exec_lua(<<~LUA, [command])
      local ok, err = pcall(vim.cmd, ...)
      return { ok = ok, err = tostring(err) }
    LUA
  end

  def next_command(frontend)
    wait_until do
      frontend.command_inbox.pop(true)
    rescue ThreadError
      nil
    end
  end

  # nvim's own `:messages`, read over the SECOND connection -- what a human
  # sitting at the editor would scroll back to, rather than anything the
  # frontend recorded about itself. `neovim_spec.rb`'s helper, verbatim.
  def messages
    inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
  end

  # A refusal `__lain.review_refused` echoed, waited for: the command returns
  # before nvim has necessarily flushed the echo, so a bare read races it.
  def refusal_shown = wait_until { messages[/lain: .+/] }

  # The real review model behind the verdict rail, for the one example that
  # asserts what the human SEES. Hand-written diff bytes over a verifying
  # double ({DiffSource}) rather than a repository -- `handover_spec.rb`'s own
  # fixture choice -- so the only thing standing in for production here is the
  # source of the bytes, and everything from `Session#submit` outward is real.
  #
  # `Policy::Permissive`, because the point is the acknowledgement and not the
  # admissibility: the default policy refuses an approve over hunks nobody
  # read, which is a different example's subject.
  def handover_over(surface)
    Lain::Review::Handover.new(session: Lain::Review::Session.open(
      changeset: Lain::Review::Changeset.new(source: verdict_source), journal: Lain::Journal.new(io: StringIO.new),
      source: "local_branch", surface:, policy: Lain::Review::Verdict::Policy::Permissive.new
    ))
  end

  def verdict_diff
    <<~DIFF
      diff --git a/a.rb b/a.rb
      index 1111111..2222222 100644
      --- a/a.rb
      +++ b/a.rb
      @@ -1,3 +1,3 @@ def alpha
       one
      -two
      +TWO
    DIFF
  end

  # Attributed, because a changeset whose diff names a file no commit's numstat
  # does is one `Partition::ByCommit` refuses.
  def verdict_commit
    Lain::Review::Source::Commit.new(
      sha: -("c" * 40), subject: -"touch a", body: "",
      numstat: [Lain::Review::Source::FileStat.new(path: -"a.rb", added: 1, deleted: 1)].freeze
    )
  end

  def verdict_source
    DiffSource.over(instance_double(Lain::Review::Source::LocalBranch,
                                    diff: verdict_diff.b, commits: [verdict_commit].freeze,
                                    base_ref: -("b" * 40), head_ref: -("h" * 40)))
  end

  describe "review_mark" do
    # The payload, end to end: `["review_mark", [line, state, generation]]` is
    # what `HumanReplies::Gestures#mark_hunk` destructures and what
    # `human_replies_spec` pushes by hand -- so this is the one example that
    # says the editor produces the shape every spec on the other side assumes.
    it "sends the row, the state the key names, and the rendering's stamp" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        set_review(%w[one two], 7)
        press("x", row: 2)

        expect(next_command(frontend)).to eq(["review_mark", [2, "reviewed", 7]])
      end
    end

    it "sends the OTHER state from the other key, on the same row" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        set_review(%w[one two], 7)
        press("u", row: 2)

        expect(next_command(frontend)).to eq(["review_mark", [2, "unreviewed", 7]])
      end
    end

    # THE COUNTER-EXAMPLE THE CARD IS ABOUT. A lua-side toggle passes both
    # examples above on a first press and diverges only on the second, which is
    # precisely the failure `human_replies.rb:554-558` describes: a state derived
    # from a rendering rather than from the human's finger, silently flipping the
    # wrong way because both values are legal. Twice on one row, twice the same
    # word.
    it "sends the same state twice for two presses of one key rather than toggling" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        set_review(%w[one two], 7)
        press("x", row: 2)
        press("x", row: 2)

        expect([next_command(frontend), next_command(frontend)])
          .to eq([["review_mark", [2, "reviewed", 7]], ["review_mark", [2, "reviewed", 7]]])
      end
    end

    # T11's stamp, on the mark rail: two renderings of EQUAL HEIGHT, which is
    # the case a line count cannot tell apart and the reason protocol 8 replaced
    # one with the other. A payload carrying the count, the first generation, or
    # nothing at all all read alike against a single render.
    it "carries the stamp of the rendering on screen, not the one before it" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        set_review(%w[one two], 6)
        set_review(%w[alpha beta], 7)
        press("x", row: 1)

        expect(next_command(frontend)).to eq(["review_mark", [1, "reviewed", 7]])
      end
    end

    # BUFFER-LOCAL, and `60_question.lua`'s comment says what a global one costs:
    # `x` is how a human deletes a character, in every file they have open. A map
    # that escaped the sidebar would break that everywhere AND send a gesture
    # about a row nobody is looking at, and nothing in the payload examples above
    # can see either.
    it "keeps the keys buffer-local, so x in the human's own file still deletes a character" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        set_review(%w[one two], 7)
        typed = inspector.exec_lua(<<~LUA, [])
          local buf = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_set_current_buf(buf)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc" })
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("x", true, false, true), "x", false)
          return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        LUA

        expect(typed).to eq(["bc"])
        expect { frontend.command_inbox.pop(true) }.to raise_error(ThreadError)
      end
    end
  end

  describe "review_verdict" do
    # ONE ARRAY HOLDING THE PAYLOAD. `ReviewWrite.verdict` refuses anything else
    # BY NAME (`65_review.lua:75-79` records what flat positionals cost), so a
    # verdict that reaches the recorder at all is a verdict that arrived in the
    # shape every verb on this rail uses -- and a flat-positional lua half fails
    # here with that refusal rather than passing quietly.
    it "hands the verdict to the bound review" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        frontend.bind_changeset_review(review)

        expect(run("LainReviewVerdict approve")).to include("ok" => true)
        expect(review.verdicts).to eq(["approve"])
      end
    end

    # The vocabulary is `Review::VERDICTS` and lua does not restate it, so this
    # is the example that says so from both sides: nothing reaches the review,
    # and the sentence the human gets is the one the ONE declaration produced.
    #
    # READ OFF THE MESSAGE RAIL SINCE T16, not off `pcall`'s `ok`. The command
    # used to re-raise the refusal that crossed the wire, so the human met a
    # `stack traceback:` under lain's own sentence; it
    # now answers through `__lain.review_refused` and returns, so the command
    # COMPLETES and the sentence is echoed. What is asserted about the sentence
    # and about the review is unchanged -- only where the sentence is read from.
    it "refuses a word the vocabulary does not hold, and tells the human which words it does" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        frontend.bind_changeset_review(review)

        expect(run("LainReviewVerdict looks-fine")).to include("ok" => true)
        expect(refusal_shown).to include(*Lain::Review::VERDICTS).and include("looks-fine")
        expect(review.verdicts).to be_empty
      end
    end

    # A bare invocation takes the SAME path as a typo, deliberately: lua holds
    # no vocabulary to check against, so the empty verdict is refused by the
    # object that owns the words and the human is told what they are.
    it "refuses an empty verdict by naming the vocabulary rather than sending nothing" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        frontend.bind_changeset_review(review)

        expect(run("LainReviewVerdict")).to include("ok" => true)
        expect(refusal_shown).to include(*Lain::Review::VERDICTS)
        expect(review.verdicts).to be_empty
      end
    end

    # THE ACKNOWLEDGEMENT, end to end and with nothing doubled between the
    # keystroke and the message area. Every example above binds a recorder,
    # which can say what reached Ruby and can never say what the human SEES --
    # and "the human sees nothing" was the whole defect: `:LainReviewVerdict
    # approve` journaled correctly and printed nowhere.
    #
    # So this one binds a REAL {Review::Handover} over a REAL
    # {Review::Session}, whose surface is the frontend's OWN
    # {Review::Surface::Neovim} (`#review_surface` -- never a second one built
    # here, for the reason that method's doc gives), and reads nvim's own
    # `:messages` back through the inspector connection. Nothing but the diff
    # bytes is a fixture.
    it "echoes the verdict into the editor's own message history" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        frontend.bind_changeset_review(handover_over(frontend.review_surface))

        expect(run("LainReviewVerdict approve")).to include("ok" => true)
        expect(wait_until { messages[/approve/] }).to include("approve")
      end
    end

    # ANSWERED, and the editor with no review open is the ordinary state of
    # every session: the command refuses with {NoReviewWrites}'s own sentence
    # rather than acking a verdict nothing recorded.
    it "refuses with the unopened-review sentence when no review is bound" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        expect(run("LainReviewVerdict approve")).to include("ok" => true)
        expect(refusal_shown).to include("no review is open in this editor")
      end
    end

    # THE OTHER HALF OF EVERY REFUSAL ABOVE, asserted once rather than three
    # times: none of them may cost the human a traceback. It is a separate
    # example because the three above are about WHAT lain said and this is about
    # how it arrived, which no assertion on the sentence can state.
    #
    # ANCHORED ON `refusal_shown` FIRST, and that is not ceremony. A bare
    # negative passes vacuously if either command silently no-ops, and worse, it
    # RACES the echo it is looking past -- `refusal_shown` exists in this file
    # precisely because the command returns before nvim has necessarily flushed.
    # Waiting for the refusal to land is what makes the absence of a traceback
    # beside it mean anything.
    it "shows no Lua stack traceback for any of those refusals" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        frontend.bind_changeset_review(review)

        expect(run("LainReviewVerdict looks-fine")).to include("ok" => true)
        expect(refusal_shown).to include(*Lain::Review::VERDICTS)
        expect(run("LainReviewVerdict")).to include("ok" => true)

        expect(messages).not_to include("stack traceback")
      end
    end
  end
end

# The measurement the doubles above cannot make: a real fifty-file corpus, a
# real {Lain::Review::Session}, and B8's `chunker:` seam counting at the
# CHUNKER's own `#call` -- so "the sidebar read nothing" is an observation about
# work that did not happen rather than a flag the subject set about itself.
#
# It is here rather than in `corpus_spec.rb` because the offender was the
# SURFACE: `Session.open` and `Session#present` were already lazy, and the view
# chunked all fifty afterwards.
RSpec.describe Lain::Frontend::Neovim::ReviewView, "over a real corpus", :seam do
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
