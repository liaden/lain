# frozen_string_literal: true

require "async"
require "fileutils"
require "mixlib/shellout"
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

# {RecordingSurveyInlet} with the SIDEBAR rail as well, which is the rail a
# re-presentation rides. One recorder rather than two, because in a live cockpit
# there is one {Lain::Frontend::Neovim::RenderInlet}: the diff pair a `<CR>`
# posts and the rows drawn after it go out of the same door, in that order, and
# a fixture that split them could not show that.
#
# The sidebar rail is RECORDED rather than doubled because what the redraw
# examples assert is that a second rendering was posted at all -- a `present`
# recorded on a double of the surface would be the assertion standing in for its
# own subject.
class RecordingCockpitInlet < RecordingSurveyInlet
  def initialize
    super
    @drawn = []
  end

  # @return [Array<Array(Array<String>, Integer, Array<String>)>] the lines of
  #   every rendering posted, the stamp it was posted under and the sides the
  #   round said it presents, oldest first
  attr_reader :drawn

  def set_review(lines, generation, sides) = (@drawn << [lines, generation, sides]) && nil

  def review_refused(_message) = nil

  def set_thread(*) = nil

  # Counted rather than ignored, for the one law below that is about this rail
  # NOT firing: a rail nobody records cannot be shown to have stayed quiet.
  def review_focus = (@focused = (@focused || 0) + 1)

  def focused = @focused || 0
end

# A sink that has already lost its destination. `IOError` and not a
# `Lain::Error`, deliberately: that is what a real `IO` answers once it is
# closed, and it is the shape that escapes every rescue on the verdict rail --
# which is exactly why the acknowledgement has to be unable to ride it out.
module ClosedSink
  module_function

  def write(*) = raise(IOError, "the editor's socket is gone")
end

# The rails a close lets go of, recorded: {Lain::CLI::HumanReplies}' one
# message that binds both of them, whose nil is the unbind.
class RecordingReviewRails
  def initialize(bound) = (@bound = bound)

  attr_reader :bound

  def bind_changeset_review(review) = @bound = review
end

