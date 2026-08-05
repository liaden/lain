# frozen_string_literal: true

require "stringio"
require "tmpdir"

# The write half of the GitHub path: a session's annotations, validated against
# the diff GitHub is actually serving, posted as ONE batched review.
#
# (Opening deliberately not with the class's own name: `Style/CommentAnnotation`
# reads a leading "Review" as an annotation keyword and `-a` rewrote the
# sentence into `REVIEW: :Submit`.)
#
# No example here touches the network. Where "no subprocess is spawned" is the
# claim, the executor is a REAL Forge::Gh over an injected shell_out_factory and
# the assertion is on the argvs that factory was handed -- a double answering a
# canned value could not tell "refused before the call" from "called and the
# answer thrown away".
RSpec.describe Lain::Review::Submit do
  # Two files; the first has two hunks, so a range can span them and a line can
  # fall between them. New-side numbering, which every example below rests on:
  # app.rb hunk one covers 40, 41 and 42, hunk two covers 81 and 82, and 60 is
  # inside the file and inside no hunk.
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

  def base_sha = -("b" * 40)

  def head_sha = -("h" * 40)

  def commits
    numstat = %w[app.rb lib/other.rb].map do |path|
      Lain::Review::Source::FileStat.new(path: -path, added: 2, deleted: 1)
    end
    [Lain::Review::Source::Commit.new(sha: -("c" * 40), subject: "the work", body: "", numstat: numstat.freeze)]
  end

  def changeset
    @changeset ||= Lain::Review::Changeset.new(
      source: instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, commits: commits.freeze,
                                                                 base_ref: base_sha, head_ref: head_sha)
    )
  end

  # A real Journal over a real file, because one acceptance criterion is about
  # what survives ON DISK when the round trip is lost.
  def journal = @journal ||= Lain::Journal.new(io: File.open(journal_path, "a"), fsync: true)

  def journal_path = @journal_path ||= File.join(@dir, "review.ndjson")

  def session(policy: Lain::Review::Verdict::Policy.default)
    @session ||= Lain::Review::Session.open(changeset:, journal:, source: "local_branch", policy:)
  end

  def anchor(path: "app.rb", side: :new, line: 42, anchor_text: "forty two", revision: head_sha)
    Lain::Review::Anchor.new(path:, side:, line:, anchor_text:, revision:)
  end

  def annotate(text: "kaboom", kind: "note", drifted: false, **anchoring)
    session.annotate(anchor(**anchoring), text, kind:, drifted:)
  end

  # A real Gh over a recording factory: `factory.argvs` is the ONE fact that
  # says whether a subprocess was spawned.
  let(:factory) { GhParity.factory }
  let(:executor) { Lain::Forge::Gh.new(shell_out_factory: factory) }

  around do |example|
    Dir.mktmpdir("lain-submit") do |dir|
      @dir = dir
      example.run
    end
  end

  def submission(comments: nil, **rest)
    return described_class.for(session:, executor:, number: 7, **rest) if comments.nil?

    described_class.new(session:, executor:, number: 7, comments:, **rest)
  end

  # What went on the wire, read back off the stdin the factory was handed --
  # never off the object that built it, which would only assert the builder
  # agrees with itself.
  def sent = JSON.parse(factory.options.last.fetch(:input))

  def body_sent = sent.fetch("body")

  def comment_of(annotation, **) = described_class::Comment.of(annotation, **)

  # The refusal message must name THAT reason, not merely be a refusal. `/range/`
  # matched the outer Refused sentence, which contains the word whatever went
  # wrong, so it could not tell one cause from any other -- which is the very
  # confusion these reasons exist to prevent.
  def refusing(reason) = /#{Regexp.escape(described_class::REASONS.fetch(reason))}/

  describe "the payload GitHub's line-and-side model asks for" do
    it "carries path, line and side RIGHT for a new-side note, and nothing else" do
      annotate
      submission.call

      expect(sent.fetch("comments"))
        .to eq([{ "path" => "app.rb", "line" => 42, "side" => "RIGHT", "body" => "kaboom" }])
    end

    # Stated as an absence as well as by the exact equality above, because
    # `position` is the field both surveyed projects still compute and octo's
    # arithmetic for it has zero test coverage. It is an offset into the diff AS
    # SERVED, so it breaks under pagination and re-hunking.
    it "never puts a position on the wire" do
      annotate
      submission.call

      expect(sent.fetch("comments").first).not_to have_key("position")
      expect(sent).not_to have_key("position")
    end

    it "spells the old side LEFT" do
      annotate(side: :old, line: 41, anchor_text: "forty one", revision: base_sha)
      submission.call

      expect(sent.fetch("comments").first).to include("side" => "LEFT", "line" => 41)
    end

    # GitHub's LEFT/RIGHT is a WIRE detail rather than review vocabulary -- but
    # the DOMAIN it maps from is the vocabulary, and `fetch` is what makes that
    # real: a member added to or renamed in Review::SIDES raises here at load
    # rather than quietly acquiring no GitHub spelling.
    it "derives its side map from Review::SIDES rather than restating the domain" do
      expect(described_class::SIDES.keys).to eq(Lain::Review::SIDES.map(&:to_sym))
      expect(described_class::SIDES.values).to contain_exactly("LEFT", "RIGHT")
    end

    it "carries one top-level commit_id, the head the changeset was read at" do
      annotate
      submission.call

      expect(sent.fetch("commit_id")).to eq(head_sha)
      expect(sent.fetch("comments").first).not_to have_key("commit_id")
    end

    it "sends a range that sits inside one hunk with its start_line and start_side" do
      placed = annotate
      submission(comments: [comment_of(placed, start_line: 40)]).call

      expect(sent.fetch("comments").first)
        .to include("line" => 42, "start_line" => 40, "side" => "RIGHT", "start_side" => "RIGHT")
    end

    it "leaves start_line off a single-position comment rather than sending it null" do
      annotate
      submission.call

      expect(sent.fetch("comments").first.keys).to contain_exactly("path", "line", "side", "body")
    end

    it "reads the review event out of the verdict, COMMENT when there is none" do
      annotate
      submission.call

      expect(sent.fetch("event")).to eq("COMMENT")
    end

    it "sends APPROVE once the round has been approved" do
      session(policy: Lain::Review::Verdict::Policy::Permissive.new)
      annotate
      session.submit("approve")
      submission.call

      expect(sent.fetch("event")).to eq("APPROVE")
    end

    it "derives its event map from Review::VERDICTS rather than restating it" do
      expect(described_class::EVENTS.keys).to eq(Lain::Review::VERDICTS)
    end
  end

  describe "validating before the network call" do
    # §4.6's first skipped check, and the one tuicr 422s on. A range is not a
    # position: narrowing it to one line (tuicr normalizes) or moving it to the
    # body both misreport what the human selected, so it stops the submission.
    it "refuses a range whose ends are in different hunks, naming the comment" do
      placed = annotate(line: 81, anchor_text: "eighty")

      expect { submission(comments: [comment_of(placed, start_line: 42)]).call }
        .to raise_error(described_class::Refused, /app\.rb:42-81 \(new\)/)
    end

    it "names the hunk-span reason and not another" do
      placed = annotate(line: 81, anchor_text: "eighty")

      expect { submission(comments: [comment_of(placed, start_line: 42)]).call }
        .to raise_error(described_class::Refused, refusing(:range_spans_hunks))
    end

    it "spawns no gh subprocess when it refuses" do
      placed = annotate(line: 81, anchor_text: "eighty")

      expect { submission(comments: [comment_of(placed, start_line: 42)]).call }
        .to raise_error(described_class::Refused)
      expect(factory.argvs).to be_empty
    end

    it "refuses a range whose ends are on different sides of the diff" do
      placed = annotate

      expect { submission(comments: [comment_of(placed, start_line: 41, start_side: :old)]).call }
        .to raise_error(described_class::Refused, refusing(:mixed_side_range))
    end

    it "refuses a range that does not run forwards" do
      placed = annotate(line: 40, anchor_text: "forty")

      expect { submission(comments: [comment_of(placed, start_line: 42)]).call }
        .to raise_error(described_class::Refused, refusing(:range_inverted))
    end

    # GitHub requires a multi-line comment's start to be strictly before its
    # end, so a "range" of one line is a single position spelled the long way --
    # and it 422s. Refused here rather than quietly flattened.
    it "refuses a range that begins and ends on the same line" do
      placed = annotate

      expect { submission(comments: [comment_of(placed, start_line: 42)]).call }
        .to raise_error(described_class::Refused, refusing(:range_inverted))
    end

    it "refuses a range whose first line the diff does not show" do
      placed = annotate

      expect { submission(comments: [comment_of(placed, start_line: 39)]).call }
        .to raise_error(described_class::Refused, refusing(:no_such_start_line))
    end

    # THE discriminating example: which rule actually ships. `unknown_path` is a
    # reason that degrades at a single position -- the example below in the
    # degrading group proves it -- and the very same reason refuses here, purely
    # because the comment carries a span. An implementation that decided by a
    # whitelist of "degrading reasons" rather than by Rejection#range? would
    # degrade this one too, and nothing else in the suite would notice.
    it "refuses a RANGE rejected for a reason that degrades at a single position" do
      placed = annotate(path: "gone.rb")

      expect { submission(comments: [comment_of(placed, start_line: 40)]).call }
        .to raise_error(described_class::Refused, refusing(:unknown_path))
    end

    it "has exactly one check per reason, and one reason per check" do
      checks = described_class::Placer.private_instance_methods(false)
                                      .grep(/\?\z/).map { |name| name.to_s.delete_suffix("?").to_sym }

      expect(checks.sort).to eq(described_class::REASONS.keys.sort)
    end

    # tuicr's MixedSideRange stands in for three structurally different causes
    # and shows one string for all of them, so a human reading it cannot tell
    # which happened. Stated mechanically rather than by eye: no two reasons may
    # share a sentence, and no sentence may contain another.
    it "gives every rejection reason its own sentence, none a substring of another" do
      sentences = described_class::REASONS.values

      expect(sentences.uniq.size).to eq(sentences.size)
      expect(sentences.size).to be > 1
      # `permutation`, never `combination`: combination yields each pair in ONE
      # order, so `one.include?(other)` never tested the reverse -- and a reason
      # that swallowed another's whole sentence passed. Half a containment law
      # reads exactly like a whole one.
      expect(sentences.permutation(2).select { |one, other| one.include?(other) }).to be_empty
    end
  end

  describe "an unmappable comment degrading instead of disappearing" do
    # §4.6's second skipped check. tuicr's own per-commit mode injects a
    # synthetic `Commit Message (abc1234)` path with no guard in the mapper, so
    # a note on a commit message maps to it and GitHub rejects the whole review.
    # Both halves, and the second one is what a mutation found missing: with the
    # path check disabled the note STILL degrades -- the line check catches it
    # one step later -- so asserting only that it reached the body says nothing
    # about the path check existing. The REASON is the observable that moves.
    it "moves a note on a path absent from the diff into the body, naming the path" do
      annotate(path: "gone.rb")
      submission.call

      expect(body_sent).to include(described_class::UNPLACED_HEADING)
      expect(body_sent).to match(/^- .*gone\.rb/)
      expect(body_sent).to include(described_class::REASONS.fetch(:unknown_path))
      expect(body_sent).not_to include(described_class::REASONS.fetch(:no_such_line))
      expect(sent.fetch("comments")).to be_empty
    end

    it "keeps the human's words and the note's kind in the bullet" do
      annotate(path: "gone.rb", kind: "blocker")
      submission.call

      expect(body_sent).to include("kaboom").and include("blocker")
    end

    it "moves a note on a line no hunk shows, and says so rather than saying the path is missing" do
      annotate(line: 60, anchor_text: "sixty")
      submission.call

      expect(body_sent).to include(described_class::REASONS.fetch(:no_such_line))
      expect(body_sent).not_to include(described_class::REASONS.fetch(:unknown_path))
    end

    # The live defect §4.6 found in tuicr: comments validated against the
    # full-range diff and submitted against a narrowed commit_id. T13 put the
    # revision ON the annotation precisely so this is detectable rather than
    # implied by whatever is on screen at submit time.
    it "moves a note authored against another revision, naming that revision" do
      annotate(revision: "d" * 40)
      submission.call

      expect(body_sent).to include(described_class::REASONS.fetch(:revision_moved))
      expect(body_sent).to include("ddddddd")
      expect(sent.fetch("comments")).to be_empty
    end

    it "keeps the human's own summary above the heading" do
      annotate(path: "gone.rb")
      submission.call(body: "the summary")

      expect(body_sent).to start_with("the summary")
      expect(body_sent.index("the summary")).to be < body_sent.index(described_class::UNPLACED_HEADING)
    end

    it "writes no heading when every comment placed" do
      annotate
      submission.call

      expect(body_sent).not_to include(described_class::UNPLACED_HEADING)
    end

    it "refuses a review with no comment and no words rather than posting an empty one" do
      expect { submission.call }.to raise_error(described_class::Nothing)
      expect(factory.argvs).to be_empty
    end
  end

  describe "durability across a lost round trip" do
    # A refusal is a VALUE at this tier, so it must reach the caller as one --
    # Submit returning it unchanged is what lets a caller decide, and what keeps
    # a retry a decision somebody takes rather than something that happens.
    it "answers gh's refusal as a value rather than raising" do
      annotate
      answer = described_class.for(session:, executor: refusing_executor, number: 7).call

      expect(answer).not_to be_ok
      expect(answer.detail["stderr"]).to include("must be part of the diff")
    end

    it "leaves the session's annotations exactly as they were" do
      placed = annotate
      described_class.for(session:, executor: refusing_executor, number: 7).call

      expect(session.annotations).to eq([placed])
    end

    it "leaves them on disk, readable by a session rebuilt from the journal" do
      annotate
      described_class.for(session:, executor: refusing_executor, number: 7).call
      journal.close

      resumed = Lain::Review::Session.from_journal(File.readlines(journal_path),
                                                   changeset:, journal: Lain::Journal.new(io: StringIO.new))

      expect(resumed.annotations.map(&:text)).to eq(["kaboom"])
    end

    # Not "the annotations were journaled earlier in the method" -- that a crash
    # could still lose. The claim is that they are ON THE FILE by the time the
    # call goes out, so the executor is what looks.
    it "has every annotation on disk by the time the submit call runs" do
      annotate
      seen = nil
      path = journal_path
      peeking = Struct.new(:noop) do
        define_method(:submit_review) do |**|
          seen = File.read(path)
          Lain::Forge::Gh::Answer.new(ok: true)
        end
      end
      described_class.for(session:, executor: peeking.new, number: 7).call

      expect(seen).to include("kaboom")
    end

    def refusing_executor
      Lain::Forge::Gh.new(shell_out_factory: GhParity::FakeGh.new do
        GhParity::FakeGhShellOut.new(1, "", GhParity::REVIEW_REFUSAL)
      end)
    end
  end
end
