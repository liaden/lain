# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# T14: `lain://review`, the changeset review's navigator -- the two scopes it
# renders, the line -> target map it builds in the same pass, and the gesture it
# resolves against the rendering the human is actually looking at.
#
# The changeset duck is the one `Lain::Review::Surface`'s class doc states
# (`#files` / `#by_commit`), plus the two members that doc does not name and
# this view needs: a file entry's `#hunks` (for the new-side line an open lands
# on) and a commit entry's `#numstat`. `Lain::Review::Changeset` (T7) and the
# session that joins it to `Marks` (T13) are both unlanded, so the doubles here
# ARE the statement of what they have to answer.
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

  def file_entry(path:, state: "unreviewed", first: 1)
    Struct.new(:path, :state, :hunks).new(path, state, [hunk(path:, new_start: first)])
  end

  # `#added` / `#deleted` as SCALARS on the commit entry, and NOT reached
  # through `#numstat`. `Changeset::CommitScope#numstat` is a frozen Array of
  # per-file stats, so it answers neither -- a double that invented an aggregate
  # behind that name would read as satisfied while the real object crashed the
  # walk. The `numstat:` member is carried here in its REAL shape so the two
  # facts sit side by side in the fixture.
  def commit_entry(subject:, files:, added: 1, deleted: 0, stats: [])
    Struct.new(:subject, :files, :numstat, :added, :deleted)
          .new(subject, files, stats.freeze, added, deleted)
  end

  def file_stat(path:, added:, deleted:) = Struct.new(:path, :added, :deleted).new(path, added, deleted)

  def changeset(files: [], commits: [])
    Struct.new(:files, :by_commit).new(files, commits)
  end

  # Where a resolved row is actually opened -- {ReviewView::Unwired}'s duck,
  # recording what it was asked for so "no file is opened" is an observation
  # rather than a tautology.
  def recorder(answer: nil)
    calls = []
    Object.new.tap do |port|
      port.define_singleton_method(:calls) { calls }
      port.define_singleton_method(:open) { |path, line| calls.push([path, line]) && answer }
    end
  end

  describe "the two scopes" do
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

    # The T7 panel's measurement: with a merge in the range, `by_commit`
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

    it "refuses a scope that is not one of Review::SCOPES" do
      expect { view.render(changeset, scope: :cumulatve) }.to raise_error(KeyError)
    end

    it "dispatches on exactly the scopes the vocabulary declares" do
      expect(described_class::SCOPE_ROWS.keys.map(&:to_s)).to match_array(Lain::Review::SCOPES)
    end
  end

  # The BLOCKER a review panel found: `Changeset::CommitScope#numstat` is an
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

    it "never reaches through #numstat, which answers no aggregate at all" do
      commit = Struct.new(:subject, :files, :numstat).new("Add the thing", [], [].freeze)

      expect { view.render(changeset(commits: [commit]), scope: :commits) }
        .to raise_error(NoMethodError, /added/)
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
      expect(described_class::PLACEHOLDERS.values.uniq.size).to eq(2)
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

    def duplicated_file(hunks) = Struct.new(:path, :state, :hunks).new("lib/dup.rb", "unreviewed", hunks)

    it "resolves a file row to exactly the keys Marks would derive for that file" do
      rendered = view.render(changeset(files:), scope: :cumulative)

      outcome = view.marks(2, generation: rendered.generation)

      expect(outcome).to have_attributes(marked?: true, hunk_keys: Lain::Review::Hunk.keys(files.last.hunks))
    end

    it "keys a nested row from the WHOLE file, never from the subset that commit reached" do
      whole = duplicated_pair
      cumulative = duplicated_file(whole)
      commits = [commit_entry(subject: "one", files: [duplicated_file([whole.first])])]
      rendered = view.render(changeset(files: [cumulative], commits:), scope: :commits)

      # 1 legend, 2 commit header, 3 lib/dup.rb
      outcome = view.marks(3, generation: rendered.generation)

      expect(outcome.hunk_keys).to eq(Lain::Review::Hunk.keys(whole))
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
