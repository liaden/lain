# frozen_string_literal: true

require "async"
require "stringio"
require "tmpdir"

# The baton, recorded: what an epic hands a changeset review, reduced to the one
# message {Lain::Review::Handover} sends it. `verdict_at_settle` is what makes
# the ORDER assertable -- the handover promises that the round is judged before
# the baton is settled, and the only moment that is observable is inside this
# call.
class RecordingBaton
  def initialize(session:, raising: nil)
    @session = session
    @raising = raising
    @settles = 0
  end

  attr_reader :settles, :verdict_at_settle

  def settle
    @settles += 1
    @verdict_at_settle = @session.verdict.to_s
    raise @raising unless @raising.nil?

    :settled
  end
end

# The rendering, recorded: {Lain::Frontend::Neovim::ReviewView}'s two gesture
# messages in their own answer shapes. Used only where a REAL view cannot
# produce the case -- a session refusing the second of a row's keys, which no
# real rendering of a real changeset can arrange, because a real view cuts its
# keys from the same changeset the session holds.
class StubReviewView
  def initialize(opened: nil, marked: nil)
    @opened = opened
    @marked = marked
  end

  def open(_line, generation:) = @opened || refused_open(generation)

  def marks(_line, generation:) = @marked || refused_marks(generation)

  private

  def refused_open(generation)
    Lain::Frontend::Neovim::ReviewView::Opened.new(path: nil, line: nil, report: "no rendering #{generation}")
  end

  def refused_marks(generation)
    Lain::Frontend::Neovim::ReviewView::Marked.new(hunk_keys: [].freeze, report: "no rendering #{generation}")
  end
end

# The editor's render inlet, reduced to the one message a
# {Lain::Frontend::Neovim::ChangesetDiff} sends it, and answering nothing --
# which is what says the pair was accepted.
#
# `changeset_diff_spec.rb` carries the same recorder for its single-subject
# pins. Duplicated rather than shared through `spec/support/`, which
# `spec_helper` globs into every worker of every run: two files needing one
# recorder is not yet a reason to load it into all of them.
class RecordingSurveyInlet
  def initialize
    @opened = []
  end

  # @return [Array<String>] the path of every pair posted, in order
  attr_reader :opened

  def open_changeset(path, _old_lines, _line, _revisions)
    @opened << path
    nil
  end
end

