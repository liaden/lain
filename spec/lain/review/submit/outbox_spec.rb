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
      source: instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, base_ref: base_sha,
                                                                 head_ref: head_sha, commits: [])
    )
  end

  def round
    Lain::Review::Session.open(changeset:, journal: Lain::Journal.new(io: StringIO.new), source: "github_pr")
  end

  def session = @session ||= round

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
