# frozen_string_literal: true

# The gh executor contract, once, for every interpretation of it.
#
# `Forge::Gh` shells out, `Forge::Gh::Recorded` replays a journal, and
# `Forge::Journaled` wraps either -- three objects that must be substitutable for
# one another, because T24's landing holds one of them and must not care which.
# Deliberate identity is what a shared group states MECHANICALLY: three copies of
# these cases could only stay identical by convention, and a fix applied to one
# would be a fix missing from the other two (the reasoning
# `exec_boundary_parity.rb` records).
#
# The host block supplies ONE thing, `let(:executor)`, arranged against the
# fixture below -- the same scenario every host answers:
#
#   pr_create(head: HEAD)          opens pull request NUMBER
#   pr_create(head: OPEN_HEAD)     is refused: one is open already, at OPEN_NUMBER
#   pr_create(head: REFUSED_HEAD)  is refused by GitHub
#   pr_merge(number: NUMBER)       merges
#   merge_state(number: NUMBER)    answers MERGE_STATE
#
# OPEN_HEAD is in the fixture because `observed` is the tier's own honesty flag --
# the difference between "we opened this" and "it was already there" -- and it is
# the one thing the executors could otherwise disagree about in silence. Before
# it was here, replacing `observed: recorded.observed?` with `observed: false` in
# Recorded#replay left the whole suite green (the panel's finding).
#
# The fixture is constants rather than prose so all three hosts arrange the same
# addresses mechanically. {GhParity.factory} is the live arrangement and
# {GhParity.recorded_journal} the replayed one -- the recording under test is a
# REAL recording, produced by running the live executor under `Forge::Journaled`,
# not a hand-written fixture that could drift from what the writer actually
# writes.
module GhParity
  EPIC_SLUG = "demo"
  ISSUE_ID = "a1"
  BASE = "main"
  HEAD = "epic/demo/a1"
  TITLE = "demo a1: the thing"
  BODY = "landed by lain"
  NUMBER = 4271
  URL = "https://github.com/acme/widgets/pull/#{NUMBER}".freeze
  MERGE_STATE = "CLEAN"

  # A head ref GitHub refuses a pull request for. Its wording is gh's own, kept
  # verbatim so the "structured error, never a raw exception" case is pinned
  # against something a real gh actually says.
  REFUSED_HEAD = "epic/demo/nothing-to-compare"
  REFUSAL = "pull request create failed: GraphQL: No commits between main and epic/demo/nothing-to-compare"

  # A head ref that ALREADY has an open pull request, and gh's own wording for
  # saying so. A distinct number from NUMBER, so an executor that answered the
  # ordinary success here would be caught rather than accidentally right.
  OPEN_HEAD = "epic/demo/already-open"
  OPEN_NUMBER = 3118
  OPEN_URL = "https://github.com/acme/widgets/pull/#{OPEN_NUMBER}".freeze
  ALREADY_OPEN = %(a pull request for branch "#{OPEN_HEAD}" into branch "#{BASE}" already exists: #{OPEN_URL}).freeze

  # One review payload, in the shape §4.6 verified against both surveyed
  # projects: `path`/`line`/`side`/`body` per comment, one top-level `commit_id`,
  # and NO `position` anywhere.
  HEAD_SHA = ("f" * 40).freeze
  REVIEW = { "body" => "one thing", "commit_id" => HEAD_SHA, "event" => "COMMENT",
             "comments" => [{ "body" => "kaboom", "line" => 42, "path" => "app.rb",
                              "side" => "RIGHT" }] }.freeze
  REVIEW_ID = 88_012
  REVIEW_STATE = "COMMENTED"

  # A pull request GitHub refuses the review for, and its own 422 wording. A
  # DIFFERENT number rather than a different payload, because the number is what
  # the endpoint carries and the payload is what the address is keyed on -- so a
  # replay of the refusal cannot be confused with a replay of the success.
  UNKNOWN_NUMBER = 9999
  REVIEW_REFUSAL = <<~REFUSAL
    gh: Unprocessable Entity (HTTP 422)
    {"message":"Pull request review thread line must be part of the diff"}
  REFUSAL

  # The closed verb set, named once so the tier-2 example below can iterate it
  # rather than trusting three spec files to list the same five.
  VERBS = %i[pr_create pr_merge pr_view merge_state submit_review].freeze

  # The one duck a gh executor exercises on a Mixlib::ShellOut: #run_command,
  # #exitstatus, #stdout, #stderr. Named distinctly from up_spec.rb's
  # FakeShellOut and tmux_surface_spec.rb's FakeTmuxShellOut so the three
  # top-level constants never collide when the suite loads all of them.
  FakeGhShellOut = Struct.new(:exitstatus, :stdout, :stderr) do
    def run_command = self
  end

  # A `shell_out_factory` stand-in that answers a canned shell per argv and
  # RECORDS every argv it was handed -- which is what lets a spec pin the wire
  # (argv arrays, never `sh -c`, never a built string).
  class FakeGh
    attr_reader :argvs, :options

    def initialize(&answer)
      @answer = answer
      @argvs = []
      @options = []
    end

    def call(*argv, **options)
      @argvs << argv
      @options << options
      @answer.call(argv)
    end
  end

  # An inner that answers the two OBSERVATIONS for real and refuses every
  # EFFECT by name.
  #
  # It exists for one failure the parity group could not otherwise see. A
  # replaying executor whose verb reads `@inner.submit_review(...)` -- the
  # pass-through shape `pr_view` and `merge_state` legitimately have -- answers
  # exactly what the live executor answers, because the recording was MADE by
  # running the live executor. Every assertion about ok, value and detail then
  # passes over a call that went to the remote. Handing the replayer an inner
  # that refuses effects turns that silence into a named failure, and it costs
  # the two observations nothing, since no {Forge::Outcome} can key them.
  class ObservationsOnly
    class Reached < StandardError; end

    def initialize(live)
      @live = live
    end

    # The two verbs no Forge::Outcome can key, because they ask a question
    # rather than cause one. Everything else in VERBS is an EFFECT and is
    # derived by SUBTRACTION rather than listed: writing the effects out here
    # would be one more restatement of the closed set, in the very file whose
    # job is to hold that set once -- and a verb added to VERBS would then
    # silently not be guarded, which is the failure this class exists to catch.
    OBSERVATIONS = %i[pr_view merge_state].freeze

    OBSERVATIONS.each do |verb|
      define_method(verb) { |**kwargs| @live.public_send(verb, **kwargs) }
    end

    (VERBS - OBSERVATIONS).each do |verb|
      define_method(verb) { |**kwargs| unreached(verb, kwargs) }
    end

    private

    def unreached(verb, kwargs)
      raise Reached, "#{verb}(#{kwargs.inspect}) fell through to the inner executor -- this address IS " \
                     "recorded, so a replay reaching the remote means the verb is missing from Recorded"
    end
  end

  class << self
    # A factory answering the fixture scenario. `argv[0]` is the binary and
    # `argv[2]` the gh subcommand, because the executor prepends "gh".
    def factory = FakeGh.new { |argv| reply(argv) }

    # @param live [Forge::Gh] what the observations are answered by
    # @return [ObservationsOnly]
    def observations_only(live) = ObservationsOnly.new(live)

    # `gh api` is the one verb whose subcommand is at `argv[1]`, because it
    # carries no noun -- every other verb here is `gh <noun> <verb>`.
    def reply(argv)
      return review_reply(argv) if argv[1] == "api"

      case argv[2]
      when "create" then create_reply(argv)
      when "merge" then FakeGhShellOut.new(0, "", "")
      when "view" then viewed
      else FakeGhShellOut.new(1, "", "no fixture for #{argv.inspect}")
      end
    end

    def review_reply(argv)
      return refused_review if argv.any? { |field| field.include?("/pulls/#{UNKNOWN_NUMBER}/") }

      submitted
    end

    def submitted
      FakeGhShellOut.new(0, %({"id":#{REVIEW_ID},"state":"#{REVIEW_STATE}"}\n), "")
    end

    def refused_review = FakeGhShellOut.new(1, "", REVIEW_REFUSAL)

    def create_reply(argv)
      return refused_create if argv.include?(REFUSED_HEAD)

      argv.include?(OPEN_HEAD) ? already_open : created
    end

    def created = FakeGhShellOut.new(0, "#{URL}\n", "")
    def refused_create = FakeGhShellOut.new(1, "", REFUSAL)
    def already_open = FakeGhShellOut.new(1, "", ALREADY_OPEN)
    def viewed = FakeGhShellOut.new(0, %({"mergeStateStatus":"#{MERGE_STATE}"}\n), "")

    # The whole fixture scenario, journaled by running `executor` under
    # `Forge::Journaled`. Both refused and successful attempts are driven, so a
    # replay of these lines can answer every case the group asks about.
    #
    # @return [Array<String>] NDJSON lines
    def recorded_journal(executor)
      io = StringIO.new
      journaled = Lain::Forge::Journaled.new(executor, journal: Lain::Journal.new(io:),
                                                       epic_slug: EPIC_SLUG, issue_id: ISSUE_ID)
      journaled.pr_create(base: BASE, head: HEAD, title: TITLE, body: BODY)
      journaled.pr_create(base: BASE, head: OPEN_HEAD, title: TITLE, body: BODY)
      journaled.pr_create(base: BASE, head: REFUSED_HEAD, title: TITLE, body: BODY)
      journaled.pr_merge(number: NUMBER)
      journaled.submit_review(number: NUMBER, review: REVIEW)
      journaled.submit_review(number: UNKNOWN_NUMBER, review: REVIEW)
      io.string.lines
    end
  end
end

RSpec.shared_examples "a gh executor" do
  it "answers pr_create with the new pull request's number" do
    answer = executor.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                                title: GhParity::TITLE, body: GhParity::BODY)

    expect(answer).to be_ok
    expect(answer).not_to be_observed
    expect(answer.value).to eq(GhParity::NUMBER)
  end

  # `observed` is the tier's honesty flag: true means the effect was found
  # ALREADY IN PLACE and confirmed, rather than performed. It is the ONE fact a
  # replay could get wrong without changing ok, value or detail, so the contract
  # has to state it -- a resume that reads "we opened this" for a pull request
  # somebody else's run opened has lost the only distinction that made the
  # re-run safe.
  it "answers an effect already in place as an OBSERVED success, never a fresh one" do
    answer = executor.pr_create(base: GhParity::BASE, head: GhParity::OPEN_HEAD,
                                title: GhParity::TITLE, body: GhParity::BODY)

    expect(answer).to be_ok
    expect(answer).to be_observed
    expect(answer.value).to eq(GhParity::OPEN_NUMBER)
  end

  it "answers pr_merge with the number it merged" do
    answer = executor.pr_merge(number: GhParity::NUMBER)

    expect(answer).to be_ok
    expect(answer.value).to eq(GhParity::NUMBER)
  end

  it "answers merge_state with GitHub's own state string" do
    answer = executor.merge_state(number: GhParity::NUMBER)

    expect(answer).to be_ok
    expect(answer.value).to eq(GhParity::MERGE_STATE)
  end

  # The contract that keeps a landing legible: gh refusing is a VALUE, not an
  # exception, so a caller folds on it the same way whether the refusal was
  # heard live or read back out of a journal.
  it "answers a refused pr_create as a not-ok value carrying why, never raising" do
    answer = executor.pr_create(base: GhParity::BASE, head: GhParity::REFUSED_HEAD,
                                title: GhParity::TITLE, body: GhParity::BODY)

    expect(answer).not_to be_ok
    expect(answer.value).to be_nil
    expect(answer.detail["stderr"]).to include("No commits between")
  end

  # GitHub's line-and-side model, round-tripped: the verb takes the payload
  # whole and answers the review GitHub created. Nothing here reads `position`,
  # and nothing puts one on the wire -- see the Submit spec for that claim
  # pinned at the field level.
  it "answers submit_review with the review GitHub created" do
    answer = executor.submit_review(number: GhParity::NUMBER, review: GhParity::REVIEW)

    expect(answer).to be_ok
    expect(answer.value).to include("id" => GhParity::REVIEW_ID, "state" => GhParity::REVIEW_STATE)
  end

  # A batched review POST is not idempotent, so a refusal must arrive as a
  # value the caller can read and decide about -- never a retry, and never an
  # exception a fold has no branch for.
  it "answers a refused submit_review as a not-ok value carrying why, never raising" do
    answer = executor.submit_review(number: GhParity::UNKNOWN_NUMBER, review: GhParity::REVIEW)

    expect(answer).not_to be_ok
    expect(answer.value).to be_nil
    expect(answer.detail["stderr"]).to include("must be part of the diff")
  end

  it "answers deeply frozen, Ractor-shareable values" do
    answer = executor.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                                title: GhParity::TITLE, body: GhParity::BODY)

    expect(Ractor.shareable?(answer)).to be(true)
  end

  # Tier 2 by construction, stated mechanically rather than by convention: a
  # verb taking a positional String is a verb a model-built command could ride
  # in on, and no reading of the implementation would catch that as reliably as
  # counting the parameter kinds.
  it "takes keyword arguments only -- no verb accepts a command string" do
    GhParity::VERBS.each do |verb|
      kinds = executor.method(verb).parameters.map(&:first).uniq
      expect(kinds - %i[keyreq key]).to be_empty, "#{verb} takes #{kinds.inspect}, so a positional string fits"
    end
  end
end