RSpec.describe Lain::Review::Handover do
  # `session_spec.rb`'s fixture, at the size this card needs: one file with two
  # hunks (so a row names more than one key and a partial mark is expressible)
  # and a second file (so a refusal can name one and not the other).
  def diff
    <<~DIFF
      diff --git a/a.rb b/a.rb
      index 1111111..2222222 100644
      --- a/a.rb
      +++ b/a.rb
      @@ -1,3 +1,3 @@ def alpha
       one
      -two
      +TWO
      @@ -10,3 +10,3 @@ def beta
       ten
      -eleven
      +ELEVEN
      diff --git a/b.rb b/b.rb
      index 3333333..4444444 100644
      --- a/b.rb
      +++ b/b.rb
      @@ -1,2 +1,2 @@ def gamma
       x
      -y
      +Y
    DIFF
  end

  def base_sha = -("b" * 40)

  def head_sha = -("h" * 40)

  # Both files attributed, because a changeset whose diff names a file no
  # commit's numstat does is one `Partition::ByCommit` refuses -- and every
  # rendering below walks it.
  def commit(sha:, subject:, path:)
    Lain::Review::Source::Commit.new(
      sha: -sha, subject: -subject, body: "",
      numstat: [Lain::Review::Source::FileStat.new(path: -path, added: 3, deleted: 1)].freeze
    )
  end

  def commits
    [commit(sha: "c" * 40, subject: "first: touch a", path: "a.rb"),
     commit(sha: "d" * 40, subject: "second: touch b", path: "b.rb")]
  end

  def source_double
    DiffSource.over(instance_double(Lain::Review::Source::LocalBranch,
                                    diff: diff.b, commits: commits.freeze,
                                    base_ref: base_sha, head_ref: head_sha))
  end

  def keys_for(path)
    Lain::Review::Hunk.keys(changeset.hunks.select { |hunk| hunk.path == path })
  end

  # The note as {Lain::Frontend::Neovim::ReviewWrite} normalizes it: exactly its
  # KEYS, String-keyed, every closed member already judged. Spelled out here
  # rather than built through that class, so this spec pins what the HANDOVER
  # does with a note rather than what the boundary does to one.
  def note(**overrides)
    { "path" => "a.rb", "side" => "new", "line" => 3, "anchor_text" => "TWO",
      "text" => "this reads backwards", "kind" => "note", "revision" => head_sha,
      "drifted" => false }.merge(overrides.transform_keys(&:to_s))
  end

  let(:changeset) { Lain::Review::Changeset.new(source: source_double) }
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:surface) { Lain::Review::Surface::Null.new }
  let(:policy) { Lain::Review::Verdict::Policy::Permissive.new }
  let(:session) do
    Lain::Review::Session.open(changeset:, journal:, source: "local_branch", surface:, policy:)
  end
  let(:baton) { RecordingBaton.new(session:) }

  def records_of(type) = Lain::Journal.records(io.string.lines, type:).to_a

  def handover(**overrides) = described_class.new(session:, baton:, **overrides)

  describe "a verdict written in the editor" do
    it "submits it to the session, journaled against the changeset it judged" do
      handover.wrote_verdict("approve")

      expect(records_of("review_verdict").map { |record| record.values_at("verdict", "changeset_digest") })
        .to eq([["approve", session.digest]])
    end

    it "answers nothing, which is how the editor's :w succeeds" do
      expect(handover.wrote_verdict("approve")).to be_nil
    end

    it "settles the baton, which is what wakes whoever is parked on the review" do
      handover.wrote_verdict("approve")

      expect(baton.settles).to eq(1)
    end

    # The ordering the whole park rests on: the fiber that settling wakes must
    # not be able to observe a closed review with no judgement on it. Asserted
    # from INSIDE the settle, because that is the only instant the two states
    # are distinguishable.
    it "submits BEFORE it settles, so nothing wakes to a review with no verdict on it" do
      handover.wrote_verdict("approve")

      expect(baton.verdict_at_settle).to eq("approve")
    end

    # `Verdict::Policy` refuses an approve over hunks nobody read. A refusal
    # leaves the round OPEN -- which is what lets the human mark the rest and
    # answer again -- so the baton must not have been settled.
    it "answers a refusing policy in words, and leaves the baton unsettled" do
      refusing = handover(session: Lain::Review::Session.open(changeset:, journal:, source: "local_branch",
                                                              surface:, policy: Lain::Review::Verdict::Policy.default))
      refusal = refusing.wrote_verdict("approve")

      expect(refusal).to be_a(String).and include("unreviewed")
      expect([baton.settles, records_of("review_verdict")]).to eq([0, []])
    end

    # First-answer-wins ({Approval::Queue::Pending#decide}'s rule), and it is
    # the SESSION's refusal rather than a flag here.
    it "answers a second verdict with a sentence rather than judging twice" do
      handover.wrote_verdict("approve")
      second = handover.wrote_verdict("approve")

      expect(second).to be_a(String)
      expect(records_of("review_verdict").size).to eq(1)
    end

    # The rail's rule, and the reason the rescue is wide: this method's return
    # value is what an editor's `:w` fails with, and a raise instead reaches
    # RpcThread#answer, which answers the editor and then re-raises -- ending
    # the session over a verdict. A baton whose generation is no longer open is
    # exactly the reachable case.
    it "answers a baton that refuses in words, never by raising" do
      stale = Lain::Epic::Review::NotOpen.new("generation 1 is not open")
      refusing = handover(baton: RecordingBaton.new(session:, raising: stale))

      expect { @answer = refusing.wrote_verdict("approve") }.not_to raise_error
      expect(@answer).to include("not open")
    end

    it "answers a verdict outside the vocabulary in words, rather than raising" do
      expect { @answer = handover.wrote_verdict("lgtm") }.not_to raise_error
      expect(@answer).to be_a(String).and include("approve")
      expect(baton.settles).to eq(0)
    end
  end

  # The cut this card is defined by: what an epic supplies is a BATON, and a
  # review opened outside one supplies a null whose settle is genuinely nothing.
  # If this needed behaviour, settling would belong to the epic and the object
  # would be in the wrong place.
  describe "a review with no baton behind it" do
    subject(:unheld) { described_class.new(session:) }

    it "still submits the verdict and journals it" do
      expect(unheld.wrote_verdict("approve")).to be_nil
      expect(records_of("review_verdict").size).to eq(1)
    end

    it "is a no-op that answers nothing" do
      expect(Lain::Review::Handover::Unheld.settle).to be_nil
    end

    # A null that had to be TOLD anything -- a generation, a path, an epic --
    # would mean the baton was not the seam.
    it "takes no arguments at all, which is what makes it genuinely null" do
      expect(Lain::Review::Handover::Unheld.method(:settle).arity).to eq(0)
    end
  end

  describe "a note written in the editor" do
    it "journals it as an annotation at the position the wire named" do
      handover.wrote_annotation(note)

      expect(records_of("annotation_placed").first)
        .to include("path" => "a.rb", "side" => "new", "line" => 3, "text" => "this reads backwards",
                    "kind" => "note", "revision" => head_sha)
    end

    it "answers nothing, which is how the editor's :w succeeds" do
      expect(handover.wrote_annotation(note)).to be_nil
    end

    # THE MEASUREMENT IS FORWARDED, NEVER COMPUTED, and this is the example that
    # says so. `anchor_text` here is exactly what the diff's new side reads at
    # that line, so an implementation that measured drift ITSELF -- anchor text
    # against the diff it holds -- would answer false and journal false. Only a
    # forwarding one journals true.
    it "records drift as the editor measured it, over a line whose text still matches" do
      handover.wrote_annotation(note(anchor_text: "TWO", drifted: true))

      expect(records_of("annotation_placed").first["drifted"]).to be(true)
    end

    # The other direction of the same property, so "always journals true" is not
    # a passing implementation either.
    it "records a note that did not drift as one that did not, over text that no longer matches" do
      handover.wrote_annotation(note(anchor_text: "nothing like the diff", drifted: false))

      expect(records_of("annotation_placed").first["drifted"]).to be(false)
    end

    # The revision is the ANCHOR's -- the diff the human was looking at -- and
    # not the changeset's head. That is the whole reason the record carries one:
    # an annotation authored against one diff and submitted against another has
    # to stay detectable.
    it "records the revision the editor authored against, not the changeset's head" do
      handover.wrote_annotation(note(revision: "e" * 40))

      expect(records_of("annotation_placed").first["revision"]).to eq("e" * 40)
    end

    it "keeps the note in the session's own annotations, in placement order" do
      handover.wrote_annotation(note(text: "first"))
      handover.wrote_annotation(note(text: "second"))

      expect(session.annotations.map(&:text)).to eq(%w[first second])
    end

    # The boundary judges a note's shape before this rail ever sees it, so this
    # is defence in depth rather than the first check -- but a raise here costs
    # the human their editor session, and one dropped key is all it takes.
    it "answers a note whose kind is outside the vocabulary in words, never by raising" do
      expect { @answer = handover.wrote_annotation(note(kind: "nitpick")) }.not_to raise_error
      expect(@answer).to be_a(String)
      expect(records_of("annotation_placed")).to be_empty
    end

    it "answers a note carrying no line in words, never by raising" do
      expect { @answer = handover.wrote_annotation(note(line: 0)) }.not_to raise_error
      expect(@answer).to be_a(String)
    end
  end

  describe "the sidebar's open gesture" do
    # `review_view_spec.rb`'s own idiom for the diff pair: nothing here pretends
    # to be the object that will one day answer it (T31b's), and the calls are
    # recorded rather than asserted into place.
    let(:opener) do
      calls = []
      Object.new.tap do |port|
        port.define_singleton_method(:calls) { calls }
        port.define_singleton_method(:open) { |path, line| calls.push([path, line]) && nil }
      end
    end
    let(:view) { Lain::Frontend::Neovim::ReviewView.new(changesets: opener) }

    # A REAL view, rendered, so the row a line names is the one the human is
    # looking at rather than one a double asserted into place -- and the line is
    # READ OFF the rendering, so this cannot pass by counting rows the same way
    # twice.
    def rendered = view.render(session.marked, scope: :cumulative)

    def row_of(rendering, path) = rendering.lines.index { |line| line.include?(path) } + 1

    it "opens the file the row names, through the view that drew it" do
      rendering = rendered

      opened = handover(view:).open(row_of(rendering, "a.rb"), generation: rendering.generation)

      expect([opened.opened?, opened.path]).to eq([true, "a.rb"])
      expect(opener.calls).to eq([["a.rb", 1]])
    end

    # Without a counter-example a stamp-checking implementation and one that
    # ignores the stamp are indistinguishable.
    it "refuses a stamp the view never issued, in the view's own words" do
      rendering = rendered

      opened = handover(view:).open(row_of(rendering, "a.rb"), generation: 99)

      expect(opened.opened?).to be(false)
      expect(opened.report).to include("never issued")
      expect(opener.calls).to be_empty
    end

    it "refuses when no editor is attached, saying THAT rather than blaming the row" do
      opened = handover.open(2, generation: 1)

      expect([opened.opened?, opened.report]).to eq([false, Lain::Review::Handover::Detached::NO_EDITOR])
    end
  end

  describe "the sidebar's mark gesture" do
    let(:view) { Lain::Frontend::Neovim::ReviewView.new }

    def rendered = view.render(session.marked, scope: :cumulative)

    def row_of(rendering, path) = rendering.lines.index { |line| line.include?(path) } + 1

    # `a.rb` and not `b.rb` deliberately: it carries TWO hunks, so an
    # implementation marking the row's first key and stopping is distinguishable
    # from one marking every key the row names.
    it "marks every hunk the row names, because a row IS a file" do
      rendering = rendered

      marked = handover(view:).mark(row_of(rendering, "a.rb"), "reviewed", generation: rendering.generation)

      expect(marked.marked?).to be(true)
      expect(records_of("hunk_marked").map { |record| record["hunk_key"] }).to eq(keys_for("a.rb"))
    end

    it "records the state the wire carried, never a toggle computed here" do
      rendering = rendered

      handover(view:).mark(row_of(rendering, "a.rb"), "unreviewed", generation: rendering.generation)

      expect(records_of("hunk_marked").map { |record| record["state"] }.uniq).to eq(["unreviewed"])
    end

    it "refuses a stamp the view never issued, and marks nothing" do
      rendering = rendered

      marked = handover(view:).mark(row_of(rendering, "a.rb"), "reviewed", generation: 99)

      expect([marked.marked?, records_of("hunk_marked")]).to eq([false, []])
    end

    # `Review::Session#mark` RAISES what `Surface::Neovim::Unbound` answers as a
    # value, which is why this object folds the refusal itself. A raise here
    # would escape into the reply consumer's fiber, which rescues only
    # NoMethodError.
    it "answers a state outside the vocabulary in words, never by raising" do
      stamp = rendered.generation

      expect { @marked = handover(view:).mark(2, "skimmed", generation: stamp) }.not_to raise_error
      expect([@marked.marked?, records_of("hunk_marked")]).to eq([false, []])
    end

    # The batch hazard, named. A row whose second key the session refuses leaves
    # the first recorded, and the human is owed that fact rather than a bare
    # refusal -- `#marked?` still answers no, because the gesture did not land.
    it "reports a row the session took only half of, rather than claiming nothing happened" do
      half = StubReviewView.new(
        marked: Lain::Frontend::Neovim::ReviewView::Marked.new(
          hunk_keys: [keys_for("a.rb").first, "not-a-key-this-changeset-produces"].freeze, report: "a.rb"
        )
      )

      marked = handover(view: half).mark(2, "reviewed", generation: 1)

      expect(marked.marked?).to be(false)
      expect(marked.report).to include("1 of 2").and include("partly marked")
      expect(records_of("hunk_marked").size).to eq(1)
    end

    it "refuses when no editor is attached" do
      marked = handover.mark(2, "reviewed", generation: 1)

      expect([marked.marked?, marked.report]).to eq([false, Lain::Review::Handover::Detached::NO_EDITOR])
    end
  end

  # THE CARD'S ACCEPTANCE TEST, and it needs a SURVEY. Every group above opens
  # with `source: "local_branch"`, where a file is chunked the moment the parser
  # produces it, so `#chunked?` is true before any gesture and none of them can
  # see the defect: over a corpus every file is `added`,
  # {Lain::Review::Changeset#old_side} short-circuits on `old_path`, and the
  # `<CR>` that draws the diff pair never asked the file for a hunk. The row then
  # carried no key, and marking it was refused for a file the human was reading.
  #
  # A real {Lain::Review::Source::Corpus} over a real directory, a real
  # {Lain::Review::Changeset}, a real {Lain::Review::Session}, a real
  # {Lain::Frontend::Neovim::ReviewView} and a real
  # {Lain::Frontend::Neovim::ChangesetDiff} -- no double between any two of them,
  # because the defect lived in the join rather than in any one of them. B8's
  # `chunker:` seam counts at the chunker's own `#call`, so what is asserted is
  # work that happened rather than a flag a subject set about itself.
  #
  # == THE REDRAW BETWEEN THE GESTURES HAS NO PRODUCTION CALLER
  #
  # Read this before reading the examples as a claim that the cockpit works,
  # because they are green over a sequence the cockpit cannot currently execute.
  #
  # A row's `hunk_keys` are cut at RENDER time and carried
  # ({Frontend::Neovim::ReviewView}'s own doc says why they are not re-derived),
  # so a rendering drawn before the file was read names no key however read the
  # file now is. Every helper below therefore redraws before each gesture -- and
  # NOTHING IN `lib/` DOES THAT. `CLI::HumanReplies::Gestures#open_hunk` and
  # `#mark_hunk` forward and return; `Surface::Neovim#mark` posts a notice;
  # `46_sidebar.lua` changes the sidebar only through `set_review`. `present` is
  # called once, when the round opens.
  #
  # So in a live editor today: `<CR>` reads the file (which is what this card
  # fixed and what these examples pin), and the `x` after it still resolves
  # against the pre-open rendering and still answers {ReviewView::UNREAD} -- and
  # a mark that DOES land still leaves the row drawn `[ ]`, because nothing
  # re-presents after a mark either. One `present` after each gesture closes the
  # whole loop, verdict included; it is a filed follow-up card, and every file
  # that could do it is outside T15's scope. What is proven here is the read
  # registration, not the cockpit round trip.
  describe "a survey opened over a directory", :seam do
    let(:chunked) { [] }
    let(:inlet) { RecordingSurveyInlet.new }
    let(:opener) { Lain::Frontend::Neovim::ChangesetDiff.new(rpc: inlet) }
    let(:survey_view) { Lain::Frontend::Neovim::ReviewView.new(changesets: opener) }
    let(:survey) { Lain::Review::Changeset.new(source: corpus) }
    let(:baton) { RecordingBaton.new(session: survey_session) }
    let(:survey_session) do
      Lain::Review::Session.open(changeset: survey, journal:, source: "corpus", surface:,
                                 policy: Lain::Review::Verdict::Policy.default)
    end

    around do |example|
      Dir.mktmpdir("lain-handover-survey") do |made|
        @root = File.realpath(made)
        surveyed.each { |name| File.binwrite(File.join(@root, name), document(name)) }
        example.run
      end
    end

    before { survey_view.reviewing(survey) }

    # Two files, so "opening one row read one file" is distinguishable from
    # "opening one row read the survey", and so an approve can be refused over
    # the one nobody opened.
    def surveyed = %w[alpha.md beta.md]

    # Sections rather than a paragraph, because the chunker's granularity floor
    # merges a runt backwards -- a two-line file chunks to one unit and hides
    # every difference between a partial mark and a full one.
    def document(name) = (1..4).map { |n| "## #{name} #{n}\n\nbody #{n} one.\nbody #{n} two.\n\n" }.join

    # The real dispatch, wrapped so every chunking is logged with its path --
    # `review_view_spec.rb`'s counter and its reason: counting at the DISPATCH
    # would call a corpus that resolves eagerly and chunks lazily eager.
    def counting(log)
      lambda do |for_path|
        chunker = Lain::Survey::Chunker.for(for_path)
        lambda do |path:, source:|
          log << path
          chunker.call(path:, source:)
        end
      end
    end

    def corpus
      sensitivity = Lain::Sensitivity.new(home: "/home/surveyor", cwd: @root)
      Lain::Review::Source::Corpus.new(walk: Lain::Survey::Walk.new(root: @root, sensitivity:),
                                       projection: Lain::Survey::Projection.new(ledger:),
                                       chunker: counting(chunked))
    end

    def ledger = @ledger ||= Lain::Sensitivity::Ledger.new

    # A corpus answers no commit walk, so the flat scope is the only one it can
    # be grouped by -- `MarkedChangeset::WALK` would be refused by the strategy
    # rather than by anything this card is about.
    def cumulative = Lain::Review::Partition::STRATEGIES.fetch(:cumulative)

    def drawn = survey_view.render(survey_session.marked(strategy: cumulative), scope: :cumulative)

    def row_of(rendering, path) = rendering.lines.index { |line| line.include?(path) } + 1

    def gestures = described_class.new(session: survey_session, view: survey_view, baton:)

    # Each gesture resolves against the rendering the human is looking at, which
    # is the one drawn immediately before it -- the stamp is what makes that
    # true rather than a comment.
    def open_row(path)
      rendering = drawn
      gestures.open(row_of(rendering, path), generation: rendering.generation)
    end

    def mark_row(path, state = "reviewed")
      rendering = drawn
      gestures.mark(row_of(rendering, path), state, generation: rendering.generation)
    end

    # The whole survey, worked the way a human works one: open a row, mark it,
    # move on. Each gesture redraws first, so every one of them resolves against
    # the rendering it came from.
    def worked_through
      surveyed.each do |path|
        open_row(path)
        mark_row(path)
      end
    end

    it "opens the real file the row names, through the diff surface the view was wired with" do
      opened = open_row("alpha.md")

      expect([opened.opened?, opened.path]).to eq([true, "alpha.md"])
      expect(inlet.opened).to eq(["alpha.md"])
    end

    it "makes a row markable once the open gesture has read it" do
      open_row("alpha.md")

      marked = mark_row("alpha.md")

      expect(marked.marked?).to be(true)
      expect(drawn.lines).to include("[x] alpha.md")
    end

    # The counter-example, and the guard on the sentence: a row nobody opened
    # still refuses, and the refusal names the file and the keystroke that would
    # read it rather than claiming there is nothing there.
    it "refuses a row nothing has read, naming the file and the gesture that reads it" do
      marked = mark_row("beta.md")

      expect(marked.marked?).to be(false)
      expect(marked.report).to include("beta.md").and include("<CR>")
    end

    it "admits an approve over a survey whose every file has been opened and marked" do
      worked_through

      expect(gestures.wrote_verdict("approve")).to be_nil
      expect(records_of("review_verdict").map { |record| record["verdict"] }).to eq(["approve"])
    end

    # BOUNDING GUARD, green against the unfixed tree -- it was satisfied by a
    # survey nothing could read at all. It is here so the scenario above cannot
    # be passed by a fix that credits every file as read on the first gesture.
    it "still refuses an approve while a file of the survey is unread" do
      open_row("alpha.md")
      mark_row("alpha.md")

      expect(gestures.wrote_verdict("approve")).to include("beta.md")
      expect(records_of("review_verdict")).to be_empty
    end

    # Registering the read reaches the disk, which the open gesture never did
    # for a survey before this card -- so a file gone by the time the `<CR>`
    # arrives is a NEW raise site on the fiber that serves the editor's
    # commands, where an exception ends the session over one keystroke.
    #
    # Driven rather than simulated: the file is really unlinked and the real
    # un-memoized `Corpus::Reading#content` really fails. The survey is drawn
    # first, because the identity pass reads every file and this example is
    # about the SECOND read, not the first.
    it "survives a file deleted between the survey and the gesture, leaving it unread" do
      drawn
      File.unlink(File.join(@root, "alpha.md"))

      opened = open_row("alpha.md")

      expect(opened.opened?).to be(true)
      expect(mark_row("alpha.md").report).to include("nothing has read")
    end

    # The latency question the card raises: reads now register EARLIER, and
    # `Verdict::Policy::EveryHunk#admit!` walks `changeset.hunks` whole. If the
    # open gesture's read were a second derivation rather than the same memo,
    # approving a survey would chunk every file twice.
    it "chunks each file exactly once across the whole round, approve included" do
      worked_through
      gestures.wrote_verdict("approve")

      expect(chunked.tally).to eq(surveyed.to_h { |path| [path, 1] })
    end

    # Drawing is still free. The read belongs to the OPEN gesture, and a fix
    # that put it on the render would undo b45553e -- which is what
    # `review_view_spec.rb`'s raising `unread_entry` double pins from the other
    # side.
    it "draws the whole survey having read nothing, before any gesture" do
      expect(drawn.lines).to eq(["[ ] alpha.md", "[ ] beta.md"])
      expect(chunked).to be_empty
    end
  end

  # The docent is a DELETABLE capability (`spec/lain/review/deletability_spec.rb`
  # owns the map), so neither the subject nor this file may name it in code --
  # which is why what stands in below is a recorder answering the one message the
  # handover sends, and not a double of that class.
  describe "the docent gesture" do
    it "hands the question to whoever answers one, unchanged" do
      answer = Struct.new(:asked?, :report).new(true, "asked")
      asked = []
      docent = Object.new
      docent.define_singleton_method(:ask) { |anchor_id, question| asked << [anchor_id, question] and answer }

      expect(handover(docent:).ask("anchor-1", "why this way?")).to be(answer)
      expect(asked).to eq([["anchor-1", "why this way?"]])
    end

    # Nothing in this tree constructs one, so this is what the gesture honestly
    # answers until something does -- in the shape `Gestures` asks of it, so the
    # human gets the sentence rather than a NoMethodError.
    it "refuses in words when no docent is wired, in the shape the consumer asks for" do
      asked = handover.ask("anchor-1", "why this way?")

      expect([asked.asked?, asked.report]).to eq([false, Lain::Review::Handover::Unattended::NO_DOCENT])
    end
  end

  # THE ANSWERED RAIL RUNS ON THE RPC THREAD, inside the human's `:w`, while the
  # call that opened the review is parked on a fiber in the reactor. Every other
  # editor answer in this tree leaves through a QUEUE for that reason --
  # `QuestionView`'s doc says a promise "must be resolved on the reactor thread"
  # -- and a verdict cannot: its return value is the editor's answer, so it has
  # to settle synchronously and wake the parked fiber from where it stands.
  #
  # Measured rather than assumed. `Async::Variable`'s condition is a
  # `Thread::Queue` in async 2.42.0 (it holds no fibers of its own), so a
  # cross-thread resolve reaches a parked fiber through the scheduler exactly as
  # a same-thread one does. This is the example that would go red if that ever
  # stopped being true -- which is the only reason the rail is direct.
  describe "a verdict written on a thread that is not the reactor's", :seam do
    it "wakes the fiber parked on the baton's promise, without raising on either side" do
      promise = Lain::Promise.new
      settled = described_class.new(session:, baton: Class.new do
        define_method(:settle) { promise.resolve(:woken) }
      end.new)
      woken = nil

      Sync do |task|
        parked = task.async { woken = promise.await }
        task.yield
        Thread.new { settled.wrote_verdict("approve") }.join
        parked.wait
      end

      expect(woken).to eq(:woken)
      expect(records_of("review_verdict").size).to eq(1)
    end
  end
end
