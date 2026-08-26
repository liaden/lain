# frozen_string_literal: true

require "stringio"

# The one verb an outbox needs of an executor, plus a tally. Its own class in
# this file rather than a shared support double, for the reason
# `review_spec.rb`'s rail records: a class declared in another spec file is one
# `parallel_tests` may hand to a different worker entirely.
#
# It RECORDS rather than answers a canned value, because "refused before the
# executor" and "called and the answer discarded" are the two things every
# example below has to tell apart.
class RecordingSubmitExecutor
  # `gh` missing from PATH: a broken machine rather than GitHub saying no, and
  # the one failure that means nothing was sent.
  class Broken < StandardError; end

  attr_reader :calls

  def initialize
    @calls = []
    @answer = Lain::Forge::Gh::Answer.new(ok: true, detail: { "value" => { "id" => 88_012,
                                                                           "state" => "COMMENTED" } })
  end

  def refuse!
    @answer = Lain::Forge::Gh::Answer.new(ok: false, detail: { "reason" => "refused", "stderr" => "HTTP 422" })
  end

  def raise! = @raising = true

  def submit_review(number:, review:)
    @calls << { number:, review: }
    raise Broken, "no gh on PATH" if @raising

    @answer
  end
end

# The slot between "the human finished a review" and "it reached the pull
# request", and the object that makes sure the second happens at most once.
#
# Nothing here touches the network. The payload's own correctness belongs to
# `spec/lain/review/submit_spec.rb`; what this file pins is WHEN a payload is
# built at all, and what happens to the one chance a batched review POST gets.
RSpec.describe Lain::Review::Submit::Outbox do
  subject(:outbox) { described_class.new }

  let(:executor) { RecordingSubmitExecutor.new }

  def head_sha = -("h" * 40)

  def base_sha = -("b" * 40)

  # Two commented lines on the new side, so a payload built from the wrong
  # session is a different comment rather than the same one.
  def diff
    <<~DIFF
      diff --git a/app.rb b/app.rb
      index 1111111..2222222 100644
      --- a/app.rb
      +++ b/app.rb
      @@ -40,2 +40,3 @@ def alpha
       forty
      -forty one
      +FORTY ONE
      +forty two
    DIFF
  end

  def changeset
    @changeset ||= Lain::Review::Changeset.new(
      source: DiffSource.over(instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, base_ref: base_sha,
                                                                                 head_ref: head_sha, commits: []))
    )
  end

  # `policy:` is a keyword rather than a second helper because the ONE thing a
  # settled round needs is a policy that will admit a verdict over a changeset
  # nobody marked -- which is `--permissive`, spelled the way the flag resolves.
  def round(policy: Lain::Review::Verdict::Policy.default)
    Lain::Review::Session.open(changeset:, journal: Lain::Journal.new(io: StringIO.new), source: "github_pr",
                               policy:)
  end

  def session = @session ||= round

  # A round a human has already judged. The verdict goes through
  # `Session#submit`, never onto a double, because what this file has to be able
  # to say is that the outbox reads the SESSION's word rather than one of its
  # own -- and a stubbed reader could say that about an object no `/review` ever
  # builds.
  def settled(on = session)
    annotate(on)
    on.submit("approve")
    on
  end

  def annotate(on = session, text: "kaboom")
    on.annotate(Lain::Review::Anchor.new(path: "app.rb", side: :new, line: 42,
                                         anchor_text: "forty two", revision: head_sha),
                text, kind: "note", drifted: false)
  end

  def held(number: 4271, label: "pull request 4271")
    annotate
    outbox.hold(session:, number:, label:)
  end

  describe "holding the round a chat has open" do
    it "answers not-open until a round is held, and open once one is" do
      expect(outbox).not_to be_open

      held

      expect(outbox).to be_open
    end

    it "refuses a submit with nothing held, naming what opens one, and touches no executor" do
      expect { outbox.submit(executor:) }
        .to raise_error(described_class::NotOpen, /no changeset review is open/)
      expect(executor.calls).to be_empty
    end

    it "holds the LAST round opened, so a second /review replaces the first rather than queueing it" do
      held
      other = round
      annotate(other, text: "the second round")
      outbox.hold(session: other, number: 99, label: "pull request 99")

      outbox.submit(executor:)

      expect(executor.calls.last.fetch(:number)).to eq(99)
      expect(executor.calls.last.fetch(:review).fetch("comments").map { |c| c.fetch("body") })
        .to eq(["the second round"])
    end
  end

  # WHETHER THE ROUND IS STILL LIVE, asked of the session this object already
  # holds. It is a forward and not a state: nothing here judges, so nothing here
  # may remember a judgement, and the answer has to keep coming from the one
  # object a `/review-submit` would post.
  #
  # The reason a chat needs the question at all is next door -- `/review` and
  # `/survey` share one set of gesture rails and each refuses to draw over the
  # other's LIVE round. Once a verdict is in, there is nothing left to draw over.
  describe "whether the round it holds is still awaiting judgement" do
    # The null-object half, and the whole of why no caller nil-checks: with
    # nothing held there is no judgement, which is what `Verdict::None` IS.
    it "answers an empty verdict with nothing held, so a caller asks one question rather than two" do
      expect(outbox.held_verdict).to be_empty
    end

    it "answers empty while the held round is still awaiting one" do
      held

      expect(outbox.held_verdict).to be_empty
    end

    it "answers the word the SESSION recorded once the round is judged" do
      @session = round(policy: Lain::Review::Verdict::Policy.strict_unless(permissive: true))
      held
      settled

      expect(outbox.held_verdict).to eq("approve")
      expect(outbox.held_verdict).not_to be_empty
    end

    # It forwards; it does not interpret. A round held BEFORE the verdict and
    # one held after answer the same way, because the answer is read at the
    # moment of asking off the session rather than latched at `hold`.
    it "reads the verdict at the moment of asking, not at the moment of holding" do
      @session = round(policy: Lain::Review::Verdict::Policy.strict_unless(permissive: true))
      held

      expect { settled }.to change { outbox.held_verdict.empty? }.from(true).to(false)
    end

    # A REFUSED JUDGEMENT IS NOT A SETTLED ROUND, and the guards downstream must
    # not be able to read it as one. `Session#submit` assigns `@judgement` only
    # after `@policy.admit!` has returned and the word is on the journal, so a
    # policy refusal leaves the round exactly as live as it was -- which is what
    # keeps a `/survey` that could not be judged from becoming one that reads as
    # judged. The default policy is what refuses here, so this is the round a
    # human gets without asking for anything.
    it "still reads as live after the POLICY refused the verdict, since nothing was judged" do
      held

      expect { session.submit("approve") }.to raise_error(Lain::Review::Verdict::Policy::Incomplete)

      expect(outbox.held_verdict).to be_empty
      expect(outbox.held_verdict).to be(Lain::Review::Verdict::None)
    end

    # The THREE readers over one held round, agreeing about how much absence they
    # tolerate. `#hold` validates nothing by design and defers the failure to
    # its readers, so what must not happen is one reader answering while another
    # raises about the same round -- a caller would then have to know which of
    # them it was holding.
    it "tolerates a round with no session exactly as held_source does, and answers the null verdict" do
      outbox.hold(session: nil, number: nil, label: "branch feature/widget")

      expect(outbox.held_source).to be_nil
      expect(outbox.annotation_count).to be_nil
      expect(outbox.held_verdict).to be(Lain::Review::Verdict::None)
    end

    # THE POSITIVE ARM, over the REAL collection. `/introspect` renders this
    # number at the prompt, so what it counts has to be what the round actually
    # recorded -- `Session#annotations` dups and freezes the live Array, and a
    # doubled `annotations:` would pin nothing but the message's existence.
    #
    # Zero and absent are the two answers this file has to keep apart: a round
    # opened with nothing written yet is a real round, and a human looking at it
    # must not be told the same thing as a human with no round at all.
    it "counts the notes the held round actually recorded, zero being a real answer" do
      expect(outbox.annotation_count).to be_nil

      outbox.hold(session:, number: 4271, label: "pull request 4271")

      expect(outbox.annotation_count).to eq(0)

      annotate
      annotate(text: "and a second note")

      expect(outbox.annotation_count).to eq(2)
    end

    # The source word, asserted positively for the first time: its nil arm above
    # was the only assertion in this file, so the reader every `/review` and
    # `/survey` refusal branches on was pinned only by what it does with nothing.
    it "answers the held round's own source word" do
      held

      expect(outbox.held_source).to eq("github_pr")
    end
  end

  # AC 4. Settling is not closing: `/review-submit` reads `#target` AFTER the
  # send, and the round a human just judged is exactly the one they then post.
  describe "a settled round, which is still the round this chat would post" do
    before { @session = round(policy: Lain::Review::Verdict::Policy.strict_unless(permissive: true)) }

    it "still holds the settled round, so /review-submit names its target rather than an absent review" do
      held
      settled

      expect(outbox).to be_open
      expect(outbox.target).to eq("pull request 4271")
    end

    it "still posts it, because a verdict is what a review is FOR and not a reason to drop it" do
      held
      settled

      expect(outbox.submit(executor:)).to be_ok
      expect(executor.calls.last.fetch(:number)).to eq(4271)
    end

    # The note on the card, pinned: nothing here reopens or closes anything, so
    # the settled round leaves the same way every other one does -- replaced.
    it "lets a later round replace it, which is the only way a held round is ever let go" do
      held
      settled
      other = round
      annotate(other, text: "the round after the verdict")
      outbox.hold(session: other, number: 99, label: "pull request 99")

      expect(outbox.held_verdict).to be_empty
      expect(outbox.target).to eq("pull request 99")
    end
  end

  describe "a review with nowhere to post" do
    it "refuses a branch round BY NAME rather than as an error, naming the branch and never posting" do
      held(number: nil, label: "branch feature/widget")

      expect { outbox.submit(executor:) }
        .to raise_error(described_class::Nowhere, %r{branch feature/widget})
      expect(executor.calls).to be_empty
    end

    it "says what a branch round can do about it, since having no pull request is not a fault" do
      held(number: nil, label: "branch feature/widget")

      expect { outbox.submit(executor:) }.to raise_error(described_class::Nowhere, %r{/review})
    end

    it "stays open after refusing, so nothing about the round was spent on a refusal it caused" do
      held(number: nil, label: "branch feature/widget")

      expect { outbox.submit(executor:) }.to raise_error(described_class::Nowhere)

      expect(outbox).to be_open
    end

    # The whole sentence, not a fragment: `label` already carries "branch", so
    # the refusal must not add a second noun that repeats it -- see F56.
    it "names the branch once, not twice, and still points at the remedy" do
      held(number: nil, label: "branch feature/widget")

      expect { outbox.submit(executor:) }.to raise_error(
        described_class::Nowhere,
        "this review was opened on branch feature/widget, which has no pull request to post a review " \
        "to -- the annotations and the verdict are on the journal either way. Run `/review <pull-request>` " \
        "against the pull request itself to post one."
      )
    end
  end

  describe "sent at most once, because an accepted POST creates a review every time" do
    it "posts the held round's annotations against the number it was held with, carrying the body given" do
      held

      answer = outbox.submit(executor:, body: "reads well")

      expect(executor.calls.size).to eq(1)
      expect(executor.calls.first.fetch(:number)).to eq(4271)
      expect(executor.calls.first.fetch(:review).fetch("body")).to eq("reads well")
      expect(answer).to be_ok
    end

    it "refuses the SECOND submit, naming the pull request and why there is no retry" do
      held
      outbox.submit(executor:)

      expect { outbox.submit(executor:) }
        .to raise_error(described_class::AlreadySent, /4271/)
      expect(executor.calls.size).to eq(1)
    end

    # The dangerous half: a not-ok answer does NOT mean nothing was created -- a
    # timeout is a POST that may well have landed -- so the second attempt is
    # refused just as hard, and the sentence says the remote is the only thing
    # that knows.
    it "refuses the second submit after a REFUSED first one too, and says only the remote can say what landed" do
      held
      executor.refuse!
      outbox.submit(executor:)

      expect { outbox.submit(executor:) }
        .to raise_error(described_class::AlreadySent, /only the pull request itself can answer/)
      expect(executor.calls.size).to eq(1)
    end

    it "hands the executor's own answer back unchanged, refusal included, rather than deciding about it" do
      held
      executor.refuse!

      answer = outbox.submit(executor:)

      expect(answer).not_to be_ok
      expect(answer.detail.fetch("reason")).to eq("refused")
    end

    # A raise is `gh` not existing -- a broken machine, and nothing was sent --
    # so the round must still be postable once the machine is fixed. Burning the
    # one chance there strands a finished review with no way to deliver it.
    it "does NOT count a raising executor as sent, because nothing reached the remote" do
      held
      executor.raise!

      expect { outbox.submit(executor:) }.to raise_error(RecordingSubmitExecutor::Broken)

      expect { outbox.submit(executor: RecordingSubmitExecutor.new) }.not_to raise_error
    end

    # Submit refuses an empty review before the executor; that refusal must not
    # burn the one chance either.
    it "does NOT count Submit's own pre-flight refusal as sent" do
      outbox.hold(session:, number: 4271, label: "pull request 4271")

      expect { outbox.submit(executor:) }.to raise_error(Lain::Review::Submit::Nothing)
      expect(executor.calls).to be_empty

      annotate
      expect(outbox.submit(executor:)).to be_ok
    end

    it "re-arms on a fresh hold, because a new round is a review GitHub has not seen" do
      held
      outbox.submit(executor:)
      outbox.hold(session:, number: 4271, label: "pull request 4271")

      expect(outbox.submit(executor:)).to be_ok
      expect(executor.calls.size).to eq(2)
    end
  end
end
