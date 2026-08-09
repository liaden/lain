# frozen_string_literal: true

require "json"
require "stringio"

# `/review-submit` (T34): the last hop, and the one this chunk never built.
#
# (Opening deliberately not with the class's own name: `Style/CommentAnnotation`
# reads a leading "Review" as an annotation keyword.)
#
# EVERY EXAMPLE DRIVES A REAL {Lain::Forge::Gh} over a recording shell_out
# factory, never a doubled executor, for `submit_spec.rb`'s reason: the fact
# under test is what reached the subprocess, and a double answering a canned
# value cannot tell "refused before the call" from "called and the answer thrown
# away". Nothing here touches the network -- the factory answers `GhParity`'s
# fixture, which is the same arrangement `forge/gh_spec.rb` runs on.
RSpec.describe Lain::CLI::Command::ReviewSubmit do
  subject(:command) { described_class.new(outbox:, root: Dir.pwd, shell_out_factory: factory) }

  let(:outbox) { Lain::Review::Submit::Outbox.new }
  let(:factory) { GhParity.factory }
  let(:env) { build_command_env }

  # Two files, three hunks, and a deletion -- so an old-side comment has a real
  # old-side line to sit on and the payload can be asserted whole. New-side
  # numbering: app.rb hunk one shows 40, 41 and 42, hunk two shows 81 and 82.
  # Old-side: 40 and 41, then 80 and 81.
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
      @@ -80,2 +81,2 @@ def beta
       eighty
      -eighty one
      +EIGHTY ONE
      diff --git a/lib/other.rb b/lib/other.rb
      index 3333333..4444444 100644
      --- a/lib/other.rb
      +++ b/lib/other.rb
      @@ -1,2 +1,2 @@ def gamma
       x
      -y
      +Y
    DIFF
  end

  def head_sha = -("h" * 40)

  def base_sha = -("b" * 40)

  def changeset
    @changeset ||= Lain::Review::Changeset.new(
      source: DiffSource.over(instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, base_ref: base_sha,
                                                                                 head_ref: head_sha, commits: []))
    )
  end

  def record = @record ||= StringIO.new

  def session
    @session ||= Lain::Review::Session.open(changeset:, journal: Lain::Journal.new(io: record),
                                            source: "github_pr")
  end

  # The REAL gesture object every note and every verdict travels through in a
  # cockpit: `:LainNote` reaches {Lain::Review::Handover#wrote_annotation} and
  # `:LainReviewVerdict` reaches `#wrote_verdict`. Driving the session directly
  # would skip the one rail a human's words actually take.
  def handover = @handover ||= Lain::Review::Handover.new(session:)

  def note(path:, side:, line:, text:, revision:)
    handover.wrote_annotation("path" => path, "side" => side.to_s, "line" => line, "text" => text,
                              "kind" => "note", "drifted" => false, "anchor_text" => "",
                              "revision" => revision)
  end

  # Every hunk this changeset produces, marked reviewed -- which is what
  # {Lain::Review::Verdict::Policy::EveryHunk} demands before it admits an
  # approve, and therefore part of finishing a review rather than decoration.
  def mark_everything
    Lain::Review::Session::MarkedChangeset.keys_by_path(changeset).each_value do |keys|
      keys.each { |key| session.mark(key, "reviewed") }
    end
  end

  def hold(number: GhParity::NUMBER, label: "pull request #{GhParity::NUMBER}")
    outbox.hold(session:, number:, label:)
  end

  # What went on the wire, read off the stdin the factory was handed -- never
  # off the object that built it, which would only assert the builder agrees
  # with itself.
  def sent = JSON.parse(factory.options.last.fetch(:input))

  def gh_calls = factory.argvs

  describe "the review a finished round posts, end to end" do
    # THE example this card exists for: a round opened, annotated on both sides
    # of the diff, marked, verdicted, held, and posted -- with the whole payload
    # the executor received asserted, not merely that something came back.
    it "posts one batched review carrying the verdict's event, the head revision and every annotation" do
      note(path: "app.rb", side: :new, line: 42, text: "the new name reads better", revision: head_sha)
      note(path: "app.rb", side: :old, line: 41, text: "why did this one go?", revision: base_sha)
      note(path: "lib/other.rb", side: :new, line: 2, text: "and this one", revision: head_sha)
      mark_everything
      expect(handover.wrote_verdict("approve")).to be_nil
      hold

      answer = command.call("the tests are the good part", env)

      expect(sent).to eq(
        "commit_id" => head_sha,
        "event" => "APPROVE",
        "body" => "the tests are the good part",
        "comments" => [
          { "path" => "app.rb", "line" => 42, "side" => "RIGHT", "body" => "the new name reads better" },
          { "path" => "app.rb", "line" => 41, "side" => "LEFT", "body" => "why did this one go?" },
          { "path" => "lib/other.rb", "line" => 2, "side" => "RIGHT", "body" => "and this one" }
        ]
      )
      expect(answer).to include("pull request #{GhParity::NUMBER}").and include(GhParity::REVIEW_STATE)
    end

    # ONE subprocess, and it is a POST to the reviews endpoint of the number the
    # round was held with. A batched review is the whole point: a comment-per-
    # call implementation would notify the author once per note.
    it "spawns exactly one gh, POSTing to the held pull request's reviews endpoint" do
      note(path: "app.rb", side: :new, line: 42, text: "kaboom", revision: head_sha)
      hold

      command.call("", env)

      expect(gh_calls.size).to eq(1)
      expect(gh_calls.first.take(4)).to eq(["gh", "api", "--method", "POST"])
      expect(gh_calls.first).to include("repos/{owner}/{repo}/pulls/#{GhParity::NUMBER}/reviews")
    end

    # A round nobody judged still has something to say, so the event is COMMENT
    # rather than a judgement the human did not make -- and an implementation
    # that always sent the verdict's event would post an APPROVE nobody typed.
    it "posts a round with no verdict as COMMENT, not as an approval nobody gave" do
      note(path: "app.rb", side: :new, line: 42, text: "kaboom", revision: head_sha)
      hold

      command.call("", env)

      expect(sent.fetch("event")).to eq("COMMENT")
    end

    it "carries an empty body when the human typed no summary, because the annotations are the review" do
      note(path: "app.rb", side: :new, line: 42, text: "kaboom", revision: head_sha)
      hold

      command.call("", env)

      expect(sent.fetch("body")).to eq("")
      expect(sent.fetch("comments").size).to eq(1)
    end

    it "reads the whole line after the verb as the summary, spaces and all" do
      note(path: "app.rb", side: :new, line: 42, text: "kaboom", revision: head_sha)
      hold

      command.call("  two sentences. and the second one.  ", env)

      expect(sent.fetch("body")).to eq("two sentences. and the second one.")
    end

    # The degrade half of {Lain::Review::Submit}'s rule, reached through this
    # command: a note the diff cannot place becomes a bullet in the body rather
    # than being dropped on the floor.
    it "keeps an unplaceable note as a bullet in the body rather than losing it" do
      note(path: "app.rb", side: :new, line: 60, text: "between the hunks", revision: head_sha)
      hold

      command.call("summary", env)

      expect(sent.fetch("comments")).to be_empty
      expect(sent.fetch("body")).to include("summary", Lain::Review::Submit::UNPLACED_HEADING,
                                            "between the hunks")
    end
  end

  describe "the line a human types, through the registry that dispatches it" do
    it "reaches this command with the summary intact, under the name that was registered" do
      note(path: "app.rb", side: :new, line: 42, text: "kaboom", revision: head_sha)
      hold
      registry = Lain::CLI::Command::Registry.new([command]).bind(env)

      registry.dispatch("/review-submit shipped, thanks") { raise "fallthrough must not run" }

      expect(sent.fetch("body")).to eq("shipped, thanks")
    end
  end

  describe "what it refuses, and what it never tries twice" do
    it "refuses with nothing open, spawning no gh at all" do
      expect { command.call("", env) }
        .to raise_error(Lain::Review::Submit::Outbox::NotOpen, /no changeset review is open/)
      expect(gh_calls).to be_empty
    end

    # A review opened on a branch has nowhere to post: not an error, a review
    # with no pull request under it. The refusal names the branch, and no
    # subprocess is spawned to discover that.
    it "refuses a BRANCH round by name, and spawns no gh discovering it" do
      note(path: "app.rb", side: :new, line: 42, text: "kaboom", revision: head_sha)
      outbox.hold(session:, number: nil, label: "branch feature/widget")

      expect { command.call("", env) }
        .to raise_error(Lain::Review::Submit::Outbox::Nowhere, %r{branch feature/widget})
      expect(gh_calls).to be_empty
    end

    # NO RETRY, EVER. An accepted POST creates a review every time, so the
    # second `/review-submit` must not reach gh -- the assertion is on the
    # subprocess count, because a refusal that still spawned would have already
    # created the second review.
    it "refuses a second submit of one round, and the second spawns nothing" do
      note(path: "app.rb", side: :new, line: 42, text: "kaboom", revision: head_sha)
      hold
      command.call("", env)

      expect { command.call("again", env) }
        .to raise_error(Lain::Review::Submit::Outbox::AlreadySent, /#{GhParity::NUMBER}/o)
      expect(gh_calls.size).to eq(1)
    end

    # GitHub refusing is a VALUE at the forge tier and must not read as a line
    # of success here. Raised, carrying gh's own words, and named so nobody
    # mistakes it for lain's own diagnosis.
    it "raises rather than reporting success when GitHub refuses the review, quoting gh's own words" do
      note(path: "app.rb", side: :new, line: 42, text: "kaboom", revision: head_sha)
      hold(number: GhParity::UNKNOWN_NUMBER, label: "pull request #{GhParity::UNKNOWN_NUMBER}")

      expect { command.call("", env) }
        .to raise_error(described_class::Rejected, /must be part of the diff/)
    end

    it "does not try again after GitHub refused, because a refusal is not proof nothing was created" do
      note(path: "app.rb", side: :new, line: 42, text: "kaboom", revision: head_sha)
      hold(number: GhParity::UNKNOWN_NUMBER, label: "pull request #{GhParity::UNKNOWN_NUMBER}")
      expect { command.call("", env) }.to raise_error(described_class::Rejected)

      expect { command.call("", env) }
        .to raise_error(Lain::Review::Submit::Outbox::AlreadySent, /only the pull request itself can answer/)
      expect(gh_calls.size).to eq(1)
    end

    it "refuses a review that would say nothing at all, before any subprocess" do
      hold

      expect { command.call("", env) }.to raise_error(Lain::Review::Submit::Nothing)
      expect(gh_calls).to be_empty
    end
  end

  describe "the command surface it presents" do
    it "answers the name the registry dispatches and a usage naming the summary" do
      expect(command.name).to eq("review-submit")
      expect(command.usage).to include("/review-submit", "summary")
    end
  end
end