# The one round a chat holds, at the two messages a close sends it. A stand-in
# rather than the real outbox, which is a deletable capability no file outside
# its own row may name (`deletability_spec.rb`); the real one is driven through
# a close end to end in `command/review_spec.rb`, and pinned in its own spec.
class RecordingCloseOutbox
  def initialize(session:, label:)
    @session = session
    @label = label
  end

  def open? = !@session.nil?
  def target = @label

  def close
    raise Lain::Error, "nothing to close" unless open?

    @session.close(by: Lain::Review::ChangesetClosed::BY_HUMAN)
    @session = nil
    @label
  end

  def release(session)
    @session = nil if @session.equal?(session)
    self
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

  # What each revision holds, so a note's evidence can be read out of the
  # objects the way a real source reads it with `git show`.
  def blobs
    { [base_sha, "a.rb"] => "one\ntwo\nthree\n", [head_sha, "a.rb"] => "one\nTWO\nthree\n",
      [base_sha, "b.rb"] => "x\ny\n", [head_sha, "b.rb"] => "x\nY\n" }
  end

  def source_double
    held = blobs
    double = instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, commits: commits.freeze,
                                                                base_ref: base_sha, head_ref: head_sha)
    allow(double).to receive(:file_at) { |revision, path| held[[revision, path]]&.b }
    DiffSource.over(double)
  end

  def keys_for(path)
    Lain::Review::Hunk.keys(changeset.hunks.select { |hunk| hunk.path == path })
  end

  # The note as {Lain::Frontend::Neovim::ReviewWrite} normalizes it: exactly its
  # KEYS, String-keyed, every closed member already judged. Spelled out here
  # rather than built through that class, so this spec pins what the HANDOVER
  # does with a note rather than what the boundary does to one.
  def note(**overrides)
    { "path" => "a.rb", "side" => "new", "line" => 2, "anchor_text" => "TWO",
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
    # A surface that can be READ back, for the acknowledgement examples alone:
    # {Surface::Null} is what every other example here wants (a review model
    # spec has no business rendering), and it is by construction unable to show
    # that anything was said.
    let(:transcript) { StringIO.new }
    let(:text_surface) { Lain::Review::Surface::Text.new(sink: transcript) }
    let(:spoken_session) do
      Lain::Review::Session.open(changeset:, journal:, source: "local_branch", surface: text_surface, policy:)
    end
    let(:spoken) { described_class.new(session: spoken_session, baton: RecordingBaton.new(session: spoken_session)) }

    it "submits it to the session, journaled against the changeset it judged" do
      handover.wrote_verdict("approve")

      expect(records_of("review_verdict").map { |record| record.values_at("verdict", "changeset_digest") })
        .to eq([["approve", session.digest]])
    end

    it "answers nothing, which is how the editor's :w succeeds" do
      expect(handover.wrote_verdict("approve")).to be_nil
    end

    # THE ACKNOWLEDGEMENT, and it has to be a PUSH rather than the return value
    # the example above pins: `nil` is what the editor's `:w` succeeds on, so
    # the only place a word can go is out through the surface. Driven over a
    # REAL {Surface::Text} rather than a double, because what this asserts is
    # that something left the surface -- a double recording "#settle was called"
    # would prove the call and not the sentence.
    it "tells the surface the verdict landed, naming the word" do
      spoken.wrote_verdict("approve")

      expect(transcript.string).to match(/\bapprove\b/)
    end

    # The other half, and the one that makes the acknowledgement worth having:
    # a policy that refuses leaves the round OPEN, so a surface told "approved"
    # over a review nobody approved is worse than the silence this card is
    # fixing. Nothing at all may reach it.
    it "acknowledges nothing when the policy refuses the verdict" do
      refusing = described_class.new(session: Lain::Review::Session.open(
        changeset:, journal:, source: "local_branch", surface: text_surface,
        policy: Lain::Review::Verdict::Policy.default
      ))
      refusal = refusing.wrote_verdict("approve")

      expect(refusal).to be_a(String)
      expect(transcript.string).to be_empty
    end

    # The acknowledgement is BEST EFFORT and the verdict is not, and this is the
    # example that keeps the two apart. A surface that raises on the way out --
    # `Surface::Text`'s sink answers `IOError`, which is outside `Lain::Error`
    # and so escapes this method's rescue entirely -- would otherwise come back
    # as the refusal sentence an editor's `:w` fails with, over a verdict the
    # journal durably holds, with the baton unsettled and the retry refused as
    # AlreadySettled. There is no way back from that, so the acknowledgement
    # must not be able to cause it.
    it "still answers nothing and settles the baton when the acknowledgement could not be delivered" do
      mute = Lain::Review::Surface::Text.new(sink: ClosedSink)
      session = Lain::Review::Session.open(changeset:, journal:, source: "local_branch", surface: mute, policy:)
      unheard = RecordingBaton.new(session:)

      answer = described_class.new(session:, baton: unheard).wrote_verdict("approve")

      expect(answer).to be_nil
      expect([unheard.settles, records_of("review_verdict").size]).to eq([1, 1])
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

    # THE SENTENCE, AS A HUMAN RECEIVES IT. `wrote_verdict`'s return value is
    # what the lua half echoes on the review rail, so this is the end where
    # "can the reader do what it says" is a real question -- and the answer
    # used to be no: it offered `Verdict::Policy::Permissive.new`, a Ruby
    # constructor, to somebody holding an editor. Both halves of the
    # replacement are checked for reachability elsewhere and pinned as text
    # here: `x` is `46_sidebar.lua`'s reviewed mark key, `--permissive` is a
    # flag `/survey` and `/review` both declare.
    it "offers only remedies a human at the editor can perform, and names no Ruby constructor" do
      refusing = handover(session: Lain::Review::Session.open(changeset:, journal:, source: "local_branch",
                                                              surface:, policy: Lain::Review::Verdict::Policy.default))

      refusal = refusing.wrote_verdict("approve")

      expect(refusal).to include("a.rb").and include("`x`").and include("--permissive")
      expect(refusal).not_to match(/::|\.new\b/)
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

  # `:LainReviewClose`: a round let go with no verdict. The handover is bound to
  # both rails, so it is what the editor's close reaches -- but what a close lets
  # go of (the outbox, the rails, the sidebar) is the opener's, so it arrives as
  # a collaborator.
  describe "a close written in the editor" do
    let(:transcript) { StringIO.new }
    let(:drawn_on) { Lain::Review::Surface::Text.new(sink: transcript) }
    let(:outbox) { RecordingCloseOutbox.new(session:, label: "branch feature") }
    let(:rails) { RecordingReviewRails.new(:bound) }
    let(:closing) { described_class::Closing.new(outbox:, rails:, surface: drawn_on) }

    it "journals the close as the human's and answers nothing, which is how the editor's command succeeds" do
      expect(handover(closing:).wrote_close).to be_nil
      expect(records_of("changeset_closed").map { |record| record.values_at("changeset_digest", "closed_by") })
        .to eq([[session.digest, "human"]])
    end

    it "lets go of everything the round held: the outbox, both rails, and the sidebar's contents" do
      handover(closing:).wrote_close

      expect(outbox).not_to be_open
      expect(rails.bound).to be_nil
      expect(transcript.string).to include("branch feature").and include("closed")
    end

    it "answers a judged round's refusal in words and keeps everything it held" do
      session.submit("approve")

      expect(handover(closing:).wrote_close).to include("already judged")
      expect(outbox).to be_open
      expect(rails.bound).to eq(:bound)
      expect(records_of("changeset_closed")).to be_empty
    end

    # An epic stage's review ends with its verdict, which is what its baton is
    # waiting on; nothing binds a close to it, and the default says so in words
    # rather than raising on the rail.
    it "answers in words from a review nobody wired a close to, journaling nothing" do
      expect(handover.wrote_close).to eq(described_class::Unclosable::NOT_CLOSABLE)
      expect(records_of("changeset_closed")).to be_empty
    end
  end

  # A ceiling or scope refusal raised AFTER the rails were bound. The round is on
  # the journal already, so it is closed there too -- as the refusal's, not the
  # human's -- and nothing it held is left behind.
  describe "a refusal after the round was bound" do
    let(:transcript) { StringIO.new }
    let(:rails) { RecordingReviewRails.new(:bound) }
    let(:outbox) { RecordingCloseOutbox.new(session: nil, label: nil) }
    let(:closing) do
      described_class::Closing.new(outbox:, rails:, surface: Lain::Review::Surface::Text.new(sink: transcript))
    end

    it "journals the round closed by the refusal, with no verdict" do
      closing.refused(session, "2 files is past the ceiling of 1")

      expect(records_of("changeset_closed").map { |record| record["closed_by"] }).to eq(["refusal"])
      expect(records_of("review_verdict")).to be_empty
    end

    it "unbinds both rails and draws the refusal where the sidebar was" do
      closing.refused(session, "2 files is past the ceiling of 1")

      expect(rails.bound).to be_nil
      expect(transcript.string).to include("2 files is past the ceiling of 1")
    end

    it "lets go of the refused round when the outbox held it" do
      outbox = RecordingCloseOutbox.new(session:, label: "branch feature")
      closing = described_class::Closing.new(outbox:, rails:, surface: Lain::Review::Surface::Null.new)

      closing.refused(session, "too large")

      expect(outbox).not_to be_open
    end

    # A survey holds only once it drew, so the round the outbox holds when a
    # survey refuses is somebody else's -- a settled review the chat may still post.
    # A gesture can land between the bind and the refusal. Whatever it did, the
    # refusal still lets go of everything and journals no second ending.
    it "still lets go of everything when a verdict settled the round first, journaling no close" do
      outbox = RecordingCloseOutbox.new(session:, label: "branch feature")
      closing = described_class::Closing.new(outbox:, rails:, surface: Lain::Review::Surface::Null.new)
      session.submit("approve")

      closing.refused(session, "too large")

      expect(rails.bound).to be_nil
      expect(outbox).not_to be_open
      expect(records_of("changeset_closed")).to be_empty
    end

    it "still lets go of everything when a close landed first, journaling one close" do
      session.close(by: "human")

      closing.refused(session, "too large")

      expect(rails.bound).to be_nil
      expect(records_of("changeset_closed").size).to eq(1)
    end

    it "keeps holding a round that is not the refused one" do
      other = Lain::Review::Session.open(changeset:, journal:, source: "local_branch", policy:)
      outbox = RecordingCloseOutbox.new(session: other, label: "pull request 12")
      closing = described_class::Closing.new(outbox:, rails:, surface: Lain::Review::Surface::Null.new)

      closing.refused(session, "too large")

      expect(outbox.target).to eq("pull request 12")
    end
  end

  # A blocker is the one annotation kind `Review::ANNOTATION_KINDS` documents as
  # readable by a verdict policy, and until this card nothing read it: the notes
  # were not among `Verdict::Policy#admit!`'s arguments at all. Driven from THIS
  # end as well as the policy's, because the claim is about the gesture PAIR a
  # human makes on the rail -- `:LainNote blocker ...`, then
  # `:LainReviewVerdict approve` -- rather than about one method's arithmetic.
  describe "a verdict over a blocker" do
    let(:strict_session) do
      Lain::Review::Session.open(changeset:, journal:, source: "local_branch", surface:,
                                 policy: Lain::Review::Verdict::Policy.default)
    end
    let(:strict_baton) { RecordingBaton.new(session: strict_session) }
    let(:strict) { described_class.new(session: strict_session, baton: strict_baton) }

    # Every hunk marked, so the note is the ONLY thing left that can refuse the
    # approve. Over a partially reviewed changeset the default policy refuses
    # either way, and an example that cannot tell the two refusals apart proves
    # nothing about the blocker.
    before { (keys_for("a.rb") + keys_for("b.rb")).each { |key| strict_session.mark(key, "reviewed") } }

    it "refuses the approve, naming the file and the line the blocker sits on" do
      strict.wrote_annotation(note(kind: "blocker"))

      expect(strict.wrote_verdict("approve")).to include("a.rb:2")
    end

    # The refusal has to leave the round OPEN, or a blocker would cost the human
    # the review rather than the verdict.
    it "leaves the round unsettled, with nothing on the journal and the baton unpassed" do
      strict.wrote_annotation(note(kind: "blocker"))
      strict.wrote_verdict("approve")

      expect(strict_baton.settles).to be_zero
      expect(strict_session.verdict).to be(Lain::Review::Verdict::None)
      expect(records_of("review_verdict")).to be_empty
    end

    it "settles when the only note placed claims nothing about admissibility" do
      strict.wrote_annotation(note(kind: "note"))

      expect(strict.wrote_verdict("approve")).to be_nil
      expect(strict_baton.settles).to eq(1)
    end

    # THE way out, end to end. There is no `resolved` record and no gesture that
    # deletes a note, so what resolves a blocker is the human saying something
    # else at the same position: cursor back on that line, `n`, and a sentence.
    # Without this example the card ships a review nobody can ever approve.
    it "settles once a later note on that same line has answered the blocker" do
      strict.wrote_annotation(note(kind: "blocker"))
      strict.wrote_annotation(note(kind: "note", text: "answered: renamed in the follow-up"))

      expect(strict.wrote_verdict("approve")).to be_nil
      expect(strict_baton.settles).to eq(1)
    end

    # One answer, one objection. Two blockers on one line are two objections --
    # the surface draws both, by id -- so one note leaves the older one
    # standing rather than clearing the line.
    it "still refuses when one note answers only one of the two blockers on a line" do
      strict.wrote_annotation(note(kind: "blocker"))
      strict.wrote_annotation(note(kind: "blocker", text: "and this one too"))
      strict.wrote_annotation(note(kind: "note", text: "answered: the first one"))

      expect(strict.wrote_verdict("approve")).to include("a.rb:2")
      expect(strict_baton.settles).to be_zero
    end

    it "settles once the second blocker has an answer of its own" do
      strict.wrote_annotation(note(kind: "blocker"))
      strict.wrote_annotation(note(kind: "blocker", text: "and this one too"))
      strict.wrote_annotation(note(kind: "note", text: "answered: the first one"))
      strict.wrote_annotation(note(kind: "note", text: "answered: the second one"))

      expect(strict.wrote_verdict("approve")).to be_nil
    end

    # The other escape, and the one an unattended run needs: a permissive policy
    # reads none of its arguments, so a blocker does not wedge it either.
    it "settles over a blocker under the permissive policy this spec's session carries" do
      handover.wrote_annotation(note(kind: "blocker"))

      expect(handover.wrote_verdict("approve")).to be_nil
      expect(baton.settles).to eq(1)
    end
  end

  describe "a note written in the editor" do
    it "journals it as an annotation at the position the wire named" do
      handover.wrote_annotation(note)

      expect(records_of("annotation_placed").first)
        .to include("path" => "a.rb", "side" => "new", "line" => 2, "text" => "this reads backwards",
                    "kind" => "note", "revision" => head_sha)
    end

    it "answers nothing, which is how the editor's :w succeeds" do
      expect(handover.wrote_annotation(note)).to be_nil
    end

    # THE MEASUREMENT IS FORWARDED, NEVER COMPUTED, and this is the example that
    # says so. The editor's `anchor_text` is exactly what the head reads at that
    # line, so an implementation that measured drift ITSELF -- the buffer's text
    # against the evidence it read -- would answer false and journal false. Only
    # a forwarding one journals true.
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

    # The checkout behind the head is the case the buffer lies in: it holds a
    # line nobody submitted, and the editor stamps it with whatever revision it
    # was drawn under. The record names what the reviewed revision holds.
    it "journals the head's own line and the head as revision, whatever the buffer held" do
      handover.wrote_annotation(note(anchor_text: "two, as the stale checkout has it", revision: "e" * 40))

      expect(records_of("annotation_placed").first.slice("anchor_text", "revision"))
        .to eq("anchor_text" => "TWO", "revision" => head_sha)
    end

    it "journals an old-side note against the base's own line and the base" do
      handover.wrote_annotation(note(side: "old", line: 2, anchor_text: "whatever the buffer said"))

      expect(records_of("annotation_placed").first.slice("anchor_text", "revision"))
        .to eq("anchor_text" => "two", "revision" => base_sha)
    end

    # The session holds the round's changeset, so the evidence reader is that
    # changeset unless one is injected -- and an injected one is what is read.
    it "reads the evidence at the note's position from whatever reader it was handed" do
      asked = []
      placed = Lain::Review::Anchor.new(path: "a.rb", side: :new, line: 2, anchor_text: "READ", revision: "r" * 40)
      reader = Object.new
      reader.define_singleton_method(:anchor) { |**position| asked.push(position) && placed }

      handover(evidence: reader).wrote_annotation(note)

      expect(asked).to eq([{ path: "a.rb", side: "new", line: 2 }])
      expect(records_of("annotation_placed").first.slice("anchor_text", "revision"))
        .to eq("anchor_text" => "READ", "revision" => "r" * 40)
    end

    # A NOTE NEVER REFUSES ON EVIDENCE. The rail takes a batch whole or refuses
    # it whole, so refusing one note would journal the others twice on a retry;
    # a position the reviewed revision holds no line at lands with no evidence.
    it "journals a note on a line the reviewed revision does not hold, with no evidence line" do
      expect(handover.wrote_annotation(note(line: 40))).to be_nil

      expect(records_of("annotation_placed").map { |record| record.values_at("line", "anchor_text") })
        .to eq([[40, nil]])
    end

    it "journals a note on a path the changeset does not carry, with no evidence line" do
      expect(handover.wrote_annotation(note(path: "c.rb"))).to be_nil

      expect(records_of("annotation_placed").map { |record| record.values_at("path", "anchor_text") })
        .to eq([["c.rb", nil]])
    end

    # THE DOCENT IS TOLD ONLY ABOUT A NOTE THAT LANDED, and the order of those
    # two lines is what says so. A note is the only thing that ever opens a
    # thread at an anchor, so the docent has to be told -- but a kind this
    # session refuses journals nothing, and a docent told anyway would hold a
    # thread for a note the record denies. Telling it AFTER the session returns
    # makes that unrepresentable rather than merely unlikely.
    #
    # The docent stands in as a RECORDER answering the two messages the handover
    # sends it, never a double of the class: the docent is a deletable
    # capability and `spec/lain/review/deletability_spec.rb` owns the map, so
    # neither the subject nor this file may name it in code.
    it "tells the docent about a note the session took, and not about one it refused" do
      held = []
      docent = Object.new
      docent.define_singleton_method(:hold) { |anchor| held << anchor.id }
      docent.define_singleton_method(:ask) { |_anchor_id, _question| nil }
      subject = handover(docent:)

      subject.wrote_annotation(note(kind: "nitpick", text: "refused"))
      subject.wrote_annotation(note(text: "took"))

      expect(held).to eq(session.annotations.map(&:id))
    end

    # SIDE IS THE NOTE'S OWN, and it is the member most easily defaulted away:
    # the new side is where nearly every note goes, so a rail that hardcoded it
    # would pass every other example in this group. It is also the one member
    # the survey group at the bottom of this file cannot state -- a corpus is
    # every file ADDED, so its old side is empty by construction and a note
    # there is not a gesture a human can make.
    it "records a note on the old side against the old side, never the side the last note used" do
      handover.wrote_annotation(note(side: "new", line: 3))
      handover.wrote_annotation(note(side: "old", line: 2, anchor_text: "two"))

      expect(records_of("annotation_placed").map { |record| record.slice("side", "path", "line") })
        .to eq([{ "side" => "new", "path" => "a.rb", "line" => 3 },
                { "side" => "old", "path" => "a.rb", "line" => 2 }])
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
    # to be the object that will one day answer it, and the calls are
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

    # The defect this card exists to close: N calls to Session#mark posted N
    # notices, each naming a truncated content hash because that is all a bare
    # hunk key ever lets Surface::Neovim#mark say. The row's own name --
    # already computed by the view that resolved it -- is what a human is
    # owed instead, in ONE sentence.
    it "names the row, not a hunk key, when a single-unit row lands whole" do
      rendering = rendered

      marked = handover(view:).mark(row_of(rendering, "b.rb"), "reviewed", generation: rendering.generation)

      expect(marked.report).to eq("marked reviewed: 1 hunk(s) of b.rb")
    end

    it "posts one report naming every unit when a multi-unit row lands whole" do
      rendering = rendered

      marked = handover(view:).mark(row_of(rendering, "a.rb"), "reviewed", generation: rendering.generation)

      expect(marked.report).to eq("marked reviewed: 2 hunk(s) of a.rb")
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
      expect(marked.report).to include("1 of 2").and include("the rest were refused")
      expect(records_of("hunk_marked").size).to eq(1)
    end

    it "refuses when no editor is attached" do
      marked = handover.mark(2, "reviewed", generation: 1)

      expect([marked.marked?, marked.report]).to eq([false, Lain::Review::Handover::Detached::NO_EDITOR])
    end
  end

  # The two redraw cases a SURVEY cannot express, which is why they are here over
  # the diff rather than in the group below: a partial mark needs a row naming
  # two hunks and a session that refuses the second, and a refused gesture needs
  # a stamp the view can reject. Everything else about redrawing is asserted over
  # the corpus, where the defect actually bit.
  describe "the sidebar after a mark that did not land whole" do
    let(:inlet) { RecordingCockpitInlet.new }
    let(:view) { Lain::Frontend::Neovim::ReviewView.new }
    let(:surface) { Lain::Review::Surface::Neovim.new(rpc: inlet, view:) }
    let(:redraw) { described_class::Redraw.new(scope: :cumulative) }

    def rows = inlet.drawn.last.first

    def stamped = inlet.drawn.last.last

    # The row HAS moved -- to partly marked -- so a human told "nothing
    # happened" over a sidebar still reading unreviewed has been told two untrue
    # things rather than one. The redraw is conditioned on the gesture REACHING
    # the session, not on it landing whole.
    it "draws the row again for a row the session took only half of" do
      half = StubReviewView.new(
        marked: Lain::Frontend::Neovim::ReviewView::Marked.new(
          hunk_keys: [keys_for("a.rb").first, "not-a-key-this-changeset-produces"].freeze, report: "a.rb"
        )
      )
      session.present(scope: :cumulative)

      handover(view: half, redraw:).mark(1, "reviewed", generation: stamped)

      expect(rows).to include("[~] a.rb")
    end

    # The counter-example: a gesture the view refused reached nothing and
    # changed no row, so drawing again would be a rendering nothing asked for --
    # and every stamp the human holds would age out of {ReviewView::HELD} that
    # much faster.
    it "draws nothing again for a gesture that never reached the session" do
      session.present(scope: :cumulative)
      drawn = inlet.drawn.size

      handover(view:, redraw:).mark(1, "reviewed", generation: 99)

      expect(inlet.drawn.size).to eq(drawn)
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
  # because the defect lived in the join rather than in any one of them. The
  # `chunker:` seam counts at the chunker's own `#call`, so what is asserted is
  # work that happened rather than a flag a subject set about itself.
  #
  # == WHY THE HELPERS BELOW REDRAW, AND WHY THE NESTED GROUP DOES NOT
  #
  # A row's `hunk_keys` are cut at RENDER time and carried
  # ({Frontend::Neovim::ReviewView}'s own doc says why they are not re-derived),
  # so a rendering drawn before the file was read names no key however read the
  # file now is. Every helper in THIS group therefore redraws before each
  # gesture, and that is scaffolding rather than a claim: what these examples
  # prove is the READ REGISTRATION, and the redraw is there so the read is
  # observable through a mark.
  #
  # When they were written, nothing in `lib/` redrew -- `present` was called once,
  # when the round opened -- so `<CR>` read the file and the `x` after it still
  # answered {ReviewView::UNREAD}, and a mark that DID land still left the row
  # drawn `[ ]`. **That is no longer true.** {Lain::Review::Handover} now
  # re-presents after both gestures ({Lain::Review::Handover::Redraw}, wired from
  # the three callers that open a round), and the nested group at the bottom of
  # this file is the same survey with the scaffolding REMOVED: it presents once
  # and lets the subject draw everything after that. The cockpit round trip is
  # proven there, and end to end against a real editor in
  # `spec/lain/seams/survey_subdirectory_spec.rb`.
  #
  # The history is kept because it is the reason the two groups are shaped
  # differently, and because a reader who finds a redraw-per-gesture helper
  # should know it is deliberate rather than the code under test.
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

    # THE SAME SURVEY, WORKED THE WAY THE COCKPIT WORKS IT -- which is the
    # sequence the group's note above says nothing in `lib/` could execute.
    # Every helper up to here redraws before each gesture, and an editor does
    # not: it draws when the round opens and then waits. So the round is
    # presented ONCE here, at the top of each example, and every rendering after
    # that line is one the SUBJECT asked for. An example that redraws between
    # two gestures is green against a handover that redraws nothing, which is
    # exactly why this gap survived the gesture rail's own specs.
    #
    # The session's surface is the real {Lain::Review::Surface::Neovim} over the
    # same view and the same inlet the diff pair posts to, so the rows a
    # re-presentation produces are read back off the EDITOR's rail rather than
    # asked of the view a second time -- and the stamp each gesture rides in
    # with is the one the human's buffer would now be carrying.
    context "when nothing redraws between the gestures" do
      let(:inlet) { RecordingCockpitInlet.new }
      let(:surface) { Lain::Review::Surface::Neovim.new(rpc: inlet, view: survey_view) }
      let(:redraw) { described_class::Redraw.new(scope: :cumulative) }
      let(:gestures) { described_class.new(session: survey_session, view: survey_view, baton:, redraw:) }

      # The round as its command opens it, and the last line in any example that
      # presents anything.
      def opened_round = survey_session.present(scope: :cumulative)

      # What the editor is holding NOW: the rows on screen, and the stamp the
      # human's next gesture rides in with.
      def rows = inlet.drawn.last.first

      def stamped = inlet.drawn.last[1]

      def line_of(path) = rows.index { |line| line.include?(path) } + 1

      def worked_through
        surveyed.each do |path|
          gestures.open(line_of(path), generation: stamped)
          gestures.mark(line_of(path), "reviewed", generation: stamped)
        end
      end

      # `present` runs on EVERY redraw and `focus` must not. A gesture that moved
      # the human into the review tabpage would yank them out of the chat pane
      # each time they marked a hunk -- which is the distinction
      # `41_layout.lua` draws between `review_place` and `review_layout`, and
      # the reason {Review::Surface} carries them as two messages.
      it "never focuses the editor while redrawing after a gesture" do
        opened_round
        worked_through
        redraw.present(survey_session)

        expect(inlet.drawn.size).to be > 1
        expect(inlet.focused).to eq(0)
      end

      it "makes a row markable from the open gesture alone" do
        opened_round
        gestures.open(line_of("alpha.md"), generation: stamped)

        marked = gestures.mark(line_of("alpha.md"), "reviewed", generation: stamped)

        expect(marked).to have_attributes(marked?: true, report: include("alpha.md"))
      end

      # The other half, and its own defect: a mark that LANDED still left the
      # row drawn `[ ]`, because nothing re-presented after one either.
      it "draws the row again with the marker the mark set" do
        opened_round
        gestures.open(line_of("alpha.md"), generation: stamped)
        gestures.mark(line_of("alpha.md"), "reviewed", generation: stamped)

        expect(rows).to eq(["[x] alpha.md", "[ ] beta.md"])
      end

      it "admits an approve over a survey worked entirely through the gestures" do
        opened_round
        worked_through

        expect(gestures.wrote_verdict("approve")).to be_nil
        expect(records_of("review_verdict").map { |record| record["verdict"] }).to eq(["approve"])
      end

      # A REDRAW MUST NOT BECOME A READ. `b45553e` made drawing a survey free
      # and this card draws on every gesture, which is the shape that would undo
      # it by volume rather than by design. Asserted on the chunker's own log:
      # the gesture read one file and the rendering that followed read nothing.
      it "draws again without reading a file no gesture has opened" do
        opened_round
        gestures.open(line_of("alpha.md"), generation: stamped)

        expect(chunked).to eq(["alpha.md"])
      end

      it "chunks each file exactly once across the whole round, redraws and approve included" do
        opened_round
        worked_through
        gestures.wrote_verdict("approve")

        expect(chunked.tally).to eq(surveyed.to_h { |path| [path, 1] })
      end

      # The gesture rail's law, and why {Redraw} answers rather than raises:
      # {Lain::CLI::HumanReplies::Gestures} reads the gesture's own outcome and
      # nothing else, so a re-presentation that refused must not turn a gesture
      # that LANDED into one the human is told failed.
      it "answers a grouping this round cannot be drawn at in words, never by raising" do
        opened_round

        refused = described_class::Redraw.new(scope: :commits).present(survey_session)

        expect(refused).to include("commits").and include("corpus")
      end

      it "refuses a scope nobody declared where it is WIRED, not at the first gesture" do
        expect { described_class::Redraw.new(scope: :sideways) }
          .to raise_error(Lain::Review::Session::UnknownScope, /sideways/)
      end

      # {Undrawn}'s claim, mechanically: a review nothing is drawing draws
      # nothing, rather than a nil check at the two call sites.
      it "draws nothing at all when nothing is drawing this review" do
        expect(described_class::Undrawn.present(survey_session)).to be_nil
        expect(inlet.drawn).to be_empty
      end
    end

    # THE NOTE RAIL OF THE SAME SURVEY, WIRED THE WAY `/survey` WIRES IT.
    # `CLI::Command::Survey` assembles its handover out of four collaborators and
    # no fewer -- the round it has just opened, the view that drew it, a docent
    # off the editor's own surface, and a redraw carrying the grouping on screen.
    # A note handed back through a handover assembled any other way is a note
    # handed back through a rail production does not have, which is the failure
    # this whole group's chunk was written to end.
    #
    # The docent stands in as a RECORDER of the one message this group exercises
    # -- never a double of the class, and never the class by name: it is a
    # deletable capability, `spec/lain/review/deletability_spec.rb` owns the map
    # of what may name it, and this file is not on that row.
    context "when the human hands their notes back" do
      let(:inlet) { RecordingCockpitInlet.new }
      let(:surface) { Lain::Review::Surface::Neovim.new(rpc: inlet, view: survey_view) }
      let(:held) { [] }
      # `#hold` ALONE, because `#hold` alone is what this group exercises: a
      # recorder advertising an `#ask` no example calls stops describing what it
      # answers. The docent gesture has its own group at the bottom of this file.
      let(:docent) do
        recorded = held
        Object.new.tap { |recorder| recorder.define_singleton_method(:hold) { |anchor| recorded << anchor } }
      end
      let(:notes) do
        described_class.new(session: survey_session, view: survey_view, docent:,
                            redraw: described_class::Redraw.new(scope: :cumulative))
      end

      # One note as {Lain::Frontend::Neovim::ReviewWrite} normalizes it off the
      # wire, authored against the survey's OWN head revision -- a corpus answers
      # a content digest where a branch answers a sha, and a note carries
      # whatever the editor was stamped with.
      def placed(line:, kind: "note", drifted: false, path: "alpha.md", anchor_text: "## alpha.md 1")
        { "path" => path, "side" => "new", "line" => line, "anchor_text" => anchor_text,
          "text" => "the note placed at #{path}:#{line}", "kind" => kind,
          "revision" => survey.head_ref, "drifted" => drifted }
      end

      def anchored = records_of("annotation_placed")

      # THE WHOLE BATCH, THROUGH THE VERB THAT CARRIES IT, rather than a loop
      # this spec wrote. `:LainNoteDone` hands every note over in ONE call and
      # `Frontend::Neovim::ReviewWrite.notes` is what unpacks it onto exactly this
      # hand-off -- `rpc_thread.rb`'s `review_writes` binds the two together and
      # its own doc says the deliveries happen in the order the payload carried.
      # A spec that looped here would assert that its own `each` kept its order.
      #
      # NOT THE ONLY GUARD ON THAT BOUNDARY, and saying so is the point:
      # `spec/lain/frontend/neovim/rpc_thread_spec.rb` already pins placement
      # order at the verb itself. What is added here is that the order SURVIVES
      # to the journal, across the boundary, the handover and the session -- so a
      # regression in `rpc_thread.rb` reddens a `Review` spec, and that is why.
      # @return [String, nil] the boundary's own refusal, or nothing once every
      #   note is taken -- ASSERTED by each example below rather than discarded.
      #   A payload this boundary turns down delivers nothing at all, so without
      #   that assertion a regression in `ReviewWrite` reads as an empty journal
      #   with no word about why it is empty.
      def handed_back(batch)
        Lain::Frontend::Neovim::ReviewWrite.notes([batch]) { |note| notes.wrote_annotation(note) }
      end

      # ORDER IS THE OUTPUT, and the order at risk is the tidy one. The editor
      # holds each note's position as an extmark and `nvim_buf_get_extmarks`
      # answers POSITIONALLY, so notes placed at 5, 9, 2 and 3 come back as 2,
      # 3, 5, 9 -- sorted, plausible, and not what the human did. Nothing but
      # this journal records which note was written first, so the sequence is
      # the record's; `annotate_spec.rb` pins the editor's half of the same
      # property, and this is the half that survives the wire.
      it "journals the batch in the order the human placed it, not in the order of the lines" do
        expect(handed_back([5, 9, 2, 3].map { |line| placed(line:) })).to be_nil

        expect(anchored.map { |record| record["line"] }).to eq([5, 9, 2, 3])
      end

      # EVERY note of the batch, and not merely the first: a rail that anchored
      # the first note and defaulted the rest passes every single-note example in
      # this file. `drifted` differs between the two for the same reason -- the
      # measurement is the EDITOR's, forwarded and never computed here, so both
      # answers have to survive the trip.
      #
      # BOTH `anchor_text` VALUES ARE DELIBERATE AND NEITHER IS A TYPO. The first
      # is exactly what alpha.md line 1 says while the note reports DRIFTED, so a
      # rail that measured for itself would journal false. The second does NOT
      # match beta.md line 9 (which reads "body 2 two.") while the note reports it
      # did NOT drift, so the same rail would journal true. Together they close
      # both directions; "correcting" either to match the document deletes half
      # the guard and stays green.
      it "carries each note's own anchor and the drift the editor measured for it" do
        expect(handed_back([placed(line: 1, drifted: true),
                            placed(line: 9, path: "beta.md", anchor_text: "## beta.md 3",
                                   drifted: false)])).to be_nil

        expect(anchored.map { |record| record.slice("side", "revision", "path", "line", "drifted") })
          .to eq([{ "side" => "new", "revision" => survey.head_ref, "path" => "alpha.md",
                    "line" => 1, "drifted" => true },
                  { "side" => "new", "revision" => survey.head_ref, "path" => "beta.md",
                    "line" => 9, "drifted" => false }])
      end

      # The docent is told about each note that LANDED, which is what opens the
      # thread the human's next question is asked in -- and it is told in the
      # same order, because a docent handed a batch it cannot sequence holds the
      # threads of a conversation nobody had in that order.
      it "tells the docent about every note it took, in that same order" do
        expect(handed_back([5, 9, 2, 3].map { |line| placed(line:) })).to be_nil

        expect(held.map(&:line)).to eq([5, 9, 2, 3])
      end
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

  # Notes over a REAL branch, through the real session and journal, then
  # replayed. Every shape a revision's bytes can take -- a checkout that is not
  # the head, the old side of a rename, CRLF, latin-1, a binary blob, a line past
  # the end -- has to leave its note on the record, or a resumed round has lost
  # the human's words while this rail answered that it took them.
  describe "notes over a real branch, journaled and replayed", :seam do
    let(:scrub) { Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB }

    around do |example|
      Dir.mktmpdir("lain-handover-branch") do |made|
        @repo = File.realpath(made)
        FileUtils.cp_r("#{SeedRepo.at("from.rb" => "#{numbered}old\n", "crlf.txt" => "a\r\nb\r\n",
                                      "latin.txt" => "plain\n", "blob.bin" => "\x00\x01")}/.", @repo)
        example.run
      end
    end

    def numbered = (1..20).map { |n| "line #{n}\n" }.join

    def git(*) = Mixlib::ShellOut.new("git", "-C", @repo, *, environment: scrub).run_command.error!

    def branched
      git("checkout", "-q", "-b", "base")
      git("checkout", "-q", "-b", "topic")
      git("mv", "from.rb", "to.rb")
      { "to.rb" => "#{numbered}new\n", "crlf.txt" => "a\r\nB\r\n", "latin.txt" => "caf\xE9 latin-1\n".b,
        "blob.bin" => "\x89PNG\r\n\x1A\n\xFF\xFE\n".b }.each do |name, body|
        File.binwrite(File.join(@repo, name), body)
      end
      git("add", "-A")
      git("commit", "-q", "-m", "head")
      File.binwrite(File.join(@repo, "to.rb"), "line 1\nWORKING COPY\n")
      Lain::Review::Changeset.new(source: Lain::Review::Source::LocalBranch.new(base: "base", head: "topic",
                                                                                repo_root: @repo))
    end

    def positions
      [["to.rb", "new", 2], ["to.rb", "new", 21], ["to.rb", "old", 21], ["to.rb", "new", 99],
       ["crlf.txt", "new", 2], ["latin.txt", "new", 1], ["blob.bin", "new", 1], ["blob.bin", "old", 1]]
    end

    it "keeps every note on the record, so a replay holds as many as the live round took" do
      changeset = branched
      live = Lain::Review::Session.open(changeset:, journal:, source: "local_branch", surface:, policy:)
      rail = described_class.new(session: live)

      answers = positions.map do |path, side, line|
        rail.wrote_annotation(note(path:, side:, line:, anchor_text: "BUFFER", revision: "stale"))
      end

      replayed = Lain::Review::Session.from_journal(io.string.lines, changeset:, journal:, surface:)
      expect(answers).to all(be_nil)
      expect([live.annotations.size, replayed.annotations.size]).to eq([positions.size, positions.size])
    end

    it "journals what each revision holds, never what the buffer sent" do
      changeset = branched
      rail = described_class.new(session: Lain::Review::Session.open(changeset:, journal:, source: "local_branch",
                                                                     surface:, policy:))
      positions.first(6).each do |path, side, line|
        rail.wrote_annotation(note(path:, side:, line:, anchor_text: "BUFFER", revision: "stale"))
      end

      expect(records_of("annotation_placed").map { |record| record["anchor_text"] })
        .to eq(["line 2", "new", "old", nil, "B\r", "caf\uFFFD latin-1"])
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
